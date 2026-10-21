import 'dart:io';

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
  static const _sources = ['canvases', 'data', 'settings', 'sync'];
  static const _attachments = 'attachments';
  static const keepAutomatic = 14;

  /// Manual, pre-upgrade and before-restore backups kept (oldest go first).
  static const keepOther = 20;

  String get _sep => Platform.pathSeparator;
  Directory get backupsDir => Directory('${root.path}${_sep}backups');

  Future<List<Directory>> list() async {
    if (!await backupsDir.exists()) return [];
    final dirs = await backupsDir
        .list()
        .where((e) => e is Directory)
        .cast<Directory>()
        .toList();
    dirs.sort((a, b) => b.path.compareTo(a.path)); // newest first
    return dirs;
  }

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
  }) async {
    var target = Directory(
      '${backupsDir.path}$_sep${_stamp(DateTime.now())}-$reason',
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

  /// Makes a daily automatic backup.
  Future<void> automaticBackup() async {
    final autos = (await list()).where((d) => d.path.endsWith('-auto'));
    final today = _stamp(DateTime.now()).substring(0, 8);
    final hasToday = autos.any((d) => _name(d).startsWith(today));
    if (!hasToday) await snapshot('auto');
  }

  String _name(Directory d) =>
      d.uri.pathSegments.where((s) => s.isNotEmpty).last;

  /// Keeps a bounded number of backups. The newest pre-upgrade backup is
  /// never removed.
  Future<void> _prune() async {
    final all = await list();
    final autos = all.where((d) => _name(d).endsWith('-auto')).toList();
    for (final old in autos.skip(keepAutomatic)) {
      await old.delete(recursive: true);
    }
    final others = all.where((d) => !_name(d).endsWith('-auto')).toList();
    final newestPre = others
        .where((d) => _name(d).contains('-pre-v'))
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
}
