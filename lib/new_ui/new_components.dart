// Small reusable visual components of the New interface. They only draw;
// behaviour (taps, long presses, completion) is passed in by the caller and
// is always an existing action.
import 'package:flutter/material.dart';

import '../app/theme.dart';

/// The brand "+": a brand-gradient capsule with a white plus and a warm coral
/// glow. THE one definition: Quick Add on Windows/iPad and "New" on the
/// iPhone are both this widget, so they cannot drift apart. It only draws; the
/// caller owns the tap, the hover and the label.
class BrandPlus extends StatelessWidget {
  const BrandPlus({
    super.key,
    this.width = 40,
    this.height = 40,
    this.hovered = false,
    this.label,
  });

  final double width;
  final double height;

  /// Brighter, larger glow while the pointer is over it (pointer devices).
  final bool hovered;

  /// Shown beside the plus when there is room (the expanded sidebar).
  final String? label;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: AppMotion.quick,
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: AppGradients.brand,
        borderRadius: BorderRadius.circular(AppRadii.capsule),
        boxShadow: [
          BoxShadow(
            color: BrandColors.rose.withValues(
              alpha: hovered ? 0.5 : 0.28,
            ),
            blurRadius: hovered ? 14 : 8,
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.add, size: 22, color: Colors.white),
          if (label != null) ...[
            const SizedBox(width: AppSpace.xs),
            Flexible(
              child: Text(
                label!,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: AppType.sizeBodySmall,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A rounded surface with a hairline border: the basis of New cards.
class NewCard extends StatelessWidget {
  const NewCard({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(AppSpace.md),
    this.radius = AppRadii.card,
    this.onTap,
    this.onLongPress,
    this.borderColor,
  });

  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return Material(
      color: color ?? AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: shape,
        side: BorderSide(color: borderColor ?? AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// A small rounded label ("Today", "2/5").
class NewPill extends StatelessWidget {
  const NewPill(this.text, {super.key, this.color, this.textColor});

  final String text;
  final Color? color;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadii.capsule),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          text,
          style: AppType.label.copyWith(
            fontSize: AppType.sizeMeta,
            color: textColor ?? AppColors.accent,
          ),
        ),
      ),
    );
  }
}

/// A thin horizontal progress bar with the brand gradient.
class NewProgressBar extends StatelessWidget {
  const NewProgressBar({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.capsule),
      child: SizedBox(
        height: 6,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: AppColors.cardRaised)),
            FractionallySizedBox(
              widthFactor: value.clamp(0, 1).toDouble(),
              child: const DecoratedBox(
                decoration: BoxDecoration(gradient: AppGradients.brand),
                child: SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The app-wide atmosphere: soft colour pools ([AppGradients.pools]) as one
/// continuous field. The shell paints it once behind everything (sidebar,
/// page bar, every page), so pages leave their own background transparent
/// and the field flows through without seams. Full-screen routes pushed
/// over the shell use [NewAtmosphere.behind]. Draws only; ignores touches;
/// repaints only when the window size or the light/dark theme changes.
class NewAtmosphere extends StatelessWidget {
  const NewAtmosphere({super.key}) : child = null;

  /// The page colour, the field, then [child] on top: for a screen that is
  /// not inside the shell (a pushed route) and must give itself the field.
  const NewAtmosphere.behind({super.key, required Widget this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    // Depending on the theme rebuilds the field when light/dark changes.
    final light = Theme.of(context).brightness == Brightness.light;
    final field = IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _AtmospherePainter(
            light: light,
            pools: AppGradients.pools,
            veilBottom: AppGradients.veilBottom,
            page: AppColors.background,
          ),
        ),
      ),
    );
    final child = this.child;
    if (child == null) return field;
    return ColoredBox(
      color: AppColors.background,
      child: Stack(
        fit: StackFit.expand,
        children: [field, child],
      ),
    );
  }
}

class _AtmospherePainter extends CustomPainter {
  _AtmospherePainter({
    required this.light,
    required this.pools,
    required this.veilBottom,
    required this.page,
  });

  final bool light;
  final List<AtmospherePool> pools;
  final double veilBottom;
  final Color page;

  // Smooth falloff (1-t)²(1+2t) sampled at five stops: full at the centre,
  // 0 at the rim with a zero slope, so no ring is visible.
  static const _stops = [0.0, 0.25, 0.5, 0.75, 1.0];
  static const _falloff = [1.0, 0.84375, 0.5, 0.15625, 0.0];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final unit = Rect.fromCircle(center: Offset.zero, radius: 1);
    for (final p in pools) {
      final shader = RadialGradient(
        colors: [
          for (final f in _falloff) p.color.withValues(alpha: p.opacity * f),
        ],
        stops: _stops,
      ).createShader(unit);
      final center = p.center.withinRect(Offset.zero & size);
      canvas
        ..save()
        ..translate(center.dx, center.dy)
        ..scale(p.radius * size.width, p.radius * size.height)
        ..drawCircle(Offset.zero, 1, Paint()..shader = shader)
        ..restore();
    }
    final veil = Offset.zero & size;
    canvas.drawRect(
      veil,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            page.withValues(alpha: 0),
            page.withValues(alpha: veilBottom),
          ],
        ).createShader(veil),
    );
  }

  @override
  bool shouldRepaint(_AtmospherePainter old) =>
      old.light != light || old.page != page || old.veilBottom != veilBottom;
}

/// The Archive's capsule search field, shared with Notes (and any module
/// that has a search): a filled pill with a leading magnifier and a clear
/// button. Drawing only; the caller owns the text and what it filters.
class NewSearchField extends StatelessWidget {
  const NewSearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
    this.onClear,
  });

  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;

  /// Shown as a clear button while [controller] holds text.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final showClear = controller != null && controller!.text.isNotEmpty;
    OutlineInputBorder border([Color? color]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.capsule),
      borderSide: color == null ? BorderSide.none : BorderSide(color: color),
    );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: TextStyle(color: AppColors.text, fontSize: AppType.sizeBody),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.textFaint),
        prefixIcon: Icon(Icons.search, size: 20, color: AppColors.textFaint),
        suffixIcon: showClear
            ? IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClear,
              )
            : null,
        filled: true,
        fillColor: AppColors.surfaceSecondary,
        contentPadding: EdgeInsets.zero,
        border: border(),
        enabledBorder: border(),
        focusedBorder: border(AppColors.accent),
      ),
    );
  }
}

