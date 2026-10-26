// Alignment helpers for the Mindmap: guides and spacing marks shown while
// an object is dragged, snapping to the grid, and the explicit "align" and
// "distribute" commands. Everything here is plain geometry in canvas (world)
// units; the caller converts screen distances with the current zoom, so a
// 6-pixel snap reach is 6 pixels at any zoom.
import 'dart:math' as math;
import 'dart:ui';

/// A guide line shown while dragging: [vertical] at x = [at], from [from]
/// to [to] along the other axis.
class AlignGuide {
  const AlignGuide(this.vertical, this.at, this.from, this.to);
  final bool vertical;
  final double at;
  final double from;
  final double to;
}

/// A gap between the dragged object and its nearest neighbour.
class SpacingMark {
  const SpacingMark(this.a, this.b, this.distance);
  final Offset a;
  final Offset b;
  final double distance;
}

class SnapResult {
  const SnapResult(this.adjustment, this.guides, this.spacing);
  static const none = SnapResult(Offset.zero, [], []);

  /// How much the dragged rectangle is moved to line up (world units).
  final Offset adjustment;
  final List<AlignGuide> guides;
  final List<SpacingMark> spacing;
}

/// Where [moving] would snap to among [others].
///
/// - [guides]: edges and centres line up with those of the other objects
///   when within [reach] (world units);
/// - [grid]: on an axis where nothing lined up, the top-left corner goes to
///   the nearest multiple of [grid].
SnapResult snapMove({
  required Rect moving,
  required Iterable<Rect> others,
  required double reach,
  bool guides = true,
  double? grid,
}) {
  var dx = 0.0, dy = 0.0;
  var matchedX = false, matchedY = false;
  final list = others.toList();

  if (guides) {
    var bestX = double.infinity, bestY = double.infinity;
    for (final o in list) {
      for (final m in [moving.left, moving.center.dx, moving.right]) {
        for (final t in [o.left, o.center.dx, o.right]) {
          final d = t - m;
          if (d.abs() <= reach && d.abs() < bestX) {
            bestX = d.abs();
            dx = d;
            matchedX = true;
          }
        }
      }
      for (final m in [moving.top, moving.center.dy, moving.bottom]) {
        for (final t in [o.top, o.center.dy, o.bottom]) {
          final d = t - m;
          if (d.abs() <= reach && d.abs() < bestY) {
            bestY = d.abs();
            dy = d;
            matchedY = true;
          }
        }
      }
    }
  }
  if (grid != null && grid > 0) {
    if (!matchedX) dx = (moving.left / grid).roundToDouble() * grid - moving.left;
    if (!matchedY) dy = (moving.top / grid).roundToDouble() * grid - moving.top;
  }

  final snapped = moving.shift(Offset(dx, dy));
  final lines = <AlignGuide>[];
  if (guides) {
    const eps = 0.01;
    // Every object that now shares an edge or centre gets its guide.
    final xs = [snapped.left, snapped.center.dx, snapped.right];
    final ys = [snapped.top, snapped.center.dy, snapped.bottom];
    final seenX = <double>{}, seenY = <double>{};
    for (final o in list) {
      for (final x in xs) {
        for (final t in [o.left, o.center.dx, o.right]) {
          if ((t - x).abs() < eps && seenX.add(x.roundToDouble())) {
            final all = list.where(
              (r) => [r.left, r.center.dx, r.right].any((v) => (v - x).abs() < eps),
            );
            var top = snapped.top, bottom = snapped.bottom;
            for (final r in all) {
              top = math.min(top, r.top);
              bottom = math.max(bottom, r.bottom);
            }
            lines.add(AlignGuide(true, x, top, bottom));
          }
        }
      }
      for (final y in ys) {
        for (final t in [o.top, o.center.dy, o.bottom]) {
          if ((t - y).abs() < eps && seenY.add(y.roundToDouble())) {
            final all = list.where(
              (r) => [r.top, r.center.dy, r.bottom].any((v) => (v - y).abs() < eps),
            );
            var left = snapped.left, right = snapped.right;
            for (final r in all) {
              left = math.min(left, r.left);
              right = math.max(right, r.right);
            }
            lines.add(AlignGuide(false, y, left, right));
          }
        }
      }
    }
  }
  return SnapResult(Offset(dx, dy), lines, spacingMarks(snapped, list));
}

