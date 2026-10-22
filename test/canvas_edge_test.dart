// Canvas edge cases: undo/redo of resize, move, delete; autosave; viewport.
import 'dart:convert';

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasDocument? lastSaved;
CanvasController make(List<CanvasItem> items) => CanvasController(
  document: CanvasDocument(
    id: 'c',
    title: 'T',
    items: items,
    updatedAt: DateTime(2026),
    viewport: const CanvasViewport(),
    schema: 3,
  ),
  onSave: (d) async => lastSaved = d,
  saveDelay: const Duration(milliseconds: 5),
);
TextItem t(String id, Offset at) =>
    TextItem(id: id, position: at, width: 200, minHeight: 100, text: id);
CanvasDocument rt(CanvasDocument d) => CanvasDocument.fromJson(
  jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resize: undo restores, redo reapplies', () {
    final c = make([t('a', Offset.zero)])..select(['a']);
    c.pointerDown(const Offset(200, 100));
    c.pointerMove(const Offset(320, 150));
    c.pointerUp();
    expect((c.itemById('a') as TextItem).width, 320);
    c.undo();
    expect((c.itemById('a') as TextItem).width, 200);
    c.redo();
    expect((c.itemById('a') as TextItem).width, 320);
  });

  test('multi-select move then undo moves all back', () {
    final c = make([t('a', Offset.zero), t('b', const Offset(400, 0))]);
    c.selectAll();
    c.pointerDown(const Offset(50, 50));
    c.pointerMove(const Offset(150, 90));
    c.pointerUp();
    expect((c.itemById('a') as TextItem).position, const Offset(100, 40));
    expect((c.itemById('b') as TextItem).position, const Offset(500, 40));
    c.undo();
    expect((c.itemById('a') as TextItem).position, Offset.zero);
    expect((c.itemById('b') as TextItem).position, const Offset(400, 0));
  });

  test('delete then undo restores the same item (same id)', () {
    final c = make([t('a', Offset.zero)])..select(['a']);
    c.deleteSelection();
    expect(c.itemById('a'), isNull);
    c.undo();
    expect(c.itemById('a'), isNotNull);
  });

  test('undo/redo changes are autosaved', () async {
    final c = make([t('a', Offset.zero)])..select(['a']);
    c.deleteSelection();
    await c.flush();
    expect(lastSaved!.items, isEmpty);
    c.undo();
    await c.flush();
    expect(rt(lastSaved!).items.map((i) => i.id), ['a']);
  });

  test('zoom and pan are saved with the canvas', () async {
    final c = make([t('a', Offset.zero)]);
    c.zoomAt(const Offset(100, 100), 2);
    c.panBy(const Offset(30, -20));
    await c.flush();
    final v = rt(lastSaved!).viewport;
    expect(v.scale, closeTo(2, 1e-9));
    final c2 = CanvasController(document: rt(lastSaved!), onSave: (_) async {});
    expect(c2.scale, closeTo(2, 1e-9));
    expect(
      c2.toWorld(const Offset(100, 100)).dx,
      closeTo(c.toWorld(const Offset(100, 100)).dx, 1e-6),
    );
  });

  test('a new edit after undo clears redo', () {
    final c = make([t('a', Offset.zero), t('b', const Offset(400, 0))])
      ..select(['a']);
    c.deleteSelection();
    c.undo();
    c.select(['b']);
    c.deleteSelection();
    c.redo(); // must not re-delete 'a'
    expect(c.itemById('a'), isNotNull);
  });

  test(
    'extreme zoom is clamped; tiny/huge factors do not break coordinates',
    () {
      final c = make(const []);
      for (var i = 0; i < 50; i++) {
        c.zoomAt(Offset.zero, 10);
      }
      final maxScale = c.scale;
      for (var i = 0; i < 100; i++) {
        c.zoomAt(Offset.zero, 0.1);
      }
      expect(c.scale, greaterThan(0));
      expect(maxScale.isFinite, isTrue);
      expect(c.toWorld(const Offset(10, 10)).dx.isFinite, isTrue);
      c.zoomAt(Offset.zero, double.nan);
      expect(c.scale.isFinite, isTrue, reason: 'NaN zoom ignored');
    },
  );

  test('resizing below zero does not produce negative sizes', () {
    final c = make([t('a', Offset.zero)])..select(['a']);
    c.pointerDown(const Offset(200, 100));
    c.pointerMove(const Offset(-500, -500));
    c.pointerUp();
    final a = c.itemById('a') as TextItem;
    expect(a.width, greaterThan(0));
    expect(a.minHeight, greaterThanOrEqualTo(0));
  });
}
