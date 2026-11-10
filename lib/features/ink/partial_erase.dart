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
///
/// [halfWidth]: half the drawn width of the line at a point, added to the
/// eraser's reach there, so the eraser cuts where it touches the ink as
/// drawn (a pressure line is wider where the pen pressed). [maxHalfWidth]
/// is its largest value (for the quick far-away test). Without them the
/// centre line alone is tested against [radius].
List<List<StrokePoint>>? erasePolyline(
  List<StrokePoint> points,
  Offset a,
  Offset b,
  double radius, {
  double Function(StrokePoint p)? halfWidth,
  double maxHalfWidth = 0,
}) {
  if (points.isEmpty) return null;
  bool inside(StrokePoint p) =>
      distanceToSegment(p.offset, a, b) <=
      radius + (halfWidth == null ? 0 : halfWidth(p));
  if (points.length == 1) return inside(points.first) ? const [] : null;

  final capsule = Rect.fromPoints(a, b).inflate(radius + maxHalfWidth);
  final pieces = <List<StrokePoint>>[];
  var current = <StrokePoint>[];
  var touched = false;
  if (!inside(points.first)) {
    current.add(points.first);
  } else {
    touched = true;
  }

  for (var i = 0; i < points.length - 1; i++) {
    final p = points[i], q = points[i + 1];
    // Strictly apart only: a point exactly on the eraser's edge counts
    // as inside below, so a piece that merely touches the box must be
    // looked at (Rect.overlaps calls touching boxes apart, and the piece
    // kept so far was then dropped when the line left the eraser).
    if (math.max(p.x, q.x) < capsule.left ||
        math.min(p.x, q.x) > capsule.right ||
        math.max(p.y, q.y) < capsule.top ||
        math.min(p.y, q.y) > capsule.bottom) {
      // Far from the eraser: both ends are outside, nothing changes.
      current.add(q);
      continue;
    }
    // Sample often enough that the capsule cannot slip between samples
    // (except by grazing its very edge).
    final length = (q.offset - p.offset).distance;
    final n = math.max(1, (length / (radius / 2)).ceil()).clamp(1, 4000);
    var prevT = 0.0;
    var prevIn = inside(p);
    for (var k = 1; k <= n; k++) {
      final t = k / n;
      final curIn = inside(_at(p, q, t));
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

/// The point at [t] along p→q, with the pen's pressure, angle and time
/// there.
StrokePoint _at(StrokePoint p, StrokePoint q, double t) =>
    StrokePoint.lerp(p, q, t);

/// Where between [t0] (inside: [startsIn]) and [t1] the line crosses the
/// capsule's edge, to well under a hundredth of a unit.
double _edge(
  StrokePoint p,
  StrokePoint q,
  double t0,
  double t1,
  bool startsIn,
  bool Function(StrokePoint) inside,
) {
  var lo = t0, hi = t1;
  for (var i = 0; i < 30; i++) {
    final mid = (lo + hi) / 2;
    if (inside(_at(p, q, mid)) == startsIn) {
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
