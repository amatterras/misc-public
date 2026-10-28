// Hub backups. Pure Dart.
//
// A backup is `<hub>\backups\<time>\` holding a consistent copy of the
// journal (taken between batches), the device registry, and a manifest
// listing the journal's checksum and every attachment hash. Attachments are
// content-addressed and never modified, so the manifest is enough to know
// which files a restore needs. A backup only counts once its manifest has
// been written (it is written last).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'hub_store.dart';

class HubBackups {
  HubBackups(this.store);

  static const keep = 10;

  final HubStore store;

  static String get _sep => Platform.pathSeparator;
  Directory get dir => Directory('${store.dir.path}${_sep}backups');

  static File _manifest(Directory b) => File('${b.path}${_sep}manifest.json');

  /// Frequent backups while THEapp runs on this PC (every 10 seconds when
  /// something changed): a rolling set of their own in `backups/live`, so
  /// they never push out the daily ones.
  Directory get liveDir => Directory('${dir.path}${_sep}live');
  static const keepLive = 12;

  /// Complete backups, newest first.
  Future<List<Directory>> list() async {
    await _recoverInterruptedPurges();
    return _completeIn(dir);
  }

  /// Removes every backup (daily and live) except [keep]: used once the hub
  /// switches to end-to-end encryption, because older backups hold the
  /// records in plain text. Returns how many were removed.
  Future<int> removeAllExcept(Directory keep) async {
    var n = 0;
    for (final b in [...await list(), ...await listLive()]) {
      if (b.path == keep.path) continue;
      await b.delete(recursive: true);
      n++;
    }
    return n;
  }

  /// Complete frequent ("live") backups, newest first.
  Future<List<Directory>> listLive() async {
    await _recoverInterruptedPurges(liveDir);
    return _completeIn(liveDir);
  }

  static Future<List<Directory>> _completeIn(Directory parent) async {
    if (!await parent.exists()) return [];
    final all = await parent
        .list()
        .where((e) => e is Directory)
        .cast<Directory>()
        .toList();
    final complete = [
      for (final d in all)
        if (await _manifest(d).exists()) d,
    ];
    complete.sort((a, b) => b.path.compareTo(a.path));
    return complete;
  }

  static Future<String> _fileSha(File f) async =>
      (await sha256.bind(f.openRead()).first).toString();

  /// A daily backup (kept: [keep]).
  Future<Directory> create() async {
    final target = await _createIn(dir);
    await _prune();
    return target;
  }

  /// A frequent backup (kept: [keepLive]), checked before it counts: one
  /// that fails the check is removed and an error thrown; earlier ones
  /// are never touched by a failure.
  Future<Directory> createLive() async {
    final target = await _createIn(liveDir);
    if (!await verify(target)) {
      await target.delete(recursive: true);
      throw const FileSystemException('The new hub backup failed its check');
    }
    for (final old in (await listLive()).skip(keepLive)) {
      await old.delete(recursive: true);
    }
    await _removeHalfMade(liveDir, const Duration(minutes: 5));
    return target;
  }

  /// Writes a backup into [parent]: the journal and devices first, the
  /// manifest last (a folder without a manifest is not a backup, so an
  /// interrupted run can never be mistaken for a complete one).
  Future<Directory> _createIn(Directory parent) async {
    final t = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    final name =
        '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}'
        '${parent.path == dir.path ? '' : '-${three(t.millisecond)}'}';
    var target = Directory('${parent.path}$_sep$name');
    var n = 1;
    while (await target.exists()) {
      target = Directory('${parent.path}$_sep$name-${n++}');
    }
    await target.create(recursive: true);
    final journal = File('${target.path}${_sep}journal.jsonl');
    await store.copyJournalTo(journal);
    final devices = File('${store.dir.path}${_sep}devices.json');
    if (await devices.exists()) {
      await devices.copy('${target.path}${_sep}devices.json');
    }
    final stats = store.stats;
    await _manifest(target).writeAsString(
      const JsonEncoder.withIndent(' ').convert({
        'createdAt': t.toIso8601String(),
        'lastSeq': stats.lastSeq,
        'records': stats.records,
        'journalBytes': await journal.length(),
        'journalSha256': await _fileSha(journal),
        'attachments': await store.attachmentHashes(),
      }),
      flush: true,
    );
    return target;
  }

