import 'dart:io';
import 'dart:convert';

import '../../platform/windows_native.dart' as win;

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

  /// Folders that hold records.
  static const _sources = [
    'canvases',
    'data',
    'settings',
    'sync',
    'canvas_snapshots', // named mindmap versions
    'retention', // permanent calendar-expiration ledger
  ];
  static const _attachments = 'attachments';
  static const keepAutomatic = 14;

  /// Manual, pre-upgrade and before-restore backups kept (oldest go first).
  static const keepOther = 20;

  /// Weekly automatic backups that include photos and PDFs.
  static const keepFull = 4;
  static const fullEvery = Duration(days: 7);

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
    return parent
        .list()
        .where((e) => e is Directory)
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
    var target = Directory(
      '${backupsDir.path}$_sep${_stamp(now ?? DateTime.now())}-$reason',
    );
    var n = 1;
    while (await target.exists()) {
      target = Directory('${target.path}-${n++}');
    }
    await for (final (rel, file) in _files(
      root,
      attachments: includeAttachments,
    )) {
      final dest = File('${target.path}$_sep$rel');
      await dest.parent.create(recursive: true);
      await file.copy(dest.path);
    }
    await target.create(recursive: true);
    await _prune();
    return target;
  }

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
  Future<void> automaticBackup({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final own = await _listIn(backupsDir);
    final fulls = own.where((d) => _isReason(d, 'auto-full'));
    final weekAgo = _stamp(at.subtract(fullEvery));
    if (!fulls.any((d) => _name(d).compareTo(weekAgo) > 0)) {
      await snapshot('auto-full', includeAttachments: true, now: at);
      return; // it holds today's records too
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
      final collectionFile = File(
        '${backup.path}$_sep$dataDir$_sep$calendarEntriesFile',
      );
      for (final suffix in ['', '.bak']) {
        final file = File('${collectionFile.path}$suffix');
        if (await file.exists()) {
          final json = jsonDecode(await file.readAsString());
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
          await _atomicWrite(
            file,
            const JsonEncoder.withIndent(' ').convert({
              ...json,
              'records': records,
              'revs': revs,
              'tombstones': tombstones,
            }),
          );
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
            await file.delete();
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
        await target.parent.create(recursive: true);
        final staging = File('${target.path}.purge.tmp');
        await source.copy(staging.path);
        await _replace(staging, target);
      }
    }
  }

  Future<void> _atomicWrite(File target, String content) async {
    final staging = File('${target.path}.purge.tmp');
    await staging.writeAsString(content, flush: true);
    await _replace(staging, target);
  }

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
    return staging.rename(target.path);
  }

  String _name(Directory d) =>
      d.uri.pathSegments.where((s) => s.isNotEmpty).last;

  /// Backups that are never removed automatically, by reason (the end of the
  /// folder name): the state before the first sync with a hub.
  static const protectedReasons = {'before-first-sync'};

  static const dataDir = 'data';
  static const calendarEntriesFile = 'calendar_entries.json';
  static const calendarExpirationsFile = 'calendar_entry_expirations.json';
  static const expirationLedgerFile = 'expired_calendar_entries.json';

  /// Whether [d] was made for [reason] (a second backup in the same second
  /// gets "-1", "-2", … after it).
  bool _isReason(Directory d, String reason) =>
      RegExp('-${RegExp.escape(reason)}(-\\d+)?\$').hasMatch(_name(d));

  bool _isProtected(Directory d) =>
      protectedReasons.any((r) => RegExp('-$r(-\\d+)?\$').hasMatch(_name(d)));

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
    final others = all
        .where((d) => !_isReason(d, 'auto') && !_isReason(d, 'auto-full'))
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
  }

  /// Replaces current records with those in [backup].
  ///
  /// The current state is backed up first (so a restore can be undone).
  /// The backup is copied into a staging folder and checked before the
  /// live folders are swapped, so a failure part-way leaves the live data
  /// as it was. Attachments are only ever added, never replaced.
  Future<void> restore(Directory backup) async {
    await snapshot('before-restore');
    final staging = Directory(
      '${root.path}$_sep.restore-${DateTime.now().millisecondsSinceEpoch}',
    );
    await restoreTo(backup, staging);
    for (final name in _sources) {
      final current = Directory('${root.path}$_sep$name');
      final staged = Directory('${staging.path}$_sep$name');
      final old = Directory(
        '${root.path}$_sep.replaced-$name-${DateTime.now().millisecondsSinceEpoch}',
      );
      if (await current.exists()) await current.rename(old.path);
      if (await staged.exists()) {
        await staged.rename(current.path);
      } else {
        await current.create(recursive: true);
      }
      // Trash folders are not in backups: keep them (e.g. deleted notes'
      // handwriting, which "Recently deleted" can still bring back).
      await _keepTrash(old, current);
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
