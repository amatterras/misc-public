// How solid the pen draws (its opacity) and whether it shades when the
// Pencil is laid flat: one small dialog, shared by the Canvas, note pages
// and the Calendar. This is the pen's own ink only; the page, the dots and
// the highlighter are not affected.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/design_tokens.dart';
import '../../app/popups.dart';
import '../../data/models/canvas_models.dart';
import '../canvas/canvas_controller.dart';
import 'stroke_geometry.dart';

/// Opens the pen opacity dialog for [ink]; the choice is kept for next
/// time (this device) and used by every drawing surface.
Future<void> showPenLookDialog(
  BuildContext context,
  AppState state,
  CanvasController ink,
) => showAppDialog<void>(
  context: context,
  builder: (context) => StatefulBuilder(
    builder: (context, setState) {
      final opacity = ink.penOpacity;
      return AlertDialog(
        title: const Text(
          'Pen opacity',
          style: TextStyle(fontSize: AppType.sizeHeading),
        ),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const ValueKey('pen-opacity-preview'),
                height: 64,
                width: double.infinity,
                child: CustomPaint(
                  painter: PenLookPreviewPainter(
                    ink.penWidth,
                    ink.penColor,
                    opacity,
                  ),
                ),
              ),
              Slider(
                key: const ValueKey('pen-opacity-slider'),
                value: opacity,
                min: CanvasController.penOpacityMin,
                max: 1,
                divisions: 18,
                label: '${(opacity * 100).round()} %',
                onChanged: (v) {
                  ink.setPen(opacity: v);
                  setState(() {});
                },
                onChangeEnd: (v) => state.setPenLook(opacity: v),
              ),
              Text(
                '${(opacity * 100).round()} % · new strokes only',
                style: const TextStyle(fontSize: AppType.sizeLabel),
              ),
              SwitchListTile(
                key: const ValueKey('pen-tilt-shading'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'Shade when the Pencil is tilted',
                  style: TextStyle(fontSize: AppType.sizeLabel),
                ),
                subtitle: const Text(
                  'The line widens as the Pencil is laid flat. Only pens '
                  'that report their angle.',
                  style: TextStyle(fontSize: AppType.sizeMeta),
                ),
                value: ink.penTiltShading,
                onChanged: (v) {
                  ink.setPen(tilt: v);
                  setState(() {});
                  state.setPenLook(tilt: v);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
    },
  ),
);

/// A sample of the pen's ink at the chosen opacity, crossing itself and a
/// darker bar, drawn by the same code as real strokes.
class PenLookPreviewPainter extends CustomPainter {
  PenLookPreviewPainter(this.width, this.color, this.opacity);

  final double width;
  final Color color;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    // Something behind the ink, so see-through shows.
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.42, 6, size.width * 0.16, size.height - 12),
      Paint()..color = const Color(0x55808080),
    );
    final points = [
      for (var i = 0; i <= 48; i++)
        StrokePoint(
          16 + (size.width - 32) * i / 48,
          size.height / 2 + math.sin(i / 48 * 2 * math.pi) * size.height * 0.28,
          0.25 + 0.5 * math.sin(i / 48 * math.pi),
        ),
    ];
    paintStroke(
      canvas,
      StrokeItem(
        id: 'preview',
        points: points,
        color: color.withValues(alpha: color.a * opacity),
        strokeWidth: math.max(width, 3),
        pressureWidth: true,
        penInk: opacity < 0.99,
      ),
    );
  }

  @override
  bool shouldRepaint(PenLookPreviewPainter old) =>
      old.width != width || old.color != color || old.opacity != opacity;
}
