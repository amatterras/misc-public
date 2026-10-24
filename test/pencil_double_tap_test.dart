// Apple Pencil double-tap = Undo. Tested here without an iPad: the router
// (which drawing, duplicates, the user's choices), the native→Dart
// message as Swift sends it (simulated on the channel), the app wiring and
// setting, and the Swift source. A real Pencil has NOT been tested.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/ink/pencil_double_tap.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasController make(String id) => CanvasController(
  document: CanvasDocument(
    id: id,
    title: id,
    items: const [],
    updatedAt: DateTime(2026),
    viewport: const CanvasViewport(),
    schema: 3,
  ),
  onSave: (_) async {},
);

void draw(CanvasController c, [double x = 10]) {
  c.setView(Offset.zero, 1);
  c.tool = CanvasTool.pen;
  c.pointerDown(Offset(x, 10));
  c.pointerMove(Offset(x + 30, 20));
  c.pointerMove(Offset(x + 60, 25));
  c.pointerUp();
}

int strokes(CanvasController c) => c.items.whereType<StrokeItem>().length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('router', () {
    late DateTime clock;
    late PencilDoubleTap taps;
    setUp(() {
      clock = DateTime(2026, 10, 24, 12);
      taps = PencilDoubleTap(now: () => clock);
    });
    void later([int ms = 500]) => clock = clock.add(Duration(milliseconds: ms));

    test('undoes on the drawing in use, once per tap', () {
      final a = make('a'), b = make('b');
      var bShown = true;
      taps.register(a, active: () => true);
      final unregisterB = taps.register(b, active: () => bShown);
      draw(a);
      draw(a, 100);
      draw(b);
      expect(taps.handle('switchEraser'), PencilTapResult.undone);
      expect(strokes(b), 0); // b was drawn on last
      expect(strokes(a), 2);

      // The same press arriving twice is one undo.
      expect(taps.handle('switchEraser'), PencilTapResult.repeat);
      later();
      // b has nothing left; it is still the drawing in use.
      expect(taps.handle('switchPrevious'), PencilTapResult.nothingToUndo);
      expect(strokes(a), 2);

      bShown = false; // b's page is closed or hidden
      later();
      expect(taps.handle('other'), PencilTapResult.undone);
      expect(strokes(a), 1);
      unregisterB();
      a.redo();
      expect(strokes(a), 2); // the same undo history as the Undo button
    });

    test('drawing on another surface moves the tap there', () {
      final a = make('a'), b = make('b');
      taps.register(a, active: () => true);
      taps.register(b, active: () => true);
      draw(b);
      draw(a);
      expect(taps.target, a);
      draw(b);
      expect(taps.target, b);
    });

    test('off in THEapp or in iPadOS ("ignore"): nothing happens', () {
      final a = make('a');
      taps.register(a, active: () => true);
      draw(a);
      expect(taps.handle('ignore'), PencilTapResult.ignored);
      taps.enabled = false;
      later();
      expect(taps.handle('switchEraser'), PencilTapResult.off);
      expect(strokes(a), 1);
    });

    test('no drawing shown: nothing happens', () {
      final unregister = taps.register(make('a'), active: () => false);
      expect(taps.handle('switchEraser'), PencilTapResult.noDrawing);
      unregister();
      later();
      expect(taps.handle('switchEraser'), PencilTapResult.noDrawing);
    });
  });

  group('app', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(IosBridge.channelName);
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('theapp_pencil_');
      messenger.setMockMethodCallHandler(channel, (call) async => null);
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> fromNative(String method, Object? args) =>
        messenger.handlePlatformMessage(
          IosBridge.channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, args),
          ),
          (_) {},
        );

    Future<AppState> start() async {
      final ws = Workspace(dir);
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
        ios: IosBridge(),
      );
      s.capture.fetchPreviews = false;
      await s.init();
      return s;
    }

    test('a double-tap from iOS undoes; the setting turns it off', () async {
      var s = await start();
      final c = make('c');
      s.pencilDoubleTap.register(c, active: () => true);
      draw(c);
      draw(c, 100);
      await fromNative('pencilDoubleTap', 'switchEraser');
      await Future<void>.delayed(Duration.zero);
      expect(strokes(c), 1);

      await s.setPencilDoubleTapUndo(false);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await fromNative('pencilDoubleTap', 'switchEraser');
      await Future<void>.delayed(Duration.zero);
      expect(strokes(c), 1);
      await s.flush();
      s.dispose();

      s = await start();
      expect(s.pencilDoubleTapUndo, isFalse);
      expect(s.pencilDoubleTap.enabled, isFalse);
      await s.flush();
      s.dispose();
    });

    test('nothing to undo says so', () async {
      final s = await start();
      s.pencilDoubleTap.register(make('c'), active: () => true);
      expect(
        s.onPencilDoubleTap('switchEraser'),
        PencilTapResult.nothingToUndo,
      );
      await s.flush();
      s.dispose();
    });
  });

  test('the Swift side reports taps on old and new iPadOS, once, with the '
      "user's choice (source check, not a device test)", () {
    final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(swift, contains('func pencilInteractionDidTap('));
    expect(swift, contains('didReceiveTap tap: UIPencilInteraction.Tap'));
    expect(swift, contains('@available(iOS 17.5, *)'));
    expect(swift, contains('UIPencilInteraction.preferredTapAction'));
    expect(swift, contains('case .ignore: return "ignore"'));
    expect(swift, contains('invokeMethod("pencilDoubleTap"'));
    expect(swift, contains('now - lastPencilTap < 0.25'));
  });
}
