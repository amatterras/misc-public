// The hub's authoritative synced state. Pure Dart.
//
// Storage is an append-only journal (`journal.jsonl`): every accepted
// record version and every acknowledged operation is a line. A push is
// written as one batch followed by a commit line and forced to disk before
// it is acknowledged; on start-up anything after the last commit line (a
// write interrupted by a crash or power cut) is cut off, so a batch is
// either fully there or not at all. Only an index is kept in memory; record
// data is read from the journal on demand.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../sync/hlc.dart';
import '../sync/protocol.dart';

/// Where the latest version of one record lives in the journal.
class _Entry {
  _Entry(
    this.seq,
    this.rev,
    this.deleted,
    this.device,
    this.offset,
    this.length,
  );
  final int seq;
  final String rev;
  final bool deleted;
  final String device;
  final int offset;
  final int length;
}

/// A version staged in the current batch (not yet on disk).
class _Staged {
  _Staged(this.seq, this.change, this.device);
  final int seq;
  final SyncChange change;
  final String device;
}

class HubStats {
  const HubStats({
    required this.records,
    required this.lastSeq,
    required this.journalBytes,
  });
  final int records;
  final int lastSeq;
  final int journalBytes;

  Map<String, dynamic> toJson() => {
    'records': records,
    'lastSeq': lastSeq,
    'journalBytes': journalBytes,
  };
}

class HubStore {
  HubStore._(this.dir);

  /// Acknowledged operations are remembered this long, so a device that
  /// retries an old push gets the same answer instead of a duplicate.
  static const ackRetention = Duration(days: 180);

  final Directory dir;
  final Map<String, _Entry> _latest = {};
  final SplayTreeMap<int, String> _bySeq = SplayTreeMap();
  final Map<String, Map<String, dynamic>> _acks = {};
  final SyncClock _clock = SyncClock(deviceId: 'hub');
  int _seq = 0;
  int _length = 0;
  RandomAccessFile? _file;
  Future<void> _lock = Future.value();

  String get _sep => Platform.pathSeparator;
  File get journal => File('${dir.path}${_sep}journal.jsonl');
  Directory get attachmentsDir => Directory('${dir.path}${_sep}attachments');

  /// Sequence number of the newest version (the cursor a fully synced
  /// device would hold).
  int get lastSeq => _seq;

  /// Permanent identity of this hub (lets devices notice a different or
  /// restored hub).
  late final String hubId;

  HubStats get stats =>
      HubStats(records: _latest.length, lastSeq: _seq, journalBytes: _length);

  static Future<HubStore> open(Directory dir) async {
    final store = HubStore._(dir);
    await dir.create(recursive: true);
    final idFile = File('${dir.path}${Platform.pathSeparator}hub-id');
    if (await idFile.exists()) {
      store.hubId = (await idFile.readAsString()).trim();
    } else {
      final random = Random.secure();
      store.hubId = List.generate(
        16,
        (_) => random.nextInt(36).toRadixString(36),
      ).join();
      await idFile.writeAsString(store.hubId, flush: true);
    }
    await store._load();
    return store;
  }

