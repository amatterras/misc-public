// Eraser modes: precision, the highlighter-only filter, no specks, the same
// reach at any zoom, exact undo/redo, and save/reload of the cut strokes.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

List<StrokePoint> line(Offset from, Offset to, int n) => [
  for (var i = 0; i <= n; i++)
    StrokePoint(
      from.dx + (to.dx - from.dx) * i / n,
      from.dy + (to.dy - from.dy) * i / n,
      0.5,
    ),
];

CanvasController make(List<CanvasItem> items) => CanvasController(
  document: CanvasDocument(
    id: 'c',
    title: 'Ink',
    items: items,
    updatedAt: DateTime(2026),
    viewport: const CanvasViewport(),
    schema: 3,
  ),
  onSave: (_) async {},
);

StrokeItem pen(String id, List<StrokePoint> pts) => StrokeItem(
  id: id,
  points: pts,
  color: const Color(0xFF3366FF),
  strokeWidth: 2,
);

StrokeItem marker(String id, List<StrokePoint> pts) => StrokeItem(
  id: id,
  points: pts,
  color: const Color(0xFFF2D84A).withValues(alpha: 0.38),
  strokeWidth: 18,
);

/// One eraser dab at world point [at] (any zoom).
void dab(CanvasController c, Offset at) {
  c.tool = CanvasTool.eraser;
  final s = c.toScreen(at);
  c.pointerDown(s);
  c.pointerUp();
}

List<StrokeItem> strokes(CanvasController c) =>
    c.items.whereType<StrokeItem>().toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('precision erases a much narrower gap than partial', () {
    double gap(EraserMode mode) {
      final c = make([pen('a', line(Offset.zero, const Offset(400, 0), 80))]);
      c.setView(Offset.zero, 1);
      c.setEraser(mode: mode, size: 40);
      dab(c, const Offset(200, 0));
      final s = strokes(c);
      expect(s, hasLength(2));
      return s[1].points.first.x - s[0].points.last.x;
    }

    final partial = gap(EraserMode.partial);
    final precision = gap(EraserMode.precision);
    expect(precision, lessThan(partial / 2));
    expect(precision, greaterThan(0));
  });

  test('highlighter-only leaves pen strokes alone, in every mode', () {
    for (final mode in EraserMode.values) {
      final pts = line(Offset.zero, const Offset(200, 0), 20);
      final c = make([pen('p', pts), marker('m', pts)]);
      c.setView(Offset.zero, 1);
      c.setEraser(mode: mode, size: 40, highlighterOnly: true);
      dab(c, const Offset(100, 0));
      expect(c.itemById('p'), isNotNull, reason: '$mode');
      expect(strokes(c).where((s) => s.id == 'p'), hasLength(1));
      expect(strokes(c).where((s) => s.points.length == 21), hasLength(1));
      final markers = strokes(c).where((s) => s.strokeWidth == 18);
      if (mode == EraserMode.stroke) {
        expect(markers, isEmpty, reason: 'whole highlighter stroke erased');
      } else {
        expect(markers.length, 2, reason: 'highlighter was cut in two');
      }
    }
  });

  test('same reach on screen at every zoom', () {
    for (final zoom in [0.1, 1.0, 10.0]) {
      final c = make([pen('a', line(Offset.zero, const Offset(4000, 0), 400))]);
      c.setView(Offset.zero, zoom);
      c.setEraser(mode: EraserMode.partial, size: 20);
      dab(c, const Offset(2000, 0));
      final s = strokes(c);
      expect(s, hasLength(2), reason: 'zoom $zoom');
      final gapScreen = (s[1].points.first.x - s[0].points.last.x) * zoom;
      // The eraser's diameter plus the line's own drawn width, in pixels.
      expect(gapScreen, closeTo(20 + 2 * zoom, 1.5), reason: 'zoom $zoom');
    }
  });

  test('no specks are left; a miss touches nothing', () {
    final c = make([pen('a', line(Offset.zero, const Offset(100, 0), 50))]);
    c.setView(Offset.zero, 1);
    c.setEraser(mode: EraserMode.partial, size: 40);
    dab(c, const Offset(10, 0)); // leaves ~0 of the start
    expect(strokes(c), hasLength(1));
    expect(strokes(c).single.points.first.x, greaterThan(20));
    dab(c, const Offset(60, 80)); // far away
    expect(strokes(c), hasLength(1));
  });

  test('neighbouring strokes and non-ink objects are untouched', () {
    final text = TextItem(
      id: 't',
      position: const Offset(80, -20),
      width: 100,
      minHeight: 40,
      text: 'keep',
    );
    final c = make([
      pen('a', line(Offset.zero, const Offset(200, 0), 20)),
      pen('b', line(const Offset(0, 40), const Offset(200, 40), 20)),
      text,
    ]);
    c.setView(Offset.zero, 1);
    c.setEraser(mode: EraserMode.partial, size: 20);
    dab(c, const Offset(100, 0));
    expect(c.itemById('t'), same(text));
    expect(c.itemById('b'), isA<StrokeItem>());
    expect((c.itemById('b') as StrokeItem).points, hasLength(21));
  });

  test('undo restores the exact stroke; redo and reload agree', () {
    final original = StrokeItem(
      id: 'a',
      points: [
        for (var i = 0; i <= 20; i++) StrokePoint(i * 10.0, 0, 0.3 + i / 100),
      ],
      color: const Color(0xFF3366FF).withValues(alpha: 0.5),
      strokeWidth: 3.5,
      pressureWidth: true,
    );
    final c = make([original]);
    c.setView(Offset.zero, 1);
    c.setEraser(mode: EraserMode.partial, size: 30);
    c.tool = CanvasTool.eraser;
    c.pointerDown(const Offset(100, 0));
    c.pointerMove(const Offset(110, 0));
    c.pointerUp();
    expect(strokes(c).length, greaterThan(1));
    String itemsJson() => jsonEncode(c.document.toJson()['items']);
    final after = itemsJson();
    final back = CanvasDocument.fromJson(
      jsonDecode(jsonEncode(c.document.toJson())) as Map<String, dynamic>,
    );
    expect(back.items.whereType<StrokeItem>().length, strokes(c).length);
    for (final s in strokes(c)) {
      expect(s.color, original.color);
      expect(s.strokeWidth, 3.5);
      expect(s.pressureWidth, isTrue);
    }
    c.undo();
    expect(strokes(c), hasLength(1));
    expect(strokes(c).single, same(original));
    c.redo();
    expect(itemsJson(), after);
  });
}
