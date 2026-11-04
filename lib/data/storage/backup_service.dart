import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../app/build_info.dart';
import '../../platform/file_protection.dart';
import '../../platform/windows_native.dart' as win;
import 'backup_file.dart';
import 'storage_encryption.dart';

/// Point-in-time copies of all records under
/// `<data>\backups\<timestamp>-<reason>`.
///
/// Attachments (photos) are immutable and never deleted, so routine backups
/// only copy records. Backups made before a data upgrade ([snapshot] with
/// `includeAttachments`) also copy the attachments, and every backup can be
/// checked byte-for-byte with [verify].
class BackupService {
  BackupService(this.root);

  final Directory root;

  /// The workspace key (null: files are plain, see storage_encryption.dart).
  /// Backups are byte copies of the live files, so they hold ciphertext when
  /// the live files do; the manifest is encrypted too.
  FileCipher? get _cipher => StorageEncryption.active;

  /// Folders that hold records.
  static const _sources = [
    'canvases',
    'data',
    'settings',
    'sync',
    'canvas_snapshots', // named mindmap versions
    'retention', // permanent calendar-expiration ledger
    'migrations', // migration checkpoints and history
  ];
  static const _attachments = 'attachments';
  static const keepAutomatic = 14;

  /// Manual, pre-upgrade and before-restore backups kept (oldest go first).
  static const keepOther = 20;

  /// Weekly automatic backups that include photos and PDFs.
  static const keepFull = 4;
  static const fullEvery = Duration(days: 7);

  /// Frequent backups while THEapp runs (records only, made only after a
  /// change): a rolling set of their own, so they never push out daily,
  /// weekly, manual or pre-upgrade backups. Photos and PDFs are in the
  /// weekly full backup and the hub's content-addressed store.
  static const keepLive = 12;

  /// Folders being written start with this; they are not backups until
  /// checked and renamed, and are removed if left behind.
  static const partialPrefix = '.partial-';

  /// A frequent backup of the records: copied into a hidden folder,
  /// compared file by file with the live files (so an edit during the
  /// copy cannot leave a mixed set), and only then given its real name.
  /// If anything fails, the hidden folder is removed, earlier backups are
  /// untouched, and an error is thrown (the caller tries again later).
  Future<Directory> liveSnapshot({DateTime? now}) async {
    final name = '${_stamp(now ?? DateTime.now())}-live';
    final partial = Directory('${backupsDir.path}$_sep$partialPrefix$name');
    try {
      if (await partial.exists()) await partial.delete(recursive: true);
      await partial.create(recursive: true);
      await for (final (rel, file) in _files(root, attachments: false)) {
        final dest = File('${partial.path}$_sep$rel');
        await dest.parent.create(recursive: true);
        await file.copy(dest.path);
      }
      if (!await verify(partial)) {
        throw const FileSystemException(
          'Data changed while it was copied; the backup is made again shortly',
        );
      }
      await writeManifest(partial, reason: 'live');
      var target = Directory('${backupsDir.path}$_sep$name');
      for (var n = 1; await target.exists(); n++) {
        target = Directory('${backupsDir.path}$_sep$name-$n');
      }
      final done = await partial.rename(target.path);
      await FileProtection.protect([done.path], tree: true);
      await _prune();
      return done;
    } catch (_) {
      if (await partial.exists()) await partial.delete(recursive: true);
      rethrow;
    }
  }

  /// Removes folders left by a backup that was interrupted (app closed or
  /// crashed while copying). They were never counted as backups.
  Future<int> removeInterrupted() async {
    if (!await backupsDir.exists()) return 0;
    var n = 0;
    await for (final e in backupsDir.list()) {
      if (e is Directory && _name(e).startsWith(partialPrefix)) {
        await e.delete(recursive: true);
        n++;
      }
    }
    return n;
  }

  /// Copies saved outside the data folder (iPhone/iPad: Documents/THEapp
  /// Backups, visible in the Files app). Listed with the others so they can
  /// be restored; never pruned or changed by THEapp.
  Directory? copiesDir;

  String get _sep => Platform.pathSeparator;
  Directory get backupsDir => Directory('${root.path}${_sep}backups');

  Future<List<Directory>> list() async {
    final dirs = [
      ...await _listIn(backupsDir),
      if (copiesDir != null) ...await _listIn(copiesDir!),
    ];
    // Newest first (names start with the time stamp).
    dirs.sort((a, b) => _name(b).compareTo(_name(a)));
    return dirs;
  }

