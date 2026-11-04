// All-or-nothing changes across several record collections.
//
// Each collection is one file, written atomically on its own. An operation
// that changes two collections (a note and its version history, a folder and
// the notes in it) used to be two independent saves: a crash between them
// left one half. This log closes that gap with a write-ahead intent:
//
//   1. the operations (record id, content before, content after) are
//      written to `txn/<id>.json` first (the same encrypted, atomic write as
//      every other file);
//   2. only then may the collections they touch be saved (RecordCollection
//      .hold), and the change is applied in memory at once;
//   3. when every touched collection is on disk the intent is deleted.
//
// After a crash, [recover] finishes what was begun: an operation whose record
// still has its "before" content is applied, one that is already applied is
// left alone, and one whose record was changed by something later is NOT
// touched (the later edit wins; nothing is overwritten). The intent is then
// deleted. An intent that names a collection this version does not know
// (written by a newer version) is kept untouched.
//
// Pure Dart; no Flutter.
import 'dart:async';
import 'dart:convert';

import '../models/canvas_models.dart' show newId;
import '../models/record.dart';
import '../repositories/record_collection.dart';
import 'app_log.dart';
import 'json_file_store.dart';

/// One step of a transaction.
class TxOp {
  const TxOp.put(this.collection, this.id, this.before, this.after)
    : remove = false,
      recoverable = true;
  const TxOp.remove(
    this.collection,
    this.id,
    this.before, {
    this.recoverable = true,
  }) : remove = true,
       after = null;

  final String collection;
  final String id;
  final bool remove;
  final bool recoverable;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  Map<String, dynamic> toJson() => {
    'c': collection,
    'id': id,
    'op': remove ? 'remove' : 'put',
    if (before != null) 'before': before,
    if (after != null) 'after': after,
    if (remove && !recoverable) 'recoverable': false,
  };

  static TxOp? fromJson(Object? j) {
    if (j is! Map) return null;
    final c = j['c'], id = j['id'], op = j['op'];
    if (c is! String || id is! String) return null;
    final before = (j['before'] as Map?)?.cast<String, dynamic>();
    final after = (j['after'] as Map?)?.cast<String, dynamic>();
    if (op == 'remove') {
      return TxOp.remove(c, id, before, recoverable: j['recoverable'] != false);
    }
    if (op == 'put' && after != null) return TxOp.put(c, id, before, after);
    return null;
  }
}

/// Content of a record without its edit time and with sorted keys, so two
/// copies of the same content compare equal however they were produced.
String canonicalContent(Map<String, dynamic>? json) {
  if (json == null) return 'null';
  Object? norm(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: norm(v[k])};
    }
    if (v is List) return [for (final e in v) norm(e)];
    return v;
  }

  final copy = Map<String, dynamic>.of(json)..remove('updatedAt');
  return jsonEncode(norm(copy));
}

/// The steps of one transaction, being built.
class Tx {
  Tx(this._collections);

  final Map<String, RecordCollection> _collections;
  final List<TxOp> ops = [];
  final List<void Function()> _apply = [];

  String _nameOf(RecordCollection c) {
    for (final e in _collections.entries) {
      if (identical(e.value, c)) return e.key;
    }
    throw StateError('Collection ${c.name} is not part of this workspace');
  }

  /// Stores [record] in [c].
  void put<T extends Record>(RecordCollection<T> c, T record) {
    ops.add(
      TxOp.put(_nameOf(c), record.id, c.jsonOf(record.id), record.toJson()),
    );
    _apply.add(() => c.put(record));
  }

  /// Deletes [id] from [c].
  void remove<T extends Record>(
    RecordCollection<T> c,
    String id, {
    bool recoverable = true,
  }) {
    final before = c.jsonOf(id);
    if (before == null) return;
    ops.add(TxOp.remove(_nameOf(c), id, before, recoverable: recoverable));
    _apply.add(() => c.remove(id, recoverable: recoverable));
  }
}

class RecoveryReport {
  const RecoveryReport({
    this.intents = 0,
    this.applied = 0,
    this.alreadyDone = 0,
    this.skipped = 0,
    this.kept = 0,
  });

  /// Intent files found.
  final int intents;

  /// Steps that had not happened and were finished now.
  final int applied;

  /// Steps that were already on disk.
  final int alreadyDone;

  /// Steps left alone because the record was changed again afterwards.
  final int skipped;

  /// Intents kept because they need a newer version of the app.
  final int kept;
}

class TransactionLog {
  TransactionLog(this.store, this.collections);

  final JsonFileStore store;
  final Map<String, RecordCollection> collections;

  static const folder = 'txn';

  /// Builds a transaction with [build] (nothing changes yet), then applies
  /// it in memory at once. The returned future completes when it is on disk
  /// and its intent is gone; if it fails the intent stays and [recover]
  /// finishes the job at the next start.
  Future<void> run(String label, void Function(Tx tx) build) {
    final tx = Tx(collections);
    build(tx);
    if (tx.ops.isEmpty) return Future.value();
    final id = newId();
    final written = store.write(folder, id, {
      'schema': 1,
      'label': label,
      'at': DateTime.now().toUtc().toIso8601String(),
      'ops': [for (final o in tx.ops) o.toJson()],
    });
    final touched = {for (final o in tx.ops) collections[o.collection]!};
    for (final c in touched) {
      c.hold(written);
    }
    for (final apply in tx._apply) {
      apply();
    }
    return () async {
      try {
        await written;
      } catch (e, s) {
        // Still save: losing the all-or-nothing guarantee is better than
        // losing the change.
        AppLog.error('Transaction "$label": intent not written', e, s);
      }
      await Future.wait([for (final c in touched) c.flush()]);
      await store.delete(folder, id);
    }();
  }

  /// Finishes interrupted transactions. Call once after the collections are
  /// loaded.
  Future<RecoveryReport> recover() async {
    var intents = 0, applied = 0, done = 0, skipped = 0, kept = 0;
    final ids = await store.list(folder);
    for (final id in ids) {
      final json = await store.read(folder, id);
      if (json == null) continue;
      intents++;
      final ops = [
        for (final o in (json['ops'] as List? ?? [])) TxOp.fromJson(o),
      ];
      if (ops.any((o) => o == null || collections[o.collection] == null)) {
        kept++;
        AppLog.warn('Transaction $id needs a newer version; kept untouched');
        continue;
      }
      final touched = <RecordCollection>{};
      for (final op in ops.cast<TxOp>()) {
        final c = collections[op.collection]!;
        final now = canonicalContent(c.jsonOf(op.id));
        if (op.remove) {
          if (c.jsonOf(op.id) == null) {
            done++;
          } else if (now == canonicalContent(op.before)) {
            c.remove(op.id, recoverable: op.recoverable);
            touched.add(c);
            applied++;
          } else {
            skipped++;
          }
        } else if (now == canonicalContent(op.after)) {
          done++;
        } else if (op.before == null
            ? !c.hasTombstone(op.id) && c.jsonOf(op.id) == null
            : now == canonicalContent(op.before)) {
          c.putJson(op.after!);
          touched.add(c);
          applied++;
        } else {
          skipped++;
        }
      }
      await Future.wait([for (final c in touched) c.flush()]);
      await store.delete(folder, id);
      AppLog.info(
        'Finished interrupted change "${json['label']}" '
        '($applied applied so far)',
      );
    }
    return RecoveryReport(
      intents: intents,
      applied: applied,
      alreadyDone: done,
      skipped: skipped,
      kept: kept,
    );
  }
}
