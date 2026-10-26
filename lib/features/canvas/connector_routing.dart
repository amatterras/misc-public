// Automatic routing of mind-map connections around the other objects.
//
// The route is found on the grid made by the obstacles' (inflated) edges and
// the two ends, with A*: shortest length plus a fixed price per bend, and a
// fixed order of neighbours, so the same diagram always gives the same
// route (no flicker while an object is dragged: the route only changes when
// an obstacle really gets in the way or out of it). Elbow ("orthogonal")
// routes use the grid as it is; straight and curved routes pull the same
// path tight around the corners of the obstacles.
import 'dart:math' as math;
import 'dart:ui';

/// Space kept between a route and the objects it goes around.
const routeMargin = 14.0;

/// Price of one bend, in length units: prefers a few long runs.
const _bendPrice = 36.0;

bool _inside(Rect r, Offset p) =>
    p.dx > r.left && p.dx < r.right && p.dy > r.top && p.dy < r.bottom;

/// Whether the segment a→b passes through the inside of [r].
bool segmentCrossesRect(Offset a, Offset b, Rect r) {
  if (_inside(r, a) || _inside(r, b)) return true;
  // Liang-Barsky against the open rectangle.
  var t0 = 0.0, t1 = 1.0;
  final d = b - a;
  bool clip(double p, double q) {
    if (p == 0) return q > 0;
    final t = q / p;
    if (p < 0) {
      if (t > t1) return false;
      if (t > t0) t0 = t;
    } else {
      if (t < t0) return false;
      if (t < t1) t1 = t;
    }
    return true;
  }

  const e = 1e-6;
  final ok =
      clip(-d.dx, a.dx - r.left - e) &&
      clip(d.dx, r.right - e - a.dx) &&
      clip(-d.dy, a.dy - r.top - e) &&
      clip(d.dy, r.bottom - e - a.dy);
  return ok && t1 - t0 > 1e-9;
}

/// The path from [from] to [to] around [obstacles]: the corner points
/// including both ends. Straight when nothing is in the way. With
/// [orthogonal] every piece is horizontal or vertical; otherwise the path
/// is pulled tight (any angle) around the obstacles' corners.
List<Offset> routeAround(
  Offset from,
  Offset to,
  List<Rect> obstacles, {
  bool orthogonal = false,
  double margin = routeMargin,
}) {
  // An object an end already touches gets no margin there (else the end
  // would start inside its own keep-out zone); an object the end is inside
  // of is ignored.
  final zones = <Rect>[];
  for (final o in obstacles) {
    var z = o.inflate(margin);
    if (_inside(z, from) || _inside(z, to)) z = o.inflate(1);
    if (_inside(z, from) || _inside(z, to)) continue;
    zones.add(z);
  }

  if (!orthogonal && !zones.any((z) => segmentCrossesRect(from, to, z))) {
    return [from, to];
  }
  final path = _gridRoute(from, to, zones, orthogonal);
  return orthogonal ? path : _pullTight(path, zones);
}

/// An elbow path between [from] and [to] with nothing in the way: one
/// bend, leaving horizontally when the horizontal distance is larger.
List<Offset> elbow(Offset from, Offset to) {
  if (from.dx == to.dx || from.dy == to.dy) return [from, to];
  final horizontalFirst = (to.dx - from.dx).abs() >= (to.dy - from.dy).abs();
  final corner = horizontalFirst
      ? Offset(to.dx, from.dy)
      : Offset(from.dx, to.dy);
  return [from, corner, to];
}

