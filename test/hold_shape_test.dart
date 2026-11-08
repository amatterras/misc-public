// Hold-to-perfect-shape: a rough circle/ellipse or rectangle becomes a
// clean one when the pen is held still at the end of the drawing for the hold time
// (CanvasController.holdToStraighten, 1.2 s).
// Open curves, handwriting, scribbles and triangles stay as drawn; one
// shape only; undo/redo and save/reload keep it.
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

/// Pen down, along [points], and then it stays down (held).
void drawAndHold(
  CanvasController c,
  List<Offset> points, {
  PointerDeviceKind kind = PointerDeviceKind.stylus,
}) {
  c.setView(Offset.zero, 1);
  c.tool = CanvasTool.pen;
  c.pointerDown(points.first, kind: kind);
  for (var i = 1; i < points.length; i++) {
    c.pointerMove(points[i], timeStamp: Duration(milliseconds: i * 8));
  }
}

/// A hand-drawn ellipse: a little wobbly, overshooting its start a bit.
List<Offset> roughEllipse(Offset center, double rx, double ry, double turn) {
  const n = 60;
  final c = math.cos(turn), s = math.sin(turn);
  return [
    for (var i = 0; i <= n; i++)
      () {
        final a = i / n * 2 * math.pi * 1.015;
        final wobble = 1 + 0.04 * math.sin(i * 0.9) + 0.02 * math.cos(i * 2.3);
        final x = rx * wobble * math.cos(a), y = ry * wobble * math.sin(a);
        return center + Offset(x * c - y * s, x * s + y * c);
      }(),
  ];
}

/// A hand-drawn rectangle with wobbly edges and a corner that overshoots.
List<Offset> roughRect(Offset center, double w, double h, double turn) {
  final c = math.cos(turn), s = math.sin(turn);
  Offset at(double x, double y) =>
      center + Offset(x * c - y * s, x * s + y * c);
  final corners = [
    Offset(-w / 2, -h / 2),
    Offset(w / 2, -h / 2),
    Offset(w / 2, h / 2),
    Offset(-w / 2, h / 2),
    Offset(-w / 2, -h / 2 + 4), // ends a bit past the start
  ];
  final out = <Offset>[];
  for (var k = 0; k < 4; k++) {
    final a = corners[k], b = corners[k + 1];
    final steps = ((b - a).distance / 8).round();
    for (var i = 0; i < steps; i++) {
      final p = Offset.lerp(a, b, i / steps)!;
      final n = Offset(-(b - a).dy, (b - a).dx) / (b - a).distance;
      out.add(at(p.dx, p.dy) + n * (2.0 * math.sin(i * 1.3 + k)));
    }
  }
  out.add(at(corners.last.dx, corners.last.dy));
  return out;
}

StrokeItem only(CanvasController c) => c.items.whereType<StrokeItem>().single;

