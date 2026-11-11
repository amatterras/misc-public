// Feeds the search index from the workspace and keeps it current.
//
// Incremental: the index remembers, per collection, the revision of every
// record it has read. [refresh] compares those revisions with the
// collection's current ones (a cheap scan; no text is read or split) and
// re-reads only records that were added or changed, and drops records that
// were deleted. A search therefore never walks the whole workspace's text,
// and a big workspace is only read in full once (the first search, or after
// [rebuild]).
//
// Sources outside the record collections (mindmap text, notebook-page text,
// PDF text) come through [SearchSources]; they are compared by a cheap
// fingerprint, the same way.
//
// Safe by construction: documents are made from records and are never
// written anywhere; deleted, moved or partly loaded records simply fall out
// of (or stay out of) the index; a record that cannot be turned into a
// document is skipped, not fatal.
import '../data/models/calendar_models.dart';
import '../data/models/canvas_models.dart' show CanvasSummary;
import '../data/models/library_models.dart';
import '../data/models/object_library_models.dart';
import '../data/models/task_models.dart';
import '../data/storage/app_log.dart';
import '../data/workspace.dart';
import '../features/links/link_tags.dart';
import '../features/smartlinks/smart_links.dart' show plainLinkText;
import 'search_index.dart';

/// Text that does not live in a record collection.
class SearchSources {
  const SearchSources({
    this.canvases = _none,
    this.notebookPages = _noPages,
    this.pdfPages = _noPdf,
    this.pdfText = _noText,
    this.calendarNotes = _noPages,
  });

  static List<CanvasSummary> _none() => const [];
  static Map<String, String> _noPages() => const {};
  static List<String>? _noPdf(String assetId) => null;
  static String? _noText(String assetId) => null;

  final List<CanvasSummary> Function() canvases;

  /// `nb-<noteId>` → the text written on that note's pages.
  final Map<String, String> Function() notebookPages;

  /// The text of a PDF split by page (null: not read yet / none).
  final List<String>? Function(String assetId) pdfPages;

  /// The whole text of a PDF when it is not split in pages.
  final String? Function(String assetId) pdfText;

  /// Text typed on the Calendar's drawing layer: day key (yyyy-mm-dd) → the
  /// text boxes of that day. Never the strokes.
  final Map<String, String> Function() calendarNotes;
}

class WorkspaceSearch {
  WorkspaceSearch(this.ws, {this.sources = const SearchSources()});

  final Workspace ws;
  final SearchSources sources;
  final SearchIndex index = SearchIndex();

  /// collection name (or 'x:<source>') → id → version last indexed.
  final Map<String, Map<String, String>> _seen = {};

  /// What the last [refresh] did (for tests and diagnostics).
  int lastRead = 0;
  int lastDropped = 0;
  int lastScanned = 0;

  /// Forgets everything and reads the workspace again.
  void rebuild() {
    index.clear();
    _seen.clear();
    refresh();
  }

