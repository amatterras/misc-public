// One-time upgrade of an existing plain-text data folder to encrypted files.
//
// Safety rules (see tests/encryption_test.dart):
//  * A verified recovery backup ("pre-encryption", never pruned) is made
//    first; if it cannot be verified nothing is changed.
//  * Every file is encrypted to a `.enc-tmp` file, read back and decrypted to
//    check it equals the original, and only then swapped in atomically. A
//    crash leaves, for each file, either the old plain file or the new
//    encrypted one (both readable); leftovers are finished or removed at the
//    next start. Running it again is harmless.
//  * Files are encrypted as raw bytes, never parsed, so unknown or newer
//    fields and files survive exactly.
//  * Older backups (and the user-visible backup copies) are encrypted too,
//    with their manifests updated in step, so no plain-text copy of the data
//    stays in managed storage.
//  * It is reported as complete only when a final scan finds no plain file.
//    Otherwise the problems are returned and the app keeps reading the
//    mixed folder (both kinds are readable) and tries again next start.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../platform/windows_native.dart' as win;
import 'app_log.dart';
import 'backup_service.dart';
import 'storage_encryption.dart';

class EncryptionMigrationResult {
  const EncryptionMigrationResult({
    this.encrypted = 0,
    this.problems = const [],
    this.recoveryBackup,
  });

  /// Files encrypted by this run.
  final int encrypted;

  /// Why the upgrade is not finished (empty = finished and verified).
  final List<String> problems;
  final Directory? recoveryBackup;

  bool get complete => problems.isEmpty;
}

/// Called after each step (`backup`, `file:PATH`, `backup-files:DIR`),
/// so tests can interrupt the run.
typedef MigrationHook = FutureOr<void> Function(String step);

const encryptionMarker = 'encryption.json';
const _pendingSuffix = '.enc-tmp';

