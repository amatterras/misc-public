// Floating panels inside THEapp's window (e.g. the app-switching bar, the
// AI window): they can be dragged by their title bar and resized from the
// corner, stay inside the window, and remember where they were on this
// device (settings are per device, so an iPad layout never moves a PC one).
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/repositories/canvas_repository.dart' show SettingsRepository;

/// What a floating window shows.
class FloatingWindowSpec {
  const FloatingWindowSpec({
    required this.id,
    required this.title,
    required this.builder,
    this.initialRect = const Rect.fromLTWH(80, 80, 380, 420),
    this.initialRectFor,
    this.minSize = const Size(220, 140),
    this.onMinimize,
    this.onDock,
    this.onClose,
    this.liveTitle,
  });

  /// The current title (a page window follows its note or chat title).
  final String Function()? liveTitle;

  /// Window buttons for pages (minimize, put back in the main area,
  /// close). Without [onClose] the close button just hides the window.
  final VoidCallback? onMinimize;
  final VoidCallback? onDock;
  final VoidCallback? onClose;

  final String id;
  final String title;
  final WidgetBuilder builder;
  final Rect initialRect;

  /// Optional viewport-aware initial geometry. Used by content windows whose
  /// default size is defined relative to the page-content viewport.
  final Rect Function(Size viewport)? initialRectFor;
  final Size minSize;
}

/// Shared default geometry for floating page content. Coordinates are local
/// to the visible page-content area (below the page bar and beside the
/// sidebar), never the operating-system display or a document canvas.
abstract final class ContentWindowGeometry {
  static const phoneBreakpoint = 640.0;
  static const desktopWidthFraction = 2 / 5;
  static const verticalMarginFraction = .075;
  static const phoneHorizontalMargin = 12.0;

  static Rect initial(Size viewport) {
    final width = viewport.width < phoneBreakpoint
        ? (viewport.width - phoneHorizontalMargin * 2).clamp(
            0.0,
            viewport.width,
          )
        : viewport.width * desktopWidthFraction;
    final top = viewport.height * verticalMarginFraction;
    final height = viewport.height - top * 2;
    final left =
        viewport.width -
        width -
        (viewport.width < phoneBreakpoint ? phoneHorizontalMargin : 0.0);
    return Rect.fromLTWH(left.clamp(0.0, viewport.width), top, width, height);
  }
}

class FloatingWindows extends ChangeNotifier {
  FloatingWindows(this._settings);

  final SettingsRepository _settings;
  static const _key = 'floatingWindows';

  /// Open windows, back to front.
  final List<FloatingWindowSpec> _open = [];
  List<FloatingWindowSpec> get open => List.unmodifiable(_open);

  bool isOpen(String id) => _open.any((w) => w.id == id);

  Map<String, dynamic> get _saved => {
    ...?_settings.get<Map<String, dynamic>>(_key),
  };

  /// Where window [spec] is (its last place on this device, or its
  /// initial one).
  Rect rectOf(FloatingWindowSpec spec, {Size? viewport}) {
    final r = _saved[spec.id];
    if (r is List && r.length == 4 && r.every((v) => v is num)) {
      final v = [for (final n in r) (n as num).toDouble()];
      return Rect.fromLTWH(
        v[0],
        v[1],
        v[2] < spec.minSize.width ? spec.minSize.width : v[2],
        v[3] < spec.minSize.height ? spec.minSize.height : v[3],
      );
    }
    return viewport != null && spec.initialRectFor != null
        ? spec.initialRectFor!(viewport)
        : spec.initialRect;
  }

  /// Opens [spec] (or brings it to the front if it is open).
  void show(FloatingWindowSpec spec) {
    _open.removeWhere((w) => w.id == spec.id);
    _open.add(spec);
    notifyListeners();
  }

  /// Updates an open window's spec (e.g. a new title) without moving it
  /// in front of the others.
  void replace(FloatingWindowSpec spec) {
    final i = _open.indexWhere((w) => w.id == spec.id);
    if (i < 0) return;
    _open[i] = spec;
    notifyListeners();
  }

  /// Compact picture-in-picture size: on, the window shrinks to a small
  /// corner window; off, it goes back to where it was.
  bool isCompact(String id) => _saved['$id.compact'] is List;

  void toggleCompact(String id, Rect current, Size area) {
    final saved = _saved;
    final before = saved['$id.compact'];
    if (before is List && before.length == 4) {
      final v = [for (final n in before) (n as num).toDouble()];
      saved[id] = v;
      saved.remove('$id.compact');
    } else {
      saved['$id.compact'] = [
        current.left,
        current.top,
        current.width,
        current.height,
      ];
      const w = 300.0, h = 220.0;
      saved[id] = [area.width - w - 16, area.height - h - 16, w, h];
    }
    unawaited(_settings.set(_key, saved));
    notifyListeners();
  }

  void close(String id) {
    final before = _open.length;
    _open.removeWhere((w) => w.id == id);
    if (_open.length != before) notifyListeners();
  }

  void toFront(String id) {
    final i = _open.indexWhere((w) => w.id == id);
    if (i < 0 || i == _open.length - 1) return;
    _open.add(_open.removeAt(i));
    notifyListeners();
  }

  /// Remembers a window's place (after a drag or resize).
  void place(String id, Rect rect) {
    final saved = _saved..[id] = [rect.left, rect.top, rect.width, rect.height];
    unawaited(_settings.set(_key, saved));
    notifyListeners();
  }

  /// [rect] moved and shrunk as needed to fit inside [area].
  static Rect fit(Rect rect, Size area, Size minSize) {
    final w = rect.width.clamp(
      minSize.width,
      area.width < minSize.width ? minSize.width : area.width,
    );
    final h = rect.height.clamp(
      minSize.height,
      area.height < minSize.height ? minSize.height : area.height,
    );
    final left = rect.left.clamp(
      0.0,
      (area.width - w).clamp(0.0, double.infinity),
    );
    final top = rect.top.clamp(
      0.0,
      (area.height - h).clamp(0.0, double.infinity),
    );
    return Rect.fromLTWH(left, top, w, h);
  }
}

/// Global rectangles of the open floating windows (kept by FloatingLayer),
/// so a native view (Safari on Windows) can step aside when one covers it.
final ValueNotifier<Map<String, Rect>> floatingWindowRects = ValueNotifier({});
