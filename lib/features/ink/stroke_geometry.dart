// Shape of a pen stroke, shared by every writing surface (Canvas, note
// pages, PDF pages, Calendar days, widgets) so ink looks and behaves the
// same everywhere, on every platform.
//
// Two representations are kept apart:
//  * the saved stroke: the raw samples as the pen delivered them
//    (position + pressure), never smoothed or resampled;
//  * the drawn shape, rebuilt from those samples here, every time, by
//    the same code for the live stroke and the finished one. Nothing is
//    filtered over time, so the ink never trails behind the pen.
import 'dart:math' as math;
import 'dart:ui';

import '../../data/models/canvas_models.dart';

export '../../data/models/canvas_models.dart'
    show pressureFactor, tiltWidthFactor, inkWidthFactor;

/// Pen pressure as 0..1. Flutter reports Apple Pencil force on iOS as a raw
/// value up to `pressureMax` (about 4.2), mice report nothing.
double normalizedPressure(double pressure, double pressureMax) {
  if (!pressure.isFinite) return 0.5;
  if (pressureMax > 1) return (pressure / pressureMax).clamp(0.0, 1.0);
  return pressure.clamp(0.0, 1.0);
}

/// The drawn shape of one stroke: one filled or stroked [path].
///
/// A pressure stroke's path holds its outline and, at sharp turns, round
/// [discs] (centre, radius; listed for tests and diagnosis). The discs give
/// a hairpin turn (the top of an "n", the point of a "v") the round tip a
/// real pen leaves; an offset outline alone pinches there. Everything is
/// in ONE path filled once, so see-through ink has the same opacity
/// everywhere: nothing is painted twice where the parts overlap.
class StrokeShape {
  StrokeShape(this.path, {this.discs = const [], this.filled = true});

  final Path path;
  final List<(Offset, double)> discs;

  /// Filled outline (pressure ink) or a centre line stroked with round caps.
  final bool filled;

  void paint(Canvas canvas, Paint paint) => canvas.drawPath(path, paint);
}

/// A disc as a polygon wound the same way as a stroke outline (see
/// [_pressureRange]), so that inside one non-zero-filled path it adds to
/// the outline instead of cutting a hole into it.
List<Offset> _discPolygon(Offset centre, double radius) {
  final steps = (radius * 12).ceil().clamp(12, 64);
  return [
    for (var k = 0; k < steps; k++)
      Offset(
        centre.dx + radius * math.cos(2 * math.pi * k / steps),
        centre.dy - radius * math.sin(2 * math.pi * k / steps),
      ),
  ];
}

// ----------------------------------------------------------- the curve --

/// Points closer than this (world units) are one position: a still pen.
const double _same = 1e-3;

