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
Path centreLine(
  List<StrokePoint> points, [
  Offset? predicted,
  double width = 0,
]) {
  final pts = [for (final p in points) p.offset];
  // Set-down/lift-off wobble would show as a hook under the round cap.
  if (width > 0) trimLiftJitter(pts, width, width);
  final path = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (var i = 1; i < pts.length - 1; i++) {
    final p = pts[i];
    final mid = Offset.lerp(p, pts[i + 1], 0.5)!;
    path.quadraticBezierTo(p.dx, p.dy, mid.dx, mid.dy);
  }
  if (pts.length > 1) path.lineTo(pts.last.dx, pts.last.dy);
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
  trimLiftJitter(p, w.first, w.last, widths: w);
  if (p.length == 1) {
    return Path()
      ..addOval(Rect.fromCircle(center: p.first, radius: w.first / 2));
  }
  final left = <Offset>[], right = <Offset>[];
  for (var i = 0; i < p.length; i++) {
    // At the two ends the direction is taken over about half a line width
    // (endTangent), so one shaky last sample cannot twist the cap.
    var d = i == 0
        ? endTangent(p, w.first, atStart: true)
        : i == p.length - 1
        ? endTangent(p, w.last, atStart: false)
        : p[i + 1] - p[i - 1];
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

  // Round ends bulge OUTWARD, ahead of the tip and behind the start. With
  // "left" = the normal turned from the direction as above, that is the
  // counter-clockwise half circle on screen (y points down). The default
  // (clockwise) arc bulged back into the stroke: both ends looked cut off
  // with a notch.
  edge(left);
  path.arcToPoint(
    right.last,
    radius: Radius.circular(w.last / 2),
    clockwise: false,
  );
  edge(right.reversed.toList());
  path.arcToPoint(
    left.first,
    radius: Radius.circular(w.first / 2),
    clockwise: false,
  );
  path.close();
  return path;
}

/// The stroke's direction at one end, measured from the end point to the
/// first point at least [width] / 2 away (or the far end of a short
/// stroke): the local direction of the drawn line, not of the last tiny
/// pen movement.
Offset endTangent(List<Offset> p, double width, {required bool atStart}) {
  final reach = math.max(width / 2, 0.5);
  if (atStart) {
    for (var i = 1; i < p.length; i++) {
      if ((p[i] - p.first).distance >= reach) return p[i] - p.first;
    }
    return p.last - p.first;
  }
  for (var i = p.length - 2; i >= 0; i--) {
    if ((p.last - p[i]).distance >= reach) return p.last - p[i];
  }
  return p.last - p.first;
}

/// Removes the pen's set-down and lift-off wobble from the copy that is
/// drawn (never from the saved stroke): an end sample closer than a third
/// of the line width that turns back by more than 90° would show as a
/// hook or a spike under the round end. Everything else is kept, so the
/// drawn line follows the saved centre line.
void trimLiftJitter(
  List<Offset> p,
  double startWidth,
  double endWidth, {
  List<double>? widths,
}) {
  bool turnsBack(Offset a, Offset b, Offset c) {
    final d1 = b - a, d2 = c - b;
    return d1.dx * d2.dx + d1.dy * d2.dy < 0;
  }

  while (p.length > 2 &&
      (p.last - p[p.length - 2]).distance < endWidth / 3 &&
      turnsBack(p[p.length - 3], p[p.length - 2], p.last)) {
    p.removeLast();
    widths?.removeLast();
  }
  while (p.length > 2 &&
      (p[1] - p.first).distance < startWidth / 3 &&
      turnsBack(p[2], p[1], p.first)) {
    p.removeAt(0);
    widths?.removeAt(0);
  }
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
    cachedPath ?? centreLine(points, predicted, stroke.strokeWidth),
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
    : centreLine(stroke.points, null, stroke.strokeWidth);

// ------------------------------------------------- straight-line hold --

/// Whether a stroke drawn and then held still should become a straight
/// line: long enough on screen and close to the line between its ends, so
/// handwriting (letters, curves) is never straightened.
bool looksLikeLine(List<StrokePoint> points, double scale) {
  if (points.length < 2 || !scale.isFinite || scale <= 0) return false;
  final a = points.first.offset, b = points.last.offset;
  final chord = (b - a).distance;
  final screenLength = chord * scale;
  if (screenLength < minLineLength || chord == 0) return false;
  var pathLength = 0.0;
  var deviation = 0.0;
  var squaredDeviation = 0.0;
  var backwards = 0.0;
  var previous = points.first.offset;
  final direction = (b - a) / chord;
  for (final p in points) {
    final error = distanceToSegment(p.offset, a, b) * scale;
    deviation = math.max(deviation, error);
    squaredDeviation += error * error;
    final segment = p.offset - previous;
    pathLength += segment.distance;
    if (segment.distance > 0) {
      backwards +=
          math.max(
            0,
            -((segment / segment.distance).dx * direction.dx +
                (segment / segment.distance).dy * direction.dy),
          ) *
          segment.distance;
    }
    previous = p.offset;
  }
  final rms = math.sqrt(squaredDeviation / points.length);
  // Exclude loops and scribbles that happen to remain inside a narrow band:
  // their travelled path is too long or turns substantially back on itself.
  final efficient = pathLength / chord;
  final backtrackRatio = backwards / chord;
  return deviation <= math.max(8, screenLength * 0.09) &&
      rms <= math.max(3, screenLength * 0.035) &&
      efficient <= 1.16 &&
      backtrackRatio <= 0.08;
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
