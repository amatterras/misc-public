// Pictures of canvas content: a selection (for the AI), a whole mindmap or
// a note's pages (image export). Drawn with the same painter as the
// screen, on the app's dark background, so what you see is what you get.
// The source document is never changed.
import 'dart:math' as math;
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
  final picture = await renderItemsPicture(
    source,
    items: items,
    margin: margin,
    maxSide: maxSide,
    background: background,
  );
  return picture?.png;
}

/// Like [renderItemsPng], also counting photos that could not be drawn.
Future<({Uint8List png, int missingImages})?> renderItemsPicture(
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
    final rect = area!.inflate(margin);
    final png = await renderRectPng(
      copy,
      rect,
      maxSide: maxSide,
      background: background,
    );
    if (png == null) return null;
    return (png: png, missingImages: missingImagesIn(copy, rect));
  } finally {
    copy.dispose();
  }
}

/// The attachment files the pictures and link previews in [rect] of [c]
/// show.
List<String> imageFilesIn(CanvasController c, Rect rect) {
  final r = c.resources;
  if (r == null) return const [];
  return [
    for (final i in c.items)
      if (c.itemBounds(i).overlaps(rect))
        if (i is ImageItem)
          ?r.asset(i.assetId)?.file
        else if (i is LinkItem)
          ?r.asset(i.assetId)?.previewFile,
  ];
}

/// Photos in [rect] that still cannot be drawn (missing or unreadable
/// files): they appear as a placeholder, and an export says so.
int missingImagesIn(CanvasController c, Rect rect) {
  final r = c.resources;
  if (r == null) return 0;
  return [
    for (final i in c.items.whereType<ImageItem>())
      if (c.itemBounds(i).overlaps(rect)) r.asset(i.assetId)?.file,
  ].where((file) => file == null || r.image(file) == null).length;
}

/// PNG of the world rectangle [rect] of [c]. Photos are loaded first (the
/// screen loads them lazily; a picture must not miss them). The longest
/// side is at most [maxSide] pixels, however large the area.
Future<Uint8List?> renderRectPng(
  CanvasController c,
  Rect rect, {
  double maxSide = 2400,
  Color background = AppColors.background,
  void Function(Canvas canvas, Size size)? underlay,
}) async {
  if (rect.isEmpty) return null;
  await c.resources
      ?.preload(imageFilesIn(c, rect))
      .timeout(const Duration(seconds: 20), onTimeout: () {});
  final scale = math.min(2.0, maxSide / rect.longestSide);
  final size = Size(
    math.max(1, (rect.width * scale).ceilToDouble()),
    math.max(1, (rect.height * scale).ceilToDouble()),
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
