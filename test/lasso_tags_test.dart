// Tags on lasso-selected Mindmap objects: apply, remove from one object,
// quick toggle, undo/redo, rename and delete, save/reload; the objects and
// their connections are never changed, and the Archive folders are not
// involved at all.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

TextItem box(String id, Offset at) =>
    TextItem(id: id, position: at, width: 120, minHeight: 60, text: id);

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Workspace ws;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_lasso_tags_');
    ws = Workspace(dir);
    await ws.load();
  });
  tearDown(() {
    ws.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  CanvasController scene() => make([
    box('a', Offset.zero),
    box('b', const Offset(200, 0)),
    box('c', const Offset(400, 0)),
    box('far', const Offset(1200, 900)),
    const ConnectorItem(id: 'k', fromId: 'a', toId: 'b'),
  ]);

  /// A lasso loop around the three boxes at the top (screen == world).
  void lassoTop(CanvasController c) {
    c.setView(Offset.zero, 1);
    c.tool = CanvasTool.lasso;
    c.pointerDown(const Offset(-20, -20));
    for (final p in const [
      Offset(300, -30),
      Offset(560, -20),
      Offset(570, 100),
      Offset(300, 110),
      Offset(-20, 100),
      Offset(-25, 30),
    ]) {
      c.pointerMove(p);
    }
    c.pointerUp();
  }

  test('lasso several objects, tag them, remove a tag from only one', () {
    final c = scene();
    final work = ws.createTag('Work', 0xFF2878F0).tag;
    final idea = ws.createTag('Idea', 0xFFFF6A00).tag;
    lassoTop(c);
    expect(c.selection, containsAll(['a', 'b', 'c']));
    expect(c.selection, isNot(contains('far')));

    final before = c.items.map((i) => i.toJson()).toList();
    c.toggleCustomTag(c.selection, work.id);
    c.toggleCustomTag(c.selection, idea.id);
    for (final id in ['a', 'b', 'c']) {
      expect(c.customTagsOf(id), unorderedEquals([work.id, idea.id]));
    }
    expect(c.customTagsOf('far'), isEmpty);
    // Content, place and the connection are exactly as they were.
    expect(c.items.map((i) => i.toJson()).toList(), before);

    // Only 'b' loses "Idea".
    c.select(const ['b']);
    c.toggleCustomTag(c.selection, idea.id);
    expect(c.customTagsOf('b'), [work.id]);
    expect(c.customTagsOf('a'), contains(idea.id));
    expect(c.customTagsOf('c'), contains(idea.id));
    // A mixed selection toggled puts the tag on everyone first.
    c.select(const ['a', 'b']);
    expect(c.tagCoverage(c.selection, idea.id), (with_: 1, total: 2));
    c.toggleCustomTag(c.selection, idea.id);
    expect(c.customTagsOf('b'), contains(idea.id));
    c.toggleCustomTag(c.selection, idea.id); // all had it: now off both
    expect(c.customTagsOf('a'), isNot(contains(idea.id)));
    expect(c.customTagsOf('b'), isNot(contains(idea.id)));
    expect(c.customTagsOf('a'), contains(work.id));
  });

  test('every tag change is one undo/redo step', () {
    final c = scene();
    final t = ws.createTag('One', 0xFF176B4D).tag;
    c.select(const ['a', 'b']);
    c.toggleCustomTag(c.selection, t.id);
    expect(c.customTagsOf('a'), [t.id]);
    c.undo();
    expect(c.customTagsOf('a'), isEmpty);
    expect(c.customTagsOf('b'), isEmpty);
    c.redo();
    expect(c.customTagsOf('a'), [t.id]);
    expect(c.customTagsOf('b'), [t.id]);
    // A later move does not disturb the tags; undoing it keeps them.
    c.select(const ['a']);
    c.pointerDown(const Offset(60, 30));
    c.pointerMove(const Offset(90, 60));
    c.pointerMove(const Offset(120, 90));
    c.pointerUp();
    c.undo();
    expect(c.customTagsOf('a'), [t.id]);
    c.undo(); // the tagging itself
    expect(c.customTagsOf('a'), isEmpty);
    expect(c.canUndo, isFalse);
  });

  test('picker-style apply sets exactly the chosen tags in one step', () {
    final c = scene();
    final x = ws.createTag('X', 0xFFFF3B30).tag;
    final y = ws.createTag('Y', 0xFF5CC8FF).tag;
    c.applyCustomTags({
      'a': [x.id],
      'b': [x.id, y.id],
    });
    expect(c.customTagsOf('b'), [x.id, y.id]);
    c.applyCustomTags({'b': [x.id, y.id]}); // nothing changes: no new step
    c.undo();
    expect(c.customTagsOf('a'), isEmpty);
    expect(c.canUndo, isFalse);
  });

  test('renaming a tag shows everywhere; deleting never deletes objects', () {
    final c = scene();
    final t = ws.createTag('Old name', 0xFF2878F0).tag;
    final other = ws.createTag('Stays', 0xFF176B4D).tag;
    c.select(const ['a', 'b', 'c']);
    c.toggleCustomTag(c.selection, t.id);
    c.toggleCustomTag(c.selection, other.id);
    expect(ws.renameTag(t.id, 'New name'), isNull);
    expect(ws.customTags[t.id]!.name, 'New name');
    for (final id in ['a', 'b', 'c']) {
      expect(c.customTagsOf(id), contains(t.id), reason: 'same id, new name');
    }
    ws.recolorTag(t.id, 0xFFFF6A00);
    expect(ws.customTags[t.id]!.color, 0xFFFF6A00);

    final count = c.items.length;
    ws.deleteTag(t.id);
    c.scrubCustomTags((id) => ws.customTags[id] != null);
    expect(c.items, hasLength(count), reason: 'objects stay');
    for (final id in ['a', 'b', 'c']) {
      expect(c.customTagsOf(id), [other.id]);
    }
    expect(c.items.whereType<ConnectorItem>(), hasLength(1));
  });

  test('assignments survive save and reload', () {
    final c = scene();
    final t = ws.createTag('Persist', 0xFFFF6A00).tag;
    c.select(const ['a', 'c']);
    c.toggleCustomTag(c.selection, t.id);
    final back = CanvasDocument.fromJson(
      jsonDecode(jsonEncode(c.document.toJson())) as Map<String, dynamic>,
    );
    final again = CanvasController(document: back, onSave: (_) async {});
    expect(again.customTagsOf('a'), [t.id]);
    expect(again.customTagsOf('c'), [t.id]);
    expect(again.customTagsOf('b'), isEmpty);
    expect(again.items.length, c.items.length);
    for (var i = 0; i < c.items.length; i++) {
      expect(again.items[i].toJson(), c.items[i].toJson());
    }
  });

  test('tagging is separate from Archive folders', () {
    final c = scene();
    final folders = ws.archiveFolders.all.length;
    final t = ws.createTag('NoFolder', 0xFF2878F0).tag;
    c.select(const ['a']);
    c.toggleCustomTag(c.selection, t.id);
    expect(ws.archiveFolders.all.length, folders);
    expect(c.groupOf('a'), isNull);
  });
}
