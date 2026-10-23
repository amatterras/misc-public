// Safari's tabs and records: address/search parsing, history (never for
// private tabs), bookmarks with folders, downloads, site permissions,
// external-link rules and the restored session (normal tabs only).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/browser_models.dart';
import '../../data/models/canvas_models.dart' show newId;
import '../../data/repositories/canvas_repository.dart' show SettingsRepository;
import '../../data/workspace.dart';
import 'browser_engine.dart';

/// One tab. Its engine is made when the tab is first shown.
class BrowserTab {
  BrowserTab({
    required this.id,
    this.url = '',
    this.title = '',
    this.private = false,
  });
  final String id;
  String url;
  String title;
  final bool private;
  BrowserEngine? engine;
  StreamSubscription<EngineEvent>? _events;
}

class DownloadItem {
  DownloadItem(this.id, this.url, this.fileName);
  final String id;
  final String url;
  final String fileName;
  double progress = 0;
  bool done = false;
  String? path;
  String? error;
}

/// How links to other apps (mailto:, tel:, app links) are handled.
enum ExternalLinks { ask, open, block }

/// Turns what was typed in the address bar into a URL to load: a web
/// address, or a web search. Unsafe schemes (javascript:, file:, data:)
/// are never loaded from the address bar.
Uri? addressToUrl(
  String input, {
  String searchUrl = 'https://duckduckgo.com/?q=',
}) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final lower = text.toLowerCase();
  if (lower.startsWith('javascript:') ||
      lower.startsWith('file:') ||
      lower.startsWith('data:') ||
      lower.startsWith('vbscript:')) {
    return null;
  }
  final hasScheme = RegExp(r'^[a-z][a-z0-9+.-]*://').hasMatch(lower);
  if (hasScheme) {
    final u = Uri.tryParse(text);
    return u != null &&
            (u.scheme == 'http' || u.scheme == 'https') &&
            u.host.isNotEmpty
        ? u
        : null;
  }
  final looksLikeHost =
      !text.contains(' ') &&
      (RegExp(r'^[\w-]+(\.[\w-]+)+(:\d+)?(/.*)?$').hasMatch(text) ||
          RegExp(r'^localhost(:\d+)?(/.*)?$').hasMatch(lower));
  if (looksLikeHost) return Uri.tryParse('https://$text');
  return Uri.parse('$searchUrl${Uri.encodeQueryComponent(text)}');
}

class BrowserWorkspace extends ChangeNotifier {
  BrowserWorkspace(
    this.ws,
    this.settings, {
    this.sessionKey = 'browser.session',
  });

  /// Where this browser's tabs are remembered (one per Safari window).
  final String sessionKey;

  final Workspace ws;
  final SettingsRepository settings;

  final List<BrowserTab> tabs = [];
  String? activeId;
  final List<DownloadItem> downloads = [];

  /// External-link request waiting for the user ([ExternalLinks.ask]).
  final ValueNotifier<String?> pendingExternal = ValueNotifier(null);

  /// Opens [url] in the system (mailto:, tel:…); replaceable in tests.
  bool Function(String url) openExternal = (_) => false;

  /// Asked when a site wants camera, microphone or location and there is
  /// no saved decision; replaceable by the page (a dialog).
  Future<bool> Function(String host, String kind) askPermission = (
    _,
    _,
  ) async => false;

  static const maxHistory = 5000;

  BrowserTab? get active => tabs.where((t) => t.id == activeId).firstOrNull;

  ExternalLinks get externalLinks =>
      ExternalLinks.values.asNameMap()[settings.get<String>(
        'browser.external',
      )] ??
      ExternalLinks.ask;

  Future<void> setExternalLinks(ExternalLinks v) async {
    await settings.set('browser.external', v.name);
    notifyListeners();
  }

  // ------------------------------------------------------------- tabs --