  Future<List<Directory>> _listIn(Directory parent) async {
    if (!await parent.exists()) return [];
    // Hidden folders (a backup still being written) are not backups.
    return parent
        .list()
        .where((e) => e is Directory && !_name(e).startsWith('.'))
        .cast<Directory>()
        .toList();
  }

  /// Whether [backup] is one of the copies outside the data folder.
  bool isCopy(Directory backup) =>
      copiesDir != null && backup.parent.path == copiesDir!.path;

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  Iterable<String> _folders({required bool attachments}) => [
    ..._sources,
    if (attachments) _attachments,
  ];

  /// Every file that belongs in a backup, as (relative path, file).
  Stream<(String, File)> _files(
    Directory base, {
    required bool attachments,
  }) async* {
    for (final name in _folders(attachments: attachments)) {
      final src = Directory('${base.path}$_sep$name');
      if (!await src.exists()) continue;
      await for (final entity in src.list(recursive: true)) {
        if (entity is! File) continue;
        final rel = entity.path.substring(base.path.length + 1);
        if (rel.endsWith('.tmp') || rel.contains('.trash')) continue;
        // Credentials never go into a backup or export (see [isSecret]).
        if (isSecret(rel)) continue;
        yield (rel, entity);
      }
    }
  }

  /// Copies every record file (and optionally attachments) into a new
  /// backup folder.
  Future<Directory> snapshot(
    String reason, {
    bool includeAttachments = false,
    DateTime? now,
  }) async {
    final name = '${_stamp(now ?? DateTime.now())}-$reason';
    var target = Directory('${backupsDir.path}$_sep$name');
    var n = 1;
    while (await target.exists()) {
      target = Directory('${backupsDir.path}$_sep$name-${n++}');
    }
    // Written under a hidden name and renamed only when complete, with its
    // manifest, so an interrupted copy is never mistaken for a backup.
    final partial = Directory(
      '${backupsDir.path}$_sep$partialPrefix${_name(target)}',
    );
    try {
      if (await partial.exists()) await partial.delete(recursive: true);
      await partial.create(recursive: true);
      await for (final (rel, file) in _files(
        root,
        attachments: includeAttachments,
      )) {
        final dest = File('${partial.path}$_sep$rel');
        await dest.parent.create(recursive: true);
        await file.copy(dest.path);
      }
      await writeManifest(
        partial,
        reason: reason,
        includesAttachments: includeAttachments,
      );
      await partial.rename(target.path);
      await FileProtection.protect([target.path], tree: true);
    } catch (_) {
      if (await partial.exists()) await partial.delete(recursive: true);
      rethrow;
    }
    await _prune();
    return target;
  }

  // ------------------------------------------------------------ manifest --

  static const manifestFile = 'manifest.json';
  static const manifestFormat = 'theapp-backup';
  static const manifestFormatVersion = 1;

  /// Files that hold credentials (device keys, API keys, OAuth tokens):
  /// never copied into a backup or export, and never replaced by a
  /// restore. A restored device keeps its own keys.
  static bool isSecret(String relativePath) {
    final name = relativePath.split(RegExp(r'[\\/]')).last.toLowerCase();
    return name.endsWith('.token') ||
        name.endsWith('.token.bak') ||
        name.endsWith('.key') ||
        name.endsWith('.client');
  }

  /// Schema versions written into each manifest (set by the app at start;
  /// informational, used to report what a backup holds).
  static Map<String, int> schemaVersions = const {};

