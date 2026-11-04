// Finding your other devices on the local network. A transport seam: the
// sync engine does not know how a peer was found. Bonjour (iPhone and iPad,
// through Swift) is one source; a hand-entered or Tailscale address is
// another ([ManualPeerDiscovery]); more can be added without touching the
// engine.
import 'dart:async';

import '../platform/ios_bridge.dart';

/// A device of this workspace that can be reached for sync.
class PeerAnnouncement {
  const PeerAnnouncement({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.port,
    required this.tag,
  });

  final String deviceId;
  final String name;
  final String host;
  final int port;

  /// PeerTrust.tag of the workspace it belongs to.
  final String tag;

  @override
  String toString() => 'Peer $deviceId at $host:$port';
}

abstract interface class PeerDiscovery {
  /// A peer appeared (or its address changed).
  Stream<PeerAnnouncement> get found;

  /// A peer went away (its device id).
  Stream<String> get lost;

  /// Makes this device findable.
  Future<void> advertise({
    required String deviceId,
    required String name,
    required int port,
    required String tag,
  });

  Future<void> startBrowsing();

  /// Stops advertising and browsing.
  Future<void> stop();
}

/// Peers announced by code: a configured address (Tailscale, a fixed IP) or a
/// test. Also what is used where no automatic discovery exists.
class ManualPeerDiscovery implements PeerDiscovery {
  final _found = StreamController<PeerAnnouncement>.broadcast();
  final _lost = StreamController<String>.broadcast();

  @override
  Stream<PeerAnnouncement> get found => _found.stream;
  @override
  Stream<String> get lost => _lost.stream;

  void announce(PeerAnnouncement peer) => _found.add(peer);
  void withdraw(String deviceId) => _lost.add(deviceId);

  @override
  Future<void> advertise({
    required String deviceId,
    required String name,
    required int port,
    required String tag,
  }) async {}

  @override
  Future<void> startBrowsing() async {}

  @override
  Future<void> stop() async {}
}

/// Bonjour (`_misc-sync._tcp`) through the iOS bridge. The Swift side
/// (AppDelegate.swift, PeerBonjour) needs the local-network permission and
/// the `NSBonjourServices` entry in Info.plist; it has been compiled only in
/// the cloud and never run on a device.
class BonjourPeerDiscovery implements PeerDiscovery {
  BonjourPeerDiscovery(this._bridge) {
    _bridge.peerFound.listen((m) {
      final txt = (m['txt'] as Map?)?.cast<String, String>() ?? const {};
      final id = txt['id'], tag = txt['tag'];
      final port = m['port'];
      final host = m['host'];
      if (id == null || tag == null || port is! int || host is! String) return;
      if (host.isEmpty) return;
      _found.add(
        PeerAnnouncement(
          deviceId: id,
          name: '${m['name'] ?? id}',
          host: host,
          port: port,
          tag: tag,
        ),
      );
    });
    _bridge.peerLost.listen((serviceName) {
      final id = _names.remove(serviceName) ?? serviceName;
      _lost.add(id);
    });
  }

  final IosBridge _bridge;
  final _found = StreamController<PeerAnnouncement>.broadcast();
  final _lost = StreamController<String>.broadcast();
  final Map<String, String> _names = {};

  @override
  Stream<PeerAnnouncement> get found => _found.stream;
  @override
  Stream<String> get lost => _lost.stream;

  @override
  Future<void> advertise({
    required String deviceId,
    required String name,
    required int port,
    required String tag,
  }) async {
    _names[name] = deviceId;
    await _bridge.peerAdvertise(
      name: name,
      port: port,
      txt: {'id': deviceId, 'tag': tag},
    );
  }

  @override
  Future<void> startBrowsing() => _bridge.peerBrowse();

  @override
  Future<void> stop() async {
    await _bridge.peerStop();
  }
}
