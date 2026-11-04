// What the Data & Storage page does with backups: export everything to one
// `.theappbackup` file, import one, describe a backup, and restore it. All the
// work is BackupService's (checked copies, manifests, staged restore with a
// safety copy first); this file only asks the user, calls it, and reports in
// plain words.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/storage/app_log.dart';
import '../../data/storage/backup_file.dart';
import '../../platform/platform.dart' as native;
import '../../widgets/common.dart';
import '../export/exports.dart';

/// Chooses the file to import; replaceable in tests.
Future<List<String>> Function() pickBackupPath = () async =>
    List<String>.of(await native.pickBackupFile());

/// "14.2 MB"
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// What a backup folder's name says: when, and why it was made.
class BackupLabel {
  BackupLabel(this.directory) {
    final name = directory.uri.pathSegments.where((p) => p.isNotEmpty).last;
    this.name = name;
    final m = RegExp(
      r'^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-(.*)$',
    ).firstMatch(name);
    if (m != null) {
      at = DateTime(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
        int.parse(m.group(6)!),
      );
      reasonId = m.group(7)!.replaceFirst(RegExp(r'-\d+$'), '');
    }
  }

  final Directory directory;
  late final String name;
  DateTime? at;
  String reasonId = '';

  String get reason => switch (reasonId) {
    'auto' => 'Automatic',
    'auto-full' => 'Automatic, with photos & PDFs',
    'live' => 'Automatic, while open',
    'manual' => 'Manual',
    'export' => 'Export',
    'imported' => 'Imported from a file',
    'before-restore' => 'Safety copy before a restore',
    'before-first-sync' => 'Before the first sync',
    final r when r.startsWith('pre-') => 'Safety copy before a data upgrade',
    '' => name,
    final other => other,
  };

  /// "Today 14:05", "Yesterday 09:30", "12 Oct 2026, 18:40".
  String when([DateTime? now]) {
    final t = at;
    if (t == null) return name;
    final today = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(t.hour)}:${two(t.minute)}';
    final days = DateTime(today.year, today.month, today.day)
        .difference(DateTime(t.year, t.month, t.day))
        .inDays;
    if (days == 0) return 'Today $time';
    if (days == 1) return 'Yesterday $time';
    return '${formatShortDate(t)}, ${t.year} · $time';
  }
}

String _stampName(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'THEapp-backup-${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// Exports everything (records, photos, PDFs) to one `.theappbackup` file:
/// asks where on Windows, saves to the exports folder and opens the share
/// sheet on iPhone/iPad (Save to Files, iCloud Drive, AirDrop…). Returns the
/// file, or null if cancelled or it failed (the reason is shown).
Future<File?> exportAllData(AppState s) async {
  File? target;
  final name = _stampName(DateTime.now());
  final folder = exportsFolder(s);
  try {
    await folder.create(recursive: true);
  } on FileSystemException {
    // The Save dialog then opens in its own default folder.
  }
  if (hasExportDialog) {
    final path = askExportPath(
      suggestedName: '$name.$backupFileExtension',
      extension: backupFileExtension,
      typeLabel: 'misc. backup',
      initialDir: folder.path,
    );
    if (path == null) {
      s.showToast('Export cancelled. Nothing was saved.');
      return null;
    }
    target = File(path);
  } else {
    target = freshFile(folder, name, backupFileExtension);
  }
  try {
    await s.flush();
    final file = await s.workspace.backups.exportFile(target);
    AppLog.info('Exported a backup file (${await file.length()} bytes)');
    s.showToast(
      'Saved ${file.path} (${formatBytes(await file.length())}). '
      'Keep it somewhere safe, outside misc.',
    );
    await revealExport(s, file);
    return file;
  } on FileSystemException catch (e, st) {
    AppLog.error('Backup export failed', e, st);
    s.showToast('Could not save the backup: ${e.message}. Nothing was changed.');
  } on BackupFileException catch (e) {
    s.showToast(e.message);
  }
  return null;
}

/// Lets the user pick a `.theappbackup`, checks it, and adds it to the list of
/// backups. Nothing live is changed; restoring it is a separate step.
Future<Directory?> importBackupFile(AppState s) async {
  final picked = await pickBackupPath();
  if (picked.isEmpty) return null;
  final file = File(picked.first);
  try {
    final backup = await s.workspace.backups.importFile(file);
    AppLog.info('Imported a backup file');
    s.showToast(
      'Backup added to your list. Open it to check it and restore it.',
    );
    return backup;
  } on BackupFileException catch (e) {
    s.showToast(e.message);
  } on FileSystemException catch (e, st) {
    AppLog.error('Backup import failed', e, st);
    s.showToast('Could not read that file: ${e.message}. Nothing was changed.');
  }
  return null;
}

/// Confirms, makes a safety copy of the current data, replaces it with
/// [backup], and closes THEapp so it opens on the restored data. If the
/// restore fails, the data is as it was and THEapp keeps running.
Future<void> restoreBackup(
  BuildContext context,
  AppState s,
  Directory backup,
) async {
  final label = BackupLabel(backup);
  final ok = await confirm(
    context,
    title: 'Restore this backup?',
    message:
        'Your current data is backed up first, then replaced with the '
        'backup from ${label.when()}. misc. closes afterwards: start it '
        'again to continue with the restored content.',
    action: 'Restore and close',
  );
  if (!ok) return;
  await s.flush();
  final wasReadOnly = s.workspace.store.readOnly;
  s.workspace.store.readOnly = true;
  try {
    await s.workspace.backups.restore(backup);
  } on FileSystemException catch (e, st) {
    AppLog.error('Restore failed', e, st);
    s.workspace.store.readOnly = wasReadOnly;
    s.showToast('Could not restore: ${e.message}');
    return;
  } catch (e, st) {
    AppLog.error('Restore failed', e, st);
    s.workspace.store.readOnly = wasReadOnly;
    s.showToast('Could not restore. Your data was left as it was.');
    return;
  }
  exit(0);
}
