// THEapp design system: the one authoritative set of non-colour tokens.
//
// Colour lives next door in lib/new_ui/new_tokens.dart (NewColors, theme
// aware through AppColors.light). Everything else a component needs to look
// like part of the family is here: type, spacing, geometry, strokes,
// elevation and motion. Older names (Space, NewSpace, NewRadii, NewMotion,
// NewText) are kept as thin aliases of these values so nothing drifts.
//
// Rule of thumb for new code: if a number describes how something LOOKS or
// MOVES (a size, a gap, a radius, a duration, a curve), it comes from here.
// Numbers that describe behaviour (debounce delays, hit-test slop, canvas
// geometry stored in documents) stay where they are.
import 'package:flutter/material.dart';

import '../new_ui/new_tokens.dart' show NewColors;
import 'theme.dart' show AppColors;

// ── Typography ─────────────────────────────────────────────────────────────

/// Type scale. One family (the platform UI face), three weights, a tight
/// scale with slightly negative tracking on large sizes and a touch of
/// positive tracking on small labels, which is what keeps it crisp instead of
/// "default Material".
abstract final class AppType {
  /// Windows: Segoe UI. iOS/macOS: falls back to the system face (SF Pro).
  static const family = 'Segoe UI';

  // Sizes.
  static const sizeDisplay = 28.0;
  static const sizeTitle = 20.0;
  static const sizeHeading = 16.0;
  static const sizeBody = 14.0;
  static const sizeBodySmall = 13.0;
  static const sizeLabel = 12.0;
  static const sizeMeta = 11.0;
  static const sizeMicro = 10.0;

  // Weights (400 / 600 / 700 only).
  static const regular = FontWeight.w400;
  static const semibold = FontWeight.w600;
  static const bold = FontWeight.w700;

  // Line heights.
  static const heightTight = 1.15;
  static const heightSnug = 1.3;
  static const heightBody = 1.45;

  // Letter spacing.
  static const trackDisplay = -0.4;
  static const trackTitle = -0.2;
  static const trackBody = 0.0;
  static const trackLabel = 0.1;
  static const trackCaps = 0.6;

  // Styles (colourless: callers add the theme colour, so they stay live).
  static const display = TextStyle(
    fontSize: sizeDisplay,
    fontWeight: semibold,
    height: heightTight,
    letterSpacing: trackDisplay,
  );
  static const title = TextStyle(
    fontSize: sizeTitle,
    fontWeight: bold,
    height: heightTight,
    letterSpacing: trackTitle,
  );
  static const heading = TextStyle(
    fontSize: sizeHeading,
    fontWeight: semibold,
    letterSpacing: -0.1,
  );

  /// One line of UI text (labels, list rows, inputs).
  static const body = TextStyle(fontSize: sizeBody, fontWeight: regular);

  /// Running text (notes, descriptions, AI answers): roomier lines.
  static const paragraph = TextStyle(
    fontSize: sizeBody,
    fontWeight: regular,
    height: heightBody,
  );
  static const bodySmall = TextStyle(
    fontSize: sizeBodySmall,
    fontWeight: regular,
  );

  /// Secondary lines under a title (dates, counts).
  static const caption = TextStyle(fontSize: sizeLabel, fontWeight: regular);
  static const label = TextStyle(
    fontSize: sizeLabel,
    fontWeight: semibold,
    letterSpacing: trackLabel,
  );
  static const meta = TextStyle(fontSize: sizeMeta, fontWeight: regular);

  /// Small all-caps section labels ("RECENT", "TAGS").
  static const caps = TextStyle(
    fontSize: sizeMicro,
    fontWeight: semibold,
    letterSpacing: trackCaps,
  );

  /// Window and panel titles (floating panels, dialogs' own bars).
  static const chrome = TextStyle(
    fontSize: sizeBodySmall,
    fontWeight: semibold,
    letterSpacing: trackLabel,
  );
}

// ── Spacing ────────────────────────────────────────────────────────────────

/// 4-point spacing scale plus named layout roles.
abstract final class AppSpace {
  static const micro = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const page = 48.0;

  /// Between the parts of one control (icon and its label).
  static const inline = 6.0;

  /// Between controls of a group (buttons in a toolbar group).
  static const component = sm;

  /// Between groups / sections of a page.
  static const section = xl;

  /// Inside panels, popups and dialogs.
  static const panel = lg;

  /// Inside dialogs.
  static const dialog = xl;

  /// Page content margin from the window edge.
  static const workspace = xl;

  /// Gap between floating chrome and the window edge.
  static const edge = 14.0;

  /// Between toolbar items, and between toolbar groups.
  static const toolbar = xs;
  static const toolbarGroup = md;
}

// ── Geometry ───────────────────────────────────────────────────────────────

/// Corner radii. Nested surfaces step down one size so corners stay
/// concentric (a 12 popup holds 8 menu rows).
abstract final class AppRadii {
  /// Tiny marks: progress tracks, swatch chips, focus outlines of small things.
  static const xs = 4.0;

  /// Buttons, menu rows, inputs inside panels, list rows.
  static const sm = 8.0;

