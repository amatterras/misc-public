// The Material theme, built from the design system: colours from
// palette.dart, everything else from design_tokens.dart. Both are
// re-exported here, so `import 'theme.dart'` gives a widget the whole system.
import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'palette.dart';

export 'design_tokens.dart';
export 'palette.dart';
export 'popups.dart' show showAppDialog, PopupEntrance;

/// The Material theme, built entirely from the design tokens
/// (design_tokens.dart) and the palette (AppColors). Every stock Material
/// control the app uses gets the same geometry, states and motion here, so
/// individual screens don't restyle them one by one.
ThemeData buildAppTheme({Brightness brightness = Brightness.dark}) {
  final previousMode = AppColors.mode;
  AppColors.mode = brightness == Brightness.light
      ? ThemeMode.light
      : ThemeMode.dark;
  try {
    return _buildTheme(brightness);
  } finally {
    AppColors.mode = previousMode;
  }
}

ThemeData _buildTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final onAccent = AppColors.onAccent;
  final scheme = light
      ? ColorScheme.light(
          surface: AppColors.background,
          onSurface: AppColors.text,
          onSurfaceVariant: AppColors.textMuted,
          surfaceContainerLowest: AppColors.card,
          surfaceContainerLow: AppColors.card,
          surfaceContainer: AppColors.card,
          surfaceContainerHigh: AppColors.surfaceSecondary,
          surfaceContainerHighest: AppColors.cardRaised,
          primary: AppColors.accent,
          onPrimary: onAccent,
          primaryContainer: AppColors.accentSoft,
          onPrimaryContainer: AppColors.accent,
          secondary: AppColors.accentSecondary,
          onSecondary: Colors.white,
          secondaryContainer: AppColors.selected,
          onSecondaryContainer: AppColors.text,
          error: AppColors.danger,
          onError: Colors.white,
          outline: AppColors.border,
          outlineVariant: AppColors.border,
          shadow: AppElevation.shadowColor,
          scrim: AppElevation.modalBarrier,
        )
      : ColorScheme.dark(
          surface: AppColors.background,
          onSurface: AppColors.text,
          onSurfaceVariant: AppColors.textMuted,
          surfaceContainerLowest: AppColors.background,
          surfaceContainerLow: AppColors.card,
          surfaceContainer: AppColors.card,
          surfaceContainerHigh: AppColors.surfaceSecondary,
          surfaceContainerHighest: AppColors.cardRaised,
          primary: AppColors.accent,
          onPrimary: onAccent,
          primaryContainer: AppColors.accentSoft,
          onPrimaryContainer: AppColors.accent,
          secondary: AppColors.accent,
          onSecondary: AppColors.background,
          secondaryContainer: AppColors.selected,
          onSecondaryContainer: AppColors.text,
          error: AppColors.danger,
          onError: AppColors.background,
          outline: AppColors.border,
          outlineVariant: AppColors.border,
          shadow: AppElevation.shadowColor,
          scrim: AppElevation.modalBarrier,
        );

  // Shared state layers: a quiet hover, a slightly deeper press, no ripple.
  final hover = AppStates.hover;
  final pressed = AppStates.pressed;
  WidgetStateProperty<Color?> overlay([Color? tint]) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return tint?.withValues(alpha: 0.16) ?? pressed;
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return tint?.withValues(alpha: 0.10) ?? hover;
        }
        return null;
      });
  final controlShape = WidgetStatePropertyAll<OutlinedBorder>(
    RoundedRectangleBorder(borderRadius: AppRadii.all(AppRadii.sm)),
  );
  final focusSide = WidgetStateProperty.resolveWith<BorderSide?>(
    (states) => states.contains(WidgetState.focused)
        ? BorderSide(color: AppStates.focusRing, width: AppStroke.focus)
        : null,
  );
  const controlPadding = WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: AppSpace.md + 2, vertical: AppSpace.sm),
  );
  const minControl = WidgetStatePropertyAll(Size(64, AppSizes.control));
  const labelStyle = WidgetStatePropertyAll(AppType.label);
  const noElevation = WidgetStatePropertyAll<double>(0);
  Color faded(Color c) => c.withValues(alpha: AppStates.disabledOpacity);

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    fontFamily: AppType.family,
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.compact,
    hoverColor: hover,
    focusColor: hover,
    highlightColor: pressed,
    splashColor: Colors.transparent,
    disabledColor: AppColors.textFaint,
    dividerColor: AppColors.border,
    shadowColor: AppElevation.shadowColor,
  );

  final menuStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(
      light ? AppColors.card : AppColors.cardRaised,
    ),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shadowColor: WidgetStatePropertyAll(AppElevation.shadowColor),
    elevation: const WidgetStatePropertyAll(8),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(vertical: AppSpace.xs),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: AppRadii.all(AppRadii.popup),
        side: BorderSide(color: AppColors.border),
      ),
    ),
  );

  OutlineInputBorder field(Color color, [double width = AppStroke.border]) =>
      OutlineInputBorder(
        borderRadius: AppRadii.all(AppRadii.md),
        borderSide: BorderSide(color: color, width: width),
      );

  return base.copyWith(
    textTheme: base.textTheme
        .copyWith(
          displaySmall: AppType.display,
          headlineSmall: AppType.title,
          titleLarge: AppType.title,
          titleMedium: AppType.heading,
          titleSmall: AppType.label.copyWith(fontSize: AppType.sizeBodySmall),
          bodyLarge: AppType.body,
          bodyMedium: AppType.bodySmall,
          bodySmall: AppType.caption,
          labelLarge: AppType.label.copyWith(fontSize: AppType.sizeBodySmall),
          labelMedium: AppType.label,
          labelSmall: AppType.meta,
        )
        .apply(
          fontFamily: AppType.family,
          bodyColor: AppColors.text,
          displayColor: AppColors.text,
        ),
    iconTheme: IconThemeData(color: AppColors.textMuted, size: 20),
    dividerTheme: DividerThemeData(
      color: AppColors.border,
      space: 1,
      thickness: AppStroke.divider,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      exitDuration: AppMotion.quick,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm + 2,
        vertical: AppSpace.xs + 1,
      ),
      decoration: BoxDecoration(
        color: light ? AppColors.text : AppColors.cardRaised,
        borderRadius: AppRadii.all(AppRadii.sm),
        border: light ? null : Border.all(color: AppColors.border),
      ),
      textStyle: AppType.caption.copyWith(
        color: light ? AppColors.background : AppColors.text,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: AppElevation.shadowColor,
      barrierColor: AppElevation.modalBarrier,
      insetPadding: const EdgeInsets.all(AppSpace.xl),
      titleTextStyle: AppType.heading.copyWith(
        color: AppColors.text,
        fontSize: 17,
      ),
      contentTextStyle: AppType.bodySmall.copyWith(
        color: AppColors.textMuted,
        height: AppType.heightBody,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.all(AppRadii.dialog),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: AppElevation.modalBarrier,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadii.dialog),
        ),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: light ? AppColors.card : AppColors.cardRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: AppElevation.shadowColor,
      menuPadding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.all(AppRadii.popup),
        side: BorderSide(color: AppColors.border),
      ),
      textStyle: AppType.bodySmall.copyWith(color: AppColors.text),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => AppType.bodySmall.copyWith(
          color: states.contains(WidgetState.disabled)
              ? AppColors.textFaint
              : AppColors.text,
        ),
      ),
    ),
    menuTheme: MenuThemeData(style: menuStyle),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: menuStyle,
      textStyle: AppType.bodySmall.copyWith(color: AppColors.text),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        overlayColor: overlay(),
        minimumSize: const WidgetStatePropertyAll(Size(0, AppSizes.menuRow)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: AppSpace.md),
        ),
        textStyle: WidgetStatePropertyAll(
          AppType.bodySmall.copyWith(color: AppColors.text),
        ),
        shape: controlShape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: light ? AppColors.card : AppColors.surfaceSecondary,
      hoverColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm + 2,
      ),
      hintStyle: AppType.bodySmall.copyWith(color: AppColors.textFaint),
      labelStyle: AppType.bodySmall.copyWith(color: AppColors.textMuted),
      floatingLabelStyle: AppType.label.copyWith(color: AppColors.accent),
      helperStyle: AppType.caption.copyWith(color: AppColors.textFaint),
      errorStyle: AppType.caption.copyWith(color: AppColors.danger),
      prefixIconColor: AppColors.textFaint,
      suffixIconColor: AppColors.textFaint,
      border: field(AppColors.border),
      enabledBorder: field(AppColors.border),
      disabledBorder: field(faded(AppColors.border)),
      focusedBorder: field(AppColors.accent, AppStroke.selected),
      errorBorder: field(AppColors.danger),
      focusedErrorBorder: field(AppColors.danger, AppStroke.selected),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppColors.focus,
      selectionColor: AppColors.selection,
      selectionHandleColor: AppColors.accent,
    ),
    // Buttons: one height, one radius, one state language.
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? faded(AppColors.textMuted)
              : AppColors.accent,
        ),
        overlayColor: overlay(AppColors.accent),
        shape: controlShape,
        side: focusSide,
        padding: controlPadding,
        minimumSize: minControl,
        textStyle: labelStyle,
        animationDuration: AppMotion.hover,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? faded(AppColors.accent)
              : AppColors.accent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? faded(onAccent) : onAccent,
        ),
        overlayColor: overlay(onAccent),
        elevation: noElevation,
        shape: controlShape,
        side: focusSide,
        padding: controlPadding,
        minimumSize: minControl,
        textStyle: labelStyle,
        animationDuration: AppMotion.hover,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStatePropertyAll(AppColors.surfaceSecondary),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? faded(AppColors.text)
              : AppColors.text,
        ),
        overlayColor: overlay(),
        elevation: noElevation,
        shape: controlShape,
        side: focusSide,
        padding: controlPadding,
        minimumSize: minControl,
        textStyle: labelStyle,
        animationDuration: AppMotion.hover,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? faded(AppColors.text)
              : AppColors.text,
        ),
        overlayColor: overlay(),
        shape: controlShape,
        side: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused)
              ? BorderSide(color: AppStates.focusRing, width: AppStroke.focus)
              : BorderSide(
                  color: s.contains(WidgetState.disabled)
                      ? faded(AppColors.border)
                      : AppColors.border,
                ),
        ),
        padding: controlPadding,
        minimumSize: minControl,
        textStyle: labelStyle,
        animationDuration: AppMotion.hover,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? faded(AppColors.textMuted)
              : s.contains(WidgetState.selected)
              ? AppColors.accent
              : AppColors.textMuted,
        ),
        overlayColor: overlay(),
        shape: controlShape,
        side: focusSide,
        animationDuration: AppMotion.hover,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.accentSoft
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.accent
              : AppColors.textMuted,
        ),
        overlayColor: overlay(),
        side: WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
        shape: controlShape,
        textStyle: labelStyle,
        visualDensity: VisualDensity.compact,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surfaceSecondary,
      selectedColor: AppColors.accentSoft,
      disabledColor: faded(AppColors.surfaceSecondary),
      side: BorderSide(color: AppColors.border),
      shape: RoundedRectangleBorder(borderRadius: AppRadii.all(AppRadii.sm)),
      labelStyle: AppType.caption.copyWith(color: AppColors.text),
      secondaryLabelStyle: AppType.caption.copyWith(color: AppColors.accent),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      checkmarkColor: AppColors.accent,
      iconTheme: IconThemeData(color: AppColors.textMuted, size: 16),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? (s.contains(WidgetState.disabled)
                  ? faded(AppColors.accent)
                  : AppColors.accent)
            : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(onAccent),
      side: BorderSide(color: AppColors.textFaint, width: AppStroke.selected),
      shape: RoundedRectangleBorder(borderRadius: AppRadii.all(AppRadii.xs)),
      overlayColor: overlay(),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? AppColors.accent
            : AppColors.textFaint,
      ),
      overlayColor: overlay(),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? onAccent
            : (light ? AppColors.card : AppColors.textMuted),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? AppColors.accent
            : AppColors.surfaceSecondary,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? Colors.transparent
            : AppColors.border,
      ),
      overlayColor: overlay(),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: AppColors.accent,
      inactiveTrackColor: AppColors.border,
      thumbColor: AppColors.accent,
      overlayColor: AppColors.accent.withValues(alpha: 0.12),
      valueIndicatorColor: light ? AppColors.text : AppColors.cardRaised,
      valueIndicatorTextStyle: AppType.caption.copyWith(
        color: light ? AppColors.background : AppColors.text,
      ),
      trackHeight: 3,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: AppColors.accent,
      linearTrackColor: AppColors.border,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 3,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(AppRadii.capsule),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
      minThumbLength: 36,
      thumbColor: WidgetStateProperty.resolveWith((s) {
        final ink = light ? const Color(0xFF181C25) : Colors.white;
        if (s.contains(WidgetState.dragged)) return ink.withValues(alpha: 0.40);
        if (s.contains(WidgetState.hovered)) return ink.withValues(alpha: 0.28);
        return ink.withValues(alpha: 0.16);
      }),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      iconColor: AppColors.textMuted,
      textColor: AppColors.text,
      selectedColor: AppColors.text,
      shape: RoundedRectangleBorder(borderRadius: AppRadii.all(AppRadii.sm)),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      horizontalTitleGap: AppSpace.md,
      minVerticalPadding: AppSpace.xs,
      titleTextStyle: AppType.bodySmall.copyWith(color: AppColors.text),
      subtitleTextStyle: AppType.caption.copyWith(color: AppColors.textMuted),
    ),
    cardTheme: CardThemeData(
      color: AppColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.all(AppRadii.card),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: light ? AppColors.text : AppColors.cardRaised,
      contentTextStyle: AppType.bodySmall.copyWith(
        color: light ? AppColors.background : AppColors.text,
      ),
      actionTextColor: light ? BrandColors.steelBlue : AppColors.accent,
      elevation: 6,
      insetPadding: const EdgeInsets.all(AppSpace.lg),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.all(AppRadii.md),
        side: light ? BorderSide.none : BorderSide(color: AppColors.border),
      ),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: AppColors.accent,
      textColor: onAccent,
      textStyle: AppType.meta.copyWith(fontWeight: AppType.semibold),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: AppColors.text,
      unselectedLabelColor: AppColors.textMuted,
      indicatorColor: AppColors.accent,
      dividerColor: AppColors.border,
      labelStyle: AppType.label.copyWith(fontSize: AppType.sizeBodySmall),
      unselectedLabelStyle: AppType.bodySmall,
      overlayColor: overlay(),
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.all(AppRadii.dialog),
      ),
      headerForegroundColor: AppColors.text,
      dayForegroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? onAccent : AppColors.text,
      ),
      dayBackgroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? AppColors.accent : null,
      ),
      todayForegroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? onAccent : AppColors.accent,
      ),
      todayBorder: BorderSide(color: AppColors.accent),
      dividerColor: AppColors.border,
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.all(AppRadii.dialog),
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
