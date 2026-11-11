import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/background_palette.dart';
import '../../app/theme.dart';
import '../../app/canvas_ops.dart' show canvasLinkTarget;
import '../../data/models/canvas_models.dart';
import '../tags/tag_ui.dart' show tagForeground;
import 'canvas_controller.dart';
import 'connector_geometry.dart';
import 'canvas_text.dart';
import '../ink/ink_metrics.dart';
import '../ink/stroke_geometry.dart';

/// Paints the whole canvas: dot grid, items, selection and live drawing.
///
/// Everything is drawn in one pass with a camera transform instead of as
/// separate widgets, so the space is truly unbounded and stays fast with
/// many items (anything off-screen is skipped).
class CanvasPainter extends CustomPainter {
  CanvasPainter(
    this.controller, {
    this.page,
    this.pageScale = 1,
    this.itemOpacity = const {},
    this.itemOpacityFor,
    Listenable? repaint,
    bool? lightTheme,
    this.rasterCache,
    this.devicePixelRatio = 0,
  }) : light = BackgroundPalette.isLight(lightTheme),
       super(repaint: repaint ?? controller);

  /// Keeps the finished drawing as one image between changes (see
  /// [InkRasterCache]); null paints every item every time.
  final InkRasterCache? rasterCache;

  /// Physical pixels per logical pixel; needed for [rasterCache].
  final double devicePixelRatio;

  final CanvasController controller;

  /// The theme the background dots are drawn for (black dots on the light
  /// canvas, white on the dark one); see BackgroundPalette.
  final bool light;

  /// Notebook page: only this world rectangle is drawn, at [pageScale],
  /// with no grid (the page widget draws the paper). Null for a canvas.
  final Rect? page;
  final double pageScale;

  /// Per-item alpha overrides used for short, item-specific transitions.
  final Map<String, double> itemOpacity;

  /// Optional live opacity lookup for animations that should repaint without
  /// rebuilding the canvas widget tree on every animation tick.
  final double Function(CanvasItem item)? itemOpacityFor;

  static final Expando<StrokeShape> _shapeCache = Expando();

  @override
  void paint(Canvas canvas, Size size) {
    final cache = rasterCache;
    if (cache == null || !cache.draw(canvas, size, this)) {
      _paintContent(canvas, size);
    }
    _paintOverlay(canvas, size);
  }

  /// The zoom and the visible world rectangle for a paint of [size].
  (double, Rect) _view(Size size) {
    final page = this.page;
    if (page != null) return (pageScale, page);
    final scale = controller.scale;
    return (scale, controller.visibleWorld(size).inflate(20 / scale));
  }

  /// Moves [canvas] from widget pixels to world units.
  void _toWorld(Canvas canvas, Size size) {
    final page = this.page;
    if (page == null) {
      canvas.translate(controller.offset.dx, controller.offset.dy);
      canvas.scale(controller.scale);
    } else {
      canvas.clipRect(Offset.zero & size);
      canvas.translate(-page.left * pageScale, -page.top * pageScale);
      canvas.scale(pageScale);
    }
  }

  /// Marks, tags and the selection: drawn over the finished drawing on
  /// every paint (they change with the selection and are cheap).
  void _paintOverlay(Canvas canvas, Size size) {
    final (scale, visible) = _view(size);
    canvas.save();
    _toWorld(canvas, size);
    _paintMarks(canvas, scale, visible);
    _paintSelection(canvas, scale);
    // Alignment guides and the eraser's footprint follow the pointer, so
    // they are overlay (never baked into the cached ink image).
    _paintAlignOverlay(canvas, scale, visible);
    _paintEraserRing(canvas, scale);
    canvas.restore();
  }

