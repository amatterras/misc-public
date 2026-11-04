// Direct device-to-device sync, built on the existing engine and hub.
//
//  * [PeerHost]: this device hosts a small hub of its own (the same HubServer
//    code the PC runs; plain Dart, so it runs on an iPhone or iPad while the
//    app is in front) and syncs itself into it, so other devices can reach
//    this device's data without the PC.
//  * [PeerSyncService]: finds the other devices (PeerDiscovery), joins their
//    hubs by proving it holds the workspace key (PeerTrust: no pairing code,
//    nothing to type, nothing recurring), and syncs with each one through the
//    ordinary SyncEngine (one sync state per peer, SyncEngine.remote).
//
// Changes made while a peer is unreachable stay in the local data and go out
// on the next successful sync with it (the engine sends whatever differs from
// what that peer last confirmed), so there is nothing extra to queue or lose.
// Sync with the PC hub is unchanged and independent: records converge through
// whichever path is open, and what is already identical is never sent twice.
//
// iOS does not let an app keep a server or a connection alive in the
// background. Peers sync while the app is in front and at the moments iOS
// allows; this file promises no more.
import 'dart:async';
import 'dart:io';

import '../data/repositories/canvas_repository.dart';
import '../data/storage/app_log.dart';
import '../data/workspace.dart';
import '../hub/hub_server.dart';
import 'e2ee.dart';
import 'peer_discovery.dart';
import 'peer_trust.dart';
import 'secret_store.dart';
import 'sync_client.dart';
import 'sync_engine.dart';

/// Where a peer's sync token is kept (the token is a secret of this device).
abstract interface class PeerTokenStore {
  Future<String?> read(String peerId);
  Future<void> write(String peerId, String token);
  Future<void> delete(String peerId);
}

class MemoryPeerTokens implements PeerTokenStore {
  final Map<String, String> _tokens = {};
  @override
  Future<String?> read(String peerId) async => _tokens[peerId];
  @override
  Future<void> write(String peerId, String token) async =>
      _tokens[peerId] = token;
  @override
  Future<void> delete(String peerId) async => _tokens.remove(peerId);
}

/// Tokens in OS-protected storage (DPAPI / Keychain), in files named
/// `*.token` so backups and exports never carry them.
class SecretPeerTokens implements PeerTokenStore {
  SecretPeerTokens(this.root);
  final Directory root;

  File _file(String id) => File(
    '${root.path}${Platform.pathSeparator}keys'
    '${Platform.pathSeparator}peer_$id.token',
  );

  @override
  Future<String?> read(String peerId) => readSecret(_file(peerId));
  @override
  Future<void> write(String peerId, String token) =>
      writeSecret(_file(peerId), token);
  @override
  Future<void> delete(String peerId) async {
    final f = _file(peerId);
    if (await f.exists()) await f.delete();
  }
}

class PeerHost {
  PeerHost({
    required this.workspace,
    required this.canvases,
    required this.crypto,
    required this.trust,
    this.openCanvas,
  });

  final Workspace workspace;
  final CanvasRepository canvases;
  final SyncCrypto crypto;
  final PeerTrust trust;
  final OpenCanvasBridge? openCanvas;

  HubServer? _hub;
  SyncEngine? _self;

  bool get running => _hub != null;
  int get port => _hub?.port ?? 0;

  /// Starts this device's hub. [privateHost] is this device's address on the
  /// local network (the hub only accepts private addresses); without it the
  /// hub listens on this device only (tests).
  Future<int> start({String? privateHost}) async {
    if (_hub != null) return port;
    final hub = await HubServer.start(
      dir: Directory('${workspace.root.path}${Platform.pathSeparator}peer_hub'),
      port: 0,
      privateHost: privateHost,
      dailyBackups: false,
    );
    hub.peerTrust = trust;
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      workspace.device!.id,
      'this device',
    );
    _self = SyncEngine(
      workspace: workspace,
      canvases: canvases,
      client: SyncClient(
        Uri.parse('http://127.0.0.1:${hub.port}'),
        token: token,
        crypto: crypto,
      ),
      openCanvas: openCanvas,
      remote: 'self',
    );
    _hub = hub;
    return hub.port;
  }

  /// Puts this device's own changes into its hub (and takes in what peers
  /// pushed there).
  Future<SyncReport?> syncSelf() async => _self?.syncOnce();

  Future<void> stop() async {
    final hub = _hub;
    _hub = null;
    _self = null;
    await hub?.stop();
  }
}