  /// Reopens the normal tabs of the last session (private ones are never
  /// saved).
  void restoreSession() {
    if (tabs.isNotEmpty) return;
    final saved = settings.get<List<dynamic>>(sessionKey) ?? const [];
    for (final s in saved) {
      if (s is Map && s['url'] is String) {
        tabs.add(
          BrowserTab(
            id: newId(),
            url: s['url'] as String,
            title: s['title'] as String? ?? '',
          ),
        );
      }
    }
    activeId = tabs.firstOrNull?.id;
    notifyListeners();
  }

  void _saveSession() => unawaited(
    settings.set(sessionKey, [
      for (final t in tabs)
        if (!t.private && t.url.isNotEmpty) {'url': t.url, 'title': t.title},
    ]),
  );

  BrowserTab newTab({
    String url = '',
    bool private = false,
    bool activate = true,
  }) {
    final t = BrowserTab(id: newId(), url: url, private: private);
    tabs.add(t);
    if (activate) activeId = t.id;
    _saveSession();
    notifyListeners();
    return t;
  }

  void duplicate(String id) {
    final t = tabs.where((x) => x.id == id).firstOrNull;
    if (t != null) newTab(url: t.url, private: t.private);
  }

  void activate(String id) {
    activeId = id;
    notifyListeners();
  }

  void closeTab(String id) {
    final i = tabs.indexWhere((t) => t.id == id);
    if (i < 0) return;
    final t = tabs.removeAt(i);
    _release(t);
    if (activeId == id) {
      activeId = tabs.isEmpty ? null : tabs[i.clamp(0, tabs.length - 1)].id;
    }
    _saveSession();
    notifyListeners();
  }

  void _release(BrowserTab t) {
    t._events?.cancel();
    t.engine?.dispose();
    t.engine = null;
  }

  /// The tab's engine, made on first use; null when none runs here.
  BrowserEngine? engineFor(BrowserTab t) {
    if (t.engine != null) return t.engine;
    final e = BrowserEngine.create(private: t.private);
    if (e == null) return null;
    t.engine = e;
    e.state.addListener(() => _onState(t, e.state.value));
    t._events = e.events.listen((ev) => _onEvent(t, ev));
    // Not during the build that asked for the engine.
    if (t.url.isNotEmpty) scheduleMicrotask(() => unawaited(e.load(t.url)));
    return e;
  }

  void _onState(BrowserTab t, EngineState s) {
    final changedUrl = s.url.isNotEmpty && s.url != t.url;
    if (s.url.isNotEmpty) t.url = s.url;
    if (s.title.isNotEmpty) t.title = s.title;
    if (changedUrl || (!s.loading && s.error == null)) {
      if (!s.loading) recordVisit(t, s.url, s.title);
      _saveSession();
    }
    notifyListeners();
  }

  void _onEvent(BrowserTab t, EngineEvent ev) {
    switch (ev) {
      case NewWindowRequested(:final url):
        // Pop-ups open as a new tab (same privacy as their opener).
        if (addressToUrl(url) != null) newTab(url: url, private: t.private);
      case ExternalLinkRequested(:final url):
        externalLink(url);
      case DownloadEvent():
        onDownload(ev);
      case PermissionRequested(:final host, :final kind, :final respond):
        final saved = ws.sitePermissions['$host|$kind'];
        if (saved != null) {
          respond(saved.allowed);
        } else {
          askPermission(host, kind).then((allow) {
            setPermission(host, kind, allow);
            respond(allow);
          });
        }
    }
  }

  /// Navigates the active tab (or a new one) to what was typed.
  /// Returns false when it cannot be loaded (unsafe or empty).
  Future<bool> go(String input) async {
    final url = addressToUrl(input);
    if (url == null) return false;
    final t = active ?? newTab();
    t.url = url.toString();
    final e = engineFor(t);
    if (e != null) await e.load(t.url);
    _saveSession();
    notifyListeners();
    return true;
  }

  /// A link the browser does not open itself, handled by the user's rule.
  void externalLink(String url) {
    switch (externalLinks) {
      case ExternalLinks.open:
        openExternal(url);
      case ExternalLinks.block:
        break;
      case ExternalLinks.ask:
        pendingExternal.value = url;
    }
  }

