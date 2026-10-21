import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasController make({
  List<CanvasItem> items = const [],
  CanvasViewport? view,
  int schema = 2,
}) {
  return CanvasController(
    document: CanvasDocument(
      id: 'c1',
      title: 'Test',
      items: items,
      updatedAt: DateTime(2026),
      viewport: view ?? const CanvasViewport(),
      schema: schema,
    ),
    onSave: (_) async {},
    saveDelay: const Duration(milliseconds: 5),
  );
}

TextItem note(String id, Offset at, {String text = 'x'}) =>
    TextItem(id: id, position: at, width: 200, minHeight: 40, text: text);

CanvasDocument roundTrip(CanvasDocument doc) => CanvasDocument.fromJson(
  jsonDecode(jsonEncode(doc.toJson())) as Map<String, dynamic>,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('there is no limit on the number of notes (500 created)', () {
    final c = make();
    for (var i = 0; i < 500; i++) {
      c.createText(Offset(i * 300.0, (i % 20) * 120.0));
      c.updateEditingText('Note $i');
      c.endEditing();
    }
    expect(c.items, hasLength(500));
    final restored = roundTrip(c.document);
    expect(restored.items, hasLength(500));
    expect((restored.items.last as TextItem).text, 'Note 499');
  });

  test('note styling persists: size, bold, italic, alignment, colours', () {
    final c = make(items: [note('a', Offset.zero)])..select(['a']);
    c.setFontSize(32);
    c.updateSelectedTexts(
      (t) => t.copyWith(
        bold: true,
        italic: true,
        align: TextAlignment.center,
        textColor: () => const Color(0xFFE76F51),
        background: () => const Color(0xFF35A99A),
      ),
    );
    final t = roundTrip(c.document).items.single as TextItem;
    expect(t.fontSize, 32);
    expect(t.bold, isTrue);
    expect(t.italic, isTrue);
    expect(t.align, TextAlignment.center);
    expect(t.textColor, const Color(0xFFE76F51));
    expect(t.background, const Color(0xFF35A99A));
    c.undo();
    expect((c.items.single as TextItem).background, isNull);
  });

  test('duplicate makes independent copies and is undoable', () {
    final c = make(items: [note('a', Offset.zero, text: 'hi')])..select(['a']);
    c.duplicateSelection();
    expect(c.items, hasLength(2));
    expect(c.items[1].id, isNot('a'));
    expect((c.items[1] as TextItem).text, 'hi');
    expect((c.items[1] as TextItem).position, const Offset(24, 24));
    expect(c.selection, {c.items[1].id});
    c.undo();
    expect(c.items, hasLength(1));
  });

  test('copy/paste of canvas items creates new copies at the target', () {
    final c = make(
      items: [note('a', Offset.zero), note('b', const Offset(300, 0))],
    );
    c.pasteItems(c.items, const Offset(1000, 1000));
    expect(c.items, hasLength(4));
    final pasted = c.items.skip(2).toList();
    expect(pasted.map((i) => i.id), isNot(contains('a')));
    final bounds = pasted
        .map((i) => i.bounds)
        .reduce((x, y) => x.expandToInclude(y));
    expect(bounds.center.dx, closeTo(1000, 0.001));
  });

  test('images, links and note cards persist with position and size', () {
    final c = make();
    final now = DateTime(2026);
    final img = Asset(
      id: 'img',
      kind: AssetKind.image,
      file: 'p.png',
      width: 1600,
      height: 900,
      createdAt: now,
      updatedAt: now,
    );
    final image = c.insertImage(img, const Offset(5000, -3000));
    expect(image.width, closeTo(480, 0.001));
    expect(image.height, closeTo(270, 0.001));
    final link = Asset(
      id: 'lnk',
      kind: AssetKind.link,
      url: 'https://example.com',
      createdAt: now,
      updatedAt: now,
    );
    c.insertLink(link, const Offset(-8000, 200));
    c.insertNoteCard('note-1', const Offset(0, 9000));

    final items = roundTrip(c.document).items;
    expect(items[0], isA<ImageItem>().having((i) => i.assetId, 'asset', 'img'));
    expect((items[0] as ImageItem).position, image.position);
    expect(items[1], isA<LinkItem>().having((i) => i.assetId, 'asset', 'lnk'));
    expect(
      items[2],
      isA<NoteCardItem>().having((i) => i.noteId, 'note', 'note-1'),
    );
  });

  test('resizing an image keeps its aspect ratio', () {
    final c = make(
      items: [
        const ImageItem(
          id: 'i',
          assetId: 'a',
          position: Offset.zero,
          width: 200,
          minHeight: 100,
        ),
      ],
    )..select(['i']);
    c.pointerDown(const Offset(200, 100));
    c.pointerMove(const Offset(400, 130));
    c.pointerUp();
    final i = c.items.single as ImageItem;
    expect(i.width, 400);
    expect(i.height, 200);
  });

  test('drawing never moves objects and moving never draws', () {
    final c = make(items: [note('a', Offset.zero)]);
    c.tool = CanvasTool.pen;
    c.pointerDown(const Offset(20, 20));
    c.pointerMove(const Offset(120, 80));
    c.pointerUp();
    expect((c.itemById('a') as TextItem).position, Offset.zero);
    expect(c.items.whereType<StrokeItem>(), hasLength(1));

    c.tool = CanvasTool.select;
    c.pointerDown(const Offset(20, 20), timeStamp: const Duration(seconds: 5));
    c.pointerMove(const Offset(60, 20));
    c.pointerUp();
    expect(c.items.whereType<StrokeItem>(), hasLength(1));
  });

  test('a tiny saved zoom is replaced by a readable fit on open', () {
    final c = make(
      items: [note('a', Offset.zero), note('b', const Offset(600, 300))],
      view: const CanvasViewport(scale: 0.22),
    );
    c.ensureSensibleView(const Size(1200, 800));
    expect(c.scale, greaterThanOrEqualTo(CanvasController.readableScale));
    expect(c.scale, lessThanOrEqualTo(1));
    final visible = c.visibleWorld(const Size(1200, 800));
    expect(visible.overlaps(c.contentBounds()!), isTrue);
  });

  test('a readable saved view is kept', () {
    final c = make(
      items: [note('a', Offset.zero)],
      view: const CanvasViewport(scale: 1.2),
    );
    c.ensureSensibleView(const Size(1200, 800));
    expect(c.scale, 1.2);
  });

  test('the world is effectively unbounded: zoom range and far positions', () {
    final c = make();
    c.zoomAt(Offset.zero, 0.0001);
    expect(c.scale, CanvasController.minScale);
    // At minimum zoom a 1200px window shows ~40 000 world units across,
    // over 30x the width visible at 100 %.
    expect(c.visibleWorld(const Size(1200, 800)).width, greaterThan(1200 * 30));
    c.createText(const Offset(1e6, -1e6));
    c.updateEditingText('far away');
    c.endEditing();
    expect(
      roundTrip(c.document).items.single.bounds.left,
      closeTo(1e6 - kTextPadding, 0.001),
    );
  });

  test('schema 1 files load and are rewritten in the current schema', () {
    final v1 = {
      'schema': 1,
      'id': 'old',
      'title': 'Old',
      'folderId': null,
      'updatedAt': '2026-10-21T21:10:09.512624',
      'viewport': {'dx': 0.0, 'dy': 0.0, 'scale': 0.22},
      'items': [
        {
          'type': 'text',
          'id': 't',
          'x': 1.0,
          'y': 2.0,
          'w': 420.0,
          'h': 0.0,
          'text': 'Hello',
          'fontSize': 22.0,
        },
      ],
    };
    final doc = CanvasDocument.fromJson(v1);
    expect(doc.schema, 1);
    final c = CanvasController(document: doc, onSave: (_) async {});
    expect(c.saveState, SaveState.pending);
    expect(c.document.toJson()['schema'], CanvasDocument.schemaVersion);
    final t = c.items.single as TextItem;
    expect(t.text, 'Hello');
    expect(t.bold, isFalse);
    c.dispose();
  });

  test('bring to front / send to back reorder items', () {
    final c = make(items: [note('a', Offset.zero), note('b', Offset.zero)])
      ..select(['a']);
    c.bringToFront();
    expect(c.items.last.id, 'a');
    c.sendToBack();
    expect(c.items.first.id, 'a');
  });
}
