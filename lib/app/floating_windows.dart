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
    this.minSize = const Size(220, 140),
    this.onMinimize,
    this.onDock,
    this.onClose,
  });

  /// Window buttons for pages (minimize, put back in the main area,
  /// close). Without [onClose] the close button just hides the window.
  final VoidCallback? onMinimize;
  final VoidCallback? onDock;
  final VoidCallback? onClose;

  final String id;
  final String title;
  final WidgetBuilder builder;
  final Rect initialRect;
  final Size minSize;
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
  Rect rectOf(FloatingWindowSpec spec) {
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
    return spec.initialRect;
  }

  /// Opens [spec] (or brings it to the front if it is open).
  void show(FloatingWindowSpec spec) {
    _open.removeWhere((w) => w.id == spec.id);
    _open.add(spec);
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
