// The few building blocks every iPhone screen is made of. Deliberately
// small: a hairline, a small-caps label, a row, a press target, a ring to tick
// things, and the bottom sheet. No cards, no shadows.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/theme.dart';
import 'phone_tokens.dart';

class Hairline extends StatelessWidget {
  const Hairline({super.key, this.inset = 0, this.endInset = 0});

  final double inset;
  final double endInset;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: inset, right: endInset),
    child: SizedBox(
      height: 1,
      width: double.infinity,
      child: ColoredBox(color: AppColors.border.withValues(alpha: 0.7)),
    ),
  );
}

/// SMALL CAPITALS above a group.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color, this.trailing});

  final String text;
  final Color? color;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          text.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: PhoneType.eyebrow.copyWith(color: color),
        ),
      ),
      if (trailing != null)
        Text(trailing!, style: PhoneType.eyebrow.copyWith(color: color)),
    ],
  );
}

/// The brand gradient as a short line: the one coloured stroke of a screen.
class BrandBar extends StatelessWidget {
  const BrandBar({super.key, this.width = 18, this.height = 2.5});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      gradient: AppGradients.brand,
      borderRadius: BorderRadius.circular(height),
    ),
  );
}

/// A tap target that dims while pressed instead of splashing. Gives a small
/// tick of haptic feedback on a long press.
class Press extends StatefulWidget {
  const Press({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final HitTestBehavior behavior;

  @override
  State<Press> createState() => _PressState();
}

class _PressState extends State<Press> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: widget.behavior,
    onTapDown: (_) => _set(true),
    onTapCancel: () => _set(false),
    onTapUp: (_) => _set(false),
    onTap: widget.onTap,
    onLongPress: widget.onLongPress == null
        ? null
        : () {
            HapticFeedback.mediumImpact();
            _set(false);
            widget.onLongPress!();
          },
    child: AnimatedOpacity(
      duration: AppMotion.press,
      opacity: _down ? 0.5 : 1,
      child: widget.child,
    ),
  );
}

/// The round tick of a task or habit: an empty ring, a filled one when done.
class TickRing extends StatelessWidget {
  const TickRing({
    super.key,
    required this.done,
    required this.onTap,
    this.enabled = true,
  });

  final bool done;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    checked: done,
    label: done ? 'Mark not done' : 'Mark done',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      // A 44 pt target around a 22 pt ring.
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: AnimatedContainer(
            duration: AppMotion.quick,
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? AppColors.accent : Colors.transparent,
              border: Border.all(
                color: !enabled
                    ? AppColors.border
                    : done
                    ? AppColors.accent
                    : AppColors.textFaint,
                width: 1.5,
              ),
            ),
            child: done
                ? Icon(
                    Icons.check_rounded,
                    size: 15,
                    color: AppColors.background,
                  )
                : null,
          ),
        ),
      ),
    ),
  );
}

/// A line in the sheets: large type, optional glyph, no chrome.
class SheetItem extends StatelessWidget {
  const SheetItem({
    super.key,
    required this.label,
    this.hint,
    this.icon,
    this.color,
    required this.onTap,
  });

  final String label;
  final String? hint;
  final IconData? icon;
  final Color? color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Press(
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 54),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: PhoneSpace.margin),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: PhoneType.title.copyWith(
                      fontSize: 21,
                      fontWeight: FontWeight.w600,
                      color: color ?? AppColors.text,
                    ),
                  ),
                  if (hint != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(hint!, style: PhoneType.meta),
                    ),
                ],
              ),
            ),
            if (icon != null)
              Icon(icon, size: 20, color: color ?? AppColors.textFaint),
          ],
        ),
      ),
    ),
  );
}

/// A bottom sheet with a flat surface and a hairline on top. [children] are
/// usually [SheetItem]s.
Future<T?> showPhoneSheet<T>(
  BuildContext context, {
  String? eyebrow,
  required List<Widget> Function(BuildContext context) children,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  backgroundColor: AppColors.card,
  barrierColor: AppElevation.modalBarrier,
  showDragHandle: false,
  useSafeArea: true,
  shape: RoundedRectangleBorder(
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(AppRadii.card),
    ),
    side: BorderSide(color: AppColors.border.withValues(alpha: 0.8)),
  ),
  clipBehavior: Clip.antiAlias,
  builder: (context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 9, bottom: 6),
                child: Container(
                  width: 34,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(AppRadii.xs),
                  ),
                ),
              ),
            ),
            if (eyebrow != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PhoneSpace.margin,
                  10,
                  PhoneSpace.margin,
                  4,
                ),
                child: Eyebrow(eyebrow),
              ),
            ...children(context),
            const SizedBox(height: 14),
          ],
        ),
      ),
    ),
  ),
);

/// Top of a screen: small caps line, large title, actions on the right.
/// Scrolls with the content (it is a sliver), so the page keeps its height.
class PhoneHeader extends StatelessWidget {
  const PhoneHeader({
    super.key,
    this.eyebrow,
    required this.title,
    this.actions = const [],
    this.titleStyle,
    this.subtitle,
  });

  final String? eyebrow;
  final String title;
  final TextStyle? titleStyle;
  final Widget? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      PhoneSpace.margin,
      MediaQuery.paddingOf(context).top + 14,
      PhoneSpace.margin - 8,
      12,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (eyebrow != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    eyebrow!.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PhoneType.eyebrow,
                  ),
                ),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle ?? PhoneType.display,
              ),
              ?subtitle,
            ],
          ),
        ),
        ...actions,
      ],
    ),
  );
}

/// A glyph button with a 44 pt target.
class GlyphButton extends StatelessWidget {
  const GlyphButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.label,
    this.color,
    this.size = 23,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String label;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Press(
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(icon, size: size, color: color ?? AppColors.textMuted),
      ),
    ),
  );
}

/// An empty list in the app's voice: one sentence in large light type.
class EmptyNote extends StatelessWidget {
  const EmptyNote(this.headline, {super.key, this.hint});

  final String headline;
  final String? hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      PhoneSpace.margin,
      36,
      PhoneSpace.margin,
      24,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          headline,
          style: PhoneType.title.copyWith(
            fontSize: 26,
            fontWeight: FontWeight.w300,
            letterSpacing: -0.8,
            color: AppColors.textMuted,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 8),
          Text(hint!, style: PhoneType.meta),
        ],
      ],
    ),
  );
}

/// A quiet text button: "Earlier today · 5", "Open full calendar".
class TextLink extends StatelessWidget {
  const TextLink(this.text, {super.key, required this.onTap, this.trailing});

  final String text;
  final VoidCallback onTap;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) => Press(
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: AppType.sizeBody,
              fontWeight: FontWeight.w600,
              color: AppColors.accent,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 4),
            Icon(trailing, size: 16, color: AppColors.accent),
          ],
        ],
      ),
    ),
  );
}
