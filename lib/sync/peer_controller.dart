// Turns direct device sync on and off for the app (Settings → Sync).
//
// Off by default. When on (iPhone and iPad, app in front): this device hosts
// its own small hub, announces itself on the local network, looks for the
// other devices of the workspace, and syncs with each one every few seconds.
// When the app goes to the background everything is stopped (iOS does not
// allow more) and starts again when it returns.
//
// It needs the workspace key (the one used for end-to-end encrypted sync).
// A device that has never been set up for sync has none; then the switch says
// so instead of doing anything. Handing a brand-new device that key still
// needs the existing one-time pairing (with the PC hub or a device that
// already has it).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/repositories/canvas_repository.dart';
import '../data/storage/app_log.dart';
import '../data/workspace.dart';
import '../platform/ios_bridge.dart';
import 'peer_discovery.dart';
import 'peer_sync.dart';
import 'peer_trust.dart';
import 'sync_key_store.dart';

enum PeerSyncStatus { off, needsKey, starting, running, unsupported, failed }

class PeerSyncController extends ChangeNotifier {
  PeerSyncController({
    required this.workspace,
    required this.canvases,
    required this.settings,
    PeerDiscovery Function()? discovery,
    this.supported,
    this.every = const Duration(seconds: 20),
    this.lan = lanAddress,
  }) : _discoveryFactory = discovery;

  static const settingKey = 'peerSync';

  final Workspace workspace;
  final CanvasRepository canvases;
  final SettingsRepository settings;
  final PeerDiscovery Function()? _discoveryFactory;

  /// Whether this platform can do it (null: iPhone and iPad only).
  final bool? supported;
  final Duration every;
  final Future<String?> Function() lan;

  PeerSyncStatus _status = PeerSyncStatus.off;
  String? _problem;
  PeerHost? _host;
  PeerSyncService? _service;
  PeerDiscovery? _discovery;
  Timer? _timer;
  bool _round = false;

  PeerSyncStatus get status => _status;
  String? get problem => _problem;

  bool get isSupported => supported ?? Platform.isIOS;
  bool get enabled => settings.get<bool>(settingKey) ?? false;

  /// The devices found right now.
  List<PeerAnnouncement> get peers => [...?_service?.peers.values];

  Future<void> setEnabled(bool on) async {
    await settings.set(settingKey, on);
    if (on) {
      await start();
    } else {
      await stop();
    }
  }

  /// Starts if switched on (app start, back in front).
  Future<void> startIfEnabled() async {
    if (enabled) await start();
  }

  Future<void> start() async {
    if (_status == PeerSyncStatus.running ||
        _status == PeerSyncStatus.starting) {
      return;
    }
    if (!isSupported) {
      _set(PeerSyncStatus.unsupported);
      return;
    }
    _set(PeerSyncStatus.starting);
    try {
      final crypto = await SyncKeyStore(workspace.root).load();
      if (crypto == null) {
        _set(PeerSyncStatus.needsKey);
        return;
      }
      final trust = PeerTrust(crypto.exportKey());
      final host = PeerHost(
        workspace: workspace,
        canvases: canvases,
        crypto: crypto,
        trust: trust,
      );
      final port = await host.start(privateHost: await lan());
      final discovery =
          _discoveryFactory?.call() ?? BonjourPeerDiscovery(IosBridge.instance);
      final service = PeerSyncService(
        workspace: workspace,
        canvases: canvases,
        discovery: discovery,
        trust: trust,
        crypto: crypto,
        tokens: SecretPeerTokens(workspace.root),
        deviceName: 'this device',
      );
      await discovery.advertise(
        deviceId: workspace.device!.id,
        name: workspace.device!.id,
        port: port,
        tag: trust.tag,
      );
      await service.start();
      _host = host;
      _discovery = discovery;
      _service = service;
      service.changed.listen((_) => unawaited(syncNow()));
      _timer = Timer.periodic(every, (_) => unawaited(syncNow()));
      _problem = null;
      _set(PeerSyncStatus.running);
    } on Object catch (e, s) {
      AppLog.error('Direct sync could not start', e, s);
      await stop(keepSetting: true);
      _problem = e.toString();
      _set(PeerSyncStatus.failed);
    }
  }

  /// One round with every device found: this device's own hub first, each
  /// peer, then this device's hub again (to take in what peers pushed).
  Future<void> syncNow() async {
    final host = _host, service = _service;
    if (host == null || service == null || _round) return;
    if (service.peers.isEmpty) {
      // Still keep this device's own hub current for the first visitor.
      _round = true;
      try {
        await host.syncSelf();
      } on Object catch (e) {
        AppLog.warn('Direct sync: own hub not updated ($e)');
      } finally {
        _round = false;
      }
      return;
    }
    _round = true;
    try {
      await host.syncSelf();
      await service.syncAll();
      await host.syncSelf();
    } on Object catch (e) {
      AppLog.warn('Direct sync round failed ($e)');
    } finally {
      _round = false;
    }
  }

  /// Stops everything (app to the background, or switched off).
  Future<void> stop({bool keepSetting = true}) async {
    _timer?.cancel();
    _timer = null;
    final service = _service, host = _host, discovery = _discovery;
    _service = null;
    _host = null;
    _discovery = null;
    await service?.stop();
    await discovery?.stop();
    await host?.stop();
    if (_status != PeerSyncStatus.failed) _set(PeerSyncStatus.off);
  }

  void _set(PeerSyncStatus s) {
    _status = s;
    notifyListeners();
  }
}

/// This device's private (home or office network) IPv4 address, or null.
Future<String?> lanAddress() async {
  try {
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in i.addresses) {
        final b = a.rawAddress;
        final private =
            b[0] == 10 ||
            (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
            (b[0] == 192 && b[1] == 168);
        if (private) return a.address;
      }
    }
  } on SocketException {
    // No interface list right now.
  }
  return null;
}
