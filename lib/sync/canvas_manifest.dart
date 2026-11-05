// A cache of the revisions inside every canvas file, so a sync cycle does not
// have to open and parse every canvas just to learn that nothing changed.
//
// What it is: for each canvas, its metadata revision, the revision of each
// item, and its item tombstones (no item data), plus a fingerprint of the
// canvas file (size and modification time of the file and of its previous
// version). What it is NOT: a source of truth. The canvas files are. A
// cache entry is believed only while the fingerprint of the file still
// matches AND nothing wrote that file through this app since (the store tells
// us). Anything else, a missing, damaged or older manifest included, simply
// means "read that canvas again", which is exactly what every cycle used to
// do for all canvases. So a stale or lost manifest can cost time, never
// correctness, and it can never hide a change.
//
// Writes to the manifest file are atomic (the JsonFileStore way: temporary
// file, rename, previous copy kept); if one fails, the cache stays in memory
// and the next refresh tries again.
import '../data/models/canvas_models.dart';
import '../data/storage/app_log.dart';
import '../data/storage/json_file_store.dart';

/// The revisions in one canvas: what sync needs to decide "pending".
class CanvasRevs {
  CanvasRevs({
    required this.id,
    required this.metaRev,
    required this.itemRevs,
    required this.tombstones,
    required this.fingerprint,
  });

  /// Entry for [doc] exactly as the sync engine enumerates it: the metadata
  /// stamp, each item that has a stamp, and the item tombstones.
  factory CanvasRevs.of(CanvasDocument doc, String? fingerprint) => CanvasRevs(
    id: doc.id,
    metaRev: doc.metaRev,
    itemRevs: {
      for (final item in doc.items)
        if (doc.itemRevs[item.id] != null) item.id: doc.itemRevs[item.id]!,
    },
    tombstones: {...doc.tombstones},
    fingerprint: fingerprint,
  );

  factory CanvasRevs.fromJson(String id, Map<String, dynamic> j) => CanvasRevs(
    id: id,
    metaRev: j['m'] as String?,
    itemRevs: {...(j['i'] as Map).cast<String, String>()},
    tombstones: {...(j['t'] as Map).cast<String, String>()},
    fingerprint: j['f'] as String?,
  );

  final String id;
  final String? metaRev;

  /// Item id → stamp, for items that exist in the canvas.
  final Map<String, String> itemRevs;

  /// Item id → deletion stamp.
  final Map<String, String> tombstones;

  /// The canvas file when this was read; null = not trustworthy (the file
  /// was changing while it was read), so it is read again next time.
  final String? fingerprint;

  /// Sync keys and stamps in this canvas (`canvases/<id>`,
  /// `canvas_items/<id>/<item>`), with tombstones included.
  Iterable<(String key, String rev)> get versions sync* {
    final m = metaRev;
    if (m != null) yield ('canvases/$id', m);
    for (final e in itemRevs.entries) {
      yield ('canvas_items/$id/${e.key}', e.value);
    }
    for (final e in tombstones.entries) {
      yield ('canvas_items/$id/${e.key}', e.value);
    }
  }

  /// Whether any version here differs from what the remote last confirmed
  /// (`base`), i.e. the canvas has something to send.
  bool hasPending(Map<String, String> base) {
    for (final (key, rev) in versions) {
      if (base[key] != rev) return true;
    }
    return false;
  }

  /// Same revisions (the fingerprint is not part of the content).
  bool sameContentAs(CanvasRevs other) =>
      metaRev == other.metaRev &&
      _same(itemRevs, other.itemRevs) &&
      _same(tombstones, other.tombstones);

  static bool _same(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
    'm': ?metaRev,
    'i': itemRevs,
    't': tombstones,
    'f': ?fingerprint,
  };
}

