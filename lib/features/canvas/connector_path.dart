// Geometry of a hand-drawn connector, from the pencil's own movement.
//
// The raw gesture is only the *input*. After the same pointer tracking the
// pencil drawing uses (world coordinates, so zoom and pan do not matter), it
// is cleaned in three steps, and the live preview runs the very same steps,
// so the line never jumps when the pencil lifts:
//
//  1. smoothing: a light low-pass removes the small involuntary shake;
//  2. simplification (Ramer–Douglas–Peucker, tolerance in screen pixels, so
//     it feels the same at any zoom) keeps only the points that matter;
//  3. curve fitting: a centripetal Catmull–Rom spline through those points,
//     broken at sharp turns so intentional corners stay corners.
//
// A gesture that is nearly straight stays a plain straight line (no stored
// curve at all). The stored curve is in the frame of the connector's own
// chord (start → end): `u` along it, `v` across it, both in chord lengths.
// That keeps the shape attached when either item moves, and similar when
// the distance between them changes.
//
// Pure Dart; no Flutter.
import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Most key points stored for one connector.
const connectorMaxKeys = 24;

/// A turn sharper than this (radians, ~54°) is kept as a corner.
const connectorCornerAngle = 0.95;

/// Chord shorter than this (world units) is never curved.
const connectorMinChord = 12.0;

/// Removes small jitter: duplicates closer than [minStep] are dropped and a
/// 1-2-1 average is applied twice to the interior. First and last points
/// stay exactly where they were.
List<Offset> smoothTrail(List<Offset> raw, {double minStep = 0.5}) {
  if (raw.length < 3) return List.of(raw);
  final pts = <Offset>[raw.first];
  for (var i = 1; i < raw.length - 1; i++) {
    if ((raw[i] - pts.last).distance >= minStep) pts.add(raw[i]);
  }
  pts.add(raw.last);
  var cur = pts;
  for (var pass = 0; pass < 2 && cur.length >= 3; pass++) {
    final next = List<Offset>.of(cur);
    for (var i = 1; i < cur.length - 1; i++) {
      next[i] = (cur[i - 1] + cur[i] * 2 + cur[i + 1]) / 4;
    }
    cur = next;
  }
  return cur;
}

double _lineDistance(Offset p, Offset a, Offset b) {
  final d = b - a;
  final len = d.distance;
  if (len == 0) return (p - a).distance;
  return ((p.dx - a.dx) * d.dy - (p.dy - a.dy) * d.dx).abs() / len;
}

/// Ramer–Douglas–Peucker: the fewest points that stay within [epsilon] of
/// the original path. Iterative (long gestures cannot overflow the stack).
List<Offset> simplifyTrail(List<Offset> pts, double epsilon) {
  if (pts.length < 3) return List.of(pts);
  final keep = List<bool>.filled(pts.length, false);
  keep[0] = keep[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (lo, hi) = stack.removeLast();
    var worst = -1.0;
    var at = -1;
    for (var i = lo + 1; i < hi; i++) {
      final d = _lineDistance(pts[i], pts[lo], pts[hi]);
      if (d > worst) {
        worst = d;
        at = i;
      }
    }
    if (at >= 0 && worst > epsilon) {
      keep[at] = true;
      stack.add((lo, at));
      stack.add((at, hi));
    }
  }
  return [
    for (var i = 0; i < pts.length; i++)
      if (keep[i]) pts[i],
  ];
}

/// The turn at each interior point of [pts], in radians (0 = straight on).
double _turn(Offset before, Offset at, Offset after) {
  final a = at - before, b = after - at;
  final la = a.distance, lb = b.distance;
  if (la == 0 || lb == 0) return 0;
  final c = ((a.dx * b.dx + a.dy * b.dy) / (la * lb)).clamp(-1.0, 1.0);
  return math.acos(c);
}

/// Turns a finished (or running) gesture into the connector's curve, or
/// null when a straight line says the same thing.
///
/// [trail]: the pencil's path in world coordinates, from where the gesture
/// began to where it is now. [a] and [b]: where the connector really starts
/// and ends (on the two items). [tolerance]: how far from the gesture the
/// result may be, in world units (use a few screen pixels / zoom).
///
/// Returns the interior key points in the chord frame (see the file
/// comment); the ends are implied.
List<Offset>? fitConnector(
  List<Offset> trail,
  Offset a,
  Offset b, {
  required double tolerance,
}) {
  final chord = (b - a).distance;
  if (chord < connectorMinChord || trail.length < 3) return null;
  final smooth = smoothTrail(trail);
  final pts = <Offset>[a, ...smooth.skip(1).take(smooth.length - 2), b];
  var epsilon = math.max(tolerance, chord * 0.02);
  var keys = simplifyTrail(pts, epsilon);
  while (keys.length > connectorMaxKeys + 2) {
    epsilon *= 1.5;
    keys = simplifyTrail(pts, epsilon);
  }
  var deviation = 0.0;
  for (var i = 1; i < keys.length - 1; i++) {
    deviation = math.max(deviation, _lineDistance(keys[i], a, b));
  }
  // Nearly straight: a straight line is the simplest honest geometry.
  if (deviation <= math.max(tolerance * 2, chord * 0.05)) return null;
  final dir = (b - a) / chord;
  final perp = Offset(-dir.dy, dir.dx);
  final out = <Offset>[];
  for (var i = 1; i < keys.length - 1; i++) {
    final d = keys[i] - a;
    final u = (d.dx * dir.dx + d.dy * dir.dy) / chord;
    final v = (d.dx * perp.dx + d.dy * perp.dy) / chord;
    // A scribble far outside the two items is not a connector shape.
    if (!u.isFinite || !v.isFinite || u < -0.6 || u > 1.6 || v.abs() > 2) {
      return null;
    }
    out.add(Offset(u, v));
  }
  return out.isEmpty ? null : out;
}

/// The key points of a fitted connector between [a] and [b] in world
/// coordinates, ends included (the interior ones become the connector's
/// waypoints).
List<Offset> connectorKeyPoints(Offset a, Offset b, List<Offset> keys) {
  final chord = (b - a).distance;
  if (chord == 0) return [a, b];
  final dir = (b - a) / chord;
  final perp = Offset(-dir.dy, dir.dx);
  return [
    a,
    for (final k in keys) a + dir * (k.dx * chord) + perp * (k.dy * chord),
    b,
  ];
}

/// Whether [pts] turns sharply anywhere (an intentional corner): such a line
/// is drawn with straight pieces so the corner stays a corner; a gentle one
/// is drawn as a smooth curve.
bool connectorHasCorner(List<Offset> pts) {
  for (var i = 1; i < pts.length - 1; i++) {
    if (_turn(pts[i - 1], pts[i], pts[i + 1]) > connectorCornerAngle) {
      return true;
    }
  }
  return false;
}