/// Appends the centripetal Catmull-Rom curve through [p] to [out] as dense
/// samples, close enough that straight lines between them stay within
/// [tolerance] (world units) of the curve, with [w] interpolated alongside
/// into [outW] when given. Straight stretches get no extra samples.
///
/// Centripetal Catmull-Rom passes through every sample (small loops and
/// the exact shape of a letter survive, unlike curves through midpoints,
/// which cut corners and shrink loops when samples are sparse) and, unlike
/// the uniform kind, never overshoots into cusps or self-loops. Each piece
/// depends only on its four neighbouring samples, so finished pieces of a
/// live stroke never change as the pen moves on: only the last piece is
/// provisional, and the finished stroke is exactly the last live frame.
void catmullRomDense(
  List<Offset> p,
  List<double>? w,
  double tolerance,
  List<Offset> out, [
  List<double>? outW,
  int from = 0,
  int? to,
]) {
  final n = p.length;
  if (n == 0) return;
  final last = math.min(to ?? n - 1, n - 1);
  out.add(p[from]);
  outW?.add(w![from]);
  if (n == 1) return;
  // Plain doubles throughout: this runs for every sample of the live stroke
  // on every frame, and Offset arithmetic allocated ~20 objects a sample.
  for (var i = from; i < last; i++) {
    final p1 = p[i], p2 = p[i + 1];
    final x1 = p1.dx, y1 = p1.dy, x2 = p2.dx, y2 = p2.dy;
    // Outer neighbours; mirrored at the stroke's ends, so the curve leaves
    // the first and reaches the last sample along the line to its
    // neighbour.
    double x0, y0, x3, y3;
    if (i > 0) {
      x0 = p[i - 1].dx;
      y0 = p[i - 1].dy;
    } else {
      x0 = 2 * x1 - x2;
      y0 = 2 * y1 - y2;
    }
    if (i + 2 < n) {
      x3 = p[i + 2].dx;
      y3 = p[i + 2].dy;
    } else {
      x3 = 2 * x2 - x1;
      y3 = 2 * y2 - y1;
    }
    // Centripetal parameterisation (Barry–Goldman, alpha = 1/2).
    final d2 = math.sqrt(math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)));
    double c1x = x1, c1y = y1, c2x = x2, c2y = y2;
    if (d2 >= 1e-9) {
      var d1 = math.sqrt(math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)));
      var d3 = math.sqrt(math.sqrt((x3 - x2) * (x3 - x2) + (y3 - y2) * (y3 - y2)));
      if (d1 < 1e-9) d1 = d2;
      if (d3 < 1e-9) d3 = d2;
      final a = d2 / d1, b = d2 / (d1 + d2);
      final m1x = (x2 - x1) + ((x1 - x0) * a - (x2 - x0) * b);
      final m1y = (y2 - y1) + ((y1 - y0) * a - (y2 - y0) * b);
      final c = d2 / d3, e = d2 / (d2 + d3);
      final m2x = (x2 - x1) + ((x3 - x2) * c - (x3 - x1) * e);
      final m2y = (y2 - y1) + ((y3 - y2) * c - (y3 - y1) * e);
      c1x = x1 + m1x / 3;
      c1y = y1 + m1y / 3;
      c2x = x2 - m2x / 3;
      c2y = y2 - m2y / 3;
    }
    // Wang's bound: segments needed for the cubic to stay within tolerance.
    final ax = x1 - 2 * c1x + c2x, ay = y1 - 2 * c1y + c2y;
    final bx = c1x - 2 * c2x + x2, by = c1y - 2 * c2y + y2;
    final dd = math.sqrt(math.max(ax * ax + ay * ay, bx * bx + by * by));
    final steps = dd <= 0
        ? 1
        : math.max(1, math.min(32, math.sqrt(0.75 * dd / tolerance).ceil()));
    for (var s = 1; s < steps; s++) {
      final t = s / steps;
      final u = 1 - t;
      final k0 = u * u * u, k1 = 3 * u * u * t, k2 = 3 * u * t * t;
      final k3 = t * t * t;
      out.add(
        Offset(
          k0 * x1 + k1 * c1x + k2 * c2x + k3 * x2,
          k0 * y1 + k1 * c1y + k2 * c2y + k3 * y2,
        ),
      );
      if (outW != null) outW.add(w![i] + (w[i + 1] - w[i]) * t);
    }
    out.add(p2);
    outW?.add(w![i + 1]);
  }
}

/// Copies [points] (plus [predicted]) without repeated positions.
List<Offset> _distinct(List<StrokePoint> points, Offset? predicted) {
  final out = <Offset>[];
  for (final p in points) {
    final o = p.offset;
    if (out.isNotEmpty && (o - out.last).distanceSquared < _same * _same) {
      continue;
    }
    out.add(o);
  }
  if (predicted != null &&
      out.isNotEmpty &&
      (predicted - out.last).distanceSquared >= _same * _same) {
    out.add(predicted);
  }
  return out;
}

/// Smooth centre line through [points] (see [catmullRomDense]): exactly
/// through every sample, ending on the last one, so the ink stays under the
/// pen tip.
Path centreLine(
  List<StrokePoint> points, [
  Offset? predicted,
  double width = 0,
]) {
  final dense = centreLinePoints(points, predicted, width);
  if (dense.isEmpty) return Path();
  if (dense.length == 1) {
    // A dot: a zero-length line still gets its round cap.
    return Path()
      ..moveTo(dense.first.dx, dense.first.dy)
      ..lineTo(dense.first.dx, dense.first.dy);
  }
  // One call for the whole line (see pressureShape).
  return Path()..addPolygon(dense, false);
}

