// The shape of a mind-map connection: a smooth curve (Catmull-Rom turned
// into cubic Béziers) through its two ends and its waypoints. Shared by the
// painter, hit-testing and the editing handles, so what is drawn is exactly
// what is clicked.
import 'dart:ui';

/// Samples per span used for hit-testing and bounds.
const _samplesPerSpan = 16;

/// The cubic segments (start, control 1, control 2, end) of the smooth curve
/// through [pts]. Two points give a straight segment.
List<(Offset, Offset, Offset, Offset)> connectorCubics(List<Offset> pts) {
  final out = <(Offset, Offset, Offset, Offset)>[];
  for (var i = 0; i + 1 < pts.length; i++) {
    final p0 = i == 0 ? pts[i] : pts[i - 1];
    final p1 = pts[i], p2 = pts[i + 1];
    final p3 = i + 2 < pts.length ? pts[i + 2] : pts[i + 1];
    out.add((p1, p1 + (p2 - p0) / 6, p2 - (p3 - p1) / 6, p2));
  }
  return out;
}

/// The curve through [pts] as a [Path].
Path connectorPath(List<Offset> pts) {
  final path = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (final (_, c1, c2, end) in connectorCubics(pts)) {
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
  }
  return path;
}

Offset _cubicAt(Offset a, Offset b, Offset c, Offset d, double t) {
  final u = 1 - t;
  return a * (u * u * u) + b * (3 * u * u * t) + c * (3 * u * t * t) + d * (t * t * t);
}

/// Points along the curve, with the span (0 = first segment) each lies on.
List<(Offset, int)> connectorSamples(List<Offset> pts) {
  final out = <(Offset, int)>[];
  final cubics = connectorCubics(pts);
  for (var s = 0; s < cubics.length; s++) {
    final (a, b, c, d) = cubics[s];
    for (var k = 0; k <= _samplesPerSpan; k++) {
      out.add((_cubicAt(a, b, c, d, k / _samplesPerSpan), s));
    }
  }
  return out;
}

double _segDistance(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (l2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// How far [p] is from the curve through [pts], and which span is nearest.
({double distance, int span, Offset point}) nearestOnConnector(
  Offset p,
  List<Offset> pts,
) {
  final samples = connectorSamples(pts);
  var best = double.infinity;
  var span = 0;
  var point = pts.first;
  for (var i = 0; i + 1 < samples.length; i++) {
    if (samples[i].$2 != samples[i + 1].$2) continue;
    final d = _segDistance(p, samples[i].$1, samples[i + 1].$1);
    if (d < best) {
      best = d;
      span = samples[i].$2;
      final a = samples[i].$1, b = samples[i + 1].$1;
      final ab = b - a;
      final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
      final t = l2 == 0
          ? 0.0
          : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
      point = a + ab * t;
    }
  }
  return (distance: best, span: span, point: point);
}

/// Bounding box of the curve through [pts].
Rect connectorBounds(List<Offset> pts) {
  final s = connectorSamples(pts);
  var r = Rect.fromPoints(s.first.$1, s.first.$1);
  for (final (p, _) in s) {
    r = r.expandToInclude(Rect.fromPoints(p, p));
  }
  return r;
}
