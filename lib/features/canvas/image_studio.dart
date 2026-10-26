// In-note image editing: crop dialog, aspect choices and "edited copy".
// Edits are non-destructive (see ImageEdit): the original file is only ever
// replaced by an explicit, confirmed "Replace with edited copy", and even
// then the original stays in the Archive untouched.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../widgets/common.dart' show confirm;
import 'canvas_controller.dart';
import 'canvas_painter.dart' show paintEditedImage;
import 'canvas_resources.dart';

enum CropHandle { move, tl, t, tr, r, br, b, bl, l }

const double _minCrop = 0.04;

/// [start] after dragging [handle] by [d] (fractions of the photo).
/// [ratio] (crop width / height in fractions) locks the shape; then only
/// the corners resize.
Rect dragCrop(Rect start, CropHandle handle, Offset d, {double? ratio}) {
  Rect clampMove(Rect r) {
    var dx = 0.0, dy = 0.0;
    if (r.left < 0) dx = -r.left;
    if (r.right > 1) dx = 1 - r.right;
    if (r.top < 0) dy = -r.top;
    if (r.bottom > 1) dy = 1 - r.bottom;
    return r.shift(Offset(dx, dy));
  }

  if (handle == CropHandle.move) return clampMove(start.shift(d));
  if (ratio != null) {
    final left = handle == CropHandle.tl || handle == CropHandle.bl;
    final top = handle == CropHandle.tl || handle == CropHandle.tr;
    if (handle == CropHandle.t ||
        handle == CropHandle.b ||
        handle == CropHandle.l ||
        handle == CropHandle.r) {
      return start;
    }
    final anchor = Offset(
      left ? start.right : start.left,
      top ? start.bottom : start.top,
    );
    var w = (left ? start.width - d.dx : start.width + d.dx);
    // Largest width that keeps the shape inside the photo.
    final maxW = [
      left ? anchor.dx : 1 - anchor.dx,
      (top ? anchor.dy : 1 - anchor.dy) * ratio,
    ].reduce((a, b) => a < b ? a : b);
    w = w.clamp(_minCrop, maxW < _minCrop ? _minCrop : maxW);
    final h = w / ratio;
    return Rect.fromLTRB(
      left ? anchor.dx - w : anchor.dx,
      top ? anchor.dy - h : anchor.dy,
      left ? anchor.dx : anchor.dx + w,
      top ? anchor.dy : anchor.dy + h,
    );
  }
  var l = start.left, t = start.top, r = start.right, b = start.bottom;
  if (handle == CropHandle.tl || handle == CropHandle.l || handle == CropHandle.bl) {
    l = (l + d.dx).clamp(0.0, r - _minCrop);
  }
  if (handle == CropHandle.tr || handle == CropHandle.r || handle == CropHandle.br) {
    r = (r + d.dx).clamp(l + _minCrop, 1.0);
  }
  if (handle == CropHandle.tl || handle == CropHandle.t || handle == CropHandle.tr) {
    t = (t + d.dy).clamp(0.0, b - _minCrop);
  }
  if (handle == CropHandle.bl || handle == CropHandle.b || handle == CropHandle.br) {
    b = (b + d.dy).clamp(t + _minCrop, 1.0);
  }
  return Rect.fromLTRB(l, t, r, b);
}

/// The photo shown through [edit], as PNG (transparency is kept).
Future<Uint8List?> renderEditedPng(ui.Image image, ImageEdit edit) async {
  final shown = edit.shown(image.width.toDouble(), image.height.toDouble());
  var w = shown.width, h = shown.height;
  final big = w > h ? w : h;
  if (big > 8192) {
    w *= 8192 / big;
    h *= 8192 / big;
  }
  final rec = ui.PictureRecorder();
  paintEditedImage(ui.Canvas(rec), image, Rect.fromLTWH(0, 0, w, h), edit);
  final out = await rec.endRecording().toImage(w.round(), h.round());
  final data = await out.toByteData(format: ui.ImageByteFormat.png);
  out.dispose();
  return data?.buffer.asUint8List();
}

const aspectChoices = <String, double?>{
  'Original': null,
  '1:1': 1,
  '4:3': 4 / 3,
  '3:4': 3 / 4,
  '16:9': 16 / 9,
  '3:2': 3 / 2,
};

ui.Image? _imageOf(CanvasController c, ImageItem item) {
  final file = c.resources?.asset(item.assetId)?.file;
  return file == null ? null : c.resources?.image(file);
}

/// Saves the photo as shown (crop, turn, mirror) as a new picture. With
/// [replace] the item switches to it (one undo step); the original picture
/// is not touched either way.
Future<bool> saveEditedImage(
  BuildContext context,
  CanvasController c,
  ImageItem item, {
  required bool replace,
}) async {
  final r = c.resources;
  final image = _imageOf(c, item);
  if (r is! WorkspaceCanvasResources || image == null) return false;
  if (replace) {
    final ok = await confirm(
      context,
      title: 'Replace with the edited copy?',
      message:
          'This photo will use a new picture with the crop and turn baked '
          'in. The original picture stays in your Archive untouched, and '
          'Undo brings the edits back.',
      action: 'Replace',
    );
    if (!ok) return false;
  }
  final png = await renderEditedPng(image, item.edit);
  if (png == null) return false;
  final asset = await r.workspace.imageAssetFromBytes(png, 'png');
  if (replace) {
    c.swapImageAsset(item.id, asset.id);
  } else {
    final b = item.bounds;
    c.addItems([
      ImageItem(
        id: newId(),
        assetId: asset.id,
        position: Offset(b.right + 24, b.top),
        width: b.width,
        minHeight: b.height,
      ),
    ]);
  }
  return true;
}

