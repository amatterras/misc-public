// The search dialog's results from the unified index (lib/search): ranked,
// grouped by section, each with where it was found and a way to open it
// exactly there.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/record.dart';
import '../../new_ui/new_archive_page.dart' show openArchiveItem;
import '../../phone/phone_archive.dart' show openPhoneArchiveItem;
import '../../phone/phone_profile.dart';
import '../../search/search_index.dart';
import '../../widgets/common.dart' show formatShortDate;
import '../relations/pdf_page_viewer.dart';

/// One line of the results.
class SearchResult {
  const SearchResult({
    required this.icon,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.open,
    this.why = '',
    this.section = '',
    this.location = '',
  });

  final IconData icon;
  final String kind;
  final String title;
  final String subtitle;
  final VoidCallback open;

  /// Where the match is ("in title, tags"), for ranked results.
  final String why;

  /// The group this result is listed under ("Notes", "Calendar"…).
  final String section;

  /// Where the item lives ("Notes › Physics", "Calendar › 3 Nov").
  final String location;
}

/// The kind filters offered in the dialog.
enum SearchFilter {
  all('All', null),
  notes('Notes', {DocKind.note, DocKind.notebookPage}),
  tasks('Tasks', {DocKind.task, DocKind.project}),
  calendar('Calendar', {DocKind.entry, DocKind.calendarNote}),
  archive('Archive', {
    DocKind.archive,
    DocKind.folder,
    DocKind.link,
    DocKind.bookmark,
  }),
  pdfs('PDFs', {DocKind.document}),
  mindmaps('Mindmaps', {DocKind.canvas});

  const SearchFilter(this.label, this.kinds);
  final String label;
  final Set<DocKind>? kinds;
}

/// The group a kind of result is listed under.
String sectionOf(DocKind kind) => switch (kind) {
  DocKind.note || DocKind.notebookPage => 'Notes',
  DocKind.task || DocKind.project => 'Tasks and projects',
  DocKind.entry || DocKind.calendarNote => 'Calendar',
  DocKind.canvas => 'Mindmaps',
  DocKind.archive ||
  DocKind.folder ||
  DocKind.link ||
  DocKind.bookmark => 'Archive',
  DocKind.document => 'PDFs',
  DocKind.aiChat || DocKind.experiment => 'AI and thinking',
};

/// Ranked results for [query], from the one index. Never searches
/// handwriting: the index is made from typed text only.
List<SearchResult> searchRanked(
  AppState s,
  String query, {
  SearchFilter filter = SearchFilter.all,
  BuildContext? context,
}) {
  if (query.trim().isEmpty) return const [];
  return [
    for (final h in s.search.search(query, kinds: filter.kinds))
      resultOf(s, h, context, query: query),
  ];
}

/// Every kind of record, found by the one index (kept under its old name
/// for callers and tests that want the plain list).
List<SearchResult> searchEverything(AppState s, String query) =>
    searchRanked(s, query);

