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

/// The line through [pts] as a [Path]: a smooth curve, or (not [smooth])
/// straight pieces with sharp corners.
Path connectorPath(List<Offset> pts, {bool smooth = true}) {
  final path = Path()..moveTo(pts.first.dx, pts.first.dy);
  if (!smooth) {
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }
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
List<(Offset, int)> connectorSamples(List<Offset> pts, {bool smooth = true}) {
  final out = <(Offset, int)>[];
  if (!smooth) {
    for (var i = 0; i < pts.length; i++) {
      out.add((pts[i], i == 0 ? 0 : i - 1));
    }
    return out;
  }
  final cubics = connectorCubics(pts);
  for (var s = 0; s < cubics.length; s++) {
    final (a, b, c, d) = cubics[s];
    for (var k = 0; k <= _samplesPerSpan; k++) {
      out.add((_cubicAt(a, b, c, d, k / _samplesPerSpan), s));
    }
  }
  return out;
}

/// The pieces of the drawn line: (from, to, span).
List<(Offset, Offset, int)> _pieces(List<Offset> pts, bool smooth) {
  if (!smooth) {
    return [
      for (var i = 0; i + 1 < pts.length; i++) (pts[i], pts[i + 1], i),
    ];
  }
  final s = connectorSamples(pts);
  return [
    for (var i = 0; i + 1 < s.length; i++)
      if (s[i].$2 == s[i + 1].$2) (s[i].$1, s[i + 1].$1, s[i].$2),
  ];
}

/// How far [p] is from the line through [pts], which span is nearest, and
/// the nearest point on it.
({double distance, int span, Offset point}) nearestOnConnector(
  Offset p,
  List<Offset> pts, {
  bool smooth = true,
}) {
  var best = double.infinity;
  var span = 0;
  var point = pts.first;
  for (final (a, b, s) in _pieces(pts, smooth)) {
    final ab = b - a;
    final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
    final t = l2 == 0
        ? 0.0
        : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
    final q = a + ab * t;
    final d = (p - q).distance;
    if (d < best) {
      best = d;
      span = s;
      point = q;
    }
  }
  return (distance: best, span: span, point: point);
}

/// Bounding box of the curve through [pts].
Rect connectorBounds(List<Offset> pts, {bool smooth = true}) {
  final s = connectorSamples(pts, smooth: smooth);
  var r = Rect.fromPoints(s.first.$1, s.first.$1);
  for (final (p, _) in s) {
    r = r.expandToInclude(Rect.fromPoints(p, p));
  }
  return r;
}
