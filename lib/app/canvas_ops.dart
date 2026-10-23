// Mindmap operations that reach beyond one canvas: links to other
// mindmaps, reusable components, named version snapshots, and copying or
// moving a selection into a note or another mindmap.
import 'dart:ui';

import '../data/models/canvas_models.dart';
import '../data/models/record.dart';
import '../features/canvas/canvas_controller.dart';
import 'app_state.dart';

/// Links to another mindmap are link cards with this address.
const canvasLinkPrefix = 'theapp://canvas/';

/// The mindmap a link card points to, or null for an ordinary link.
String? canvasLinkTarget(String? url) =>
    url != null && url.startsWith(canvasLinkPrefix)
    ? url.substring(canvasLinkPrefix.length)
    : null;

/// A saved component: its items, as stored.
class CanvasComponent {
  const CanvasComponent(this.id, this.name, this.items, this.marks);
  final String id;
  final String name;
  final List<CanvasItem> items;
  final Map<String, Map<String, dynamic>> marks;
}

/// A named version of a canvas, kept on this device.
class CanvasSnapshot {
  const CanvasSnapshot(this.key, this.name, this.savedAt, this.itemCount);
  final String key;
  final String name;
  final DateTime savedAt;
  final int itemCount;
}

extension CanvasOps on AppState {
  static const _snapshots = 'canvas_snapshots';
  static const _componentMark = 'component';
  static const _componentNameMark = 'componentName';

  // ------------------------------------------------------------ links --

  /// Puts a card on [c] at [at] that opens mindmap [targetId].
  LinkItem? linkToCanvas(CanvasController c, String targetId, Offset at) {
    final target = canvasList.where((x) => x.id == targetId).firstOrNull;
    if (target == null) return null;
    final asset = workspace.linkAsset(
      '$canvasLinkPrefix$targetId',
      title: target.title,
    );
    return c.insertLink(asset, at);
  }

  /// Mindmaps that show a card of note [noteId] (its incoming canvas links).
  Future<List<CanvasSummary>> canvasesShowingNote(String noteId) async {
    final result = <CanvasSummary>[];
    for (final summary in canvasList) {
      final items = canvas?.id == summary.id
          ? canvas!.items
          : (await canvases.load(summary.id))?.items ?? const <CanvasItem>[];
      if (items.any((i) => i is NoteCardItem && i.noteId == noteId)) {
        result.add(summary);
      }
    }
    return result;
  }

  // ------------------------------------------------------- components --

  /// Saves copies of [items] (with their tags, locks and groups) as a
  /// component called [name]. The originals are not changed.
  Future<String> saveComponent(
    String name,
    List<CanvasItem> items,
    Map<String, Map<String, dynamic>> marks,
  ) async {
    final store = await openComponents();
    final id = newId();
    // Each component gets its own row in the document.
    var bottom = 0.0;
    for (final i in store.items) {
      final b = store.itemBounds(i);
      if (b.bottom > bottom) bottom = b.bottom;
    }
    final area = _boundsOf(store, items);
    final (copies, ids) = CanvasController.copyItems(
      items,
      Offset(-area.left, bottom + 80 - area.top),
    );
    store.addItemsWithMarks(copies, {
      for (final copy in copies)
        copy.id: {
          ...?marks[ids.entries
              .where((e) => e.value == copy.id)
              .firstOrNull
              ?.key],
          _componentMark: id,
          _componentNameMark: name,
        },
    });
    store.select(const []);
    await store.flush();
    return id;
  }

