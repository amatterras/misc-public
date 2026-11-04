// Sorting what was captured. Everything saved into the Archive starts as
// "unfiled" (the existing Unfiled area, not a second inbox). From there each
// item can be filed into a folder, turned into a note or a task, or archived
// away, and every one of those can be taken back.
//
// The state of an item is not a new field: it is read from relations that
// already exist (a 'space' relation = filed) plus two additive ones:
//   * 'converted' (id `conv.<note|task>.<objectId>`): the item became a note
//     or a task; `targetId` is that record. The item itself is kept as it
//     was, with its source, so nothing is lost and the link back is stable.
//   * 'archived' (id `arch.<objectId>`): put away; not deleted.
// Their ids are fixed, so doing the same thing twice cannot make a duplicate.
//
// Changes that touch two collections (a new note and the relation to it) go
// through the transaction log: both happen or neither does, even if the app
// is closed in the middle.
import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/library_models.dart';
import '../../data/models/object_library_models.dart';
import '../../data/models/task_models.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/workspace.dart';

enum CaptureState {
  /// Not filed anywhere yet.
  unfiled,

  /// In at least one Archive folder.
  filed,

  /// Turned into a note or a task.
  converted,

  /// Put away.
  archived;

  String get label => switch (this) {
    unfiled => 'Unfiled',
    filed => 'Filed',
    converted => 'Converted',
    archived => 'Archived',
  };
}

/// Takes a sorting action back.
class SortUndo {
  const SortUndo(this.message, this.undo);
  final String message;
  final Future<void> Function() undo;
}

class SortResult {
  SortResult(
    this.id,
    this.undo, {
    this.already = false,
    Future<void>? persisted,
  }) : persisted = persisted ?? Future<void>.value();

  /// Completes when the change is safely on disk. The change itself is
  /// already visible and can be undone at once; this is for callers that
  /// must be sure (a test, closing the app).
  final Future<void> persisted;

  /// The note or task made (or the folder filed into).
  final String? id;
  final SortUndo undo;

  /// It had been done before: nothing new was made.
  final bool already;
}

class CaptureSorter {
  CaptureSorter(this.ws, this.repo);

  final Workspace ws;
  final LibraryRepository repo;

  static String convRelation(String kind, String objectId) =>
      'conv.$kind.$objectId';
  static String archRelation(String objectId) => 'arch.$objectId';

  Iterable<LibraryRelation> _relations(String objectId) =>
      ws.libraryRelations.all.where((r) => r.objectId == objectId);

  CaptureState stateOf(String objectId) {
    final rels = _relations(objectId).toList();
    if (rels.any((r) => r.kind == 'archived')) return CaptureState.archived;
    if (rels.any((r) => r.kind == 'converted' && _targetExists(r))) {
      return CaptureState.converted;
    }
    final filed = rels.any(
      (r) =>
          r.kind == 'space' &&
          ws.librarySpaces[r.targetId]?.kind == LibrarySpaceKind.regular,
    );
    return filed ? CaptureState.filed : CaptureState.unfiled;
  }

  bool _targetExists(LibraryRelation r) {
    final type = r.value['type'];
    return switch (type) {
      'note' => ws.notes[r.targetId] != null,
      'task' => ws.tasks[r.targetId] != null,
      _ => false,
    };
  }

  /// Items in [state], newest first.
  List<LibraryObject> items(CaptureState state) {
    final list = [
      for (final o in repo.objects)
        if (stateOf(o.id) == state) o,
    ];
    list.sort(
      (a, b) => (b.lastSavedAt ?? b.createdAt).compareTo(
        a.lastSavedAt ?? a.createdAt,
      ),
    );
    return list;
  }

  Map<CaptureState, int> counts() {
    final out = {for (final s in CaptureState.values) s: 0};
    for (final o in repo.objects) {
      final s = stateOf(o.id);
      out[s] = out[s]! + 1;
    }
    return out;
  }

  // ---- filing ------------------------------------------------------------

  Future<SortResult?> file(String objectId, String spaceId) async {
    final space = ws.librarySpaces[spaceId];
    if (space == null ||
        space.kind != LibrarySpaceKind.regular ||
        ws.libraryObjects[objectId] == null) {
      return null;
    }
    final relId = '$spaceId.$objectId';
    final had = ws.libraryRelations[relId] != null;
    await repo.addToRegularSpace(spaceId, objectId);
    return SortResult(
      spaceId,
      SortUndo('Filed in “${space.name}”.', () async {
        if (!had) ws.libraryRelations.remove(relId);
      }),
      already: had,
    );
  }

  // ---- converting --------------------------------------------------------

