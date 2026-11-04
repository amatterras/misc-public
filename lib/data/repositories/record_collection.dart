import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/record.dart';
import '../models/unknown_fields.dart';
import '../storage/log_sanitizer.dart';
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

  /// Fields of each record that this version does not know (record id →
  /// fields), e.g. added by a newer version on another device. Written back
  /// and synced with the record, so an edit here never drops them.
  final Map<String, Map<String, dynamic>> _unknownFields = {};

  /// Top-level keys of the file that this version does not know.
  Map<String, dynamic> _unknownFileKeys = const {};
  static const _fileKeys = {
    'schema',
    'records',
    'revs',
    'tombstones',
    'recentlyDeleted',
  };

  /// The last content of deleted records (id → deletion stamp, time and
  /// data), so a deletion can be undone ([restoreDeleted]). Kept on this
  /// device only (never synced), for [deletedRetention], at most
  /// [deletedLimit] per collection. Records removed with
  /// `recoverable: false` (e.g. expired calendar entries) are not kept.
  final Map<String, Map<String, dynamic>> _recentlyDeleted = {};
  static const deletedRetention = Duration(days: 30);
  static const deletedLimit = 200;

  /// Decides whether a removed record may be kept for restoring (null =
  /// always). Used by the workspace to keep purged records unrecoverable.
  bool Function(String id)? keepDeleted;

  Timer? _timer;
  bool _dirty = false;

  /// Schema of the file as it was loaded (for migrations).
  int loadedSchema = schemaVersion;

  Iterable<T> get all => _records.values;
  int get length => _records.length;
  T? operator [](String? id) => id == null ? null : _records[id];
  bool contains(String id) => _records.containsKey(id);

  /// Whether [id] was deleted for good (set by the workspace; see PurgeMark).
  bool Function(String id)? isPurged;

  /// Records kept aside because this version could not read them.
  int get unreadableCount => _unreadable.length;

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
    _unknownFields.clear();
    _recentlyDeleted.clear();
    _unknownFileKeys = const {};
    if (json == null) return;
    loadedSchema = json['schema'] as int? ?? 1;
    _unknownFileKeys = unknownFields(json, _fileKeys);
    final savedRevs =
        (json['revs'] as Map?)?.cast<String, String>() ?? const {};
    for (final raw in json['records'] as List? ?? const []) {
      try {
        final record = fromJson(raw as Map<String, dynamic>);
        if (_records.containsKey(record.id)) {
          // The same id twice (a damaged or badly merged file): the first
          // is used, the other is kept aside and written back unchanged,
          // so saving never drops it. The integrity check reports it.
          AppLog.warn('Keeping a duplicate $name record aside');
          _unreadable.add(raw);
          continue;
        }
        _records[record.id] = record;
        _keepUnknownFields(record, raw);
        // Records from before revisions existed get one from their edit time.
        _revs[record.id] =
            savedRevs[record.id] ?? clock.stampAt(record.updatedAt);
      } catch (e) {
        // One damaged record must not take the rest down with it.
        AppLog.warn(
          'Keeping unreadable $name record aside: ${describeError(e)}',
        );
        if (raw is Map<String, dynamic>) _unreadable.add(raw);
      }
    }
    (json['tombstones'] as Map?)?.forEach(
      (k, v) => _tombstones[k as String] = clock.normalize(v as String),
    );
    (json['recentlyDeleted'] as Map?)?.forEach((k, v) {
      if (v is Map) _recentlyDeleted[k as String] = v.cast<String, dynamic>();
    });
    _revs.values.forEach(clock.observe);
    _tombstones.values.forEach(clock.observe);
    if (loadedSchema < schemaVersion) _dirty = true;
    notifyListeners();
  }

  void _keepUnknownFields(T record, Map<String, dynamic> raw) {
    final unknown = unknownFields(raw, record.toJson().keys);
    if (unknown.isEmpty) {
      _unknownFields.remove(record.id);
    } else {
      _unknownFields[record.id] = unknown;
    }
  }

  /// The record as stored and synced: its own fields plus any fields this
  /// version does not know. Null if there is no such record.
  Map<String, dynamic>? jsonOf(String id) {
    final record = _records[id];
    if (record == null) return null;
    return withUnknownFields(record.toJson(), _unknownFields[id]);
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

  /// Deletes a record: a tombstone with a new stamp replaces it (so the
  /// deletion syncs), and unless [recoverable] is false its last content is
  /// kept in "recently deleted" for [restoreDeleted]. Only this record is
  /// affected: records it refers to (attachments, notes, folders) stay.
  void remove(String id, {bool recoverable = true}) {
    final json = jsonOf(id);
    if (_records.remove(id) == null) return;
    _unknownFields.remove(id);
    _revs.remove(id);
    final stamp = _tombstones[id] = clock.now();
    _keepDeleted(id, stamp, json, recoverable);
    _changed();
  }

  void _keepDeleted(
    String id,
    String stamp,
    Map<String, dynamic>? json,
    bool recoverable,
  ) {
    if (json == null || !recoverable || !(keepDeleted?.call(id) ?? true)) {
      _recentlyDeleted.remove(id);
      return;
    }
    _recentlyDeleted[id] = {
      'rev': stamp,
      'at': DateTime.now().toUtc().toIso8601String(),
      'data': json,
    };
  }

  /// Deleted records whose content can still be restored, by id.
  Map<String, Map<String, dynamic>> get recentlyDeleted =>
      Map.unmodifiable(_recentlyDeleted);

  /// Brings a deleted record back as a new edit: it gets a new stamp that
  /// is newer than its deletion, so sync spreads the restore instead of the
  /// deletion. Nothing else is touched (no other record is restored).
  /// Returns null if [id] exists or is not in "recently deleted".
  T? restoreDeleted(String id) {
    if (_records.containsKey(id)) return null;
    final kept = _recentlyDeleted[id];
    final data = kept?['data'];
    if (data is! Map) return null;
    final json = data.cast<String, dynamic>();
    final record = fromJson(json);
    _records[id] = record;
    _keepUnknownFields(record, json);
    _revs[id] = clock.now();
    _tombstones.remove(id);
    _recentlyDeleted.remove(id);
    _changed();
    return record;
  }

  /// Makes a deleted record unrecoverable here (e.g. it expired).
  void forgetDeleted(String id) {
    if (_recentlyDeleted.remove(id) != null) _changed();
  }

  void _pruneDeleted() {
    final cutoff = DateTime.now().toUtc().subtract(deletedRetention);
    _recentlyDeleted.removeWhere((_, v) {
      final at = DateTime.tryParse(v['at'] as String? ?? '');
      return at == null || at.isBefore(cutoff);
    });
    if (_recentlyDeleted.length > deletedLimit) {
      final oldest = _recentlyDeleted.entries.toList()
        ..sort((a, b) => (a.value['at'] as String).compareTo(b.value['at']));
      for (final e in oldest.take(_recentlyDeleted.length - deletedLimit)) {
        _recentlyDeleted.remove(e.key);
      }
    }
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
    // A record deleted for good never comes back from sync or a restore.
    if (data != null && (isPurged?.call(id) ?? false)) return;
    if (data == null) {
      // Deleted on another device: also recoverable here.
      final json = jsonOf(id);
      _records.remove(id);
      _unknownFields.remove(id);
      _revs.remove(id);
      _tombstones[id] = rev;
      _keepDeleted(id, rev, json, true);
    } else {
      final record = fromJson(data);
      final existing = _records[id];
      if (existing != null) onReplace?.call(existing, record);
      _records[id] = record;
      _keepUnknownFields(record, data);
      _revs[id] = rev;
      _tombstones.remove(id);
      _recentlyDeleted.remove(id);
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

  /// After a permanent deletion: brings the previous-version copy of this
  /// collection's file up to date so it no longer holds the deleted record.
  Future<void> refreshBackup() async {
    await flush();
    await store.refreshBackup(_folder, name);
  }

  /// Saves of this collection wait until [until] has finished (a failure of
  /// [until] does not stop the save). Used by the transaction log: a
  /// multi-record change must be written to its intent file before any of
  /// the collections it touches is saved.
  void hold(Future<void> until) {
    final safe = until.catchError((Object _) {});
    final previous = _hold;
    _hold = previous == null ? safe : Future.wait([previous, safe]);
  }

  Future<void>? _hold;

  /// Whether [id] was deleted here (it has a tombstone).
  bool hasTombstone(String id) => _tombstones.containsKey(id);

  /// Stores the record described by [json] as a local edit (used when
  /// replaying an interrupted transaction).
  void putJson(Map<String, dynamic> json) => put(fromJson(json));

  Future<void> flush() async {
    _timer?.cancel();
    final hold = _hold;
    if (hold != null) {
      await hold;
      if (identical(_hold, hold)) _hold = null;
    }
    if (!_dirty) return;
    _dirty = false;
    _pruneDeleted();
    try {
      await store.write(_folder, name, {
        ..._unknownFileKeys,
        'schema': schemaVersion,
        'records': [
          for (final r in _records.values)
            withUnknownFields(r.toJson(), _unknownFields[r.id]),
          ..._unreadable,
        ],
        'revs': _revs,
        'tombstones': _tombstones,
        if (_recentlyDeleted.isNotEmpty) 'recentlyDeleted': _recentlyDeleted,
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
