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
    // Turned the way the corners are (not just the bounding box), sized to
    // hold the whole drawing.
    final u = _boxDirection(corners);
    final v = Offset(-u.dy, u.dx);
    final frame = _extentsIn(pts, u, v);
    Offset at(double a, double b) => u * a + v * b;
    final c0 = at(frame.minU, frame.minV), c1 = at(frame.maxU, frame.minV);
    final c2 = at(frame.maxU, frame.maxV), c3 = at(frame.minU, frame.maxV);
    return ShapeMatch(
      RecognizedShape.rectangle,
      _densify([c0, c1, c2, c3, c0], pressure),
    );
  }

  // An ellipse: points stay close to the ellipse that fits them, turned
  // along their main direction.
  final u = _mainDirection(pts);
  final v = Offset(-u.dy, u.dx);
  final f = _extentsIn(pts, u, v);
  final cu = (f.minU + f.maxU) / 2, cv = (f.minV + f.maxV) / 2;
  final rx = (f.maxU - f.minU) / 2, ry = (f.maxV - f.minV) / 2;
  if (rx < 8 || ry < 8) return null;
  var error = 0.0;
  for (final p in pts) {
    final a = p.dx * u.dx + p.dy * u.dy - cu;
    final b = p.dx * v.dx + p.dy * v.dy - cv;
    error += (math.sqrt(math.pow(a / rx, 2) + math.pow(b / ry, 2)) - 1).abs();
  }
  if (error / pts.length < 0.12 && corners.length > 4) {
    return ShapeMatch(RecognizedShape.ellipse, [
      for (var i = 0; i <= 64; i++)
        StrokePoint(
          (u * (cu + rx * math.cos(i / 64 * 2 * math.pi)) +
                  v * (cv + ry * math.sin(i / 64 * 2 * math.pi)))
              .dx,
          (u * (cu + rx * math.cos(i / 64 * 2 * math.pi)) +
                  v * (cv + ry * math.sin(i / 64 * 2 * math.pi)))
              .dy,
          pressure,
        ),
    ]);
  }
  return null;
}

/// The direction (unit vector) a rectangle with these four corners is
/// turned: the average of its edge angles, folded to a quarter turn.
Offset _boxDirection(List<Offset> c) {
  var sx = 0.0, sy = 0.0;
  for (var i = 0; i < 4; i++) {
    final e = c[(i + 1) % 4] - c[i];
    final a = math.atan2(e.dy, e.dx) * 4; // 90Â° apart edges agree
    sx += math.cos(a);
    sy += math.sin(a);
  }
  final angle = math.atan2(sy, sx) / 4;
  return Offset(math.cos(angle), math.sin(angle));
}

/// The main direction of a point cloud (its longest spread).
Offset _mainDirection(List<Offset> pts) {
  var mx = 0.0, my = 0.0;
  for (final p in pts) {
    mx += p.dx;
    my += p.dy;
  }
  mx /= pts.length;
  my /= pts.length;
  var sxx = 0.0, syy = 0.0, sxy = 0.0;
  for (final p in pts) {
    sxx += (p.dx - mx) * (p.dx - mx);
    syy += (p.dy - my) * (p.dy - my);
    sxy += (p.dx - mx) * (p.dy - my);
  }
  final angle = 0.5 * math.atan2(2 * sxy, sxx - syy);
  return Offset(math.cos(angle), math.sin(angle));
}

({double minU, double maxU, double minV, double maxV}) _extentsIn(
  List<Offset> pts,
  Offset u,
  Offset v,
) {
  var minU = double.infinity, maxU = -double.infinity;
  var minV = double.infinity, maxV = -double.infinity;
  for (final p in pts) {
    final a = p.dx * u.dx + p.dy * u.dy;
    final b = p.dx * v.dx + p.dy * v.dy;
    minU = math.min(minU, a);
    maxU = math.max(maxU, a);
    minV = math.min(minV, b);
    maxV = math.max(maxV, b);
  }
  return (minU: minU, maxU: maxU, minV: minV, maxV: maxV);
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
