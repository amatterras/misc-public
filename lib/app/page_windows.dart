// Page instances: the pages the user added to the top bar (a destination,
// a particular note or mindmap, a Safari window, an AI conversation…).
// Each instance has a stable id and its own live page widget, and is
// shown in exactly one place at a time:
//   - docked: in the main area when it is the active one;
//   - floating: in a draggable, resizable window (FloatingWindows);
//   - minimized: kept alive off screen (no painting, no animations).
// Moving between places keeps the page's state (one GlobalKey per
// instance). The list, modes and pins are saved per device.
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models/canvas_models.dart' show newId;
import '../data/repositories/canvas_repository.dart' show SettingsRepository;
import 'app_state.dart';
import 'floating_windows.dart';

enum PageMode { docked, floating, minimized }

class PageInstance {
  PageInstance({
    required this.id,
    required this.kind,
    this.refId,
    this.title = '',
    this.mode = PageMode.docked,
    this.pinned = false,
  });

  final String id;
  final AppPage kind;

  /// What the instance shows (null: the destination itself):
  ///   canvas / notes: the mindmap or note id (a shared record: one
  ///     instance per record, so there is never a second controller);
  ///   ai: the conversation id, or `new-…` until its first message;
  ///   browser: its own tab set;
  ///   calendar / links: `view-…` (an independent view of the same
  ///     records), `folder:<id>` or `res:<id>` (Archive).
  /// Changes only when a new AI chat gets its conversation ([rebind]).
  String? refId;
  String title;

  /// The user renamed the tab (else it follows the content's own title).
  bool named = false;
  PageMode mode;
  bool pinned;

  /// Where a minimized instance comes back to.
  PageMode before = PageMode.docked;

  /// Keeps the page's state when it moves between main area and window.
  final GlobalKey hostKey = GlobalKey();

  /// The built page, reused so switching pages does not rebuild every
  /// live page (each page listens to its own data).
  Widget? host;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'refId': ?refId,
    'title': title,
    'mode': mode.name,
    'before': before.name,
    if (pinned) 'pinned': true,
    if (named) 'named': true,
  };

  static PageInstance? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = AppPage.values.asNameMap()[raw['kind']];
    final id = raw['id'];
    if (kind == null || id is! String) return null;
    return PageInstance(
        id: id,
        kind: kind,
        refId: raw['refId'] is String ? raw['refId'] as String : null,
        title: raw['title'] is String ? raw['title'] as String : '',
        mode: PageMode.values.asNameMap()[raw['mode']] ?? PageMode.docked,
        pinned: raw['pinned'] == true,
      )
      ..before = PageMode.values.asNameMap()[raw['before']] ?? PageMode.docked
      ..named = raw['named'] == true;
  }
}

/// Builds the live page for an instance (supplied by the shell).
typedef PageBuilder = Widget Function(BuildContext context, PageInstance p);

class PageWindows extends ChangeNotifier {
  PageWindows(this._settings, this._floating);

  final SettingsRepository _settings;
  final FloatingWindows _floating;

  /// Most page instances kept at once (each is a real live page).
  static const maxInstances = 40;
  static const _key = 'pageInstances';

  final List<PageInstance> _all = [];
  List<PageInstance> get all => List.unmodifiable(_all);

  /// The docked instance shown in the main area, or null for the plain
  /// destination page.
  String? activeId;

  PageBuilder? builder;

  /// The tab name of an instance (set by the app: it knows the records).
  String Function(PageInstance p)? titleOf;

  /// Told when an instance is closed (to let go of its session).
  void Function(String id)? onClosed;

  /// Told when an instance becomes the one shown in the main area.
  void Function(PageInstance p)? onShow;

  void _show(PageInstance p) {
    activeId = p.id;
    onShow?.call(p);
    unawaited(_settings.set('pageActive', p.id));
  }

  /// Pages with work that would be lost on close (an unsent AI question,
  /// an unsaved form) register a check here; [close] asks it first.
  final Map<String, Future<bool> Function()> _guards = {};

  void setCloseGuard(String id, Future<bool> Function()? guard) =>
      guard == null ? _guards.remove(id) : _guards[id] = guard;

  /// Points instance [id] at a new record (a new AI chat that now has its
  /// conversation), so it reopens with it after a restart.
  void rebind(String id, String refId) {
    final p = byId(id);
    if (p == null || p.refId == refId) return;
    p.refId = refId;
    _save();
    notifyListeners();
  }

  bool get collapsed => _settings.get<bool>('topBarCollapsed') ?? false;

  Future<void> setCollapsed(bool on) async {
    await _settings.set('topBarCollapsed', on);
    notifyListeners();
  }

  PageInstance? byId(String? id) =>
      id == null ? null : _all.where((p) => p.id == id).firstOrNull;

  PageInstance? get active => byId(activeId);

  /// The instance showing [kind]/[refId], if one is open.
  PageInstance? find(AppPage kind, String? refId) =>
      _all.where((p) => p.kind == kind && p.refId == refId).firstOrNull;

  /// Restores the saved instances (floating ones float again).
  void restore() {
    if (_all.isNotEmpty) return;
    for (final raw in _settings.get<List<dynamic>>(_key) ?? const []) {
      final p = PageInstance.fromJson(raw);
      if (p != null &&
          _all.length < maxInstances &&
          find(p.kind, p.refId) == null) {
        _all.add(p);
      }
    }
    for (final p in _all.where((p) => p.mode == PageMode.floating)) {
      _floatWindow(p);
    }
    // The page that was in the main area comes back there.
    final last = byId(_settings.get<String>('pageActive'));
    if (last != null && last.mode == PageMode.docked) _show(last);
    notifyListeners();
  }

