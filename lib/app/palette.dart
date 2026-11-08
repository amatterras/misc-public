// misc.'s colour system: the one place colours are defined.
//
//   AppColors      semantic roles (page, cards, text, accent, states, glass),
//                  light and dark, following Settings → Appearance → Theme
//   BrandColors    the fixed brand hues the gradients and glows are made of
//   AppGradients   the brand gradient, the app-wide atmosphere, lighting
//   InkColors …    content palettes: pen inks, Calendar / Archive categories
//                  and canvas tags (stored ids and user-facing names)
//
// Non-colour tokens (type, spacing, radii, motion, elevation) live in
// design_tokens.dart; theme.dart builds the Material theme from both and
// re-exports them, so `import 'theme.dart'` gives a widget everything.
//
// Harmony rules (2026-11-08 colour pass, values computed in OKLCH):
// - Every neutral (page, surfaces, borders, text, both themes) shares ONE
//   undertone, hue 268° — between the steel-blue accent (241°) and the
//   periwinkle/indigo brand hues (~278°), so it bridges the two.
// - Selected states are tinted toward the accent hue, not the neutral one.
// - success / warm / danger share one lightness and chroma per theme, so no
//   state colour shouts louder than another.
// - Category colours keep their own hues but share one muted
//   chroma/lightness band (retuned 2026-11-08, user-approved).
// Keep new colours inside these rules.
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

/// Semantic colour roles. Light theme ("porcelain & ink"): a cool pearl
/// page, pure white cards that lift off it, and one slate ink for text and
/// borders. Dark: graphite with the same undertone. Depth comes from soft
/// layered shadows and hairlines, not heavy fills or outlines.
abstract final class AppColors {
  /// The theme choice; set by AppState from Settings → Appearance → Theme.
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

  // ── Page and surfaces ────────────────────────────────────────────────

  /// The window and page background (also the infinite canvas).
  static Color get background =>
      light ? const Color(0xFFF3F5F9) : const Color(0xFF191A1D);
  static Color get canvas => background;

  /// Standard surface: cards, panels, dialogs.
  static Color get card =>
      light ? const Color(0xFFFFFFFF) : const Color(0xFF1F2126);

  /// The sidebar's surface (the same as a card).
  static Color get sidebar => card;

  /// Secondary surface: inputs, grouped areas.
  static Color get surfaceSecondary =>
      light ? const Color(0xFFECEEF5) : const Color(0xFF26282F);

  /// Elevated surface: menus, tooltips, floating panels.
  static Color get cardRaised =>
      light ? const Color(0xFFE5E8F0) : const Color(0xFF2C2F36);

  static Color get border =>
      light ? const Color(0xFFDEE2EA) : const Color(0xFF3A3D45);

  // ── Text ─────────────────────────────────────────────────────────────
  static Color get text =>
      light ? const Color(0xFF181C25) : const Color(0xFFEFF0F4);
  static Color get textMuted =>
      light ? const Color(0xFF555B68) : const Color(0xFFB7BAC3);

  /// Faint text, kept at 4.5:1 or better on the page and on white.
  static Color get textFaint =>
      light ? const Color(0xFF656A78) : const Color(0xFF888C96);
  static Color get disabled => textFaint;

  // ── Accent and states ────────────────────────────────────────────────

  /// Primary accent for text, icons and fills: the established steel blue.
  /// Light uses a deepened steel blue (#3E6A8C, about 5.3:1 on the page) so
  /// both themes share one identity.
  static Color get accent =>
      light ? const Color(0xFF3E6A8C) : BrandColors.steelBlue;
  static Color get focus => accent;

  /// Text and icons on an [accent] fill (filled buttons, switches).
  static Color get onAccent =>
      light ? const Color(0xFFFFFFFF) : const Color(0xFF191A1D);
  static Color get accentSecondary =>
      light ? BrandColors.deepIndigo : BrandColors.periwinkle;
  static Color get accentSoft => accent.withValues(alpha: light ? 0.11 : 0.16);
  static Color get brand => BrandColors.deepIndigo;

  static Color get selected =>
      light ? const Color(0xFFE0EAF4) : const Color(0xFF242D38);
  static Color get selection => accent.withValues(alpha: 0.28);
  static Color get hover =>
      light ? const Color(0x0F181C25) : const Color(0x14FFFFFF);
  static Color get success =>
      light ? const Color(0xFF3D784F) : const Color(0xFF8FBF98);
  static Color get warm =>
      light ? const Color(0xFFA45936) : const Color(0xFFDFA084);
  static Color get danger =>
      light ? const Color(0xFFAF3D36) : const Color(0xFFE39289);

  // ── Glass (floating chrome) ──────────────────────────────────────────
  static Color get glass =>
      light ? const Color(0xCCFFFFFF) : const Color(0x991F2126);
  static Color get glassBorder =>
      light ? const Color(0x1A181C25) : const Color(0x26FFFFFF);
}

/// The fixed brand hues (the same in both themes). Gradients, glows and a
/// few accents are made of these; screens use [AppColors] roles instead.
abstract final class BrandColors {
  /// The established identity colour: the dark theme's accent.
  static const steelBlue = Color(0xFF789BB5);

  // Sampled reference palette (Soma atmospheric gradient).
  static const warmCoral = Color(0xFFCD775C);
  static const softCoral = Color(0xFFE7A396);
  static const periwinkle = Color(0xFFABB0EA);
  static const deepIndigo = Color(0xFF5B629C);

  // The brand gradient's stops: one OKLCH lightness (≈ 0.62), travelling
  // through rose so the middle never greys and white on it stays ≥3.6:1.
  static const iris = Color(0xFF787DC3);
  static const rose = Color(0xFFB66C93);
  static const coral = Color(0xFFCA6C53);
}

