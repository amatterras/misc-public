import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasController makeController({
  List<CanvasItem> items = const [],
  List<CanvasDocument>? saved,
}) {
  return CanvasController(
    document: CanvasDocument(
      id: 'c1',
      title: 'Test',
      items: items,
      updatedAt: DateTime(2026),
    ),
    onSave: (doc) async => saved?.add(doc),
    saveDelay: const Duration(milliseconds: 10),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('creating and typing text is one undoable step', () {
    final c = makeController();
    c.createText(const Offset(100, 100));
    c.updateEditingText('Hello');
    c.updateEditingText('Hello world');
    c.endEditing();

    expect(c.items, hasLength(1));
    expect((c.items.single as TextItem).text, 'Hello world');

    c.undo();
    expect(c.items, isEmpty);
    c.redo();
    expect((c.items.single as TextItem).text, 'Hello world');
  });

  test('empty text boxes are discarded without an undo step', () {
    final c = makeController();
    c.createText(Offset.zero);
    c.endEditing();
    expect(c.items, isEmpty);
    expect(c.canUndo, isFalse);
  });

  test('drawing with the pen adds a stroke; eraser removes it', () {
    final c = makeController()..tool = CanvasTool.pen;
    c.pointerDown(const Offset(10, 10));
    c.pointerMove(const Offset(50, 50));
    c.pointerMove(const Offset(90, 10));
    c.pointerUp();

    final stroke = c.items.single as StrokeItem;
    expect(stroke.points.length, 3);

    c.tool = CanvasTool.eraser;
    c.pointerDown(const Offset(50, 50));
    c.pointerUp();
    expect(c.items, isEmpty);

    c.undo();
    expect(c.items.single.id, stroke.id);
  });

  test('dragging a selected item moves it and can be undone', () {
    final text = TextItem(
      id: 't',
      position: const Offset(0, 0),
      width: 200,
      minHeight: 40,
      text: 'Move me',
    );
    final c = makeController(items: [text]);
    // Items are selected with the lasso, never by tapping them.
    c.tool = CanvasTool.lasso;
    c.pointerDown(const Offset(-20, -20));
    c.pointerMove(const Offset(220, -20));
    c.pointerMove(const Offset(220, 60));
    c.pointerMove(const Offset(-20, 60));
    c.pointerUp();
    expect(c.selection, {'t'});
    c.pointerDown(const Offset(20, 20), timeStamp: const Duration(seconds: 1));
    c.pointerMove(const Offset(70, 45));
    c.pointerUp();

    expect((c.items.single as TextItem).position, const Offset(50, 25));
    c.undo();
    expect((c.items.single as TextItem).position, Offset.zero);
  });

  test('double-click on empty space starts a new text box', () {
    final c = makeController();
    c.pointerDown(
      const Offset(300, 300),
      timeStamp: const Duration(seconds: 1),
    );
    c.pointerUp();
    c.pointerDown(
      const Offset(301, 300),
      timeStamp: const Duration(seconds: 1, milliseconds: 150),
    );
    c.pointerUp();
    expect(c.editingItem, isNotNull);
  });

  test('lasso drag selects items inside it', () {
    final items = [
      TextItem(
        id: 'a',
        position: const Offset(10, 10),
        width: 80,
        minHeight: 30,
        text: 'a',
      ),
      TextItem(
        id: 'b',
        position: const Offset(500, 500),
        width: 80,
        minHeight: 30,
        text: 'b',
      ),
    ];
    final c = makeController(items: items);
    // The select tool has no marquee: dragging on empty space selects nothing.
    c.pointerDown(const Offset(-50, -50));
    c.pointerMove(const Offset(200, 200));
    c.pointerUp();
    expect(c.selection, isEmpty);
    c.tool = CanvasTool.lasso;
    c.pointerDown(const Offset(-50, -50));
    c.pointerMove(const Offset(200, -50));
    c.pointerMove(const Offset(200, 200));
    c.pointerMove(const Offset(-50, 200));
    c.pointerUp();
    expect(c.selection, {'a'});
  });

  test('resize handle changes text box width', () {
    final text = TextItem(
      id: 't',
      position: Offset.zero,
      width: 200,
      minHeight: 100,
      text: 'x',
    );
    final c = makeController(items: [text])..select(['t']);
    // The resize dot is the top-right corner; the bottom-left stays.
    c.pointerDown(const Offset(200, 0));
    c.pointerMove(const Offset(320, -50));
    c.pointerUp();
    final resized = c.items.single as TextItem;
    expect(resized.width, 320);
    expect(resized.minHeight, 150);
  });

  test('zooming keeps the point under the cursor fixed', () {
    final c = makeController();
    const focal = Offset(400, 300);
    final before = c.toWorld(focal);
    c.zoomAt(focal, 2.5);
    expect(c.scale, 2.5);
    expect(c.toWorld(focal).dx, closeTo(before.dx, 1e-9));
    expect(c.toWorld(focal).dy, closeTo(before.dy, 1e-9));
  });

  test('middle mouse drag pans regardless of tool', () {
    final c = makeController()..tool = CanvasTool.pen;
    c.pointerDown(const Offset(0, 0), buttons: kMiddleMouseButton);
    c.pointerMove(const Offset(30, 40));
    c.pointerUp();
    expect(c.offset, const Offset(30, 40));
    expect(c.items, isEmpty);
  });

  test('changes are autosaved and survive a JSON round trip', () async {
    final saved = <CanvasDocument>[];
    final c = makeController(saved: saved);
    c.createText(const Offset(5, 5));
    c.updateEditingText('Persist me');
    c.endEditing();
    c.tool = CanvasTool.pen;
    c.pointerDown(const Offset(0, 0), pressure: 0.8);
    c.pointerMove(const Offset(10, 10));
    c.pointerUp();
    c.zoomAt(Offset.zero, 2);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(saved, isNotEmpty);
    expect(c.saveState, SaveState.saved);

    final restored = CanvasDocument.fromJson(
      jsonDecode(jsonEncode(saved.last.toJson())) as Map<String, dynamic>,
    );
    expect(restored.items, hasLength(2));
    expect((restored.items[0] as TextItem).text, 'Persist me');
    expect((restored.items[1] as StrokeItem).points.first.pressure, 0.8);
    expect(restored.viewport.scale, 2);
    c.dispose();
  });
}
