// Search everything: one field over the one index (lib/search). Results
// update as the user types (after a very short pause, so typing never waits
// on a search), are grouped by section, show where each match is with the
// matching words highlighted, and open the exact item or place. Handwriting
// is never searched: the index is made from typed text only.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../search/search_index.dart' show matchRanges;
import 'ranked_search.dart';

export 'ranked_search.dart'
    show SearchFilter, SearchResult, searchEverything, searchRanked;

Future<void> showSearchDialog(BuildContext context, AppState state) {
  return showAppDialog<void>(
    context: context,
    builder: (_) => _SearchDialog(state: state, rootContext: context),
  );
}

/// Pause after the last key before a search runs.
const searchPause = Duration(milliseconds: 120);

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.state, this.rootContext});

  final AppState state;

  /// Where opened results may push pages (the window the search came from).
  final BuildContext? rootContext;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

/// What PDF text search covers right now.
String _pdfLine(AppState s) {
  final p = s.pdfTexts;
  if (p.running) return 'Reading PDF text… ${p.done} of ${p.total}';
  return 'Typed text is searched on this device. Handwriting is not '
      'searched. Nothing is sent anywhere.';
}

class _SearchDialogState extends State<_SearchDialog> {
  final _controller = TextEditingController();
  Timer? _pause;
  String _query = '';
  SearchFilter _filter = SearchFilter.all;

  /// A search is waiting for the typing pause or is running.
  bool _loading = false;
  Object? _error;
  List<SearchResult> _results = const [];

