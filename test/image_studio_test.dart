// In-note image editing: non-destructive crop / turn / mirror, aspect
// choices, undo/redo, reset, repeated edits, save/reload, transparency, the
// exported picture, and that no other object moves.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/tag_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart' as lib;
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_export.dart';
import 'package:flutter_application_1/features/canvas/canvas_resources.dart';
import 'package:flutter_application_1/features/canvas/image_studio.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeResources extends ChangeNotifier implements CanvasResources {
  FakeResources(this.photo, this._asset);
  final ui.Image photo;
  final Asset _asset;
  @override
  Asset? asset(String id) => id == _asset.id ? _asset : null;
  @override
  lib.Note? note(String id) => null;
  @override
  ui.Image? image(String fileName) => photo;
  @override
  Future<void> preload(Iterable<String> fileNames) async {}
  @override
  CustomTag? tag(String id) => null;
}

/// 4 x 2 photo: only the top-left pixel is (opaque red); the rest is fully
/// transparent.
Future<ui.Image> redCorner() {
  final px = Uint8List(4 * 2 * 4);
  px[0] = 255;
  px[3] = 255;
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, 4, 2, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

Future<(int, int, Uint8List)> decodePng(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final img = (await codec.getNextFrame()).image;
  final data = (await img.toByteData())!;
  return (img.width, img.height, data.buffer.asUint8List());
}

List<int> pixel((int, int, Uint8List) p, int x, int y) {
  final i = (y * p.$1 + x) * 4;
  return [p.$3[i], p.$3[i + 1], p.$3[i + 2], p.$3[i + 3]];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final asset = Asset(
    id: 'a1',
    kind: AssetKind.image,
    file: 'p.png',
    width: 4,
    height: 2,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
  const note = TextItem(
    id: 'n',
    position: Offset(500, 40),
    width: 200,
    minHeight: 60,
    text: 'keep me',
  );
  const photo = ImageItem(
    id: 'i',
    assetId: 'a1',
    position: Offset(100, 100),
    width: 40,
    minHeight: 20,
  );

  CanvasController make(ui.Image img, {List<CanvasItem>? items}) =>
      CanvasController(
        document: CanvasDocument(
          id: 'c',
          title: 'Map',
          items: items ?? [photo, note],
          updatedAt: DateTime(2026),
          viewport: const CanvasViewport(),
          schema: 3,
        ),
        onSave: (_) async {},
        resources: FakeResources(img, asset),
      );

  ImageItem img(CanvasController c) =>
      c.items.whereType<ImageItem>().single;

  test('edit values survive JSON; damaged values fall back', () {
    const e = ImageEdit(crop: Rect.fromLTRB(0.1, 0.2, 0.6, 0.9), turns: 3, flip: true);
    expect(ImageEdit.fromJson(e.toJson()), e);
    expect(ImageEdit.none.toJson(), isEmpty);
    expect(ImageEdit.fromJson('junk'), ImageEdit.none);
    expect(ImageEdit.fromJson({'crop': [0, 0, 1, 1]}).crop, isNull);
    expect(ImageEdit.fromJson({'crop': [5, 5, 1, 1], 'turns': 7}).turns, 3);
    expect(ImageEdit.fromJson({'crop': 'x', 'turns': 'y'}), ImageEdit.none);
    // An unedited photo writes exactly what it always did.
    expect(photo.toJson().containsKey('edit'), isFalse);
  });

  test('dragCrop: free, locked ratio, move, and limits', () {
    const r = Rect.fromLTRB(0.2, 0.2, 0.8, 0.8);
    expect(dragCrop(r, CropHandle.l, const Offset(0.1, 0)).left, closeTo(0.3, 1e-9));
    expect(dragCrop(r, CropHandle.br, const Offset(0.5, 0.5)).right, 1.0);
    expect(dragCrop(r, CropHandle.l, const Offset(5, 0)).width, greaterThan(0));
    final moved = dragCrop(r, CropHandle.move, const Offset(0.9, 0.9));
    expect(moved.right, closeTo(1, 1e-9));
    expect(moved.width, closeTo(0.6, 1e-9));
    final locked = dragCrop(r, CropHandle.br, const Offset(0.1, 0.0), ratio: 1.0);
    expect(locked.width / locked.height, closeTo(1, 1e-9));
    expect(dragCrop(r, CropHandle.t, const Offset(0, 0.1), ratio: 1.0), r);
  });

  testWidgets('crop, turn, mirror, reset; undo/redo; nothing else moves', (t) async {
    final image = (await t.runAsync(redCorner))!;
    final c = make(image);
    final noteBefore = note.toJson();

    c.cropImage('i', const Rect.fromLTRB(0, 0, 0.5, 1));
    expect(img(c).edit.crop, const Rect.fromLTRB(0, 0, 0.5, 1));
    // 2 x 2 px of a 4 x 2 photo drawn at 10 units / px.
    expect(img(c).bounds.size, const Size(20, 20));
    expect(img(c).position, const Offset(100, 100), reason: 'crop keeps top-left');

    c.rotateImage('i');
    c.setImageAspect('i', 2);
    expect(img(c).edit.turns, 1);
    final shape = img(c).bounds.size;
    expect(shape.width / shape.height, closeTo(2, 0.1));

    c.flipImage('i');
    expect(img(c).edit.flip, isTrue);

    c.resetImageEdits('i');
    expect(img(c).edit.isNone, isTrue);
    expect(img(c).bounds.size, const Size(40, 20));

    for (var i = 0; i < 5; i++) {
      c.undo();
    }
    expect(img(c).edit.isNone, isTrue);
    expect(img(c).bounds, photo.bounds);
    for (var i = 0; i < 5; i++) {
      c.redo();
    }
    expect(img(c).edit.isNone, isTrue);
    expect(c.items.whereType<TextItem>().single.toJson(), noteBefore);
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('rotating keeps the centre; four turns return exactly', (t) async {
    final image = (await t.runAsync(redCorner))!;
    final c = make(image);
    final centre = photo.bounds.center;
    c.rotateImage('i');
    expect(img(c).bounds.size, const Size(20, 40));
    expect(img(c).bounds.center, centre);
    c.rotateImage('i');
    c.rotateImage('i');
    c.rotateImage('i');
    expect(img(c).edit.isNone, isTrue);
    expect(img(c).bounds, photo.bounds);
    c.rotateImage('i', clockwise: false);
    expect(img(c).edit.turns, 3);
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('locked photos cannot be edited', (t) async {
    final image = (await t.runAsync(redCorner))!;
    final c = make(image);
    c.select({'i'});
    c.toggleLockSelection();
    c.rotateImage('i');
    c.cropImage('i', const Rect.fromLTRB(0, 0, 0.5, 0.5));
    expect(img(c).edit.isNone, isTrue);
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('edits survive save and reload, and repeat editing', (t) async {
    final image = (await t.runAsync(redCorner))!;
    final c = make(image);
    c.cropImage('i', const Rect.fromLTRB(0, 0, 0.5, 1));
    c.rotateImage('i');
    c.cropImage('i', const Rect.fromLTRB(0, 0, 0.5, 0.5));
    final json = CanvasDocument(
      id: 'c',
      title: 'Map',
      items: c.items,
      updatedAt: DateTime(2026),
      viewport: const CanvasViewport(),
      schema: 3,
    ).toJson();
    final back = CanvasDocument.fromJson(json);
    final again = back.items.whereType<ImageItem>().single;
    expect(again.edit, img(c).edit);
    expect(again.bounds, img(c).bounds);
    final c2 = make(image, items: back.items);
    c2.rotateImage('i');
    expect(img(c2).edit.turns, 2);
    expect(img(c2).edit.crop, const Rect.fromLTRB(0, 0, 0.5, 0.5));
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('edited copy keeps transparency and the turn', (t) async {
    final image = (await t.runAsync(redCorner))!;
    final png = (await t.runAsync(
      () => renderEditedPng(image, const ImageEdit(turns: 1)),
    ))!;
    final p = (await t.runAsync(() => decodePng(png)))!;
    expect([p.$1, p.$2], [2, 4]);
    // A clockwise turn moves the top-left pixel to the top-right.
    expect(pixel(p, 1, 0), [255, 0, 0, 255]);
    expect(pixel(p, 0, 0)[3], 0);
    expect(pixel(p, 0, 3)[3], 0);

    final cropped = (await t.runAsync(
      () => renderEditedPng(image, const ImageEdit(crop: Rect.fromLTRB(0, 0, 0.5, 1))),
    ))!;
    final q = (await t.runAsync(() => decodePng(cropped)))!;
    expect([q.$1, q.$2], [2, 2]);
    expect(pixel(q, 0, 0), [255, 0, 0, 255]);
  });

  testWidgets('the exported picture shows the edits', (t) async {
    final image = (await t.runAsync(redCorner))!;
    final c = make(image);
    c.rotateImage('i');
    final b = img(c).bounds; // 20 x 40
    final png = (await t.runAsync(() => renderRectPng(c, b, background: const Color(0x00000000))))!;
    final p = (await t.runAsync(() => decodePng(png)))!;
    expect([p.$1, p.$2], [40, 80]);
    // Red source pixel is now the top-right 20 x 20 of the output.
    expect(pixel(p, 30, 10)[0], greaterThan(200));
    expect(pixel(p, 30, 10)[3], greaterThan(200));
    expect(pixel(p, 10, 10)[3], lessThan(40));
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('crop dialog: aspect, drag, apply, and reset crop', (t) async {
    final image = (await t.runAsync(redCorner))!;
    final c = make(image);
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showImageCropDialog(context, c, img(c)),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('crop-aspect-1:1')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('crop-apply')));
    await t.pumpAndSettle();
    final crop = img(c).edit.crop!;
    // Square on a 4 x 2 photo: half as wide as it is tall in fractions.
    expect(crop.width * 4 / (crop.height * 2), closeTo(1, 1e-6));
    expect(img(c).bounds.width, closeTo(img(c).bounds.height, 1e-6));

    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('crop-reset')));
    await t.pumpAndSettle();
    expect(img(c).edit.crop, isNull);
    expect(img(c).bounds, photo.bounds);
    await t.pump(const Duration(seconds: 2));
  });
}
