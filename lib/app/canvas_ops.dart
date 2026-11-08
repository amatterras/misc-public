// Mindmap operations that reach beyond one canvas: links to other
// mindmaps, reusable components, named version snapshots, and copying or
// moving a selection into a note or another mindmap.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import '../data/models/canvas_models.dart';
import '../data/models/record.dart';
import '../features/canvas/canvas_controller.dart';
import '../features/canvas/canvas_export.dart' show renderItemsPng;
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

int _snapshotSeq = 0;

/// A version of a canvas, kept on this device.
class CanvasSnapshot {
  const CanvasSnapshot(
    this.key,
    this.name,
    this.savedAt,
    this.itemCount, {
    this.auto = false,
    this.summary = '',
    this.damaged = false,
  });
  final String key;
  final String name;
  final DateTime savedAt;
  final int itemCount;

  /// Made by the app (not named by the user).
  final bool auto;

  /// What changed since the version before, in words.
  final String summary;

  /// Could not be read completely: listed, but never restorable.
  final bool damaged;
}

/// Rules and helpers of the Time Machine.
abstract final class TimeMachine {
  /// At most one automatic version per this long, per mindmap.
  static const autoInterval = Duration(minutes: 15);

  /// Automatic versions kept per mindmap (the newest).
  static int maxAuto = 40;

  /// Named versions kept per mindmap (the newest).
  static int maxNamed = 60;

  /// A number that changes when anything on the canvas changes.
  static int fingerprint(CanvasDocument doc) => Object.hashAll([
    for (final i in doc.items) jsonEncode(i.toJson()),
  ]);

  /// "Added 3, removed 1, changed 2" comparing [before] to [after].
  static String describe(
    CanvasDocument? before,
    CanvasDocument after, {
    String verb = '',
  }) {
    if (before == null) {
      return after.items.isEmpty ? 'Empty' : '${after.items.length} items';
    }
    final old = {for (final i in before.items) i.id: jsonEncode(i.toJson())};
    final now = {for (final i in after.items) i.id: jsonEncode(i.toJson())};
    final added = now.keys.where((k) => !old.containsKey(k)).length;
    final removed = old.keys.where((k) => !now.containsKey(k)).length;
    final changed = now.keys
        .where((k) => old.containsKey(k) && old[k] != now[k])
        .length;
    final parts = [
      if (added > 0) 'added $added',
      if (removed > 0) 'removed $removed',
      if (changed > 0) 'changed $changed',
    ];
    if (parts.isEmpty) {
      return verb.isEmpty ? 'No changes' : '$verb changes nothing';
    }
    final text = parts.join(', ');
    return verb.isEmpty
        ? '${text[0].toUpperCase()}${text.substring(1)}'
        : '$verb: $text';
  }
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
  //
  // The Time Machine for mindmaps (and note handwriting): versions kept on
  // THIS device only (never synced, so a bad sync cannot spoil them).
  //   - automatic: after meaningful changes, at most one per 15 minutes;
  //   - named: made by the user ("Save a version…");
  //   - a safety copy of the current state before every restore.
  // Retention (see TimeMachine): newest 40 automatic and 60 named versions
  // per mindmap; older ones go to the trash folder. A version only counts
  // once it has been written completely and read back.

  /// Keeps the current state of [c] as a named version (on this device).
  Future<CanvasSnapshot> saveSnapshot(CanvasController c, String name) async {
    await c.flush();
    return _writeSnapshot(c.document, name);
  }

  /// Writes [doc] as a version and checks it by reading it back. Throws if
  /// it cannot be written completely; nothing is pruned in that case.
  Future<CanvasSnapshot> _writeSnapshot(
    CanvasDocument doc,
    String name, {
    bool auto = false,
    String? summary,
  }) async {
    final now = DateTime.now();
    // The clock can repeat a value (Windows ticks coarsely): the counter keeps
    // every version's name its own, so one never overwrites another.
    final key =
        '${doc.id}~${now.microsecondsSinceEpoch}-${(_snapshotSeq++ % 1000).toString().padLeft(3, '0')}';
    final previous = (await snapshotsOf(doc.id)).where((v) => !v.damaged).firstOrNull;
    final before = previous == null ? null : await _snapshotDocument(previous.key);
    final text = summary ?? TimeMachine.describe(before, doc);
    await workspace.store.write(_snapshots, key, {
      'canvasId': doc.id,
      'name': name,
      'savedAt': utcIso(now),
      'auto': auto,
      'summary': text,
      'itemCount': doc.items.length,
      'document': doc.toJson(),
    });
    await workspace.store.flush();
    final back = await _snapshotDocument(key);
    if (back == null || back.items.length != doc.items.length) {
      throw StateError('The version could not be written completely.');
    }
    snapshotState[doc.id] = (
      at: now,
      fingerprint: TimeMachine.fingerprint(doc),
    );
    await _pruneSnapshots(doc.id);
    return CanvasSnapshot(
      key,
      name,
      now,
      doc.items.length,
      auto: auto,
      summary: text,
    );
  }

