import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../platform/input_hints.dart';
import '../ink/pen_sizes.dart';
import 'canvas_controller.dart';

const _canvasFormatColors = [
  AppColors.text,
  AppColors.textMuted,
  AppColors.accent,
  AppColors.accentSecondary,
  AppColors.success,
  AppColors.warm,
];
const _canvasFormatColorNames = [
  'Soft White',
  'Warm Grey',
  'Steel Blue',
  'Dusty Blue',
  'Dusty Mint',
  'Champagne',
];

/// Floating vertical tool palette on the left of the canvas.
class CanvasToolbar extends StatelessWidget {
  const CanvasToolbar({
    super.key,
    required this.controller,
    required this.onAddImage,
    required this.onAddLink,
    this.onAddDocument,
    this.onMore,
  });

  final CanvasController controller;
  final VoidCallback onAddImage;
  final VoidCallback onAddLink;
  final VoidCallback? onAddDocument;

  /// Opens the canvas menu (versions, components, links to mindmaps);
  /// on Windows it is also on right-click.
  final ValueChanged<Offset>? onMore;

  @override
  Widget build(BuildContext context) {
    final tool = controller.tool;
    Widget toolButton(CanvasTool t, Widget icon, String label) => ToolButton(
      icon: icon,
      tooltip: label,
      active: tool == t,
      onPressed: () => controller.tool = t,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ToolPanel(
          children: [
            toolButton(
              CanvasTool.select,
              Transform.flip(
                flipX: true,
                child: const Icon(Icons.near_me_outlined, size: 18),
              ),
              'Select & move  (V)',
            ),
            toolButton(
              CanvasTool.lasso,
              const Icon(Icons.gesture, size: 18),
              'Lasso select  (L)',
            ),
            toolButton(
              CanvasTool.pan,
              const Icon(Icons.pan_tool_outlined, size: 17),
              'Pan  (H, or hold Space / middle mouse)',
            ),
            const _PanelDivider(),
            toolButton(
              CanvasTool.pen,
              const Icon(Icons.draw_outlined, size: 18),
              'Draw  (P)',
            ),
            toolButton(
              CanvasTool.highlighter,
              const Icon(Icons.highlight, size: 18),
              'Highlighter',
            ),
            toolButton(
              CanvasTool.eraser,
              const _EraserIcon(),
              'Eraser — removes drawings  (E)',
            ),
            toolButton(
              CanvasTool.text,
              const Icon(Icons.title, size: 18),
              touchFirst
                  ? 'Note  (or double-tap)'
                  : 'Note  (T, or double-click)',
            ),
            toolButton(
              CanvasTool.connect,
              const Icon(Icons.share_outlined, size: 18),
              touchFirst
                  ? 'Connect — tap one item, then another (or drag)'
                  : 'Connect — click one item, then another, or drag  (C)',
            ),
            const _PanelDivider(),
            ToolButton(
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              tooltip: 'Add photos from this PC',
              onPressed: onAddImage,
            ),
            if (onAddDocument != null)
              ToolButton(
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                tooltip: 'Add PDF documents from this PC',
                onPressed: onAddDocument!,
              ),
            ToolButton(
              icon: const Icon(Icons.add_link, size: 18),
              tooltip: 'Add link  (or paste a URL with Ctrl+V)',
              onPressed: onAddLink,
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        ToolPanel(
          children: [
            ToolButton(
              icon: const Icon(Icons.undo, size: 18),
              tooltip: 'Undo  (Ctrl+Z)',
              onPressed: controller.canUndo ? controller.undo : null,
            ),
            ToolButton(
              icon: const Icon(Icons.redo, size: 18),
              tooltip: 'Redo  (Ctrl+Y)',
              onPressed: controller.canRedo ? controller.redo : null,
            ),
            if (onMore != null)
              Builder(
                builder: (context) => ToolButton(
                  key: const ValueKey('canvas-more'),
                  icon: const Icon(Icons.more_horiz, size: 18),
                  tooltip: 'More: versions, components, links to mindmaps',
                  onPressed: () {
                    final box = context.findRenderObject() as RenderBox;
                    onMore!(box.localToGlobal(box.size.center(Offset.zero)));
                  },
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Context options shown at the top of the canvas: pen colours/widths while
/// drawing, formatting and actions for the current selection.
class CanvasContextBar extends StatelessWidget {
  const CanvasContextBar({
    super.key,
    required this.controller,
    required this.onActivate,
    required this.onRefreshLink,
    this.onEraser,
    this.onPenWidth,
    this.collapsed = false,
    this.onToggleCollapsed,
  });

  /// Folded away (see [CollapsibleBar]); [onToggleCollapsed] null: the
  /// strip cannot be folded (e.g. inside a dialog).
  final bool collapsed;
  final VoidCallback? onToggleCollapsed;

  final CanvasController controller;
  final void Function(CanvasItem) onActivate;
  final void Function(LinkItem) onRefreshLink;

  /// Keeps eraser changes (mode, size) for next time; without it they
  /// apply to this canvas only.
  final EraserChange? onEraser;

  /// Keeps the chosen pen thickness for next time (else this canvas only).
  final void Function(CanvasController c, double width)? onPenWidth;

  static const _penColors = InkColors.all;
  static const _highlighterColors = InkColors.all;
  static const _highlighterWidths = [12.0, 18.0, 26.0, 36.0];
  static const _fontSizes = {'S': 13.0, 'M': 16.0, 'L': 22.0, 'XL': 32.0};

  /// The strip, folded away with its own handle when it has anything.
  @override
  Widget build(BuildContext context) {
    final panel = _panel(context);
    final toggle = onToggleCollapsed;
    if (toggle == null || panel is SizedBox) return panel;
    return CollapsibleBar(
      collapsed: collapsed,
      onToggle: toggle,
      vertical: false,
      what: 'colours and options',
      handleKey: const ValueKey('context-bar-collapse'),
      child: panel,
    );
  }

  Widget _panel(BuildContext context) {
    final c = controller;
    if (c.tool == CanvasTool.pen) {
      return ToolPanel(
        horizontal: true,
        children: [
          for (final color in _penColors)
            _Swatch(
              color: color,
              active: c.penColor == color,
              onTap: () => c.setPen(color: color),
            ),
          const _PanelDivider(vertical: true),
          for (final width in penSizes)
            ToolButton(
              key: ValueKey('pen-size-$width'),
              tooltip: 'Line width $width',
              active: c.penWidth == width,
              onPressed: () => onPenWidth != null
                  ? onPenWidth!(c, width)
                  : c.setPen(width: width),
              icon: Container(
                width: (width + 2).clamp(2.5, 20.0),
                height: (width + 2).clamp(2.5, 20.0),
                decoration: const BoxDecoration(
                  color: AppColors.text,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          const _PanelDivider(vertical: true),
          ToolButton(
            key: const ValueKey('canvas-shapes'),
            tooltip: c.recognizeShapes
                ? 'Clean shapes: on (rough lines, triangles, rectangles '
                      'and circles become neat)'
                : 'Clean shapes: off',
            active: c.recognizeShapes,
            onPressed: () {
              c.recognizeShapes = !c.recognizeShapes;
            },
            icon: const Icon(Icons.category_outlined, size: 17),
          ),
        ],
      );
    }
    if (c.tool == CanvasTool.highlighter) {
      return ToolPanel(
        horizontal: true,
        children: [
          for (final color in _highlighterColors)
            _Swatch(
              color: color,
              active: c.highlighterColor == color,
              onTap: () => c.setHighlighter(color: color),
            ),
          const _PanelDivider(vertical: true),
          for (final width in _highlighterWidths)
            ToolButton(
              tooltip: 'Highlighter width',
              active: c.highlighterWidth == width,
              onPressed: () => c.setHighlighter(width: width),
              icon: Container(
                width: 14,
                height: (width / 2.5).clamp(4.0, 14.0),
                decoration: BoxDecoration(
                  color: c.highlighterColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      );
    }
    if (c.tool == CanvasTool.eraser) {
      return EraserPanel(controller: c, onChange: onEraser);
    }
    final selected = c.selectedItems;
    final selecting = c.tool == CanvasTool.select || c.tool == CanvasTool.lasso;
    if (!selecting || selected.isEmpty || c.isDragging) {
      return const SizedBox.shrink();
    }
    final texts = selected.whereType<TextItem>().toList();
    final first = texts.isEmpty ? null : texts.first;
    final single = selected.length == 1 ? selected.first : null;

    return ToolPanel(
      horizontal: true,
      children: [
        if (first != null) ...[
          for (final entry in _fontSizes.entries)
            ToolButton(
              tooltip: 'Text size',
              active: first.fontSize == entry.value,
              onPressed: () => c.setFontSize(entry.value),
              icon: Text(
                entry.key,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const _PanelDivider(vertical: true),
          ToolButton(
            tooltip: 'Bold',
            active: first.bold,
            onPressed: () =>
                c.updateSelectedTexts((t) => t.copyWith(bold: !first.bold)),
            icon: const Icon(Icons.format_bold, size: 18),
          ),
          ToolButton(
            tooltip: 'Italic',
            active: first.italic,
            onPressed: () =>
                c.updateSelectedTexts((t) => t.copyWith(italic: !first.italic)),
            icon: const Icon(Icons.format_italic, size: 18),
          ),
          ToolButton(
            tooltip: 'Alignment',
            onPressed: () {
              final next = TextAlignment.values[(first.align.index + 1) % 3];
              c.updateSelectedTexts((t) => t.copyWith(align: next));
            },
            icon: Icon(switch (first.align) {
              TextAlignment.left => Icons.format_align_left,
              TextAlignment.center => Icons.format_align_center,
              TextAlignment.right => Icons.format_align_right,
            }, size: 18),
          ),
          _ColorMenu(
            tooltip: 'Text colour',
            icon: Icons.format_color_text,
            current: first.textColor,
            noneLabel: 'Default',
            onSelected: (color) => c.updateSelectedTexts(
              (t) => t.copyWith(textColor: () => color),
            ),
          ),
          _ColorMenu(
            tooltip: 'Note background',
            icon: Icons.format_color_fill,
            current: first.background,
            noneLabel: 'None',
            onSelected: (color) => c.updateSelectedTexts(
              (t) => t.copyWith(background: () => color),
            ),
          ),
          const _PanelDivider(vertical: true),
        ],
        if (single is LinkItem) ...[
          ToolButton(
            tooltip: 'Open link in browser  (double-click)',
            onPressed: () => onActivate(single),
            icon: const Icon(Icons.open_in_new, size: 17),
          ),
          ToolButton(
            tooltip: 'Fetch title & preview again',
            onPressed: () => onRefreshLink(single),
            icon: const Icon(Icons.refresh, size: 17),
          ),
          const _PanelDivider(vertical: true),
        ],
        if (single is NoteCardItem) ...[
          ToolButton(
            tooltip: 'Open note  (double-click)',
            onPressed: () => onActivate(single),
            icon: const Icon(Icons.open_in_new, size: 17),
          ),
          const _PanelDivider(vertical: true),
        ],
        if (selected.any((i) => i is StrokeItem || i is TextItem))
          PopupMenuButton<Color>(
            key: const ValueKey('canvas-recolor'),
            tooltip: 'Recolor ink and text',
            position: PopupMenuPosition.under,
            onSelected: c.recolorSelection,
            itemBuilder: (_) => [
              for (final color in InkColors.all)
                PopupMenuItem(
                  value: color,
                  height: 30,
                  child: Container(width: 70, height: 14, color: color),
                ),
            ],
            child: const SizedBox(
              width: 36,
              height: 36,
              child: Icon(
                Icons.palette_outlined,
                size: 17,
                color: AppColors.textMuted,
              ),
            ),
          ),
        PopupMenuButton<int>(
          key: const ValueKey('canvas-tag'),
          tooltip: 'Tag (colored dots, glows in the minimap)',
          position: PopupMenuPosition.under,
          onSelected: (i) => c.tagSelection(i < 0 ? null : i),
          itemBuilder: (_) => [
            const PopupMenuItem(value: -1, height: 30, child: Text('No tag')),
            for (var i = 0; i < CanvasTagColors.selected.length; i++)
              PopupMenuItem(
                value: i,
                height: 30,
                child: Row(
                  children: [
                    for (var k = 0; k < 2; k++)
                      Container(
                        width: 12,
                        height: 12,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: CanvasTagColors.selected[i],
                          shape: BoxShape.circle,
                        ),
                      ),
                    Text('Tag ${i + 1}'),
                  ],
                ),
              ),
          ],
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(
              Icons.sell_outlined,
              size: 17,
              color: single != null && c.tagOf(single.id) != null
                  ? CanvasTagColors.selected[c.tagOf(single.id)!]
                  : AppColors.textMuted,
            ),
          ),
        ),
        ToolButton(
          key: const ValueKey('canvas-lock'),
          tooltip: selected.every((i) => c.isLocked(i.id))
              ? 'Unlock'
              : 'Lock (cannot be moved, edited or deleted)',
          active: selected.every((i) => c.isLocked(i.id)),
          onPressed: c.toggleLockSelection,
          icon: Icon(
            selected.every((i) => c.isLocked(i.id))
                ? Icons.lock
                : Icons.lock_open,
            size: 17,
          ),
        ),
        if (selected.length > 1 || c.groupOf(selected.first.id) != null)
          ToolButton(
            key: const ValueKey('canvas-group'),
            tooltip:
                c.groupOf(selected.first.id) != null &&
                    selected.every(
                      (i) => c.groupOf(i.id) == c.groupOf(selected.first.id),
                    )
                ? 'Ungroup'
                : 'Group (select and move together)',
            onPressed: () {
              final g = c.groupOf(selected.first.id);
              if (g != null && selected.every((i) => c.groupOf(i.id) == g)) {
                c.ungroupSelection();
              } else {
                c.groupSelection();
              }
            },
            icon: const Icon(Icons.workspaces_outline, size: 17),
          ),
        if (selected.any((i) => i is StrokeItem))
          ToolButton(
            key: const ValueKey('canvas-rotate'),
            tooltip: 'Rotate ink 90°',
            onPressed: () => c.rotateSelection(math.pi / 2),
            icon: const Icon(Icons.rotate_90_degrees_cw_outlined, size: 17),
          ),
        if (selected.any((i) => i is ImageItem || i is LinkItem))
          ToolButton(
            key: const ValueKey('canvas-reference'),
            tooltip: 'Use as reference (faint, behind the ink, not selectable)',
            onPressed: c.makeSelectionReference,
            icon: const Icon(Icons.layers_outlined, size: 17),
          ),
        const _PanelDivider(vertical: true),
        ToolButton(
          tooltip: 'Duplicate  (Ctrl+D)',
          onPressed: c.duplicateSelection,
          icon: const Icon(Icons.copy_all_outlined, size: 17),
        ),
        ToolButton(
          tooltip: 'Bring to front',
          onPressed: c.bringToFront,
          icon: const Icon(Icons.flip_to_front, size: 17),
        ),
        ToolButton(
          tooltip: 'Send to back',
          onPressed: c.sendToBack,
          icon: const Icon(Icons.flip_to_back, size: 17),
        ),
        ToolButton(
          tooltip: 'Delete  (Del)',
          onPressed: c.deleteSelection,
          icon: const Icon(Icons.delete_outline, size: 17),
        ),
      ],
    );
  }
}

class _ColorMenu extends StatelessWidget {
  const _ColorMenu({
    required this.tooltip,
    required this.icon,
    required this.current,
    required this.noneLabel,
    required this.onSelected,
  });

  final String tooltip;
  final IconData icon;
  final Color? current;
  final String noneLabel;
  final ValueChanged<Color?> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: tooltip,
      position: PopupMenuPosition.under,
      onSelected: (i) => onSelected(i < 0 ? null : _canvasFormatColors[i]),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: -1,
          height: 34,
          child: Row(
            children: [
              const Icon(Icons.block, size: 14, color: AppColors.textFaint),
              const SizedBox(width: 10),
              Text(noneLabel),
            ],
          ),
        ),
        for (var i = 0; i < _canvasFormatColors.length; i++)
          PopupMenuItem(
            value: i,
            height: 34,
            child: Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: _canvasFormatColors[i],
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Text(_canvasFormatColorNames[i]),
              ],
            ),
          ),
      ],
      child: SizedBox(
        width: 36,
        height: 36,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: AppColors.textMuted),
            const SizedBox(height: 2),
            Container(
              width: 16,
              height: 3,
              decoration: BoxDecoration(
                color: current ?? AppColors.textFaint,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ToolPanel extends StatelessWidget {
  const ToolPanel({super.key, required this.children, this.horizontal = false});

  final List<Widget> children;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: horizontal
          ? Row(mainAxisSize: MainAxisSize.min, children: children)
          : Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _PanelDivider extends StatelessWidget {
  const _PanelDivider({this.vertical = false});

  final bool vertical;

  @override
  Widget build(BuildContext context) => Container(
    width: vertical ? 1 : 20,
    height: vertical ? 20 : 1,
    margin: vertical
        ? const EdgeInsets.symmetric(horizontal: 6)
        : const EdgeInsets.symmetric(vertical: 6),
    color: AppColors.border,
  );
}

class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Material(
        color: active ? AppColors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppColors.hover,
          onTap: onPressed,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: IconTheme.merge(
                data: IconThemeData(
                  color: !enabled
                      ? AppColors.textFaint
                      : active
                      ? AppColors.text
                      : AppColors.textMuted,
                ),
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color: active ? AppColors.text : AppColors.textMuted,
                  ),
                  child: icon,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.active,
    required this.onTap,
  });

  final Color color;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? AppColors.text : Colors.transparent,
              width: 2,
              strokeAlign: BorderSide.strokeAlignOutside,
            ),
          ),
        ),
      ),
    );
  }
}

/// Material Icons has no eraser glyph, so we draw a simple one.
class _EraserIcon extends StatelessWidget {
  const _EraserIcon();

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? AppColors.textMuted;
    return CustomPaint(
      size: const Size(18, 18),
      painter: _EraserPainter(color),
    );
  }
}

class _EraserPainter extends CustomPainter {
  _EraserPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2 - 1);
    canvas.rotate(-0.7);
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 14, height: 8),
      const Radius.circular(2),
    );
    canvas.drawRRect(body, paint);
    canvas.drawLine(const Offset(-1, -4), const Offset(-1, 4), paint);
    canvas.restore();
    canvas.drawLine(
      Offset(size.width * 0.45, size.height - 1.5),
      Offset(size.width - 1, size.height - 1.5),
      paint,
    );
  }

  @override
  bool shouldRepaint(_EraserPainter old) => old.color != color;
}

/// Saves an eraser change (see [EraserPanel]).
typedef EraserChange = Future<void> Function(
  CanvasController c, {
  EraserMode? mode,
  double? size,
});

/// The eraser's options: whole strokes or only the part under the eraser,
/// and its size (shown as a circle of that size).
class EraserPanel extends StatelessWidget {
  const EraserPanel({super.key, required this.controller, this.onChange});

  final CanvasController controller;
  final EraserChange? onChange;

  static const sizes = [8.0, 16.0, 32.0, 56.0];

  void _set({EraserMode? mode, double? size}) {
    final save = onChange;
    if (save != null) {
      save(controller, mode: mode, size: size);
    } else {
      controller.setEraser(mode: mode, size: size);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ToolPanel(
      key: const ValueKey('eraser-panel'),
      horizontal: true,
      children: [
        ToolButton(
          key: const ValueKey('eraser-mode-stroke'),
          tooltip: 'Erase whole strokes',
          active: c.eraserMode == EraserMode.stroke,
          onPressed: () => _set(mode: EraserMode.stroke),
          icon: const Icon(Icons.gesture, size: 18),
        ),
        ToolButton(
          key: const ValueKey('eraser-mode-partial'),
          tooltip: 'Erase only the part under the eraser',
          active: c.eraserMode == EraserMode.partial,
          onPressed: () => _set(mode: EraserMode.partial),
          icon: const Icon(Icons.content_cut, size: 18),
        ),
        const _PanelDivider(vertical: true),
        for (final size in sizes)
          ToolButton(
            key: ValueKey('eraser-size-${size.round()}'),
            tooltip: 'Eraser size',
            active: c.eraserSize == size,
            onPressed: () => _set(size: size),
            icon: Container(
              width: (size / 3).clamp(4.0, 20.0),
              height: (size / 3).clamp(4.0, 20.0),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.text, width: 1.5),
              ),
            ),
          ),
      ],
    );
  }
}

/// Background dot visibility for the surface of [c] (Mindmap or Archive),
/// changed live. Only the dots fade; items and text stay as they are.
Future<void> showDotOpacityDialog(
  BuildContext context,
  CanvasController c,
  Future<void> Function(CanvasController c, double value) save,
) => showDialog<void>(
  context: context,
  builder: (context) => StatefulBuilder(
    builder: (context, setState) => AlertDialog(
      title: const Text('Background dots', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              key: const ValueKey('dot-opacity-slider'),
              value: c.dotOpacity,
              min: CanvasController.dotOpacityMin,
              max: CanvasController.dotOpacityMax,
              onChanged: (v) {
                c.setDotOpacity(v); // the dots change right away
                setState(() {});
              },
              onChangeEnd: (v) => save(c, v),
            ),
            Text(
              '${(c.dotOpacity * 100).round()}% · '
              '${c.dotOpacity <= 0.03 ? 'nearly invisible' : 'visible'}',
              key: const ValueKey('dot-opacity-value'),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('dot-opacity-reset'),
          onPressed: () {
            c.setDotOpacity(CanvasController.defaultDotOpacity);
            save(c, CanvasController.defaultDotOpacity);
            setState(() {});
          },
          child: const Text('Default'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    ),
  ),
);

/// A tool strip that can be folded away with its own handle. Folding only
/// hides it: the active tool, colour, thickness and eraser stay as they
/// are. The handle takes its own taps, so they never reach the canvas.
class CollapsibleBar extends StatelessWidget {
  const CollapsibleBar({
    super.key,
    required this.collapsed,
    required this.onToggle,
    required this.vertical,
    required this.what,
    required this.child,
    this.handleKey,
  });

  final bool collapsed;
  final VoidCallback onToggle;

  /// A vertical strip folds upward; a horizontal one folds to the left.
  final bool vertical;

  /// What the strip holds, for the tooltip ("tools", "colours").
  final String what;
  final Widget child;
  final Key? handleKey;

  @override
  Widget build(BuildContext context) {
    final handle = Tooltip(
      message: collapsed ? 'Show $what' : 'Hide $what',
      child: Material(
        color: AppColors.cardRaised,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          key: handleKey,
          customBorder: const CircleBorder(),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Icon(
              vertical
                  ? (collapsed ? Icons.expand_more : Icons.expand_less)
                  : (collapsed ? Icons.chevron_right : Icons.chevron_left),
              size: 16,
              color: AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
    final body = AnimatedSize(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      alignment: vertical ? Alignment.topCenter : Alignment.centerLeft,
      child: collapsed ? const SizedBox.shrink() : child,
    );
    return vertical
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [handle, const SizedBox(height: 4), body],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [body, const SizedBox(width: 4), handle],
          );
  }
}