/// Gradient library. The target is a soft blurred field, not hard bands.
/// Use sparingly: navigation, floating surfaces, selected surfaces, the
/// app-wide atmosphere.
abstract final class AppGradients {
  static bool get _light => AppColors.light;

  /// Brand gradient (selected-item marker, Quick Add, filled buttons,
  /// progress bars, selected date). Same periwinkle → coral direction as the
  /// atmosphere, at one lightness end to end.
  static const LinearGradient brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [BrandColors.iris, BrandColors.rose, BrandColors.coral],
  );

  /// Light falling across floating chrome (top-left to bottom-right).
  static LinearGradient get lighting => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      BrandColors.periwinkle.withValues(alpha: _light ? 0.14 : 0.16),
      Colors.transparent,
      BrandColors.softCoral.withValues(alpha: 0.12),
    ],
  );

  /// The atmosphere: ONE continuous field painted behind the whole window
  /// (every page, the page bar, the sidebar; see `NewAtmosphere`), not a
  /// patch per page header.
  ///
  /// - Hues travel one path across the window — coral (top-left) → rose →
  ///   iris (top-right) → lavender blue (right) — with a mauve bridge in
  ///   the middle and quiet violet / indigo low corners. Pools that overlap
  ///   are always hue neighbours, so no blend turns grey.
  /// - Pools are ellipses that follow the window's shape, with a smooth
  ///   falloff (no visible rim).
  /// - Strength is set so text keeps contrast everywhere: main text ≥11:1,
  ///   muted ≥5.2:1 at the strongest spot, both themes.
  /// - Light is its own set: the same map as pastels, no deep indigo (it
  ///   turns grey on white).
  static List<AtmospherePool> get pools => _light ? _lightPools : _darkPools;

  /// How much of the page colour is laid back over the field towards the
  /// bottom of the window (0 at the top), so lists and grids lower down sit
  /// on a calmer ground while the field stays continuous.
  static double get veilBottom => _light ? 0.20 : 0.25;

  static const _darkPools = <AtmospherePool>[
    AtmospherePool(Alignment(-0.95, -1.05), 0.62, Color(0xFFD28063), 0.14),
    AtmospherePool(Alignment(-0.20, -1.10), 0.55, Color(0xFFC27895), 0.13),
    AtmospherePool(Alignment(0.70, -1.05), 0.62, Color(0xFF928FD4), 0.15),
    AtmospherePool(Alignment(1.10, -0.15), 0.50, Color(0xFF7185B7), 0.11),
    AtmospherePool(Alignment(0.10, -0.30), 0.55, Color(0xFF9F7FA7), 0.07),
    AtmospherePool(Alignment(-1.05, 1.05), 0.55, Color(0xFF7C6A9D), 0.09),
    AtmospherePool(Alignment(0.95, 1.10), 0.55, Color(0xFF575D96), 0.11),
  ];

  static const _lightPools = <AtmospherePool>[
    AtmospherePool(Alignment(-0.95, -1.05), 0.62, Color(0xFFF5BCA2), 0.28),
    AtmospherePool(Alignment(-0.20, -1.10), 0.55, Color(0xFFEBB6C9), 0.26),
    AtmospherePool(Alignment(0.70, -1.05), 0.62, Color(0xFFBFBEF0), 0.30),
    AtmospherePool(Alignment(1.10, -0.15), 0.50, Color(0xFFBBCBEC), 0.25),
    AtmospherePool(Alignment(0.10, -0.30), 0.55, Color(0xFFDFC8E4), 0.16),
    AtmospherePool(Alignment(-1.05, 1.05), 0.55, Color(0xFFD2C7EA), 0.22),
    AtmospherePool(Alignment(0.95, 1.10), 0.55, Color(0xFFB8C2EC), 0.22),
  ];
}

/// One colour pool of the atmosphere field ([AppGradients.pools]).
class AtmospherePool {
  const AtmospherePool(this.center, this.radius, this.color, this.opacity);

  /// Where the pool is centred; may lie just outside the window.
  final Alignment center;

  /// Radius as a fraction of the window's width (horizontally) and height
  /// (vertically): the pool is an ellipse with the window's proportions.
  final double radius;
  final Color color;

  /// Strength at the centre; it falls smoothly to 0 at the rim.
  final double opacity;
}

// ── Content palettes ───────────────────────────────────────────────────────
// Colours people pick or that mark categories. Their ids and names are
// stored or shown, so they are not theme roles.

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

List<String> get inkColorNames =>
    InkColors.library.map((swatch) => swatch.name).toList(growable: false);

/// Archive / Links categories (spec ID-003).
abstract final class ArchiveCategoryColors {
  static const resource = Color(0xFF5581C1);
  static const projects = Color(0xFFBB565A);
  static const other = Color(0xFFDEB866);
  static const shopping = Color(0xFF489A68);
  static const secondBrain = Color(0xFFD492C1);
}

/// Calendar categories (spec ID-004).
abstract final class CalendarCategoryColors {
  static const reading = Color(0xFF8EA96C);
  static const habits = Color(0xFF7092D0);
  static const other = Color(0xFFC491C1);
  static const reminderEvent = Color(0xFF52B0AB);
}

/// Canvas lasso / tag colours, in their selected order (spec ID-005).
abstract final class CanvasTagColors {
  static const selected = [
    Color(0xFFACDCD8),
    Color(0xFF2C6149),
    Color(0xFFA65469),
    Color(0xFFE9C5DB),
    Color(0xFFE1AB7B),
  ];
}