/// The points [centreLine] joins: the smooth curve through [points] as
/// dense samples (one point for a dot, none for no points). Also what an
/// export strokes, so exported lines are the lines on screen.
List<Offset> centreLinePoints(
  List<StrokePoint> points, [
  Offset? predicted,
  double width = 0,
]) {
  final pts = _distinct(points, predicted);
  if (pts.isEmpty) return pts;
  // Set-down/lift-off wobble would show as a hook under the round cap.
  if (width > 0) trimLiftJitter(pts, width, width);
  if (pts.length == 1) return pts;
  final dense = <Offset>[];
  catmullRomDense(pts, null, 0.04, dense);
  return dense;
}

/// The closed outlines [strokeShape] fills for [stroke] (its edge, and the
/// discs at sharp turns), all wound the same way for a non-zero fill; null
/// for a stroke that is drawn as an even line (see [centreLinePoints]).
/// For exports that must draw exactly the ink on screen.
List<List<Offset>>? inkContours(StrokeItem stroke) {
  if (!isPressureInk(stroke)) return null;
  final prep = _PressurePrep(
    stroke.points,
    stroke.strokeWidth,
    null,
    stroke.pressureWidth,
    stroke.tiltWidth,
  );
  if (prep.p.isEmpty) return const [];
  if (prep.p.length == 1) {
    return [_discPolygon(prep.p.first, prep.w.first / 2)];
  }
  final contours = <List<Offset>>[];
  _pressureRange(prep, 0, prep.p.length - 1, contours: contours);
  return contours;
}

/// Filled outline of a pressure-sensitive stroke (see [pressureShape]).
Path pressureOutline(
  List<StrokePoint> points,
  double baseWidth, [
  Offset? predicted,
]) => pressureShape(points, baseWidth, predicted).path;

/// The most set-down or lift-off samples [trimLiftJitter] removes at one
/// end. Real wobble is one or two samples; without a limit a thick pen
/// writing a small zigzag had its whole stroke trimmed away.
const int maxLiftTrim = 2;

/// Turns sharper than this (cosine of the angle between the incoming and
/// outgoing direction) get a round disc: about 75°.
const double _sharpTurnCos = 0.26;

/// Pressure ink: two edges offset from the curved centre line by half the
/// local width, joined by round ends, plus round discs at sharp turns.
///
/// [pressure] / [tilt]: which of the samples' measurements set the width
/// (see [inkWidthFactor]).
StrokeShape pressureShape(
  List<StrokePoint> points,
  double baseWidth, [
  Offset? predicted,
  bool pressure = true,
  bool tilt = false,
]) {
  final prep = _PressurePrep(points, baseWidth, predicted, pressure, tilt);
  if (prep.p.isEmpty) return StrokeShape(Path());
  if (prep.p.length == 1) return _dot(prep.p.first, prep.w.first);
  return _pressureRange(prep, 0, prep.p.length - 1);
}

/// The samples of a pressure stroke as drawn: repeated positions merged,
/// widths from pressure (softened), the prediction appended, set-down and
/// lift-off wobble trimmed. Cheap (no curve work).
class _PressurePrep {
  _PressurePrep(
    List<StrokePoint> points,
    double baseWidth,
    Offset? predicted, [
    bool pressure = true,
    bool tilt = false,
  ]) {
    for (final s in points) {
      final o = s.offset;
      final width =
          baseWidth *
          (pressure ? pressureFactor(s.pressure) : 1) *
          (tilt ? tiltWidthFactor(s.altitude) : 1);
      // Repeated positions (a still pen) have no direction: keep one, at
      // the widest pressure seen there.
      if (p.isNotEmpty && (o - p.last).distanceSquared < _same * _same) {
        w[w.length - 1] = math.max(w.last, width);
        continue;
      }
      p.add(o);
      w.add(width);
    }
    real = p.length;
    if (p.isEmpty) return;
    if (predicted != null &&
        (predicted - p.last).distanceSquared >= _same * _same) {
      p.add(predicted);
      w.add(w.last);
    }
    if (p.length == 1) return;
    // Soften width jumps between samples (pressure is noisy). One pass over
    // the neighbours only: a sample's width is final once the next sample
    // has arrived, so the live stroke does not ripple behind the pen.
    for (var i = 1; i < w.length - 1; i++) {
      w[i] = (w[i - 1] + 2 * w[i] + w[i + 1]) / 4;
    }
    // Lift-off wobble first, then set-down wobble (as always).
    trimLiftJitter(p, w.first, w.last, widths: w, start: false);
    real = math.min(real, p.length);
    final before = p.length;
    trimLiftJitter(p, w.first, w.last, widths: w, end: false);
    trimmedStart = before - p.length;
    real -= trimmedStart;
  }

