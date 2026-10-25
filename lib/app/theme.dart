import 'package:flutter/material.dart';

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

  // Provisional light palette: the repository history and current spec only
  // record that light theme was postponed, with no recoverable prior values.
  static const _darkBackground = Color(0xFF191A1D);
  static const _darkSidebar = Color(0xFF222429);
  static const _darkRaised = Color(0xFF303239);
  static const _darkBorder = Color(0xFF41444A);
  static const _darkText = Color(0xFFF5F3EF);
  static const _darkMuted = Color(0xFFAAAEB6);
  static const _lightBackground = Color(0xFFF4F2ED);
  static const _lightCanvas = Color(0xFFFBFAF7);
  static const _lightSidebar = Color(0xFFFFFFFF);
  static const _lightRaised = Color(0xFFECE9E3);
  static const _lightBorder = Color(0xFFC9C6BF);
  static const _lightText = Color(0xFF202328);
  static const _lightMuted = Color(0xFF5C6169);
  static const _lightDisabled = Color(0xFF777C84);
  static const _lightAccent = Color(0xFF456E8B);
  static const _lightAccentSecondary = Color(0xFF56738A);
  static const _lightSuccess = Color(0xFF34734F);
  static const _lightWarm = Color(0xFF8A551A);
  static const _lightDanger = Color(0xFFB42318);

  static Color get background => light ? _lightBackground : _darkBackground;
  static Color get canvas => light ? _lightCanvas : _darkBackground;
  static Color get sidebar => light ? _lightSidebar : _darkSidebar;
  static Color get card => light ? _lightSidebar : _darkSidebar;
  static Color get cardRaised => light ? _lightRaised : _darkRaised;
  static Color get border => light ? _lightBorder : _darkBorder;
  static Color get hover =>
      light ? const Color(0x1A456E8B) : const Color(0x1A789BB5);
  static Color get selected => light ? const Color(0xFFDCE6ED) : _darkRaised;
  static Color get text => light ? _lightText : _darkText;
  static Color get textMuted => light ? _lightMuted : _darkMuted;
  static Color get textFaint => light ? _lightDisabled : _darkMuted;
  static Color get disabled => light ? _lightDisabled : _darkMuted;
  static Color get accent => light ? _lightAccent : const Color(0xFF789BB5);
  static Color get accentSecondary =>
      light ? _lightAccentSecondary : const Color(0xFF829CB5);
  static Color get focus => accent;
  static Color get selection =>
      light ? const Color(0x55456E8B) : const Color(0x55789BB5);
  static Color get success => light ? _lightSuccess : const Color(0xFF8FBFA9);
  static Color get brand => const Color(0xFF172943);
  static Color get warm => light ? _lightWarm : const Color(0xFFE5D5B8);
  static Color get danger => light ? _lightDanger : warm;
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
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(color: AppColors.text, fontSize: 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.cardRaised,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: AppColors.border),
      ),
      textStyle: TextStyle(color: AppColors.text, fontSize: 13),
    ),
    inputDecorationTheme: InputDecorationTheme(
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
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppColors.focus,
      selectionColor: AppColors.selection,
    ),
  );
  AppColors.mode = previousMode;
  return result;
}
