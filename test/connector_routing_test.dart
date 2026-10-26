// Automatic routing of connections around other objects: straight, curved
// and elbow styles, manual bends kept, endpoints attached while nodes move,
// stable routes, many obstacles, zoom levels, save/reload.
import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/connector_routing.dart';
import 'package:flutter_test/flutter_test.dart';

TextItem box(String id, Offset at, {double w = 200}) =>
    TextItem(id: id, position: at, width: w, minHeight: 80, text: id);

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

ConnectorItem auto(ConnectorStyle style) =>
    ConnectorItem(id: 'k', fromId: 'a', toId: 'b', auto: true, style: style);

bool hitsAny(List<Offset> p, Iterable<Rect> rects) {
  for (final r in rects) {
    for (var i = 0; i + 1 < p.length; i++) {
      if (segmentCrossesRect(p[i], p[i + 1], r)) return true;
    }
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // a at the left, b at the right, a tall wall (x) between them.
  CanvasController walled(ConnectorStyle style) => make([
    box('a', Offset.zero),
    box('b', const Offset(800, 0)),
    TextItem(
      id: 'x',
      position: const Offset(400, -150),
      width: 100,
      minHeight: 340,
      text: 'wall',
    ),
    auto(style),
  ]);

  Iterable<Rect> wall(CanvasController c) => [c.itemBounds(c.itemById('x')!)];

  for (final style in ConnectorStyle.values) {
    test('$style: goes around the wall, stays attached to both ends', () {
      final c = walled(style);
      final k = c.items.whereType<ConnectorItem>().single;
      final shape = c.connectorShape(k)!;
      expect(hitsAny(shape.points, wall(c)), isFalse);
      final a = c.itemBounds(c.itemById('a')!).inflate(0.5);
      final b = c.itemBounds(c.itemById('b')!).inflate(0.5);
      expect(a.contains(shape.points.first), isTrue);
      expect(b.contains(shape.points.last), isTrue);
      if (style == ConnectorStyle.orthogonal) {
        for (var i = 0; i + 1 < shape.points.length; i++) {
          final d = shape.points[i + 1] - shape.points[i];
          expect(d.dx == 0 || d.dy == 0, isTrue, reason: 'right angles only');
        }
      }
      // The drawn line is selectable where it is drawn.
      final mid = shape.points[shape.points.length ~/ 2];
      expect(c.hitTest(mid)?.id, 'k');
    });
  }

  test('nothing in the way: a straight line', () {
    final c = make([
      box('a', Offset.zero),
      box('b', const Offset(800, 0)),
      auto(ConnectorStyle.curved),
    ]);
    final shape = c.connectorShape(c.items.last as ConnectorItem)!;
    expect(shape.points, hasLength(2));
  });

  test('same diagram, same route (predictable)', () {
    final one = walled(ConnectorStyle.orthogonal);
    final two = walled(ConnectorStyle.orthogonal);
    final p1 = one.connectorPoints(one.items.last as ConnectorItem)!;
    final p2 = two.connectorPoints(two.items.last as ConnectorItem)!;
    expect(p1, p2);
    expect(one.connectorPoints(one.items.last as ConnectorItem)!, p1);
  });

  test('moving a node keeps the end attached and the route calm', () {
    final c = walled(ConnectorStyle.orthogonal);
    final k = c.items.last as ConnectorItem;
    final before = c.connectorPoints(k)!;
    c.setView(Offset.zero, 1);
    c.tool = CanvasTool.select;
    c.pointerDown(const Offset(900, 40));
    c.pointerMove(const Offset(903, 43));
    c.pointerMove(const Offset(906, 46));
    c.pointerUp();
    final after = c.connectorPoints(c.items.last as ConnectorItem)!;
    final b = c.itemBounds(c.itemById('b')!).inflate(0.5);
    expect(b.contains(after.last), isTrue);
    expect(after.length, before.length, reason: 'same route, slightly moved');
    expect(hitsAny(after, wall(c)), isFalse);
  });

  test('crowded diagram: the route avoids 30 objects', () {
    final items = <CanvasItem>[
      box('a', Offset.zero, w: 100),
      box('b', const Offset(1500, 700), w: 100),
    ];
    for (var i = 0; i < 6; i++) {
      for (var j = 0; j < 5; j++) {
        items.add(
          TextItem(
            id: 'o$i$j',
            position: Offset(220.0 + i * 220, -100.0 + j * 200),
            width: 120,
            minHeight: 80,
            text: 'o',
          ),
        );
      }
    }
    items.add(auto(ConnectorStyle.straight));
    final c = make(items);
    final pts = c.connectorPoints(items.last as ConnectorItem)!;
    final obstacles = [
      for (final i in c.items.whereType<TextItem>())
        if (i.id.startsWith('o')) c.itemBounds(i),
    ];
    expect(hitsAny(pts, obstacles), isFalse);
    expect(pts.length, greaterThan(2));
  });

  test('overlapping obstacles are one blocked area', () {
    final c = make([
      box('a', Offset.zero, w: 100),
      box('b', const Offset(900, 0), w: 100),
      TextItem(
        id: 'x1',
        position: const Offset(400, -200),
        width: 100,
        minHeight: 250,
        text: 'x',
      ),
      TextItem(
        id: 'x2',
        position: const Offset(380, 0),
        width: 140,
        minHeight: 250,
        text: 'x',
      ),
      auto(ConnectorStyle.orthogonal),
    ]);
    final pts = c.connectorPoints(c.items.last as ConnectorItem)!;
    final blocks = [
      c.itemBounds(c.itemById('x1')!),
      c.itemBounds(c.itemById('x2')!),
    ];
    expect(hitsAny(pts, blocks), isFalse);
  });

  test('manual bends survive switching to automatic and back', () {
    final c = make([
      box('a', Offset.zero),
      box('b', const Offset(800, 0)),
      const ConnectorItem(
        id: 'k',
        fromId: 'a',
        toId: 'b',
        bends: [Offset(400, -200), Offset(600, 200)],
      ),
    ]);
    c.select(const ['k']);
    c.setConnectorAuto(true);
    expect((c.items.last as ConnectorItem).bends, hasLength(2));
    c.setConnectorAuto(false);
    expect((c.items.last as ConnectorItem).bends, const [
      Offset(400, -200),
      Offset(600, 200),
    ]);
    c.undo();
    expect((c.items.last as ConnectorItem).auto, isTrue);
  });

  test('dragging an automatic line makes it manual and keeps its shape', () {
    final c = walled(ConnectorStyle.straight);
    c.setView(Offset.zero, 1);
    c.tool = CanvasTool.select;
    final k = c.items.last as ConnectorItem;
    final pts = c.connectorPoints(k)!;
    final grab = Offset.lerp(pts[0], pts[1], 0.5)!;
    c.pointerDown(grab);
    c.pointerMove(grab + const Offset(0, 6));
    c.pointerMove(grab + const Offset(0, 40));
    c.pointerUp();
    final now = c.items.last as ConnectorItem;
    expect(now.auto, isFalse);
    expect(now.bends.length, greaterThanOrEqualTo(pts.length - 1));
  });

  test('style, auto flag and bends are saved and reload; old files load', () {
    final c = make([
      box('a', Offset.zero),
      box('b', const Offset(800, 0)),
      const ConnectorItem(
        id: 'k',
        fromId: 'a',
        toId: 'b',
        style: ConnectorStyle.orthogonal,
        auto: true,
        bends: [Offset(5, 6)],
      ),
    ]);
    final back = CanvasDocument.fromJson(
      jsonDecode(jsonEncode(c.document.toJson())) as Map<String, dynamic>,
    );
    final k = back.items.whereType<ConnectorItem>().single;
    expect(k.style, ConnectorStyle.orthogonal);
    expect(k.auto, isTrue);
    expect(k.bends, [const Offset(5, 6)]);
    final old = ConnectorItem.fromJson({
      'type': 'connector',
      'id': 'k',
      'from': 'a',
      'to': 'b',
      'style': 'bogus',
    });
    expect(old.style, ConnectorStyle.curved);
    expect(old.auto, isFalse);
  });

  for (final zoom in [0.05, 1.0, 12.0]) {
    test('selecting an automatic line at zoom $zoom', () {
      final c = walled(ConnectorStyle.orthogonal);
      c.setView(Offset.zero, zoom);
      c.tool = CanvasTool.select;
      final pts = c.connectorPoints(c.items.last as ConnectorItem)!;
      final on = Offset.lerp(pts[1], pts[2], 0.5)!;
      c.pointerDown(c.toScreen(on));
      c.pointerUp();
      expect(c.selection, {'k'});
    });
  }

  test('delete and recolor still work on an automatic line', () {
    final c = walled(ConnectorStyle.curved);
    c.select(const ['k']);
    c.setConnectorColor(const Color(0xFFFF6A00));
    expect((c.items.last as ConnectorItem).color, const Color(0xFFFF6A00));
    c.deleteSelection();
    expect(c.items.whereType<ConnectorItem>(), isEmpty);
    c.undo();
    expect(c.items.whereType<ConnectorItem>(), hasLength(1));
  });
}