  final p = <Offset>[];
  final w = <double>[];

  /// Samples before the prediction (after trimming).
  int real = 0;

  /// Set-down samples trimmed from the start.
  int trimmedStart = 0;
}

/// The outline of the samples from [from] to [to] of [prep] (indices into
/// prep.p), with round ends, curved using the samples around them too, so
/// a range drawn alone matches the same stretch of the whole stroke.
StrokeShape _pressureRange(
  _PressurePrep prep,
  int from,
  int to, {
  int? discsFrom,
  List<List<Offset>>? contours,
}) {
  final p = prep.p, w = prep.w;
  final dense = <Offset>[], dw = <double>[];
  // 0.04 world units: facets stay under a fifth of a pixel at 5× zoom.
  catmullRomDense(p, w, 0.04, dense, dw, from, to);

  final m = dense.length;
  final left = List<Offset>.filled(m, Offset.zero);
  final right = List<Offset>.filled(m, Offset.zero);
  var nx = 0.0, ny = 1.0;
  var startNormal = const Offset(0, 1);
  for (var i = 0; i < m; i++) {
    // Direction: at the ends over about half a line width (endTangent), so
    // one shaky last sample cannot twist the cap; inside, the bisector of
    // the incoming and outgoing direction.
    double dx, dy;
    if (i == 0 || i == m - 1) {
      final d = endTangent(
        dense,
        i == 0 ? dw.first : dw.last,
        atStart: i == 0,
      );
      dx = d.dx;
      dy = d.dy;
    } else {
      final ax = dense[i].dx - dense[i - 1].dx;
      final ay = dense[i].dy - dense[i - 1].dy;
      final bx = dense[i + 1].dx - dense[i].dx;
      final by = dense[i + 1].dy - dense[i].dy;
      final la = math.sqrt(ax * ax + ay * ay);
      final lb = math.sqrt(bx * bx + by * by);
      dx = (la > 0 ? ax / la : 0) + (lb > 0 ? bx / lb : 0);
      dy = (la > 0 ? ay / la : 0) + (lb > 0 ? by / lb : 0);
      // A full reversal (a cusp): keep the incoming direction.
      if (dx * dx + dy * dy < 1e-6 && la > 0) {
        dx = ax / la;
        dy = ay / la;
      }
    }
    final len = math.sqrt(dx * dx + dy * dy);
    if (len > 0) {
      nx = -dy / len;
      ny = dx / len;
    }
    if (i == 0) startNormal = Offset(nx, ny);
    final half = dw[i] / 2;
    final c = dense[i];
    left[i] = Offset(c.dx + nx * half, c.dy + ny * half);
    right[i] = Offset(c.dx - nx * half, c.dy - ny * half);
  }
  final lastNormal = Offset(nx, ny);

  // One closed polygon: the left edge, the round end, the right edge back,
  // the round start. Built as one list and handed over in one call (one
  // path command per point was the main cost of a long live stroke).
  // Round ends bulge OUTWARD, ahead of the tip and behind the start: with
  // "left" = the normal turned from the direction as above, that is the
  // counter-clockwise half circle on screen (y points down).
  final outline = <Offset>[...left];
  _cap(outline, dense.last, lastNormal, dw.last / 2, ahead: true);
  outline.addAll(right.reversed);
  _cap(outline, dense.first, startNormal, dw.first / 2, ahead: false);
  final path = Path()..addPolygon(outline, true);
  contours?.add(outline);

  final discs = <(Offset, double)>[];
  final firstDisc = math.max(1, discsFrom ?? from);
  for (var i = firstDisc; i < math.min(to, p.length - 1); i++) {
    final a = p[i] - p[i - 1], b = p[i + 1] - p[i];
    final la = a.distance, lb = b.distance;
    if (la == 0 || lb == 0) continue;
    final cos = (a.dx * b.dx + a.dy * b.dy) / (la * lb);
    if (cos < _sharpTurnCos) {
      discs.add((p[i], w[i] / 2));
      final disc = _discPolygon(p[i], w[i] / 2);
      path.addPolygon(disc, true);
      contours?.add(disc);
    }
  }
  return StrokeShape(path, discs: discs);
}