SearchResult resultOf(
  AppState s,
  SearchHit h,
  BuildContext? context, {
  String query = '',
}) {
  final d = h.doc;
  final ws = s.workspace;
  final why = h.reasons.isEmpty ? '' : 'in ${h.reasons.join(', ')}';
  final where = h.page == null ? '' : 'page ${h.page}';
  final detail = [
    if (where.isNotEmpty) where,
    if (h.snippet.isNotEmpty) h.snippet else d.subtitle,
  ].join(': ');
  String day(CalendarEntry e) => formatShortDate(searchHitDay(e) ?? DateTime.now());
  final (icon, kind, location) = switch (d.kind) {
    DocKind.note => (
      Icons.description_outlined,
      'Note',
      'Notes › ${ws.folderLabel(ws.notes[d.id]?.folderId)}',
    ),
    DocKind.notebookPage => (
      Icons.edit_note,
      'Note page',
      'Notes › typed text on the pages',
    ),
    DocKind.task => (Icons.check_box_outline_blank, 'Task', d.subtitle),
    DocKind.project => (Icons.folder_outlined, 'Project', 'Tasks › Projects'),
    DocKind.entry => () {
      final e = ws.entries[d.id];
      return (
        Icons.calendar_today_outlined,
        e?.category.label ?? 'Calendar',
        e == null ? 'Calendar' : 'Calendar › ${day(e)}',
      );
    }(),
    DocKind.calendarNote => (
      Icons.edit_calendar_outlined,
      'Calendar note',
      'Calendar › ${_dayLabel(d.id)}',
    ),
    DocKind.link => (Icons.link, 'Link', 'Archive › ${d.subtitle}'),
    DocKind.document => (Icons.picture_as_pdf_outlined, 'PDF', 'PDFs'),
    DocKind.archive => (Icons.bookmark_border, 'Archive', 'Archive'),
    DocKind.folder => (
      Icons.folder_open_outlined,
      'Archive folder',
      'Archive › Folders',
    ),
    DocKind.canvas => (Icons.grid_view, 'Mindmap', 'Mindmaps › ${d.title}'),
    DocKind.bookmark => (
      Icons.bookmark_outline,
      'Bookmark',
      'Safari › Bookmarks',
    ),
    DocKind.aiChat => (Icons.auto_awesome_outlined, 'AI chat', 'AI › Chats'),
    DocKind.experiment => (
      Icons.psychology_outlined,
      'Thought experiment',
      'Thought experiments',
    ),
  };
  return SearchResult(
    icon: icon,
    kind: kind,
    title: d.title,
    subtitle: detail,
    why: why,
    section: sectionOf(d.kind),
    location: location,
    open: () => openHit(s, h, context, query: query),
  );
}

String _dayLabel(String key) {
  try {
    return formatShortDate(parseDayKey(key));
  } on FormatException {
    return key;
  }
}

/// The day a calendar search hit opens on: where the entry starts, its
/// first date, the date of a reading-plan page, or its first reading day
/// (null: none, the caller uses today).
DateTime? searchHitDay(CalendarEntry e) {
  DateTime? first(Iterable<String> keys) {
    final sorted = keys.toList()..sort();
    for (final k in sorted) {
      try {
        return parseDayKey(k);
      } on FormatException {
        continue; // a damaged key is skipped
      }
    }
    return null;
  }

  return e.startDate ??
      first(e.dates) ??
      e.readingPlanDate ??
      first(e.readingLog.keys);
}

/// After a mindmap opens from a search hit: selects and centres the first
/// text box that holds the search words (the exact place of the match).
/// Does nothing if the match is in the title only.
Future<void> revealCanvasMatch(AppState s, String canvasId, String query) async {
  if (query.trim().isEmpty) return;
  final c = s.canvas;
  if (c == null || c.id != canvasId) return;
  final words = tokenize(query);
  if (words.isEmpty) return;
  TextItem? best;
  for (final item in c.items) {
    if (item is! TextItem) continue;
    final folded = foldText(item.text);
    if (words.every(folded.contains)) {
      best = item;
      break;
    }
    best ??= words.any(folded.contains) ? item : null;
  }
  if (best == null) return;
  final id = best.id;
  c.reveal(id);
  // The view may not be laid out yet right after opening: centre again once
  // it is.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      if (identical(s.canvas, c) && c.itemById(id) != null) c.reveal(id);
    } on FlutterError {
      // The mindmap was closed in the meantime.
    }
  });
}

/// Opens a hit where the match is.
Future<void> openHit(
  AppState s,
  SearchHit h,
  BuildContext? context, {
  String query = '',
}) async {
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
      s.openCalendarDay(searchHitDay(e) ?? DateTime.now());
    case DocKind.calendarNote:
      try {
        s.openCalendarDay(parseDayKey(id));
      } on FormatException {
        s.goTo(AppPage.calendar);
      }
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
      await revealCanvasMatch(s, id, query);
    case DocKind.bookmark:
      final url = ws.bookmarks[id]?.url;
      if (url != null) s.openInSafari(url);
    case DocKind.aiChat:
      s.openAiConversation(id);
    case DocKind.experiment:
      s.openExperiment(id);
  }
}
