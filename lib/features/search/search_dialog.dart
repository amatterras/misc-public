import 'ranked_search.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/canvas_ops.dart' show canvasLinkTarget;
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../data/models/record.dart';
import '../../platform/platform.dart' as native;
import '../../widgets/common.dart';
import '../links/link_tags.dart';

class SearchResult {
  const SearchResult({
    required this.icon,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.open,
    this.why = '',
  });

  final IconData icon;
  final String kind;
  final String title;
  final String subtitle;
  final VoidCallback open;

  /// Where the match is ("in title, tags"), for ranked results.
  final String why;
}

/// Searches every kind of record. Pure function so it can be tested.
List<SearchResult> searchEverything(AppState s, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  bool has(String? text) => text != null && text.toLowerCase().contains(q);
  String snippet(String text) {
    final i = text.toLowerCase().indexOf(q);
    if (i < 0) return text.length > 90 ? '${text.substring(0, 90)}…' : text;
    final start = (i - 30).clamp(0, text.length);
    final end = (i + q.length + 60).clamp(0, text.length);
    return '${start > 0 ? '…' : ''}${text.substring(start, end).replaceAll('\n', ' ')}${end < text.length ? '…' : ''}';
  }

  final ws = s.workspace;
  final results = <SearchResult>[];
  for (final n in ws.notes.all) {
    if (has(n.title) || has(n.body) || n.tags.any(has)) {
      results.add(
        SearchResult(
          icon: Icons.description_outlined,
          kind: 'Note',
          title: n.displayTitle,
          subtitle: has(n.body) ? snippet(n.body) : ws.folderLabel(n.folderId),
          open: () => s.openNote(n.id),
        ),
      );
    }
  }
  // Text typed on note pages and on the Archive board.
  for (final MapEntry(key: id, value: text) in s.pageSearchText.entries) {
    if (!has(text)) continue;
    if (isNotebookId(id)) {
      final note = ws.notes[id.substring('nb-'.length)];
      if (note == null) continue; // a deleted note's pages
      results.add(
        SearchResult(
          icon: Icons.edit_note,
          kind: 'Note page',
          title: note.displayTitle,
          subtitle: snippet(text),
          open: () => s.openNote(note.id),
        ),
      );
    } else if (isLinksBoardId(id)) {
      results.add(
        SearchResult(
          icon: Icons.bookmarks_outlined,
          kind: 'Archive',
          title: 'Archive board',
          subtitle: snippet(text),
          open: () => s.goTo(AppPage.links),
        ),
      );
    }
  }
  for (final c in s.canvasList) {
    if (has(c.title) || has(c.searchText)) {
      results.add(
        SearchResult(
          icon: Icons.grid_view,
          kind: 'Canvas',
          title: c.title,
          subtitle: has(c.searchText) ? snippet(c.searchText) : 'Canvas',
          open: () => s.openCanvas(c.id),
        ),
      );
    }
  }
  for (final a in ws.assets.all) {
    final tags = LinkTag.of(a.linkTags);
    final own = ws.tagsOfAsset(a); // the user's own tags
    if (a.kind == AssetKind.link &&
        (has(a.title) ||
            has(a.url) ||
            has(a.description) ||
            has(a.siteName) ||
            tags.any((t) => has(t.label)) ||
            own.any((t) => has(t.name)))) {
      results.add(
        SearchResult(
          icon: Icons.link,
          kind: 'Link',
          title: a.label,
          subtitle: [
            if (tags.isNotEmpty || own.isNotEmpty)
              [
                ...tags.map((t) => t.label),
                ...own.map((t) => t.name),
              ].join(', '),
            a.url ?? '',
          ].join('  ·  '),
          // The card in Archive if there is one, else the web page.
          open: () async {
            final mindmap = canvasLinkTarget(a.url);
            if (mindmap != null) {
              await s.openCanvas(mindmap); // a link to another mindmap
              return;
            }
            if (!await s.openLinkCard(a.id) && a.url != null) {
              native.openUrl(a.url!);
            }
          },
        ),
      );
    } else if (a.kind == AssetKind.document &&
        (has(a.title) || has(s.pdfTexts[a.id]))) {
      final body = s.pdfTexts[a.id] ?? '';
      results.add(
        SearchResult(
          icon: Icons.picture_as_pdf_outlined,
          kind: 'Document',
          title: a.label,
          // Text recognised on a scanned page names the page.
          subtitle: switch (s.pdfTexts.pageMatch(a.id, [q])) {
            (final page, final text) => 'Page $page: ${snippet(text)}',
            null => has(body) ? snippet(body) : 'PDF',
          },
          open: () {
            final file = ws.documentFile(a);
            if (file != null) s.openDocument(file.path);
          },
        ),
      );
    }
  }
  for (final e in ws.entries.all) {
    if (has(e.name) ||
        has(e.description) ||
        has(e.notes) ||
        has(e.author) ||
        has(e.highlights)) {
      final day =
          e.startDate ??
          (e.dates.isNotEmpty
              ? parseDayKey((e.dates.toList()..sort()).first)
              : null) ??
          (e.readingLog.isNotEmpty
              ? parseDayKey((e.readingLog.keys.toList()..sort()).first)
              : null) ??
          DateTime.now();
      results.add(
        SearchResult(
          icon: Icons.calendar_today_outlined,
          kind: e.category.label,
          title: e.name + (e.archived ? '  (archived)' : ''),
          subtitle: e.description.isNotEmpty
              ? snippet(e.description)
              : formatShortDate(day),
          open: () => s.openCalendarDay(day),
        ),
      );
    }
  }
  for (final p in ws.projects.all) {
    if (has(p.name)) {
      results.add(
        SearchResult(
          icon: Icons.folder_outlined,
          kind: 'Project',
          title: p.name,
          subtitle: 'Tasks',
          open: () => s.goTo(AppPage.tasks),
        ),
      );
    }
  }
  for (final t in ws.tasks.all) {
    if (has(t.title) || has(t.notes)) {
      results.add(
        SearchResult(
          icon: t.done
              ? Icons.check_box_outlined
              : Icons.check_box_outline_blank,
          kind: t.isExam ? 'Exam' : 'Task',
          title: t.title,
          subtitle: t.dueDate == null
              ? (ws.projects[t.projectId]?.name ?? '')
              : 'Due ${formatShortDate(t.dueDate!)}',
          open: () => s.openTask(t.id),
        ),
      );
    }
  }
  for (final c in ws.aiConversations.all) {
    final text = c.messages.map((m) => m.text).join(' ');
    if (has(c.title) || has(text)) {
      results.add(
        SearchResult(
          icon: Icons.auto_awesome_outlined,
          kind: 'AI chat',
          title: c.title,
          subtitle: has(text) ? snippet(text) : '',
          open: () => s.openAiConversation(c.id),
        ),
      );
    }
  }
  for (final x in ws.experiments.all) {
    final text = x.toText();
    if (has(text)) {
      results.add(
        SearchResult(
          icon: Icons.psychology_outlined,
          kind: 'Thought experiment',
          title: x.title,
          subtitle: snippet(text),
          open: () => s.openExperiment(x.id),
        ),
      );
    }
  }
  for (final b in ws.bookmarks.all) {
    if (has(b.title) || has(b.url)) {
      results.add(
        SearchResult(
          icon: Icons.bookmark_outline,
          kind: 'Bookmark',
          title: b.title,
          subtitle: b.url,
          open: () => s.openInSafari(b.url),
        ),
      );
    }
  }
  return results;
}