/// The live (still being drawn) pressure stroke, drawn as finished pieces
/// that are kept plus a short tail rebuilt each frame, so the cost of a
/// frame does not grow with the length of the stroke.
///
/// Each piece of the curve depends only on its neighbouring samples, so a
/// stretch more than a few samples behind the pen never changes again.
/// Pieces are computed with their neighbours (see [_pressureRange]) and
/// overlap by one sample, and their round ends lie inside the line (a
/// round end is a disc of the line's own width centred on its centre
/// line), so together they draw what [pressureShape] draws for the whole
/// stroke, which is what the finished stroke uses.
class LiveInkGeometry {
  String? _id;
  double _width = 0;
  bool _pressure = true;
  bool _tilt = false;
  int _trimmedStart = 0;
  int _frozenTo = 0;
  int _pieces = 0;

  /// The kept pieces as one path (and their discs): one path, so where
  /// pieces overlap the edge is anti-aliased once, exactly like the
  /// finished stroke's single outline (two overlapping anti-aliased edges
  /// would draw a slightly darker seam).
  Path _frozenPath = Path();
  final List<(Offset, double)> _frozenDiscs = [];

  /// Samples behind the pen after which a piece no longer changes (the
  /// curve looks two samples ahead, width softening one, lift-off
  /// trimming up to two), with a margin.
  static const int settle = 6;

  /// Samples per frozen piece.
  static const int chunk = 48;

  /// Frozen pieces kept now (for tests).
  int get frozenPieces => _pieces;

  void reset() {
    _id = null;
    _frozenPath = Path();
    _frozenDiscs.clear();
    _frozenTo = 0;
    _pieces = 0;
  }

  /// What to draw for the live [stroke] now (in order, same paint for all).
  List<StrokeShape> shapes(StrokeItem stroke, Offset? predicted) {
    if (!isPressureInk(stroke)) {
      reset();
      return [strokeShape(stroke, predicted: predicted)];
    }
    final prep = _PressurePrep(
      stroke.points,
      stroke.strokeWidth,
      predicted,
      stroke.pressureWidth,
      stroke.tiltWidth,
    );
    if (prep.p.length < 2) {
      reset();
      return [strokeShape(stroke, predicted: predicted)];
    }
    if (stroke.id != _id ||
        stroke.strokeWidth != _width ||
        stroke.pressureWidth != _pressure ||
        stroke.tiltWidth != _tilt ||
        prep.trimmedStart != _trimmedStart ||
        _frozenTo > prep.real - settle) {
      reset();
      _id = stroke.id;
      _width = stroke.strokeWidth;
      _pressure = stroke.pressureWidth;
      _tilt = stroke.tiltWidth;
      _trimmedStart = prep.trimmedStart;
    }
    final settled = prep.real - settle;
    if (settled - _frozenTo >= chunk) {
      final piece = _pressureRange(
        prep,
        math.max(0, _frozenTo - 1),
        settled,
        discsFrom: _frozenTo,
      );
      _frozenPath.addPath(piece.path, Offset.zero);
      _frozenDiscs.addAll(piece.discs);
      _frozenTo = settled;
      _pieces++;
    }
    final tail = _pressureRange(
      prep,
      math.max(0, _frozenTo - 1),
      prep.p.length - 1,
      discsFrom: _frozenTo,
    );
    if (_pieces == 0) return [tail];
    return [
      StrokeShape(
        Path.from(_frozenPath)..addPath(tail.path, Offset.zero),
        discs: [..._frozenDiscs, ...tail.discs],
      ),
    ];
  }
}

/// Adds the half circle of a round end to [out] (without its two corner
/// points, which the edges already have): from the left corner over the
/// tip to the right one at the end ([ahead]); from right over the back to
/// left at the start.
void _cap(
  List<Offset> out,
  Offset centre,
  Offset normal,
  double radius, {
  required bool ahead,
}) {
  final forward = Offset(normal.dy, -normal.dx) * (ahead ? 1 : -1);
  final side = ahead ? normal : -normal;
  final steps = (radius * 6).ceil().clamp(8, 48);
  for (var k = 1; k < steps; k++) {
    final a = math.pi * k / steps;
    out.add(
      centre + side * (radius * math.cos(a)) + forward * (radius * math.sin(a)),
    );
  }
}