  /// Results of a search by meaning (local AI), until the text changes.
  List<SearchResult>? _meaning;
  bool _searchingMeaning = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.state.pdfTexts.indexAll());
    // The last search is kept until it is cleared (also across openings).
    _query = widget.state.searchQuery.value;
    _controller.text = _query;
    if (_query.trim().isNotEmpty) {
      _loading = true;
      _pause = Timer(searchPause, _run);
    }
    // Text that changes while the dialog is open (a PDF finishing, a note
    // saved by sync) updates the results too.
    widget.state.pdfTexts.addListener(_refreshSoon);
  }

  @override
  void dispose() {
    widget.state.pdfTexts.removeListener(_refreshSoon);
    _pause?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _refreshSoon() {
    if (_query.trim().isNotEmpty) _schedule();
  }

  void _typed(String value) {
    _query = value;
    widget.state.searchQuery.value = value;
    _meaning = null;
    _schedule();
    setState(() {});
  }

  void _schedule() {
    _pause?.cancel();
    if (_query.trim().isEmpty) {
      setState(() {
        _loading = false;
        _error = null;
        _results = const [];
      });
      return;
    }
    setState(() => _loading = true);
    _pause = Timer(searchPause, _run);
  }

  Future<void> _run() async {
    // One frame first, so "Searching…" shows before the first (possibly
    // larger) index build.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final query = _query;
    try {
      final found = searchRanked(
        widget.state,
        query,
        filter: _filter,
        context: widget.rootContext,
      );
      if (!mounted || query != _query) return;
      setState(() {
        _results = found;
        _error = null;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// Starts again from a clean index (after an error).
  void _retry() {
    try {
      widget.state.search.rebuild();
    } on Object catch (error) {
      setState(() => _error = error);
      return;
    }
    _schedule();
  }

  void _clear() {
    _controller.clear();
    _typed('');
  }

  Future<void> _byMeaning() async {
    final s = widget.state;
    setState(() => _searchingMeaning = true);
    try {
      final found = await s.searchByMeaning(_query);
      _meaning = [
        for (final (note, score) in found)
          SearchResult(
            icon: Icons.auto_awesome_outlined,
            kind: 'By meaning ${(score * 100).round()}%',
            title: note.displayTitle,
            subtitle: note.body.split('\n').first,
            section: 'By meaning',
            location: 'Notes',
            open: () => s.openNote(note.id),
          ),
      ];
    } catch (_) {
      s.showToast('The local AI could not search (is Ollama running?).');
    }
    if (mounted) setState(() => _searchingMeaning = false);
  }

  void _open(SearchResult r) {
    Navigator.pop(context);
    r.open();
  }

  /// Section headers and results in one list. Sections appear in the order
  /// of their best result; inside a section the ranking is kept.
  List<Object> _rows(List<SearchResult> results) {
    final order = <String>[];
    final bySection = <String, List<SearchResult>>{};
    for (final r in results) {
      final key = r.section.isEmpty ? 'Results' : r.section;
      if (!bySection.containsKey(key)) order.add(key);
      (bySection[key] ??= []).add(r);
    }
    return [
      for (final key in order) ...[key, ...bySection[key]!],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final results = _meaning ?? _results;
    final viewport = MediaQuery.sizeOf(context);
    final dialogWidth = (viewport.width - 24).clamp(0.0, 620.0).toDouble();
    final dialogHeight = (viewport.height - 24).clamp(180.0, 520.0).toDouble();
    final rows = _rows(results);
    return Dialog(
      alignment: const Alignment(0, -0.5),
      insetPadding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(minWidth: 0, maxWidth: 620),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: TextField(
                key: const ValueKey('global-search-field'),
                controller: _controller,
                autofocus: true,
                style: const TextStyle(fontSize: 15),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('search-field-clear'),
                          tooltip: 'Clear',
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: _clear,
                        ),
                  hintText: 'Search notes, tasks, calendar, mindmaps, Archive…',
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: 16,
                  ),
                  constraints: const BoxConstraints(minHeight: 62),
                ),
                onChanged: _typed,
                onSubmitted: (_) {
                  if (results.isNotEmpty) _open(results.first);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
              child: Row(
                children: [
                  Expanded(
                    child: ListenableBuilder(
                      listenable: widget.state.pdfTexts,
                      builder: (context, _) => Text(
                        _pdfLine(widget.state),
                        style: TextStyle(
                          fontSize: AppType.sizeMeta,
                          color: AppColors.textFaint,
                        ),
                      ),
                    ),
                  ),
                  if (widget.state.canSearchByMeaning &&
                      _query.trim().isNotEmpty)
                    TextButton.icon(
                      key: const ValueKey('search-by-meaning'),
                      onPressed: _searchingMeaning ? null : _byMeaning,
                      icon: const Icon(Icons.auto_awesome_outlined, size: 15),
                      label: const Text('Search by meaning (local AI)'),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                children: [
                  for (final f in SearchFilter.values)
                    Padding(
                      padding: const EdgeInsets.only(
                        right: 6,
                        top: 6,
                        bottom: 6,
                      ),
                      child: ChoiceChip(
                        key: ValueKey('search-filter-${f.name}'),
                        label: Text(
                          f.label,
                          style: const TextStyle(fontSize: AppType.sizeLabel),
                        ),
                        selected: _filter == f,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) {
                          setState(() => _filter = f);
                          _schedule();
                        },
                      ),
                    ),
                ],
              ),
            ),
            const Divider(),
            Expanded(child: _body(rows, results)),
          ],
        ),
      ),
    );
  }

  Widget _message(String text, {String? detail, Widget? action, Key? key}) {
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: AppType.sizeBodySmall,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 4),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textFaint,
                  fontSize: AppType.sizeLabel,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 8), action],
          ],
        ),
      ),
    );
  }

  Widget _body(List<Object> rows, List<SearchResult> results) {
    if (_error != null) {
      return _message(
        'Search ran into a problem.',
        detail: 'Your data is untouched. Try again.',
        key: const ValueKey('search-error'),
        action: TextButton(
          key: const ValueKey('search-retry'),
          onPressed: _retry,
          child: const Text('Try again'),
        ),
      );
    }
    if (_query.trim().isEmpty) {
      return _message(
        'Start typing to search everything.',
        detail:
            'Notes, tasks, projects, calendar, mindmaps and the Archive. '
            'Parts of words work too.',
        key: const ValueKey('search-hint'),
      );
    }
    if (results.isEmpty) {
      if (_loading) {
        return _message(
          'Searching…',
          key: const ValueKey('search-loading'),
        );
      }
      return _message(
        'Nothing found for “${_query.trim()}”.',
        detail: _filter == SearchFilter.all
            ? 'Check the spelling, or try fewer or shorter words.'
            : 'Only ${_filter.label} is searched. Try All.',
        key: const ValueKey('search-empty'),
      );
    }
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('search-results'),
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final row = rows[i];
              if (row is String) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.lg,
                    AppSpace.md,
                    AppSpace.lg,
                    2,
                  ),
                  child: Text(
                    row.toUpperCase(),
                    key: ValueKey('search-section-$row'),
                    style: TextStyle(
                      fontSize: AppType.sizeMeta,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textFaint,
                    ),
                  ),
                );
              }
              return _row(row as SearchResult);
            },
          ),
        ),
      ],
    );
  }

  Widget _row(SearchResult r) {
    final meta = TextStyle(
      fontSize: AppType.sizeLabel,
      color: AppColors.textFaint,
    );
    return ListTile(
      key: ValueKey('search-result-${r.kind}-${r.title}'),
      dense: true,
      leading: Icon(r.icon, size: 18, color: AppColors.textMuted),
      title: _highlight(
        r.title,
        _query,
        const TextStyle(fontSize: AppType.sizeBodySmall),
        maxLines: 1,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (r.subtitle.isNotEmpty) _highlight(r.subtitle, _query, meta),
          if (r.location.isNotEmpty || r.why.isNotEmpty)
            Text(
              [
                if (r.location.isNotEmpty) r.location,
                if (r.why.isNotEmpty) r.why,
              ].join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: meta.copyWith(fontSize: AppType.sizeMeta),
            ),
        ],
      ),
      trailing: Text(r.kind, style: meta.copyWith(fontSize: AppType.sizeMeta)),
      onTap: () => _open(r),
    );
  }

  /// [text] with the parts that match [query] in the accent colour and
  /// bold.
  Widget _highlight(String text, String query, TextStyle base, {int maxLines = 2}) {
    final spans = matchRanges(text, query);
    if (spans.isEmpty) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    final marked = base.copyWith(
      fontWeight: FontWeight.w700,
      color: AppColors.accent,
    );
    final parts = <TextSpan>[];
    var at = 0;
    for (final s in spans) {
      if (s.start > at) parts.add(TextSpan(text: text.substring(at, s.start)));
      parts.add(TextSpan(text: text.substring(s.start, s.end), style: marked));
      at = s.end;
    }
    if (at < text.length) parts.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(style: base, children: parts),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
