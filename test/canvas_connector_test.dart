// Mind-map connections between items on the same canvas.
import 'dart:convert';

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
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

/// Connect tool drag from [from] to [to] (world == screen at scale 1).
void connect(CanvasController c, Offset from, Offset to) {
  c.tool = CanvasTool.connect;
  c.pointerDown(from);
  c.pointerMove(Offset.lerp(from, to, 0.5)!);
  c.pointerMove(to);
  c.pointerUp();
}

Iterable<ConnectorItem> lines(CanvasController c) =>
    c.items.whereType<ConnectorItem>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const aCentre = Offset(100, 40), bCentre = Offset(500, 340);

  CanvasController twoBoxes() =>
      make([box('a', Offset.zero), box('b', const Offset(400, 300))]);

  test('dragging from one item to another connects them; undo/redo', () {
    final c = twoBoxes();
    connect(c, aCentre, bCentre);
    expect(lines(c), hasLength(1));
    final line = lines(c).single;
    expect({line.fromId, line.toId}, {'a', 'b'});
    expect(c.liveConnection, isNull, reason: 'preview ends with the drag');
    c.undo();
    expect(lines(c), isEmpty);
    c.redo();
    expect(lines(c), hasLength(1));
  });

  test('no connection to empty space, to itself, or twice', () {
    final c = twoBoxes();
    connect(c, aCentre, const Offset(900, 900)); // empty space
    connect(c, aCentre, const Offset(120, 50)); // same item
    expect(lines(c), isEmpty);
    connect(c, aCentre, bCentre);
    connect(c, bCentre, aCentre); // same pair, other way round
    expect(lines(c), hasLength(1));
    connect(c, const Offset(900, 900), aCentre); // starting on nothing
    expect(lines(c), hasLength(1));
  });

  test('the line follows the items and meets their edges', () {
    final c = twoBoxes();
    connect(c, aCentre, bCentre);
    final before = c.connectorEnds(lines(c).single)!;
    expect(
      c.itemBounds(c.itemById('a')!).inflate(0.01).contains(before.$1),
      isTrue,
    );
    // Move b with the select tool.
    c.tool = CanvasTool.select;
    c.pointerDown(bCentre);
    c.pointerMove(bCentre + const Offset(0, 200));
    c.pointerUp();
    final after = c.connectorEnds(lines(c).single)!;
    expect(after.$2.dy, greaterThan(before.$2.dy + 150));
  });

  test('deleting an item removes its connections in one undo step', () {
    final c = make([
      box('a', Offset.zero),
      box('b', const Offset(400, 300)),
      box('x', const Offset(0, 600)),
    ]);
    connect(c, aCentre, bCentre);
    connect(c, aCentre, const Offset(100, 640));
    connect(c, bCentre, const Offset(100, 640));
    expect(lines(c), hasLength(3));
    c.select(['a']);
    c.deleteSelection();
    expect(c.itemById('a'), isNull);
    expect(lines(c).map((l) => {l.fromId, l.toId}), [
      {'b', 'x'},
    ]);
    c.undo();
    expect(c.itemById('a'), isNotNull);
    expect(lines(c), hasLength(3));
  });

  test('clicking the line selects only the connection; Delete removes it', () {
    final c = twoBoxes();
    connect(c, aCentre, bCentre);
    final ends = c.connectorEnds(lines(c).single)!;
    c.tool = CanvasTool.select;
    final mid = Offset.lerp(ends.$1, ends.$2, 0.5)!;
    c.pointerDown(mid);
    c.pointerUp();
    expect(c.selection, {lines(c).single.id});
    expect(c.resizeHandleAt(mid), isNull, reason: 'lines have no handle');
    c.deleteSelection();
    expect(lines(c), isEmpty);
    expect(c.itemById('a'), isNotNull);
    expect(c.itemById('b'), isNotNull);
  });

  test('duplicate and paste copy a connection only with both ends', () {
    final c = twoBoxes();
    connect(c, aCentre, bCentre);
    c.selectAll();
    c.duplicateSelection();
    expect(lines(c), hasLength(2));
    final copy = lines(c).last;
    expect(
      {copy.fromId, copy.toId}.intersection({'a', 'b'}),
      isEmpty,
      reason: 'the copy joins the copies',
    );
    expect(c.itemById(copy.fromId), isNotNull);
    expect(c.itemById(copy.toId), isNotNull);

    c.select(['a']);
    c.duplicateSelection();
    expect(lines(c), hasLength(2), reason: 'one end only: no line copied');

    c.pasteItems([...c.items], const Offset(2000, 2000));
    expect(lines(c), hasLength(4));
  });

  test('connections are saved and reload; a missing end hides the line', () {
    final c = twoBoxes();
    connect(c, aCentre, bCentre);
    final json = jsonDecode(jsonEncode(c.document.toJson()));
    final reloaded = CanvasDocument.fromJson(json as Map<String, dynamic>);
    final saved = reloaded.items.whereType<ConnectorItem>().single;
    expect({saved.fromId, saved.toId}, {'a', 'b'});

    // e.g. the other device deleted "b" and the change synced here.
    final c2 = make([...reloaded.items.where((i) => i.id != 'b')]);
    final orphan = c2.items.whereType<ConnectorItem>().single;
    expect(c2.connectorEnds(orphan), isNull);
    expect(c2.hitTest(const Offset(300, 200)), isNull);
  });
}
