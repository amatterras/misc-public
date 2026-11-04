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
  // Light theme ("porcelain & ink"): a cool pearl page with a breath of
  // lavender, pure white cards that lift off it, and one violet-tinted ink for
  // text and borders so nothing reads as neutral grey. Depth comes from soft
  // layered shadows and hairlines, not from heavy fills or outlines.

  /// The window / canvas background.
  static Color get background =>
      _light ? const Color(0xFFF5F4F9) : const Color(0xFF191A1D);
  static Color get canvas => background;
  static Color get canvasPage => background;

  /// Standard surface (cards, sidebar panels, dialogs).
  static Color get surface =>
      _light ? const Color(0xFFFFFFFF) : const Color(0xFF202126);

  /// Secondary surface (inputs, grouped areas).
  static Color get surfaceSecondary =>
      _light ? const Color(0xFFEEEDF5) : const Color(0xFF262932);

  /// Elevated surface (menus, tooltips, floating panels).
  static Color get surfaceRaised =>
      _light ? const Color(0xFFE8E6F2) : const Color(0xFF2D3038);

  static Color get border =>
      _light ? const Color(0xFFE3E1EC) : const Color(0xFF3A3D47);

  // ── Text ─────────────────────────────────────────────────────────────
  static Color get text =>
      _light ? const Color(0xFF1C1A27) : const Color(0xFFF4F1F5);
  static Color get textMuted =>
      _light ? const Color(0xFF5D5A6B) : const Color(0xFFB9B5C1);

  /// Muted text, kept at 4.5:1 or better on the page and on white.
  static Color get textFaint =>
      _light ? const Color(0xFF6A6778) : const Color(0xFF898692);

  // ── Accent and states ───────────────────────────────────────────────
  /// Primary accent for text, icons and fills. Light uses a deeper iris than
  /// [mutedViolet] (#7D80B8 is only 3.6:1 on the page; this is 5.2:1).
  static Color get accent =>
      _light ? const Color(0xFF5B60A8) : const Color(0xFF789BB5);
  static Color get accentSecondary => _light ? deepIndigo : periwinkle;
  static Color get accentSoft => accent.withValues(alpha: _light ? 0.11 : 0.16);
  static Color get selected =>
      _light ? const Color(0xFFE9E8F6) : const Color(0xFF282C38);
  static Color get selection => accent.withValues(alpha: 0.28);
  static Color get hover =>
      _light ? const Color(0x0F1C1A27) : const Color(0x14FFFFFF);
  static Color get success =>
      _light ? const Color(0xFF3F7A57) : const Color(0xFF9DB59A);
  static Color get warm =>
      _light ? const Color(0xFFB0603F) : const Color(0xFFE7A396);
  static Color get danger =>
      _light ? const Color(0xFFB42318) : const Color(0xFFE48A74);

  // ── Glass ────────────────────────────────────────────────────────────
  static Color get glass =>
      _light ? const Color(0xCCFFFFFF) : const Color(0x99202126);
  static Color get glassBorder =>
      _light ? const Color(0x1A1C1A27) : const Color(0x26FFFFFF);
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
  static const sm = 10.0;
  static const md = 14.0;
  static const card = 18.0;
  static const lg = 24.0;

  /// A full capsule (pill) end.
  static const capsule = 999.0;
}

/// 4/8-point spacing scale.
abstract final class NewSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;

  /// Gap between the window edge and floating chrome.
  static const edge = 14.0;
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
  static const quick = Duration(milliseconds: 140);
  static const normal = Duration(milliseconds: 220);
  static const curve = Curves.easeOutCubic;
}

abstract final class NewShadows {
  // Light shadows are tinted with the ink violet and layered (a tight contact
  // shadow plus a wide soft one), which is what makes white cards look lifted
  // instead of outlined.
  static const _ink = Color(0xFF1C1A27);

  static List<BoxShadow> get floating => AppColors.light
      ? [
          BoxShadow(
            color: _ink.withValues(alpha: 0.06),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: _ink.withValues(alpha: 0.09),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ]
      : [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ];

  /// A resting card: barely there.
  static List<BoxShadow> get card => AppColors.light
      ? [
          BoxShadow(
            color: _ink.withValues(alpha: 0.05),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: _ink.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ]
      : [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ];

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
  static const label = TextStyle(fontSize: 12, fontWeight: FontWeight.w600);
  static const body = TextStyle(fontSize: 14, fontWeight: FontWeight.w400);
  static const meta = TextStyle(fontSize: 12, fontWeight: FontWeight.w400);
  static const title = TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
  static const heading = TextStyle(fontSize: 20, fontWeight: FontWeight.w700);
}

/// Icon sizes.
abstract final class NewIcons {
  static const sm = 16.0;
  static const md = 20.0;
  static const lg = 24.0;
}