Future<EncryptionMigrationResult> migrateToEncrypted(
  Directory root,
  FileCipher cipher, {
  required BackupService backups,
  List<Directory> extraBackupRoots = const [],
  MigrationHook? hook,
}) async {
  final sep = Platform.pathSeparator;
  final backupsRoot = Directory('${root.path}${sep}backups');
  final backupRoots = [backupsRoot, ...extraBackupRoots];
  final problems = <String>[];
  var count = 0;
  Directory? recovery;

  bool isUnder(File f, Directory d) => f.path.startsWith('${d.path}$sep');

  Future<bool> plain(File f) async => !await FileCipher.fileIsEncrypted(f);

  bool equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> swapIn(File tmp, File target) async {
    if (Platform.isWindows) {
      win.replaceFileAtomically(tmp.path, target.path);
    } else {
      await tmp.rename(target.path);
    }
  }

  /// Writes the encrypted form of [file] next to it and checks it.
  Future<File> prepare(File file, Uint8List bytes) async {
    final tmp = File('${file.path}$_pendingSuffix');
    await tmp.writeAsBytes(cipher.encrypt(bytes), flush: true);
    if (!equal(cipher.decrypt(await tmp.readAsBytes()), bytes)) {
      await tmp.delete();
      throw FileSystemException('Encrypted copy did not verify', file.path);
    }
    return tmp;
  }

  Stream<File> everything() async* {
    yield* StorageEncryption.managedFiles(root);
    for (final extra in extraBackupRoots) {
      if (!await extra.exists()) continue;
      await for (final e in extra.list(recursive: true, followLinks: false)) {
        if (e is File) yield e;
      }
    }
  }

  try {
    // 1. Finish what an interrupted run left behind.
    await for (final f in everything()) {
      if (!f.path.endsWith(_pendingSuffix)) continue;
      final target = File(
        f.path.substring(0, f.path.length - _pendingSuffix.length),
      );
      try {
        if (!await target.exists()) {
          await f.rename(target.path);
        } else if (target.path.endsWith(BackupService.manifestFile)) {
          // Prepared last, with the checksums of the encrypted files: always
          // belongs in place (the files it describes are finished here too).
          await swapIn(f, target);
        } else if (await FileCipher.fileIsEncrypted(target)) {
          await f.delete();
        } else if (equal(
          cipher.decrypt(await f.readAsBytes()),
          await target.readAsBytes(),
        )) {
          await swapIn(f, target);
        } else {
          await f.delete();
        }
      } on Exception catch (e) {
        problems.add('Could not finish an earlier upgrade step: $e');
      }
    }
    if (problems.isNotEmpty) {
      return EncryptionMigrationResult(problems: problems);
    }

    // 2. What is still plain.
    final livePlain = <File>[];
    final backupPlain = <File>[];
    await for (final f in everything()) {
      if (!await plain(f)) continue;
      if (backupRoots.any((r) => isUnder(f, r))) {
        backupPlain.add(f);
      } else {
        livePlain.add(f);
      }
    }
    livePlain.sort((a, b) => a.path.compareTo(b.path));

    // 3. A verified recovery backup before anything is changed.
    if (livePlain.isNotEmpty) {
      final existing = (await backups.list())
          .where((d) => d.path.split(sep).last.contains('-pre-encryption'))
          .firstOrNull;
      if (existing != null) {
        recovery = existing;
      } else {
        recovery = await backups.snapshot(
          'pre-encryption',
          includeAttachments: true,
        );
        if (!await backups.verify(recovery)) {
          return EncryptionMigrationResult(
            problems: const [
              'The recovery backup could not be verified, so nothing was '
                  'encrypted yet.',
            ],
            recoveryBackup: recovery,
          );
        }
      }
      await hook?.call('backup');
      // The snapshot just made holds plain copies: encrypt those as well.
      await for (final f in everything()) {
        if (backupRoots.any((r) => isUnder(f, r)) &&
            !backupPlain.any((b) => b.path == f.path) &&
            !f.path.endsWith(_pendingSuffix) &&
            await plain(f)) {
          backupPlain.add(f);
        }
      }
    }

    // 4. Live files, one at a time, each swapped in only once verified.
    for (final f in livePlain) {
      try {
        final bytes = await f.readAsBytes();
        final tmp = await prepare(f, bytes);
        await swapIn(tmp, f);
        count++;
      } on Exception catch (e) {
        problems.add(
          'Could not encrypt ${f.path.substring(root.path.length + 1)}: $e',
        );
        break;
      }
      await hook?.call('file:${f.path.substring(root.path.length + 1)}');
    }

    // 5. Backups (only once the live data is done), grouped per backup so
    //    each manifest is updated together with its files.
    if (problems.isEmpty) {
      final byBackup = <String, List<File>>{};
      for (final f in backupPlain) {
        final base = backupRoots.firstWhere((r) => isUnder(f, r));
        final unit = f.path
            .substring(base.path.length + 1)
            .split(RegExp(r'[\\/]'))
            .first;
        byBackup.putIfAbsent('${base.path}$sep$unit', () => []).add(f);
      }
      for (final entry in byBackup.entries) {
        try {
          count += await _encryptBackup(
            Directory(entry.key),
            entry.value,
            cipher,
            prepare,
            swapIn,
          );
        } on Exception catch (e) {
          problems.add(
            'Could not encrypt a backup (${entry.key.split(sep).last}): $e',
          );
          break;
        }
        await hook?.call('backup-files:${entry.key.split(sep).last}');
      }
    }

    // 6. Complete only if nothing plain is left.
    var left = 0;
    String? first;
    await for (final f in everything()) {
      if (f.path.endsWith(_pendingSuffix)) {
        problems.add('Unfinished encrypted copy: ${f.path}');
      } else if (await plain(f)) {
        left++;
        first ??= f.path;
      }
    }
    if (left > 0) {
      problems.add('$left file(s) are still not encrypted (first: $first).');
    }
    if (problems.isEmpty) {
      final marker = File('${root.path}${sep}keys$sep$encryptionMarker');
      await marker.parent.create(recursive: true);
      await marker.writeAsString(
        jsonEncode({
          'format': 1,
          'status': 'complete',
          'at': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
    }
  } on Exception catch (e, s) {
    AppLog.error('Encryption upgrade failed', e, s);
    problems.add('The encryption upgrade stopped: $e');
  }
  if (problems.isNotEmpty) {
    AppLog.error('Encryption upgrade incomplete: ${problems.join(' | ')}');
  }
  return EncryptionMigrationResult(
    encrypted: count,
    problems: problems,
    recoveryBackup: recovery,
  );
}

/// Encrypts the plain [files] of one backup folder and brings its manifest
/// (sizes and checksums of the files as stored) up to date, in one step: all
/// encrypted copies are prepared and verified first, then swapped in, the
/// manifest last. A crash in between is completed by the next run.
Future<int> _encryptBackup(
  Directory backup,
  List<File> files,
  FileCipher cipher,
  Future<File> Function(File, Uint8List) prepare,
  Future<void> Function(File, File) swapIn,
) async {
  final sep = Platform.pathSeparator;
  final manifest = File('${backup.path}$sep${BackupService.manifestFile}');
  Map<String, dynamic>? parsed;
  if (await manifest.exists()) {
    try {
      parsed = jsonDecode(
        await StorageEncryption.readText(manifest, cipher),
      ) as Map<String, dynamic>;
    } catch (_) {
      parsed = null; // a damaged manifest is not made worse
    }
  }
  final prepared = <(File, File)>[];
  final changed = <String, (int, String)>{};
  try {
    for (final f in files) {
      if (parsed != null && f.path == manifest.path) continue;
      final tmp = await prepare(f, await f.readAsBytes());
      prepared.add((f, tmp));
      final rel = f.path.substring(backup.path.length + 1).replaceAll(sep, '/');
      changed[rel] = (
        await tmp.length(),
        sha256.convert(await tmp.readAsBytes()).toString(),
      );
    }
    if (parsed != null) {
      for (final e in (parsed['files'] as List? ?? const [])) {
        final map = e as Map<String, dynamic>;
        final update = changed[map['path']];
        if (update != null) {
          map['size'] = update.$1;
          map['sha256'] = update.$2;
        }
      }
      final tmp = File('${manifest.path}$_pendingSuffix');
      await tmp.writeAsBytes(
        cipher.encryptText(const JsonEncoder.withIndent(' ').convert(parsed)),
        flush: true,
      );
      prepared.add((manifest, tmp));
    }
  } catch (_) {
    for (final (_, tmp) in prepared) {
      if (await tmp.exists()) await tmp.delete();
    }
    rethrow;
  }
  // Files first, the manifest last.
  prepared.sort((a, b) {
    final am = a.$1.path == manifest.path ? 1 : 0;
    final bm = b.$1.path == manifest.path ? 1 : 0;
    return am - bm;
  });
  for (final (target, tmp) in prepared) {
    await swapIn(tmp, target);
  }
  return prepared.length;
}