  // ---------------------------------------------------------- history --

  void recordVisit(BrowserTab t, String url, String title) {
    if (t.private || url.isEmpty || url == 'about:blank') return;
    final last = ws.history.all.isEmpty
        ? null
        : ws.history.all.reduce(
            (a, b) => a.visitedAt.isAfter(b.visitedAt) ? a : b,
          );
    if (last != null && last.url == url) {
      if (title.isNotEmpty && last.title != title) {
        ws.history.put(
          HistoryEntry(
            id: last.id,
            url: url,
            title: title,
            visitedAt: last.visitedAt,
          ),
        );
      }
      return;
    }
    ws.history.put(
      HistoryEntry(
        id: newId(),
        url: url,
        title: title,
        visitedAt: DateTime.now(),
      ),
    );
    if (ws.history.length > maxHistory) {
      final old = ws.history.all.toList()
        ..sort((a, b) => a.visitedAt.compareTo(b.visitedAt));
      for (final h in old.take(ws.history.length - maxHistory)) {
        ws.history.remove(h.id);
      }
    }
  }

  List<HistoryEntry> searchHistory(String q) {
    final s = q.trim().toLowerCase();
    return [
      for (final h in ws.history.all)
        if (s.isEmpty ||
            h.url.toLowerCase().contains(s) ||
            h.title.toLowerCase().contains(s))
          h,
    ]..sort((a, b) => b.visitedAt.compareTo(a.visitedAt));
  }

  void clearHistory({DateTime? since}) {
    for (final h in ws.history.all.toList()) {
      if (since == null || h.visitedAt.isAfter(since)) ws.history.remove(h.id);
    }
  }

  /// Clears cookies, cache and site data of every open tab's engine.
  Future<void> clearBrowsingData() async {
    for (final t in tabs) {
      await t.engine?.clearData();
    }
  }

  // -------------------------------------------------------- bookmarks --

  Bookmark addBookmark(String url, String title, {String folder = ''}) {
    final existing = ws.bookmarks.all.where((b) => b.url == url).firstOrNull;
    if (existing != null) return existing;
    final b = Bookmark(
      id: newId(),
      title: title.isEmpty ? url : title,
      url: url,
      folder: folder,
      updatedAt: DateTime.now(),
    );
    ws.bookmarks.put(b);
    return b;
  }

  bool isBookmarked(String url) => ws.bookmarks.all.any((b) => b.url == url);

  List<String> get bookmarkFolders => {
    for (final b in ws.bookmarks.all)
      if (b.folder.isNotEmpty) b.folder,
  }.toList()..sort();

  /// Renames a folder (and its sub-folders) for every bookmark in it.
  void renameFolder(String from, String to) {
    for (final b in ws.bookmarks.all.toList()) {
      if (b.folder == from || b.folder.startsWith('$from/')) {
        ws.bookmarks.put(
          b.copyWith(folder: to + b.folder.substring(from.length)),
        );
      }
    }
  }

  // -------------------------------------------------------- downloads --

  void onDownload(DownloadEvent e) {
    var d = downloads.where((x) => x.id == e.id).firstOrNull;
    if (d == null) {
      d = DownloadItem(e.id, e.url, e.fileName);
      downloads.insert(0, d);
    }
    d
      ..progress = e.progress
      ..done = e.done
      ..path = e.path ?? d.path
      ..error = e.error;
    notifyListeners();
  }

  // ------------------------------------------------------ permissions --

  void setPermission(String host, String kind, bool allowed) =>
      ws.sitePermissions.put(
        SitePermission(
          id: '$host|$kind',
          host: host,
          kind: kind,
          allowed: allowed,
          updatedAt: DateTime.now(),
        ),
      );

  @override
  void dispose() {
    for (final t in tabs) {
      _release(t);
    }
    pendingExternal.dispose();
    super.dispose();
  }
}
