import 'package:flutter/material.dart';

/// Colour tokens taken from the Gemini prototype: near-black surfaces,
/// hairline white borders and soft grey text.
abstract final class AppColors {
  static const background = Color(0xFF141414);
  static const canvas = Color(0xFF111111);
  static const sidebar = Color(0xFF181818);
  static const card = Color(0xFF1B1B1B);
  static const cardRaised = Color(0xFF222222);
  static const border = Color(0x14FFFFFF);
  static const hover = Color(0x0DFFFFFF);
  static const selected = Color(0xFF262626);
  static const text = Color(0xFFEDEDED);
  static const textMuted = Color(0xFF8E8E8E);
  static const textFaint = Color(0xFF5C5C5C);
  static const accent = Color(0xFF4D8FD6);
  static const danger = Color(0xFFE76F51);
}

/// The ten organiser colours shared by Calendar entries, pens and labels.
abstract final class OrganizerColors {
  static const coral = Color(0xFFE76F51);
  static const amber = Color(0xFFE9A23B);
  static const yellow = Color(0xFFE8D45B);
  static const green = Color(0xFF79B85A);
  static const teal = Color(0xFF35A99A);
  static const blue = Color(0xFF4D8FD6);
  static const indigo = Color(0xFF6965C9);
  static const purple = Color(0xFFA56BC4);
  static const pink = Color(0xFFD86D9C);
  static const grey = Color(0xFF9A9A9A);

  static const all = [
    coral,
    amber,
    yellow,
    green,
    teal,
    blue,
    indigo,
    purple,
    pink,
    grey,
  ];
}

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
    primary: AppColors.text,
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
      selectionColor: Color(0x554D8FD6),
    ),
  );
}