  /// Inputs, small cards, toolbar capsules' inner items.
  static const md = 12.0;

  /// Popups, menus, dropdown sheets, floating panels.
  static const popup = 14.0;
  static const lg = 16.0;

  /// Content cards.
  static const card = 18.0;

  /// Dialogs and large sheets.
  static const dialog = 22.0;
  static const xl = 24.0;

  /// A full capsule end.
  static const capsule = 999.0;

  static BorderRadius all(double r) => BorderRadius.all(Radius.circular(r));
}

/// Stroke widths.
abstract final class AppStroke {
  static const border = 1.0;
  static const divider = 1.0;

  /// Keyboard focus ring.
  static const focus = 2.0;

  /// Selected-state outline (selected swatch, active card).
  static const selected = 1.5;
}

/// Component sizes shared across modules.
abstract final class AppSizes {
  /// Compact desktop control height (buttons, inputs, dropdowns).
  static const control = 34.0;

  /// Touch control height (iPad / iPhone).
  static const controlTouch = 44.0;

  /// Icon-only buttons in toolbars.
  static const toolbarButton = 32.0;

  /// Title bar of floating panels.
  static const panelHeader = 38.0;

  /// Menu rows.
  static const menuRow = 34.0;

  // Icons.
  static const iconSm = 16.0;
  static const iconMd = 18.0;
  static const iconLg = 20.0;
  static const iconXl = 24.0;
}

// ── Elevation ──────────────────────────────────────────────────────────────

/// Shadows and overlays, theme aware. Dark surfaces separate by tone and a
/// hairline, so their shadows are deep but soft; light surfaces lift with a
/// tight contact shadow plus a wide ink-tinted one.
abstract final class AppElevation {
  static const _ink = Color(0xFF1C1A27);

  static bool get _light => AppColors.light;

  /// Resting cards and chips: barely there.
  static List<BoxShadow> get subtle => _light
      ? [
          BoxShadow(
            color: _ink.withValues(alpha: 0.05),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: _ink.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ]
      : [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ];

  /// Floating panels, popups, menus, toolbars over the canvas.
  static List<BoxShadow> get floating => _light
      ? [
          BoxShadow(
            color: _ink.withValues(alpha: 0.06),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: _ink.withValues(alpha: 0.10),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ]
      : [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.34),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ];

  /// Dialogs: the deepest lift in the app.
  static List<BoxShadow> get dialog => _light
      ? [
          BoxShadow(
            color: _ink.withValues(alpha: 0.08),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
          BoxShadow(
            color: _ink.withValues(alpha: 0.16),
            blurRadius: 48,
            offset: const Offset(0, 20),
          ),
        ]
      : [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.46),
            blurRadius: 56,
            offset: const Offset(0, 24),
          ),
        ];

  /// Material shadow colour for widgets that take an elevation number.
  static Color get shadowColor =>
      _light ? _ink.withValues(alpha: 0.45) : Colors.black;

  /// Scrim behind modal dialogs and sheets.
  static Color get modalBarrier => _light
      ? const Color(0xFF1C1A27).withValues(alpha: 0.22)
      : Colors.black.withValues(alpha: 0.50);
}

// ── Motion ─────────────────────────────────────────────────────────────────

/// Durations and curves. Short, decelerating, never bouncy.
abstract final class AppMotion {
  // Durations, by interaction.
  static const hover = Duration(milliseconds: 120);
  static const press = Duration(milliseconds: 90);
  static const dropdown = Duration(milliseconds: 160);
  static const popup = Duration(milliseconds: 190);
  static const popupExit = Duration(milliseconds: 140);
  static const sidebar = Duration(milliseconds: 220);
  static const page = Duration(milliseconds: 240);
  static const panel = Duration(milliseconds: 180);

  /// Small state changes (a chip filling, a check appearing).
  static const quick = Duration(milliseconds: 140);

  /// Default for anything larger than a hover that is not listed above.
  static const normal = Duration(milliseconds: 220);

  // Curves.
  /// Entering / changing: decelerate into place.
  static const standard = Curves.easeOutCubic;

  /// Larger moves (sidebar, page): a quick start and a long, soft landing.
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Leaving: accelerate away.
  static const exit = Curves.easeInCubic;

  /// Popup entrance: fade plus this much scale (0.96 → 1).
  static const popupScaleFrom = 0.96;

  /// True when the system asks for reduced motion (Windows "Animation
  /// effects" off, iOS "Reduce Motion"), as Flutter reports it.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [d], or no animation at all when the user asked for reduced motion.
  static Duration of(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;
}

/// Interaction-state colours shared by every control, derived from the
/// palette so they follow the theme.
abstract final class AppStates {
  static Color get hover => NewColors.hover;
  static Color get pressed =>
      AppColors.light ? const Color(0x1A1C1A27) : const Color(0x24FFFFFF);
  static Color get focusRing => NewColors.accent.withValues(alpha: 0.55);
  static Color get selected => NewColors.selected;

  /// Opacity of disabled controls (content and fill together).
  static const disabledOpacity = 0.42;
}
