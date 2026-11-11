// P0 regression 2026-11-11: Apple Pencil squeeze (hold → eraser) and
// double-tap (→ Undo) stopped working. Both come from ONE native object,
// UIPencilInteraction, which Swift installed only if a foreground-active key
// window existed at the moment a drawing page asked; otherwise the install
// failed silently and was never tried again. Fixed in AppDelegate.swift
// (installPencilInteractions on every Flutter window) and SceneDelegate.swift
// (installed again on every scene activation).
//
// What is tested here, WITHOUT an iPad: the Swift source (not compiled), and
// the Dart side end to end on the Mindmap canvas with the same platform
// messages Swift sends, plus ordinary drawing, erasing, undo/redo, panning
// and the toolbar around it. A real Pencil has NOT been tested.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_page.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Swift source (not compiled here)', () {
    final app = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final scene = File('ios/Runner/SceneDelegate.swift').readAsStringSync();

    String body(String source, String signature) {
      final start = source.indexOf(signature);
      expect(start, isNonNegative, reason: '$signature is missing');
      final next = source.indexOf(
        RegExp(r'\n  (private )?func |\n  //'),
        start + 1,
      );
      return source.substring(start, next < 0 ? source.length : next);
    }

    test('Dart asking installs on every Flutter window, not only the '
        'foreground-active key window of that moment', () {
      expect(app, contains('case "enablePencilSqueeze":'));
      expect(app, contains('result(installPencilInteraction())'));
      final ask = body(app, 'private func installPencilInteraction() -> Bool');
      expect(ask, contains('pencilInteractionOn = true'));
      expect(ask, contains('installPencilInteractions()'));
      final install = body(app, 'func installPencilInteractions() -> Bool');
      expect(install, contains('guard pencilInteractionOn'));
      expect(install, contains('UIApplication.shared.connectedScenes'));
      expect(install, contains('rootViewController is FlutterViewController'));
      // The old one-shot guard that made a failed first try permanent.
      expect(app, isNot(contains('if pencilInteraction != nil')));
    });

    test('never two interactions on one window (one tap, one undo)', () {
      final add = body(
        app,
        'private func addPencilInteraction(to view: UIView)',
      );
      expect(add, contains('delegate === self'));
      expect(add, contains('interaction.delegate = self'));
      // Swift also drops a tap delivered twice (both iPadOS APIs).
      expect(app, contains('now - lastPencilTap < 0.25'));
    });

    test('installed again whenever a scene becomes active', () {
      final active = body(scene, 'override func sceneDidBecomeActive');
      expect(active, contains('installPencilInteractions()'));
      expect(active, contains('installInkObservers()'));
    });
  });

  group('Mindmap on an iPad (simulated native messages)', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(IosBridge.channelName);
    late Directory dir;
    late List<String> calls;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('theapp_pencil_p0_');
      calls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'enablePencilSqueeze') return true;
        return null;
      });
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<AppState> boot(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ws = Workspace(dir);
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
        ios: IosBridge(),
      );
      s.capture.fetchPreviews = false;
      await tester.runAsync(s.init);
      await tester.pumpWidget(TheApp(state: s));
      await tester.pump();
      await tester.runAsync(() => s.createCanvas(show: true));
      s.goTo(AppPage.canvas);
      await settle(tester);
      return s;
    }

    Future<void> shutDown(WidgetTester tester, AppState s) async {
      await waitForBothClocks(tester, s.flush, what: 'Saving');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      s.dispose();
    }

    Future<void> fromNative(
      WidgetTester tester,
      String method,
      Object? args,
    ) async {
      await messenger.handlePlatformMessage(
        IosBridge.channelName,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
      await tester.pump();
    }

    var pointer = 100;
    Future<void> pencil(WidgetTester tester, Offset from, Offset by) async {
      final g = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        pointer: pointer++,
      );
      await g.down(from);
      await g.moveTo(from + by * 0.5);
      await g.moveTo(from + by);
      await g.up();
      // The pen-lift wait for native samples (PencilFeed.finish).
      await tester.pump(const Duration(milliseconds: 50));
    }

    int strokes(CanvasController c) => c.items.whereType<StrokeItem>().length;

    testWidgets('double-tap undoes exactly once per tap; Undo/Redo buttons, '
        'drawing and panning still work', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final s = await boot(tester);
      final c = s.canvas!;
      // The canvas asked iOS for squeeze + double-tap.
      expect(calls, contains('enablePencilSqueeze'));

      c.tool = CanvasTool.pen;
      await tester.pump();
      final centre = tester.getRect(find.byType(CanvasView)).center;
      await pencil(
        tester,
        centre - const Offset(120, 60),
        const Offset(80, 10),
      );
      await pencil(
        tester,
        centre + const Offset(150, -40),
        const Offset(80, 10),
      );
      expect(strokes(c), 2);
      // Let the entry screen finish fading out (a separate, debug-only
      // AnimatedSwitcher issue when the map empties again within 140 ms).
      await tester.pump(const Duration(milliseconds: 300));

      // One double-tap, delivered twice by iOS (old + new API): one undo.
      await fromNative(tester, 'pencilDoubleTap', 'switchEraser');
      await fromNative(tester, 'pencilDoubleTap', 'switchEraser');
      expect(strokes(c), 1);
      expect(c.canRedo, isTrue);
      expect(c.tool, CanvasTool.pen, reason: 'a tap never changes the tool');

      // The toolbar's own Redo and Undo are the same history.
      await tester.tap(find.byTooltip('Redo  (Ctrl+Y)'));
      await tester.pump();
      expect(strokes(c), 2);
      await tester.tap(find.byTooltip('Undo  (Ctrl+Z)'));
      await tester.pump();
      expect(strokes(c), 1);

      // A later double-tap (past the duplicate gap) undoes the next step.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)),
      );
      await fromNative(tester, 'pencilDoubleTap', 'switchPrevious');
      expect(strokes(c), 0);

      // Turned off in iPadOS Settings: nothing happens.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)),
      );
      await pencil(
        tester,
        centre + const Offset(150, -120),
        const Offset(60, 20),
      );
      expect(strokes(c), 1);
      await fromNative(tester, 'pencilDoubleTap', 'ignore');
      expect(strokes(c), 1);

      // One finger still pans; it draws nothing.
      final before = c.offset;
      final finger = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: pointer++,
      );
      await finger.down(centre + const Offset(300, -250));
      await finger.moveTo(centre + const Offset(360, -210));
      await finger.up();
      await tester.pump();
      expect(c.offset, isNot(before));
      expect(strokes(c), 1);

      await shutDown(tester, s);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('squeeze (hold) picks the eraser without erasing anything; '
        'erases with the Pencil while held; the tool before comes back', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final s = await boot(tester);
      final c = s.canvas!;
      c.tool = CanvasTool.pen;
      await tester.pump();
      final centre = tester.getRect(find.byType(CanvasView)).center;
      await pencil(
        tester,
        centre + const Offset(-40, -120),
        const Offset(80, 0),
      );
      await pencil(
        tester,
        centre + const Offset(-40, -200),
        const Offset(80, 0),
      );
      expect(strokes(c), 2);
      await tester.pump(const Duration(milliseconds: 300));
      final undoSteps = c.canUndo;

      await fromNative(tester, 'pencilSqueeze', 'began');
      expect(c.tool, CanvasTool.eraser);
      expect(c.squeezeEraser, isTrue);
      expect(find.byKey(const ValueKey('squeeze-eraser')), findsOneWidget);
      // Picking the eraser erased nothing.
      expect(strokes(c), 2);
      expect(c.canUndo, undoSteps);
      // A second "began" (a squeeze reported twice) changes nothing.
      await fromNative(tester, 'pencilSqueeze', 'began');
      expect(c.tool, CanvasTool.eraser);

      // While held, the Pencil erases what it crosses (and only that).
      await pencil(tester, centre + const Offset(0, -150), const Offset(0, 60));
      expect(strokes(c), 1);

      await fromNative(tester, 'pencilSqueeze', 'ended');
      expect(c.tool, CanvasTool.pen);
      expect(c.squeezeEraser, isFalse);
      expect(find.byKey(const ValueKey('squeeze-eraser')), findsNothing);

      // Drawing again is ordinary drawing, and Undo brings the erased back.
      await pencil(
        tester,
        centre + const Offset(-40, -260),
        const Offset(80, 0),
      );
      expect(strokes(c), 2);
      c.undo();
      c.undo();
      await tester.pump();
      expect(strokes(c), 2);

      // A cancelled squeeze also gives the tool back.
      await fromNative(tester, 'pencilSqueeze', 'began');
      expect(c.tool, CanvasTool.eraser);
      await fromNative(tester, 'pencilSqueeze', 'cancelled');
      expect(c.tool, CanvasTool.pen);

      // The toolbar still chooses tools; a tool picked by hand during a
      // squeeze stays afterwards.
      await fromNative(tester, 'pencilSqueeze', 'began');
      await tester.tap(find.byTooltip('Highlighter'));
      await tester.pump();
      expect(c.tool, CanvasTool.highlighter);
      await fromNative(tester, 'pencilSqueeze', 'ended');
      expect(c.tool, CanvasTool.highlighter);

      await shutDown(tester, s);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