class PeerOutcome {
  const PeerOutcome(this.peerId, {this.report, this.error, this.retryable});
  final String peerId;
  final SyncReport? report;
  final String? error;
  final bool? retryable;
  bool get ok => report != null;
}

class PeerSyncService {
  PeerSyncService({
    required this.workspace,
    required this.canvases,
    required this.discovery,
    required this.trust,
    required this.crypto,
    required this.tokens,
    this.deviceName = 'device',
    this.openCanvas,
    this.retryAfter = const Duration(seconds: 30),
  });

  final Workspace workspace;
  final CanvasRepository canvases;
  final PeerDiscovery discovery;
  final PeerTrust trust;
  final SyncCrypto crypto;
  final PeerTokenStore tokens;
  final String deviceName;
  final OpenCanvasBridge? openCanvas;

  /// After a failed attempt a peer is left alone this long (it is retried
  /// sooner when it is announced again or [syncPeer] is forced).
  final Duration retryAfter;

  final Map<String, PeerAnnouncement> peers = {};
  final Map<String, SyncEngine> _engines = {};
  final Map<String, DateTime> _blockedUntil = {};
  final List<StreamSubscription<Object?>> _subs = [];

  /// Call when a peer appears or goes away.
  final StreamController<void> _changed = StreamController.broadcast();
  Stream<void> get changed => _changed.stream;

  Future<void> start() async {
    _subs
      ..add(discovery.found.listen(_onFound))
      ..add(discovery.lost.listen(_onLost));
    await discovery.startBrowsing();
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await discovery.stop();
  }

  void _onFound(PeerAnnouncement a) {
    // Another workspace, or this very device: not ours to sync with.
    if (a.tag != trust.tag || a.deviceId == workspace.device?.id) return;
    final known = peers[a.deviceId];
    peers[a.deviceId] = a;
    if (known == null || known.host != a.host || known.port != a.port) {
      _engines.remove(a.deviceId); // new address: a new connection
    }
    _blockedUntil.remove(a.deviceId); // it is there again: try at once
    _changed.add(null);
  }

  void _onLost(String id) {
    if (peers.remove(id) != null) {
      _engines.remove(id);
      _changed.add(null);
    }
  }

  /// One sync with every known peer, one after the other.
  Future<List<PeerOutcome>> syncAll() async => [
    for (final id in peers.keys.toList()) await syncPeer(id),
  ];

  Future<PeerOutcome> syncPeer(String id, {bool force = false}) async {
    final peer = peers[id];
    if (peer == null) {
      return PeerOutcome(id, error: 'Not on the network.', retryable: true);
    }
    final blocked = _blockedUntil[id];
    if (!force && blocked != null && DateTime.now().isBefore(blocked)) {
      return PeerOutcome(id, error: 'Waiting to retry.', retryable: true);
    }
    var rejoined = false;
    while (true) {
      try {
        final engine = await _engine(peer);
        final report = await engine.syncOnce();
        _blockedUntil.remove(id);
        return PeerOutcome(id, report: report);
      } on SyncFailure catch (e) {
        if (e.code == 'unauthorized' && !rejoined) {
          // The peer forgot this device (reinstalled, hub reset): join again.
          rejoined = true;
          await tokens.delete(id);
          _engines.remove(id);
          continue;
        }
        if (e.retryable || e.code == 'unauthorized') {
          _blockedUntil[id] = DateTime.now().add(retryAfter);
        }
        AppLog.warn('Peer ${peer.deviceId}: ${e.code}');
        return PeerOutcome(id, error: e.message, retryable: e.retryable);
      } on SocketException {
        _blockedUntil[id] = DateTime.now().add(retryAfter);
        return PeerOutcome(id, error: 'Not reachable.', retryable: true);
      }
    }
  }

  Future<SyncEngine> _engine(PeerAnnouncement peer) async {
    final cached = _engines[peer.deviceId];
    if (cached != null) return cached;
    final client = SyncClient(
      Uri(scheme: 'http', host: peer.host, port: peer.port),
      token: await tokens.read(peer.deviceId),
      crypto: crypto,
    );
    if (client.token == null) {
      final token = await client.peerJoin(
        trust.proof(workspace.device!.id, deviceName),
      );
      await tokens.write(peer.deviceId, token);
    }
    return _engines[peer.deviceId] = SyncEngine(
      workspace: workspace,
      canvases: canvases,
      client: client,
      openCanvas: openCanvas,
      remote: peer.deviceId,
    );
  }
}
