// Regression tests for the iPad start-up that stayed on "Starting
// iPhone/iPad services" (2026-11-10): importing items left by the Share
// Extension used to run inside start-up, so a large or damaged shared item
// held the start-up screen at every launch. The native side is SIMULATED;
// this does not prove the iPad behaviour.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/app_log.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/capture_service.dart';
import 'package:flutter_application_1/features/capture/send_to.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(IosBridge.channelName);

  late Directory dir;
  late Directory shared;
  final defaultTimeout = IosBridge.callTimeout;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('theapp_ios_inbox_');
    shared = Directory('${dir.path}${sep}group')..createSync();
    IosBridge.callTimeout = const Duration(milliseconds: 200);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    IosBridge.callTimeout = defaultTimeout;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File request(String name, Map<String, Object?> json) {
    final requests = Directory('${shared.path}${sep}inbox_requests')
      ..createSync(recursive: true);
    return File('${requests.path}$sep$name.json')
      ..writeAsStringSync(jsonEncode(json));
  }

  void simulateIos() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'sharedContainer':
          return shared.path;
        case 'sharedContainerStatus':
          return {'summary': 'TEST App Group (simulated)'};
        case 'shareTagCatalog':
          return true;
        case 'initialLinks':
          return <Object?>[];
      }
      return null;
    });
  }

  test('shared items are imported after Ready, not during start-up', () async {
    simulateIos();
    request('r1', {'type': 'text', 'value': 'shared while closed'});
    final ws = Workspace(Directory('${dir.path}${sep}data'));
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
      ios: IosBridge(),
    );
    final steps = <String>[];
    final logStart = AppLog.session.length;
    await state.init(onStep: steps.add).timeout(const Duration(seconds: 10));
    expect(steps.last, 'Ready');
    // Each iOS service is named on the start-up screen and in the log.
    expect(steps, contains('Starting iPhone/iPad services'));
    expect(
      steps,
      contains('Starting iPhone/iPad services: share inbox folder'),
    );
    expect(steps, isNot(contains(contains('shared items import'))));

    await state.iosInboxImport!.timeout(const Duration(seconds: 10));
    final log = AppLog.session.skip(logStart).toList();
    final ready = log.indexWhere((l) => l.contains('Start-up: Ready'));
    final import = log.indexWhere(
      (l) => l.contains('iOS service "shared items import": started'),
    );
    expect(ready, isNonNegative);
    expect(import, greaterThan(ready), reason: 'import runs after Ready');
    expect(
      log.any((l) => l.contains('iOS service "shared items import": done in')),
      isTrue,
    );
    expect(
      log.any((l) => l.contains('Share inbox: text request imported in')),
      isTrue,
    );
    await state.flush();
    state.dispose();
  });

  group('Share Extension requests that never finished', () {
    late Workspace ws;
    late CaptureService capture;
    setUp(() {
      ws = Workspace(Directory('${dir.path}${sep}data'));
      capture = CaptureService(ws, fetchPreviews: false);
    });

    test('one interrupted twice is set aside, kept, and not retried', () async {
      final r = request('stuck', {'type': 'text', 'value': 'big item'});
      File('${r.path}.attempts').writeAsStringSync('2');
      final ok = request('fine', {'type': 'text', 'value': 'small item'});
      final bridge = SendToBridge(shared);

      final count = await bridge.processRequests(capture);
      expect(count, 1, reason: 'the other request is still imported');
      expect(bridge.failedCount, 1);
      expect(bridge.lastFailure, contains('set aside'));
      expect(r.existsSync(), isFalse);
      expect(File('${r.path}.failed').existsSync(), isTrue, reason: 'kept');
      expect(File('${r.path}.attempts').existsSync(), isFalse);
      expect(ok.existsSync(), isFalse);
      expect(ws.inbox.all.map((i) => i.text), contains('small item'));

      // The next launch does not try it again.
      expect(await bridge.processRequests(capture), 0);
      expect(bridge.failedCount, 0);
    });

    test('one interrupted once is retried and its counter removed', () async {
      final r = request('again', {'type': 'text', 'value': 'retry me'});
      File('${r.path}.attempts').writeAsStringSync('1');
      final bridge = SendToBridge(shared);
      expect(await bridge.processRequests(capture), 1);
      expect(File('${r.path}.attempts').existsSync(), isFalse);
      expect(r.existsSync(), isFalse);
    });

    test('a request that fails normally leaves no counter behind', () async {
      // A staged Share Extension file that is missing cannot be imported.
      final r = request('bad', {
        'type': 'file',
        'temporary': true,
        'value': '${dir.path}${sep}missing.png',
      });
      final bridge = SendToBridge(shared);
      expect(await bridge.processRequests(capture), 0);
      expect(bridge.failedCount, 1);
      expect(File('${r.path}.failed').existsSync(), isTrue);
      expect(File('${r.path}.attempts').existsSync(), isFalse);
    });
  });
}