Future<void> showSearchDialog(BuildContext context, AppState state) {
  return showAppDialog<void>(
    context: context,
    builder: (_) => _SearchDialog(state: state, rootContext: context),
  );
}

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
  return 'Text inside PDFs is searched on this device. Scanned PDFs are '
      'read with on-device text recognition (Windows OCR / Apple Vision) '
      'where available; nothing is sent anywhere.';
}

class _SearchDialogState extends State<_SearchDialog> {
  String _query = '';
  SearchFilter _filter = SearchFilter.all;

  @override
  void initState() {
    super.initState();
    unawaited(widget.state.pdfTexts.indexAll());
  }

  /// Results of a search by meaning (local AI), until the text changes.
  List<SearchResult>? _meaning;
  bool _searchingMeaning = false;

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
            open: () => s.openNote(note.id),
          ),
      ];
    } catch (_) {
      s.showToast('The local AI could not search (is Ollama running?).');
    }
    if (mounted) setState(() => _searchingMeaning = false);
  }

  @override
  Widget build(BuildContext context) {
    final results =
        _meaning ??
        searchRanked(
          widget.state,
          _query,
          filter: _filter,
          context: widget.rootContext,
        );
    final viewport = MediaQuery.sizeOf(context);
    final dialogWidth = (viewport.width - 24).clamp(0.0, 620.0).toDouble();
    final dialogHeight = (viewport.height - 24).clamp(180.0, 460.0).toDouble();
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
              padding: const EdgeInsets.all(Space.lg),
              child: TextField(
                key: const ValueKey('global-search-field'),
                autofocus: true,
                style: const TextStyle(fontSize: 15),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Search notes, canvases, links, calendar and tasks',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: Space.md,
                    vertical: 16,
                  ),
                  constraints: BoxConstraints(minHeight: 56),
                ),
                onChanged: (v) => setState(() {
                  _query = v;
                  _meaning = null;
                }),
                onSubmitted: (_) {
                  if (results.isNotEmpty) {
                    Navigator.pop(context);
                    results.first.open();
                  }
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.lg),
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
                padding: const EdgeInsets.symmetric(horizontal: Space.lg),
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
                        onSelected: (_) => setState(() => _filter = f),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: results.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty
                            ? 'Start typing to search everything.'
                            : 'Nothing found.',
                        style: TextStyle(
                          color: AppColors.textFaint,
                          fontSize: AppType.sizeBodySmall,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, i) {
                        final r = results[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            r.icon,
                            size: 18,
                            color: AppColors.textMuted,
                          ),
                          title: Text(r.title, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            r.why.isEmpty
                                ? r.subtitle
                                : '${r.subtitle}\n${r.why}',
                            maxLines: r.why.isEmpty ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.sizeLabel,
                              color: AppColors.textFaint,
                            ),
                          ),
                          trailing: Text(
                            r.kind,
                            style: TextStyle(
                              fontSize: AppType.sizeMeta,
                              color: AppColors.textFaint,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            r.open();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