  /// Scrubs the contents and preserves the permanent calendar-entry
  /// tombstone in every hub backup, including backups created before expiry.
  Future<void> purgeExpiredCalendarEntry(String id) async {
    final current = await store.currentJournalLine('calendar_entries', id);
    if (current == null || current['del'] != true) {
      throw StateError('Expired calendar entry $id has no hub tombstone.');
    }
    for (final backup in [...await list(), ...await listLive()]) {
      await _rewriteWithoutExpiredEntry(backup, id, current);
    }
  }

  Future<void> purgeAllExpiredCalendarEntries() async {
    for (final id in await store.expiredCalendarEntryIds()) {
      await purgeExpiredCalendarEntry(id);
    }
  }

  /// Removes a record deleted for good from every hub backup, leaving only
  /// its tombstone (so restoring a backup cannot bring it back). The journal
  /// lines are identified by collection and id; nothing is read of their
  /// (sealed) content.
  Future<void> purgeRecord(String collection, String id) async {
    final current = await store.currentJournalLine(collection, id);
    if (current == null || current['del'] != true) return;
    for (final backup in [...await list(), ...await listLive()]) {
      await _rewriteWithoutExpiredEntry(backup, id, current, collection);
    }
  }

  Future<void> _rewriteWithoutExpiredEntry(
    Directory backup,
    String id,
    Map<String, dynamic> tombstone, [
    String collection = 'calendar_entries',
  ]) async {
    // Already clean (only the tombstone is left)? Then nothing to do.
    var versions = 0;
    var onlyTombstone = true;
    await for (final raw in File(
      '${backup.path}${_sep}journal.jsonl',
    ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
      if (raw.isEmpty || !raw.contains('"$id"')) continue;
      try {
        final line = jsonDecode(raw) as Map<String, dynamic>;
        if (line['t'] == 'v' && line['c'] == collection && line['id'] == id) {
          versions++;
          if (line['del'] != true) onlyTombstone = false;
        }
      } catch (_) {
        // A damaged line: rewrite to be sure.
        onlyTombstone = false;
      }
    }
    if (versions == 1 && onlyTombstone) return;
    final manifest = jsonDecode(
      await _manifest(backup).readAsString(),
    ) as Map<String, dynamic>;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final stage = Directory('${backup.path}.purge-stage-$stamp');
    final old = Directory('${backup.path}.purge-old-$stamp');
    await stage.create(recursive: true);
    final sourceJournal = File('${backup.path}${_sep}journal.jsonl');
    final outputJournal = File('${stage.path}${_sep}journal.jsonl');
    final sink = outputJournal.openWrite();
    var lineCount = 0;
    var lastSeq = manifest['lastSeq'] as int? ?? 0;
    final recordKeys = <String>{};
    try {
      await for (final raw
          in sourceJournal
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (raw.isEmpty) continue;
        final line = jsonDecode(raw) as Map<String, dynamic>;
        if (line['t'] == 'c') continue;
        if (line['t'] == 'v' && line['c'] == collection && line['id'] == id) {
          continue;
        }
        sink.writeln(raw);
        lineCount++;
        if (line['t'] == 'v') {
          final seq = line['seq'];
          if (seq is int && seq > lastSeq) lastSeq = seq;
          recordKeys.add('${line['c']}/${line['id']}');
        }
      }
      sink.writeln(jsonEncode(tombstone));
      lineCount++;
      final tombstoneSeq = tombstone['seq'];
      if (tombstoneSeq is int && tombstoneSeq > lastSeq) {
        lastSeq = tombstoneSeq;
      }
      recordKeys.add('$collection/$id');
      sink.writeln(jsonEncode({'t': 'c', 'n': lineCount}));
      await sink.flush();
    } finally {
      await sink.close();
    }

    await for (final entity in backup.list(recursive: true)) {
      if (entity is! File || entity.path == sourceJournal.path) continue;
      final relative = entity.path.substring(backup.path.length + 1);
      final destination = File('${stage.path}$_sep$relative');
      await destination.parent.create(recursive: true);
      await entity.copy(destination.path);
    }
    final stagedManifest = _manifest(stage);
    await stagedManifest.writeAsString(
      const JsonEncoder.withIndent(' ').convert({
        ...manifest,
        'lastSeq': lastSeq,
        'records': recordKeys.length,
        'journalBytes': await outputJournal.length(),
        'journalSha256': await _fileSha(outputJournal),
      }),
      flush: true,
    );
    if (!await verify(stage)) {
      await stage.delete(recursive: true);
      throw StateError('Sanitized hub backup did not verify.');
    }

    await backup.rename(old.path);
    try {
      await stage.rename(backup.path);
    } catch (_) {
      await old.rename(backup.path);
      rethrow;
    }
    await old.delete(recursive: true);
  }

  Future<void> _recoverInterruptedPurges([Directory? parent]) async {
    final base = parent ?? dir;
    if (!await base.exists()) return;
    final children = await base
        .list()
        .where((entity) => entity is Directory)
        .cast<Directory>()
        .toList();
    final grouped = <String, List<Directory>>{};
    for (final child in children) {
      final name = child.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final stageAt = name.indexOf('.purge-stage-');
      final oldAt = name.indexOf('.purge-old-');
      final at = stageAt >= 0 ? stageAt : oldAt;
      if (at >= 0) {
        grouped.putIfAbsent(name.substring(0, at), () => []).add(child);
      }
    }
    for (final entry in grouped.entries) {
      final canonical = Directory('${base.path}$_sep${entry.key}');
      final candidates = entry.value;
      if (await canonical.exists()) {
        if (await verify(canonical)) {
          for (final candidate in candidates) {
            await candidate.delete(recursive: true);
          }
        }
        continue;
      }
      Directory? replacement;
      for (final candidate in candidates) {
        final name = candidate.uri.pathSegments.last;
        if (name.contains('.purge-stage-') && await verify(candidate)) {
          replacement = candidate;
          break;
        }
      }
      if (replacement == null) {
        for (final candidate in candidates) {
          if (candidate.uri.pathSegments.last.contains('.purge-old-')) {
            replacement = candidate;
            break;
          }
        }
      }
      if (replacement != null) await replacement.rename(canonical.path);
    }
  }

  Future<void> _prune() async {
    for (final old in (await list()).skip(keep)) {
      await old.delete(recursive: true);
    }
    await _removeHalfMade(dir, const Duration(hours: 1));
  }

  /// Removes half-made backups (no manifest) older than [age] left in
  /// [parent] by an interrupted run; never the live folder itself.
  Future<void> _removeHalfMade(Directory parent, Duration age) async {
    if (!await parent.exists()) return;
    await for (final e in parent.list()) {
      if (e is! Directory || e.path == liveDir.path) continue;
      if (await _manifest(e).exists()) continue;
      final old = DateTime.now().difference((await e.stat()).modified);
      if (old > age) await e.delete(recursive: true);
    }
  }

  /// True if the backup is complete and its journal matches the checksum.
  static Future<bool> verify(Directory backup) async {
    try {
      final m = jsonDecode(
        await _manifest(backup).readAsString(),
      ) as Map<String, dynamic>;
      final journal = File('${backup.path}${_sep}journal.jsonl');
      return await journal.length() == m['journalBytes'] &&
          await _fileSha(journal) == m['journalSha256'];
    } catch (_) {
      return false;
    }
  }

  /// Restores [backup] into [target], which must not exist yet (this never
  /// overwrites live data). Attachment files listed in the manifest are
  /// copied from [attachmentsFrom] (normally the live hub's attachments).
  /// Returns the hashes of attachments that could not be found.
  static Future<List<String>> restoreTo(
    Directory backup,
    Directory target, {
    Directory? attachmentsFrom,
  }) async {
    if (!await verify(backup)) {
      throw const FileSystemException('Backup is incomplete or damaged');
    }
    if (await target.exists() && !await target.list().isEmpty) {
      throw FileSystemException('Restore target is not empty', target.path);
    }
    await target.create(recursive: true);
    await File('${backup.path}${_sep}journal.jsonl')
        .copy('${target.path}${_sep}journal.jsonl');
    final devices = File('${backup.path}${_sep}devices.json');
    if (await devices.exists()) {
      await devices.copy('${target.path}${_sep}devices.json');
    }
    final m = jsonDecode(
      await _manifest(backup).readAsString(),
    ) as Map<String, dynamic>;
    final missing = <String>[];
    final dest = Directory('${target.path}${_sep}attachments');
    for (final sha in (m['attachments'] as List).cast<String>()) {
      final src = File('${attachmentsFrom?.path}$_sep$sha');
      if (attachmentsFrom != null && await src.exists()) {
        await dest.create(recursive: true);
        await src.copy('${dest.path}$_sep$sha');
      } else {
        missing.add(sha);
      }
    }
    return missing;
  }
}