  void _save() =>
      unawaited(_settings.set(_key, [for (final p in _all) p.toJson()]));

  /// Opens (or focuses, never duplicates) the page for [kind]/[refId].
  PageInstance open(
    AppPage kind, {
    String? refId,
    String title = '',
    PageMode mode = PageMode.docked,
  }) {
    final existing = find(kind, refId);
    if (existing != null) {
      focus(existing.id);
      return existing;
    }
    if (_all.length >= maxInstances) {
      // Make room: the oldest unpinned, not-floating instance with nothing
      // unsaved goes (its content stays; only the open page closes).
      final old = _all
          .where(
            (p) =>
                !p.pinned &&
                p.mode != PageMode.floating &&
                !_guards.containsKey(p.id),
          )
          .firstOrNull;
      if (old != null) close(old.id);
    }
    final p = PageInstance(
      id: newId(),
      kind: kind,
      refId: refId,
      title: title,
      mode: mode,
    );
    _all.add(p);
    if (mode == PageMode.floating) {
      _floatWindow(p);
    } else if (mode == PageMode.docked) {
      _show(p);
    }
    _save();
    notifyListeners();
    return p;
  }

  /// Shows an instance where it lives: the main area, or its window in
  /// front. A minimized instance comes back where it was before.
  void focus(String id) {
    final p = byId(id);
    if (p == null) return;
    switch (p.mode) {
      case PageMode.floating:
        _floatWindow(p);
      case PageMode.docked:
        _show(p);
      case PageMode.minimized:
        restoreInstance(id);
        return;
    }
    notifyListeners();
  }

  /// Leaves the instance view: the main area shows the destination again.
  void showDestination() {
    if (activeId == null) return;
    activeId = null;
    notifyListeners();
  }

  void float(String id) {
    final p = byId(id);
    if (p == null) return;
    if (activeId == id) activeId = null;
    p.mode = PageMode.floating;
    _floatWindow(p);
    _save();
    notifyListeners();
  }

  void dock(String id) {
    final p = byId(id);
    if (p == null) return;
    _floating.close(id);
    p.mode = PageMode.docked;
    _show(p);
    _save();
    notifyListeners();
  }

  void minimize(String id) {
    final p = byId(id);
    if (p == null) return;
    _floating.close(id);
    if (activeId == id) activeId = null;
    if (p.mode != PageMode.minimized) p.before = p.mode;
    p.mode = PageMode.minimized;
    _save();
    notifyListeners();
  }

  /// A minimized instance: floating again if it was floating last, else
  /// docked in the main area.
  void restoreInstance(String id) {
    final p = byId(id);
    if (p == null) return;
    p.before == PageMode.floating ? float(id) : dock(id);
  }

  void togglePin(String id) {
    final p = byId(id);
    if (p == null) return;
    p.pinned = !p.pinned;
    // Pinned instances come first.
    _all
      ..remove(p)
      ..insert(p.pinned ? 0 : _all.where((x) => x.pinned).length, p);
    _save();
    notifyListeners();
  }

  /// Closes an instance. Its page saves on its own as it goes away (notes
  /// and mindmaps flush when their page is disposed); [beforeClose] may
  /// refuse (e.g. an unsent AI question the user wants to keep).
  Future<void> close(String id, {Future<bool> Function()? beforeClose}) async {
    final p = byId(id);
    if (p == null) return;
    final check = beforeClose ?? _guards[id];
    if (check != null && !await check()) return;
    _guards.remove(id);
    _floating.close(id);
    _all.remove(p);
    if (activeId == id) activeId = null;
    onClosed?.call(id);
    _save();
    notifyListeners();
  }

  void rename(String id, String title) {
    final p = byId(id);
    if (p == null || p.title == title) return;
    p.title = title;
    p.named = true;
    if (p.mode == PageMode.floating) _floating.replace(_specFor(p));
    _save();
    notifyListeners();
  }

  /// Next instance in the bar (Ctrl+Tab).
  void cycle() {
    if (_all.isEmpty) return;
    final i = _all.indexWhere((p) => p.id == activeId);
    focus(_all[(i + 1) % _all.length].id);
  }

  void _floatWindow(PageInstance p) => _floating.show(_specFor(p));

  FloatingWindowSpec _specFor(PageInstance p) => FloatingWindowSpec(
    id: p.id,
    title: p.title.isEmpty ? p.kind.name : p.title,
    liveTitle: () => titleOf?.call(p) ?? p.title,
    initialRectFor: ContentWindowGeometry.initial,
    minSize: const Size(200, 140),
    builder: (context) => instanceHost(context, p),
    onMinimize: () => minimize(p.id),
    onDock: () => dock(p.id),
    onClose: () => close(p.id),
  );

  /// The live page of [p], keyed so it keeps its state wherever it moves.
  Widget instanceHost(BuildContext context, PageInstance p) {
    final build = builder;
    if (build == null) return const SizedBox.shrink(); // not cached
    return p.host ??= KeyedSubtree(key: p.hostKey, child: build(context, p));
  }
}
