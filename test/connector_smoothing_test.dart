// The connection tool follows the pencil and refines the result.
// Acceptance criteria:
//  1. A shaky, nearly straight gesture becomes a plain straight line (no
//     stored curve); an intentional curve stays a curve, a sharp turn stays
//     a corner, and the result is never further from the gesture than a few
//     screen pixels.
//  2. The live preview is the same geometry that is stored when the pencil
//     lifts: nothing jumps on release.
//  3. The line stays attached to both items (their edges) and keeps its
//     shape when an item moves; select, delete, copy, colour-less
//     persistence, undo and redo all keep working.
//  4. Tap-tap connections, short gestures and gestures that end on nothing
//     behave as before (straight / none); nothing snaps to other items.
//  5. Zoomed canvases give the same result in world terms; slow, fast,
//     short and long gestures all work; fitting stays fast.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/connector_geometry.dart';
import 'package:flutter_application_1/features/canvas/connector_path.dart';
import 'package:flutter_test/flutter_test.dart';

TextItem box(String id, Offset at) =>
    TextItem(id: id, position: at, width: 200, minHeight: 80, text: id);

CanvasController make(List<CanvasItem> items) => CanvasController(
  document: CanvasDocument(
    id: 'c',
    title: 'Map',
    items: items,
    updatedAt: DateTime(2026),
    viewport: const CanvasViewport(),
    schema: 3,
  ),
  onSave: (_) async {},
);

Iterable<ConnectorItem> lines(CanvasController c) =>
    c.items.whereType<ConnectorItem>();

const aCentre = Offset(100, 40), bCentre = Offset(500, 340);

CanvasController twoBoxes() =>
    make([box('a', Offset.zero), box('b', const Offset(400, 300))]);

/// Points from [a] to [b] bulging sideways by [bulge] in the middle.
List<Offset> arc(Offset a, Offset b, double bulge, int n, {double shake = 0}) {
  final rnd = math.Random(7);
  final d = b - a;
  final dir = d / d.distance;
  final perp = Offset(dir.dy, -dir.dx);
  return [
    for (var i = 0; i <= n; i++)
      () {
        final t = i / n;
        final jitter = i == 0 || i == n
            ? Offset.zero
            : Offset(
                (rnd.nextDouble() - 0.5) * 2 * shake,
                (rnd.nextDouble() - 0.5) * 2 * shake,
              );
        return a + d * t + perp * (bulge * math.sin(math.pi * t)) + jitter;
      }(),
  ];
}

void drag(CanvasController c, List<Offset> screenPath) {
  c.tool = CanvasTool.connect;
  c.pointerDown(screenPath.first);
  for (final p in screenPath.skip(1)) {
    c.pointerMove(p);
  }
  c.pointerUp();
}

/// The smooth line through a fitted connector's key points.
List<Offset> sampleConnector(Offset a, Offset b, List<Offset> keys) => [
  for (final (p, _) in connectorSamples(connectorKeyPoints(a, b, keys))) p,
];

double distanceToPolyline(Offset p, List<Offset> pts) {
  var best = double.infinity;
  for (var i = 0; i < pts.length - 1; i++) {
    best = math.min(best, distanceToSegment(p, pts[i], pts[i + 1]));
  }
  return best;
}

/// The points a connector is drawn through, as sampled.
List<Offset> drawn(CanvasController c, ConnectorItem line) {
  final shape = c.connectorShape(line)!;
  return shape.smooth
      ? [for (final (p, _) in connectorSamples(shape.points)) p]
      : shape.points;
}