void main() {
  for (final kind in [PointerDeviceKind.stylus, PointerDeviceKind.mouse]) {
    for (final turn in [0.0, 0.5, 1.2]) {
      testWidgets('a rough ellipse held still becomes a clean one '
          '($kind, turned $turn)', (tester) async {
        final c = make();
        c.setPen(color: const Color(0xFFFF6A00), width: 5);
        final rough = roughEllipse(const Offset(300, 300), 120, 70, turn);
        drawAndHold(c, rough, kind: kind);
        // Just before the hold time (CanvasController.holdToStraighten).
        await tester.pump(
          CanvasController.holdToStraighten - const Duration(milliseconds: 100),
        );
        expect(
          c.lineStraightenPreview,
          isNull,
          reason: 'not before the hold time',
        );
        await tester.pump(const Duration(milliseconds: 200));
        final preview = c.lineStraightenPreview;
        expect(preview, isNotNull);
        c.pointerUp();
        await tester.pump(const Duration(seconds: 3));

        final s = only(c);
        expect(c.items, hasLength(1), reason: 'one shape, no duplicates');
        expect(s.color, const Color(0xFFFF6A00));
        expect(s.strokeWidth, 5);
        // Closed and smooth: every point on one ellipse.
        final pts = [for (final p in s.points) p.offset];
        expect((pts.first - pts.last).distance, lessThan(1e-6));
        final cx = pts.map((p) => p.dx).reduce((a, b) => a + b) / pts.length;
        final cy = pts.map((p) => p.dy).reduce((a, b) => a + b) / pts.length;
        final center = Offset(cx, cy);
        expect((center - const Offset(300, 300)).distance, lessThan(12));
        final radii = [for (final p in pts) (p - center).distance];
        expect(radii.reduce(math.max), lessThan(135));
        expect(radii.reduce(math.min), greaterThan(55));
        // Size and place of what was drawn are kept (within 12%).
        final drawn = Rect.fromPoints(
          Offset(
            rough.map((p) => p.dx).reduce(math.min),
            rough.map((p) => p.dy).reduce(math.min),
          ),
          Offset(
            rough.map((p) => p.dx).reduce(math.max),
            rough.map((p) => p.dy).reduce(math.max),
          ),
        );
        expect(s.bounds.width, closeTo(drawn.width, drawn.width * 0.12));
        expect(s.bounds.height, closeTo(drawn.height, drawn.height * 0.12));
        c.dispose();
      });
    }
  }

  for (final turn in [0.0, 0.4, 1.0]) {
    testWidgets('a rough rectangle held still becomes a clean one '
        '(turned $turn)', (tester) async {
      final c = make();
      c.setPen(width: 3);
      final rough = roughRect(const Offset(300, 300), 220, 120, turn);
      drawAndHold(c, rough);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(c.lineStraightenPreview, isNotNull);
      c.pointerUp();
      await tester.pump(const Duration(seconds: 3));
      expect(c.items, hasLength(1));
      final pts = [for (final p in only(c).points) p.offset];
      expect((pts.first - pts.last).distance, lessThan(1e-6));
      // Four straight edges, each corner a right angle.
      final corners = <Offset>[pts.first];
      for (var i = 1; i < pts.length - 1; i++) {
        final a = pts[i] - pts[i - 1], b = pts[i + 1] - pts[i];
        final cross = a.dx * b.dy - a.dy * b.dx;
        if (cross.abs() > 1e-6 * a.distance * b.distance) corners.add(pts[i]);
      }
      expect(corners, hasLength(4));
      for (var i = 0; i < 4; i++) {
        final a = corners[(i + 1) % 4] - corners[i];
        final b = corners[(i + 3) % 4] - corners[i];
        final cos = (a.dx * b.dx + a.dy * b.dy) / (a.distance * b.distance);
        expect(cos.abs(), lessThan(1e-6), reason: 'corner $i is square');
      }
      final w = (corners[1] - corners[0]).distance;
      final h = (corners[3] - corners[0]).distance;
      final sides = [w, h]..sort();
      expect(sides[1], closeTo(220, 220 * 0.1));
      expect(sides[0], closeTo(120, 120 * 0.15));
      c.dispose();
    });
  }

  testWidgets('open curves, handwriting, scribbles and triangles stay', (
    tester,
  ) async {
    final shapes = <String, List<Offset>>{
      'half circle': [
        for (var i = 0; i <= 30; i++)
          Offset(
            300 + 100 * math.cos(i / 30 * math.pi),
            300 + 100 * math.sin(i / 30 * math.pi),
          ),
      ],
      'wave': [
        for (var i = 0; i <= 60; i++)
          Offset(100 + i * 5.0, 300 + 14 * math.sin(i / 3)),
      ],
      'scribble': [
        for (var i = 0; i <= 30; i++)
          Offset(
            200 + (i.isEven ? 0 : 90),
            200 + i * 4.0 + 7 * math.sin(i * 2.1),
          ),
      ],
      'triangle': [
        for (var i = 0; i <= 12; i++)
          Offset.lerp(const Offset(200, 400), const Offset(300, 250), i / 12)!,
        for (var i = 1; i <= 12; i++)
          Offset.lerp(const Offset(300, 250), const Offset(400, 400), i / 12)!,
        for (var i = 1; i <= 12; i++)
          Offset.lerp(const Offset(400, 400), const Offset(200, 402), i / 12)!,
      ],
    };
    for (final e in shapes.entries) {
      final c = make();
      drawAndHold(c, e.value);
      await tester.pump(const Duration(seconds: 3));
      expect(c.lineStraightenPreview, isNull, reason: e.key);
      c.pointerUp();
      await tester.pump(const Duration(seconds: 3));
      final s = only(c);
      expect(s.points.length, e.value.length, reason: e.key);
      c.dispose();
    }
  });

  testWidgets('moving on after the preview cancels it; highlighter never', (
    tester,
  ) async {
    var c = make();
    final rough = roughEllipse(const Offset(300, 300), 100, 100, 0);
    drawAndHold(c, rough);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(c.lineStraightenPreview, isNotNull);
    // A tiny jitter keeps it ...
    c.pointerMove(rough.last + const Offset(1, 1));
    expect(c.lineStraightenPreview, isNotNull);
    // ... real movement means the drawing goes on: back to the raw line.
    c.pointerMove(rough.last + const Offset(40, 30));
    expect(c.lineStraightenPreview, isNull);
    c.pointerUp();
    expect(only(c).points.length, greaterThan(40));
    c.dispose();

    c = make();
    drawAndHold(c, rough);
    c.tool = CanvasTool.highlighter;
    await tester.pump(const Duration(seconds: 3));
    expect(c.lineStraightenPreview, isNull);
    c.dispose();
  });

  testWidgets('undo, redo and save/reload keep the one clean shape', (
    tester,
  ) async {
    final c = make();
    drawAndHold(c, roughEllipse(const Offset(300, 300), 90, 90, 0));
    await tester.pump(const Duration(milliseconds: 1600));
    c.pointerUp();
    final shape = only(c);
    final back = CanvasDocument.fromJson(
      jsonDecode(jsonEncode(c.document.toJson())) as Map<String, dynamic>,
    );
    expect(
      (back.items.single as StrokeItem).points.map((p) => p.offset),
      shape.points.map((p) => p.offset),
    );
    c.undo();
    expect(c.items, isEmpty);
    c.redo();
    expect(only(c).points.length, shape.points.length);
    expect(c.items, hasLength(1));
    // It is an ordinary object: selectable and movable.
    c.select([shape.id]);
    expect(c.selectedItems.single, isA<StrokeItem>());
    c.dispose();
  });
}