  /// Runs [action] alone (one writer at a time).
  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _load() async {
    _latest.clear();
    _bySeq.clear();
    _acks.clear();
    _seq = 0;
    var committedLength = 0;
    if (await journal.exists()) {
      final bytes = await journal.readAsBytes();
      var offset = 0;
      final batch = <(Map<String, dynamic>, int, int)>[];
      while (offset < bytes.length) {
        var end = bytes.indexOf(10, offset); // '\n'
        if (end < 0) break; // torn last line
        final lineLength = end - offset;
        Map<String, dynamic>? line;
        try {
          line = jsonDecode(
            utf8.decode(bytes.sublist(offset, end)),
          ) as Map<String, dynamic>;
        } catch (_) {
          // An interrupted write can only damage the end of the journal. If
          // a commit marker follows, the damage is in the middle (disk
          // fault): never cut away later committed data — stop instead.
          final rest = utf8.decode(bytes.sublist(end), allowMalformed: true);
          if (rest.contains('{"t":"c"')) {
            throw StateError(
              'The hub journal is damaged in the middle. Nothing was changed; '
              'restore the latest backup (thehub restore-to).',
            );
          }
          break; // damaged tail: stop at the last good commit
        }
        if (line['t'] == 'c') {
          for (final (l, o, n) in batch) {
            _index(l, o, n);
          }
          batch.clear();
          committedLength = end + 1;
        } else {
          batch.add((line, offset, lineLength));
        }
        offset = end + 1;
      }
    }
    if (await journal.exists() && await journal.length() != committedLength) {
      // Keep the unfinished tail aside (for inspection), then cut it off: it
      // was never acknowledged, so the devices still have those changes.
      final bytes = await journal.readAsBytes();
      await File(
        '${journal.path}.tail-${DateTime.now().millisecondsSinceEpoch}',
      ).writeAsBytes(bytes.sublist(committedLength), flush: true);
    }
    _file = await journal.open(mode: FileMode.append);
    if (await _file!.length() != committedLength) {
      await _file!.truncate(committedLength);
    }
    _length = committedLength;
    for (final e in _latest.values) {
      _clock.observe(e.rev);
    }
  }

  void _index(Map<String, dynamic> line, int offset, int length) {
    switch (line['t']) {
      case 'v':
        final key = '${line['c']}/${line['id']}';
        final seq = line['seq'] as int;
        final old = _latest[key];
        if (old != null) _bySeq.remove(old.seq);
        _latest[key] = _Entry(
          seq,
          line['rev'] as String,
          line['del'] as bool,
          line['dev'] as String,
          offset,
          length,
        );
        _bySeq[seq] = key;
        if (seq > _seq) _seq = seq;
      case 'ack':
        _acks[line['op'] as String] = line;
    }
  }

  Future<Map<String, dynamic>> _readLine(_Entry e) async {
    final f = await journal.open();
    try {
      await f.setPosition(e.offset);
      final bytes = await f.read(e.length);
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } finally {
      await f.close();
    }
  }

  SyncChange _changeFromLine(Map<String, dynamic> l) => SyncChange(
    collection: l['c'] as String,
    id: l['id'] as String,
    rev: l['rev'] as String,
    deleted: l['del'] as bool,
    data: l['data'] as Map<String, dynamic>?,
    seq: l['seq'] as int,
  );

  /// The hub's current version of a record, or null.
  Future<SyncChange?> current(String collection, String id) async {
    final e = _latest['$collection/$id'];
    return e == null ? null : _changeFromLine(await _readLine(e));
  }

  static String _opId(String device, SyncChange c) =>
      '$device|${c.collection}|${c.id}|${c.rev}';

  /// Applies pushed changes from [device] as one durable batch and returns
  /// one result per change, in order. See SYNC_ARCHITECTURE.md §11 for the
  /// rules.
  Future<List<PushResult>> push(String device, List<SyncChange> changes) {
    if (changes.length > maxPushBatch) {
      throw const ProtocolException(
        'too_many_changes',
        'Too many changes in one push.',
      );
    }
    for (final c in changes) {
      // A device may only send its own new edits. The exception is a record
      // it is re-offering with no base revision (after the hub was restored
      // or the device re-paired): it may hold versions made elsewhere, which
      // then go through the normal rules (never overwriting newer data).
      if (deviceOfRev(c.rev) != device && c.baseRev != null) {
        throw const ProtocolException(
          'bad_change',
          'A revision does not belong to this device.',
        );
      }
      if (c.data != null &&
          utf8.encode(jsonEncode(c.data)).length > maxRecordBytes) {
        throw const ProtocolException(
          'record_too_large',
          'A record is too large.',
        );
      }
    }
    return _locked(() => _push(device, changes));
  }