  /// Writes `manifest.json` into [backup]: every file with its size and
  /// SHA-256, record counts per collection, and the schema versions. A
  /// backup is trusted only when [checkManifest] agrees with it.
  Future<File> writeManifest(
    Directory backup, {
    required String reason,
    bool? includesAttachments,
  }) async {
    final files = <Map<String, dynamic>>[];
    final counts = <String, int>{};
    final entities = await backup.list(recursive: true).toList();
    entities.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entities) {
      if (e is! File) continue;
      final rel = _rel(backup, e);
      if (rel == manifestFile) continue;
      files.add({
        'path': rel,
        'size': await e.length(),
        'sha256': (await sha256.bind(e.openRead()).first).toString(),
      });
      if (rel.startsWith('data/') && rel.endsWith('.json')) {
        try {
          final json = jsonDecode(await StorageEncryption.readText(e, _cipher));
          final records = json is Map ? json['records'] : null;
          if (records is List) {
            counts[rel.substring(5, rel.length - 5)] = records.length;
          }
        } on FormatException {
          // Reported as unreadable by checkManifest.
        } on DecryptionFailure {
          // Reported as unreadable by checkManifest.
        }
      }
    }
    final manifest = File('${backup.path}$_sep$manifestFile');
    await StorageEncryption.writeText(
      manifest,
      const JsonEncoder.withIndent(' ').convert({
        'format': manifestFormat,
        'formatVersion': manifestFormatVersion,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'appBuild': appBuild,
        'reason': reason,
        'schemas': schemaVersions,
        'includesAttachments':
            includesAttachments ??
            await Directory('${backup.path}$_sep$_attachments').exists(),
        'secretsIncluded': false,
        'recordCounts': counts,
        'files': files,
      }),
      _cipher,
    );
    return manifest;
  }

  /// Checks [backup] against its manifest: every listed file is present
  /// with the same size and SHA-256, and every record file parses as JSON.
  /// Returns the problems found (empty = the backup is intact). A backup
  /// without a manifest (made by an older version) is reported as such.
  Future<List<String>> checkManifest(Directory backup) async {
    final problems = <String>[];
    final manifest = File('${backup.path}$_sep$manifestFile');
    if (!await manifest.exists()) return ['No manifest (older backup).'];
    Map<String, dynamic> json;
    try {
      json = jsonDecode(
        await StorageEncryption.readText(manifest, _cipher),
      ) as Map<String, dynamic>;
    } catch (_) {
      return ['The manifest is damaged.'];
    }
    if (json['format'] != manifestFormat) return ['Not a THEapp backup.'];
    for (final entry in (json['files'] as List? ?? const [])) {
      final rel = (entry as Map)['path'] as String;
      final file = File('${backup.path}$_sep${rel.replaceAll('/', _sep)}');
      if (!await file.exists()) {
        problems.add('Missing: $rel');
        continue;
      }
      if (await file.length() != entry['size']) {
        problems.add('Wrong size: $rel');
        continue;
      }
      final sha = (await sha256.bind(file.openRead()).first).toString();
      if (sha != entry['sha256']) {
        problems.add('Checksum mismatch: $rel');
        continue;
      }
      if (rel.endsWith('.json') && !rel.startsWith('attachments/')) {
        try {
          jsonDecode(await StorageEncryption.readText(file, _cipher));
        } on FormatException {
          problems.add('Unreadable: $rel');
        } on DecryptionFailure {
          problems.add('Unreadable (wrong key or changed data): $rel');
        } on StorageLockedException {
          problems.add('Encrypted, and this device has no key: $rel');
        }
      }
    }
    return problems;
  }

  /// The manifest of [backup], or null if it has none or it is damaged.
  Future<Map<String, dynamic>?> readManifest(Directory backup) async {
    try {
      final f = File('${backup.path}$_sep$manifestFile');
      if (!await f.exists()) return null;
      return jsonDecode(await StorageEncryption.readText(f, _cipher))
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  String _rel(Directory base, File file) =>
      file.path.substring(base.path.length + 1).replaceAll(_sep, '/');

  /// True if every file currently in the live folders has an identical copy
  /// in [backup] (records, plus attachments if the backup contains them).
  Future<bool> verify(Directory backup) async {
    final withAttachments =
        await Directory('${backup.path}$_sep$_attachments').exists() ||
        !await Directory('${root.path}$_sep$_attachments').exists();
    try {
      await for (final (rel, file) in _files(
        root,
        attachments: withAttachments,
      )) {
        final copy = File('${backup.path}$_sep$rel');
        if (!await copy.exists()) return false;
        if (await copy.length() != await file.length()) return false;
        final a = await file.readAsBytes();
        final b = await copy.readAsBytes();
        for (var i = 0; i < a.length; i++) {
          if (a[i] != b[i]) return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Makes a daily automatic backup of the records, and once a week one
  /// that also holds photos and PDFs (so a copy of everything exists even
  /// if the attachments folder is lost).
  ///
  /// [every] is how often the records-only backup is made between the weekly
  /// full ones (default: each day; Settings → Data & Storage can choose a
  /// week). The weekly full backup is made either way.
  Future<void> automaticBackup({
    DateTime? now,
    Duration every = const Duration(days: 1),
  }) async {
    final at = now ?? DateTime.now();
    final own = await _listIn(backupsDir);
    final fulls = own.where((d) => _isReason(d, 'auto-full'));
    final weekAgo = _stamp(at.subtract(fullEvery));
    if (!fulls.any((d) => _name(d).compareTo(weekAgo) > 0)) {
      await snapshot('auto-full', includeAttachments: true, now: at);
      return; // it holds today's records too
    }
    if (every > const Duration(days: 1)) {
      final since = _stamp(at.subtract(every));
      final recent = own.any(
        (d) =>
            (_isReason(d, 'auto') || _isReason(d, 'auto-full')) &&
            _name(d).compareTo(since) > 0,
      );
      if (!recent) await snapshot('auto', now: at);
      return;
    }
    final today = _stamp(at).substring(0, 8);
    final hasToday = own.any(
      (d) =>
          (_isReason(d, 'auto') || _isReason(d, 'auto-full')) &&
          _name(d).startsWith(today),
    );
    if (!hasToday) await snapshot('auto', now: at);
  }

  /// Removes an expired calendar entry from every backup folder THEapp
  /// manages, including its exported app-container copies. The deletion
  /// tombstone and expiration ledger are inserted into older backups too, so
  /// restoring one on another device cannot resurrect the record.
  ///
  /// Calendar attachments are shared Archive assets, so this method removes
  /// only the expired entry reference; it never deletes an asset that may be
  /// independently saved or used elsewhere.
  Future<void> purgeExpiredCalendarEntry({
    required String id,
    required String tombstoneRev,
  }) async {
    for (final backup in await list()) {
      // Work out every change first; a backup that needs none is not
      // touched (this runs at each start for every expired entry).
      final writes = <File, String>{};
      final copies = <File, File>{};
      final deletes = <File>[];
      final collectionFile = File(
        '${backup.path}$_sep$dataDir$_sep$calendarEntriesFile',
      );
      for (final suffix in ['', '.bak']) {
        final file = File('${collectionFile.path}$suffix');
        if (!await file.exists()) continue;
        final text = await StorageEncryption.readText(file, _cipher);
        final json = jsonDecode(text);
        if (json is! Map<String, dynamic>) {
          throw FormatException('Invalid calendar collection in $file');
        }
        final records = (json['records'] as List? ?? const [])
            .where((raw) => raw is! Map || raw['id'] != id)
            .toList();
        final revs = Map<String, dynamic>.of(
          (json['revs'] as Map?)?.cast<String, dynamic>() ?? const {},
        )..remove(id);
        final tombstones = Map<String, dynamic>.of(
          (json['tombstones'] as Map?)?.cast<String, dynamic>() ?? const {},
        )..[id] = tombstoneRev;
        final recentlyDeleted = Map<String, dynamic>.of(
          (json['recentlyDeleted'] as Map?)?.cast<String, dynamic>() ??
              const {},
        )..remove(id);
        final purged = {
          ...json,
          'records': records,
          'revs': revs,
          'tombstones': tombstones,
        }..remove('recentlyDeleted');
        if (recentlyDeleted.isNotEmpty) {
          purged['recentlyDeleted'] = recentlyDeleted;
        }
        final hadRecord =
            (json['records'] as List? ?? const []).length != records.length;
        final hadKept = (json['recentlyDeleted'] as Map?)?.containsKey(id);
        if (hadRecord ||
            hadKept == true ||
            (json['revs'] as Map?)?.containsKey(id) == true ||
            (json['tombstones'] as Map?)?[id] != tombstoneRev) {
          writes[file] = const JsonEncoder.withIndent(' ').convert(purged);
        }
      }

      // A damaged sidecar is never used for restore; remove it because its
      // bytes may still contain the expired record and the valid collection
      // copies above remain available.
      final backupDataDir = Directory('${backup.path}$_sep$dataDir');
      if (await backupDataDir.exists()) {
        await for (final file in backupDataDir.list()) {
          if (file is File &&
              file.uri.pathSegments.last.startsWith(
                '$calendarEntriesFile.corrupt-',
              )) {
            deletes.add(file);
          }
        }
      }

      for (final rel in [
        'data$_sep$calendarExpirationsFile',
        'retention$_sep$expirationLedgerFile',
      ]) {
        final source = File('${root.path}$_sep$rel');
        if (!await source.exists()) continue;
        final target = File('${backup.path}$_sep$rel');
        if (await target.exists() && await _sameContent(target, source)) {
          continue;
        }
        copies[target] = source;
      }
      if (writes.isEmpty && copies.isEmpty && deletes.isEmpty) continue;

      // The purge is an intended change to files the manifest lists: a
      // backup that was intact gets a manifest with the new checksums. One
      // that was already damaged keeps its old manifest (still failing).
      final manifest = await readManifest(backup);
      final intact = manifest != null && (await checkManifest(backup)).isEmpty;
      for (final MapEntry(key: file, value: text) in writes.entries) {
        await _atomicWrite(file, text);
      }
      for (final file in deletes) {
        await file.delete();
      }
      for (final MapEntry(key: target, value: source) in copies.entries) {
        await target.parent.create(recursive: true);
        final staging = File('${target.path}.purge.tmp');
        await source.copy(staging.path);
        await _replace(staging, target);
      }
      if (intact) {
        await writeManifest(
          backup,
          reason: manifest['reason'] as String? ?? 'unknown',
          includesAttachments: manifest['includesAttachments'] as bool?,
        );
      }
    }
  }

  /// Whether two stored files hold the same content (each encryption of the
  /// same content differs, so ciphertext is never compared).
  Future<bool> _sameContent(File a, File b) async {
    try {
      return await StorageEncryption.readText(a, _cipher) ==
          await StorageEncryption.readText(b, _cipher);
    } on DecryptionFailure {
      return false;
    }
  }

  Future<void> _atomicWrite(File target, String content) async {
    final staging = File('${target.path}.purge.tmp');
    await StorageEncryption.writeText(staging, content, _cipher);
    await _replace(staging, target);
  }

  /// Removes records that were deleted for good from every backup THEapp
  /// manages (the data folder's backups and the saved copies): their content,
  /// their "recently deleted" copy, damaged-file leftovers, and the
  /// attachment files named in [attachmentFiles]. [records] is
  /// collection -> {id: tombstone revision}. A tombstone takes each record's
  /// place, so a restore of the backup cannot bring it back. Backups that were
  /// intact get a new manifest; the retention policy (which backups exist and
  /// how many) is untouched. A backup made under another key cannot be opened
  /// here and is left alone.
  Future<void> purgeRecords({
    required Map<String, Map<String, String>> records,
    List<String> attachmentFiles = const [],
  }) async {
    for (final backup in await list()) {
      final writes = <File, String>{};
      final deletes = <File>[];
      try {
        for (final MapEntry(key: collection, value: ids) in records.entries) {
          final base = File('${backup.path}$_sep$dataDir$_sep$collection.json');
          for (final suffix in ['', '.bak']) {
            final file = File('${base.path}$suffix');
            if (!await file.exists()) continue;
            final json = jsonDecode(
              await StorageEncryption.readText(file, _cipher),
            );
            if (json is! Map<String, dynamic>) continue;
            final all = (json['records'] as List? ?? const []);
            final records = all
                .where((raw) => raw is! Map || !ids.containsKey(raw['id']))
                .toList();
            final revs = Map<String, dynamic>.of(
              (json['revs'] as Map?)?.cast<String, dynamic>() ?? const {},
            );
            final tombstones = Map<String, dynamic>.of(
              (json['tombstones'] as Map?)?.cast<String, dynamic>() ?? const {},
            );
            final recentlyDeleted = Map<String, dynamic>.of(
              (json['recentlyDeleted'] as Map?)?.cast<String, dynamic>() ??
                  const {},
            );
            var changed = records.length != all.length;
            for (final MapEntry(key: id, value: rev) in ids.entries) {
              if (revs.remove(id) != null) changed = true;
              if (recentlyDeleted.remove(id) != null) changed = true;
              if (tombstones[id] != rev) {
                tombstones[id] = rev;
                changed = true;
              }
            }
            if (!changed) continue;
            final purged = {
              ...json,
              'records': records,
              'revs': revs,
              'tombstones': tombstones,
            }..remove('recentlyDeleted');
            if (recentlyDeleted.isNotEmpty) {
              purged['recentlyDeleted'] = recentlyDeleted;
            }
            writes[file] = const JsonEncoder.withIndent(' ').convert(purged);
          }
          final dataFolder = Directory('${backup.path}$_sep$dataDir');
          if (await dataFolder.exists()) {
            await for (final f in dataFolder.list()) {
              if (f is File &&
                  f.uri.pathSegments.last.startsWith(
                    '$collection.json.corrupt-',
                  )) {
                deletes.add(f);
              }
            }
          }
        }
      } on DecryptionFailure {
        continue; // another device's backup: not ours to change
      } on StorageLockedException {
        continue;
      }
      for (final name in attachmentFiles) {
        final f = File('${backup.path}$_sep$_attachments$_sep$name');
        if (await f.exists()) deletes.add(f);
      }
      if (writes.isEmpty && deletes.isEmpty) continue;
      final manifest = await readManifest(backup);
      final intact = manifest != null && (await checkManifest(backup)).isEmpty;
      for (final MapEntry(key: file, value: text) in writes.entries) {
        await _atomicWrite(file, text);
      }
      for (final f in deletes) {
        await f.delete();
      }
      if (intact) {
        await writeManifest(
          backup,
          reason: manifest['reason'] as String? ?? 'unknown',
          includesAttachments: manifest['includesAttachments'] as bool?,
        );
      }
    }
  }

  /// A restore replaces live data, so first make sure this device's key
  /// opens the backup. A backup made under another key (another device, or a
  /// lost key) is left untouched and nothing is changed; no key is invented.
  Future<void> _requireReadable(Directory backup) async {
    await for (final (_, file) in _files(backup, attachments: false)) {
      if (!await FileCipher.fileIsEncrypted(file)) continue;
      try {
        await StorageEncryption.readBytes(file, _cipher);
      } on DecryptionFailure {
        throw FileSystemException(_wrongKeyMessage, backup.path);
      } on StorageLockedException {
        throw FileSystemException(_wrongKeyMessage, backup.path);
      }
    }
  }

  static const _wrongKeyMessage =
      'This backup is encrypted with a key this device does not have (it '
      'was made on another device, or the key was lost). The backup was '
      'kept untouched and nothing was changed. Backups can only be opened '
      'with the key of the device that made them.';

  Future<void> _replace(File source, File target) async {
    if (Platform.isWindows) {
      win.replaceFileAtomically(source.path, target.path);
    } else {
      await source.rename(target.path);
    }
  }

  /// Copies [backup] into [destination] (e.g. Documents/THEapp Backups on
  /// iPhone/iPad, visible in the Files app) and checks every file arrived
  /// unchanged. Returns the copy.
  Future<Directory> copyTo(Directory backup, Directory destination) async {
    final target = Directory('${destination.path}$_sep${_name(backup)}');
    if (await target.exists()) {
      throw FileSystemException(
        'A copy with this name already exists',
        target.path,
      );
    }
    var staging = Directory('${target.path}.partial');
    var suffix = 1;
    while (await staging.exists()) {
      staging = Directory('${target.path}.partial-$suffix');
      suffix++;
    }
    await for (final entity in backup.list(recursive: true)) {
      if (entity is! File) continue;
      final rel = entity.path.substring(backup.path.length + 1);
      final dest = File('${staging.path}$_sep$rel');
      await dest.parent.create(recursive: true);
      await entity.copy(dest.path);
      final sourceBytes = await entity.readAsBytes();
      final copiedBytes = await dest.readAsBytes();
      if (sourceBytes.length != copiedBytes.length) {
        throw FileSystemException('Copy is incomplete', dest.path);
      }
      for (var i = 0; i < sourceBytes.length; i++) {
        if (sourceBytes[i] != copiedBytes[i]) {
          throw FileSystemException('Copy verification failed', dest.path);
        }
      }
    }
    await staging.create(recursive: true);
    // Only a complete copy gets its final name.
    final done = await staging.rename(target.path);
    await FileProtection.protect([done.path], tree: true);
    return done;
  }

  String _name(Directory d) =>
      d.uri.pathSegments.where((s) => s.isNotEmpty).last;

  // ------------------------------------------------------- backup files --

  /// Makes a complete backup (records, photos, PDFs), checks it, and packs it
  /// into one `.theappbackup` file at [out]. The file is the backup: the
  /// temporary backup folder it was made from is removed again. [out] is
  /// replaced only when the new file is complete.
  Future<File> exportFile(File out, {DateTime? now}) async {
    final backup = await snapshot(
      'export',
      includeAttachments: true,
      now: now,
    );
    try {
      if (!await verify(backup)) {
        throw const FileSystemException(
          'The data changed while the backup was made; try again',
        );
      }
      final problems = await checkManifest(backup);
      if (problems.isNotEmpty) {
        throw FileSystemException('The backup failed its check: ${problems.first}');
      }
      final file = await BackupFile.pack(backup, out);
      if (!await BackupFile.looksLikeBackup(file)) {
        await file.delete();
        throw const FileSystemException('The exported file could not be read back');
      }
      return file;
    } finally {
      if (await backup.exists()) await backup.delete(recursive: true);
    }
  }

  /// Adds the backup inside [file] (a `.theappbackup`) to the list of
  /// backups, after checking every file against its manifest. Live data is
  /// not touched: restoring it is a separate, confirmed step ([restore]).
  /// Throws if the file is not a THEapp backup, is incomplete, or fails its
  /// check; nothing is added then.
  Future<Directory> importFile(File file, {DateTime? now}) async {
    final name = '${_stamp(now ?? DateTime.now())}-imported';
    var target = Directory('${backupsDir.path}$_sep$name');
    for (var n = 1; await target.exists(); n++) {
      target = Directory('${backupsDir.path}$_sep$name-$n');
    }
    final partial = Directory(
      '${backupsDir.path}$_sep$partialPrefix${_name(target)}',
    );
    try {
      if (await partial.exists()) await partial.delete(recursive: true);
      await partial.create(recursive: true);
      await BackupFile.unpack(file, partial);
      final problems = await checkManifest(partial);
      if (problems.isNotEmpty) {
        throw BackupFileException(
          'The backup file failed its check (${problems.first}); nothing was '
          'added.',
        );
      }
      final done = await partial.rename(target.path);
      await FileProtection.protect([done.path], tree: true);
      return done;
    } catch (_) {
      if (await partial.exists()) await partial.delete(recursive: true);
      rethrow;
    }
  }

  /// How much room each kind of data takes, in bytes.
  Future<({int records, int attachments, int backups})> usage() async {
    Future<int> size(Directory d) async {
      if (!await d.exists()) return 0;
      var total = 0;
      await for (final e in d.list(recursive: true)) {
        if (e is File) total += await e.length();
      }
      return total;
    }

    var records = 0;
    for (final name in _sources) {
      records += await size(Directory('${root.path}$_sep$name'));
    }
    return (
      records: records,
      attachments: await size(Directory('${root.path}$_sep$_attachments')),
      backups: await size(backupsDir),
    );
  }

  /// Backups that are never removed automatically, by reason (the end of the
  /// folder name): the state before the first sync with a hub.
  static const protectedReasons = {
    'before-first-sync',
    'pre-migration',
    'pre-encryption',
  };

  static const dataDir = 'data';
  static const calendarEntriesFile = 'calendar_entries.json';
  static const calendarExpirationsFile = 'calendar_entry_expirations.json';
  static const expirationLedgerFile = 'expired_calendar_entries.json';

  /// Whether [d] was made for [reason] (a second backup in the same second
  /// gets "-1", "-2", … after it).
  bool _isReason(Directory d, String reason) =>
      RegExp('-${RegExp.escape(reason)}(-\\d+)?\$').hasMatch(_name(d));

  bool _isProtected(Directory d) => protectedReasons.any(
    (r) => RegExp('-$r(-[a-z0-9-]+)?\$').hasMatch(_name(d)),
  );

  /// Keeps a bounded number of backups. The newest pre-upgrade backup and
  /// [protectedReasons] backups are never removed.
  Future<void> _prune() async {
    // Only backups in the data folder; copies saved elsewhere are the
    // user's and are never removed.
    final all =
        (await _listIn(backupsDir)).where((d) => !_isProtected(d)).toList()
          ..sort((a, b) => _name(b).compareTo(_name(a)));
    final autos = all.where((d) => _isReason(d, 'auto')).toList();
    for (final old in autos.skip(keepAutomatic)) {
      await old.delete(recursive: true);
    }
    final fulls = all.where((d) => _isReason(d, 'auto-full')).toList();
    for (final old in fulls.skip(keepFull)) {
      await old.delete(recursive: true);
    }
    final live = all.where((d) => _isReason(d, 'live')).toList();
    for (final old in live.skip(keepLive)) {
      await old.delete(recursive: true);
    }
    final others = all
        .where(
          (d) =>
              !_isReason(d, 'auto') &&
              !_isReason(d, 'auto-full') &&
              !_isReason(d, 'live'),
        )
        .toList();
    // Pre-upgrade backups: "pre-v<schema>" and "pre-level<n>".
    final newestPre = others
        .where((d) => _name(d).contains('-pre-'))
        .firstOrNull;
    for (final old in others.skip(keepOther)) {
      if (old.path == newestPre?.path) continue;
      await old.delete(recursive: true);
    }
  }

  /// Copies the backup's records into [target] (an empty folder elsewhere),
  /// e.g. to inspect a backup without touching live data.
  Future<void> restoreTo(Directory backup, Directory target) async {
    await for (final (rel, file) in _files(backup, attachments: true)) {
      final dest = File('${target.path}$_sep$rel');
      await dest.parent.create(recursive: true);
      await file.copy(dest.path);
    }
    await FileProtection.protect([target.path], tree: true);
  }

  /// Replaces current records with those in [backup].
  ///
  /// The current state is backed up first (so a restore can be undone).
  /// The backup is copied into a staging folder and checked before the
  /// live folders are swapped, so a failure part-way leaves the live data
  /// as it was. Attachments are only ever added, never replaced.
  Future<void> restore(Directory backup) async {
    // A backup with a manifest must match it before anything is replaced.
    if (await readManifest(backup) != null) {
      final problems = await checkManifest(backup);
      if (problems.isNotEmpty) {
        throw FileSystemException(
          'This backup failed its check (${problems.first}); nothing was '
          'changed',
          backup.path,
        );
      }
    }
    await _requireReadable(backup);
    await snapshot('before-restore');
    final staging = Directory(
      '${root.path}$_sep.restore-${DateTime.now().millisecondsSinceEpoch}',
    );
    await restoreTo(backup, staging);
    // Each live folder is moved aside (not deleted) before its replacement
    // goes in, and the moved-aside folders are only deleted once every swap
    // succeeded. If anything fails part-way, they are put back, so a failed
    // restore leaves the data as it was.
    final swapped = <(Directory current, Directory old)>[];
    try {
      for (final name in _sources) {
        final current = Directory('${root.path}$_sep$name');
        final staged = Directory('${staging.path}$_sep$name');
        final old = Directory(
          '${root.path}$_sep.replaced-$name-${DateTime.now().millisecondsSinceEpoch}',
        );
        if (await current.exists()) await current.rename(old.path);
        swapped.add((current, old));
        if (await staged.exists()) {
          await staged.rename(current.path);
        } else {
          await current.create(recursive: true);
        }
        // Trash folders are not in backups: keep them (e.g. deleted notes'
        // handwriting, which "Recently deleted" can still bring back).
        await _keepTrash(old, current);
        // This device's keys stay (backups never hold them).
        await _keepSecrets(old, current);
      }
    } catch (_) {
      for (final (current, old) in swapped.reversed) {
        try {
          if (!await old.exists()) continue;
          if (await current.exists()) {
            await current.rename('${current.path}.failed-restore');
          }
          await old.rename(current.path);
        } catch (_) {
          // The moved-aside folder stays on disk next to the data folder.
        }
      }
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
    for (final (_, old) in swapped) {
      if (await old.exists()) await old.delete(recursive: true);
    }
    // Forget what the restored data last synced, so a paired hub treats the
    // restored records as changes to offer (restoring deleted ones, keeping
    // newer versions from other devices as conflicts) instead of quietly
    // overwriting them with its own newer versions on the next sync.
    for (final name in ['client_state.json', 'client_state.json.bak']) {
      final f = File('${root.path}${_sep}sync$_sep$name');
      if (await f.exists()) await f.delete();
    }
    // Bring back attachments the backup has but the live folder lost.
    final stagedAttachments = Directory('${staging.path}$_sep$_attachments');
    if (await stagedAttachments.exists()) {
      final live = Directory('${root.path}$_sep$_attachments');
      await live.create(recursive: true);
      await for (final e in stagedAttachments.list()) {
        if (e is! File) continue;
        final dest = File('${live.path}$_sep${e.uri.pathSegments.last}');
        if (!await dest.exists()) await e.copy(dest.path);
      }
    }
    await staging.delete(recursive: true);
    // Restored files are protected like any other (also on the iPad).
    await FileProtection.protect([root.path], tree: true);
  }

  /// Moves credential files ([isSecret]) from [from] into the same place
  /// under [to] when [to] has none there.
  Future<void> _keepSecrets(Directory from, Directory to) async {
    if (!await from.exists()) return;
    await for (final e in from.list(recursive: true)) {
      if (e is! File) continue;
      final rel = e.path.substring(from.path.length + 1);
      if (!isSecret(rel)) continue;
      final target = File('${to.path}$_sep$rel');
      if (await target.exists()) continue;
      await target.parent.create(recursive: true);
      await e.rename(target.path);
    }
  }

  /// Moves every `.trash` folder (at any depth) from [from] into the same
  /// place under [to], merging with what is there.
  Future<void> _keepTrash(Directory from, Directory to) async {
    if (!await from.exists()) return;
    final trashes = await from
        .list(recursive: true)
        .where((e) => e is Directory && e.uri.pathSegments.contains('.trash'))
        .cast<Directory>()
        .where((d) => _name(d) == '.trash')
        .toList();
    for (final trash in trashes) {
      final rel = trash.path.substring(from.path.length);
      final dest = Directory('${to.path}$rel');
      await dest.create(recursive: true);
      await for (final f in trash.list()) {
        if (f is! File) continue;
        final target = File('${dest.path}$_sep${f.uri.pathSegments.last}');
        if (!await target.exists()) await f.rename(target.path);
      }
    }
  }
}