class CanvasManifest {
  CanvasManifest({
    required this.store,
    required this.metaStore,
    required this.load,
    this.collection = 'canvases',
    this.verifyEvery = const Duration(hours: 24),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How long a verified manifest is trusted before it is checked against
  /// every canvas file again.
  final Duration verifyEvery;
  final DateTime Function() _now;
  DateTime? _verifiedAt;

  /// True until the manifest has been checked against the files in this run,
  /// and again once a day. The check is a full read (what every cycle used
  /// to cost), so it is rare.
  bool get dueForVerify =>
      _verifiedAt == null || _now().difference(_verifiedAt!) >= verifyEvery;

  /// Where the canvas files live.
  final JsonFileStore store;

  /// Where the manifest itself is kept (the workspace's store).
  final JsonFileStore metaStore;

  /// Reads one canvas (null if it cannot be read).
  final Future<CanvasDocument?> Function(String id) load;
  final String collection;

  static const _file = ('sync', 'canvas_manifest');
  static const _version = 1;

  final Map<String, CanvasRevs> _entries = {};

  /// Canvases written (or deleted) through this store since the last refresh
  /// looked: their entry is not believed whatever their fingerprint says.
  final Set<String> _dirty = {};
  bool _loaded = false;
  bool _listening = false;

  /// For tests and the benchmark: how many canvas files were read by the
  /// last [refresh] / [verify].
  int lastReads = 0;

  /// How many entries the last [verify] found wrong (and repaired).
  int lastMismatches = 0;

  /// Canvas files read since this object was made (refreshes and checks).
  int readsTotal = 0;

  void _listen() {
    if (_listening) return;
    _listening = true;
    store.addWriteListener((c, id) {
      if (c == collection) _dirty.add(id);
    });
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _listen();
    _loaded = true;
    try {
      final json = await metaStore.read(_file.$1, _file.$2);
      if (json == null || json['v'] != _version) return;
      final entries = json['c'];
      if (entries is! Map) return;
      for (final e in entries.entries) {
        try {
          _entries[e.key as String] = CanvasRevs.fromJson(
            e.key as String,
            (e.value as Map).cast<String, dynamic>(),
          );
        } catch (_) {
          // One damaged entry only costs one canvas being read again.
        }
      }
    } catch (e) {
      // Anything odd about the file: start empty (every canvas is read).
      _entries.clear();
      AppLog.warn('Canvas manifest could not be read; rebuilding it ($e)');
    }
  }

  Future<void> _persist() async {
    try {
      await metaStore.write(_file.$1, _file.$2, {
        'v': _version,
        'c': {for (final e in _entries.entries) e.key: e.value.toJson()},
      });
    } catch (e) {
      AppLog.warn('Canvas manifest could not be saved ($e)');
    }
  }

  /// Brings the cache up to date and returns the revisions of every canvas.
  /// Reads only canvases that are new, changed (fingerprint), written through
  /// the store since last time, or whose entry was not trustworthy.
  Future<Map<String, CanvasRevs>> refresh() async {
    await _ensureLoaded();
    final ids = (await store.list(collection)).toSet();
    // Take the dirty set first: a write that lands while we read is noticed
    // by the next refresh, never lost.
    final dirtyNow = {..._dirty};
    _dirty.removeAll(dirtyNow);
    var changed = false;
    var reads = 0;
    for (final gone in _entries.keys.where((k) => !ids.contains(k)).toList()) {
      _entries.remove(gone);
      changed = true;
    }
    for (final id in ids) {
      final before = await store.fingerprint(collection, id);
      final known = _entries[id];
      if (known != null &&
          before != null &&
          known.fingerprint == before &&
          !dirtyNow.contains(id)) {
        continue;
      }
      reads++;
      final doc = await load(id);
      if (doc == null) {
        if (_entries.remove(id) != null) changed = true;
        continue;
      }
      final after = await store.fingerprint(collection, id);
      // A file that changed while it was being read is not cached as stable.
      final entry = CanvasRevs.of(doc, before == after ? after : null);
      if (known == null ||
          !known.sameContentAs(entry) ||
          known.fingerprint != entry.fingerprint) {
        changed = true;
      }
      _entries[id] = entry;
    }
    lastReads = reads;
    readsTotal += reads;
    if (changed) await _persist();
    return Map.unmodifiable(_entries);
  }

  /// Compares every cached entry with a fresh read of its file, repairs any
  /// difference, and returns how many were wrong. The safety net for the
  /// cases a fingerprint cannot see (and for a manifest of unknown origin).
  Future<int> verify() async {
    await _ensureLoaded();
    final ids = (await store.list(collection)).toSet();
    _dirty.clear();
    var wrong = 0;
    var reads = 0;
    for (final gone in _entries.keys.where((k) => !ids.contains(k)).toList()) {
      _entries.remove(gone);
      wrong++;
    }
    for (final id in ids) {
      final before = await store.fingerprint(collection, id);
      reads++;
      final doc = await load(id);
      final known = _entries[id];
      if (doc == null) {
        if (_entries.remove(id) != null) wrong++;
        continue;
      }
      final after = await store.fingerprint(collection, id);
      final entry = CanvasRevs.of(doc, before == after ? after : null);
      if (known == null || !known.sameContentAs(entry)) wrong++;
      _entries[id] = entry;
    }
    lastReads = reads;
    readsTotal += reads;
    lastMismatches = wrong;
    _verifiedAt = _now();
    if (wrong > 0) {
      AppLog.warn(
        'Canvas manifest was out of date for $wrong canvas(es); repaired',
      );
    }
    await _persist();
    return wrong;
  }

  /// Forgets everything (the next refresh reads every canvas).
  Future<void> reset() async {
    _entries.clear();
    _dirty.clear();
    _loaded = true;
    _listen();
    await _persist();
  }
}
