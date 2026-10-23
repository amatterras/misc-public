// Turns a rough hand-drawn shape into a clean one: a straight line, a
// triangle, a rectangle or an ellipse. Only clear cases are recognized;
// anything else (handwriting, scribbles) is left exactly as drawn.
import 'dart:math' as math;
import 'dart:ui';

import '../../data/models/canvas_models.dart';

enum RecognizedShape { line, triangle, rectangle, ellipse }

class ShapeMatch {
  const ShapeMatch(this.shape, this.points);
  final RecognizedShape shape;

  /// The clean outline (closed shapes end where they start).
  final List<StrokePoint> points;
}

/// The clean shape [points] were meant to be, or null.
ShapeMatch? recognizeShape(List<StrokePoint> points) {
  if (points.length < 4) return null;
  final pts = [for (final p in points) Offset(p.x, p.y)];
  final bounds = _bounds(pts);
  final size = math.max(bounds.width, bounds.height);
  if (size < 24) return null; // too small to be meant as a shape
  final pressure =
      points.map((p) => p.pressure).reduce((a, b) => a + b) / points.length;
  final length = _length(pts);
  final gap = (pts.first - pts.last).distance;

  // A line: nearly as long as the distance between its ends.
  if (gap / length > 0.93) {
    return ShapeMatch(
      RecognizedShape.line,
      _densify([pts.first, pts.last], pressure),
    );
  }

  // Closed shapes end near where they started.
  if (gap > size * 0.25) return null;

  final corners = _simplify(pts, size * 0.08);
  // Drop the duplicated closing point.
  if (corners.length > 2 &&
      (corners.first - corners.last).distance < size * 0.25) {
    corners.removeLast();
  }

  if (corners.length == 3 && _isConvexish(corners)) {
    return ShapeMatch(
      RecognizedShape.triangle,
      _densify([...corners, corners.first], pressure),
    );
  }
  if (corners.length == 4 && _rightAngled(corners)) {
    return ShapeMatch(
      RecognizedShape.rectangle,
      _densify([
        bounds.topLeft,
        bounds.topRight,
        bounds.bottomRight,
        bounds.bottomLeft,
        bounds.topLeft,
      ], pressure),
    );
  }

  // An ellipse: points stay close to the ellipse fitting the bounds.
  final c = bounds.center;
  final rx = bounds.width / 2, ry = bounds.height / 2;
  if (rx < 8 || ry < 8) return null;
  var error = 0.0;
  for (final p in pts) {
    final d = math.sqrt(
      math.pow((p.dx - c.dx) / rx, 2) + math.pow((p.dy - c.dy) / ry, 2),
    );
    error += (d - 1).abs();
  }
  if (error / pts.length < 0.12 && corners.length > 4) {
    return ShapeMatch(RecognizedShape.ellipse, [
      for (var i = 0; i <= 64; i++)
        StrokePoint(
          c.dx + rx * math.cos(i / 64 * 2 * math.pi),
          c.dy + ry * math.sin(i / 64 * 2 * math.pi),
          pressure,
        ),
    ]);
  }
  return null;
}

Rect _bounds(List<Offset> pts) {
  var r = Rect.fromPoints(pts.first, pts.first);
  for (final p in pts) {
    r = r.expandToInclude(Rect.fromPoints(p, p));
  }
  return r;
}

double _length(List<Offset> pts) {
  var sum = 0.0;
  for (var i = 1; i < pts.length; i++) {
    sum += (pts[i] - pts[i - 1]).distance;
  }
  return sum == 0 ? 1 : sum;
}

/// Ramer–Douglas–Peucker: the corner points of a polyline.
List<Offset> _simplify(List<Offset> pts, double epsilon) {
  if (pts.length < 3) return [...pts];
  var index = 0;
  var maxDistance = 0.0;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = _distanceToSegment(pts[i], pts.first, pts.last);
    if (d > maxDistance) {
      maxDistance = d;
      index = i;
    }
  }
  // A closed loop: split at the point farthest from the start instead.
  if ((pts.first - pts.last).distance < epsilon) {
    var far = 0.0;
    for (var i = 1; i < pts.length - 1; i++) {
      final d = (pts[i] - pts.first).distance;
      if (d > far) {
        far = d;
        index = i;
      }
    }
    maxDistance = far;
  }
  if (maxDistance <= epsilon) return [pts.first, pts.last];
  final left = _simplify(pts.sublist(0, index + 1), epsilon);
  final right = _simplify(pts.sublist(index), epsilon);
  return [...left.sublist(0, left.length - 1), ...right];
}

double _distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

bool _isConvexish(List<Offset> c) {
  final area =
      ((c[1] - c[0]).dx * (c[2] - c[0]).dy -
              (c[1] - c[0]).dy * (c[2] - c[0]).dx)
          .abs();
  final b = _bounds(c);
  return area > b.width * b.height * 0.2;
}

/// Four corners whose angles are all near 90°.
bool _rightAngled(List<Offset> c) {
  for (var i = 0; i < 4; i++) {
    final a = c[(i + 3) % 4] - c[i];
    final b = c[(i + 1) % 4] - c[i];
    final cos = (a.dx * b.dx + a.dy * b.dy) / (a.distance * b.distance);
    if (cos.abs() > 0.35) return false; // more than ~20° off
  }
  return true;
}

/// Points along the polyline [corners], every few units, so erasing and
/// hit-testing work along the whole shape.
List<StrokePoint> _densify(List<Offset> corners, double pressure) {
  final out = <StrokePoint>[];
  for (var i = 0; i < corners.length - 1; i++) {
    final a = corners[i], b = corners[i + 1];
    final steps = math.max(1, ((b - a).distance / 6).ceil());
    for (var k = 0; k < steps; k++) {
      final p = Offset.lerp(a, b, k / steps)!;
      out.add(StrokePoint(p.dx, p.dy, pressure));
    }
  }
  out.add(StrokePoint(corners.last.dx, corners.last.dy, pressure));
  return out;
}
