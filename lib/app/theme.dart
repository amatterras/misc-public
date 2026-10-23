import 'package:flutter/material.dart';

/// Colour tokens taken from the Gemini prototype: near-black surfaces,
/// hairline white borders and soft grey text.
abstract final class AppColors {
  static const background = Color(0xFF191A1D);
  static const canvas = background;
  static const sidebar = Color(0xFF222429);
  static const card = Color(0xFF222429);
  static const cardRaised = Color(0xFF303239);
  static const border = Color(0xFF41444A);
  static const hover = Color(0x1A789BB5);
  static const selected = Color(0xFF303239);
  static const text = Color(0xFFF5F3EF);
  static const textMuted = Color(0xFFAAAEB6);
  static const textFaint = Color(0xFFAAAEB6);
  static const accent = Color(0xFF789BB5);
  static const accentSecondary = Color(0xFF829CB5);
  static const success = Color(0xFF8FBFA9);
  static const brand = Color(0xFF172943);
  static const warm = Color(0xFFE5D5B8);
  // No separate danger hue was selected; warnings use the approved warm role.
  static const danger = warm;
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

  static const all = [
    pearl,
    steelBlue,
    dustyBlue,
    midnightNavy,
    petrol,
    dustyMint,
    pistachio,
    orchidMist,
    softAmber,
    fuchsia,
    antiqueGold,
    electricAzure,
    sapphire,
    vividTurquoise,
    electricLime,
    ultraviolet,
    electricGold,
    deepPine,
  ];
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

const inkColorNames = [
  'Pearl',
  'Steel Blue',
  'Dusty Blue',
  'Midnight Navy',
  'Petrol',
  'Dusty Mint',
  'Pistachio',
  'Orchid Mist',
  'Soft Amber',
  'Fuchsia',
  'Antique Gold',
  'Electric Azure',
  'Sapphire',
  'Vivid Turquoise',
  'Electric Lime',
  'Ultraviolet',
  'Electric Gold',
  'Deep Pine',
];

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

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
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
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'Segoe UI',
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.compact,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, space: 1),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: AppColors.cardRaised,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(color: AppColors.text, fontSize: 12),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.cardRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: AppColors.border),
      ),
      textStyle: TextStyle(color: AppColors.text, fontSize: 13),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppColors.background,
      border: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: AppColors.textMuted),
      ),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.text,
      selectionColor: Color(0x55789BB5),
    ),
  );
}