  /// Brings the index up to date with the workspace.
  void refresh() {
    lastRead = lastDropped = lastScanned = 0;
    _collection('notes', ws.notes.versions(), (id) {
      final n = ws.notes[id];
      return n == null ? null : _note(n);
    });
    _collection('tasks', ws.tasks.versions(), (id) {
      final t = ws.tasks[id];
      return t == null ? null : _task(t);
    });
    _collection('projects', ws.projects.versions(), (id) {
      final p = ws.projects[id];
      return p == null
          ? null
          : IndexedDoc(
              kind: DocKind.project,
              id: p.id,
              title: p.name,
              subtitle: 'Project',
            );
    });
    _collection('calendar_entries', ws.entries.versions(), (id) {
      final e = ws.entries[id];
      return e == null ? null : _entry(e);
    });
    _collection('assets', ws.assets.versions(), (id) {
      final a = ws.assets[id];
      return a == null ? null : _asset(a);
    });
    // A PDF's text is read in the background after its record exists: when
    // the pages arrive (or change) the document is read again.
    final pdfSeen = _seen['x:pdf'] ??= {};
    for (final a in ws.assets.all) {
      if (a.kind != AssetKind.document) continue;
      final fingerprint =
          '${sources.pdfPages(a.id)?.length ?? 0}.${sources.pdfText(a.id)?.length ?? 0}';
      if (pdfSeen[a.id] == fingerprint) continue;
      pdfSeen[a.id] = fingerprint;
      _read('assets', a.id, (id) => _asset(a));
    }
    _collection('library_objects', ws.libraryObjects.versions(), (id) {
      final o = ws.libraryObjects[id];
      return o == null || o.deleted ? null : _archiveObject(o);
    });
    _collection('library_spaces', ws.librarySpaces.versions(), (id) {
      final s = ws.librarySpaces[id];
      return s == null
          ? null
          : IndexedDoc(
              kind: DocKind.folder,
              id: s.id,
              title: s.name,
              subtitle: 'Archive folder',
            );
    });
    _collection('browser_bookmarks', ws.bookmarks.versions(), (id) {
      final b = ws.bookmarks[id];
      return b == null
          ? null
          : IndexedDoc(
              kind: DocKind.bookmark,
              id: b.id,
              title: b.title,
              subtitle: b.url,
              fields: [SearchField('url', b.url, weight: 4)],
            );
    });
    _collection('ai_conversations', ws.aiConversations.versions(), (id) {
      final c = ws.aiConversations[id];
      return c == null
          ? null
          : IndexedDoc(
              kind: DocKind.aiChat,
              id: c.id,
              title: c.title,
              subtitle: 'AI chat',
              fields: [
                SearchField('body', c.messages.map((m) => m.text).join(' ')),
              ],
            );
    });
    _collection('thought_experiments', ws.experiments.versions(), (id) {
      final x = ws.experiments[id];
      return x == null
          ? null
          : IndexedDoc(
              kind: DocKind.experiment,
              id: x.id,
              title: x.title,
              subtitle: 'Thought experiment',
              fields: [SearchField('body', x.toText())],
            );
    });

    // Sources that are not records, compared by a cheap fingerprint.
    final canvases = {for (final c in sources.canvases()) c.id: c};
    _external(
      'x:canvas',
      {
        for (final c in canvases.values)
          c.id:
              '${c.title.hashCode}.${c.searchText.hashCode}.'
              '${c.searchText.length}',
      },
      DocKind.canvas,
      (id) {
        final c = canvases[id]!;
        if (c.isNotebook ||
            c.isLinksBoard ||
            c.isCalendarInk ||
            c.isComponents) {
          return null;
        }
        return IndexedDoc(
          kind: DocKind.canvas,
          id: c.id,
          title: c.title,
          subtitle: 'Mindmap',
          fields: [SearchField('body', plainLinkText(c.searchText))],
        );
      },
    );
    final notes = sources.calendarNotes();
    _external(
      'x:calendar-notes',
      {
        for (final e in notes.entries)
          if (e.value.trim().isNotEmpty)
            e.key: '${e.value.hashCode}.${e.value.length}',
      },
      DocKind.calendarNote,
      (id) {
        final day = DateTime.tryParse(id);
        return IndexedDoc(
          kind: DocKind.calendarNote,
          id: id,
          title: day == null ? 'Calendar note' : 'Calendar note ($id)',
          subtitle: 'Calendar note',
          fields: [SearchField('body', notes[id] ?? '')],
        );
      },
    );
    final pages = sources.notebookPages();
    _external(
      'x:pages',
      {
        for (final e in pages.entries)
          if (e.key.startsWith('nb-'))
            e.key: '${e.value.hashCode}.${e.value.length}',
      },
      DocKind.notebookPage,
      (id) {
        final noteId = id.substring(3);
        final note = ws.notes[noteId];
        if (note == null) return null; // a deleted note's pages
        return IndexedDoc(
          kind: DocKind.notebookPage,
          id: noteId,
          title: note.displayTitle,
          subtitle: 'Note page',
          fields: [SearchField('pages', plainLinkText(pages[id] ?? ''))],
        );
      },
      docId: (id) => id.substring(3),
    );
  }

  /// Compares [versions] with what was indexed for [name]; re-reads the
  /// changed, drops the vanished.
  void _collection(
    String name,
    Iterable<({String id, String rev, bool deleted})> versions,
    IndexedDoc? Function(String id) build,
  ) {
    final seen = _seen[name] ??= {};
    final now = <String, String>{};
    for (final v in versions) {
      if (!v.deleted) now[v.id] = v.rev;
    }
    lastScanned += now.length;
    for (final id in seen.keys.toList()) {
      if (!now.containsKey(id)) {
        _drop(name, id);
        seen.remove(id);
      }
    }
    for (final e in now.entries) {
      if (seen[e.key] == e.value) continue;
      seen[e.key] = e.value;
      _read(name, e.key, build);
    }
  }

  void _external(
    String name,
    Map<String, String> now,
    DocKind kind,
    IndexedDoc? Function(String id) build, {
    String Function(String id)? docId,
  }) {
    final seen = _seen[name] ??= {};
    lastScanned += now.length;
    for (final id in seen.keys.toList()) {
      if (!now.containsKey(id)) {
        index.remove('${kind.name}:${docId?.call(id) ?? id}');
        seen.remove(id);
        lastDropped++;
      }
    }
    for (final e in now.entries) {
      if (seen[e.key] == e.value) continue;
      seen[e.key] = e.value;
      try {
        final doc = build(e.key);
        final key = '${kind.name}:${docId?.call(e.key) ?? e.key}';
        if (doc == null) {
          index.remove(key);
        } else {
          index.upsert(doc);
          lastRead++;
        }
      } on Object catch (error) {
        AppLog.warn('Search: skipped ${e.key} ($error)');
      }
    }
  }

