import '../data/models/canvas_models.dart';
import 'protocol.dart';

/// The parts of a canvas that sync, as plain mutable state.
class CanvasSyncState {
  CanvasSyncState({
    required this.items,
    required this.itemRevs,
    required this.tombstones,
    required this.title,
    required this.folderId,
    required this.metaRev,
  });

  List<CanvasItem> items;
  Map<String, String> itemRevs;
  Map<String, String> tombstones;
  String title;
  String? folderId;
  String? metaRev;
}

/// Data sent for a canvas's metadata record.
Map<String, dynamic> canvasMetaData(
  String title,
  String? folderId,
  List<CanvasItem> items,
) => {
  'title': title,
  'folderId': folderId,
  'order': [for (final i in items) i.id],
};

/// Applies incoming `canvases` / `canvas_items` changes for one canvas.
///
/// [isPending] says whether this device has an unsent local change for a
/// key (then the incoming version is skipped: the local one will be pushed
/// and the hub decides, preserving the loser as a conflict). Returns the
/// keys that were applied.
Set<String> applyCanvasChanges(
  CanvasSyncState s,
  String canvasId,
  List<SyncChange> changes,
  bool Function(String key, String? localRev) isPending,
) {
  final applied = <String>{};
  SyncChange? meta;
  for (final c in changes) {
    if (c.collection == 'canvases') {
      meta = c;
      continue;
    }
    final itemId = c.id.substring(c.id.indexOf('/') + 1);
    final localRev = s.itemRevs[itemId] ?? s.tombstones[itemId];
    if (localRev == c.rev) {
      applied.add(c.key); // already have exactly this version
      continue;
    }
    if (isPending(c.key, localRev)) continue;
    if (c.deleted) {
      s.items = [
        for (final i in s.items)
          if (i.id != itemId) i,
      ];
      s.itemRevs.remove(itemId);
      s.tombstones[itemId] = c.rev;
    } else {
      final CanvasItem item;
      try {
        item = CanvasItem.fromJson(c.data!);
      } catch (_) {
        continue; // unreadable (e.g. newer app version): leave it on the hub
      }
      final index = s.items.indexWhere((i) => i.id == itemId);
      s.items = index < 0 ? [...s.items, item] : ([...s.items]..[index] = item);
      s.itemRevs[itemId] = c.rev;
      s.tombstones.remove(itemId);
    }
    applied.add(c.key);
  }
  if (meta != null && !meta.deleted) {
    final localRev = s.metaRev;
    if (localRev == meta.rev) {
      applied.add(meta.key);
    } else if (!isPending(meta.key, localRev)) {
      final data = meta.data!;
      s.title = data['title'] as String? ?? s.title;
      s.folderId = data['folderId'] as String?;
      s.metaRev = meta.rev;
      final order = [...?(data['order'] as List?)?.cast<String>()];
      if (order.isNotEmpty) {
        final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
        final indexed = [
          for (var i = 0; i < s.items.length; i++) (i, s.items[i]),
        ];
        indexed.sort((a, b) {
          final ra = rank[a.$2.id], rb = rank[b.$2.id];
          if (ra != null && rb != null) return ra.compareTo(rb);
          if (ra != null) return -1;
          if (rb != null) return 1;
          return a.$1.compareTo(b.$1); // unknown to the sender: keep at the end
        });
        s.items = [for (final e in indexed) e.$2];
      }
      applied.add(meta.key);
    }
  }
  return applied;
}