  /// Version [key] as a document, or null when it is missing or damaged.
  Future<CanvasDocument?> _snapshotDocument(String key) async {
    try {
      final json = await workspace.store.read(_snapshots, key);
      final raw = json?['document'];
      if (raw is! Map) return null;
      final doc = CanvasDocument.fromJson(raw.cast<String, dynamic>());
      final count = json?['itemCount'];
      if (count is int && count != doc.items.length) return null;
      return doc;
    } catch (_) {
      return null;
    }
  }

  /// Keeps the newest [TimeMachine.maxAuto] automatic and
  /// [TimeMachine.maxNamed] named versions of [canvasId]; the rest move to
  /// the trash folder.
  Future<void> _pruneSnapshots(String canvasId) async {
    final all = await snapshotsOf(canvasId);
    var auto = 0, named = 0;
    for (final v in all) {
      final keep = v.auto
          ? ++auto <= TimeMachine.maxAuto
          : ++named <= TimeMachine.maxNamed;
      if (!keep) {
        try {
          await workspace.store.moveToTrash(_snapshots, v.key);
        } catch (_) {
          // Left in place; the next save tries again.
        }
      }
    }
  }

  /// Makes an automatic version after meaningful changes (called after a
  /// mindmap was saved). Quiet: a failure only means no version this time.
  Future<void> autoSnapshot(CanvasDocument doc) async {
    if (doc.items.isEmpty) return;
    final fp = TimeMachine.fingerprint(doc);
    var state = snapshotState[doc.id];
    if (state == null) {
      final newest = (await snapshotsOf(doc.id)).where((v) => !v.damaged).firstOrNull;
      final d = newest == null ? null : await _snapshotDocument(newest.key);
      state = (
        at: newest?.savedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        fingerprint: d == null ? 0 : TimeMachine.fingerprint(d),
      );
      snapshotState[doc.id] = state;
    }
    if (state.fingerprint == fp) return;
    if (DateTime.now().difference(state.at) < TimeMachine.autoInterval) return;
    try {
      await _writeSnapshot(doc, 'Automatic version', auto: true);
    } catch (_) {
      // No version this time.
    }
  }

  /// The versions kept of canvas [canvasId], newest first. A version that
  /// cannot be read completely is listed as damaged (and cannot be restored).
  Future<List<CanvasSnapshot>> snapshotsOf(String canvasId) async {
    final result = <CanvasSnapshot>[];
    for (final key in await workspace.store.list(_snapshots)) {
      if (!key.startsWith('$canvasId~')) continue;
      final json = await workspace.store.read(_snapshots, key);
      if (json == null) continue;
      final items = (json['document'] as Map?)?['items'];
      final count = json['itemCount'];
      final ok = items is List && (count is! int || count == items.length);
      result.add(
        CanvasSnapshot(
          key,
          json['name'] as String? ?? 'Version',
          parseDate(json['savedAt']) ?? DateTime(2000),
          items is List ? items.length : 0,
          auto: json['auto'] == true,
          summary: json['summary'] as String? ?? '',
          damaged: !ok,
        ),
      );
    }
    return result..sort((a, b) => b.savedAt.compareTo(a.savedAt));
  }

  /// A small picture of version [key] for previewing (the current mindmap
  /// is not touched). Null if it cannot be read.
  Future<Uint8List?> snapshotPreview(String key, {double maxSide = 420}) async {
    final doc = await _snapshotDocument(key);
    if (doc == null || doc.items.isEmpty) return null;
    final c = CanvasController(
      document: doc,
      onSave: (_) async {},
      resources: resources,
    );
    try {
      return await renderItemsPng(c, maxSide: maxSide, margin: 16);
    } finally {
      c.dispose();
    }
  }

  /// What restoring [key] onto [c] would change, in words (nothing is
  /// changed by asking).
  Future<String?> restoreSummary(CanvasController c, String key) async {
    final doc = await _snapshotDocument(key);
    if (doc == null) return null;
    return TimeMachine.describe(c.document, doc, verb: 'Restoring');
  }

  /// Puts version [key] back on [c]: every item, position, size, tag and
  /// connection as it was. First the current state is kept as a version
  /// ("Before restoring…"); if that cannot be written, nothing is restored.
  /// One undo step, saved and synced like an edit. False if the version
  /// cannot be read or the safety copy failed (then nothing changes).
  Future<bool> restoreSnapshot(CanvasController c, String key) async {
    final doc = await _snapshotDocument(key);
    if (doc == null || doc.id != c.id) return false;
    final name = (await snapshotsOf(c.id))
        .where((v) => v.key == key)
        .map((v) => v.name)
        .firstOrNull;
    try {
      await c.flush();
      await _writeSnapshot(
        c.document,
        'Before restoring “${name ?? 'a version'}”',
        auto: true,
        summary: 'Safety copy made before a restore.',
      );
    } catch (_) {
      return false;
    }
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
    final target = openNotebookFor(id) != null
        ? openNotebookFor(id)!
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
        openNotebooks.contains(target) ||
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