  Future<List<PushResult>> _push(
    String device,
    List<SyncChange> changes,
  ) async {
    final staged = <String, _Staged>{};
    final lines = <Map<String, dynamic>>[];
    final results = <PushResult>[];
    final now = DateTime.now().toUtc().toIso8601String();
    var seq = _seq;

    // Latest version of a record, including changes staged in this batch.
    ({String rev, bool deleted, String device})? latest(String key) {
      final s = staged[key];
      if (s != null) {
        return (rev: s.change.rev, deleted: s.change.deleted, device: s.device);
      }
      final e = _latest[key];
      return e == null
          ? null
          : (rev: e.rev, deleted: e.deleted, device: e.device);
    }

    Future<SyncChange> currentOf(String key) async {
      final s = staged[key];
      if (s != null) {
        final c = s.change;
        return SyncChange(
          collection: c.collection,
          id: c.id,
          rev: c.rev,
          deleted: c.deleted,
          data: c.data,
          seq: s.seq,
        );
      }
      return _changeFromLine(await _readLine(_latest[key]!));
    }

    void stage(SyncChange c, String by) {
      seq++;
      staged[c.key] = _Staged(seq, c, by);
      lines.add({
        't': 'v',
        'seq': seq,
        'c': c.collection,
        'id': c.id,
        'rev': c.rev,
        'del': c.deleted,
        if (c.data != null) 'data': c.data,
        'dev': by,
        'at': now,
      });
    }

    Future<String> preserveConflict(
      String reason,
      SyncChange kept,
      String keptDevice,
      SyncChange other,
      String otherDevice,
      String opId,
    ) async {
      final id =
          'cf-${sha256.convert(utf8.encode(opId)).toString().substring(0, 24)}';
      stage(
        SyncChange(
          collection: 'conflicts',
          id: id,
          rev: _clock.now(),
          deleted: false,
          data: {
            'id': id,
            'collection': other.collection,
            'recordId': other.id,
            'reason': reason,
            'keptRev': kept.rev,
            'keptDevice': keptDevice,
            'keptDeleted': kept.deleted,
            'otherRev': other.rev,
            'otherDevice': otherDevice,
            'otherDeleted': other.deleted,
            if (other.data != null) 'otherData': other.data,
            'at': now,
          },
        ),
        'hub',
      );
      return id;
    }

    for (final c in changes) {
      final opId = _opId(device, c);
      // Edits (with a base) that were already handled get their earlier
      // answer. Base-less offers (new records, or re-offers after a restore
      // or re-pairing) always go through the rules below, which treat an
      // identical version as a duplicate and never let it overwrite newer data.
      final ack = c.baseRev == null ? null : _acks[opId];
      if (ack != null) {
        // A retry of something already handled: nothing new is stored. If
        // the record has moved on since, the device must take the current
        // version rather than believe its old one is still in sync.
        final stored = PushStatus.values.byName(ack['st'] as String);
        final now = latest(c.key);
        final status =
            stored != PushStatus.keptServer && now != null && now.rev != c.rev
            ? PushStatus.keptServer
            : stored;
        results.add(
          PushResult(
            collection: c.collection,
            id: c.id,
            rev: c.rev,
            status: status == PushStatus.applied
                ? PushStatus.duplicate
                : status,
            current: status == PushStatus.keptServer
                ? await currentOf(c.key)
                : null,
            conflictId: ack['cf'] as String?,
          ),
        );
        continue;
      }
      final cur = latest(c.key);
      PushStatus status;
      String? conflictId;
      if (cur == null || cur.rev == c.baseRev) {
        stage(c, device);
        status = PushStatus.applied;
      } else if (cur.rev == c.rev) {
        status = PushStatus.duplicate;
      } else if (deviceOfRev(cur.rev) == device &&
          deviceOfRev(c.rev) == device &&
          c.rev.compareTo(cur.rev) > 0) {
        // The hub's version is this device's own earlier edit (its reply was
        // lost); the new edit was made on top of it, so it simply replaces it.
        stage(c, device);
        status = PushStatus.applied;
      } else {
        // The hub's version changed since this device last saw it.
        final server = await currentOf(c.key);
        if (cur.deleted && c.deleted) {
          status = PushStatus.keptServer; // both deleted: nothing to keep
        } else if (c.deleted) {
          // Deleted here, edited elsewhere: never let a deletion overwrite
          // an edit. Keep the edit; record that a deletion was requested.
          conflictId = await preserveConflict(
            'deleted_here_edited_elsewhere',
            server,
            cur.device,
            c,
            device,
            opId,
          );
          status = PushStatus.keptServer;
        } else if (cur.deleted) {
          // Edited here after it was deleted elsewhere: keep the edit.
          stage(c, device);
          conflictId = await preserveConflict(
            'edited_after_delete',
            c,
            device,
            server,
            cur.device,
            opId,
          );
          status = PushStatus.applied;
        } else if (c.rev.compareTo(cur.rev) > 0) {
          // Both edited: newer revision wins, the other is preserved.
          stage(c, device);
          conflictId = await preserveConflict(
            'concurrent_edit',
            c,
            device,
            server,
            cur.device,
            opId,
          );
          status = PushStatus.applied;
        } else {
          conflictId = await preserveConflict(
            'concurrent_edit',
            server,
            cur.device,
            c,
            device,
            opId,
          );
          status = PushStatus.keptServer;
        }
      }
      lines.add({
        't': 'ack',
        'op': opId,
        'st': status.name,
        'cf': ?conflictId,
        'at': now,
      });
      results.add(
        PushResult(
          collection: c.collection,
          id: c.id,
          rev: c.rev,
          status: status,
          current: status == PushStatus.keptServer
              ? await currentOf(c.key)
              : null,
          conflictId: conflictId,
        ),
      );
    }
    await _append(lines);
    return results;
  }

