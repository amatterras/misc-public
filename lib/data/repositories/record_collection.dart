import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/record.dart';
import '../storage/app_log.dart';
import '../storage/json_file_store.dart';
import '../sync/sync_clock.dart';

/// An in-memory set of records of one type, saved as one JSON file.
///
/// Screens read and write through this class only. Saving is debounced and
/// crash-safe (see [JsonFileStore]).
///
/// For future sync every record carries a revision stamp from [clock]
/// (bumped only when its content really changes), and deleted ids are kept
/// as tombstones with the stamp of the deletion.
class RecordCollection<T extends Record> extends ChangeNotifier {
  RecordCollection({
    required this.store,
    required this.name,
    required this.fromJson,
    SyncClock? clock,
    this.saveDelay = const Duration(milliseconds: 400),
  }) : clock = clock ?? SyncClock();

  static const _folder = 'data';

  /// 1: records + ISO-date tombstones. 2: adds `revs` and stamp tombstones.
  static const schemaVersion = 2;

  final JsonFileStore store;
  final String name;
  final T Function(Map<String, dynamic>) fromJson;
  final SyncClock clock;
  final Duration saveDelay;

  final Map<String, T> _records = {};
  final Map<String, String> _revs = {};
  final Map<String, String> _tombstones = {};

  /// Records this version could not read (damaged, or written by a newer
  /// version). Kept untouched and written back, never silently dropped.
  final List<Map<String, dynamic>> _unreadable = [];
  Timer? _timer;
  bool _dirty = false;

  /// Schema of the file as it was loaded (for migrations).
  int loadedSchema = schemaVersion;

  Iterable<T> get all => _records.values;
  int get length => _records.length;
  T? operator [](String? id) => id == null ? null : _records[id];
  bool contains(String id) => _records.containsKey(id);

  /// Revision stamp of a record, or null if it doesn't exist.
  String? revOf(String id) => _revs[id];

  /// Deleted ids and when they were deleted (as stamps).
  Map<String, String> get tombstones => Map.unmodifiable(_tombstones);

  Future<void> load() async {
    final json = await store.read(_folder, name);
    _records.clear();
    _revs.clear();
    _tombstones.clear();
    _unreadable.clear();
    if (json == null) return;
    loadedSchema = json['schema'] as int? ?? 1;
    final savedRevs =
        (json['revs'] as Map?)?.cast<String, String>() ?? const {};
    for (final raw in json['records'] as List? ?? const []) {
      try {
        final record = fromJson(raw as Map<String, dynamic>);
        _records[record.id] = record;
        // Records from before revisions existed get one from their edit time.
        _revs[record.id] =
            savedRevs[record.id] ?? clock.stampAt(record.updatedAt);
      } catch (e) {
        // One damaged record must not take the rest down with it.
        AppLog.warn('Keeping unreadable $name record aside: $e');
        if (raw is Map<String, dynamic>) _unreadable.add(raw);
      }
    }
    (json['tombstones'] as Map?)?.forEach(
      (k, v) => _tombstones[k as String] = clock.normalize(v as String),
    );
    _revs.values.forEach(clock.observe);
    _tombstones.values.forEach(clock.observe);
    if (loadedSchema < schemaVersion) _dirty = true;
    notifyListeners();
  }

  /// Record content without its edit time, to detect real changes.
  static String _content(Record r) {
    final json = Map<String, dynamic>.of(r.toJson())..remove('updatedAt');
    return jsonEncode(json);
  }

  /// Told before an existing record is replaced, by a local edit or by a
  /// change from another device (e.g. to keep a version history).
  void Function(T previous, T next)? onReplace;

  bool _store(T record) {
    final existing = _records[record.id];
    if (existing != null && _content(existing) == _content(record)) {
      return false;
    }
    if (existing != null) onReplace?.call(existing, record);
    _records[record.id] = record;
    _revs[record.id] = clock.now();
    _tombstones.remove(record.id);
    return true;
  }

  void put(T record) {
    if (_store(record)) _changed();
  }

  void putAll(Iterable<T> records) {
    var changed = false;
    for (final r in records) {
      changed = _store(r) || changed;
    }
    if (changed) _changed();
  }

  void remove(String id) {
    if (_records.remove(id) == null) return;
    _revs.remove(id);
    _tombstones[id] = clock.now();
    _changed();
  }

  /// Every record and tombstone with its revision, for sync.
  Iterable<({String id, String rev, bool deleted})> versions() sync* {
    for (final e in _revs.entries) {
      yield (id: e.key, rev: e.value, deleted: false);
    }
    for (final e in _tombstones.entries) {
      yield (id: e.key, rev: e.value, deleted: true);
    }
  }

  /// Applies a version received from the sync hub, keeping its revision
  /// (no new local stamp, so it is not sent back as a local change).
  /// `data == null` means the record was deleted.
  void applyRemote(String id, String rev, Map<String, dynamic>? data) {
    clock.observe(rev);
    if (data == null) {
      _records.remove(id);
      _revs.remove(id);
      _tombstones[id] = rev;
    } else {
      final record = fromJson(data);
      final existing = _records[id];
      if (existing != null) onReplace?.call(existing, record);
      _records[id] = record;
      _revs[id] = rev;
      _tombstones.remove(id);
    }
    _changed();
  }

  void _changed() {
    _dirty = true;
    _timer?.cancel();
    // A failure is logged and retried inside flush().
    _timer = Timer(saveDelay, () => unawaited(flush().catchError((_) {})));
    notifyListeners();
  }

  Future<void> flush() async {
    _timer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    try {
      await store.write(_folder, name, {
        'schema': schemaVersion,
        'records': [
          for (final r in _records.values) r.toJson(),
          ..._unreadable,
        ],
        'revs': _revs,
        'tombstones': _tombstones,
      });
      onSaveResult?.call(name, true);
    } catch (e) {
      _dirty = true;
      onSaveResult?.call(name, false);
      AppLog.error('Saving $name failed; will retry', e);
      // Try again by itself (e.g. once a locked file is free), rather than
      // only at the next edit, so no change is left unsaved.
      _timer?.cancel();
      _timer = Timer(retryDelay, () => unawaited(flush().catchError((_) {})));
      rethrow;
    }
  }

  /// Wait before retrying a failed save.
  static Duration retryDelay = const Duration(seconds: 5);

  /// Told after every save attempt (collection name, whether it worked), so
  /// the app can show that changes are not on disk yet.
  void Function(String name, bool saved)? onSaveResult;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
