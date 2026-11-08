import 'package:flutter/material.dart';

import '../new_ui/new_tokens.dart';
import 'design_tokens.dart';

export 'design_tokens.dart';
export 'popups.dart' show showAppDialog, PopupEntrance;

import 'dart:ui' show PlatformDispatcher;

/// Colour tokens taken from the Gemini prototype: near-black surfaces,
/// hairline white borders and soft grey text.
abstract final class AppColors {
  static ThemeMode mode = ThemeMode.dark;

  static bool get light => switch (mode) {
    ThemeMode.light => true,
    ThemeMode.dark => false,
    ThemeMode.system => _platformBrightness == Brightness.light,
  };

  /// The system light/dark setting, read the same way MaterialApp reads it
  /// (through the binding when there is one), so the two never disagree.
  static Brightness get _platformBrightness {
    try {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    } catch (_) {
      return PlatformDispatcher.instance.platformBrightness;
    }
  }

  // Every colour comes from the New palette (lib/new_ui/new_tokens.dart),
  // which follows the light/dark choice through [light].
  static Color get background => NewColors.background;
  static Color get canvas => NewColors.canvasPage;
  static Color get sidebar => NewColors.surface;
  static Color get card => NewColors.surface;
  static Color get cardRaised => NewColors.surfaceRaised;
  static Color get border => NewColors.border;
  static Color get hover => NewColors.hover;
  static Color get selected => NewColors.selected;
  static Color get text => NewColors.text;
  static Color get textMuted => NewColors.textMuted;
  static Color get textFaint => NewColors.textFaint;
  static Color get disabled => NewColors.textFaint;
  static Color get accent => NewColors.accent;
  static Color get accentSecondary => NewColors.accentSecondary;
  static Color get focus => NewColors.accent;
  static Color get selection => NewColors.selection;
  static Color get success => NewColors.success;
  static Color get brand => NewColors.deepIndigo;
  static Color get warm => NewColors.warm;
  static Color get danger => NewColors.danger;
}

/// Canonical ink choices shared by fineliner, brush, pencil, highlighter,
/// and marker tools. Order and names are part of the user-facing palette.
abstract final class InkColors {
  static const pearl = Color(0xFFE3E5E8);
  static const steelBlue = Color(0xFF789BB5);
  static const dustyBlue = Color(0xFF829CB5);
  static const midnightNavy = Color(0xFF172943);
  static const petrol = Color(0xFF4F9AA6);
  static const dustyMint = Color(0xFF8FBFA9);
  static const pistachio = Color(0xFFC7D5A0);
  static const orchidMist = Color(0xFFC8AED2);
  static const softAmber = Color(0xFFD5A16F);
  static const fuchsia = Color(0xFFE56BDA);
  static const antiqueGold = Color(0xFFC6AD79);
  static const electricAzure = Color(0xFF2878F0);
  static const sapphire = Color(0xFF2366AD);
  static const vividTurquoise = Color(0xFF00BDB1);
  static const electricLime = Color(0xFFB5DC32);
  static const ultraviolet = Color(0xFF793BE8);
  static const electricGold = Color(0xFFF2D84A);
  static const deepPine = Color(0xFF176B4D);

  /// Single approved bright red swatch. Added last so all legacy indices and
  /// any IDs derived from the original swatch order remain stable.
  static const brightRed = Color(0xFFFF3B30);

