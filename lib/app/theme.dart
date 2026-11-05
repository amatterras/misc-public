import 'package:flutter/material.dart';

import '../new_ui/new_tokens.dart';

import 'dart:ui' show PlatformDispatcher;

/// Colour tokens taken from the Gemini prototype: near-black surfaces,
/// hairline white borders and soft grey text.
abstract final class AppColors {
  static ThemeMode mode = ThemeMode.dark;

  static bool get light => switch (mode) {
    ThemeMode.light => true,
    ThemeMode.dark => false,
    ThemeMode.system =>
      PlatformDispatcher.instance.platformBrightness == Brightness.light,
  };

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
  static const resource = Color(0xFF3060B0);
  static const projects = Color(0xFFB03040);
  static const other = Color(0xFFF0C060);
  static const shopping = Color(0xFF409060);
  static const secondBrain = Color(0xFFE0A0D0);
}

abstract final class CalendarCategoryColors {
  static const reading = Color(0xFFA3B18A);
  static const habits = Color(0xFF6495ED);
  static const other = Color(0xFFDDA0DD);
  static const reminderEvent = Color(0xFF20B2AA);
}

abstract final class CanvasTagColors {
  static const selected = [
    Color(0xFFB5E1DF),
    Color(0xFF15563F),
    Color(0xFFA84D67),
    Color(0xFFE9C5DD),
    Color(0xFFE8AB73),
  ];
}

List<String> get inkColorNames =>
    InkColors.library.map((swatch) => swatch.name).toList(growable: false);

/// Shared spacing scale, so every page lines up the same way.
abstract final class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const page = 48.0;
}

ThemeData buildAppTheme({Brightness brightness = Brightness.dark}) {
  final previousMode = AppColors.mode;

  AppColors.mode = brightness == Brightness.light
      ? ThemeMode.light
      : ThemeMode.dark;
  final scheme = brightness == Brightness.light
      ? ColorScheme.light(
          surface: AppColors.background,
          onSurface: AppColors.text,
          primary: AppColors.accent,
          onPrimary: Colors.white,
          secondary: AppColors.accentSecondary,
          onSecondary: Colors.white,
          error: AppColors.danger,
          onError: Colors.white,
          outline: AppColors.border,
        )
      : ColorScheme.dark(
          surface: AppColors.background,
          onSurface: AppColors.text,
          primary: AppColors.accent,
          onPrimary: AppColors.background,
          secondary: AppColors.accent,
          error: AppColors.danger,
          outline: AppColors.border,
        );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'Segoe UI',
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.compact,
  );
  final result = base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dividerTheme: DividerThemeData(color: AppColors.border, space: 1),
    tooltipTheme: TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: AppColors.cardRaised,
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      textStyle: TextStyle(color: AppColors.text, fontSize: 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(22)),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      // White (light) / raised (dark) menus with a soft shadow.
      color: AppColors.light ? AppColors.card : AppColors.cardRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: const Color(0x331C1A27),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        side: BorderSide(color: AppColors.border),
      ),
      textStyle: TextStyle(color: AppColors.text, fontSize: 13),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppColors.light
          ? AppColors.cardRaised.withValues(alpha: 0.5)
          : AppColors.background,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.accent),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppColors.focus,
      selectionColor: AppColors.selection,
    ),
  );
  AppColors.mode = previousMode;
  return result;
}
