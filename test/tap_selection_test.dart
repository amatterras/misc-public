import 'package:flutter/gestures.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasController _make(List<CanvasItem> items) => CanvasController(
  document: CanvasDocument(
    id: 'c',
    title: 'T',
    items: items,
    updatedAt: DateTime(2026),
  ),
  onSave: (_) async {},
);

void main() {
  final text = TextItem(
    id: 't',
    position: Offset.zero,
    width: 200,
    minHeight: 40,
    text: 'Hello',
  );
  const link = LinkItem(
    id: 'l',
    position: Offset(400, 0),
    width: 300,
    assetId: 'a',
    minHeight: 100,
  );

  test('tapping text does not select it; tapping a link does', () {
    final c = _make([text, link]);
    c.tool = CanvasTool.select;
    c.pointerDown(const Offset(20, 20), timeStamp: const Duration(seconds: 1));
    c.pointerUp();
    expect(c.selection, isEmpty);
    c.pointerDown(
      const Offset(450, 30),
      timeStamp: const Duration(seconds: 5),
    );
    c.pointerUp();
    expect(c.selection, {'l'});
    c.dispose();
  });

  test('dragging on empty space selects nothing', () {
    final c = _make([text]);
    c.tool = CanvasTool.select;
    c.pointerDown(const Offset(900, 900));
    c.pointerMove(const Offset(0, 0));
    c.pointerUp();
    expect(c.selection, isEmpty);
    c.dispose();
  });
}