  /// Writes a batch plus commit marker, forces it to disk, then indexes it.
  Future<void> _append(List<Map<String, dynamic>> lines) async {
    if (lines.isEmpty) return;
    final encoded = [for (final l in lines) utf8.encode('${jsonEncode(l)}\n')];
    final commit = utf8.encode(
      '${jsonEncode({'t': 'c', 'n': lines.length})}\n',
    );
    final builder = BytesBuilder(copy: false);
    for (final e in encoded) {
      builder.add(e);
    }
    builder.add(commit);
    final start = _length;
    final f = _file!;
    try {
      await f.setPosition(start);
      await f.writeFrom(builder.takeBytes());
      await f.flush();
    } catch (e) {
      // Never leave a partial batch behind.
      await f.truncate(start);
      rethrow;
    }
    var offset = start;
    for (var i = 0; i < lines.length; i++) {
      _index(lines[i], offset, encoded[i].length - 1);
      offset += encoded[i].length;
    }
    _length = offset + commit.length;
  }

  /// Versions newer than [since], oldest first, at most [limit].
  Future<({List<SyncChange> changes, int next, bool hasMore})> changesSince(
    int since,
    int limit,
  ) async {
    final n = limit.clamp(1, maxPullLimit);
    final picked = <_Entry>[];
    var key = _bySeq.firstKeyAfter(since);
    while (key != null && picked.length < n) {
      picked.add(_latest[_bySeq[key]!]!);
      key = _bySeq.firstKeyAfter(key);
    }
    final changes = <SyncChange>[];
    if (picked.isNotEmpty) {
      final f = await journal.open();
      try {
        for (final e in picked) {
          await f.setPosition(e.offset);
          final line = jsonDecode(
            utf8.decode(await f.read(e.length)),
          ) as Map<String, dynamic>;
          changes.add(_changeFromLine(line));
        }
      } finally {
        await f.close();
      }
    }
    final next = picked.isEmpty ? since : picked.last.seq;
    return (changes: changes, next: next, hasMore: key != null);
  }

  // -------------------------------------------------------- attachments --

  File attachmentFile(String sha) {
    if (!sha256Pattern.hasMatch(sha)) {
      throw const ProtocolException('bad_attachment', 'Invalid attachment id.');
    }
    return File('${attachmentsDir.path}$_sep$sha');
  }

