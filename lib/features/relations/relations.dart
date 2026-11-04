// Relationships between things, by stable ids.
//
// What links to what was scattered: `[[Title]]` in note text (by title, so a
// rename breaks it), `Task.noteIds`, `Task.projectId`, `Note.assetIds`.
// This adds the missing piece without a second graph or a new data format:
// an explicit relation is a LibraryRelation (the record that already exists
// and already syncs) of kind 'ref':
//
//   objectId  "<kind>:<id>" of the source      e.g. note:k3x9…
//   targetId  "<kind>:<id>" of the target      e.g. asset:p7q2…
//   value     {'rel': 'related'|'cites'|'mentions'|…, 'page': 7 (PDF page)}
//
// Because they use ids, a rename or a move changes nothing. The relation id
// is fixed by (source, target, rel, page), so adding the same relation twice
// cannot duplicate it. A deleted target is not an error: the relation stays,
// is shown as unavailable, and works again if the target is restored.
// Unlinking removes the record the normal way (it can be brought back from
// "recently deleted").
//
// Read side: [relatedTo] returns both directions and also reports the older
// implicit links (title mentions, task↔note, task→project, note→files), so
// one list shows everything connected to an item.
import '../../data/models/library_models.dart';
import '../../data/models/object_library_models.dart';
import '../../data/workspace.dart';

enum RefKind { note, task, project, entry, asset, archive, canvas }

class Ref {
  const Ref(this.kind, this.id);

  final RefKind kind;
  final String id;

  String get key => '${kind.name}:$id';

  static Ref? parse(String key) {
    final i = key.indexOf(':');
    if (i <= 0) return null;
    final kind = RefKind.values.where((k) => k.name == key.substring(0, i));
    if (kind.isEmpty) return null;
    return Ref(kind.first, key.substring(i + 1));
  }

  @override
  bool operator ==(Object other) =>
      other is Ref && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => key;
}

/// One item connected to another.
class Related {
  const Related({
    required this.other,
    required this.title,
    required this.exists,
    required this.rel,
    required this.outgoing,
    this.page,
    this.relationId,
  });

  final Ref other;
  final String title;

  /// False when the other item was deleted or is not on this device.
  final bool exists;

  /// "related", "cites", "mentions", "attachment", "task", "project"…
  final String rel;

  /// True: the item points at [other]; false: [other] points at the item
  /// (a backlink).
  final bool outgoing;

  /// A page of a PDF, when the relation is about one.
  final int? page;

  /// Set for explicit relations (they can be removed); null for the implicit
  /// ones read from older links.
  final String? relationId;

  bool get explicit => relationId != null;
}

class RelationService {
  RelationService(this.ws);

  final Workspace ws;

  static const kind = 'ref';

  // ---- names and existence ------------------------------------------------

  bool exists(Ref r) => switch (r.kind) {
    RefKind.note => ws.notes[r.id] != null,
    RefKind.task => ws.tasks[r.id] != null,
    RefKind.project => ws.projects[r.id] != null,
    RefKind.entry => ws.entries[r.id] != null,
    RefKind.asset => ws.assets[r.id] != null,
    RefKind.archive =>
      ws.libraryObjects[r.id] != null && !ws.libraryObjects[r.id]!.deleted,
    RefKind.canvas => true, // canvases live in their own files
  };

  String titleOf(Ref r) => switch (r.kind) {
    RefKind.note => ws.notes[r.id]?.displayTitle ?? '(deleted note)',
    RefKind.task => ws.tasks[r.id]?.title ?? '(deleted task)',
    RefKind.project => ws.projects[r.id]?.name ?? '(deleted project)',
    RefKind.entry => ws.entries[r.id]?.name ?? '(deleted entry)',
    RefKind.asset => ws.assets[r.id]?.label ?? '(file not available)',
    RefKind.archive =>
      ws.libraryObjects[r.id]?.title.isNotEmpty == true
          ? ws.libraryObjects[r.id]!.title
          : (ws.libraryObjects[r.id] == null ? '(deleted item)' : 'Untitled'),
    RefKind.canvas => 'Mindmap',
  };

  // ---- explicit relations ---------------------------------------------------

  static String idOf(Ref from, Ref to, String rel, int? page) =>
      'ref.${from.key}>${to.key}.$rel${page == null ? '' : '#p$page'}';

  /// Relates [from] to [to]. Doing the same twice changes nothing. Returns the
  /// relation's id.
  String link(Ref from, Ref to, {String rel = 'related', int? page}) {
    final id = idOf(from, to, rel, page);
    if (from == to) return id;
    if (ws.libraryRelations[id] == null) {
      ws.libraryRelations.put(
        LibraryRelation(
          id: id,
          objectId: from.key,
          kind: kind,
          targetId: to.key,
          updatedAt: DateTime.now().toUtc(),
          value: {'rel': rel, 'page': ?page},
        ),
      );
    }
    return id;
  }

  /// Removes an explicit relation (it stays in "recently deleted").
  bool unlink(String relationId) {
    final r = ws.libraryRelations[relationId];
    if (r == null || r.kind != kind) return false;
    ws.libraryRelations.remove(relationId);
    return true;
  }

