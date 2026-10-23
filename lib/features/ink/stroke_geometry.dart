// Shape of a pen stroke, shared by every writing surface (Canvas, note
// pages, PDF pages) so ink looks and behaves the same everywhere.
import 'dart:math' as math;
import 'dart:ui';

import '../../data/models/canvas_models.dart';

/// Pen pressure as 0..1. Flutter reports Apple Pencil force on iOS as a raw
/// value up to `pressureMax` (about 4.2), mice report nothing.
double normalizedPressure(double pressure, double pressureMax) {
  if (pressureMax > 1) return (pressure / pressureMax).clamp(0.0, 1.0);
  return pressure.clamp(0.0, 1.0);
}

/// Width factor for a pressure (0..1): 0.5 keeps the base width, light
/// strokes thin down to 45 %, firm ones up to 155 %.
double pressureFactor(double pressure) => 0.45 + 1.1 * pressure;

/// Smooth centre line through [points] (quadratic curves through segment
/// midpoints; ends exactly on the first and last point, so the ink stays
/// under the pen tip).
Path centreLine(List<StrokePoint> points, [Offset? predicted]) {
  final path = Path()..moveTo(points.first.x, points.first.y);
  for (var i = 1; i < points.length - 1; i++) {
    final p = points[i].offset;
    final mid = Offset.lerp(p, points[i + 1].offset, 0.5)!;
    path.quadraticBezierTo(p.dx, p.dy, mid.dx, mid.dy);
  }
  if (points.length > 1) path.lineTo(points.last.x, points.last.y);
  if (predicted != null) path.lineTo(predicted.dx, predicted.dy);
  return path;
}

/// Filled outline of a pressure-sensitive stroke: two edges offset from the
/// smoothed centre line by half the local width, joined by round ends.
Path pressureOutline(
  List<StrokePoint> points,
  double baseWidth, [
  Offset? predicted,
]) {
  final pts = <Offset>[for (final p in points) p.offset];
  final widths = <double>[
    for (final p in points) baseWidth * pressureFactor(p.pressure),
  ];
  if (predicted != null && pts.isNotEmpty) {
    pts.add(predicted);
    widths.add(widths.last);
  }
  // Drop repeated positions (a still pen): they have no direction.
  final p = <Offset>[], w = <double>[];
  for (var i = 0; i < pts.length; i++) {
    if (p.isNotEmpty && (pts[i] - p.last).distanceSquared < 1e-6) {
      w[w.length - 1] = math.max(w.last, widths[i]);
      continue;
    }
    p.add(pts[i]);
    w.add(widths[i]);
  }
  if (p.length == 1) {
    return Path()
      ..addOval(Rect.fromCircle(center: p.first, radius: w.first / 2));
  }
  // Soften width jumps between samples (pressure is noisy).
  for (var i = 1; i < w.length - 1; i++) {
    w[i] = (w[i - 1] + 2 * w[i] + w[i + 1]) / 4;
  }
  final left = <Offset>[], right = <Offset>[];
  for (var i = 0; i < p.length; i++) {
    final a = p[math.max(0, i - 1)], b = p[math.min(p.length - 1, i + 1)];
    var d = b - a;
    if (d.distance == 0) d = const Offset(1, 0);
    final n = Offset(-d.dy, d.dx) / d.distance * (w[i] / 2);
    left.add(p[i] + n);
    right.add(p[i] - n);
  }
  final path = Path()..moveTo(left.first.dx, left.first.dy);
  void edge(List<Offset> e) {
    for (var i = 1; i < e.length - 1; i++) {
      final mid = Offset.lerp(e[i], e[i + 1], 0.5)!;
      path.quadraticBezierTo(e[i].dx, e[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(e.last.dx, e.last.dy);
  }

  edge(left);
  path.arcToPoint(right.last, radius: Radius.circular(w.last / 2));
  edge(right.reversed.toList());
  path.arcToPoint(left.first, radius: Radius.circular(w.first / 2));
  path.close();
  return path;
}

/// Draws one stroke the same way on every surface. [predicted]: where the
/// pen is expected to be next (drawn only, never stored).
void paintStroke(
  Canvas canvas,
  StrokeItem stroke, {
  Path? cachedPath,
  Offset? predicted,
}) {
  final points = stroke.points;
  if (points.isEmpty) return;
  final fill = Paint()
    ..color = stroke.color
    ..isAntiAlias = true;
  // Pressure-sensitive ink (Apple Pencil pen); highlighters stay even.
  if (stroke.pressureWidth && stroke.color.a >= 0.99) {
    canvas.drawPath(
      cachedPath ?? pressureOutline(points, stroke.strokeWidth, predicted),
      fill,
    );
    return;
  }
  if (points.length == 1 && predicted == null) {
    canvas.drawCircle(points.first.offset, stroke.strokeWidth / 2, fill);
    return;
  }
  canvas.drawPath(
    cachedPath ?? centreLine(points, predicted),
    Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true,
  );
}

/// Cacheable path for [stroke] (what [paintStroke] draws).
Path strokePath(StrokeItem stroke) =>
    stroke.pressureWidth && stroke.color.a >= 0.99
    ? pressureOutline(stroke.points, stroke.strokeWidth)
    : centreLine(stroke.points);

// ------------------------------------------------- straight-line hold --

/// Whether a stroke drawn and then held still should become a straight
/// line: long enough on screen and close to the line between its ends, so
/// handwriting (letters, curves) is never straightened.
bool looksLikeLine(List<StrokePoint> points, double scale) {
  if (points.length < 2) return false;
  final a = points.first.offset, b = points.last.offset;
  final length = (b - a).distance * scale;
  if (length < minLineLength) return false;
  var deviation = 0.0;
  for (final p in points) {
    deviation = math.max(deviation, distanceToSegment(p.offset, a, b) * scale);
  }
  return deviation <= math.max(10, length * 0.12);
}

/// Shortest straight line (screen pixels) that a hold can produce.
const double minLineLength = 30;

/// The straight replacement for a held stroke: same start and end points
/// (and pressures), with points in between so erasing and hit-testing work
/// along its whole length.
List<StrokePoint> straightened(List<StrokePoint> points) {
  final a = points.first, b = points.last;
  final length = (b.offset - a.offset).distance;
  final steps = math.max(1, (length / 6).ceil());
  final pressure =
      points.map((p) => p.pressure).reduce((x, y) => x + y) / points.length;
  return [
    for (var i = 0; i <= steps; i++)
      StrokePoint(
        a.x + (b.x - a.x) * i / steps,
        a.y + (b.y - a.y) * i / steps,
        pressure,
      ),
  ];
}
