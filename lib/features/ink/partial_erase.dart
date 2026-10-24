// The partial eraser's geometry: the eraser is a disc of radius r moved
// from a to b, so it sweeps a capsule (all points within r of the segment
// a→b). The part of a stroke's centre line inside the capsule is cut out;
// what is left becomes one or more strokes. Cuts are placed exactly on the
// capsule's edge (by bisection), and kept pieces keep their original
// points, so nothing outside the eraser moves.
import 'dart:math' as math;
import 'dart:ui';

import '../../data/models/canvas_models.dart';

/// The pieces of [points] left after erasing the capsule a→b of radius
/// [radius]; null when the capsule does not touch the line at all (so the
/// stroke is left as it is). An empty list means the whole stroke goes.
List<List<StrokePoint>>? erasePolyline(
  List<StrokePoint> points,
  Offset a,
  Offset b,
  double radius,
) {
  if (points.isEmpty) return null;
  bool inside(Offset p) => distanceToSegment(p, a, b) <= radius;
  if (points.length == 1) return inside(points.first.offset) ? const [] : null;

  final capsule = Rect.fromPoints(a, b).inflate(radius);
  final pieces = <List<StrokePoint>>[];
  var current = <StrokePoint>[];
  var touched = false;
  if (!inside(points.first.offset)) {
    current.add(points.first);
  } else {
    touched = true;
  }

  for (var i = 0; i < points.length - 1; i++) {
    final p = points[i], q = points[i + 1];
    final seg = Rect.fromPoints(p.offset, q.offset);
    if (!seg.overlaps(capsule)) {
      // Far from the eraser: both ends are outside, nothing changes.
      current.add(q);
      continue;
    }
    // Sample often enough that the capsule cannot slip between samples
    // (except by grazing its very edge).
    final length = (q.offset - p.offset).distance;
    final n = math.max(1, (length / (radius / 2)).ceil()).clamp(1, 4000);
    var prevT = 0.0;
    var prevIn = inside(p.offset);
    for (var k = 1; k <= n; k++) {
      final t = k / n;
      final curIn = inside(_at(p, q, t).offset);
      if (curIn != prevIn) {
        touched = true;
        final cut = _at(p, q, _edge(p, q, prevT, t, prevIn, inside));
        if (prevIn) {
          current = [cut]; // leaving the eraser: a new piece starts
        } else {
          current.add(cut); // entering: the piece ends at the edge
          pieces.add(current);
          current = [];
        }
      } else if (curIn) {
        touched = true;
      }
      prevT = t;
      prevIn = curIn;
    }
    if (!prevIn) current.add(q);
  }
  if (current.isNotEmpty) pieces.add(current);
  if (!touched) return null;
  return [
    for (final piece in pieces)
      if (piece.length >= 2 && _length(piece) > 0.25) piece,
  ];
}

/// The point at [t] along p→q, pressure included.
StrokePoint _at(StrokePoint p, StrokePoint q, double t) => StrokePoint(
  p.x + (q.x - p.x) * t,
  p.y + (q.y - p.y) * t,
  p.pressure + (q.pressure - p.pressure) * t,
);

/// Where between [t0] (inside: [startsIn]) and [t1] the line crosses the
/// capsule's edge, to well under a hundredth of a unit.
double _edge(
  StrokePoint p,
  StrokePoint q,
  double t0,
  double t1,
  bool startsIn,
  bool Function(Offset) inside,
) {
  var lo = t0, hi = t1;
  for (var i = 0; i < 30; i++) {
    final mid = (lo + hi) / 2;
    if (inside(_at(p, q, mid).offset) == startsIn) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  // The kept side of the edge, so a cut point is never inside the eraser.
  return startsIn ? hi : lo;
}

double _length(List<StrokePoint> piece) {
  var sum = 0.0;
  for (var i = 0; i < piece.length - 1; i++) {
    sum += (piece[i + 1].offset - piece[i].offset).distance;
  }
  return sum;
}
