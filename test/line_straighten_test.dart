// Automatic line straightening: 1.5 seconds after a stroke is finished, a
// freehand stroke that is close to a straight line becomes one (any angle,
// any length, shaky hands), keeping its look; curves, handwriting, shapes,
// highlighter strokes and anything changed meanwhile stay as they are.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// Draws [points] (screen == world at scale 1) and lifts the pen.
void stroke(
  CanvasController c,
  List<Offset> points, {
  PointerDeviceKind kind = PointerDeviceKind.stylus,
}) {
  c.setView(Offset.zero, 1);
  c.pointerDown(points.first, kind: kind);
  for (var i = 1; i < points.length; i++) {
    c.pointerMove(points[i], timeStamp: Duration(milliseconds: i * 8));
  }
  c.pointerUp();
}

/// A hand-drawn line from [a] to [b]: sampled every ~6 px, shaking by up to
/// [shake] pixels sideways.
List<Offset> shakyLine(Offset a, Offset b, {double shake = 2}) {
  final length = (b - a).distance;
  final n = math.max(4, (length / 6).round());
  final normal = Offset(-(b - a).dy, (b - a).dx) / length;
  return [
    for (var i = 0; i <= n; i++)
      Offset.lerp(a, b, i / n)! +
          (i == 0 || i == n
              ? Offset.zero
              : normal * (shake * math.sin(i * 1.7))),
  ];
}