  /// Brings back a relation removed with [unlink].
  bool relink(String relationId) =>
      ws.libraryRelations.restoreDeleted(relationId) != null;

  Iterable<LibraryRelation> get _explicit =>
      ws.libraryRelations.all.where((r) => r.kind == kind);

  // ---- reading both directions ---------------------------------------------

  /// Everything connected to [r], newest explicit first, without repeats.
  List<Related> relatedTo(Ref r) {
    final out = <Related>[];
    final seen = <String>{};
    void add(Related x) {
      final k = '${x.outgoing}|${x.other.key}|${x.rel}|${x.page ?? ''}';
      if (seen.add(k)) out.add(x);
    }

    for (final rel in _explicit) {
      final from = Ref.parse(rel.objectId);
      final to = Ref.parse(rel.targetId);
      if (from == null || to == null) continue;
      final name = '${rel.value['rel'] ?? 'related'}';
      final page = (rel.value['page'] as num?)?.toInt();
      if (from == r) {
        add(
          Related(
            other: to,
            title: titleOf(to),
            exists: exists(to),
            rel: name,
            outgoing: true,
            page: page,
            relationId: rel.id,
          ),
        );
      } else if (to == r) {
        add(
          Related(
            other: from,
            title: titleOf(from),
            exists: exists(from),
            rel: name,
            outgoing: false,
            page: page,
            relationId: rel.id,
          ),
        );
      }
    }
    _implicit(r, add);
    return out;
  }

  void _implicit(Ref r, void Function(Related) add) {
    Related make(Ref other, String rel, bool outgoing) => Related(
      other: other,
      title: titleOf(other),
      exists: exists(other),
      rel: rel,
      outgoing: outgoing,
    );
    switch (r.kind) {
      case RefKind.note:
        final n = ws.notes[r.id];
        if (n == null) return;
        // Title mentions, both ways (broken by a rename; pinMentions fixes
        // that by making them explicit).
        for (final t in n.linkedTitles) {
          final target = _noteByTitle(t);
          if (target != null && target.id != n.id) {
            add(make(Ref(RefKind.note, target.id), 'mentions', true));
          }
        }
        final mine = n.displayTitle.toLowerCase();
        for (final other in ws.notes.all) {
          if (other.id == n.id) continue;
          if (other.linkedTitles.any((t) => t.trim().toLowerCase() == mine)) {
            add(make(Ref(RefKind.note, other.id), 'mentions', false));
          }
        }
        for (final id in n.assetIds) {
          if (ws.assets[id] != null) {
            add(make(Ref(RefKind.asset, id), 'attachment', true));
          }
        }
        for (final t in ws.tasks.all) {
          if (t.noteIds.contains(n.id)) {
            add(make(Ref(RefKind.task, t.id), 'task', false));
          }
        }
      case RefKind.task:
        final t = ws.tasks[r.id];
        if (t == null) return;
        for (final id in t.noteIds) {
          add(make(Ref(RefKind.note, id), 'note', true));
        }
        if (t.projectId != null) {
          add(make(Ref(RefKind.project, t.projectId!), 'project', true));
        }
      case RefKind.asset:
        for (final n in ws.notes.all) {
          if (n.assetIds.contains(r.id)) {
            add(make(Ref(RefKind.note, n.id), 'attachment', false));
          }
        }
      case RefKind.project:
        for (final t in ws.tasks.all) {
          if (t.projectId == r.id) {
            add(make(Ref(RefKind.task, t.id), 'project', false));
          }
        }
      default:
        break;
    }
  }

  Note? _noteByTitle(String title) {
    final want = title.trim().toLowerCase();
    for (final n in ws.notes.all) {
      if (n.displayTitle.toLowerCase() == want) return n;
    }
    return null;
  }

  /// Makes the `[[Title]]` mentions of [n] explicit (by id), so they survive
  /// a rename of either note. Never removes anything. Returns how many were
  /// added.
  int pinMentions(Note n) {
    var added = 0;
    for (final t in n.linkedTitles) {
      final target = _noteByTitle(t);
      if (target == null || target.id == n.id) continue;
      final id = idOf(
        Ref(RefKind.note, n.id),
        Ref(RefKind.note, target.id),
        'mentions',
        null,
      );
      if (ws.libraryRelations[id] == null) {
        link(
          Ref(RefKind.note, n.id),
          Ref(RefKind.note, target.id),
          rel: 'mentions',
        );
        added++;
      }
    }
    return added;
  }

  // ---- PDF pages -------------------------------------------------------------

  /// Notes (and others) that refer to a page of PDF [assetId]: (source, page).
  List<({Ref from, int page, String relationId})> pageReferences(
    String assetId,
  ) {
    final target = Ref(RefKind.asset, assetId);
    return [
      for (final rel in _explicit)
        if (rel.targetId == target.key && rel.value['page'] != null)
          if (Ref.parse(rel.objectId) case final from?)
            (
              from: from,
              page: (rel.value['page'] as num).toInt(),
              relationId: rel.id,
            ),
    ]..sort((a, b) => a.page.compareTo(b.page));
  }
}
