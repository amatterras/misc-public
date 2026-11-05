// A small lab for cross-device scenarios: one real hub on 127.0.0.1 and any
// number of devices, each a production AppState (SyncEngine, SyncScheduler,
// workspace on its own folder) reaching the hub through its own controllable
// "network" (FlakyProxy). A device is either a PC (Windows configuration) or
// an iPad (iOS configuration: iOS bridge, no 10-second maintenance job).
import 'dart:async';
import 'dart:io';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_application_1/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'flaky_proxy.dart';
import 'sync_keys.dart';

final sep = Platform.pathSeparator;

/// Waits (real time) until [done]; fails with [what] after [limit].
Future<Duration> until(
  FutureOr<bool> Function() done, {
  required String what,
  Duration limit = const Duration(seconds: 15),
}) async {
  final watch = Stopwatch()..start();
  while (!await done()) {
    if (watch.elapsed > limit) fail('$what not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  return watch.elapsed;
}

class Device {
  Device(this.name, this.dir, this.ipad, this.proxy);
  final String name;
  final Directory dir;
  final bool ipad;
  final FlakyProxy proxy;
  late AppState s;
}

class SyncRig {
  SyncRig._(this.root, this.hubDir, this.hub) : _port = hub.port;

  final Directory root;
  final Directory hubDir;
  HubServer hub;
  final devices = <Device>[];

  static Future<SyncRig> start() async {
    HttpOverrides.global = null;
    final root = Directory.systemTemp.createTempSync('theapp_rig_');
    final hubDir = Directory('${root.path}${sep}hub');
    final hub = await HubServer.start(
      dir: hubDir,
      port: 0,
      dailyBackups: false,
    );
    return SyncRig._(root, hubDir, hub);
  }

  int get hubPort => hub.port;

  Future<void> stopHub() => hub.stop();

  /// The same hub (same folder, same port) again.
  Future<void> startHub() async {
    hub = await HubServer.start(dir: hubDir, port: _port, dailyBackups: false);
  }

  final int _port;

  AppState _make(Device d) {
    final ws = Workspace(d.dir);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
      ios: d.ipad ? IosBridge() : null,
    );
    s.capture.fetchPreviews = false;
    // The hub of these tests is on this machine; a real iPad would refuse
    // that address, so the check is switched off for the iPad configuration.
    s.allowLoopbackHubForTests = true;
    return s;
  }

  /// A new device. [pair]: pair it with the hub now (through its own proxy).
  Future<Device> device(
    String name, {
    bool ipad = false,
    bool pair = true,
  }) async {
    final proxy = await FlakyProxy.start(_port);
    final d = Device(name, Directory('${root.path}$sep$name'), ipad, proxy);
    d.s = _make(d);
    await shareSyncKey(d.s);
    await d.s.init();
    devices.add(d);
    if (pair) {
      final error = await d.s.pairWithHub(
        'http://127.0.0.1:${proxy.port}',
        keyedPairingCode(hub.auth),
      );
      expect(error, isNull, reason: '$name pairing');
      await until(
        () => d.s.syncConnection == SyncConnection.live,
        what: '$name live',
      );
    }
    return d;
  }

  /// Closes the app on [d] and opens it again on the same folder (a restart:
  /// everything is read back from disk, the connection is set up again).
  Future<void> restart(Device d) async {
    await quiesce(d);
    d.s.dispose();
    d.s = _make(d);
    await d.s.init();
  }

  /// Stops [d]'s sync and waits for a cycle in flight, so the app can be
  /// closed or the hub stopped without a cycle hanging on it.
  Future<void> quiesce(Device d) async {
    d.s.syncPaused();
    final w = Stopwatch()..start();
    while (d.s.syncing && w.elapsed < const Duration(seconds: 12)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await d.s.flush();
  }

  Future<void> close() async {
    for (final d in devices) {
      d.s.syncPaused();
    }
    for (final d in devices) {
      final w = Stopwatch()..start();
      while (d.s.syncing && w.elapsed < const Duration(seconds: 12)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    for (final d in devices) {
      d.s.dispose();
      await d.proxy.close();
    }
    devices.clear();
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Runs sync cycles on every device until nothing moves any more.
  Future<void> converge([List<Device>? who]) async {
    final list = who ?? devices;
    for (var round = 0; round < 6; round++) {
      for (final d in list) {
        await d.s.syncNow();
      }
    }
  }
}