  void _read(String name, String id, IndexedDoc? Function(String) build) {
    try {
      final doc = build(id);
      if (doc == null) {
        _dropAny(id);
      } else {
        index.upsert(doc);
        lastRead++;
      }
    } on Object catch (error) {
      AppLog.warn('Search: skipped $name/$id ($error)');
    }
  }

  void _drop(String name, String id) {
    _dropAny(id);
  }

  /// A record id belongs to one kind in practice; remove whatever kind it
  /// was indexed as.
  void _dropAny(String id) {
    for (final k in DocKind.values) {
      final key = '${k.name}:$id';
      if (index[key] != null) {
        index.remove(key);
        lastDropped++;
      }
    }
  }

  /// Ranked hits, after bringing the index up to date.
  List<SearchHit> search(String q, {Set<DocKind>? kinds, int limit = 100}) {
    refresh();
    return index.query(q, kinds: kinds, limit: limit);
  }

  // ---- records to documents ---------------------------------------------

  IndexedDoc _note(Note n) {
    final folder = ws.folders[n.folderId]?.name;
    return IndexedDoc(
      kind: DocKind.note,
      id: n.id,
      title: n.displayTitle,
      subtitle: 'Note',
      fields: [
        SearchField('body', plainLinkText(n.body)),
        if (n.tags.isNotEmpty) SearchField('tags', n.tags.join(' '), weight: 6),
        if (folder != null) SearchField('folder', folder, weight: 3),
      ],
    );
  }

  IndexedDoc _task(Task t) {
    final project = ws.projects[t.projectId]?.name;
    // A subtask is a task with a parent: it is found by its own text and by
    // the parent's title, and says whose subtask it is.
    final parent = t.parentId == null ? null : ws.tasks[t.parentId!];
    final props = [
      for (final e in t.properties.entries) '${e.key} ${e.value}',
    ].join(' ');
    return IndexedDoc(
      kind: DocKind.task,
      id: t.id,
      title: t.title,
      subtitle: t.isExam
          ? 'Exam'
          : parent != null
          ? 'Subtask of ${parent.title}'
          : 'Task',
      fields: [
        if (t.notes.isNotEmpty)
          SearchField('notes', plainLinkText(t.notes)),
        if (t.labels.isNotEmpty)
          SearchField('tags', t.labels.join(' '), weight: 6),
        if (project != null) SearchField('project', project, weight: 4),
        if (parent != null) SearchField('parent', parent.title, weight: 3),
        if (props.isNotEmpty) SearchField('properties', props, weight: 3),
      ],
    );
  }

  IndexedDoc _entry(CalendarEntry e) => IndexedDoc(
    kind: DocKind.entry,
    id: e.id,
    title: e.name,
    subtitle: e.category.label,
    fields: [
      SearchField('description', plainLinkText(e.description), weight: 3),
      SearchField('notes', plainLinkText(e.notes)),
      if (e.author.isNotEmpty) SearchField('author', e.author, weight: 4),
      SearchField('highlights', plainLinkText(e.highlights)),
    ],
  );

  IndexedDoc _asset(Asset a) {
    final tags = [
      ...ws.tagsOfAsset(a).map((t) => t.name),
      ...LinkTag.of(a.linkTags).map((t) => t.label),
    ].join(' ');
    if (a.kind == AssetKind.document) {
      final pages = sources.pdfPages(a.id);
      final text = sources.pdfText(a.id);
      return IndexedDoc(
        kind: DocKind.document,
        id: a.id,
        title: a.label,
        subtitle: 'PDF',
        fields: [
          if (tags.isNotEmpty) SearchField('tags', tags, weight: 6),
          if (pages != null && pages.isNotEmpty)
            SearchField('pdf', '', weight: 2).withPages(pages)
          else if (text != null && text.isNotEmpty)
            SearchField('pdf', text, weight: 2),
        ],
        version: '${pages?.length ?? 0}.${text?.length ?? 0}',
      );
    }
    return IndexedDoc(
      kind: DocKind.link,
      id: a.id,
      title: a.label,
      subtitle: a.url ?? '',
      fields: [
        if (a.url != null) SearchField('url', a.url!, weight: 4),
        if (a.description != null) SearchField('description', a.description!),
        if (a.siteName != null) SearchField('site', a.siteName!, weight: 3),
        if (tags.isNotEmpty) SearchField('tags', tags, weight: 6),
      ],
    );
  }

  IndexedDoc _archiveObject(LibraryObject o) => IndexedDoc(
    kind: DocKind.archive,
    id: o.id,
    title: o.title.isEmpty ? 'Untitled' : o.title,
    subtitle: o.type.name,
    fields: [
      if (o.description != null)
        SearchField('description', o.description!, weight: 3),
      if (o.summary != null) SearchField('summary', o.summary!, weight: 3),
      if (o.content != null)
        SearchField('body', plainLinkText(o.content!)),
      if (o.sourceUrl != null) SearchField('url', o.sourceUrl!, weight: 4),
      if (o.mainEntity != null)
        SearchField('entity', o.mainEntity!.name, weight: 4),
    ],
  );
}