  /// Background, grid and every item: what [InkRasterCache] keeps.
  /// [only]: draw just the items that reach into this world rectangle (the
  /// caller clips to it), for bringing a part of the cached picture up to
  /// date.
  void _paintContent(Canvas canvas, Size size, {Rect? only}) {
    final page = this.page;
    var (scale, visible) = _view(size);
    if (only != null) visible = visible.intersect(only);
    canvas.save();
    if (page == null) {
      // No background fill: the infinite canvas sits on the app-wide
      // atmosphere (plain alpha blending, so cached and live strokes
      // composite identically). Exports paint their own background.
      _paintGrid(canvas, size);
    }
    _toWorld(canvas, size);

    // Reference overlays first and faint: they sit behind everything.
    for (final item in controller.items) {
      if (!controller.isReference(item.id)) continue;
      final bounds = controller.itemBounds(item);
      if (!bounds.overlaps(visible)) continue;
      canvas.saveLayer(
        bounds.inflate(2),
        Paint()..color = const Color.fromRGBO(0, 0, 0, 0.55),
      );
      switch (item) {
        case ImageItem():
          _paintImage(canvas, item, bounds);
        case LinkItem():
          _paintLink(canvas, item, bounds);
        case _:
          break;
      }
      canvas.restore();
    }

    // Mind-map connections first, so they run underneath the items.
    final selectedIds = controller.selection;
    for (final c in controller.drawOrder.whereType<ConnectorItem>()) {
      if (controller.connectorHidden(c)) continue;
      final shape = controller.connectorShape(c);
      if (shape == null) continue;
      _paintConnector(
        canvas,
        shape.points,
        scale,
        smooth: shape.smooth,
        selected: selectedIds.contains(c.id),
        color: c.color,
        handles: selectedIds.contains(c.id) && selectedIds.length == 1 && !c.auto
            ? c.bends
            : const [],
      );
    }
    final liveConnection = controller.liveConnection;
    if (liveConnection != null) {
      // A hand-drawn gesture is shown as the refined line it will become.
      final refined = controller.livePreview;
      _paintConnector(
        canvas,
        refined?.points ?? [liveConnection.$1, liveConnection.$2],
        scale,
        smooth: refined?.smooth ?? true,
        selected: true,
      );
    }

    for (final item in controller.drawOrder) {
      if (item is ConnectorItem || controller.isReference(item.id)) continue;
      final bounds = controller.itemBounds(item);
      if (!bounds.overlaps(visible)) continue;
      final opacity = (itemOpacityFor?.call(item) ?? itemOpacity[item.id] ?? 1)
          .clamp(0.0, 1.0);
      if (opacity < 1) {
        canvas.saveLayer(
          bounds.inflate(4),
          Paint()..color = Colors.white.withValues(alpha: opacity),
        );
      }
      final faded = controller.dimmed?.call(item) ?? false;
      if (faded) {
        canvas.saveLayer(
          bounds.inflate(4),
          Paint()..color = const Color.fromRGBO(0, 0, 0, 0.22),
        );
      }
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
      final highlight = controller.highlighted?.call(item);
      if (highlight != null) {
        final ring = _card(bounds).outerRect.inflate(2.5 / scale);
        canvas.drawRRect(
          RRect.fromRectAndRadius(ring, const Radius.circular(12)),
          Paint()
            ..color = highlight.withValues(alpha: 0.28)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 7 / scale,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(ring, const Radius.circular(12)),
          Paint()
            ..color = highlight
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 / scale,
        );
      }
      if (faded) canvas.restore();
      if (opacity < 1) canvas.restore();
    }
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
        ..color = BackgroundPalette.dot(light: light)
            .withValues(alpha: controller.dotOpacity)
        ..strokeWidth = controller.dotSize
        ..strokeCap = StrokeCap.round,
    );
  }

  /// A lasso tag: a colored dot at the item's top-left and top-right
  /// corners. A locked item: a small padlock at its top-right.
  /// Custom tags: small pills in each tag's own colour just above the
  /// item's top-left corner (screen-sized, so readable at any zoom).
  void _paintCustomTags(Canvas canvas, double scale, Rect visible) {
    for (final item in controller.items) {
      final bounds = controller.itemBounds(item);
      if (!bounds.overlaps(visible.inflate(40 / scale))) continue;
      final tags = controller.shownTagsOf(item);
      if (tags.isEmpty) continue;
      var x = bounds.left;
      final y = bounds.top - 20 / scale;
      for (final t in tags.take(4)) {
        final bg = Color(t.color);
        final text = TextPainter(
          text: TextSpan(
            text: t.name,
            style: TextStyle(fontSize: 10 / scale, color: tagForeground(bg)),
          ),
          maxLines: 1,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 120 / scale);
        final pill = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, text.width + 12 / scale, text.height + 4 / scale),
          Radius.circular(8 / scale),
        );
        canvas.drawRRect(pill, Paint()..color = bg);
        text.paint(canvas, Offset(x + 6 / scale, y + 2 / scale));
        x = pill.right + 4 / scale;
        text.dispose();
      }
    }
  }

  void _paintMarks(Canvas canvas, double scale, Rect visible) {
    _paintCustomTags(canvas, scale, visible);
    for (final (bounds, tag) in controller.taggedUnits) {
      if (!bounds.overlaps(visible)) continue;
      final dot = Paint()..color = CanvasTagColors.selected[tag];
      final ring = Paint()
        ..color = AppColors.background
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / scale;
      for (final corner in [bounds.topLeft, bounds.topRight]) {
        canvas.drawCircle(corner, 8 / scale, dot);
        canvas.drawCircle(corner, 8 / scale, ring);
      }
    }
    for (final unit in controller.unitsOf(controller.items)) {
      if (!unit.every((i) => controller.isLocked(i.id))) continue;
      final bounds = controller.boundsOf(unit)!;
      if (!bounds.overlaps(visible)) continue;
      final painter = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.lock.codePoint),
          style: TextStyle(
            fontFamily: Icons.lock.fontFamily,
            package: Icons.lock.fontPackage,
            fontSize: 13 / scale,
            color: AppColors.textMuted,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        bounds.topRight + Offset(-painter.width - 10 / scale, 2 / scale),
      );
      painter.dispose();
    }
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
    paintEditedImage(canvas, image, bounds, item.edit, rrect: rrect);
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
      asset?.isVideo ?? false
          ? Icons.play_circle_outline
          : canvasLinkTarget(asset?.url) != null
          ? Icons.hub_outlined
          : Icons.link,
      bounds.topLeft +
          Offset(kCardPadding + 8, layout.previewHeight + kCardPadding + 9),
      16,
      color: AppColors.accent,
    );
    for (final (offset, painter) in layout.lines) {
      painter.paint(canvas, bounds.topLeft + offset);
    }
    for (final (rect, color, label) in layout.chips) {
      final r = RRect.fromRectAndRadius(
        rect.shift(bounds.topLeft),
        Radius.circular(rect.height / 2),
      );
      canvas.drawRRect(r, Paint()..color = color.withValues(alpha: 0.16));
      canvas.drawRRect(
        r,
        Paint()
          ..color = color.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      label.paint(canvas, r.outerRect.topLeft + const Offset(7, 3));
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
    Color? color,
  }) {
    final painter = layoutText(
      TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: color ?? AppColors.textFaint,
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

  /// The world rectangle [stroke]'s ink is drawn in.
  Rect _drawnBounds(StrokeItem stroke) {
    final shape = _shapeCache[stroke] ??= strokeShape(stroke);
    final bounds = shape.path.getBounds();
    return shape.filled ? bounds : bounds.inflate(stroke.strokeWidth / 2);
  }

  void _paintStroke(Canvas canvas, StrokeItem stroke) => paintStroke(
    canvas,
    stroke,
    cachedShape: _shapeCache[stroke] ??= strokeShape(stroke),
  );

  /// A connection: a smooth line through [pts] with small dots where it
  /// meets the two items, and round handles on its waypoints when selected.
  void _paintConnector(
    Canvas canvas,
    List<Offset> pts,
    double scale, {
    required bool selected,
    bool smooth = true,
    Color? color,
    List<Offset> handles = const [],
  }) {
    final base = color ?? AppColors.textMuted;
    if (selected) {
      canvas.drawPath(
        connectorPath(pts, smooth: smooth),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = AppColors.accent.withValues(alpha: 0.35)
          ..strokeWidth = 7 / scale
          ..strokeCap = StrokeCap.round,
      );
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..color = base
      ..strokeWidth = (selected ? 2.5 : 1.6) / scale
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(connectorPath(pts, smooth: smooth), line);
    final dot = Paint()..color = base;
    canvas.drawCircle(pts.first, 3 / scale, dot);
    canvas.drawCircle(pts.last, 3 / scale, dot);
    for (final h in handles) {
      canvas.drawCircle(h, 6 / scale, Paint()..color = AppColors.canvas);
      canvas.drawCircle(
        h,
        6 / scale,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = AppColors.accent
          ..strokeWidth = 2 / scale,
      );
    }
  }

  /// Guides, gaps and (with grid snapping) the grid, while objects are moved.
  void _paintAlignOverlay(Canvas canvas, double scale, Rect visible) {
    if (!controller.showingAlignOverlay) return;
    const guideColor = Color(0xFFE56BDA);
    if (controller.gridSnap) {
      final step = controller.gridSize;
      // Skip a grid too fine to see (closer than 6 screen pixels).
      if (step * scale >= 6) {
        final paint = Paint()
          ..color = AppColors.textFaint.withValues(alpha: 0.18)
          ..strokeWidth = 1 / scale;
        final startX = (visible.left / step).floor() * step;
        final startY = (visible.top / step).floor() * step;
        for (var x = startX; x <= visible.right; x += step) {
          canvas.drawLine(Offset(x, visible.top), Offset(x, visible.bottom), paint);
        }
        for (var y = startY; y <= visible.bottom; y += step) {
          canvas.drawLine(Offset(visible.left, y), Offset(visible.right, y), paint);
        }
      }
    }
    final line = Paint()
      ..color = guideColor
      ..strokeWidth = 1 / scale;
    for (final g in controller.activeGuides) {
      if (g.vertical) {
        canvas.drawLine(Offset(g.at, g.from), Offset(g.at, g.to), line);
      } else {
        canvas.drawLine(Offset(g.from, g.at), Offset(g.to, g.at), line);
      }
    }
    for (final m in controller.activeSpacing) {
      if (m.distance <= 0) continue;
      canvas.drawLine(m.a, m.b, line);
      final tick = 4 / scale;
      final horizontal = (m.a.dy - m.b.dy).abs() < 1e-6;
      for (final p in [m.a, m.b]) {
        horizontal
            ? canvas.drawLine(p - Offset(0, tick), p + Offset(0, tick), line)
            : canvas.drawLine(p - Offset(tick, 0), p + Offset(tick, 0), line);
      }
      final text = TextPainter(
        text: TextSpan(
          text: m.distance.round().toString(),
          style: TextStyle(
            fontSize: 11 / scale,
            color: const Color(0xFFFFFFFF),
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final mid = Offset.lerp(m.a, m.b, 0.5)!;
      final box = Rect.fromCenter(
        center: mid,
        width: text.width + 8 / scale,
        height: text.height + 4 / scale,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(4 / scale)),
        Paint()..color = guideColor,
      );
      text.paint(canvas, box.topLeft + Offset(4 / scale, 2 / scale));
      text.dispose();
    }
  }

  /// The eraser's footprint under the pointer: a ring of its real size.
  void _paintEraserRing(Canvas canvas, double scale) {
    final at = controller.hoverPosition;
    if (controller.tool != CanvasTool.eraser || at == null) return;
    final center = controller.toWorld(at);
    final r = controller.effectiveEraserSize / 2 / scale;
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = AppColors.text.withValues(alpha: 0.7)
        ..strokeWidth = 1.2 / scale,
    );
  }

  void _paintSelection(Canvas canvas, double scale) {
    final outline = Paint()
      ..color = AppColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / scale;
    // The item a connection is being made from (connect tool).
    final sourceId = controller.connectSource;
    final source = sourceId == null ? null : controller.itemById(sourceId);
    if (source != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          controller.itemBounds(source).inflate(4 / scale),
          Radius.circular(8 / scale),
        ),
        Paint()
          ..color = AppColors.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 / scale,
      );
    }
    // What the connection would attach to, and the exact point (a ring
    // where it snaps: a line's end or nearest point, or an edge).
    final targetId = controller.connectTarget;
    final target = targetId == null ? null : controller.itemById(targetId);
    final live = controller.liveConnection;
    if (target != null && live != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          controller.itemBounds(target).inflate(4 / scale),
          Radius.circular(8 / scale),
        ),
        Paint()
          ..color = AppColors.accent.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / scale,
      );
      canvas.drawCircle(
        live.$2,
        7 / scale,
        Paint()
          ..color = AppColors.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale,
      );
    }
    // One boundary around the whole selection (a group or many strokes
    // are one object), with exactly two dots: top-left and top-right
    // (the top-right one resizes / scales).
    // Only the Select and Lasso tools show a selection (a text box being
    // typed in shows its own outline).
    final showSelection =
        controller.selectsItems || controller.editingItem != null;
    final bounds = showSelection ? controller.selectionBounds : null;
    if (bounds != null) {
      final box = bounds.inflate(4 / scale);
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(8 / scale)),
        outline,
      );
      for (final dot in [box.topLeft, box.topRight]) {
        canvas.drawCircle(dot, 5 / scale, Paint()..color = AppColors.text);
        canvas.drawCircle(dot, 5 / scale, outline);
      }
    }

    final marquee = controller.marquee;
    if (marquee != null) {
      canvas.drawRect(
        marquee,
        Paint()..color = AppColors.accent.withValues(alpha: 0.10),
      );
      canvas.drawRect(marquee, outline..strokeWidth = 1 / scale);
    }

    final lasso = controller.lassoPoints;
    if (lasso.length >= 2) {
      final lassoPath = Path()..moveTo(lasso.first.dx, lasso.first.dy);
      for (var i = 1; i < lasso.length; i++) {
        lassoPath.lineTo(lasso[i].dx, lasso[i].dy);
      }
      lassoPath.close();
      canvas.drawPath(
        lassoPath,
        Paint()..color = AppColors.accent.withValues(alpha: 0.10),
      );
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
      oldDelegate.controller != controller ||
      oldDelegate.page != page ||
      oldDelegate.pageScale != pageScale ||
      oldDelegate.light != light ||
      oldDelegate.rasterCache != rasterCache ||
      oldDelegate.devicePixelRatio != devicePixelRatio ||
      oldDelegate.itemOpacityFor != itemOpacityFor ||
      oldDelegate.itemOpacity.length != itemOpacity.length ||
      oldDelegate.itemOpacity.entries.any(
        (entry) => oldDelegate.itemOpacity[entry.key] != entry.value,
      );
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
    // Item blocks contrast with the canvas in either theme.
    final itemPaint = Paint()
      ..color = BackgroundPalette.dot().withValues(alpha: 0x55 / 0xFF);
    for (final item in controller.items) {
      final r = map(controller.itemBounds(item));
      // Archive tag selection, or the item's lasso tag color.
      final tag = controller.tagOf(item.id);
      final highlight =
          controller.highlighted?.call(item) ??
          (tag == null ? null : CanvasTagColors.selected[tag]);
      if (highlight != null) {
        final glow = r.inflate(2);
        canvas.drawRect(
          glow,
          Paint()
            ..color = highlight.withValues(alpha: 0.34)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5,
        );
        canvas.drawRect(
          glow,
          Paint()
            ..color = highlight
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
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
    canvas.drawRect(
      view,
      Paint()..color = AppColors.accent.withValues(alpha: 0.08),
    );
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

/// Paints only the stroke being drawn, plus a short predicted tip. It
/// repaints on [CanvasController.liveInk], so each pen movement redraws one
/// stroke instead of the whole canvas.
class LiveInkPainter extends CustomPainter {
  LiveInkPainter(this.controller, {this.page, this.pageScale = 1})
    : super(repaint: controller.liveInk);

  final CanvasController controller;
  final Rect? page;
  final double pageScale;

  @override
  void paint(Canvas canvas, Size size) {
    final live = controller.liveStroke;
    final preview = controller.lineStraightenPreview;
    if (live == null && preview == null) return;
    final page = this.page;
    if (page != null && live != null && !live.bounds.overlaps(page)) return;
    canvas.save();
    if (page == null) {
      canvas.translate(controller.offset.dx, controller.offset.dy);
      canvas.scale(controller.scale);
    } else {
      canvas.clipRect(Offset.zero & size);
      canvas.translate(-page.left * pageScale, -page.top * pageScale);
      canvas.scale(pageScale);
    }
    if (live != null) {
      final metrics = InkMetrics.instance;
      final start = metrics.startTimer();
      // Finished stretches of a long stroke are kept, only the tail near
      // the pen is rebuilt (LiveInkGeometry).
      final shapes = controller.liveGeometry.shapes(
        live,
        controller.predictedPoint,
      );
      metrics.livePainted(metrics.elapsedSince(start));
      for (final shape in shapes) {
        shape.paint(canvas, strokePaint(live, shape));
      }
    }
    if (preview != null) {
      if (page == null || preview.bounds.overlaps(page)) {
        final color = AppColors.accent.withValues(alpha: 0.48);
        final path = Path()
          ..moveTo(preview.points.first.x, preview.points.first.y);
        for (final point in preview.points.skip(1)) {
          path.lineTo(point.x, point.y);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.5, preview.strokeWidth)
            ..strokeCap = StrokeCap.round,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(LiveInkPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.page != page ||
      oldDelegate.pageScale != pageScale;
}

/// The finished drawing of one canvas (or notebook page) kept as a single
/// GPU image while nothing in it changes.
///
/// Without it every frame drew every visible stroke again: Flutter's
/// Impeller renderer has no raster cache, so while the pen moved, a page
/// with thousands of strokes cost as much per frame as its first paint.
/// With it, a frame while writing draws one image plus the live stroke.
///
/// * A finished stroke is added by drawing just that stroke over the old
///   image, and what the eraser removed or cut is brought up to date by
///   redrawing only the touched area ([CanvasController.inkChanges]), not
///   the whole drawing. Erasing in a drawing of thousands of strokes costs
///   what the strokes under the eraser cost.
/// * Any other change (paint epoch), a new size, zoom or position, or a
///   theme switch makes a new image; while the view is moving (panning,
///   pinching) items are drawn directly and no image is made, so moving
///   does not pay for images it would throw away the next frame.
/// * Small drawings ([minItems]) skip it: drawing them directly is cheap.
///
/// Selection, marks and tags are drawn over the image on every paint.
class InkRasterCache {
  /// Switch for the whole app (tests and diagnosis).
  static bool enabled = true;

  /// Fewer items than this are always drawn directly.
  static int minItems = 120;

  /// Largest image kept, in physical pixels (about 64 MB of memory).
  static int maxPixels = 4096 * 4096;

  ui.Image? _image;
  Object? _view;
  int _epoch = -1;
  List<CanvasItem>? _items;
  Object? _lastSeenView;

  /// How the last paint was done (for tests): "direct", "image", "append"
  /// or "rebuild".
  @visibleForTesting
  String lastPaint = 'none';

  /// Draws the finished drawing for [painter] from the image (making or
  /// updating it first when needed). False: draw it directly instead.
  bool draw(Canvas canvas, Size size, CanvasPainter painter) {
    final c = painter.controller;
    final dpr = painter.devicePixelRatio;
    final width = (size.width * dpr).ceil(),
        height = (size.height * dpr).ceil();
    if (!enabled ||
        dpr <= 0 ||
        width <= 0 ||
        height <= 0 ||
        width * height > maxPixels ||
        c.items.length < minItems ||
        c.liveConnection != null ||
        painter.itemOpacity.isNotEmpty) {
      _drop();
      _lastSeenView = null;
      lastPaint = 'direct';
      return false;
    }
    final view = (
      size,
      dpr,
      painter.light,
      painter.page,
      painter.pageScale,
      c.offset,
      c.scale,
      c.dotOpacity,
      c.dotSize,
    );
    final epoch = c.paintEpoch;
    final image = _image;
    if (image != null &&
        _view == view &&
        _epoch == epoch &&
        identical(_items, c.items)) {
      _blit(canvas, image, dpr);
      lastPaint = 'image';
      return true;
    }
    if (image != null &&
        _view == view &&
        c.dimmed == null &&
        c.highlighted == null) {
      final dirty = _pending(c, epoch);
      if (dirty != null) {
        final recorder = ui.PictureRecorder();
        final target = Canvas(recorder);
        target.drawImage(image, Offset.zero, Paint());
        var mode = 'append';
        final (scale, visible) = painter._view(size);
        for (final change in dirty) {
          final stroke = change.stroke;
          // Where the ink really is (a curve can swing a little outside
          // the box around its points).
          Rect? ink;
          for (final s in stroke != null ? [stroke] : change.erased) {
            final b = painter._drawnBounds(s);
            ink = ink?.expandToInclude(b) ?? b;
          }
          if (ink == null || !ink.overlaps(visible)) continue;
          target.save();
          target.scale(dpr);
          if (stroke != null) {
            // A new stroke lies on top of everything: draw it alone.
            painter._toWorld(target, size);
            painter._paintStroke(target, stroke);
          } else {
            // Erased ink: empty the touched area (whole physical pixels,
            // so no seam is left at its edge) and draw what remains
            // there again.
            mode = 'region';
            // Two physical pixels more than the ink's bounds: the soft
            // edge of a line reaches a little past them.
            final world = ink.inflate(2 / (dpr * scale));
            final area = _pixelRect(painter, world, size, dpr);
            target.clipRect(area, doAntiAlias: false);
            target.drawRect(area, Paint()..blendMode = BlendMode.clear);
            painter._paintContent(target, size, only: world);
          }
          target.restore();
        }
        _replace(recorder.endRecording(), width, height);
        _epoch = epoch;
        _items = c.items;
        _blit(canvas, _image!, dpr);
        lastPaint = mode;
        return true;
      }
    }
    if (_lastSeenView != view) {
      // The view is moving (or this is the first paint): draw directly.
      _lastSeenView = view;
      _drop();
      lastPaint = 'direct';
      return false;
    }
    final recorder = ui.PictureRecorder();
    final target = Canvas(recorder);
    target.scale(dpr);
    painter._paintContent(target, size);
    _replace(recorder.endRecording(), width, height);
    _view = view;
    _epoch = epoch;
    _items = c.items;
    _blit(canvas, _image!, dpr);
    lastPaint = 'rebuild';
    return true;
  }

  /// The changes that lead from the drawing in the image to the drawing
  /// now, when every one of them touched only a known area; else null.
  List<InkChange>? _pending(CanvasController c, int epoch) {
    final log = c.inkChanges;
    if (log.isEmpty ||
        log.last.toEpoch != epoch ||
        !identical(log.last.after, c.items)) {
      return null;
    }
    for (var i = log.length - 1; i >= 0; i--) {
      if (log[i].fromEpoch == _epoch && identical(log[i].before, _items)) {
        return log.sublist(i);
      }
    }
    return null;
  }

  /// [world] in widget pixels, grown outwards to whole physical pixels.
  static Rect _pixelRect(
    CanvasPainter painter,
    Rect world,
    Size size,
    double dpr,
  ) {
    final page = painter.page;
    final scale = page == null ? painter.controller.scale : painter.pageScale;
    final origin = page == null
        ? painter.controller.offset
        : Offset(-page.left * scale, -page.top * scale);
    double down(double v) => (v * dpr).floorToDouble() / dpr;
    double up(double v) => (v * dpr).ceilToDouble() / dpr;
    return Rect.fromLTRB(
      down(world.left * scale + origin.dx),
      down(world.top * scale + origin.dy),
      up(world.right * scale + origin.dx),
      up(world.bottom * scale + origin.dy),
    ).intersect(Offset.zero & size);
  }

  void _replace(ui.Picture picture, int width, int height) {
    final next = picture.toImageSync(width, height);
    picture.dispose();
    // Pictures already recorded with the old image keep their own hold
    // on it; this only drops ours.
    _image?.dispose();
    _image = next;
  }

  static void _blit(Canvas canvas, ui.Image image, double dpr) {
    canvas.save();
    canvas.scale(1 / dpr);
    canvas.drawImage(image, Offset.zero, Paint());
    canvas.restore();
  }

  void _drop() {
    _image?.dispose();
    _image = null;
    _view = null;
    _epoch = -1;
    _items = null;
  }

  void dispose() {
    _drop();
    _lastSeenView = null;
  }
}

/// Draws [image] into [bounds] the way [edit] says: cropped, mirrored and
/// turned, never stretched. Transparency is kept (nothing is filled behind
/// it). [bounds] is the final, already-turned box.
void paintEditedImage(
  Canvas canvas,
  ui.Image image,
  Rect bounds,
  ImageEdit edit, {
  RRect? rrect,
}) {
  final iw = image.width.toDouble(), ih = image.height.toDouble();
  final c = edit.crop;
  final src = c == null
      ? Rect.fromLTWH(0, 0, iw, ih)
      : Rect.fromLTRB(c.left * iw, c.top * ih, c.right * iw, c.bottom * ih);
  canvas.save();
  if (rrect != null) canvas.clipRRect(rrect);
  canvas.translate(bounds.center.dx, bounds.center.dy);
  canvas.rotate(edit.turns * math.pi / 2);
  if (edit.flip) canvas.scale(-1, 1);
  // In the turned frame the box is swapped for odd turns.
  final w = edit.turns.isOdd ? bounds.height : bounds.width;
  final h = edit.turns.isOdd ? bounds.width : bounds.height;
  canvas.drawImageRect(
    image,
    src,
    Rect.fromCenter(center: Offset.zero, width: w, height: h),
    Paint()..filterQuality = FilterQuality.medium,
  );
  canvas.restore();
}