void main() {
  const lengths = [60.0, 200.0, 800.0];
  const angles = [0.0, 17.0, 45.0, 90.0, 133.0, 200.0, 315.0];

  for (final kind in [
    PointerDeviceKind.stylus,
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
  ]) {
    testWidgets('lines at many angles and lengths straighten ($kind)', (
      tester,
    ) async {
      for (final length in lengths) {
        for (final deg in angles) {
          final c = make();
          c.tool = CanvasTool.pen;
          c.setPen(color: const Color(0xFFFF6A00), width: 5);
          final a = const Offset(100, 100);
          final r = deg * math.pi / 180;
          final b = a + Offset(math.cos(r), math.sin(r)) * length;
          stroke(c, shakyLine(a, b), kind: kind);
          final original = c.items.single as StrokeItem;
          await tester.pump(const Duration(milliseconds: 1400));
          expect(
            identical(c.items.single, original),
            isTrue,
            reason: 'not before 1.5 s ($length @ $deg)',
          );
          await tester.pump(const Duration(milliseconds: 150));
          final s = c.items.single as StrokeItem;
          expect(s.id, original.id);
          // Endpoints where the user put them, every point on the chord.
          expect(s.points.first.offset, original.points.first.offset);
          expect(s.points.last.offset, original.points.last.offset);
          for (final p in s.points) {
            expect(
              distanceToSegment(
                p.offset,
                s.points.first.offset,
                s.points.last.offset,
              ),
              lessThan(1e-6),
              reason: '$length @ $deg',
            );
          }
          // The look is unchanged.
          expect(s.color, original.color);
          expect(s.strokeWidth, original.strokeWidth);
          expect(s.pressureWidth, original.pressureWidth);
          c.dispose();
        }
      }
    });
  }

  testWidgets('opacity is kept', (tester) async {
    final c = make();
    c.tool = CanvasTool.pen;
    c.setPen(color: const Color(0xFF2878F0).withValues(alpha: 0.5));
    stroke(c, shakyLine(const Offset(0, 0), const Offset(300, 40)));
    final before = (c.items.single as StrokeItem).color;
    await tester.pump(const Duration(milliseconds: 1600));
    expect((c.items.single as StrokeItem).color, before);
    expect((c.items.single as StrokeItem).points.length, greaterThan(2));
    c.dispose();
  });

  testWidgets('curves, handwriting, circles, boxes and zigzags stay', (
    tester,
  ) async {
    final c = make();
    c.tool = CanvasTool.pen;
    final shapes = <List<Offset>>[
      // a gentle arc
      [
        for (var i = 0; i <= 40; i++)
          Offset(i * 6.0, 40 * math.sin(i / 40 * math.pi)),
      ],
      // a wave (handwriting-like)
      [
        for (var i = 0; i <= 60; i++)
          Offset(i * 5.0, 14 * math.sin(i / 3)),
      ],
      // a circle
      [
        for (var i = 0; i <= 40; i++)
          Offset(
            60 * math.cos(i / 40 * 2 * math.pi),
            60 * math.sin(i / 40 * 2 * math.pi),
          ),
      ],
      // a rectangle outline
      [
        for (var i = 0; i <= 10; i++) Offset(i * 12.0, 0),
        for (var i = 1; i <= 8; i++) Offset(120, i * 10.0),
        for (var i = 1; i <= 10; i++) Offset(120 - i * 12.0, 80),
        for (var i = 1; i <= 8; i++) Offset(0, 80 - i * 10.0),
      ],
      // a zigzag
      [
        for (var i = 0; i <= 12; i++) Offset(i * 15.0, i.isEven ? 0 : 40),
      ],
      // a "back and forth" scribble on one line
      [
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(20, 1),
        const Offset(110, 0),
      ],
    ];
    var y = 0.0;
    for (final shape in shapes) {
      stroke(c, [for (final p in shape) p + Offset(300, 100 + y)]);
      y += 200;
    }
    final before = c.items.toList();
    await tester.pump(const Duration(seconds: 4));
    expect(c.items.length, before.length);
    for (var i = 0; i < before.length; i++) {
      expect(identical(c.items[i], before[i]), isTrue, reason: 'shape $i');
    }
    c.dispose();
  });

  testWidgets('highlighter strokes are never straightened', (tester) async {
    final c = make();
    c.tool = CanvasTool.highlighter;
    stroke(c, shakyLine(const Offset(0, 0), const Offset(300, 20)));
    final original = c.items.single;
    await tester.pump(const Duration(seconds: 4));
    expect(identical(c.items.single, original), isTrue);
    c.dispose();
  });

  testWidgets('erasing, recoloring or starting a new stroke cancels it', (
    tester,
  ) async {
    // Erased before the timer: stays gone.
    var c = make();
    c.tool = CanvasTool.pen;
    stroke(c, shakyLine(const Offset(0, 0), const Offset(300, 10)));
    await tester.pump(const Duration(milliseconds: 1000));
    c.select([c.items.single.id]);
    c.deleteSelection();
    await tester.pump(const Duration(seconds: 2));
    expect(c.items, isEmpty);
    c.dispose();

    // Recolored before the timer: the user's change wins.
    c = make();
    c.tool = CanvasTool.pen;
    stroke(c, shakyLine(const Offset(0, 0), const Offset(300, 10)));
    final length = (c.items.single as StrokeItem).points.length;
    await tester.pump(const Duration(milliseconds: 1000));
    c.select([c.items.single.id]);
    c.recolorSelection(const Color(0xFFFF3B30));
    await tester.pump(const Duration(seconds: 2));
    final s = c.items.single as StrokeItem;
    expect(s.color, const Color(0xFFFF3B30));
    expect(s.points.length, length, reason: 'not straightened afterwards');
    c.dispose();

    // The pen goes down again: the earlier stroke is left alone.
    c = make();
    c.tool = CanvasTool.pen;
    stroke(c, shakyLine(const Offset(0, 0), const Offset(300, 10)));
    final first = c.items.single;
    await tester.pump(const Duration(milliseconds: 1000));
    c.pointerDown(const Offset(50, 300), kind: PointerDeviceKind.stylus);
    await tester.pump(const Duration(seconds: 2));
    c.pointerUp();
    expect(identical(c.items.first, first), isTrue);
    c.dispose();
  });

  testWidgets('undo/redo and save/reload keep the straight line', (
    tester,
  ) async {
    final c = make();
    c.tool = CanvasTool.pen;
    stroke(c, shakyLine(const Offset(10, 10), const Offset(400, 90)));
    final original = c.items.single;
    await tester.pump(const Duration(milliseconds: 1600));
    final straight = c.items.single as StrokeItem;
    expect(identical(straight, original), isFalse);
    final back = CanvasDocument.fromJson(
      jsonDecode(jsonEncode(c.document.toJson())) as Map<String, dynamic>,
    );
    final reloaded = back.items.single as StrokeItem;
    expect(
      reloaded.points.map((p) => p.offset),
      straight.points.map((p) => p.offset),
    );
    c.undo();
    expect(identical(c.items.single, original), isTrue);
    c.redo();
    expect(
      (c.items.single as StrokeItem).points.length,
      straight.points.length,
    );
    c.dispose();
  });
}
