// Editable mind-map connections: bending (waypoints), color, deletion,
// following their nodes, undo/redo, save/reload and older files.
import 'dart:convert';

import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/connector_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

TextItem box(String id, Offset at) =>
    TextItem(id: id, position: at, width: 200, minHeight: 80, text: id);

CanvasController make(List<CanvasItem> items, {double scale = 1}) {
  final c = CanvasController(
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
  if (scale != 1) c.setView(Offset.zero, scale);
  return c;
}

ConnectorItem line(CanvasController c) =>
    c.items.whereType<ConnectorItem>().single;

void drag(CanvasController c, Offset from, Offset to) {
  c.pointerDown(from);
  c.pointerMove(Offset.lerp(from, to, 0.5)!);
  c.pointerMove(to);
  c.pointerUp();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CanvasController connected({double scale = 1}) => make([
    box('a', Offset.zero),
    box('b', const Offset(400, 300)),
    const ConnectorItem(id: 'k', fromId: 'a', toId: 'b'),
  ], scale: scale);

  test('whole life of a connection: bend, recolor, move, delete, undo, reload',
      () {
    final c = connected();
    c.tool = CanvasTool.select;
    // Pull the line out three times: three waypoints.
    c.select(const []);
    var pts = c.connectorPoints(line(c))!;
    final mid = Offset.lerp(pts.first, pts.last, 0.5)!;
    drag(c, mid, mid + const Offset(0, -120));
    expect(line(c).bends, hasLength(1));
    expect(c.selection, {'k'});
    final first = line(c).bends.single;
    expect(first, mid + const Offset(0, -120));
    // Move the existing waypoint by dragging its handle.
    drag(c, first, first + const Offset(60, 0));
    expect(line(c).bends.single, first + const Offset(60, 0));
    expect(line(c).bends, hasLength(1), reason: 'handle drag adds no bend');
    // Pull a second bend out of the last stretch of the curve.
    final samples = connectorSamples(c.connectorPoints(line(c))!);
    final p = samples[samples.length - 8].$1;
    drag(c, p, p + const Offset(0, 90));
    expect(line(c).bends, hasLength(2));
    expect(line(c).bends.last, p + const Offset(0, 90));

    c.setConnectorColor(InkColors.brightRed);
    expect(line(c).color, InkColors.brightRed);

    // Moving a node: the line follows, its bends stay.
    final bends = line(c).bends;
    c.select(const ['b']);
    drag(c, const Offset(500, 340), const Offset(600, 440));
    expect(c.itemById('b'), isA<TextItem>());
    expect((c.itemById('b') as TextItem).position, const Offset(500, 400));
    expect(line(c).bends, bends);
    final ends = c.connectorEnds(line(c))!;
    expect(
      c.itemBounds(c.itemById('b')!).inflate(1).contains(ends.$2),
      isTrue,
      reason: 'the end sits on the moved node',
    );

    // Delete (what Delete/Backspace does), undo, redo.
    c.select(const ['k']);
    c.deleteSelection();
    expect(c.items.whereType<ConnectorItem>(), isEmpty);
    c.undo();
    expect(line(c).bends, bends);
    expect(line(c).color, InkColors.brightRed);
    c.redo();
    expect(c.items.whereType<ConnectorItem>(), isEmpty);
    c.undo();

    // Save and reload.
    final json = jsonDecode(jsonEncode(c.document.toJson()));
    final back = CanvasDocument.fromJson(json as Map<String, dynamic>);
    final reloaded = back.items.whereType<ConnectorItem>().single;
    expect(reloaded.bends, bends);
    expect(reloaded.color, InkColors.brightRed);
    expect(reloaded.fromId, 'a');
    expect(reloaded.toId, 'b');
  });

  test('older files without color or bends still load as straight lines', () {
    final c = ConnectorItem.fromJson({
      'type': 'connector',
      'id': 'k',
      'from': 'a',
      'to': 'b',
    });
    expect(c.color, isNull);
    expect(c.bends, isEmpty);
    expect(c.toJson().containsKey('bends'), isFalse);
    expect(c.toJson().containsKey('color'), isFalse);
    // Damaged waypoints are ignored, not fatal.
    final d = ConnectorItem.fromJson({
      'type': 'connector',
      'id': 'k',
      'from': 'a',
      'to': 'b',
      'bends': [
        [1, 2],
        'junk',
        [double.nan, 3],
      ],
    });
    expect(d.bends, [const Offset(1, 2)]);
  });

  for (final scale in [0.05, 0.5, 1.0, 8.0]) {
    test('selecting the line works at zoom $scale', () {
      final c = connected(scale: scale);
      c.tool = CanvasTool.select;
      final pts = c.connectorPoints(line(c))!;
      // A point on the line, a few screen pixels off it.
      final on = Offset.lerp(pts.first, pts.last, 0.5)!;
      final screen = c.toScreen(on);
      c.select(const []);
      c.pointerDown(screen + const Offset(0, 3));
      c.pointerUp();
      expect(c.selection, {'k'});
      // Far from everything: deselects instead of picking the line.
      c.pointerDown(screen + const Offset(300, -300));
      c.pointerUp();
      expect(c.selection, isNot(contains('k')));
    });
  }

  test('removing a bend and straightening are undoable', () {
    final c = connected();
    final k = line(c).copyWith(
      bends: [const Offset(200, 0), const Offset(300, 200)],
    );
    final d = make([
      box('a', Offset.zero),
      box('b', const Offset(400, 300)),
      k,
    ]);
    d.removeBend('k', 0);
    expect(line(d).bends, [const Offset(300, 200)]);
    d.undo();
    expect(line(d).bends, hasLength(2));
    d.select(const ['k']);
    d.straightenSelectedConnectors();
    expect(line(d).bends, isEmpty);
    d.undo();
    expect(line(d).bends, hasLength(2));
  });

  test('moving both nodes together keeps the bent shape', () {
    final d = make([
      box('a', Offset.zero),
      box('b', const Offset(400, 300)),
      const ConnectorItem(
        id: 'k',
        fromId: 'a',
        toId: 'b',
        bends: [Offset(200, 0)],
      ),
    ]);
    d.select(const ['a', 'b']);
    drag(d, const Offset(100, 40), const Offset(150, 90));
    expect(line(d).bends.single, const Offset(250, 50));
  });
}
