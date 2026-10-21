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

  /// Complete backups, newest first.
  Future<List<Directory>> list() async {
    if (!await dir.exists()) return [];
    final all = await dir
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

  Future<Directory> create() async {
    final t = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
    var target = Directory('${dir.path}$_sep$name');
    var n = 1;
    while (await target.exists()) {
      target = Directory('${dir.path}$_sep$name-${n++}');
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
    await _prune();
    return target;
  }

  Future<void> _prune() async {
    for (final old in (await list()).skip(keep)) {
      await old.delete(recursive: true);
    }
    // Remove half-made backups (no manifest) left by an interrupted run.
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is Directory && !await _manifest(e).exists()) {
          final age = DateTime.now().difference((await e.stat()).modified);
          if (age > const Duration(hours: 1)) await e.delete(recursive: true);
        }
      }
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
