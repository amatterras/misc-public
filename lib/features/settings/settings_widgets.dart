// The building blocks of the Settings window: one quiet, consistent set of
// pieces (page, group, row, switch, menu, segmented control, button) so every
// category looks the same and nothing is styled twice. They draw only; each
// row is handed the existing action to run.
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../new_ui/new_tokens.dart' show NewColors;

/// Corner radius of groups; New is a little rounder than Original.
double get _groupRadius => 18;

/// A category page: a large title, one line saying what is in it, and the
/// groups below. Scrolls on its own.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: AppColors.text,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: AppType.sizeBodySmall,
                    height: 1.4,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
              const SizedBox(height: 22),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled card holding rows, with an optional footnote underneath.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.label,
    this.footer,
    required this.children,
    this.padded = false,
  });

  final String? label;
  final String? footer;
  final List<Widget> children;

  /// Free-form content (not rows): adds its own padding, no dividers.
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0 && !padded) {
        rows.add(
          Divider(height: 1, thickness: 1, indent: 16, color: _hairline),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                label!.toUpperCase(),
                style: TextStyle(
                  fontSize: AppType.sizeMeta,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: AppColors.textFaint,
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(_groupRadius),
              border: Border.all(color: _hairline),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_groupRadius - 1),
              child: padded
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: children,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: rows,
                    ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                footer!,
                style: TextStyle(
                  fontSize: AppType.sizeLabel,
                  height: 1.4,
                  color: AppColors.textFaint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Color get _hairline => AppColors.border.withValues(alpha: 0.8);

/// One line of a group: a title, an optional explanation, and a control (or
/// chevron) on the right. With [onTap] the whole row is pressable.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.icon,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.danger : AppColors.text;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 19, color: destructive ? color : AppColors.accent),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppType.sizeBody,
                    fontWeight: FontWeight.w500,
                    color: onTap == null && trailing == null
                        ? AppColors.textMuted
                        : color,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: AppType.sizeLabel,
                      height: 1.35,
                      color: AppColors.textFaint,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          if (trailing == null && onTap != null)
            Icon(Icons.chevron_right, size: 18, color: AppColors.textFaint),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, hoverColor: AppColors.hover, child: row);
  }
}

/// A row with an on/off switch.
class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SettingsRow(
    title: title,
    subtitle: subtitle,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: Switch(
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      thumbColor: WidgetStatePropertyAll(
        value ? NewColors.onAccent : AppColors.textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.accent
            : AppColors.cardRaised,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : AppColors.border,
      ),
    ),
  );
}

/// A row that shows its current value and opens a menu of choices.
class SettingsMenu<T> extends StatelessWidget {
  const SettingsMenu({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
    this.menuKey,
  });

  final String title;
  final String? subtitle;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;

  /// Key of the menu itself (tests reach it by this).
  final Key? menuKey;

  @override
  Widget build(BuildContext context) {
    final current = options.where((o) => o.$1 == value).firstOrNull;
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      trailing: PopupMenuButton<T>(
        key: menuKey,
        enabled: onChanged != null,
        tooltip: title,
        initialValue: value,
        onSelected: onChanged,
        position: PopupMenuPosition.under,
        itemBuilder: (_) => [
          for (final (v, label) in options)
            PopupMenuItem<T>(value: v, height: 40, child: Text(label)),
        ],
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
          decoration: BoxDecoration(
            color: AppColors.cardRaised.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                current?.$2 ?? '',
                style: TextStyle(
                  fontSize: AppType.sizeBodySmall,
                  color: AppColors.text,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.unfold_more, size: 16, color: AppColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// A pill-shaped selector for two to four options (Theme, Interface).
class SettingsSegments<T> extends StatelessWidget {
  const SettingsSegments({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.cardRaised.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppRadii.capsule),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (v, label) in options)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(v),
              child: AnimatedContainer(
                duration: AppMotion.dropdown,
                curve: AppMotion.standard,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: v == value ? AppColors.card : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadii.capsule),
                  boxShadow: v == value
                      ? [
                          BoxShadow(
                            color: AppElevation.shadowColor.withValues(
                              alpha: 0.12,
                            ),
                            blurRadius: 6,
                            offset: const Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: AppType.sizeBodySmall,
                    fontWeight: v == value ? FontWeight.w600 : FontWeight.w400,
                    color: v == value ? AppColors.text : AppColors.textMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A row whose control is a [SettingsSegments] below the title.
class SettingsSegmentRow<T> extends StatelessWidget {
  const SettingsSegmentRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: AppType.sizeBody,
            fontWeight: FontWeight.w500,
            color: AppColors.text,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              height: 1.35,
              color: AppColors.textFaint,
            ),
          ),
        ],
        const SizedBox(height: 10),
        SettingsSegments<T>(
          value: value,
          options: options,
          onChanged: onChanged,
        ),
      ],
    ),
  );
}

/// A compact button for a row's action ("Back up now").
class SettingsButton extends StatelessWidget {
  const SettingsButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? NewColors.onAccent : AppColors.text;
    return Opacity(
      opacity: onPressed == null ? 0.45 : 1,
      child: Material(
        color: primary ? AppColors.accent : AppColors.cardRaised,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: fg),
                  const SizedBox(width: 7),
                ],
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.sizeBodySmall,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
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

/// A line of body text inside a group (explanations, status).
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key, this.strong = false});

  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: AppType.sizeBodySmall,
        height: 1.45,
        color: strong ? AppColors.text : AppColors.textMuted,
      ),
    ),
  );
}
