import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import 'canvas_controller.dart';
import 'canvas_text.dart';

/// Paints the whole canvas: dot grid, items, selection and live drawing.
///
/// Everything is drawn in one pass with a camera transform instead of as
/// separate widgets, so the space is truly unbounded and stays fast with
/// many items (anything off-screen is skipped).
class CanvasPainter extends CustomPainter {
  CanvasPainter(this.controller) : super(repaint: controller);

  final CanvasController controller;

  static final Expando<Path> _pathCache = Expando();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.canvas);
    _paintGrid(canvas, size);

    final scale = controller.scale;
    final visible = controller.visibleWorld(size).inflate(20 / scale);

    canvas.save();
    canvas.translate(controller.offset.dx, controller.offset.dy);
    canvas.scale(scale);

    // Mind-map connections first, so they run underneath the items.
    final selectedIds = controller.selection;
    for (final c in controller.items.whereType<ConnectorItem>()) {
      final ends = controller.connectorEnds(c);
      if (ends == null) continue;
      _paintConnector(
        canvas,
        ends,
        scale,
        selected: selectedIds.contains(c.id),
      );
    }
    final liveConnection = controller.liveConnection;
    if (liveConnection != null) {
      _paintConnector(canvas, liveConnection, scale, selected: true);
    }

    for (final item in controller.items) {
      if (item is ConnectorItem) continue;
      final bounds = controller.itemBounds(item);
      if (!bounds.overlaps(visible)) continue;
      switch (item) {
        case TextItem():
          _paintText(canvas, item, bounds);
        case StrokeItem():
          _paintStroke(canvas, item);
        case ImageItem():
          _paintImage(canvas, item, bounds);
        case LinkItem():
          _paintLink(canvas, item, bounds);
        case NoteCardItem():
          _paintNoteCard(canvas, item, bounds);
        case ConnectorItem():
          break; // drawn above
      }
    }
    final live = controller.liveStroke;
    if (live != null) _paintStroke(canvas, live, cache: false);

    _paintSelection(canvas, scale);
    canvas.restore();
  }

  void _paintGrid(Canvas canvas, Size size) {
    var spacing = 24 * controller.scale;
    while (spacing < 14) {
      spacing *= 4;
    }
    final origin = controller.offset;
    final startX = origin.dx % spacing;
    final startY = origin.dy % spacing;
    final points = <Offset>[];
    for (var x = startX; x < size.width; x += spacing) {
      for (var y = startY; y < size.height; y += spacing) {
        points.add(Offset(x, y));
      }
    }
    canvas.drawPoints(
      ui.PointMode.points,
      points,
      Paint()
        ..color = const Color(0x14FFFFFF)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );
  }

  static RRect _card(Rect r) =>
      RRect.fromRectAndRadius(r, const Radius.circular(10));

  void _paintText(Canvas canvas, TextItem item, Rect bounds) {
    final background = item.background;
    if (background != null) {
      canvas.drawRRect(
        _card(bounds),
        Paint()
          ..color = Color.alphaBlend(
            background.withValues(alpha: 0.22),
            AppColors.card,
          ),
      );
      canvas.drawRRect(
        _card(bounds),
        Paint()
          ..color = background.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    if (controller.editingId == item.id) {
      // The live text field draws the text; we just frame the box.
      if (background == null) {
        canvas.drawRRect(_card(bounds), Paint()..color = AppColors.hover);
      }
      return;
    }
    controller
        .textLayout(item)
        .paint(
          canvas,
          item.position + const Offset(kTextPadding, kTextPadding),
        );
  }

  void _paintImage(Canvas canvas, ImageItem item, Rect bounds) {
    final asset = controller.resources?.asset(item.assetId);
    final image = asset?.file == null
        ? null
        : controller.resources?.image(asset!.file!);
    final rrect = RRect.fromRectAndRadius(bounds, const Radius.circular(8));
    if (image == null) {
      canvas.drawRRect(rrect, Paint()..color = AppColors.card);
      _paintIcon(canvas, Icons.image_outlined, bounds.center, 28);
      return;
    }
    canvas.save();
    canvas.clipRRect(rrect);
    paintImage(
      canvas: canvas,
      rect: bounds,
      image: image,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
    canvas.restore();
  }

  void _paintLink(Canvas canvas, LinkItem item, Rect bounds) {
    final layout = controller.cardLayout(item);
    final rrect = _card(bounds);
    canvas.drawRRect(rrect, Paint()..color = AppColors.card);
    final asset = controller.resources?.asset(item.assetId);
    if (layout.previewHeight > 0 && asset?.previewFile != null) {
      final image = controller.resources?.image(asset!.previewFile!);
      final previewRect = Rect.fromLTWH(
        bounds.left,
        bounds.top,
        bounds.width,
        layout.previewHeight,
      );
      canvas.save();
      canvas.clipRRect(
        RRect.fromRectAndCorners(
          previewRect,
          topLeft: const Radius.circular(10),
          topRight: const Radius.circular(10),
        ),
      );
      if (image != null) {
        paintImage(
          canvas: canvas,
          rect: previewRect,
          image: image,
          fit: BoxFit.cover,
        );
      } else {
        canvas.drawRect(previewRect, Paint()..color = AppColors.cardRaised);
      }
      canvas.restore();
    }
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = AppColors.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    _paintIcon(
      canvas,
      Icons.link,
      bounds.topLeft +
          Offset(kCardPadding + 8, layout.previewHeight + kCardPadding + 9),
      16,
      color: OrganizerColors.blue,
    );
    for (final (offset, painter) in layout.lines) {
      painter.paint(canvas, bounds.topLeft + offset);
    }
  }

  void _paintNoteCard(Canvas canvas, NoteCardItem item, Rect bounds) {
    final layout = controller.cardLayout(item);
    final rrect = _card(bounds);
    canvas.drawRRect(rrect, Paint()..color = AppColors.cardRaised);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = AppColors.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    _paintIcon(
      canvas,
      Icons.description_outlined,
      bounds.topLeft + const Offset(kCardPadding + 6, kCardPadding + 6),
      13,
      color: AppColors.textFaint,
    );
    final label = layoutText(
      TextSpan(
        text: 'NOTE',
        style: canvasTextStyle(10, bold: true, color: AppColors.textFaint),
      ),
      100,
    );
    label.paint(
      canvas,
      bounds.topLeft + const Offset(kCardPadding + 16, kCardPadding - 1),
    );
    label.dispose();
    for (final (offset, painter) in layout.lines) {
      painter.paint(canvas, bounds.topLeft + offset);
    }
  }

  void _paintIcon(
    Canvas canvas,
    IconData icon,
    Offset center,
    double size, {
    Color color = AppColors.textFaint,
  }) {
    final painter = layoutText(
      TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: color,
        ),
      ),
      size * 2,
    );
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  void _paintStroke(Canvas canvas, StrokeItem stroke, {bool cache = true}) {
    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final points = stroke.points;
    if (points.length == 1) {
      canvas.drawCircle(
        points.first.offset,
        stroke.strokeWidth / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }
    final path = cache
        ? (_pathCache[stroke] ??= _smoothPath(points))
        : _smoothPath(points);
    canvas.drawPath(path, paint);
  }

  /// Quadratic curves through segment midpoints give smooth lines from
  /// coarse mouse samples.
  static Path _smoothPath(List<StrokePoint> points) {
    final path = Path()..moveTo(points.first.x, points.first.y);
    for (var i = 1; i < points.length - 1; i++) {
      final p = points[i].offset;
      final mid = Offset.lerp(p, points[i + 1].offset, 0.5)!;
      path.quadraticBezierTo(p.dx, p.dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.x, points.last.y);
    return path;
  }

  /// A connection: a line with small dots where it meets the two items.
  void _paintConnector(
    Canvas canvas,
    (Offset, Offset) ends,
    double scale, {
    required bool selected,
  }) {
    final color = selected ? AppColors.accent : const Color(0xFF8A8A8A);
    final line = Paint()
      ..color = color
      ..strokeWidth = (selected ? 2.5 : 1.6) / scale
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(ends.$1, ends.$2, line);
    final dot = Paint()..color = color;
    canvas.drawCircle(ends.$1, 3 / scale, dot);
    canvas.drawCircle(ends.$2, 3 / scale, dot);
  }

  void _paintSelection(Canvas canvas, double scale) {
    final outline = Paint()
      ..color = AppColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / scale;
    final selected = controller.selectedItems
        .where((i) => i is! ConnectorItem)
        .toList();
    for (final item in selected) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          controller.itemBounds(item).inflate(3 / scale),
          Radius.circular(8 / scale),
        ),
        outline,
      );
    }
    if (selected.length == 1 && controller.tool == CanvasTool.select) {
      final corner = controller.itemBounds(selected.first).bottomRight;
      final handle = Rect.fromCenter(
        center: corner,
        width: CanvasController.handleSize / scale,
        height: CanvasController.handleSize / scale,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(handle, Radius.circular(2 / scale)),
        Paint()..color = AppColors.text,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(handle, Radius.circular(2 / scale)),
        outline,
      );
    }

    final marquee = controller.marquee;
    if (marquee != null) {
      canvas.drawRect(marquee, Paint()..color = const Color(0x1A4D8FD6));
      canvas.drawRect(marquee, outline..strokeWidth = 1 / scale);
    }

    final lasso = controller.lassoPoints;
    if (lasso.length >= 2) {
      final lassoPath = Path()..moveTo(lasso.first.dx, lasso.first.dy);
      for (var i = 1; i < lasso.length; i++) {
        lassoPath.lineTo(lasso[i].dx, lasso[i].dy);
      }
      lassoPath.close();
      canvas.drawPath(lassoPath, Paint()..color = const Color(0x1A4D8FD6));
      canvas.drawPath(
        lassoPath,
        outline
          ..strokeWidth = 1.2 / scale
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(CanvasPainter oldDelegate) =>
      oldDelegate.controller != controller;
}

/// A small overview of the whole canvas with the visible area marked.
/// Clicking or dragging on it moves the camera there.
class MinimapPainter extends CustomPainter {
  MinimapPainter(this.controller, this.viewport) : super(repaint: controller);

  final CanvasController controller;
  final Size viewport;

  /// World rect shown by the minimap and the scale used to fit it.
  (Rect, double) mapping(Size size) {
    final visible = controller.visibleWorld(viewport);
    final content = controller.contentBounds();
    var world = content == null ? visible : content.expandToInclude(visible);
    world = world.inflate(world.longestSide * 0.08 + 50);
    final s = (size.width / world.width) < (size.height / world.height)
        ? size.width / world.width
        : size.height / world.height;
    return (world, s);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final (world, s) = mapping(size);
    final origin = Offset(
      (size.width - world.width * s) / 2,
      (size.height - world.height * s) / 2,
    );
    Rect map(Rect r) => Rect.fromLTWH(
      origin.dx + (r.left - world.left) * s,
      origin.dy + (r.top - world.top) * s,
      r.width * s,
      r.height * s,
    );
    final itemPaint = Paint()..color = const Color(0x55FFFFFF);
    for (final item in controller.items) {
      final r = map(controller.itemBounds(item));
      canvas.drawRect(
        Rect.fromLTWH(
          r.left,
          r.top,
          r.width < 1.5 ? 1.5 : r.width,
          r.height < 1.5 ? 1.5 : r.height,
        ),
        item is StrokeItem
            ? (Paint()..color = item.color.withValues(alpha: 0.5))
            : itemPaint,
      );
    }
    final view = map(controller.visibleWorld(viewport));
    canvas.drawRect(view, Paint()..color = const Color(0x144D8FD6));
    canvas.drawRect(
      view,
      Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  /// World point under a minimap position.
  Offset toWorld(Offset local, Size size) {
    final (world, s) = mapping(size);
    final origin = Offset(
      (size.width - world.width * s) / 2,
      (size.height - world.height * s) / 2,
    );
    return world.topLeft + (local - origin) / s;
  }

  @override
  bool shouldRepaint(MinimapPainter old) =>
      old.controller != controller || old.viewport != viewport;
}
