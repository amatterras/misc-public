// Start-up must never end in a blank screen: a failing or hanging step is
// shown (with the log), iOS calls that never answer cannot block it, and a
// Keychain that does not answer does not change the device's identity.
// The native side is SIMULATED; this does not prove the iPad behaviour.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/startup.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/app_log.dart';
import 'package:flutter_application_1/data/storage/json_file_store.dart';
import 'package:flutter_application_1/data/sync/sync_clock.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_application_1/sync/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

class BrokenKeychain implements KeychainBackend {
  @override
  Future<String?> read(String key) async =>
      throw TimeoutException('No answer from iOS for "keychainRead"');
  @override
  Future<void> write(String key, String value) async =>
      throw TimeoutException('No answer from iOS for "keychainWrite"');
  @override
  Future<void> delete(String key) async {}
}

class MemoryKeychain implements KeychainBackend {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(IosBridge.channelName);

  late Directory dir;
  final defaultTimeout = IosBridge.callTimeout;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('theapp_startup_');
    IosBridge.callTimeout = const Duration(milliseconds: 100);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    IosBridge.callTimeout = defaultTimeout;
    secretKeychain = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('an iOS side that never answers cannot block start-up', () async {
    // Every native call hangs forever (e.g. a handler that never replies).
    messenger.setMockMethodCallHandler(
      channel,
      (call) => Completer<Object?>().future,
    );
    secretKeychain = IosBridge();
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
      ios: IosBridge(),
    );
    final steps = <String>[];
    await state.init(onStep: steps.add).timeout(const Duration(seconds: 10));
    expect(steps.last, 'Ready');
    expect(steps, contains('Starting iPhone/iPad services'));
    expect(state.canvasList, isNotEmpty, reason: 'the app opened normally');
    expect(
      AppLog.session.any((l) => l.contains('services unavailable')),
      isTrue,
      reason: 'the reason is in the log',
    );
    await state.flush();
    state.dispose();
  });

  test('a Keychain that fails keeps the device identity', () async {
    final store = JsonFileStore(dir);
    final keychain = MemoryKeychain();
    final first = await DeviceIdentity.loadOrCreate(store, keychain: keychain);
    // Now the Keychain stops answering: not a restored backup, same device.
    final again = await DeviceIdentity.loadOrCreate(
      store,
      keychain: BrokenKeychain(),
    );
    expect(again.id, first.id);
    expect((await store.read('sync', 'device'))?['replaces'], isNull);
  });

  testWidgets('the start-up screen shows the step, a stuck step and an '
      'error', (tester) async {
    final progress = StartupProgress();
    StartupScreen.stuckAfter = const Duration(seconds: 15);
    await tester.pumpWidget(StartupApp(progress: progress));
    progress.to('Loading your data');
    await tester.pump();
    expect(find.text('Loading your data…'), findsOneWidget);

    // A step that takes too long is reported, not left as a blank wait.
    progress.stepSince = DateTime.now().subtract(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('startup-stuck')), findsOneWidget);
    expect(find.textContaining('Loading your data'), findsWidgets);

    AppLog.info('synthetic log line for the screen');
    progress.fail(StateError('synthetic start-up failure'), StackTrace.current);
    await tester.pump();
    expect(find.byKey(const ValueKey('startup-error')), findsOneWidget);
    expect(find.textContaining('synthetic start-up failure'), findsOneWidget);
    expect(
      find.textContaining('synthetic log line for the screen'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a part that fails to build says why (release builds)', (
    tester,
  ) async {
    await tester.pumpWidget(
      readableErrorWidget(
        FlutterErrorDetails(exception: StateError('synthetic build error')),
      ),
    );
    expect(find.textContaining('synthetic build error'), findsOneWidget);
  });

  test('the log copy gets the same lines', () {
    final copy = File('${dir.path}${sep}Documents${sep}THEapp-log.txt');
    AppLog.init(dir, copy: copy);
    AppLog.info('synthetic line for the copy');
    expect(copy.readAsStringSync(), contains('synthetic line for the copy'));
    expect(
      File('${dir.path}${sep}logs${sep}app.log').readAsStringSync(),
      contains('synthetic line for the copy'),
    );
    // Back to a throwaway folder so later tests never write to this one.
    AppLog.init(Directory.systemTemp.createTempSync('theapp_log_'));
  });
}
