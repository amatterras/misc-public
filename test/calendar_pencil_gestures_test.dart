// Calendar with the Apple Pencil and fingers, SIMULATED (no iPad here):
// squeezes arrive as the same platform messages Swift sends, fingers and
// the Pencil as Flutter pointer events of those kinds. Checked:
// - a squeeze makes the pen the eraser and back, once per press, draws
//   nothing, and does not move or resize anything on screen;
// - in Draw mode one pointer draws, two fingers pinch and pan, a second
//   finger cancels a finger stroke instead of drawing it, a palm next to
//   the Pencil does nothing, and nothing stays stuck afterwards.
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
import 'package:flutter_application_1/features/calendar/calendar_ink.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(IosBridge.channelName);
  late Directory dir;
  late AppState s;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('theapp_calpen_');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'enablePencilSqueeze') return true;
      return null;
    });
  });

  test(
    'iOS calendar ink claims stylus-kind input and rejects finger strokes',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final controller = CanvasController(
          document: CanvasDocument(
            id: 'calendar-ink-test',
            title: 'Test',
            items: const [],
            updatedAt: DateTime(2026),
          ),
          onSave: (_) async {},
        );
        final arbiter = CalendarInkArbiter(controller);
        final finger = PointerDownEvent(
          pointer: 91,
          position: Offset.zero,
          kind: PointerDeviceKind.touch,
          buttons: kPrimaryButton,
        );
        arbiter.down(finger);
        expect(arbiter.claim(finger), isFalse);
        final pencil = PointerDownEvent(
          pointer: 92,
          position: Offset.zero,
          kind: PointerDeviceKind.stylus,
          buttons: kPrimaryButton,
        );
        arbiter.down(pencil);
        expect(arbiter.claim(pencil), isTrue);
        arbiter.release(91);
        arbiter.release(92);
        controller.dispose();
        arbiter.dispose();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> boot(
    WidgetTester tester, {
    Size size = const Size(820, 1180),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ws = Workspace(dir);
    s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
      ios: IosBridge(),
    );
    s.capture.fetchPreviews = false;
    await tester.runAsync(s.init);
    s.goTo(AppPage.calendar);
    await tester.pumpWidget(TheApp(state: s));
    // AppState opens the Calendar ink itself (for the widgets), so
    // `calendarInk` is set before the page has attached its squeeze
    // listener. The page is ready once its ink layers are on screen.
    for (
      var i = 0;
      i < 20 && find.byType(DayInkLayer).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pump();
  }

  Future<void> shutDown(WidgetTester tester) async {
    await waitForBothClocks(tester, s.flush, what: 'Saving');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    s.dispose();
  }

  Future<void> squeeze(WidgetTester tester, String phase) async {
    await messenger.handlePlatformMessage(
      IosBridge.channelName,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('pencilSqueeze', phase),
      ),
      (_) {},
    );
    await tester.pump();
  }

  Rect grid(WidgetTester tester) =>
      tester.getRect(find.byType(InteractiveViewer));
  CanvasController ink() => s.calendarInk!;
  int strokes() => ink().items.whereType<StrokeItem>().length;
  Matrix4 view(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!
      .value
      .clone();

  Future<void> drawMode(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('calendar-draw')));
    await tester.pump();
  }

  testWidgets('squeeze: eraser while held, nothing moves, nothing drawn', (
    tester,
  ) async {
    await boot(tester);
    final screen = tester.view.physicalSize;
    final before = grid(tester);
    final penBefore = ink().tool;
    final itemsBefore = ink().items.length;

    // While idle (Draw mode off).
    await squeeze(tester, 'began');
    expect(ink().tool, CanvasTool.eraser);
    expect(find.byKey(const ValueKey('eraser-panel')), findsNothing);
    expect(grid(tester), before); // not moved, not resized
    expect(tester.view.physicalSize, screen);
    await squeeze(tester, 'ended');
    expect(ink().tool, penBefore);
    expect(grid(tester), before);

    // Rapid and repeated (a press reported twice is still one press).
    for (final phase in [
      'began',
      'began',
      'ended',
      'ended',
      'began',
      'cancelled',
      'began',
      'ended',
    ]) {
      await squeeze(tester, phase);
      expect(grid(tester), before, reason: phase);
    }
    expect(ink().tool, penBefore);

    // In Draw mode with the pen.
    await drawMode(tester);
    final drawing = grid(tester);
    await squeeze(tester, 'began');
    expect(ink().tool, CanvasTool.eraser);
    expect(find.byKey(const ValueKey('eraser-panel')), findsNothing);
    expect(grid(tester), drawing);
    await squeeze(tester, 'ended');
    expect(ink().tool, CanvasTool.pen);
    expect(grid(tester), drawing);
    expect(ink().items.length, itemsBefore); // a squeeze never draws
    await shutDown(tester);
  });

  testWidgets('squeeze in the middle of a Pencil stroke keeps the stroke', (
    tester,
  ) async {
    await boot(tester);
    await drawMode(tester);
    final before = grid(tester);
    final at = before.center;
    final pen = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
      pointer: 30,
    );
    await pen.down(at);
    await pen.moveTo(at + const Offset(30, 5));
    await squeeze(tester, 'began');
    await pen.moveTo(at + const Offset(60, 10));
    await pen.up();
    await tester.pump();
    await squeeze(tester, 'ended');
    expect(strokes(), 1);
    expect(ink().tool, CanvasTool.pen);
    expect(grid(tester), before);
    await shutDown(tester);
  });

  testWidgets('Draw mode: two fingers pinch and pan; one pointer draws', (
    tester,
  ) async {
    await boot(tester);
    await drawMode(tester);
    final c = grid(tester).center;
    final start = view(tester);

    // Pinch out with two fingers: zooms, draws nothing.
    final a = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 1,
    );
    final b = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 2,
    );
    await a.down(c - const Offset(40, 0));
    await b.down(c + const Offset(40, 0));
    await tester.pump();
    for (var i = 1; i <= 6; i++) {
      await a.moveTo(c - Offset(40.0 + 15 * i, 0));
      await b.moveTo(c + Offset(40.0 + 15 * i, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pump();
    final zoomed = view(tester);
    expect(zoomed.getMaxScaleOnAxis(), greaterThan(start.getMaxScaleOnAxis()));
    expect(strokes(), 0);

    // Two-finger pan in every direction moves the Calendar.
    for (final d in const [
      Offset(0, 60),
      Offset(0, -60),
      Offset(60, 0),
      Offset(-60, 0),
    ]) {
      final before = view(tester).getTranslation();
      final p = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 3,
      );
      final q = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 4,
      );
      await p.down(c);
      await q.down(c + const Offset(50, 0));
      await tester.pump();
      for (var i = 1; i <= 5; i++) {
        await p.moveTo(c + d * (i / 5));
        await q.moveTo(c + const Offset(50, 0) + d * (i / 5));
        await tester.pump();
      }
      await p.up();
      await q.up();
      await tester.pump();
      final moved = view(tester).getTranslation() - before;
      expect(moved.x * d.dx + moved.y * d.dy, greaterThan(0), reason: '$d');
    }
    expect(strokes(), 0);

    // One finger draws (and does not move the Calendar).
    final still = view(tester);
    final f = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 5,
    );
    await f.down(c);
    await f.moveTo(c + const Offset(40, 10));
    await f.moveTo(c + const Offset(80, 20));
    await f.up();
    await tester.pump();
    expect(strokes(), 1);
    expect(view(tester), still);
    expect(ink().tool, CanvasTool.pen); // the tool was never changed
    await shutDown(tester);
  });

  testWidgets('a second finger turns a finger stroke into a pinch; nothing '
      'stays stuck; a palm beside the Pencil does nothing', (tester) async {
    await boot(tester);
    await drawMode(tester);
    final c = grid(tester).center;

    final a = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 11,
    );
    await a.down(c);
    await a.moveTo(c + const Offset(20, 0));
    await tester.pump();
    final b = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 12,
    );
    await b.down(c + const Offset(80, 0));
    await tester.pump();
    await a.moveTo(c - const Offset(20, 0));
    await b.moveTo(c + const Offset(120, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pump();
    expect(strokes(), 0); // the half line was cancelled, not kept

    // Not stuck: the next single finger draws again.
    final f = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 13,
    );
    await f.down(c + const Offset(0, 40));
    await f.moveTo(c + const Offset(60, 40));
    await f.up();
    await tester.pump();
    expect(strokes(), 1);

    // An interrupted gesture (cancelled by the system) does not stick.
    final g = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 14,
    );
    await g.down(c + const Offset(0, 80));
    await g.moveTo(c + const Offset(30, 80));
    await g.cancel();
    await tester.pump();
    expect(strokes(), 1);
    final h = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 15,
    );
    await h.down(c + const Offset(0, 120));
    await h.moveTo(c + const Offset(60, 120));
    await h.up();
    await tester.pump();
    expect(strokes(), 2);

    // The Pencil draws while a palm rests: one stroke, no movement.
    final still = view(tester);
    final palm = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 16,
    );
    final pen = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
      pointer: 17,
    );
    await pen.down(c + const Offset(0, -60));
    await palm.down(c + const Offset(100, 100));
    await tester.pump();
    final palm2 = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 18,
    );
    await palm2.down(c + const Offset(140, 120));
    for (var i = 1; i <= 4; i++) {
      await pen.moveTo(c + Offset(20.0 * i, -60));
      await palm.moveTo(c + Offset(100 + 5.0 * i, 100));
      await palm2.moveTo(c + Offset(140 + 5.0 * i, 120));
      await tester.pump();
    }
    await pen.up();
    await palm.up();
    await palm2.up();
    await tester.pump();
    expect(strokes(), 3);
    expect(view(tester), still);

    // Undo and redo still work on these strokes.
    ink().undo();
    expect(strokes(), 2);
    ink().redo();
    expect(strokes(), 3);
    await shutDown(tester);
  });

  testWidgets('Draw mode off: one finger pans as before', (tester) async {
    await boot(tester);
    final c = grid(tester).center;
    final before = view(tester).getTranslation();
    final f = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 21,
    );
    await f.down(c);
    for (var i = 1; i <= 5; i++) {
      await f.moveTo(c + Offset(0, 20.0 * i));
      await tester.pump();
    }
    await f.up();
    await tester.pump();
    expect(view(tester).getTranslation().y, greaterThan(before.y));
    expect(strokes(), 0);
    await shutDown(tester);
  });
}
