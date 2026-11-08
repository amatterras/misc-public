// The Mindmap's entry screen: what an empty mindmap shows until the first
// thing is written, drawn or added. A comet arc with a sparkle over
// "empty canvas", the line "sketch · plan · think · create", and four
// starting actions. Colours come only from the palette (AppColors /
// AppGradients), so it follows light and dark like the rest of the app.
//
// It only draws and forwards taps: everything outside the buttons ignores
// the pointer, so double-click/double-tap to write and drawing on the
// canvas behind it work exactly as before.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../platform/input_hints.dart';

class EmptyCanvasScreen extends StatelessWidget {
  const EmptyCanvasScreen({
    super.key,
    required this.onAddNote,
    required this.onAddImage,
    required this.onAddText,
    required this.onQuickAdd,
  });

  final VoidCallback onAddNote;
  final VoidCallback onAddImage;
  final VoidCallback onAddText;
  final VoidCallback onQuickAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('empty-canvas'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IgnorePointer(child: _Masthead()),
            const SizedBox(height: 36),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                _StartButton(
                  key: const ValueKey('empty-canvas-note'),
                  icon: Icons.description_outlined,
                  label: 'Add note',
                  tooltip: 'A new note, as a card on this mindmap',
                  onTap: onAddNote,
                ),
                _StartButton(
                  key: const ValueKey('empty-canvas-image'),
                  icon: Icons.image_outlined,
                  label: 'Add image',
                  tooltip: touchFirst
                      ? 'Pick photos or images'
                      : 'Pick images — or paste one with Ctrl+V',
                  onTap: onAddImage,
                ),
                _StartButton(
                  key: const ValueKey('empty-canvas-text'),
                  icon: Icons.title,
                  label: 'Add text',
                  tooltip: touchFirst
                      ? 'Or double-tap anywhere to write · pick the pen to draw'
                      : 'Or double-click anywhere to write · P to draw',
                  onTap: onAddText,
                ),
                _StartButton(
                  key: const ValueKey('empty-canvas-quick-add'),
                  icon: Icons.add,
                  label: 'Quick add',
                  tooltip: 'Capture a note, task, event, link or photo',
                  onTap: onQuickAdd,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The arc, the sparkle and the two lines of type.
class _Masthead extends StatelessWidget {
  const _Masthead();

  static const width = 300.0;
  static const height = 112.0;

  @override
  Widget build(BuildContext context) {
    final title = TextStyle(
      fontFamily: AppType.family,
      fontSize: 22,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.2,
      height: 1.1,
      color: AppColors.text,
    );
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _CometPainter(
                ink: AppColors.text,
                glow: BrandColors.iris,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 60,
            child: Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    // The first letter carries the brand: iris into rose.
                    ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (bounds) => const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          BrandColors.iris,
                          BrandColors.rose,
                        ],
                      ).createShader(bounds),
                      child: Text('e', style: title),
                    ),
                    Text('mpty canvas', style: title),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'sketch · plan · think · create',
                  style: TextStyle(
                    fontFamily: AppType.family,
                    fontSize: AppType.sizeBodySmall,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 1.1,
                    color: AppColors.textFaint,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A hairline arc sweeping up from the lower left into a four-point
/// sparkle, with a short tail curling down from it. The arc fades in from
/// nothing; the sparkle has a soft brand-coloured glow.
class _CometPainter extends CustomPainter {
  const _CometPainter({required this.ink, required this.glow});

  final Color ink;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    const start = Offset(22, 103);
    const star = Offset(230, 22);

    final arc = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(72, 62, 152, 30, star.dx - 3, star.dy + 1);
    canvas.drawPath(
      arc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            ink.withValues(alpha: 0),
            ink.withValues(alpha: 0.22),
            ink.withValues(alpha: 0.6),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromPoints(start, star)),
    );

    final tail = Path()
      ..moveTo(star.dx, star.dy + 4)
      ..quadraticBezierTo(
        star.dx - 7,
        star.dy + 16,
        star.dx - 11,
        star.dy + 31,
      );
    canvas.drawPath(
      tail,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round
        ..shader =
            LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [ink.withValues(alpha: 0.5), ink.withValues(alpha: 0)],
            ).createShader(
              Rect.fromLTRB(star.dx - 12, star.dy, star.dx, star.dy + 32),
            ),
    );

    // Glow, then the sparkle itself.
    canvas.drawCircle(
      star,
      7,
      Paint()
        ..color = glow.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawPath(_sparkle(star, 8), Paint()..color = ink);
  }

  /// Four points with concave sides.
  static Path _sparkle(Offset c, double r) {
    final k = r * 0.16;
    final path = Path()..moveTo(c.dx, c.dy - r);
    for (var i = 0; i < 4; i++) {
      final a = -math.pi / 2 + i * math.pi / 2;
      final next = a + math.pi / 2;
      final mid = a + math.pi / 4;
      path.quadraticBezierTo(
        c.dx + k * math.cos(mid),
        c.dy + k * math.sin(mid),
        c.dx + r * math.cos(next),
        c.dy + r * math.sin(next),
      );
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_CometPainter old) => old.ink != ink || old.glow != glow;
}

/// One starting action: a quiet glass tile with an icon and a label.
class _StartButton extends StatelessWidget {
  const _StartButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.card.withValues(alpha: 0.55),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: AppColors.textMuted),
                const SizedBox(width: 9),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: AppType.family,
                    fontSize: AppType.sizeLabel,
                    fontWeight: FontWeight.w400,
                    color: AppColors.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
