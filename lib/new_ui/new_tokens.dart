// Design tokens of the New interface. Original keeps using app/theme.dart
// (AppColors, Space); nothing here changes it. While New is active,
// AppColors returns these values (AppColors.newDesign), so every module gets
// the New palette from this one file.
//
// Light/dark follows the same theme choice as the rest of the app
// (Settings → Appearance → Theme) through AppColors.light.
import 'package:flutter/material.dart';

import '../app/theme.dart';

abstract final class NewColors {
  static bool get _light => AppColors.light;

  // Sampled reference palette (Soma atmospheric gradient).
  static const warmCoral = Color(0xFFCD775C);
  static const softCoral = Color(0xFFE7A396);
  static const dustyRose = Color(0xFFD7AFBF);
  static const mutedRose = Color(0xFFC99396);
  static const paleLavender = Color(0xFFC1BEE5);
  static const periwinkle = Color(0xFFABB0EA);
  static const lavenderBlue = Color(0xFF9EA4D0);
  static const mutedViolet = Color(0xFF7D80B8);
  static const deepIndigo = Color(0xFF5B629C);
  static const blueGrey = Color(0xFF7589A0);
  static const warmOffWhite = Color(0xFFFFFBFA);

  /// Established identity colour (also Original's accent).
  static const steelBlue = Color(0xFF789BB5);

  // ── Surface hierarchy ────────────────────────────────────────────────
  //
  // Light theme ("porcelain & ink"): a cool pearl page, pure white cards that
  // lift off it, and one slate ink for text and borders. Depth comes from soft
  // layered shadows and hairlines, not from heavy fills or outlines.
  //
  // Harmony rules (2026-11-08 colour pass, values computed in OKLCH):
  // - Every neutral (page, surfaces, borders, text, both themes) shares ONE
  //   undertone, hue 268° — between the steel-blue accent (241°) and the
  //   periwinkle/indigo gradient (~278°), so it bridges the two instead of
  //   fighting them. Before, neutrals drifted 269°→318° (text read pinkish).
  // - Selected states are tinted toward the accent hue, not the neutral one.
  // - success / warm / danger share one lightness and chroma per theme, so
  //   no state colour shouts louder than another.
  // - Category colours (calendar, archive, canvas tags; theme.dart) keep
  //   their original hues but share one muted chroma/lightness band
  //   (retuned 2026-11-08 from stock web colours, user-approved).
  // Keep new colours inside these rules.

  /// The window / canvas background.
  static Color get background =>
      _light ? const Color(0xFFF3F5F9) : const Color(0xFF191A1D);
  static Color get canvas => background;
  static Color get canvasPage => background;

  /// Standard surface (cards, sidebar panels, dialogs).
  static Color get surface =>
      _light ? const Color(0xFFFFFFFF) : const Color(0xFF1F2126);

  /// Secondary surface (inputs, grouped areas).
  static Color get surfaceSecondary =>
      _light ? const Color(0xFFECEEF5) : const Color(0xFF26282F);

  /// Elevated surface (menus, tooltips, floating panels).
  static Color get surfaceRaised =>
      _light ? const Color(0xFFE5E8F0) : const Color(0xFF2C2F36);

  static Color get border =>
      _light ? const Color(0xFFDEE2EA) : const Color(0xFF3A3D45);

  // ── Text ─────────────────────────────────────────────────────────────
  static Color get text =>
      _light ? const Color(0xFF181C25) : const Color(0xFFEFF0F4);
  static Color get textMuted =>
      _light ? const Color(0xFF555B68) : const Color(0xFFB7BAC3);

  /// Muted text, kept at 4.5:1 or better on the page and on white.
  static Color get textFaint =>
      _light ? const Color(0xFF656A78) : const Color(0xFF888C96);

  // ── Accent and states ───────────────────────────────────────────────
  /// Primary accent for text, icons and fills: the established steel blue.
  /// Light uses a deepened steel blue (#3E6A8C, about 5.3:1 on the page)
  /// so both themes share one identity.
  static Color get accent =>
      _light ? const Color(0xFF3E6A8C) : const Color(0xFF789BB5);

  /// Text and icons on an [accent] fill (filled buttons, switches).
  static Color get onAccent =>
      _light ? const Color(0xFFFFFFFF) : const Color(0xFF191A1D);
  static Color get accentSecondary => _light ? deepIndigo : periwinkle;
  static Color get accentSoft => accent.withValues(alpha: _light ? 0.11 : 0.16);
  static Color get selected =>
      _light ? const Color(0xFFE0EAF4) : const Color(0xFF242D38);
  static Color get selection => accent.withValues(alpha: 0.28);
  static Color get hover =>
      _light ? const Color(0x0F181C25) : const Color(0x14FFFFFF);
  static Color get success =>
      _light ? const Color(0xFF3D784F) : const Color(0xFF8FBF98);
  static Color get warm =>
      _light ? const Color(0xFFA45936) : const Color(0xFFDFA084);
  static Color get danger =>
      _light ? const Color(0xFFAF3D36) : const Color(0xFFE39289);

