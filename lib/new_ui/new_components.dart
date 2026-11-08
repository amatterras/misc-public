// Small reusable visual components of the New interface. They only draw;
// behaviour (taps, long presses, completion) is passed in by the caller and
// is always an existing action.
import 'package:flutter/material.dart';

import '../app/design_tokens.dart';
import 'new_tokens.dart';

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
      duration: NewMotion.quick,
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: NewGradients.brand,
        borderRadius: BorderRadius.circular(NewRadii.capsule),
        boxShadow: [
          BoxShadow(
            color: NewGradients.brandRose.withValues(
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
            const SizedBox(width: NewSpace.xs),
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
    this.padding = const EdgeInsets.all(NewSpace.md),
    this.radius = NewRadii.card,
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
      color: color ?? NewColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: shape,
        side: BorderSide(color: borderColor ?? NewColors.border),
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
        color: color ?? NewColors.accentSoft,
        borderRadius: BorderRadius.circular(NewRadii.capsule),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          text,
          style: NewText.label.copyWith(
            fontSize: AppType.sizeMeta,
            color: textColor ?? NewColors.accent,
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
      borderRadius: BorderRadius.circular(NewRadii.capsule),
      child: SizedBox(
        height: 6,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: NewColors.surfaceRaised)),
            FractionallySizedBox(
              widthFactor: value.clamp(0, 1).toDouble(),
              child: const DecoratedBox(
                decoration: BoxDecoration(gradient: NewGradients.brand),
                child: SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Soft blurred colour pools (see [NewGradients]) fading into the page
/// background: decoration behind headers and selected surfaces. Draws only;
/// ignores touches.
class NewAtmosphere extends StatelessWidget {
  const NewAtmosphere({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (final layer in NewGradients.layers())
              DecoratedBox(decoration: BoxDecoration(gradient: layer)),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    NewColors.background.withValues(alpha: 0.35),
                    NewColors.background,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
      borderRadius: BorderRadius.circular(NewRadii.capsule),
      borderSide: color == null ? BorderSide.none : BorderSide(color: color),
    );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: TextStyle(color: NewColors.text, fontSize: AppType.sizeBody),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: NewColors.textFaint),
        prefixIcon: Icon(Icons.search, size: 20, color: NewColors.textFaint),
        suffixIcon: showClear
            ? IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClear,
              )
            : null,
        filled: true,
        fillColor: NewColors.surfaceSecondary,
        contentPadding: EdgeInsets.zero,
        border: border(),
        enabledBorder: border(),
        focusedBorder: border(NewColors.accent),
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
    final color = filled ? Colors.white : NewColors.accent;
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
        color: filled ? Colors.transparent : NewColors.accentSoft,
        borderRadius: BorderRadius.circular(NewRadii.capsule),
        child: Ink(
          decoration: filled
              ? BoxDecoration(
                  gradient: NewGradients.brand,
                  borderRadius: BorderRadius.circular(NewRadii.capsule),
                )
              : null,
          child: InkWell(
            borderRadius: BorderRadius.circular(NewRadii.capsule),
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
    icon: Icon(icon, size: 20, color: NewColors.textMuted),
    onPressed: onPressed,
  );
}

/// The top section of a New page, as designed for the Archive: the soft
/// atmosphere behind a large title, an optional second line, the page's
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
    return Stack(
      children: [
        const Positioned.fill(child: NewAtmosphere()),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NewSpace.lg,
            NewSpace.md,
            NewSpace.lg,
            NewSpace.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: NewSpace.md,
                runSpacing: NewSpace.xs,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: NewText.heading.copyWith(color: NewColors.text),
                      ),
                      ?subtitle,
                    ],
                  ),
                  if (actions.isNotEmpty)
                    Wrap(
                      spacing: NewSpace.sm,
                      runSpacing: NewSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: actions,
                    ),
                ],
              ),
              if (search != null) ...[
                const SizedBox(height: NewSpace.sm),
                search!,
              ],
            ],
          ),
        ),
      ],
    );
  }
}
