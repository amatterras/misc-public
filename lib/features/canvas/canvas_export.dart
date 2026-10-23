// Pictures of canvas content: a selection (for the AI), a whole mindmap or
// a note's pages (image export). Drawn with the same painter as the
// screen, on the app's dark background, so what you see is what you get.
// The source document is never changed.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import 'canvas_controller.dart';
import 'canvas_painter.dart';

/// PNG of [items] (or of everything in [source] when null), with a margin.
/// Null when there is nothing to draw. [maxSide] limits the picture size.
Future<Uint8List?> renderItemsPng(
  CanvasController source, {
  Iterable<String>? items,
  double margin = 24,
  double maxSide = 2400,
  Color background = AppColors.background,
}) async {
  final ids = items?.toSet();
  final chosen = [
    for (final i in source.items)
      if (ids == null || ids.contains(i.id)) i,
  ];
  if (chosen.isEmpty) return null;
  final copy = CanvasController(
    document: CanvasDocument(
      id: source.id,
      title: source.title,
      items: chosen,
      updatedAt: DateTime.now(),
      itemUnknownFields: source.marksOf(chosen.map((i) => i.id)),
    ),
    onSave: (_) async {},
    resources: source.resources,
  );
  try {
    Rect? area;
    for (final i in chosen) {
      final b = copy.itemBounds(i);
      area = area == null ? b : area.expandToInclude(b);
    }
    return await renderRectPng(
      copy,
      area!.inflate(margin),
      maxSide: maxSide,
      background: background,
    );
  } finally {
    copy.dispose();
  }
}

/// PNG of the world rectangle [rect] of [c].
Future<Uint8List?> renderRectPng(
  CanvasController c,
  Rect rect, {
  double maxSide = 2400,
  Color background = AppColors.background,
  void Function(Canvas canvas, Size size)? underlay,
}) async {
  if (rect.isEmpty) return null;
  final scale = (maxSide / rect.longestSide).clamp(0.1, 2.0);
  final size = Size(
    (rect.width * scale).ceilToDouble(),
    (rect.height * scale).ceilToDouble(),
  );
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & size, Paint()..color = background);
  underlay?.call(canvas, size);
  CanvasPainter(c, page: rect, pageScale: scale).paint(canvas, size);
  final image = await recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