/// A text-and-icon button of the page header (Archive's "Whole Look").
/// [filled] gives the brand-gradient capsule used for the main action.
class NewHeaderButton extends StatelessWidget {
  const NewHeaderButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.filled = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final color = filled ? Colors.white : AppColors.accent;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: AppType.sizeBodySmall,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
    return Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: Material(
        color: filled ? Colors.transparent : AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadii.capsule),
        child: Ink(
          decoration: filled
              ? BoxDecoration(
                  gradient: AppGradients.brand,
                  borderRadius: BorderRadius.circular(AppRadii.capsule),
                )
              : null,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.capsule),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// A round icon button of the page header (Archive's "new folder").
class NewHeaderIconButton extends StatelessWidget {
  const NewHeaderIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon, size: 20, color: AppColors.textMuted),
    onPressed: onPressed,
  );
}

/// The top section of a New page, as designed for the Archive: a large
/// title over the app-wide atmosphere, an optional second line, the page's
/// actions on the right and an optional search capsule below. Archive,
/// Calendar and Notes all use it; each passes its own title, actions and
/// search, so nothing module-specific lives here.
class NewPageHeader extends StatelessWidget {
  const NewPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.search,
  });

  final String title;

  /// A line under the title (the Calendar's date range).
  final Widget? subtitle;

  /// Buttons on the title row, right-aligned; they wrap in narrow windows.
  final List<Widget> actions;

  /// A [NewSearchField] (or any widget) shown under the title row.
  final Widget? search;

  @override
  Widget build(BuildContext context) {
    // No atmosphere of its own: the app-wide field (NewAtmosphere in the
    // shell) shows through, so the header and the page are one surface.
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.md,
            AppSpace.lg,
            AppSpace.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpace.md,
                runSpacing: AppSpace.xs,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppType.title.copyWith(color: AppColors.text),
                      ),
                      ?subtitle,
                    ],
                  ),
                  if (actions.isNotEmpty)
                    Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: actions,
                    ),
                ],
              ),
              if (search != null) ...[
                const SizedBox(height: AppSpace.sm),
                search!,
              ],
            ],
          ),
        ),
      ],
    );
  }
}
