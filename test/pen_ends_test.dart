// Pen stroke ends: the round end bulges outward, ahead of the tip and
// behind the start, along the line's own direction, in every direction,
// at every width, with and without pressure; set-down/lift-off wobble
// does not twist it into a hook; dots and short strokes stay round; a
// saved and reloaded stroke draws the same outline. (The outline is
// sampled with Path.contains, so these test the drawn geometry itself.)
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/ink/stroke_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

List<StrokePoint> line(Offset from, Offset to, int n, {double p = 0.5}) => [
  for (var i = 0; i <= n; i++)
    StrokePoint(
      from.dx + (to.dx - from.dx) * i / n,
      from.dy + (to.dy - from.dy) * i / n,
      p,
    ),
];

void main() {
  const widths = [0.75, 1.5, 2.5, 5.0, 9.0, 14.0, 20.0];
  final directions = [
    for (var k = 0; k < 8; k++) k * math.pi / 4, // →, ↘, ↓, ↙, ←, ↖, ↑, ↗
  ];

  test('pressure strokes end in an outward round cap in every direction', () {
    for (final w in widths) {
      for (final a in directions) {
        final dir = Offset(math.cos(a), math.sin(a));
        final start = const Offset(200, 200);
        final end = start + dir * 120;
        final path = pressureOutline(line(start, end, 12), w);
        final r = w * pressureFactor(0.5) / 2;
        final why = 'width $w, angle ${(a * 180 / math.pi).round()}°';
        // Inside the cap, just beyond the tip and before the start.
        expect(
          path.contains(end + dir * (r * 0.7)),
          isTrue,
          reason: 'end $why',
        );
        expect(
          path.contains(start - dir * (r * 0.7)),
          isTrue,
          reason: 'start $why',
        );
        // The tip itself and the line's centre near it are ink.
        expect(path.contains(end - dir * (r * 0.3)), isTrue, reason: why);
        // Nothing sticks out further than the round end.
        expect(
          path.contains(end + dir * (r * 1.4 + 0.5)),
          isFalse,
          reason: why,
        );
        expect(
          path.contains(start - dir * (r * 1.4 + 0.5)),
          isFalse,
          reason: why,
        );
        // The cap is round, not square: its corners are empty.
        final side = Offset(-dir.dy, dir.dx);
        expect(
          path.contains(end + dir * (r * 0.9) + side * (r * 0.9)),
          isFalse,
          reason: 'corner $why',
        );
      }
    }
  });

  test('curves both ways end along their own direction', () {
    for (final clockwise in [true, false]) {
      for (final w in [2.5, 9.0]) {
        // A half circle; at its end the line runs straight down or up.
        final pts = [
          for (var i = 0; i <= 30; i++)
            () {
              final t = math.pi * i / 30 * (clockwise ? 1 : -1);
              return StrokePoint(
                300 + 80 * math.cos(t),
                300 + 80 * math.sin(t),
                0.5,
              );
            }(),
        ];
        final path = pressureOutline(pts, w);
        final r = w * pressureFactor(0.5) / 2;
        final last = pts.last.offset, before = pts[pts.length - 2].offset;
        final dir = (last - before) / (last - before).distance;
        expect(path.contains(last + dir * (r * 0.6)), isTrue);
        final first = pts.first.offset, second = pts[1].offset;
        final back = (first - second) / (first - second).distance;
        expect(path.contains(first + back * (r * 0.6)), isTrue);
      }
    }
  });

  test('lift-off wobble does not become a hook', () {
    const w = 9.0;
    final r = w * pressureFactor(0.5) / 2;
    final pts = [
      ...line(const Offset(0, 0), const Offset(100, 0), 10),
      // The pen lifts: one tiny sample back and down.
      const StrokePoint(99, 2, 0.5),
    ];
    final path = pressureOutline(pts, w);
    // The end still points right (the way the line was drawn) ...
    expect(path.contains(Offset(100 + r * 0.7, 0)), isTrue);
    // ... and no spike reaches down past the line's width.
    expect(path.contains(Offset(99, r + 1.5)), isFalse);
    // Only the drawn copy is trimmed: the stroke itself is unchanged.
    expect(pts, hasLength(12));

    // The same for the plain (mouse/finger) line.
    final plain = centreLine(pts, null, w);
    final m = plain.computeMetrics().single;
    final tip = m.getTangentForOffset(m.length)!;
    expect(tip.position, const Offset(100, 0));
    expect(tip.vector.dx, greaterThan(0.99));
  });

  test('set-down wobble is trimmed too; real short strokes are not', () {
    const w = 9.0;
    final pts = [
      const StrokePoint(1, -2, 0.5), // set-down jitter, pointing back
      ...line(const Offset(0, 0), const Offset(60, 0), 6),
    ];
    final r = w * pressureFactor(0.5) / 2;
    final path = pressureOutline(pts, w);
    expect(path.contains(Offset(-r * 0.7, 0)), isTrue);
    // A short deliberate tick (two points, 4 units) keeps both points.
    final tick = [const StrokePoint(0, 0), const StrokePoint(4, 0)];
    final t = pressureOutline(tick, 2.5);
    expect(t.getBounds().width, greaterThan(4));
  });

  test('a dot is a round dot; very short strokes stay round', () {
    final dot = pressureOutline([const StrokePoint(10, 10, 0.5)], 6);
    final b = dot.getBounds();
    expect(b.width, closeTo(b.height, 0.01));
    expect(dot.contains(const Offset(10, 10)), isTrue);
    final short = pressureOutline([
      const StrokePoint(10, 10, 0.5),
      const StrokePoint(10.4, 10, 0.5),
    ], 6);
    expect(short.contains(const Offset(10.2, 10)), isTrue);
    expect(short.contains(const Offset(7.6, 10)), isTrue); // round behind
  });

  test('a stroke saved and loaded again draws exactly the same', () {
    for (final pressure in [true, false]) {
      final s = StrokeItem(
        id: 's',
        points: [
          for (var i = 0; i <= 20; i++)
            StrokePoint(i * 7.0, 30 * math.sin(i / 3), 0.2 + i / 40),
        ],
        color: const Color(0xFF223344),
        strokeWidth: 5,
        pressureWidth: pressure,
      );
      final again = CanvasItem.fromJson(s.toJson()) as StrokeItem;
      expect(strokePath(again).getBounds(), strokePath(s).getBounds());
      for (var x = -10.0; x < 150; x += 3.7) {
        for (var y = -40.0; y < 40; y += 3.1) {
          expect(
            strokePath(again).contains(Offset(x, y)),
            strokePath(s).contains(Offset(x, y)),
          );
        }
      }
    }
  });
}
