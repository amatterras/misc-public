// App lock and iOS file protection, against SIMULATED native pieces. This
// shows the Dart logic is right; it does not prove Face ID, the iOS cover or
// NSFileProtectionComplete work (that needs a device).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/data/storage/json_file_store.dart';
import 'package:flutter_application_1/platform/app_lock.dart';
import 'package:flutter_application_1/platform/file_protection.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAuthenticator implements BiometricAuthenticator {
  bool available = true;
  final results = <BiometricResult>[];
  Completer<BiometricResult>? pending;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<BiometricResult> authenticate(String reason) {
    prompts++;
    if (pending != null) return pending!.future;
    return Future.value(
      results.isEmpty ? BiometricResult.success : results.removeAt(0),
    );
  }
}

class FakeProtection implements ProtectionBackend {
  bool unlocked = true;
  final protectedPaths = <String>[];
  final protectedTrees = <String>[];
  final events = StreamController<bool>.broadcast();

  @override
  Future<bool> dataAvailable() async => unlocked;

  @override
  Stream<bool> get availability => events.stream;

  @override
  Future<bool> protect(List<String> paths, {bool tree = false}) async {
    if (!unlocked) return false;
    (tree ? protectedTrees : protectedPaths).addAll(paths);
    return true;
  }

  Future<void> setUnlocked(bool value) async {
    unlocked = value;
    events.add(value);
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppLockController', () {
    test('locks at launch, then unlocks when biometrics succeed', () async {
      final auth = FakeAuthenticator();
      final lock = AppLockController(authenticator: auth);
      expect(lock.covered, isTrue, reason: 'closed before start() answers');
      await lock.start();
      expect(lock.state, AppLockState.unlocked);
      expect(lock.covered, isFalse);
      expect(auth.prompts, 1);
      lock.dispose();
    });

    test('without biometrics there is no lock and nothing is faked', () async {
      final auth = FakeAuthenticator()..available = false;
      final lock = AppLockController(authenticator: auth);
      await lock.start();
      expect(lock.state, AppLockState.disabled);
      expect(lock.covered, isFalse);
      lock.lifecycleChanged(AppLifecycleState.paused);
      lock.lifecycleChanged(AppLifecycleState.inactive);
      expect(lock.state, AppLockState.disabled);
      expect(lock.covered, isFalse);
      expect(auth.prompts, 0);
      lock.dispose();
    });

    test('failure and cancel keep the app locked; retry can succeed', () async {
      final auth = FakeAuthenticator()
        ..results.addAll([BiometricResult.failed, BiometricResult.cancelled]);
      final lock = AppLockController(authenticator: auth);
      await lock.start();
      expect(lock.state, AppLockState.locked);
      expect(lock.failure, BiometricResult.failed);
      expect(lock.covered, isTrue);
      await lock.unlock();
      expect(lock.state, AppLockState.locked);
      expect(lock.failure, BiometricResult.cancelled);
      await lock.unlock(); // results empty: success
      expect(lock.state, AppLockState.unlocked);
      expect(lock.failure, isNull);
      lock.dispose();
    });

    test('an authenticator that throws leaves the app locked', () async {
      final lock = AppLockController(authenticator: _Throwing());
      await lock.start();
      expect(lock.state, AppLockState.locked);
      expect(lock.failure, BiometricResult.unavailable);
      lock.dispose();
    });

    test('never shows two prompts at once', () async {
      final auth = FakeAuthenticator()..pending = Completer();
      final lock = AppLockController(authenticator: auth);
      final started = lock.start();
      await Future<void>.delayed(Duration.zero);
      expect(lock.state, AppLockState.authenticating);
      await lock.unlock();
      await lock.unlock();
      lock.lifecycleChanged(AppLifecycleState.resumed);
      expect(auth.prompts, 1);
      auth.pending!.complete(BiometricResult.success);
      await started;
      expect(lock.state, AppLockState.unlocked);
      lock.dispose();
    });

    test('background locks at once; resume asks again', () async {
      final auth = FakeAuthenticator();
      final lock = AppLockController(authenticator: auth);
      await lock.start();
      lock.lifecycleChanged(AppLifecycleState.inactive);
      expect(lock.covered, isTrue, reason: 'covered for the app switcher');
      expect(lock.state, AppLockState.unlocked, reason: 'inactive != locked');
      lock.lifecycleChanged(AppLifecycleState.hidden);
      expect(lock.state, AppLockState.locked);
      lock.lifecycleChanged(AppLifecycleState.paused);
      expect(lock.covered, isTrue);
      lock.lifecycleChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(auth.prompts, 2);
      expect(lock.state, AppLockState.unlocked);
      expect(lock.covered, isFalse);
      lock.dispose();
    });

    test('a brief inactive (Face ID sheet) does not lock', () async {
      final auth = FakeAuthenticator();
      final lock = AppLockController(authenticator: auth);
      await lock.start();
      lock.lifecycleChanged(AppLifecycleState.inactive);
      lock.lifecycleChanged(AppLifecycleState.resumed);
      expect(lock.state, AppLockState.unlocked);
      expect(lock.covered, isFalse);
      expect(auth.prompts, 1);
      lock.dispose();
    });

    test('a late answer cannot unlock a later lock', () async {
      final auth = FakeAuthenticator()..pending = Completer();
      final lock = AppLockController(authenticator: auth);
      final started = lock.start();
      await Future<void>.delayed(Duration.zero);
      lock.lifecycleChanged(
        AppLifecycleState.paused,
      ); // backgrounded mid-prompt
      auth.pending!.complete(BiometricResult.success);
      await started;
      expect(lock.state, AppLockState.locked);
      expect(lock.covered, isTrue);
      lock.dispose();
    });

    // The timers run on the test's fake clock: [noteActivity] is called
    // inside the test zone after start(), which replaces start()'s timer.
    testWidgets('locks after five minutes without activity', (tester) async {
      final lock = AppLockController(authenticator: FakeAuthenticator());
      await tester.runAsync(lock.start);
      lock.noteActivity();
      expect(lock.state, AppLockState.unlocked);
      await tester.pump(const Duration(minutes: 4, seconds: 59));
      expect(lock.state, AppLockState.unlocked);
      await tester.pump(const Duration(seconds: 2));
      expect(lock.state, AppLockState.locked);
      lock.dispose();
    });

    testWidgets('activity restarts the five minutes', (tester) async {
      final lock = AppLockController(authenticator: FakeAuthenticator());
      await tester.runAsync(lock.start);
      lock.noteActivity();
      await tester.pump(const Duration(minutes: 4));
      lock.noteActivity();
      await tester.pump(const Duration(minutes: 4));
      expect(lock.state, AppLockState.unlocked);
      await tester.pump(const Duration(minutes: 2));
      expect(lock.state, AppLockState.locked);
      lock.dispose();
    });

    testWidgets('activity while locked does not unlock or start a timer', (
      tester,
    ) async {
      final auth = FakeAuthenticator()..results.add(BiometricResult.failed);
      final lock = AppLockController(authenticator: auth);
      await tester.runAsync(lock.start);
      lock.noteActivity();
      await tester.pump(const Duration(minutes: 10));
      expect(lock.state, AppLockState.locked);
      expect(tester.binding.hasScheduledFrame, isFalse);
      lock.dispose();
    });
  });

  group('AppLockGate', () {
    testWidgets('covers the app but keeps its state and typed text', (
      tester,
    ) async {
      final auth = FakeAuthenticator();
      final lock = AppLockController(authenticator: auth);
      final text = TextEditingController();
      addTearDown(text.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockGate(
            controller: lock,
            child: Scaffold(body: TextField(controller: text)),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
      await tester.runAsync(lock.start);
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-cover')), findsNothing);
      await tester.enterText(find.byType(TextField), 'draft note');

      lock.lifecycleChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: 'offstage');
      expect(text.text, 'draft note', reason: 'nothing lost while covered');

      auth.results.add(BiometricResult.failed);
      lock.lifecycleChanged(AppLifecycleState.resumed);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-message')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.byKey(const ValueKey('app-lock-cover')), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(text.text, 'draft note');
      lock.dispose();
    });

    testWidgets('has no password, PIN or typed fallback', (tester) async {
      final auth = FakeAuthenticator()..results.add(BiometricResult.failed);
      final lock = AppLockController(authenticator: auth);
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockGate(
            controller: lock,
            child: const Scaffold(body: Text('private')),
          ),
        ),
      );
      await tester.runAsync(lock.start);
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('private'), findsNothing);
      lock.dispose();
    });
  });

  group('iOS biometric channel', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(IosBridge.channelName);
    late Map<String, Object? Function(MethodCall)> answers;
    late List<MethodCall> calls;

    setUp(() {
      answers = {};
      calls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return answers[call.method]?.call(call);
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('maps native answers', () async {
      final auth = IosBiometricAuthenticator(IosBridge());
      for (final (native, expected) in [
        ('success', BiometricResult.success),
        ('failed', BiometricResult.failed),
        ('cancelled', BiometricResult.cancelled),
        ('unavailable', BiometricResult.unavailable),
        ('anything else', BiometricResult.unavailable),
      ]) {
        answers['biometricAuthenticate'] = (_) => native;
        expect(await auth.authenticate('x'), expected, reason: native);
      }
      answers['biometricAvailable'] = (_) => true;
      expect(await auth.isAvailable(), isTrue);
    });

    test('a missing native side means unavailable, never success', () async {
      final auth = IosBiometricAuthenticator(IosBridge());
      expect(await auth.isAvailable(), isFalse);
      expect(await auth.authenticate('x'), BiometricResult.unavailable);
    });

    test('a native error means unavailable', () async {
      answers['biometricAuthenticate'] = (_) =>
          throw PlatformException(code: 'boom');
      final auth = IosBiometricAuthenticator(IosBridge());
      expect(await auth.authenticate('x'), BiometricResult.unavailable);
    });

    test('Windows and other platforms report no biometric lock', () async {
      const auth = UnsupportedBiometricAuthenticator();
      expect(await auth.isAvailable(), isFalse);
      expect(await auth.authenticate('x'), BiometricResult.unavailable);
    });

    test('protection calls reach the native channel', () async {
      answers['protectPaths'] = (_) => true;
      answers['protectTree'] = (_) => true;
      answers['protectedDataAvailable'] = (_) => false;
      final bridge = IosBridge();
      expect(await bridge.protect(['/a', '/b']), isTrue);
      expect(await bridge.protect(['/c'], tree: true), isTrue);
      expect(await bridge.dataAvailable(), isFalse);
      expect(calls.map((c) => c.method), [
        'protectPaths',
        'protectTree',
        'protectedDataAvailable',
      ]);
      expect(calls.first.arguments, ['/a', '/b']);
    });

    test('lock-state events from iOS reach Dart', () async {
      final bridge = IosBridge();
      final seen = <bool>[];
      final sub = bridge.availability.listen(seen.add);
      await messenger.handlePlatformMessage(
        IosBridge.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('protectedData', false),
        ),
        (_) {},
      );
      await messenger.handlePlatformMessage(
        IosBridge.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('protectedData', true),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, [false, true]);
      await sub.cancel();
    });
  });

  group('FileProtection', () {
    late FakeProtection backend;
    setUp(() async {
      backend = FakeProtection();
      FileProtection.backend = backend;
      await FileProtection.start();
    });
    tearDown(FileProtection.reset);

    test('does nothing without a backend (Windows)', () async {
      await FileProtection.reset();
      var ran = 0;
      expect(await FileProtection.whenUnlocked(() async => ++ran), 1);
      await FileProtection.protect(['/x']);
      expect(FileProtection.available, isTrue);
    });

    test('protects files and trees when unlocked', () async {
      await FileProtection.protect(['/a']);
      await FileProtection.protect(['/dir'], tree: true);
      expect(backend.protectedPaths, ['/a']);
      expect(backend.protectedTrees, ['/dir']);
    });

    test('protection owed while locked is applied after unlock', () async {
      await backend.setUnlocked(false);
      await FileProtection.protect(['/a']);
      await FileProtection.protect(['/dir'], tree: true);
      expect(backend.protectedPaths, isEmpty);
      await backend.setUnlocked(true);
      expect(backend.protectedPaths, ['/a']);
      expect(backend.protectedTrees, ['/dir']);
    });

    test('a write waits for unlock and runs once', () async {
      await backend.setUnlocked(false);
      var runs = 0;
      final done = FileProtection.whenUnlocked(() async => ++runs);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(runs, 0);
      await backend.setUnlocked(true);
      expect(await done, 1);
      expect(runs, 1);
    });

    test('a missed unlock notification does not hang a write', () async {
      await backend.setUnlocked(false);
      var runs = 0;
      final done = FileProtection.whenUnlocked(() async => ++runs);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(runs, 0);
      backend.unlocked = true; // unlocked, but no event is ever sent
      expect(await done, 1);
      expect(runs, 1);
    });

    test('a write that fails because the device locked is deferred', () async {
      var attempts = 0;
      final done = FileProtection.whenUnlocked(() async {
        attempts++;
        if (attempts == 1) {
          backend.unlocked = false; // locked while writing
          throw const FileSystemException('Operation not permitted');
        }
        return 'ok';
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempts, 1);
      await backend.setUnlocked(true);
      expect(await done, 'ok');
      expect(attempts, 2);
    });

    test('a real file error while unlocked is not swallowed', () async {
      expect(
        FileProtection.whenUnlocked<void>(
          () async => throw const FileSystemException('disk full'),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('JsonFileStore writes wait while locked, in order, once', () async {
      final dir = Directory.systemTemp.createTempSync('theapp_protect_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonFileStore(dir);
      await store.write('c', 'a', {'v': 0});
      expect(backend.protectedPaths, hasLength(2), reason: 'file and .bak');

      await backend.setUnlocked(false);
      final first = store.write('c', 'a', {'v': 1});
      final second = store.write('c', 'a', {'v': 2});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect((await store.read('c', 'a'))!['v'], 0, reason: 'not written yet');

      await backend.setUnlocked(true);
      await Future.wait([first, second]);
      expect((await store.read('c', 'a'))!['v'], 2);
      expect(
        dir.listSync(recursive: true).where((e) => e.path.endsWith('.tmp')),
        isEmpty,
      );
    });
  });

  group('iOS project settings', () {
    String read(String path) => File(path).readAsStringSync();

    test('files default to NSFileProtectionComplete', () {
      final entitlements = read('ios/Runner/Runner.entitlements');
      expect(
        entitlements,
        contains('com.apple.developer.default-data-protection'),
      );
      expect(
        entitlements,
        contains('<string>NSFileProtectionComplete</string>'),
      );
      expect(
        entitlements,
        isNot(contains('CompleteUntilFirstUserAuthentication')),
      );
      expect(entitlements, isNot(contains('NSFileProtectionNone')));
    });

    test('Face ID has a usage description', () {
      expect(
        read('ios/Runner/Info.plist'),
        contains('NSFaceIDUsageDescription'),
      );
    });

    test('native code is biometrics-only and complete-protected', () {
      final delegate = read('ios/Runner/AppDelegate.swift');
      expect(delegate, contains('.deviceOwnerAuthenticationWithBiometrics'));
      // The passcode-accepting policy must not be used.
      expect(
        RegExp(r'\.deviceOwnerAuthentication\b(?!With)').hasMatch(delegate),
        isFalse,
      );
      expect(delegate, contains('localizedFallbackTitle = ""'));
      expect(delegate, contains('FileProtectionType.complete'));
      expect(delegate, contains('.completeFileProtection'));
      expect(delegate, isNot(contains('.noFileProtection')));
      expect(delegate, isNot(contains('completeUntilFirstUserAuthentication')));
    });

    test('the app switcher and screen recording are covered natively', () {
      final scene = read('ios/Runner/SceneDelegate.swift');
      expect(scene, contains('sceneWillResignActive'));
      expect(scene, contains('sceneDidBecomeActive'));
      expect(scene, contains('isCaptured'));
      expect(scene, contains('capturedDidChangeNotification'));
      expect(scene, contains('didEnterBackgroundNotification'));
      expect(scene, contains('willEnterForegroundNotification'));
    });

    test('a screenshot (app only inactive) never covers the screen', () {
      final scene = read('ios/Runner/SceneDelegate.swift');
      final resign = RegExp(
        r'override func sceneWillResignActive[\s\S]*?\n  \}',
      ).firstMatch(scene)!.group(0)!;
      expect(resign, isNot(contains('setInBackground(true)')));
      expect(resign, isNot(contains('show(')));
    });

    test('file protection is walked off the main thread', () {
      final delegate = read('ios/Runner/AppDelegate.swift');
      expect(delegate, contains('protectInBackground'));
      expect(delegate, isNot(contains('result(Self.protect(')));
    });
  });
}

class _Throwing implements BiometricAuthenticator {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<BiometricResult> authenticate(String reason) =>
      throw StateError('no sensor');
}