  static const library = <InkSwatch>[
    InkSwatch('pearl', 'Pearl', pearl),
    InkSwatch('steel-blue', 'Steel Blue', steelBlue),
    InkSwatch('dusty-blue', 'Dusty Blue', dustyBlue),
    InkSwatch('midnight-navy', 'Midnight Navy', midnightNavy),
    InkSwatch('petrol', 'Petrol', petrol),
    InkSwatch('dusty-mint', 'Dusty Mint', dustyMint),
    InkSwatch('pistachio', 'Pistachio', pistachio),
    InkSwatch('orchid-mist', 'Orchid Mist', orchidMist),
    InkSwatch('soft-amber', 'Soft Amber', softAmber),
    InkSwatch('fuchsia', 'Fuchsia', fuchsia),
    InkSwatch('antique-gold', 'Antique Gold', antiqueGold),
    InkSwatch('electric-azure', 'Electric Azure', electricAzure),
    InkSwatch('sapphire', 'Sapphire', sapphire),
    InkSwatch('vivid-turquoise', 'Vivid Turquoise', vividTurquoise),
    InkSwatch('electric-lime', 'Electric Lime', electricLime),
    InkSwatch('ultraviolet', 'Ultraviolet', ultraviolet),
    InkSwatch('electric-gold', 'Electric Gold', electricGold),
    InkSwatch('deep-pine', 'Deep Pine', deepPine),
    InkSwatch('bright-red', 'Bright Red', brightRed),
  ];

  static final List<Color> all = List.unmodifiable(
    library.map((swatch) => swatch.color),
  );
  static InkSwatch? byId(String id) {
    for (final swatch in library) {
      if (swatch.id == id) return swatch;
    }
    return null;
  }
}

class InkSwatch {
  const InkSwatch(this.id, this.name, this.color);
  final String id;
  final String name;
  final Color color;
}

abstract final class ArchiveCategoryColors {
  static const resource = Color(0xFF5581C1);
  static const projects = Color(0xFFBB565A);
  static const other = Color(0xFFDEB866);
  static const shopping = Color(0xFF489A68);
  static const secondBrain = Color(0xFFD492C1);
}

abstract final class CalendarCategoryColors {
  static const reading = Color(0xFF8EA96C);
  static const habits = Color(0xFF7092D0);
  static const other = Color(0xFFC491C1);
  static const reminderEvent = Color(0xFF52B0AB);
}

abstract final class CanvasTagColors {
  static const selected = [
    Color(0xFFACDCD8),
    Color(0xFF2C6149),
    Color(0xFFA65469),
    Color(0xFFE9C5DB),
    Color(0xFFE1AB7B),
  ];
}

List<String> get inkColorNames =>
    InkColors.library.map((swatch) => swatch.name).toList(growable: false);

/// Shared spacing scale, so every page lines up the same way.
abstract final class Space {
  static const xs = AppSpace.xs;
  static const sm = AppSpace.sm;
  static const md = AppSpace.md;
  static const lg = AppSpace.lg;
  static const xl = AppSpace.xl;
  static const xxl = AppSpace.xxl;
  static const page = AppSpace.page;
}

/// The Material theme, built entirely from the design tokens
/// (design_tokens.dart) and the palette (NewColors). Every stock Material
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
  final onAccent = NewColors.onAccent;
  final scheme = light
      ? ColorScheme.light(
          surface: AppColors.background,
          onSurface: AppColors.text,
          onSurfaceVariant: AppColors.textMuted,
          surfaceContainerLowest: AppColors.card,
          surfaceContainerLow: AppColors.card,
          surfaceContainer: AppColors.card,
          surfaceContainerHigh: NewColors.surfaceSecondary,
          surfaceContainerHighest: AppColors.cardRaised,
          primary: AppColors.accent,
          onPrimary: onAccent,
          primaryContainer: NewColors.accentSoft,
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
          surfaceContainerHigh: NewColors.surfaceSecondary,
          surfaceContainerHighest: AppColors.cardRaised,
          primary: AppColors.accent,
          onPrimary: onAccent,
          primaryContainer: NewColors.accentSoft,
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
      fillColor: light ? AppColors.card : NewColors.surfaceSecondary,
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
        backgroundColor: WidgetStatePropertyAll(NewColors.surfaceSecondary),
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
              ? NewColors.accentSoft
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
      backgroundColor: NewColors.surfaceSecondary,
      selectedColor: NewColors.accentSoft,
      disabledColor: faded(NewColors.surfaceSecondary),
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
            : NewColors.surfaceSecondary,
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
      actionTextColor: light ? NewColors.steelBlue : AppColors.accent,
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