StrokeShape _dot(Offset centre, double width) => StrokeShape(
  Path()..addOval(Rect.fromCircle(center: centre, radius: width / 2)),
);

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
  bool start = true,
  bool end = true,
}) {
  bool turnsBack(Offset a, Offset b, Offset c) {
    final d1 = b - a, d2 = c - b;
    return d1.dx * d2.dx + d1.dy * d2.dy < 0;
  }

  var trimmed = 0;
  while (end &&
      trimmed < maxLiftTrim &&
      p.length > 2 &&
      (p.last - p[p.length - 2]).distance < endWidth / 3 &&
      turnsBack(p[p.length - 3], p[p.length - 2], p.last)) {
    p.removeLast();
    widths?.removeLast();
    trimmed++;
  }
  trimmed = 0;
  while (start &&
      trimmed < maxLiftTrim &&
      p.length > 2 &&
      (p[1] - p.first).distance < startWidth / 3 &&
      turnsBack(p[2], p[1], p.first)) {
    p.removeAt(0);
    widths?.removeAt(0);
    trimmed++;
  }
}

/// Whether [stroke] is drawn as a filled outline whose width follows the
/// pen (pressure and / or tilt), at any opacity. Highlighter lines and
/// lines from input without pressure stay one even width.
bool isPressureInk(StrokeItem stroke) =>
    (stroke.pressureWidth || stroke.tiltWidth) && !stroke.isHighlighter;

/// Draws one stroke the same way on every surface. [predicted]: where the
/// pen is expected to be next (drawn only, never stored). [cachedShape]:
/// [strokeShape] of the same stroke, kept by the caller.
void paintStroke(
  Canvas canvas,
  StrokeItem stroke, {
  StrokeShape? cachedShape,
  Offset? predicted,
}) {
  if (stroke.points.isEmpty) return;
  final shape = cachedShape ?? strokeShape(stroke, predicted: predicted);
  shape.paint(canvas, strokePaint(stroke, shape));
}

/// The paint [paintStroke] uses for [stroke] drawn as [shape].
Paint strokePaint(StrokeItem stroke, StrokeShape shape) {
  final paint = Paint()
    ..color = stroke.color
    ..isAntiAlias = true;
  if (!shape.filled) {
    paint
      ..strokeWidth = stroke.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
  }
  return paint;
}

/// What [paintStroke] draws for [stroke] (cacheable while the stroke, an
/// immutable object, stays the same).
StrokeShape strokeShape(StrokeItem stroke, {Offset? predicted}) {
  if (isPressureInk(stroke)) {
    return pressureShape(
      stroke.points,
      stroke.strokeWidth,
      predicted,
      stroke.pressureWidth,
      stroke.tiltWidth,
    );
  }
  final distinct = _distinct(stroke.points, predicted);
  if (distinct.length == 1) return _dot(distinct.first, stroke.strokeWidth);
  return StrokeShape(
    centreLine(stroke.points, predicted, stroke.strokeWidth),
    filled: false,
  );
}

/// Cacheable path for [stroke] (the main part of what [paintStroke] draws).
Path strokePath(StrokeItem stroke) => strokeShape(stroke).path;

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
  return deviation <= math.max(10, screenLength * 0.11) &&
      rms <= math.max(4, screenLength * 0.045) &&
      efficient <= 1.25 &&
      backtrackRatio <= 0.1 &&
      !_isDeliberateWave(points, a, b, scale);
}

/// How far (screen pixels) a swing away from the chord must reach before it
/// counts as drawn on purpose. Hand wobble stays well under this; a wave
/// someone draws goes past it.
const double waveLobeReach = 8;

/// Swings within this distance of the chord (screen pixels) are noise: they
/// never start a new lobe.
const double _waveNoise = 1.5;

/// A gentle wave and a shaky straight line can be equally close to their
/// chord and equally "long" for their length, so those measures alone
/// cannot tell them apart. What differs is the swings: wobble flips side
/// every few pixels and stays a few pixels from the line; a wave makes
/// repeated, alternating lobes that each reach well away from it. Two or
/// more alternating lobes reaching [waveLobeReach] make a wave. One long
/// bow (a slightly curved line) is still a line.
bool _isDeliberateWave(
  List<StrokePoint> points,
  Offset a,
  Offset b,
  double scale,
) {
  final d = b - a;
  final length = d.distance;
  if (length == 0) return false;
  final normal = Offset(-d.dy, d.dx) / length;
  var side = 0; // sign of the current lobe; 0 before the first
  var reach = 0.0; // furthest distance in the current lobe
  var lobes = 0; // finished-or-current lobes that reached far enough
  var lastFarSide = 0;
  void close() {
    if (side != 0 && reach >= waveLobeReach) {
      if (side != lastFarSide) lobes++;
      lastFarSide = side;
    }
  }

  for (final p in points) {
    final off = p.offset - a;
    final signed = (off.dx * normal.dx + off.dy * normal.dy) * scale;
    if (signed.abs() < _waveNoise) continue;
    final s = signed > 0 ? 1 : -1;
    if (s != side) {
      close();
      side = s;
      reach = 0;
    }
    reach = math.max(reach, signed.abs());
  }
  close();
  return lobes >= 2;
}