/// The gaps between [r] and its nearest neighbour on each side, among those
/// that overlap it on the other axis.
List<SpacingMark> spacingMarks(Rect r, Iterable<Rect> others) {
  Rect? left, right, above, below;
  for (final o in others) {
    final overlapsY = o.top < r.bottom && o.bottom > r.top;
    final overlapsX = o.left < r.right && o.right > r.left;
    if (overlapsY && o.right <= r.left) {
      if (left == null || o.right > left.right) left = o;
    }
    if (overlapsY && o.left >= r.right) {
      if (right == null || o.left < right.left) right = o;
    }
    if (overlapsX && o.bottom <= r.top) {
      if (above == null || o.bottom > above.bottom) above = o;
    }
    if (overlapsX && o.top >= r.bottom) {
      if (below == null || o.top < below.top) below = o;
    }
  }
  final out = <SpacingMark>[];
  if (left != null) {
    final y = (math.max(left.top, r.top) + math.min(left.bottom, r.bottom)) / 2;
    out.add(SpacingMark(Offset(left.right, y), Offset(r.left, y), r.left - left.right));
  }
  if (right != null) {
    final y = (math.max(right.top, r.top) + math.min(right.bottom, r.bottom)) / 2;
    out.add(SpacingMark(Offset(r.right, y), Offset(right.left, y), right.left - r.right));
  }
  if (above != null) {
    final x = (math.max(above.left, r.left) + math.min(above.right, r.right)) / 2;
    out.add(SpacingMark(Offset(x, above.bottom), Offset(x, r.top), r.top - above.bottom));
  }
  if (below != null) {
    final x = (math.max(below.left, r.left) + math.min(below.right, r.right)) / 2;
    out.add(SpacingMark(Offset(x, r.bottom), Offset(x, below.top), below.top - r.bottom));
  }
  return out;
}

/// The explicit arrange commands.
enum AlignAction {
  left,
  centerH,
  right,
  top,
  middleV,
  bottom,
  distributeH,
  distributeV,
}

extension AlignActionInfo on AlignAction {
  String get label => switch (this) {
    AlignAction.left => 'Align left edges',
    AlignAction.centerH => 'Center horizontally',
    AlignAction.right => 'Align right edges',
    AlignAction.top => 'Align top edges',
    AlignAction.middleV => 'Center vertically',
    AlignAction.bottom => 'Align bottom edges',
    AlignAction.distributeH => 'Space evenly across',
    AlignAction.distributeV => 'Space evenly down',
  };

  /// Fewest objects the command makes sense for.
  int get minimum => switch (this) {
    AlignAction.distributeH || AlignAction.distributeV => 3,
    _ => 2,
  };
}

/// How far each of [rects] moves for [action] (same order). Alignment goes
/// to the edge or centre of everything together; distributing keeps the two
/// outermost where they are and spaces the others evenly between them.
List<Offset> alignDeltas(AlignAction action, List<Rect> rects) {
  if (rects.length < action.minimum) return [for (final _ in rects) Offset.zero];
  final all = rects.reduce((a, b) => a.expandToInclude(b));
  switch (action) {
    case AlignAction.left:
      return [for (final r in rects) Offset(all.left - r.left, 0)];
    case AlignAction.right:
      return [for (final r in rects) Offset(all.right - r.right, 0)];
    case AlignAction.centerH:
      return [for (final r in rects) Offset(all.center.dx - r.center.dx, 0)];
    case AlignAction.top:
      return [for (final r in rects) Offset(0, all.top - r.top)];
    case AlignAction.bottom:
      return [for (final r in rects) Offset(0, all.bottom - r.bottom)];
    case AlignAction.middleV:
      return [for (final r in rects) Offset(0, all.center.dy - r.center.dy)];
    case AlignAction.distributeH:
      return _distribute(rects, horizontal: true);
    case AlignAction.distributeV:
      return _distribute(rects, horizontal: false);
  }
}

List<Offset> _distribute(List<Rect> rects, {required bool horizontal}) {
  final order = List<int>.generate(rects.length, (i) => i)
    ..sort((a, b) {
      final ra = rects[a], rb = rects[b];
      final c = horizontal ? ra.left.compareTo(rb.left) : ra.top.compareTo(rb.top);
      return c != 0 ? c : a.compareTo(b);
    });
  double size(Rect r) => horizontal ? r.width : r.height;
  final first = rects[order.first], last = rects[order.last];
  final start = horizontal ? first.left : first.top;
  final end = horizontal ? last.right : last.bottom;
  final total = order.fold<double>(0, (n, i) => n + size(rects[i]));
  final gap = (end - start - total) / (rects.length - 1);
  final out = List<Offset>.filled(rects.length, Offset.zero);
  var cursor = start;
  for (final i in order) {
    final r = rects[i];
    final now = horizontal ? r.left : r.top;
    out[i] = horizontal ? Offset(cursor - now, 0) : Offset(0, cursor - now);
    cursor += size(r) + gap;
  }
  return out;
}