Future<void> showImageCropDialog(
  BuildContext context,
  CanvasController c,
  ImageItem item,
) => showDialog<void>(
  context: context,
  builder: (_) => _CropDialog(controller: c, item: item),
);

class _CropDialog extends StatefulWidget {
  const _CropDialog({required this.controller, required this.item});
  final CanvasController controller;
  final ImageItem item;

  @override
  State<_CropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<_CropDialog> {
  late Rect _crop = widget.item.edit.crop ?? const Rect.fromLTWH(0, 0, 1, 1);
  double? _lock; // crop width / height in photo fractions
  CropHandle? _active;
  Rect _start = Rect.zero;
  Offset _from = Offset.zero;

  ui.Image? get _image => _imageOf(widget.controller, widget.item);

  void _setAspect(double? shown) {
    final image = _image;
    if (image == null) return;
    if (shown == null) {
      setState(() {
        _lock = null;
        _crop = const Rect.fromLTWH(0, 0, 1, 1);
      });
      return;
    }
    final q = widget.item.edit.turns.isOdd ? 1 / shown : shown;
    final ia = image.width / image.height;
    final ratio = q / ia; // crop width / height in fractions
    var w = 1.0, h = 1 / ratio;
    if (h > 1) {
      h = 1;
      w = ratio;
    }
    setState(() {
      _lock = ratio;
      _crop = Rect.fromCenter(center: _crop.center, width: w, height: h)
          .shift(Offset.zero);
      _crop = dragCrop(_crop, CropHandle.move, Offset.zero);
    });
  }

  CropHandle? _hit(Offset p, Size box) {
    final r = Rect.fromLTRB(
      _crop.left * box.width,
      _crop.top * box.height,
      _crop.right * box.width,
      _crop.bottom * box.height,
    );
    const g = 18.0;
    bool near(double a, double b) => (a - b).abs() <= g;
    final onL = near(p.dx, r.left), onR = near(p.dx, r.right);
    final onT = near(p.dy, r.top), onB = near(p.dy, r.bottom);
    if (onL && onT) return CropHandle.tl;
    if (onR && onT) return CropHandle.tr;
    if (onL && onB) return CropHandle.bl;
    if (onR && onB) return CropHandle.br;
    if (_lock == null) {
      if (onT) return CropHandle.t;
      if (onB) return CropHandle.b;
      if (onL) return CropHandle.l;
      if (onR) return CropHandle.r;
    }
    return r.contains(p) ? CropHandle.move : null;
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return AlertDialog(
      key: const ValueKey('image-crop-dialog'),
      title: const Text('Crop photo', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (image == null)
              const SizedBox(
                height: 200,
                child: Center(child: Text('The photo is not loaded yet.')),
              )
            else
              LayoutBuilder(
                builder: (context, box) {
                  final ia = image.width / image.height;
                  final maxW = box.maxWidth, maxH = 340.0;
                  final w = ia > maxW / maxH ? maxW : maxH * ia;
                  final size = Size(w, w / ia);
                  return GestureDetector(
                    key: const ValueKey('image-crop-area'),
                    onPanStart: (d) {
                      _active = _hit(d.localPosition, size);
                      _start = _crop;
                      _from = d.localPosition;
                    },
                    onPanUpdate: (d) {
                      final h = _active;
                      if (h == null) return;
                      final delta = d.localPosition - _from;
                      setState(
                        () => _crop = dragCrop(
                          _start,
                          h,
                          Offset(delta.dx / size.width, delta.dy / size.height),
                          ratio: _lock,
                        ),
                      );
                    },
                    onPanEnd: (_) => _active = null,
                    child: SizedBox.fromSize(
                      size: size,
                      child: CustomPaint(
                        painter: _CropPainter(image, _crop),
                      ),
                    ),
                  );
                },
              ),
            const SizedBox(height: Space.md),
            Wrap(
              spacing: 6,
              children: [
                for (final e in aspectChoices.entries)
                  ChoiceChip(
                    key: ValueKey('crop-aspect-${e.key}'),
                    label: Text(e.key, style: const TextStyle(fontSize: 12)),
                    selected: false,
                    onSelected: (_) => _setAspect(e.value),
                  ),
                ActionChip(
                  key: const ValueKey('crop-free'),
                  label: const Text('Free', style: TextStyle(fontSize: 12)),
                  onPressed: () => setState(() => _lock = null),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('crop-reset'),
          onPressed: () {
            widget.controller.resetImageCrop(widget.item.id);
            Navigator.pop(context);
          },
          child: const Text('Reset crop'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('crop-apply'),
          onPressed: image == null
              ? null
              : () {
                  widget.controller.cropImage(widget.item.id, _crop);
                  Navigator.pop(context);
                },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.crop);
  final ui.Image image;
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    final all = Offset.zero & size;
    paintImage(canvas: canvas, rect: all, image: image, fit: BoxFit.fill);
    final r = Rect.fromLTRB(
      crop.left * size.width,
      crop.top * size.height,
      crop.right * size.width,
      crop.bottom * size.height,
    );
    final shade = Path()
      ..addRect(all)
      ..addRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(shade, Paint()..color = const Color(0x99000000));
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    for (final p in [
      r.topLeft, r.topRight, r.bottomLeft, r.bottomRight,
      r.topCenter, r.bottomCenter, r.centerLeft, r.centerRight,
    ]) {
      canvas.drawCircle(p, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
        p,
        5,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0xFF444444),
      );
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.crop != crop || old.image != image;
}