  /// The saved components, by name.
  Future<List<CanvasComponent>> components() async {
    final store = await openComponents();
    final byId = <String, List<CanvasItem>>{};
    final names = <String, String>{};
    for (final item in store.items) {
      final id = store.markOf(item.id, _componentMark);
      if (id is! String) continue;
      byId.putIfAbsent(id, () => []).add(item);
      final name = store.markOf(item.id, _componentNameMark);
      if (name is String) names[id] = name;
    }
    return [
      for (final e in byId.entries)
        CanvasComponent(
          e.key,
          names[e.key] ?? 'Component',
          e.value,
          store.marksOf(e.value.map((i) => i.id)),
        ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Puts a fresh copy of [component] on [c], centred on [at]. The saved
  /// component is not changed.
  void insertComponent(
    CanvasController c,
    CanvasComponent component,
    Offset at,
  ) {
    final area = _boundsOf(c, component.items);
    final (copies, ids) = CanvasController.copyItems(
      component.items,
      at - area.center,
    );
    final group = newId();
    c.addItemsWithMarks(copies, {
      for (final e in ids.entries)
        e.value:
            {
                ...?component.marks[e.key],
                // A component lands as one group; the bookkeeping marks of the
                // saved copy are not carried along.
                CanvasController.groupMark: group,
              }
              ..remove(_componentMark)
              ..remove(_componentNameMark),
    });
  }

  Future<void> deleteComponent(String componentId) async {
    final store = await openComponents();
    store.select([
      for (final i in store.items)
        if (store.markOf(i.id, _componentMark) == componentId) i.id,
    ]);
    store.deleteSelection();
    await store.flush();
  }

  // -------------------------------------------------------- snapshots --

  /// Keeps the current state of [c] as a named version (on this device).
  Future<CanvasSnapshot> saveSnapshot(CanvasController c, String name) async {
    await c.flush();
    final now = DateTime.now();
    final key = '${c.id}~${now.microsecondsSinceEpoch}';
    final doc = c.document;
    await workspace.store.write(_snapshots, key, {
      'canvasId': c.id,
      'name': name,
      'savedAt': utcIso(now),
      'document': doc.toJson(),
    });
    return CanvasSnapshot(key, name, now, doc.items.length);
  }

  /// The versions kept of canvas [canvasId], newest first.
  Future<List<CanvasSnapshot>> snapshotsOf(String canvasId) async {
    final result = <CanvasSnapshot>[];
    for (final key in await workspace.store.list(_snapshots)) {
      if (!key.startsWith('$canvasId~')) continue;
      final json = await workspace.store.read(_snapshots, key);
      if (json == null) continue;
      final items = (json['document'] as Map?)?['items'];
      result.add(
        CanvasSnapshot(
          key,
          json['name'] as String? ?? 'Version',
          parseDate(json['savedAt']) ?? DateTime(2000),
          items is List ? items.length : 0,
        ),
      );
    }
    return result..sort((a, b) => b.savedAt.compareTo(a.savedAt));
  }

  /// Puts version [key] back on [c]: every item, position, size, tag and
  /// connection as it was. One undo step, saved and synced like an edit.
  /// False if the version cannot be read (then nothing changes).
  Future<bool> restoreSnapshot(CanvasController c, String key) async {
    final json = await workspace.store.read(_snapshots, key);
    final raw = json?['document'];
    if (raw is! Map) return false;
    final CanvasDocument doc;
    try {
      doc = CanvasDocument.fromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return false;
    }
    if (doc.id != c.id) return false;
    c.replaceAllItems(doc.items, doc.itemUnknownFields);
    return true;
  }

  // ------------------------------------------------- copy / move away --

  /// Copies [items] of [from] onto note [noteId]'s pages (below what is
  /// there), keeping their look. With [move], they leave [from] (one undo
  /// step there). Returns how many were placed.
  Future<int> copyToNote(
    CanvasController from,
    List<CanvasItem> items,
    String noteId, {
    bool move = false,
  }) async {
    // Locked items cannot leave their canvas, so moving them would copy.
    if (move) {
      items = [
        for (final i in items)
          if (!from.isLocked(i.id)) i,
      ];
    }
    if (!workspace.notes.contains(noteId) || items.isEmpty) return 0;
    final id = notebookIdFor(noteId);
    final target = openNotebook?.id == id
        ? openNotebook!
        : await _temporary(
            id,
            'notebook',
            workspace.notes[noteId]!.displayTitle,
          );
    var bottom = 0.0;
    for (final i in target.items) {
      final b = target.itemBounds(i);
      if (b.bottom > bottom) bottom = b.bottom;
    }
    final area = _boundsOf(from, items);
    final placed = _place(
      target,
      items,
      from.marksOf(items.map((i) => i.id)),
      Offset(40 - area.left, bottom + 40 - area.top),
    );
    await _finish(target, from, items, move);
    return placed;
  }

  /// Copies (or with [move] moves) [items] of [from] to mindmap
  /// [canvasId], into empty space to the right of its content.
  Future<int> copyToCanvas(
    CanvasController from,
    List<CanvasItem> items,
    String canvasId, {
    bool move = false,
  }) async {
    if (move) {
      items = [
        for (final i in items)
          if (!from.isLocked(i.id)) i,
      ];
    }
    if (items.isEmpty || canvasId == from.id) return 0;
    final summary = canvasList.where((c) => c.id == canvasId).firstOrNull;
    if (summary == null) return 0;
    final target = canvas?.id == canvasId
        ? canvas!
        : await _temporary(canvasId, null, summary.title);
    var right = 0.0;
    for (final i in target.items) {
      final b = target.itemBounds(i);
      if (b.right > right) right = b.right;
    }
    final area = _boundsOf(from, items);
    final placed = _place(
      target,
      items,
      from.marksOf(items.map((i) => i.id)),
      Offset(right + 80 - area.left, -area.top),
    );
    await _finish(target, from, items, move);
    return placed;
  }

  int _place(
    CanvasController target,
    List<CanvasItem> items,
    Map<String, Map<String, dynamic>> marks,
    Offset delta,
  ) {
    final (copies, ids) = CanvasController.copyItems(items, delta);
    target.addItemsWithMarks(copies, {
      for (final e in ids.entries) e.value: ?marks[e.key],
    });
    target.select(const []);
    return copies.length;
  }

  Future<void> _finish(
    CanvasController target,
    CanvasController from,
    List<CanvasItem> items,
    bool move,
  ) async {
    await target.flush();
    final keepOpen =
        identical(target, openNotebook) ||
        identical(target, canvas) ||
        identical(target, linksBoard);
    if (!keepOpen) target.dispose();
    if (move) {
      from.select(items.map((i) => i.id));
      from.deleteSelection();
    }
  }

  /// A controller for a document that is not open on screen (saved and
  /// let go by [_finish]).
  Future<CanvasController> _temporary(
    String id,
    String? kind,
    String title,
  ) async {
    final doc =
        await canvases.load(id) ??
        CanvasDocument(
          id: id,
          title: title,
          items: const [],
          updatedAt: DateTime.now(),
          kind: kind,
        );
    return CanvasController(
      document: doc,
      onSave: saveDocument,
      resources: resources,
      clock: workspace.clock,
    );
  }

  static Rect _boundsOf(CanvasController c, List<CanvasItem> items) {
    Rect? r;
    for (final i in items) {
      if (i is ConnectorItem) continue;
      final b = c.itemBounds(i);
      r = r == null ? b : r.expandToInclude(b);
    }
    return r ?? Rect.zero;
  }
}
