// Live theme switching.
//
// Most of THEapp reads its colours from AppColors / NewColors, which are
// static getters that follow AppColors.mode. That keeps components simple,
// but a widget that does not depend on Theme.of(context) is not rebuilt by
// MaterialApp when the theme changes, and a CustomPainter that reads the
// palette while painting is not repainted. Without help, a switch would leave
// parts of the screen (a floating window, an open popup, the canvas grid) in
// the old colours until something else touched them.
//
// [ThemeSwitch.apply] is the one place a theme change happens: it sets the
// mode, then marks every element of the app for rebuild and every render
// object for repaint, in the same frame. State is untouched (nothing is
// re-created), so the workspace, open windows, dialogs, scroll positions and
// half-typed text all stay exactly as they were. MaterialApp's own theme
// cross-fade is turned off (themeAnimationDuration: zero) so Theme-based and
// palette-based colours never disagree for a few frames.
import 'package:flutter/material.dart';

import '../platform/window_chrome.dart';
import 'theme.dart';

abstract final class ThemeSwitch {
  /// The brightness the app was last drawn in (null before the first apply).
  static Brightness? _drawn;

  /// Forgets the last drawn brightness (tests).
  @visibleForTesting
  static void reset() => _drawn = null;

  /// The brightness the app is drawn in right now.
  static Brightness get brightness =>
      AppColors.light ? Brightness.light : Brightness.dark;

  /// Sets [mode] and refreshes everything under [root] (normally the app's
  /// root element) if the visible brightness changed. Returns whether it did.
  static bool apply(ThemeMode mode, {Element? root}) {
    AppColors.mode = mode;
    final after = brightness;
    final before = _drawn ?? after;
    _drawn = after;
    // The native title bar follows the app, not the Windows setting.
    WindowChrome.apply(dark: after == Brightness.dark);
    if (before == after) return false;
    if (root != null) refreshTree(root);
    return true;
  }

  /// Marks [root] and everything below it for rebuild and repaint.
  static void refreshTree(Element root) {
    void visit(Element e) {
      e.markNeedsBuild();
      if (e is RenderObjectElement) {
        final r = e.renderObject;
        if (r.attached) r.markNeedsPaint();
      }
      e.visitChildren(visit);
    }

    root.markNeedsBuild();
    root.visitChildren(visit);
  }
}

/// Calls [onChange] when the operating system switches light/dark, so the
/// "System" theme choice follows it live.
class PlatformBrightnessListener with WidgetsBindingObserver {
  PlatformBrightnessListener(this.onChange) {
    WidgetsBinding.instance.addObserver(this);
  }

  final VoidCallback onChange;

  @override
  void didChangePlatformBrightness() => onChange();

  void dispose() => WidgetsBinding.instance.removeObserver(this);
}

/// Shortcut so tests can refresh a pumped app the same way the app does.
@visibleForTesting
void debugRefreshThemeTree(Element root) => ThemeSwitch.refreshTree(root);