/// How far the sampled line strays from the original gesture.
double maxStray(List<Offset> line, List<Offset> gesture) {
  var worst = 0.0;
  for (final p in line) {
    worst = math.max(worst, distanceToPolyline(p, gesture));
  }
  return worst;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('geometry', () {
    const a = Offset(0, 0), b = Offset(400, 0);

    test('a shaky, nearly straight gesture stays straight', () {
      final trail = arc(a, b, 0, 80, shake: 2.5);
      expect(fitConnector(trail, a, b, tolerance: 3), isNull);
      // A slight, unintended drift too.
      expect(fitConnector(arc(a, b, 8, 80, shake: 2), a, b, tolerance: 3), isNull);
    });

    test('an intentional curve stays a curve, close to the gesture', () {
      final trail = arc(a, b, 90, 60, shake: 1.5);
      final keys = fitConnector(trail, a, b, tolerance: 3)!;
      expect(keys.length, inInclusiveRange(1, connectorMaxKeys));
      final line = sampleConnector(a, b, keys);
      expect(line.first, a);
      expect(line.last, b);
      expect(maxStray(line, trail), lessThan(10));
      // It really bulges the same way, by about as much.
      final top = line.map((p) => p.dy.abs()).reduce(math.max);
      expect(top, closeTo(90, 12));
    });

    test('the line is smoother than the shaky input', () {
      final trail = arc(a, b, 90, 120, shake: 4);
      final keys = fitConnector(trail, a, b, tolerance: 3)!;
      final line = sampleConnector(a, b, keys);
      double roughness(List<Offset> p) {
        var sum = 0.0;
        for (var i = 1; i < p.length - 1; i++) {
          final d2 = p[i - 1] - p[i] * 2 + p[i + 1];
          sum += d2.distance;
        }
        return sum / p.length;
      }

      expect(roughness(line), lessThan(roughness(trail) / 3));
    });

    test('a sharp turn stays a corner', () {
      final trail = [
        for (var i = 0; i <= 20; i++) Offset(i * 10.0, 0),
        for (var i = 1; i <= 20; i++) Offset(200, i * 10.0),
      ];
      const end = Offset(200, 200);
      final keys = fitConnector(trail, a, end, tolerance: 3)!;
      final pts = connectorKeyPoints(a, end, keys);
      expect(connectorHasCorner(pts), isTrue);
      final line = pts; // a corner is drawn with straight pieces
      expect(maxStray(line, trail), lessThan(6));
      // Something on the line is right at the corner.
      expect(
        line.map((p) => (p - const Offset(200, 0)).distance).reduce(math.min),
        lessThan(6),
      );
    });

    test('short gestures and tiny chords are never curved', () {
      expect(fitConnector([a, b], a, b, tolerance: 3), isNull);
      expect(fitConnector([a, const Offset(2, 3), const Offset(4, 0)], a, const Offset(4, 0), tolerance: 3), isNull);
    });

    test('a scribble far from the two items is not a connector', () {
      final scribble = arc(a, b, 1200, 40);
      expect(fitConnector(scribble, a, b, tolerance: 3), isNull);
    });

    test('the same gesture zoomed gives the same shape', () {
      final base = arc(a, b, 90, 60, shake: 1);
      final k1 = fitConnector(base, a, b, tolerance: 3)!;
      // Zoom 2x: world points are the same; only the tolerance (screen
      // pixels / zoom) halves.
      final k2 = fitConnector(base, a, b, tolerance: 1.5)!;
      final l1 = sampleConnector(a, b, k1), l2 = sampleConnector(a, b, k2);
      expect(maxStray(l1, l2), lessThan(8));
    });

    test('the stored shape follows the ends when they move', () {
      final keys = fitConnector(arc(a, b, 90, 60), a, b, tolerance: 3)!;
      final moved = sampleConnector(const Offset(0, 100), const Offset(400, 500), keys);
      expect(moved.first, const Offset(0, 100));
      expect(moved.last, const Offset(400, 500));
      // Twice as far apart: twice the bulge.
      final wide = sampleConnector(a, const Offset(800, 0), keys);
      final top1 = sampleConnector(a, b, keys).map((p) => p.dy.abs()).reduce(math.max);
      final top2 = wide.map((p) => p.dy.abs()).reduce(math.max);
      expect(top2, closeTo(top1 * 2, 6));
    });

    test('long gestures are fast', () {
      final trail = arc(a, b, 90, 5000, shake: 2);
      final t = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        fitConnector(trail, a, b, tolerance: 3);
      }
      expect(t.elapsedMilliseconds / 20, lessThan(40));
    });
  });

  group('saving', () {
    test('a hand-drawn connector round-trips; straight ones stay plain', () {
      final curved = ConnectorItem(
        id: 'k',
        fromId: 'a',
        toId: 'b',
        bends: const [Offset(120, 40), Offset(260, 90)],
      );
      final back = ConnectorItem.fromJson(
        jsonDecode(jsonEncode(curved.toJson())) as Map<String, dynamic>,
      );
      expect(back.bends, curved.bends);
      const straight = ConnectorItem(id: 's', fromId: 'a', toId: 'b');
      expect(straight.toJson().containsKey('bends'), isFalse);
    });
  });

  group('the tool', () {
    test('a curved drag stores a clean curve, attached to both edges', () {
      final c = twoBoxes();
      drag(c, arc(aCentre, bCentre, 120, 70, shake: 1.5));
      final line = lines(c).single;
      expect({line.fromId, line.toId}, {'a', 'b'});
      expect(line.bends, isNotEmpty);
      final ends = c.connectorEnds(line)!;
      expect(c.itemBounds(c.itemById('a')!).inflate(0.01).contains(ends.$1), isTrue);
      expect(c.itemBounds(c.itemById('b')!).inflate(0.01).contains(ends.$2), isTrue);
      final path = drawn(c, line);
      expect(path.first, ends.$1);
      expect(path.last, ends.$2);
    });

    test('a nearly straight drag stays a plain straight connector', () {
      final c = twoBoxes();
      drag(c, arc(aCentre, bCentre, 0, 60, shake: 2));
      expect(lines(c).single.bends, isEmpty);
    });

    test('the live preview is the stored geometry: no jump on release', () {
      final c = twoBoxes();
      final trail = arc(aCentre, bCentre, 120, 70, shake: 1.5);
      c.tool = CanvasTool.connect;
      c.pointerDown(trail.first);
      for (final p in trail.skip(1)) {
        c.pointerMove(p);
      }
      final live = c.livePreview!;
      c.pointerUp();
      final stored = c.connectorShape(lines(c).single)!;
      expect(stored.smooth, live.smooth);
      expect(stored.points.length, live.points.length);
      for (var i = 0; i < live.points.length; i++) {
        expect((stored.points[i] - live.points[i]).distance, lessThan(0.001));
      }
      expect(c.livePreview, isNull, reason: 'preview ends with the gesture');
    });

    test('while moving, the preview follows the pencil to its tip', () {
      final c = twoBoxes();
      final trail = arc(aCentre, bCentre, 120, 70);
      c.tool = CanvasTool.connect;
      c.pointerDown(trail.first);
      for (final p in trail.skip(1).take(30)) {
        c.pointerMove(p);
      }
      final tip = trail[30];
      final live = c.livePreview;
      final end = live == null ? c.liveConnection!.$2 : live.points.last;
      expect((end - tip).distance, lessThan(0.5));
      c.pointerUp();
    });

    test('the curve keeps its shape and attachment when an item moves', () {
      final c = twoBoxes();
      drag(c, arc(aCentre, bCentre, 120, 70));
      final line = lines(c).single;
      c.select(['b']);
      c.tool = CanvasTool.select;
      c.pointerDown(bCentre);
      c.pointerMove(bCentre + const Offset(0, 200));
      c.pointerUp();
      final ends = c.connectorEnds(line)!;
      final path = drawn(c, c.items.whereType<ConnectorItem>().single);
      expect(path.last, ends.$2);
      expect(c.itemBounds(c.itemById('b')!).inflate(0.01).contains(ends.$2), isTrue);
      expect(lines(c).single.bends, line.bends);
    });

    test('undo, redo, delete and copy keep the curve', () {
      final c = twoBoxes();
      drag(c, arc(aCentre, bCentre, 120, 70));
      final bends = lines(c).single.bends;
      c.undo();
      expect(lines(c), isEmpty);
      c.redo();
      expect(lines(c).single.bends, bends);
      // Copy both boxes: the connection between them is copied with its curve.
      final copied = CanvasController.copyItems([
        c.itemById('a')!,
        c.itemById('b')!,
        lines(c).single,
      ], const Offset(24, 24)).$1;
      expect(copied.whereType<ConnectorItem>().single.bends, isNotEmpty);
      c.addItems(copied);
      expect(lines(c), hasLength(2));
      expect(lines(c).every((l) => l.bends.isNotEmpty), isTrue);
      // Delete one end: its connection goes with it.
      c.select(['a']);
      c.deleteSelection();
      expect(lines(c), hasLength(1));
    });

    test('the curved line can be hit where it really is', () {
      final c = twoBoxes();
      drag(c, arc(aCentre, bCentre, 150, 70));
      final line = lines(c).single;
      final path = drawn(c, line);
      final mid = path[path.length ~/ 2];
      expect(c.hitTest(mid), same(line));
      // The straight chord's middle is far from the curve now.
      final chordMid = Offset.lerp(aCentre, bCentre, 0.5)!;
      expect(c.hitTest(chordMid), isNot(same(line)));
    });

    test('tap-tap connections and gestures that end on nothing', () {
      final c = twoBoxes();
      c.tool = CanvasTool.connect;
      c.pointerDown(aCentre);
      c.pointerUp(); // source chosen
      c.pointerDown(bCentre);
      c.pointerUp();
      expect(lines(c).single.bends, isEmpty);
      final d = twoBoxes();
      drag(d, arc(aCentre, const Offset(900, 900), 100, 40));
      expect(lines(d), isEmpty);
    });

    test('never snaps to an item the pencil only passed over', () {
      final c = make([
        box('a', Offset.zero),
        box('b', const Offset(400, 300)),
        box('m', const Offset(250, 120)),
      ]);
      // The bulge goes right across 'm'; the pencil lifts on 'b'.
      drag(c, arc(aCentre, bCentre, -140, 70));
      expect(lines(c), hasLength(1));
      expect({lines(c).single.fromId, lines(c).single.toId}, {'a', 'b'});
    });

    test('a zoomed and panned canvas gives the same connection', () {
      final c = twoBoxes();
      c.setView(const Offset(-30, 20), 2);
      final world = arc(aCentre, bCentre, 120, 70, shake: 1);
      drag(c, [for (final w in world) c.toScreen(w)]);
      final line = lines(c).single;
      expect(line.bends, isNotEmpty);
      final path = drawn(c, line);
      // Away from the two items (where the line leaves the chord's edge
      // points) it still follows the gesture, in world units.
      final middle = [
        for (final p in path)
          if ((p - path.first).distance > 90 && (p - path.last).distance > 90) p,
      ];
      expect(middle, isNotEmpty);
      expect(maxStray(middle, world), lessThan(14));
    });

    test('slow, fast, short and long gestures', () {
      for (final n in [2, 3, 6, 40, 400]) {
        final c = twoBoxes();
        drag(c, arc(aCentre, bCentre, 100, n, shake: n > 20 ? 1.5 : 0));
        expect(lines(c), hasLength(1), reason: '$n samples');
      }
      // A very short hop between two touching items is still allowed.
      final c = make([box('a', Offset.zero), box('b', const Offset(205, 0))]);
      drag(c, [const Offset(190, 40), const Offset(215, 40)]);
      expect(lines(c), hasLength(1));
      expect(lines(c).single.bends, isEmpty);
    });
  });
}
