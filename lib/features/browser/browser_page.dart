// The Safari destination: tabs, address/search bar, navigation, bookmarks,
// history, downloads, site permissions, private tabs, and sending a page
// (or the selected text) to the Library, Notes, a mindmap or AI — only when the
// user asks. The page itself runs in the platform's engine (see
// browser_engine.dart); where none exists the page says so.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/page_windows.dart' show PageMode;
import '../../app/theme.dart';
import '../../data/models/browser_models.dart';
import '../../data/models/object_library_models.dart';
import '../../platform/input_hints.dart';
import '../../platform/platform.dart' as native;
import '../../widgets/common.dart';
import '../ai/ai_service.dart';
import '../ai/ai_session.dart';
import '../transfer/transfer.dart';
import 'browser_engine.dart';
import 'browser_workspace.dart';

class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    required this.state,
    this.browser,
    this.instanceId,
  });

  final AppState state;

  /// This window's tabs (default: the main Safari).
  final BrowserWorkspace? browser;

  /// Page instance used by the floating window. The stand-alone Safari page
  /// passes no id, so browser chrome can never be hidden there.
  final String? instanceId;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  double _zoom = 1;
  bool _compactChrome = false;

  AppState get s => widget.state;
  BrowserWorkspace get b => widget.browser ?? s.browser;
  bool get _isFloating =>
      widget.instanceId != null &&
      s.windows.byId(widget.instanceId)?.mode == PageMode.floating;

  String? get _compactSetting =>
      widget.instanceId == null ? null : 'browserCompact.${widget.instanceId}';

  @override
  void initState() {
    super.initState();
    final savedCompact = _compactSetting;
    _compactChrome =
        savedCompact != null && (s.settings.get<bool>(savedCompact) ?? false);
    b.restoreSession();
    b.openExternal = native.openUrl;
    b.askPermission = _askPermission;
    b.pendingExternal.addListener(_onExternal);
  }

  @override
  void dispose() {
    b.pendingExternal.removeListener(_onExternal);
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  Future<bool> _askPermission(String host, String kind) async {
    if (!mounted) return false;
    return await confirm(
      context,
      title: 'Allow $host to use the $kind?',
      message:
          'Your choice is remembered for this site (Safari menu → '
          'Site permissions to change it).',
    );
  }

  Future<void> _onExternal() async {
    final url = b.pendingExternal.value;
    if (url == null || !mounted) return;
    b.pendingExternal.value = null;
    final ok = await confirm(
      context,
      title: 'Open in another app?',
      message: 'The page wants to open: $url',
    );
    if (ok) b.openExternal(url);
  }

  Future<void> _go(String text) async {
    if (!await b.go(text)) {
      s.showToast('That address cannot be opened here.');
    }
  }

  void _toggleCompactChrome() {
    if (!_isFloating) return;
    final setting = _compactSetting;
    if (setting == null) return;
    final compact = !_compactChrome;
    setState(() => _compactChrome = compact);
    unawaited(s.settings.set(setting, compact));
  }

  // ----------------------------------------------------- send to THEapp --

  /// Sends the page (and the selected text, if any) where the user chose.
  /// Nothing leaves the page unless the user picks a place.
  Future<void> _send(String where) async {
    final t = b.active;
    if (t == null || t.url.isEmpty) return;
    final engine = t.engine;
    final selected = engine == null ? '' : await engine.selectedText();
    final ws = s.workspace;
    switch (where) {
      case 'library':
        var pageText = selected;
        if (engine != null) {
          try {
            pageText = await engine.pageText();
          } catch (_) {}
        }
        if (pageText.length > 200000) pageText = pageText.substring(0, 200000);
        await s.library.save(
          type: LibraryObjectType.article,
          sourceUrl: t.url,
          title: t.title.isEmpty ? t.url : t.title,
          content: pageText.isEmpty ? null : pageText,
          metadata: {'browserCapture': true},
        );
        s.showToast('Saved to Library.');
      case 'note':
        final a = ws.linkAsset(t.url, title: t.title.isEmpty ? null : t.title);
        final n = ws.createNote(
          title: t.title.isEmpty ? t.url : t.title,
          body: selected.isEmpty ? '' : '> ${selected.trim()}',
          assetIds: [a.id],
        );
        s.showToast('Saved as note “${n.displayTitle}”.');
      case 'mindmap':
        final c = s.canvas;
        if (c == null) return;
        final a = ws.linkAsset(t.url, title: t.title.isEmpty ? null : t.title);
        c.insertLink(a, s.canvasDropPoint(c));
        s.showToast('Placed on “${c.title}”.');
      case 'ai' || 'aiText':
        if (!mounted) return;
        if (t.private &&
            !await confirm(
              context,
              title: 'Send from a private tab?',
              message:
                  'Only what is shown in the AI window is sent, and only '
                  'after you press Send there.',
            )) {
          return;
        }
        var text = selected;
        if (where == 'aiText' && engine != null) {
          final page = await engine.pageText();
          text = page.length > 20000 ? page.substring(0, 20000) : page;
        }
        s.sendToAi(
          AiContext(
            title: t.title.isEmpty ? t.url : t.title,
            source: AiSource.archive,
            text: 'Web page: ${t.url}\n$text',
          ),
        );
    }
  }

  // ---------------------------------------------------------- dialogs --

  Future<void> _bookmarks() => showDialog<void>(
    context: context,
    builder: (context) => _BookmarksDialog(state: s, browser: b),
  );

  Future<void> _history() => showDialog<void>(
    context: context,
    builder: (context) => _HistoryDialog(state: s, browser: b),
  );

  Future<void> _downloads() => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: b,
      builder: (context, _) => AlertDialog(
        title: const Text('Downloads', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 440,
          child: b.downloads.isEmpty
              ? const Text('No downloads in this session.')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final d in b.downloads)
                      ListTile(
                        dense: true,
                        title: Text(d.fileName),
                        subtitle: Text(
                          d.error ??
                              (d.done
                                  ? 'Saved: ${d.path ?? ''}'
                                  : '${(d.progress * 100).round()}%'),
                          style: TextStyle(
                            fontSize: 11,
                            color: d.error != null ? AppColors.warm : null,
                          ),
                        ),
                        trailing: d.done && d.path != null
                            ? TextButton(
                                onPressed: () => s.openDocument(d.path!),
                                child: const Text('Open'),
                              )
                            : null,
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );

  Future<void> _privacy() => showDialog<void>(
    context: context,
    builder: (context) => _PrivacyDialog(state: s, browser: b),
  );

  // ----------------------------------------------------------- build --

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([b, s.windows]),
    builder: (context, _) {
      final t = b.active;
      final compact = _isFloating && _compactChrome;
      final engine = t == null ? null : b.engineFor(t);
      if (!_addressFocus.hasFocus) _address.text = t?.url ?? '';
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyT, control: true): () =>
              b.newTab(),
          const SingleActivator(
            LogicalKeyboardKey.keyT,
            control: true,
            shift: true,
          ): () =>
              b.newTab(private: true),
          const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
            if (t != null) b.closeTab(t.id);
          },
          const SingleActivator(LogicalKeyboardKey.keyL, control: true): () =>
              _addressFocus.requestFocus(),
          const SingleActivator(LogicalKeyboardKey.keyR, control: true): () =>
              engine?.reload(),
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
              engine?.find(),
          const SingleActivator(LogicalKeyboardKey.keyD, control: true): () {
            if (t != null && t.url.isNotEmpty) b.addBookmark(t.url, t.title);
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
              engine?.back(),
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () =>
              engine?.forward(),
        },
        child: Focus(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!compact) _tabStrip(t),
              if (!compact) _toolbar(t, engine),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _body(t, engine),
                    if (compact)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Material(
                          color: AppColors.card.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(8),
                          child: GhostIconButton(
                            key: const ValueKey('browser-restore-chrome'),
                            icon: Icons.expand_more,
                            tooltip: 'Show browser controls',
                            onTap: _toggleCompactChrome,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _tabStrip(BrowserTab? active) => Container(
    height: 36,
    color: AppColors.sidebar,
    child: Row(
      children: [
        Expanded(
          child: ListView(
            key: const ValueKey('browser-tabs'),
            scrollDirection: Axis.horizontal,
            children: [
              for (final tab in b.tabs)
                InkWell(
                  key: ValueKey('browser-tab-${tab.id}'),
                  onTap: () => b.activate(tab.id),
                  child: Container(
                    width: 180,
                    padding: const EdgeInsets.only(left: 10),
                    decoration: BoxDecoration(
                      color: tab.id == active?.id ? AppColors.card : null,
                      border: Border(
                        right: BorderSide(color: AppColors.border),
                      ),
                    ),
                    child: Row(
                      children: [
                        if (tab.private)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.visibility_off_outlined,
                              size: 13,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            tab.title.isNotEmpty
                                ? tab.title
                                : tab.url.isNotEmpty
                                ? tab.url
                                : 'New tab',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        GhostIconButton(
                          icon: Icons.close,
                          tooltip: 'Close tab',
                          size: 13,
                          onTap: () => b.closeTab(tab.id),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        GhostIconButton(
          key: const ValueKey('browser-new-tab'),
          icon: Icons.add,
          tooltip: 'New tab  (Ctrl+T)',
          onTap: () => b.newTab(),
        ),
        GhostIconButton(
          icon: Icons.visibility_off_outlined,
          tooltip: 'New private tab  (Ctrl+Shift+T)',
          onTap: () => b.newTab(private: true),
        ),
      ],
    ),
  );

  Widget _toolbar(BrowserTab? t, BrowserEngine? engine) {
    final st = engine?.state.value;
    final bookmarked = t != null && b.isBookmarked(t.url);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          GhostIconButton(
            icon: Icons.arrow_back,
            tooltip: 'Back  (Alt+←)',
            onTap: st?.canGoBack ?? false ? engine!.back : null,
          ),
          GhostIconButton(
            icon: Icons.arrow_forward,
            tooltip: 'Forward  (Alt+→)',
            onTap: st?.canGoForward ?? false ? engine!.forward : null,
          ),
          GhostIconButton(
            icon: st?.loading ?? false ? Icons.close : Icons.refresh,
            tooltip: st?.loading ?? false ? 'Stop' : 'Reload  (Ctrl+R)',
            onTap: engine == null
                ? null
                : (st?.loading ?? false ? engine.stop : engine.reload),
          ),
          // Drag the page (its address) to a note, a mindmap, a day, the
          // Archive or the task list. Only what is dragged is captured.
          if (t != null && t.url.isNotEmpty)
            TransferSource(
              transfer: () => UrlTransfer(t.url, title: t.title),
              touch: touchFirst,
              feedback: Text(t.title.isEmpty ? t.url : t.title),
              child: Tooltip(
                message: 'Drag this page somewhere in misc.',
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(
                    Icons.drag_indicator,
                    key: ValueKey('browser-drag-page'),
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ),
          Expanded(
            child: TextField(
              key: const ValueKey('browser-address'),
              controller: _address,
              focusNode: _addressFocus,
              style: const TextStyle(fontSize: 13),
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: Icon(
                  t?.private ?? false
                      ? Icons.visibility_off_outlined
                      : Icons.search,
                  size: 16,
                ),
                hintText: 'Search or enter an address',
              ),
              onSubmitted: _go,
            ),
          ),
          GhostIconButton(
            key: const ValueKey('browser-bookmark'),
            icon: bookmarked ? Icons.star : Icons.star_border,
            tooltip: bookmarked ? 'Bookmarked' : 'Bookmark  (Ctrl+D)',
            onTap: t == null || t.url.isEmpty
                ? null
                : () => b.addBookmark(t.url, t.title),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('browser-menu'),
            tooltip: 'Safari menu',
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (v) async {
              switch (v) {
                case 'dup':
                  if (t != null) b.duplicate(t.id);
                case 'find':
                  await engine?.find();
                case 'zoomIn' || 'zoomOut' || 'zoom100':
                  _zoom = v == 'zoom100'
                      ? 1
                      : (_zoom * (v == 'zoomIn' ? 1.1 : 1 / 1.1)).clamp(
                          0.5,
                          3.0,
                        );
                  await engine?.setZoom(_zoom);
                case 'bookmarks':
                  await _bookmarks();
                case 'history':
                  await _history();
                case 'downloads':
                  await _downloads();
                case 'privacy':
                  await _privacy();
                case 'external':
                  if (t != null && t.url.isNotEmpty) native.openUrl(t.url);
                case 'copy':
                  if (t != null) {
                    await Clipboard.setData(ClipboardData(text: t.url));
                  }
                default:
                  await _send(v);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'dup', child: Text('Duplicate tab')),
              const PopupMenuItem(
                value: 'find',
                child: Text('Find on page  (Ctrl+F)'),
              ),
              const PopupMenuItem(value: 'zoomIn', child: Text('Zoom in')),
              const PopupMenuItem(value: 'zoomOut', child: Text('Zoom out')),
              const PopupMenuItem(value: 'zoom100', child: Text('Actual size')),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'bookmarks',
                child: Text('Bookmarks…'),
              ),
              const PopupMenuItem(value: 'history', child: Text('History…')),
              const PopupMenuItem(
                value: 'downloads',
                child: Text('Downloads…'),
              ),
              const PopupMenuItem(
                value: 'privacy',
                child: Text('Privacy and site data…'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'library',
                child: Text('Save page to Library'),
              ),
              const PopupMenuItem(
                value: 'note',
                child: Text('Save page (and selection) as a note'),
              ),
              const PopupMenuItem(
                value: 'mindmap',
                child: Text('Place page on the mindmap'),
              ),
              const PopupMenuItem(
                value: 'ai',
                child: Text('Ask AI about the selection…'),
              ),
              const PopupMenuItem(
                value: 'aiText',
                child: Text('Ask AI about the whole page…'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'copy', child: Text('Copy address')),
              const PopupMenuItem(
                value: 'external',
                child: Text('Open in default browser'),
              ),
            ],
          ),
          if (_isFloating)
            GhostIconButton(
              key: const ValueKey('browser-compact-chrome'),
              icon: Icons.open_in_full,
              tooltip: 'Hide browser controls',
              onTap: _toggleCompactChrome,
            ),
        ],
      ),
    );
  }

  Widget _body(BrowserTab? t, BrowserEngine? engine) {
    if (t == null) {
      return Center(
        child: FilledButton.icon(
          onPressed: () => b.newTab(),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('New tab'),
        ),
      );
    }
    if (engine == null) {
      return Center(
        key: const ValueKey('browser-no-engine'),
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.explore_off_outlined,
                size: 36,
                color: AppColors.textFaint,
              ),
              const SizedBox(height: Space.md),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Text(
                  BrowserEngine.unavailableReason,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMuted),
                ),
              ),
              if (t.url.isNotEmpty) ...[
                const SizedBox(height: Space.md),
                OutlinedButton(
                  onPressed: () => native.openUrl(t.url),
                  child: const Text('Open this page in the default browser'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return ValueListenableBuilder<EngineState>(
      valueListenable: engine.state,
      builder: (context, st, _) => Stack(
        fit: StackFit.expand,
        children: [
          // Keyed per tab, so each tab keeps its own page.
          KeyedSubtree(key: ValueKey('engine-${t.id}'), child: engine.view()),
          if (st.loading)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: st.progress > 0 ? st.progress : null,
                minHeight: 2,
              ),
            ),
          if (st.error != null)
            Container(
              color: AppColors.background,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(Space.xl),
              child: Text(
                st.error!,
                key: const ValueKey('browser-error'),
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.warm),
              ),
            ),
        ],
      ),
    );
  }
}

class _BookmarksDialog extends StatefulWidget {
  const _BookmarksDialog({required this.state, required this.browser});
  final AppState state;
  final BrowserWorkspace browser;
  @override
  State<_BookmarksDialog> createState() => _BookmarksDialogState();
}

class _BookmarksDialogState extends State<_BookmarksDialog> {
  @override
  Widget build(BuildContext context) {
    final s = widget.state, ws = s.workspace;
    return ListenableBuilder(
      listenable: ws.bookmarks,
      builder: (context, _) {
        final list = ws.bookmarks.all.toList()
          ..sort(
            (a, b) => '${a.folder}/${a.title}'.toLowerCase().compareTo(
              '${b.folder}/${b.title}'.toLowerCase(),
            ),
          );
        return AlertDialog(
          title: const Text('Bookmarks', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 520,
            height: 420,
            child: list.isEmpty
                ? const Center(
                    child: Text('No bookmarks yet (the ☆ in the address bar).'),
                  )
                : ListView(
                    children: [
                      for (final bm in list)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.star, size: 16),
                          title: Text(
                            bm.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              if (bm.folder.isNotEmpty) bm.folder,
                              bm.url,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            widget.browser.go(bm.url);
                          },
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) async {
                              switch (v) {
                                case 'rename':
                                  final t = await promptText(
                                    context,
                                    title: 'Name',
                                    initial: bm.title,
                                  );
                                  if (t != null) {
                                    ws.bookmarks.put(bm.copyWith(title: t));
                                  }
                                case 'folder':
                                  final f = await promptText(
                                    context,
                                    title: 'Folder (e.g. Study/Biology; empty = top)',
                                    initial: bm.folder,
                                  );
                                  ws.bookmarks.put(
                                    bm.copyWith(folder: f ?? ''),
                                  );
                                case 'delete':
                                  ws.bookmarks.remove(bm.id);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('Rename'),
                              ),
                              PopupMenuItem(
                                value: 'folder',
                                child: Text('Move to folder…'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog({required this.state, required this.browser});
  final AppState state;
  final BrowserWorkspace browser;
  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListenableBuilder(
      listenable: s.workspace.history,
      builder: (context, _) {
        final list = widget.browser.searchHistory(_q).take(300).toList();
        return AlertDialog(
          title: const Text('History', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 520,
            height: 440,
            child: Column(
              children: [
                TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 16),
                    hintText: 'Search history',
                  ),
                  onChanged: (v) => setState(() => _q = v),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final HistoryEntry h in list)
                        ListTile(
                          dense: true,
                          title: Text(
                            h.title.isEmpty ? h.url : h.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${formatShortDate(h.visitedAt)} · ${h.url}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            widget.browser.go(h.url);
                          },
                          trailing: GhostIconButton(
                            icon: Icons.close,
                            tooltip: 'Remove from history',
                            size: 14,
                            onTap: () => s.workspace.history.remove(h.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('history-clear'),
              onPressed: () async {
                final ok = await confirm(
                  context,
                  title: 'Clear all history?',
                  message: 'Bookmarks are kept.',
                );
                if (ok) widget.browser.clearHistory();
              },
              child: const Text('Clear history'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

class _PrivacyDialog extends StatelessWidget {
  const _PrivacyDialog({required this.state, required this.browser});
  final AppState state;
  final BrowserWorkspace browser;

  @override
  Widget build(BuildContext context) {
    final b = browser, ws = state.workspace;
    return ListenableBuilder(
      listenable: Listenable.merge([b, ws.sitePermissions]),
      builder: (context, _) => AlertDialog(
        title: const Text(
          'Privacy and site data',
          style: TextStyle(fontSize: 16),
        ),
        content: SizedBox(
          width: 500,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(
                'Private tabs keep no history here and use a separate, '
                'temporary data store in the engine (iPhone/iPad WebKit). '
                'They do not make you anonymous to websites or networks.',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
              const SizedBox(height: Space.md),
              Row(
                children: [
                  const Expanded(child: Text('Links to other apps')),
                  DropdownButton<ExternalLinks>(
                    value: b.externalLinks,
                    items: const [
                      DropdownMenuItem(
                        value: ExternalLinks.ask,
                        child: Text('Ask'),
                      ),
                      DropdownMenuItem(
                        value: ExternalLinks.open,
                        child: Text('Open'),
                      ),
                      DropdownMenuItem(
                        value: ExternalLinks.block,
                        child: Text('Block'),
                      ),
                    ],
                    onChanged: (v) =>
                        b.setExternalLinks(v ?? ExternalLinks.ask),
                  ),
                ],
              ),
              const SizedBox(height: Space.sm),
              const Text(
                'Site permissions',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              if (ws.sitePermissions.length == 0)
                const Text('None saved.', style: TextStyle(fontSize: 12)),
              for (final p in ws.sitePermissions.all)
                ListTile(
                  dense: true,
                  title: Text('${p.host} · ${p.kind}'),
                  subtitle: Text(p.allowed ? 'Allowed' : 'Blocked'),
                  trailing: TextButton(
                    onPressed: () => ws.sitePermissions.remove(p.id),
                    child: const Text('Forget'),
                  ),
                ),
              const SizedBox(height: Space.md),
              OutlinedButton(
                onPressed: () async {
                  final ok = await confirm(
                    context,
                    title: 'Clear cookies, cache and site data?',
                    message: 'You will be signed out of websites. History and bookmarks are kept.',
                  );
                  if (ok) {
                    await b.clearBrowsingData();
                    state.showToast('Site data cleared.');
                  }
                },
                child: const Text('Clear cookies and site data'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