/// Shortest straight line (screen pixels) that a hold can produce.
const double minLineLength = 30;

/// The straight replacement for a held stroke: same start and end
/// positions, with points in between so erasing and hit-testing work along
/// its whole length. The line keeps the stroke's character: each point
/// takes the pressure (and pen angle and time) the pen had at the same
/// share of the way along the original, so a line that started light and
/// ended firm still does.
List<StrokePoint> straightened(List<StrokePoint> points) {
  final a = points.first, b = points.last;
  final length = (b.offset - a.offset).distance;
  final steps = math.max(1, (length / 6).ceil());
  final profile = StrokeProfile(points);
  return [
    for (var i = 0; i <= steps; i++)
      profile
          .at(i / steps)
          .at(a.x + (b.x - a.x) * i / steps, a.y + (b.y - a.y) * i / steps),
  ];
}

/// The clean [shape] (a recognized circle, rectangle, triangle or line)
/// carrying what the pen did along [original]: each point of the shape
/// takes the pressure, pen angle and time found at the same share of the
/// way along the original stroke. A closed shape's last stretch eases back
/// to the pressure it started with, so its outline has no step in width
/// where it closes.
List<StrokePoint> withStrokeProfile(
  List<StrokePoint> shape,
  List<StrokePoint> original,
) {
  if (shape.isEmpty || original.isEmpty) return shape;
  final along = List<double>.filled(shape.length, 0);
  for (var i = 1; i < shape.length; i++) {
    along[i] = along[i - 1] + (shape[i].offset - shape[i - 1].offset).distance;
  }
  final length = along.last;
  final profile = StrokeProfile(original);
  final closed =
      shape.length > 3 &&
      (shape.first.offset - shape.last.offset).distance < 1e-6;
  final first = original.first.pressure;
  const ease = 0.15; // the share of the outline that eases back
  return [
    for (var i = 0; i < shape.length; i++)
      () {
        final t = length <= 0 ? 0.0 : along[i] / length;
        var p = profile.at(t).at(shape[i].x, shape[i].y);
        if (closed && t > 1 - ease) {
          final k = (t - (1 - ease)) / ease;
          p = p.withPressure(p.pressure + (first - p.pressure) * k);
        }
        return p;
      }(),
  ];
}

/// What the pen did along a stroke (pressure, angle, time) by the share of
/// its length, to carry over to a cleaned-up version of the same stroke
/// (a straight line, a recognized shape).
class StrokeProfile {
  StrokeProfile(this.points) : _along = List.filled(points.length, 0) {
    var sum = 0.0;
    for (var i = 1; i < points.length; i++) {
      sum += (points[i].offset - points[i - 1].offset).distance;
      _along[i] = sum;
    }
    _length = sum;
  }

  final List<StrokePoint> points;
  final List<double> _along;
  double _length = 0;
  int _cursor = 0;

  /// The pen's sample at share [t] (0..1) of the stroke's length. The
  /// position is the original one; callers move it with [StrokePoint.at].
  /// Fastest when asked in rising order of [t].
  StrokePoint at(double t) {
    if (points.length == 1 || _length <= 0) return points.first;
    final want = t.clamp(0.0, 1.0) * _length;
    if (_along[_cursor] > want) _cursor = 0;
    while (_cursor < points.length - 2 && _along[_cursor + 1] < want) {
      _cursor++;
    }
    final from = _along[_cursor], to = _along[_cursor + 1];
    final u = to <= from ? 0.0 : ((want - from) / (to - from)).clamp(0.0, 1.0);
    return StrokePoint.lerp(points[_cursor], points[_cursor + 1], u);
  }
}
