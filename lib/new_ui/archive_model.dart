// What the New Archive shows, computed from the existing library data
// (LibrarySpace folders, LibraryObject items and their 'space' relations).
// No second store: folder colour, pinning, order and nesting are additive
// fields of LibrarySpace; items are the library objects themselves.
import '../data/models/object_library_models.dart';
import '../data/repositories/library_repository.dart';
import '../data/workspace.dart';
import 'new_folder_colors.dart';

/// Id of the virtual collection that holds items not filed in any folder.
const unfiledId = '_unfiled';

class ArchiveCollection {
  const ArchiveCollection({
    required this.id,
    required this.name,
    required this.items,
    this.space,
  });

  final String id;
  final String name;

  /// Null for the virtual "Unfiled" collection.
  final LibrarySpace? space;

  /// Newest saved first.
  final List<LibraryObject> items;

  bool get virtual => space == null;
  int get total => items.length;

  /// How many previews the collapsed card shows in front (about two).
  static const visibleCount = 2;

  int get visible => total < visibleCount ? total : visibleCount;

  /// The "2/5" label: previews in front out of everything saved here. Not a
  /// page number.
  String get countLabel => '$visible/$total';

  /// Previews peeking out behind the front ones (at most three).
  int get hidden => (total - visible).clamp(0, 3);

  FolderColor get color =>
      NewFolderColors.byId(space?.colorId) ?? NewFolderColors.all.first;
}

abstract final class ArchiveModel {
  /// Folders under [parentId] (null = top level): pinned first, then manual
  /// order, then by name. Smart spaces are folders too.
  static List<LibrarySpace> folders(Workspace ws, {String? parentId}) {
    final list = [
      for (final s in ws.librarySpaces.all)
        if (s.parentId == parentId) s,
    ];
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final ao = a.sortOrder, bo = b.sortOrder;
      if (ao != null && bo != null && ao != bo) return ao.compareTo(bo);
      if ((ao == null) != (bo == null)) return ao == null ? 1 : -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  static List<LibraryObject> _newestFirst(Iterable<LibraryObject> items) {
    final list = items.toList();
    list.sort((a, b) {
      final at = a.lastSavedAt ?? a.createdAt;
      final bt = b.lastSavedAt ?? b.createdAt;
      return bt.compareTo(at);
    });
    return list;
  }

  static ArchiveCollection collection(LibraryRepository repo, LibrarySpace s) =>
      ArchiveCollection(
        id: s.id,
        name: s.name,
        space: s,
        items: _newestFirst(repo.inSpace(s.id)),
      );

  /// Items that are not in any regular folder.
  static ArchiveCollection unfiled(LibraryRepository repo, Workspace ws) {
    final filed = <String>{
      for (final r in ws.libraryRelations.all)
        if (r.kind == 'space' &&
            ws.librarySpaces[r.targetId]?.kind == LibrarySpaceKind.regular)
          r.objectId,
    };
    return ArchiveCollection(
      id: unfiledId,
      name: 'Unfiled',
      items: _newestFirst(repo.objects.where((o) => !filed.contains(o.id))),
    );
  }

  /// The landing page's cards, in order. The virtual Unfiled collection is
  /// last and only present when it has something in it.
  static List<ArchiveCollection> landing(LibraryRepository repo, Workspace ws) {
    final result = [for (final s in folders(ws)) collection(repo, s)];
    final rest = unfiled(repo, ws);
    if (rest.total > 0) result.add(rest);
    return result;
  }

  /// Gives every folder without a colour one: a palette colour that differs
  /// from the folders next to it. Saved, so it never changes again.
  /// Returns true when something was assigned.
  static bool ensureColors(Workspace ws) {
    var changed = false;
    final siblingsOf = <String?, List<LibrarySpace>>{};
    for (final s in ws.librarySpaces.all) {
      (siblingsOf[s.parentId] ??= []).add(s);
    }
    for (final parent in siblingsOf.keys) {
      final ordered = folders(ws, parentId: parent);
      final colours = [for (final s in ordered) s.colorId];
      for (var i = 0; i < ordered.length; i++) {
        if (colours[i] != null) continue;
        final pick = NewFolderColors.assign(
          neighbours: [
            if (i > 0) colours[i - 1],
            if (i + 1 < colours.length) colours[i + 1],
          ],
          existing: colours,
        );
        colours[i] = pick.id;
        ws.librarySpaces.put(ordered[i].copyWith(colorId: pick.id));
        changed = true;
      }
    }
    return changed;
  }

  /// Puts [draggedId] right before [targetId] among their siblings and
  /// renumbers them (so the order is explicit and stable).
  static void moveBefore(Workspace ws, String draggedId, String targetId) {
    final dragged = ws.librarySpaces[draggedId];
    final target = ws.librarySpaces[targetId];
    if (dragged == null || target == null || draggedId == targetId) return;
    final siblings = folders(ws, parentId: target.parentId)
      ..removeWhere((s) => s.id == draggedId);
    final at = siblings.indexWhere((s) => s.id == targetId);
    siblings.insert(at < 0 ? siblings.length : at, dragged);
    for (var i = 0; i < siblings.length; i++) {
      final s = siblings[i];
      final updated = s.copyWith(
        sortOrder: i * 10,
        parentId: s.id == draggedId ? () => target.parentId : null,
      );
      if (updated.sortOrder != s.sortOrder || s.id == draggedId) {
        ws.librarySpaces.put(updated);
      }
    }
  }

  /// Moves a folder up or down by one place among its siblings.
  static void nudge(Workspace ws, String id, int by) {
    final space = ws.librarySpaces[id];
    if (space == null) return;
    final siblings = folders(ws, parentId: space.parentId);
    final from = siblings.indexWhere((s) => s.id == id);
    final to = from + by;
    if (from < 0 || to < 0 || to >= siblings.length) return;
    final other = siblings[to];
    if (by < 0) {
      moveBefore(ws, id, other.id);
    } else if (to + 1 < siblings.length) {
      moveBefore(ws, id, siblings[to + 1].id);
    } else {
      final moved = siblings..removeAt(from);
      moved.add(space);
      for (var i = 0; i < moved.length; i++) {
        ws.librarySpaces.put(moved[i].copyWith(sortOrder: i * 10));
      }
    }
  }
}