  // ── Glass ────────────────────────────────────────────────────────────
  static Color get glass =>
      _light ? const Color(0xCCFFFFFF) : const Color(0x991F2126);
  static Color get glassBorder =>
      _light ? const Color(0x1A181C25) : const Color(0x26FFFFFF);
  static Color get glassHighlight =>
      _light ? const Color(0xE6FFFFFF) : const Color(0x33FFFFFF);
}

/// Gradient library. The target is a soft blurred field, not hard bands:
/// large radial colour pools that overlap, over a graphite (dark) or warm
/// white (light) base. Use sparingly: navigation, floating surfaces,
/// selected surfaces, decorative backgrounds.
abstract final class NewGradients {
  static bool get _light => AppColors.light;

  /// Opacity of the colour pools on top of the base.
  static double get poolOpacity => _light ? 0.24 : 0.26;

  /// The pools: (alignment, colour, radius). Upper-left coral → upper-middle
  /// peach → upper-right rose/lavender → middle periwinkle → lavender blue →
  /// lower muted violet → indigo at the deep edge.
  static const pools = <(Alignment, Color, double)>[
    (Alignment(-0.9, -0.95), NewColors.warmCoral, 0.95),
    (Alignment(-0.1, -0.85), NewColors.softCoral, 0.85),
    (Alignment(0.9, -0.8), NewColors.paleLavender, 0.85),
    (Alignment(0.0, -0.05), NewColors.periwinkle, 0.9),
    (Alignment(0.95, 0.15), NewColors.lavenderBlue, 0.85),
    (Alignment(-0.3, 0.8), NewColors.mutedViolet, 0.95),
    (Alignment(0.7, 1.0), NewColors.deepIndigo, 0.9),
  ];

  /// Radial layers for [BoxDecoration]-style use (stack them).
  static List<RadialGradient> layers() => [
    for (final (at, color, radius) in pools)
      RadialGradient(
        center: at,
        radius: radius,
        colors: [
          color.withValues(alpha: poolOpacity),
          color.withValues(alpha: 0),
        ],
      ),
  ];

  /// Light falling across floating chrome (top-left to bottom-right).
  static LinearGradient get lighting => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      NewColors.periwinkle.withValues(alpha: _light ? 0.14 : 0.16),
      Colors.transparent,
      NewColors.softCoral.withValues(alpha: _light ? 0.12 : 0.12),
    ],
  );

  /// Brand gradient (selected-item marker, Quick Add, selected date).
  static const LinearGradient brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [NewColors.periwinkle, NewColors.warmCoral],
  );
}

abstract final class NewRadii {
  static const sm = AppRadii.md;
  static const md = AppRadii.popup;
  static const card = AppRadii.card;
  static const lg = AppRadii.xl;

  /// A full capsule (pill) end.
  static const capsule = AppRadii.capsule;
}

/// 4/8-point spacing scale.
abstract final class NewSpace {
  static const xs = AppSpace.xs;
  static const sm = AppSpace.sm;
  static const md = AppSpace.md;
  static const lg = AppSpace.lg;
  static const xl = AppSpace.lg + AppSpace.xs;
  static const xxl = AppSpace.xl;
  static const xxxl = AppSpace.xxl;

  /// Gap between the window edge and floating chrome.
  static const edge = AppSpace.edge;
}

abstract final class NewSizes {
  static const icon = 20.0;
  static const navItem = 44.0;
  static const capsuleWidth = 60.0;
  static const capsuleExpandedWidth = 188.0;
  static const border = 1.0;
}

/// Blur strengths in one place.
abstract final class NewBlur {
  static const glass = 18.0;
  static const glow = 36.0;
}

abstract final class NewMotion {
  static const quick = AppMotion.quick;
  static const normal = AppMotion.normal;
  static const curve = AppMotion.standard;
}

abstract final class NewShadows {
  static List<BoxShadow> get floating => AppElevation.floating;

  /// A resting card: barely there.
  static List<BoxShadow> get card => AppElevation.subtle;

  /// Soft coloured light around a floating surface.
  static List<BoxShadow> get glow => [
    BoxShadow(
      color: NewColors.periwinkle.withValues(
        alpha: AppColors.light ? 0.16 : 0.18,
      ),
      blurRadius: NewBlur.glow,
      spreadRadius: 1,
    ),
    BoxShadow(
      color: NewColors.warmCoral.withValues(
        alpha: AppColors.light ? 0.08 : 0.10,
      ),
      blurRadius: NewBlur.glow,
      offset: const Offset(0, 14),
    ),
  ];
}

/// Compact text styles (SF Pro design language: the app's existing font
/// configuration is kept; weights 400 / 600 / 700 only).
abstract final class NewText {
  static const label = AppType.label;
  static const body = AppType.body;
  static const meta = AppType.caption;
  static const title = AppType.heading;
  static const heading = AppType.title;
}

/// Icon sizes.
abstract final class NewIcons {
  static const sm = AppSizes.iconSm;
  static const md = AppSizes.iconLg;
  static const lg = AppSizes.iconXl;
}