  Future<bool> hasAttachment(String sha) => attachmentFile(sha).exists();

  /// Stores an attachment streamed in [data]. It is written to a temporary
  /// file while being hashed and only moved into place when its size and
  /// SHA-256 match, so an interrupted or corrupted upload never becomes a
  /// visible file. Uploading an existing file again is a no-op.
  Future<void> putAttachment(
    String sha,
    int size,
    Stream<List<int>> data,
  ) async {
    final target = attachmentFile(sha);
    if (size < 0 || size > maxAttachmentBytes) {
      throw const ProtocolException(
        'too_large',
        'Attachment is too large.',
        status: 413,
      );
    }
    final incoming = Directory('${attachmentsDir.path}$_sep.incoming');
    await incoming.create(recursive: true);
    final tmp = File(
      '${incoming.path}$_sep$sha-${DateTime.now().microsecondsSinceEpoch}',
    );
    final sink = tmp.openWrite();
    final hashOut = _DigestSink();
    final hasher = sha256.startChunkedConversion(hashOut);
    var received = 0;
    try {
      await for (final chunk in data) {
        received += chunk.length;
        if (received > size) {
          throw const ProtocolException(
            'integrity_failed',
            'More data than declared.',
            status: 422,
          );
        }
        hasher.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      hasher.close();
      if (received != size || hashOut.value.toString() != sha) {
        throw const ProtocolException(
          'integrity_failed',
          'Attachment size or checksum does not match.',
          status: 422,
        );
      }
      if (await target.exists()) {
        await tmp.delete();
        return;
      }
      await tmp.rename(target.path);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }

  // --------------------------------------------------------- maintenance --

  /// Rewrites the journal keeping only the latest version of each record
  /// and recent acknowledgements. The old journal is replaced atomically.
  Future<void> compact() => _locked(() async {
    final tmp = File('${journal.path}.compact');
    final out = await tmp.open(mode: FileMode.write);
    final cutoff = DateTime.now().toUtc().subtract(ackRetention);
    var count = 0;
    try {
      final src = await journal.open();
      try {
        for (final seq in _bySeq.keys) {
          final e = _latest[_bySeq[seq]!]!;
          await src.setPosition(e.offset);
          await out.writeFrom(await src.read(e.length));
          await out.writeFrom([10]);
          count++;
        }
      } finally {
        await src.close();
      }
      for (final ack in _acks.values) {
        final at = DateTime.tryParse(ack['at'] as String? ?? '');
        if (at != null && at.isBefore(cutoff)) continue;
        await out.writeFrom(utf8.encode('${jsonEncode(ack)}\n'));
        count++;
      }
      await out.writeFrom(
        utf8.encode('${jsonEncode({'t': 'c', 'n': count})}\n'),
      );
      await out.flush();
    } finally {
      await out.close();
    }
    await _file!.close();
    await tmp.rename(journal.path);
    await _load();
  });

  /// Copies a consistent snapshot of the journal (taken between batches)
  /// to [target].
  Future<void> copyJournalTo(File target) => _locked(() async {
    await _file!.flush();
    await target.parent.create(recursive: true);
    final src = await journal.open();
    final out = await target.open(mode: FileMode.write);
    try {
      var remaining = _length;
      while (remaining > 0) {
        final chunk = await src.read(remaining > 1 << 20 ? 1 << 20 : remaining);
        await out.writeFrom(chunk);
        remaining -= chunk.length;
      }
      await out.flush();
    } finally {
      await src.close();
      await out.close();
    }
  });

  /// Hashes of every attachment file the hub holds.
  Future<List<String>> attachmentHashes() async {
    if (!await attachmentsDir.exists()) return [];
    return [
      await for (final e in attachmentsDir.list())
        if (e is File && sha256Pattern.hasMatch(e.uri.pathSegments.last))
          e.uri.pathSegments.last,
    ];
  }

  Future<void> close() => _locked(() async {
    await _file?.close();
    _file = null;
  });
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
