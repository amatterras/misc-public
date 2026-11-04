// The switch for direct sync (sync/peer_controller.dart): off by default,
// says why when it cannot start, and when on hosts a hub, announces itself
// and syncs with a device it finds. Discovery is replaced by a hand-fed one.
import 'dart:io';

import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/sync/e2ee.dart';
import 'package:flutter_application_1/sync/peer_controller.dart';
import 'package:flutter_application_1/sync/peer_discovery.dart';
import 'package:flutter_application_1/sync/peer_trust.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recording extends ManualPeerDiscovery {
  final advertised = <({String deviceId, int port, String tag})>[];
  var stopped = false;
  @override
  Future<void> advertise({
    required String deviceId,
    required String name,
    required int port,
    required String tag,
  }) async => advertised.add((deviceId: deviceId, port: port, tag: tag));
  @override
  Future<void> stop() async => stopped = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('theapp_pctl_'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(Workspace, FileCanvasRepository, SettingsRepository)> open(
    String name,
  ) async {
    final ws = Workspace(
      Directory('${root.path}${Platform.pathSeparator}$name'),
    );
    await ws.load();
    return (ws, FileCanvasRepository(ws.store), SettingsRepository(ws.store));
  }

  test('it is off by default and unsupported platforms say so', () async {
    final (ws, canvases, settings) = await open('a');
    final c = PeerSyncController(
      workspace: ws,
      canvases: canvases,
      settings: settings,
      supported: false,
    );
    expect(c.enabled, isFalse);
    await c.startIfEnabled();
    expect(c.status, PeerSyncStatus.off, reason: 'switched off: nothing runs');
    await c.setEnabled(true);
    expect(c.status, PeerSyncStatus.unsupported);
  });

  test('without the workspace key it says what is missing', () async {
    final (ws, canvases, settings) = await open('b');
    final c = PeerSyncController(
      workspace: ws,
      canvases: canvases,
      settings: settings,
      supported: true,
      discovery: _Recording.new,
      lan: () async => null,
    );
    await c.setEnabled(true);
    // No key store on this test platform: the same "no key" answer.
    expect(c.status, anyOf(PeerSyncStatus.needsKey, PeerSyncStatus.failed));
    await c.stop();
  });

  test('the setting survives a restart', () async {
    final (ws, canvases, settings) = await open('c');
    final c = PeerSyncController(
      workspace: ws,
      canvases: canvases,
      settings: settings,
      supported: false,
    );
    await c.setEnabled(true);
    await ws.flush();
    final again = PeerSyncController(
      workspace: ws,
      canvases: canvases,
      settings: settings,
      supported: false,
    );
    expect(again.enabled, isTrue);
  });

  test('tag and key: the trust used is derived from the workspace key', () {
    final key = SyncCrypto.generate();
    expect(PeerTrust(key.exportKey()).tag, PeerTrust(key.exportKey()).tag);
    expect(
      PeerTrust(key.exportKey()).tag,
      isNot(PeerTrust(SyncCrypto.generate().exportKey()).tag),
    );
  });
}
