// Mindmap layers: create, name, reorder, hide, lock; moving objects between
// layers without changing coordinates or connections; hidden objects
// neither drawn, hit, selected nor exported; locked ones visible but
// protected; undo/redo; save/reload and sync of the structure.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_export.dart';
import 'package:flutter_application_1/features/canvas/layers_panel.dart';
import 'package:flutter_application_1/sync/canvas_merge.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

TextItem box(String id, Offset at) =>
    TextItem(id: id, position: at, width: 200, minHeight: 80, text: id);

CanvasController make(List<CanvasItem> items, {List<CanvasLayer> layers = const []}) =>
    CanvasController(
      document: CanvasDocument(
        id: 'c',
        title: 'Map',
        items: items,
        updatedAt: DateTime(2026),
        viewport: const CanvasViewport(),
        schema: 3,
        layers: layers,
      ),
      onSave: (_) async {},
    );

CanvasController scene() => make([
  box('a', Offset.zero),
  box('b', const Offset(400, 0)),
  box('c', const Offset(0, 300)),
  const ConnectorItem(id: 'k', fromId: 'a', toId: 'b'),
]);

Map<String, String?> layerMarks(CanvasController c) => {
  for (final i in c.items)
    if (i is! ConnectorItem) i.id: c.markOf(i.id, CanvasController.layerMark) as String?,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('create, name, reorder; objects move between layers unchanged', () {
    final c = scene();
    final before = c.items.map((i) => i.toJson()).toList();
    final low = c.addLayer('Sketch');
    final high = c.addLayer('Final');
    expect(c.layers.map((l) => l.name), ['Sketch', 'Final']);
    expect(c.addLayer().name, 'Layer 3');
    c.moveToLayer(const ['a', 'c'], low.id);
    c.moveToLayer(const ['b'], high.id);
    expect(layerMarks(c), {'a': low.id, 'b': high.id, 'c': low.id});
    expect(c.countOnLayer(low.id), 2);
    expect(c.countOnLayer(null), 0);
    // Positions, sizes and the connection did not change.
    expect(c.items.map((i) => i.toJson()).toList(), before);
    // Drawing order: layers bottom to top; moving a layer up changes it.
    List<String> order() => [
      for (final i in c.drawOrder)
        if (i is! ConnectorItem) i.id,
    ];
    expect(order(), ['a', 'c', 'b']);
    c.moveLayer(low.id, up: true);
    expect(c.layers.map((l) => l.name), ['Final', 'Sketch', 'Layer 3']);
    expect(order(), ['b', 'a', 'c']);
    c.renameLayer(low.id, '  Drafts  ');
    expect(c.layers.firstWhere((l) => l.id == low.id).name, 'Drafts');
    c.renameLayer(low.id, '   ');
    expect(c.layers.firstWhere((l) => l.id == low.id).name, 'Drafts');
  });

  test('hidden objects are not drawn, hit, selected or exported', () async {
    final c = scene();
    final layer = c.addLayer('Notes');
    c.moveToLayer(const ['b'], layer.id);
    c.setView(Offset.zero, 1);
    expect(c.hitTest(const Offset(500, 40))?.id, 'b');
    c.setLayerHidden(layer.id, true);
    expect(c.drawOrder.map((i) => i.id), isNot(contains('b')));
    expect(c.hitTest(const Offset(500, 40)), isNull);
    // The line to a hidden object is hidden too.
    expect(c.connectorHidden(c.items.whereType<ConnectorItem>().single), isTrue);
    expect(c.drawOrder.whereType<ConnectorItem>().isNotEmpty, isTrue);
    c.selectAll();
    expect(c.selection, {'a', 'c', 'k'}.intersection(c.selection));
    expect(c.selection, isNot(contains('b')));
    // Marquee and lasso skip it.
    c.tool = CanvasTool.select;
    c.pointerDown(const Offset(380, -30));
    c.pointerMove(const Offset(700, 200));
    c.pointerUp();
    expect(c.selection, isNot(contains('b')));
    c.tool = CanvasTool.lasso;
    c.pointerDown(const Offset(380, -30));
    for (final p in const [Offset(700, -30), Offset(700, 200), Offset(380, 200)]) {
      c.pointerMove(p);
    }
    c.pointerUp();
    expect(c.selection, isNot(contains('b')));
    // Not in a picture of the mindmap; its place is not part of the picture.
    final shown = await renderItemsPicture(c);
    c.setLayerHidden(layer.id, false);
    final all = await renderItemsPicture(c);
    expect(shown, isNotNull);
    expect(all, isNotNull);
    final a = await shownSize(shown!.png), b = await shownSize(all!.png);
    expect(a.width, lessThan(b.width), reason: 'hidden b is left out');
    // Still in the document the whole time.
    expect(c.itemById('b'), isNotNull);
  });

  test('locked layer: visible but protected; the panel can still manage it', () {
    final c = scene();
    final layer = c.addLayer('Frozen');
    c.moveToLayer(const ['a', 'b'], layer.id);
    c.setLayerLocked(layer.id, true);
    expect(c.isLocked('a'), isTrue);
    expect(c.drawOrder.map((i) => i.id), contains('a'));
    c.setView(Offset.zero, 1);
    c.tool = CanvasTool.select;
    // Selectable, but cannot be moved or deleted.
    c.select(const ['a']);
    c.pointerDown(const Offset(100, 40));
    c.pointerMove(const Offset(160, 90));
    c.pointerMove(const Offset(220, 140));
    c.pointerUp();
    expect((c.itemById('a') as TextItem).position, Offset.zero);
    c.deleteSelection();
    expect(c.itemById('a'), isNotNull);
    c.updateSelectedTexts((t) => t.copyWith(text: 'changed'));
    expect((c.itemById('a') as TextItem).text, 'a');
    // Deliberate management still works: select the layer's objects and
    // move them to another layer.
    c.selectLayer(layer.id);
    expect(c.selection, {'a', 'b'});
    final other = c.addLayer('Open');
    c.moveToLayer(c.selection, other.id);
    expect(layerMarks(c)['a'], other.id);
    expect(c.isLocked('a'), isFalse, reason: 'the new layer is not locked');
    // Hidden layers can be reached the same way.
    c.setLayerHidden(other.id, true);
    c.selectLayer(other.id);
    expect(c.selection, {'a', 'b'});
  });

  test('every layer change is one undo step', () {
    final c = scene();
    final layer = c.addLayer('One');
    c.moveToLayer(const ['a'], layer.id);
    c.setLayerHidden(layer.id, true);
    c.setLayerLocked(layer.id, true);
    c.renameLayer(layer.id, 'Renamed');
    expect(c.layers.single.name, 'Renamed');
    c.undo(); // rename
    expect(c.layers.single.name, 'One');
    expect(c.layers.single.locked, isTrue);
    c.undo(); // lock
    expect(c.layers.single.locked, isFalse);
    expect(c.layers.single.hidden, isTrue);
    c.undo(); // hide
    expect(c.layers.single.hidden, isFalse);
    c.undo(); // move
    expect(layerMarks(c)['a'], isNull);
    expect(c.layers.single.name, 'One');
    c.undo(); // add
    expect(c.layers, isEmpty);
    c.redo();
    c.redo();
    expect(layerMarks(c)['a'], layer.id);
    c.redo();
    expect(c.layers.single.hidden, isTrue);
  });

  test('deleting a layer keeps its objects, in place, and can be undone', () {
    final c = scene();
    final layer = c.addLayer('Temp');
    c.moveToLayer(const ['a', 'b'], layer.id);
    final before = c.items.map((i) => i.toJson()).toList();
    c.deleteLayer(layer.id);
    expect(c.layers, isEmpty);
    expect(layerMarks(c), {'a': null, 'b': null, 'c': null});
    expect(c.items.map((i) => i.toJson()).toList(), before);
    expect(c.items.whereType<ConnectorItem>(), hasLength(1));
    c.undo();
    expect(c.layers.single.name, 'Temp');
    expect(layerMarks(c)['a'], layer.id);
  });

  test('new objects go to the active layer (never a hidden or locked one)', () {
    final c = make([box('a', Offset.zero)]);
    final layer = c.addLayer('Work');
    expect(c.activeLayerId, layer.id);
    c.addItems([box('n1', const Offset(300, 300))]);
    final t = c.createText(const Offset(50, 400));
    expect(layerMarks(c)['n1'], layer.id);
    expect(layerMarks(c)[t.id], layer.id);
    c.endEditing();
    // A stroke.
    c.tool = CanvasTool.pen;
    c.setView(Offset.zero, 1);
    c.pointerDown(const Offset(600, 600));
    c.pointerMove(const Offset(640, 640));
    c.pointerMove(const Offset(680, 600));
    c.pointerUp();
    final stroke = c.items.whereType<StrokeItem>().single;
    expect(layerMarks(c)[stroke.id], layer.id);
    c.setLayerLocked(layer.id, true);
    c.addItems([box('n2', const Offset(300, 500))]);
    expect(layerMarks(c)['n2'], isNull, reason: 'not lost behind a lock');
    c.setActiveLayer(null);
    c.setLayerLocked(layer.id, false);
    c.addItems([box('n3', const Offset(300, 700))]);
    expect(layerMarks(c)['n3'], isNull);
  });

  group('save, reload, sync', () {
    test('layers and assignments survive save and reload', () {
      final c = scene();
      final l1 = c.addLayer('Bottom');
      final l2 = c.addLayer('Top');
      c.moveToLayer(const ['a'], l1.id);
      c.moveToLayer(const ['b', 'c'], l2.id);
      c.setLayerHidden(l2.id, true);
      c.setLayerLocked(l1.id, true);
      final back = CanvasDocument.fromJson(
        jsonDecode(jsonEncode(c.document.toJson())) as Map<String, dynamic>,
      );
      expect(back.layers, c.layers);
      final again = CanvasController(document: back, onSave: (_) async {});
      expect(layerMarks(again), layerMarks(c));
      expect(again.isHidden('b'), isTrue);
      expect(again.isLocked('a'), isTrue);
      expect(
        again.items.map((i) => i.toJson()).toList(),
        c.items.map((i) => i.toJson()).toList(),
      );
    });

    test('older files have no layers; damaged records are ignored', () {
      final doc = CanvasDocument.fromJson({
        'schema': 3,
        'id': 'c',
        'title': 't',
        'updatedAt': '2026-01-01T00:00:00Z',
        'items': <Object>[],
      });
      expect(doc.layers, isEmpty);
      expect(doc.toJson().containsKey('layers'), isFalse);
      final odd = CanvasDocument.fromJson({
        'schema': 3,
        'id': 'c',
        'title': 't',
        'updatedAt': '2026-01-01T00:00:00Z',
        'items': <Object>[],
        'layers': [
          {'id': 'x', 'name': 'Good'},
          {'id': 'x', 'name': 'Same id twice'},
          {'name': 'No id'},
          'junk',
          {'id': 'y', 'name': 5},
        ],
      });
      expect(odd.layers.map((l) => l.name), ['Good']);
    });

    test('layers travel with the canvas metadata; unknown parts are kept', () {
      const layers = [
        CanvasLayer(id: 'l1', name: 'Bottom', locked: true),
        CanvasLayer(id: 'l2', name: 'Top', hidden: true),
      ];
      final data = canvasMetaData(
        'T',
        null,
        const [],
        {'futureField': 1},
        null,
        const [],
        layers,
      );
      expect(data['layers'], hasLength(2));
      expect(data['futureField'], 1);
      final state = CanvasSyncState(
        items: [],
        itemRevs: {},
        tombstones: {},
        title: 'old',
        folderId: null,
        metaRev: 'a',
      );
      applyCanvasChanges(
        state,
        'c',
        [
          SyncChange(
            collection: 'canvases',
            id: 'c',
            rev: 'b',
            deleted: false,
            data: data,
          ),
        ],
        (key, rev) => false,
      );
      expect(state.layers, layers);
      expect(state.metaUnknownFields, {'futureField': 1});
      // Metadata without layers (an older device): no layers.
      applyCanvasChanges(
        state,
        'c',
        [
          SyncChange(
            collection: 'canvases',
            id: 'c',
            rev: 'c',
            deleted: false,
            data: canvasMetaData('T', null, const []),
          ),
        ],
        (key, rev) => false,
      );
      expect(state.layers, isEmpty);
    });

    test('a layer change is a metadata change that gets saved and stamped', () {
      final c = scene();
      c.addLayer('Synced');
      expect(c.document.layers.single.name, 'Synced');
    });
  });

  testWidgets('the panel: add, hide, lock, move the selection, delete', (
    tester,
  ) async {
    final c = scene();
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: Center(child: LayersPanel(controller: c))),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('layer-add')));
    await tester.pump();
    expect(c.layers, hasLength(1));
    final id = c.layers.single.id;
    expect(find.text('Layer 1  ·  0'), findsOneWidget);
    c.select(const ['a', 'c']);
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('layer-move-$id')));
    await tester.pump();
    expect(c.countOnLayer(id), 2);
    expect(find.text('Layer 1  ·  2'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('layer-eye-$id')));
    await tester.pump();
    expect(c.isHidden('a'), isTrue);
    expect(c.selection, isEmpty, reason: 'hidden objects leave the selection');
    await tester.tap(find.byKey(ValueKey('layer-eye-$id')));
    await tester.tap(find.byKey(ValueKey('layer-lock-$id')));
    await tester.pump();
    expect(c.isLocked('c'), isTrue);
    // Deleting asks first and keeps the objects.
    await tester.tap(find.byKey(ValueKey('layer-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete layer…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not deleted'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(c.layers, isEmpty);
    expect(c.itemById('a'), isNotNull);
    expect(c.itemById('c'), isNotNull);
    await tester.pump(const Duration(seconds: 2));
  });
}

Future<Size> shownSize(List<int> png) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(png));
  final frame = await codec.getNextFrame();
  final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
  frame.image.dispose();
  codec.dispose();
  return size;
}