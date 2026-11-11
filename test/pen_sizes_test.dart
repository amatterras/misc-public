// Pen sizes: the original four kept, two thinner and two thicker added,
// all distinct and in order; saved values are made safe and older ones
// load as they were; the toolbar offers every size and new strokes use
// it (old strokes keep theirs); the canvas size is remembered after a
// restart; the Calendar pen offers the same sizes.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_ink.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_toolbar.dart';
import 'package:flutter_application_1/features/ink/pen_sizes.dart';
import 'package:flutter_application_1/features/ink/stroke_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

CanvasController make() => CanvasController(
  document: CanvasDocument(
    id: 'c',
    title: 'Ink',
    items: const [],
    updatedAt: DateTime(2026),
    viewport: const CanvasViewport(),
    schema: 3,
  ),
  onSave: (_) async {},
);

void draw(CanvasController c, double y) {
  c.setView(Offset.zero, 1);
  c.tool = CanvasTool.pen;
  c.pointerDown(Offset(10, y));
  c.pointerMove(Offset(60, y));
  c.pointerMove(Offset(110, y));
  c.pointerUp();
}

void main() {
  test('the original four kept; two thinner and two thicker, all distinct', () {
    expect(penSizes, containsAllInOrder([1.5, 2.5, 5.0, 9.0]));
    expect(penSizes.where((w) => w < 1.5), hasLength(4)); // 2 + 2 thinner
    expect(penSizes.where((w) => w > 9.0), hasLength(3)); // 2 + 1 thicker
    expect(penSizes.first, 0.45);
    expect(penSizes.where((w) => w < 0.8), hasLength(2));
    expect(penSizes.last, 30.0);
    expect(penSizes.toSet(), hasLength(penSizes.length));
    expect([...penSizes]..sort(), penSizes);
    expect(penSizes.first, greaterThan(0.4)); // still visible
  });

  test('saved values: older ones load as they were, odd ones are safe', () {
    expect(savedPenWidth(null), defaultPenSize);
    expect(savedPenWidth('thick'), defaultPenSize);
    expect(savedPenWidth(double.nan), defaultPenSize);
    expect(savedPenWidth(-3), defaultPenSize);
    expect(savedPenWidth(5), 5.0); // an int from older settings
    expect(savedPenWidth(9.0), 9.0);
    expect(savedPenWidth(0.3), penSizes.first);
    expect(savedPenWidth(30), 30.0);
    expect(savedPenWidth(14), 14.0);
    expect(savedPenWidth(500), penSizes.last);
  });

  test('every size draws a visibly different line', () async {
    // Each size rendered and its ink pixels counted: strictly more ink
    // for every larger size.
    Future<int> inkPixels(double w) async {
      final recorder = ui.PictureRecorder();
      paintStroke(
        Canvas(recorder),
        StrokeItem(
          id: 's',
          points: const [StrokePoint(20, 30), StrokePoint(120, 30)],
          color: const Color(0xFF000000),
          strokeWidth: w,
        ),
      );
      final image = await recorder.endRecording().toImage(140, 60);
      final data = (await image.toByteData())!;
      image.dispose();
      var n = 0; // total ink: the sum of alpha (coverage), not a count
      for (var i = 3; i < data.lengthInBytes; i += 4) {
        n += data.getUint8(i);
      }
      return n;
    }

    final counts = [for (final w in penSizes) await inkPixels(w)];
    for (var i = 1; i < counts.length; i++) {
      expect(counts[i], greaterThan(counts[i - 1]), reason: '$counts');
    }
    expect(counts.first, greaterThan(100 * 255 * 0.4)); // thinnest visible
    final c = make();
    for (var i = 0; i < penSizes.length; i++) {
      c.setPen(width: penSizes[i]);
      draw(c, 20.0 * i);
    }
    expect([
      for (final s in c.items.whereType<StrokeItem>()) s.strokeWidth,
    ], penSizes);
  });

  testWidgets('the toolbar offers every size; new strokes use it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = make()..tool = CanvasTool.pen;
    final chosen = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (_, _) => CanvasContextBar(
              controller: c,
              onActivate: (_) {},
              onRefreshLink: (_) {},
              onPenWidth: (ctrl, w) {
                chosen.add(w);
                ctrl.setPen(width: w);
              },
            ),
          ),
        ),
      ),
    );
    // The pen's panel starts folded; the chosen pen opens it.
    c.setOptionsExpanded(true);
    await tester.pumpAndSettle();
    for (final w in penSizes) {
      expect(find.byKey(ValueKey('pen-size-$w')), findsOneWidget);
    }
    draw(c, 0); // at the default size
    await tester.tap(find.byKey(const ValueKey('pen-size-20.0')));
    await tester.pump();
    expect(c.penWidth, 20.0);
    draw(c, 50);
    await tester.tap(find.byKey(const ValueKey('pen-size-0.8')));
    await tester.pump();
    draw(c, 100);
    expect(chosen, [20.0, 0.8]);
    expect(
      [for (final s in c.items.whereType<StrokeItem>()) s.strokeWidth],
      [defaultPenSize, 20.0, 0.8], // earlier strokes are never rewritten
    );
    await tester.pump(const Duration(seconds: 1)); // the autosave timer
    c.dispose();
  });

  group('remembered', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('theapp_pens_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<AppState> app() async {
      final ws = Workspace(dir);
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      s.capture.fetchPreviews = false;
      await s.init();
      return s;
    }

    test('the canvas pen size survives a restart; old values load', () async {
      var s = await app();
      expect(s.canvas!.penWidth, defaultPenSize);
      await s.setCanvasPenWidth(s.canvas!, 14);
      expect(s.canvas!.penWidth, 14);
      await s.flush();
      s.dispose();

      s = await app();
      expect(s.canvas!.penWidth, 14);
      await s.settings.set('penWidth', 5); // as an older version saved it
      expect(s.canvasPenWidth, 5.0);
      await s.settings.set('penWidth', 'huge');
      expect(s.canvasPenWidth, defaultPenSize);
      await s.flush();
      s.dispose();
    });

    testWidgets('the Calendar pen offers the same sizes', (tester) async {
      late AppState s;
      late CanvasController ink;
      await tester.runAsync(() async {
        s = await app();
        ink = await s.openCalendarInk();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPenWidthDialog(context, s, ink),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      for (final w in penSizes) {
        expect(find.byKey(ValueKey('calendar-pen-size-$w')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('calendar-pen-size-1.1')));
      await tester.pump();
      expect(ink.penWidth, 1.1);
      await waitForBothClocks(tester, s.flush, what: 'Saving');
      expect(s.calendarPenWidth, 1.1);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      s.dispose();
    });
  });
}
