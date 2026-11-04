// The search dialog's results from the unified index (lib/search): ranked,
// each with why it matched, and a way to open it where the match is.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/models/record.dart';
import '../../new_ui/new_archive_page.dart' show openArchiveItem;
import '../../phone/phone_archive.dart' show openPhoneArchiveItem;
import '../../phone/phone_profile.dart';
import '../../search/search_index.dart';
import '../relations/pdf_page_viewer.dart';
import 'search_dialog.dart' show SearchResult;

/// The kind filters offered in the dialog.
enum SearchFilter {
  all('All', null),
  notes('Notes', {DocKind.note, DocKind.notebookPage}),
  tasks('Tasks', {DocKind.task, DocKind.project}),
  calendar('Calendar', {DocKind.entry}),
  archive('Archive', {DocKind.archive, DocKind.folder, DocKind.link}),
  pdfs('PDFs', {DocKind.document}),
  mindmaps('Mindmaps', {DocKind.canvas});

  const SearchFilter(this.label, this.kinds);
  final String label;
  final Set<DocKind>? kinds;
}

List<SearchResult> searchRanked(
  AppState s,
  String query, {
  SearchFilter filter = SearchFilter.all,
  BuildContext? context,
}) {
  if (query.trim().isEmpty) return const [];
  return [
    for (final h in s.search.search(query, kinds: filter.kinds))
      resultOf(s, h, context),
  ];
}

SearchResult resultOf(AppState s, SearchHit h, BuildContext? context) {
  final d = h.doc;
  final why = h.reasons.isEmpty ? '' : 'in ${h.reasons.join(', ')}';
  final where = h.page == null ? '' : 'page ${h.page}';
  final detail = [
    if (where.isNotEmpty) where,
    if (h.snippet.isNotEmpty) h.snippet else d.subtitle,
  ].join(': ');
  final (icon, kind) = switch (d.kind) {
    DocKind.note => (Icons.description_outlined, 'Note'),
    DocKind.notebookPage => (Icons.edit_note, 'Note page'),
    DocKind.task => (Icons.check_box_outline_blank, 'Task'),
    DocKind.project => (Icons.folder_outlined, 'Project'),
    DocKind.entry => (
      Icons.calendar_today_outlined,
      s.workspace.entries[d.id]?.category.label ?? 'Calendar',
    ),
    DocKind.link => (Icons.link, 'Link'),
    DocKind.document => (Icons.picture_as_pdf_outlined, 'PDF'),
    DocKind.archive => (Icons.bookmark_border, 'Archive'),
    DocKind.folder => (Icons.folder_open_outlined, 'Archive folder'),
    DocKind.canvas => (Icons.grid_view, 'Mindmap'),
    DocKind.bookmark => (Icons.bookmark_outline, 'Bookmark'),
    DocKind.aiChat => (Icons.auto_awesome_outlined, 'AI chat'),
    DocKind.experiment => (Icons.psychology_outlined, 'Thought experiment'),
  };
  return SearchResult(
    icon: icon,
    kind: kind,
    title: d.title,
    subtitle: detail,
    why: why,
    open: () => openHit(s, h, context),
  );
}

/// Opens a hit where the match is.
Future<void> openHit(AppState s, SearchHit h, BuildContext? context) async {
  final id = h.doc.id;
  final ws = s.workspace;
  switch (h.doc.kind) {
    case DocKind.note || DocKind.notebookPage:
      s.openNote(id);
    case DocKind.task:
      s.openTask(id);
    case DocKind.project:
      s.goTo(AppPage.tasks);
    case DocKind.entry:
      final e = ws.entries[id];
      if (e == null) return;
      final day =
          e.startDate ??
          (e.dates.isNotEmpty
              ? parseDayKey((e.dates.toList()..sort()).first)
              : null) ??
          (e.readingLog.isNotEmpty
              ? parseDayKey((e.readingLog.keys.toList()..sort()).first)
              : null) ??
          DateTime.now();
      s.openCalendarDay(day);
    case DocKind.link:
      if (!await s.openLinkCard(id)) {
        final url = ws.assets[id]?.url;
        if (url != null) s.openInSafari(url);
      }
    case DocKind.document:
      final a = ws.assets[id];
      if (a == null) return;
      if (context != null && context.mounted) {
        // Where this device can show pages, opens on the page that matched.
        await openPdfAtPage(context, s, a, h.page);
      } else {
        final file = ws.documentFile(a);
        if (file != null) s.openDocument(file.path);
      }
    case DocKind.archive:
      if (context != null && context.mounted) {
        if (PhoneProfile.active) {
          await openPhoneArchiveItem(context, s, id);
        } else {
          await openArchiveItem(context, s, id);
        }
      } else {
        s.goTo(AppPage.links);
      }
    case DocKind.folder:
      s.goTo(AppPage.links);
    case DocKind.canvas:
      await s.openCanvas(id);
    case DocKind.bookmark:
      final url = ws.bookmarks[id]?.url;
      if (url != null) s.openInSafari(url);
    case DocKind.aiChat:
      s.openAiConversation(id);
    case DocKind.experiment:
      s.openExperiment(id);
  }
}