List<Offset> _gridRoute(
  Offset from,
  Offset to,
  List<Rect> zones,
  bool orthogonal,
) {
  final xs = <double>{from.dx, to.dx};
  final ys = <double>{from.dy, to.dy};
  for (final z in zones) {
    xs
      ..add(z.left)
      ..add(z.right);
    ys
      ..add(z.top)
      ..add(z.bottom);
  }
  final gx = xs.toList()..sort();
  final gy = ys.toList()..sort();
  final nx = gx.length, ny = gy.length;
  final startI = gx.indexOf(from.dx), startJ = gy.indexOf(from.dy);
  final endI = gx.indexOf(to.dx), endJ = gy.indexOf(to.dy);

  bool free(double x, double y) {
    final p = Offset(x, y);
    for (final z in zones) {
      if (_inside(z, p)) return false;
    }
    return true;
  }

  final ok = List.generate(
    nx,
    (i) => List.generate(ny, (j) => free(gx[i], gy[j])),
  );
  ok[startI][startJ] = true;
  ok[endI][endJ] = true;

  // State = (i, j, direction 0..3 right, down, left, up) - fixed order.
  const di = [1, 0, -1, 0], dj = [0, 1, 0, -1];
  int id(int i, int j, int d) => (i * ny + j) * 4 + d;
  final total = nx * ny * 4;
  final cost = List<double>.filled(total, double.infinity);
  final prev = List<int>.filled(total, -1);
  final heap = <(double, int, int)>[]; // (f, order, state)
  var order = 0;

  void push((double, int, int) e) {
    heap.add(e);
    var k = heap.length - 1;
    while (k > 0) {
      final parent = (k - 1) ~/ 2;
      if (_less(heap[k], heap[parent])) {
        final t = heap[k];
        heap[k] = heap[parent];
        heap[parent] = t;
        k = parent;
      } else {
        break;
      }
    }
  }

  (double, int, int) pop() {
    final top = heap.first;
    final last = heap.removeLast();
    if (heap.isNotEmpty) {
      heap[0] = last;
      var k = 0;
      while (true) {
        final l = 2 * k + 1, r = l + 1;
        var m = k;
        if (l < heap.length && _less(heap[l], heap[m])) m = l;
        if (r < heap.length && _less(heap[r], heap[m])) m = r;
        if (m == k) break;
        final t = heap[k];
        heap[k] = heap[m];
        heap[m] = t;
        k = m;
      }
    }
    return top;
  }

  double h(int i, int j) => (gx[i] - gx[endI]).abs() + (gy[j] - gy[endJ]).abs();

  for (var d = 0; d < 4; d++) {
    final s = id(startI, startJ, d);
    cost[s] = 0;
    push((h(startI, startJ), order++, s));
  }

  var goal = -1;
  while (heap.isNotEmpty) {
    final s = pop().$3;
    final d = s % 4;
    final cell = s ~/ 4;
    final i = cell ~/ ny, j = cell % ny;
    if (i == endI && j == endJ) {
      goal = s;
      break;
    }
    for (var nd = 0; nd < 4; nd++) {
      final ni = i + di[nd], nj = j + dj[nd];
      if (ni < 0 || nj < 0 || ni >= nx || nj >= ny) continue;
      if (!ok[ni][nj]) continue;
      // The piece between the two grid points must be free in its middle.
      if (!free((gx[i] + gx[ni]) / 2, (gy[j] + gy[nj]) / 2)) continue;
      final len = (gx[ni] - gx[i]).abs() + (gy[nj] - gy[j]).abs();
      final turn = (i == startI && j == startJ) || nd == d ? 0.0 : _bendPrice;
      final c = cost[s] + len + turn;
      final t = id(ni, nj, nd);
      if (c < cost[t] - 1e-9) {
        cost[t] = c;
        prev[t] = s;
        push((c + h(ni, nj), order++, t));
      }
    }
  }
  if (goal < 0) return orthogonal ? elbow(from, to) : [from, to];

  final pts = <Offset>[];
  for (var s = goal; s >= 0; s = prev[s]) {
    final cell = s ~/ 4;
    pts.add(Offset(gx[cell ~/ ny], gy[cell % ny]));
  }
  final path = pts.reversed.toList();
  // Drop points in the middle of a straight run.
  final out = <Offset>[path.first];
  for (var k = 1; k < path.length - 1; k++) {
    final a = out.last, b = path[k], c = path[k + 1];
    final straight =
        (a.dx == b.dx && b.dx == c.dx) || (a.dy == b.dy && b.dy == c.dy);
    if (!straight) out.add(b);
  }
  out.add(path.last);
  return out;
}

bool _less((double, int, int) a, (double, int, int) b) =>
    a.$1 != b.$1 ? a.$1 < b.$1 : a.$2 < b.$2;

/// Pulls [path] tight: skips corners the line can cut without entering a
/// zone. Greedy from the start, so the result is predictable.
List<Offset> _pullTight(List<Offset> path, List<Rect> zones) {
  if (path.length <= 2) return path;
  final out = <Offset>[path.first];
  var i = 0;
  while (i < path.length - 1) {
    var j = path.length - 1;
    while (j > i + 1 &&
        zones.any((z) => segmentCrossesRect(path[i], path[j], z))) {
      j--;
    }
    out.add(path[j]);
    i = j;
  }
  return out;
}

/// Replaces [pts] by an elbow path through them: every piece is horizontal
/// or vertical, bending once between neighbouring points.
List<Offset> orthogonalize(List<Offset> pts) {
  if (pts.length < 2) return pts;
  final out = <Offset>[pts.first];
  for (var i = 0; i + 1 < pts.length; i++) {
    out.addAll(elbow(pts[i], pts[i + 1]).skip(1));
  }
  final clean = <Offset>[out.first];
  for (var k = 1; k < out.length; k++) {
    if ((out[k] - clean.last).distance < 1e-9) continue;
    clean.add(out[k]);
  }
  return clean;
}

/// Where the path leaves [box] (its first/last point is inside it): the
/// part inside is cut off and the line starts on the edge. [atStart] false
/// trims the end. Null if the path never leaves the box.
List<Offset>? trimInside(
  List<Offset> path,
  Rect box, {
  required bool atStart,
}) {
  final p = atStart ? path : path.reversed.toList();
  for (var k = 1; k < p.length; k++) {
    if (_inside(box, p[k])) continue;
    final cut = _exit(p[k - 1], p[k], box);
    final res = [cut, ...p.skip(k)];
    if (res.length > 2 && (res[0] - res[1]).distance < 1e-6) res.removeAt(0);
    return atStart ? res : res.reversed.toList();
  }
  return null;
}

/// The point where a→b (a inside [box]) leaves it.
Offset _exit(Offset a, Offset b, Rect box) {
  final d = b - a;
  var t = 1.0;
  if (d.dx > 0) t = math.min(t, (box.right - a.dx) / d.dx);
  if (d.dx < 0) t = math.min(t, (box.left - a.dx) / d.dx);
  if (d.dy > 0) t = math.min(t, (box.bottom - a.dy) / d.dy);
  if (d.dy < 0) t = math.min(t, (box.top - a.dy) / d.dy);
  return a + d * t.clamp(0.0, 1.0);
}
