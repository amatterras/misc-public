// Settling sync conflicts safely.
//
// A conflict record (made by the hub when two devices changed the same
// record) holds the version that lost. Nothing here deletes it:
//
//  * "Keep the current version" and "Use the other version" both mark the
//    record as settled and leave BOTH versions inside it (`otherData`, and
//    `replaced` when the other version was put in place).
//  * A settling can be taken back ([reopen]) until the record is pruned, 90
//    days after it was settled.
//  * An unsettled conflict is never touched by anything except the user.
//
// Putting the other version in place is an ordinary edit (new revision), so
// it syncs and wins over both earlier versions on every device.
import '../app/app_state.dart';
import '../data/models/sync_models.dart';

/// What a conflict is about, for showing it.
class ConflictSides {
  const ConflictSides({
    required this.current,
    required this.other,
    required this.currentDeleted,
    required this.otherDeleted,
  });

  /// The version in place now (null if the record is gone).
  final Map<String, dynamic>? current;

  /// The preserved version (null if it was a deletion).
  final Map<String, dynamic>? other;
  final bool currentDeleted;
  final bool otherDeleted;
}

class ConflictResolver {
  ConflictResolver(this.state);

  final AppState state;

  /// How long a settled conflict (with both versions) is kept.
  static const settledKeepFor = Duration(days: 90);

  /// Conflicts waiting for the user.
  List<SyncConflict> open() =>
      state.workspace.conflicts.all.where((c) => !c.isResolved).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// Conflicts the user settled (still holding both versions).
  List<SyncConflict> settled() =>
      state.workspace.conflicts.all.where((c) => c.isResolved).toList()..sort(
        (a, b) => (b.resolvedAt ?? b.updatedAt).compareTo(
          a.resolvedAt ?? a.updatedAt,
        ),
      );

  bool _isCanvasItem(SyncConflict c) => c.collection == 'canvas_items';

  /// Whether the other version can be put in place from here. Canvas titles
  /// and item order (`canvases`) are shown but not restored: they are a
  /// whole-canvas setting, and the notebook's pages are merged on their own.
  bool canUseOther(SyncConflict c) {
    if (c.collection == 'conflicts') return false;
    if (_isCanvasItem(c)) {
      return c.recordId.contains('/') &&
          (c.otherDeleted || c.otherData != null);
    }
    return state.workspace.syncCollections.containsKey(c.collection) &&
        (c.otherDeleted || c.otherData != null);
  }

  /// The version in place now and the preserved one.
  Future<ConflictSides> sides(SyncConflict c) async {
    Map<String, dynamic>? current;
    if (_isCanvasItem(c)) {
      final slash = c.recordId.indexOf('/');
      if (slash > 0) {
        current = await state.canvasItemJson(
          c.recordId.substring(0, slash),
          c.recordId.substring(slash + 1),
        );
      }
    } else if (c.collection == 'canvases') {
      current = null; // metadata: shown from the conflict only
    } else {
      final collection = state.workspace.syncCollections[c.collection];
      current = collection?.jsonOf(c.recordId);
    }
    return ConflictSides(
      current: current,
      other: c.otherData,
      currentDeleted: current == null,
      otherDeleted: c.otherDeleted,
    );
  }

  /// "Keep the current version": nothing about the record changes; the
  /// preserved version stays in the settled conflict.
  void keepCurrent(SyncConflict c) {
    state.workspace.conflicts.put(
      c.settled('kept_current', at: DateTime.now()),
    );
  }

  /// "Use the other version": puts the preserved version in place (or
  /// deletes the record, if the other side deleted it) as a new edit, and
  /// keeps the version it replaces inside the settled conflict. Returns
  /// false (nothing changed) when it cannot be done from here.
  Future<bool> useOther(SyncConflict c) async {
    if (!canUseOther(c)) return false;
    final now = await sides(c);
    final replaced = now.current;
    final ok = await _put(c, c.otherDeleted ? null : c.otherData);
    if (!ok) return false;
    state.workspace.conflicts.put(
      c.settled(
        'used_other',
        at: DateTime.now(),
        replaced: replaced,
        replacedDeleted: replaced == null,
      ),
    );
    return true;
  }

  /// Takes a settling back: for "used other" the replaced version is put in
  /// place again (a new edit); the conflict becomes open again.
  Future<bool> reopen(SyncConflict c) async {
    if (!c.isResolved) return true;
    if (c.choice == 'used_other') {
      final ok = await _put(c, c.replacedWasDeleted ? null : c.replacedData);
      if (!ok) return false;
    }
    state.workspace.conflicts.put(c.reopened());
    return true;
  }

  /// Puts [json] in place of the record (null deletes it).
  Future<bool> _put(SyncConflict c, Map<String, dynamic>? json) async {
    if (_isCanvasItem(c)) {
      final slash = c.recordId.indexOf('/');
      if (slash <= 0) return false;
      return state.restoreCanvasItem(
        c.recordId.substring(0, slash),
        c.recordId.substring(slash + 1),
        json,
      );
    }
    final collection = state.workspace.syncCollections[c.collection];
    if (collection == null) return false;
    try {
      if (json == null) {
        collection.remove(c.recordId);
      } else {
        collection.put(collection.fromJson(json));
      }
    } catch (_) {
      return false; // unreadable here (for example written by a newer app)
    }
    return true;
  }

  /// Removes settled conflicts older than [settledKeepFor]. Only ones the
  /// user settled; an open conflict is never pruned. Returns how many.
  int pruneSettled({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(settledKeepFor);
    var n = 0;
    for (final c in settled()) {
      final at = c.resolvedAt;
      if (at != null && at.isBefore(cutoff)) {
        state.workspace.conflicts.remove(c.id);
        n++;
      }
    }
    return n;
  }
}