  String _bodyOf(LibraryObject o) {
    final parts = <String>[
      if ((o.content ?? '').trim().isNotEmpty) o.content!.trim(),
      if ((o.description ?? '').trim().isNotEmpty &&
          o.description!.trim() != (o.content ?? '').trim())
        o.description!.trim(),
      if ((o.summary ?? '').trim().isNotEmpty) o.summary!.trim(),
      if ((o.sourceUrl ?? '').isNotEmpty) 'Source: ${o.sourceUrl}',
    ];
    return parts.join('\n\n');
  }

  /// Makes a note from the item (its text, its source link, its pictures and
  /// files). The item stays as it was. Doing it again returns the same note.
  Future<SortResult?> convertToNote(String objectId) async {
    final o = ws.libraryObjects[objectId];
    if (o == null || o.deleted) return null;
    final relId = convRelation('note', objectId);
    final existing = ws.libraryRelations[relId];
    if (existing != null && ws.notes[existing.targetId] != null) {
      return SortResult(
        existing.targetId,
        SortUndo('Nothing to undo.', () async {}),
        already: true,
      );
    }
    final now = DateTime.now();
    final note = Note(
      id: newId(),
      title: o.title.isEmpty ? '' : o.title,
      body: _bodyOf(o),
      assetIds: [
        for (final id in o.attachmentIds)
          if (ws.assets[id] != null) id,
      ],
      createdAt: now,
      updatedAt: now,
    );
    final relation = LibraryRelation(
      id: relId,
      objectId: objectId,
      kind: 'converted',
      targetId: note.id,
      updatedAt: now.toUtc(),
      value: const {'type': 'note'},
    );
    final persisted = ws.txn.run('Convert to note', (tx) {
      tx.put(ws.notes, note);
      tx.put(ws.libraryRelations, relation);
    });
    return SortResult(
      note.id,
      SortUndo('Made a note from “${o.title}”.', () async {
        await persisted;
        await ws.txn.run('Undo convert to note', (tx) {
          tx.remove(ws.notes, note.id);
          tx.remove(ws.libraryRelations, relId);
        });
      }),
      persisted: persisted,
    );
  }

  /// Makes a task from the item (its title, its text and source link).
  Future<SortResult?> convertToTask(String objectId) async {
    final o = ws.libraryObjects[objectId];
    if (o == null || o.deleted) return null;
    final relId = convRelation('task', objectId);
    final existing = ws.libraryRelations[relId];
    if (existing != null && ws.tasks[existing.targetId] != null) {
      return SortResult(
        existing.targetId,
        SortUndo('Nothing to undo.', () async {}),
        already: true,
      );
    }
    final now = DateTime.now();
    final task = Task(
      id: newId(),
      title: o.title.isEmpty ? 'Untitled' : o.title,
      notes: _bodyOf(o),
      assetIds: [
        for (final id in o.attachmentIds)
          if (ws.assets[id] != null) id,
      ],
      createdAt: now,
      updatedAt: now,
    );
    final relation = LibraryRelation(
      id: relId,
      objectId: objectId,
      kind: 'converted',
      targetId: task.id,
      updatedAt: now.toUtc(),
      value: const {'type': 'task'},
    );
    final persisted = ws.txn.run('Convert to task', (tx) {
      tx.put(ws.tasks, task);
      tx.put(ws.libraryRelations, relation);
    });
    return SortResult(
      task.id,
      SortUndo('Made a task from “${o.title}”.', () async {
        await persisted;
        await ws.txn.run('Undo convert to task', (tx) {
          tx.remove(ws.tasks, task.id);
          tx.remove(ws.libraryRelations, relId);
        });
      }),
      persisted: persisted,
    );
  }

  // ---- archiving ---------------------------------------------------------

  Future<SortResult?> archive(String objectId) async {
    final o = ws.libraryObjects[objectId];
    if (o == null || o.deleted) return null;
    final relId = archRelation(objectId);
    final had = ws.libraryRelations[relId] != null;
    if (!had) {
      ws.libraryRelations.put(
        LibraryRelation(
          id: relId,
          objectId: objectId,
          kind: 'archived',
          targetId: '',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    }
    return SortResult(
      null,
      SortUndo('Archived “${o.title}”.', () async {
        if (!had) ws.libraryRelations.remove(relId);
      }),
      already: had,
    );
  }

  /// Brings an archived item back (to where it was: its folders and
  /// conversions are untouched by archiving).
  Future<SortResult?> restore(String objectId) async {
    final relId = archRelation(objectId);
    final rel = ws.libraryRelations[relId];
    if (rel == null) return null;
    ws.libraryRelations.remove(relId);
    return SortResult(
      null,
      SortUndo('Restored.', () async => ws.libraryRelations.put(rel)),
    );
  }
}
