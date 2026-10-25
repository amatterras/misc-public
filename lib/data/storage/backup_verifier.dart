// "A backup file's mere existence does not count as a backup": this opens a
// copy of a backup the way the app would and compares it with its manifest.
import 'dart:io';

import '../repositories/canvas_repository.dart';
import '../workspace.dart';
import 'backup_service.dart';

class RestoreCheck {
  const RestoreCheck(this.problems, {this.records = 0, this.canvases = 0});

  /// Empty when the backup is intact and opens.
  final List<String> problems;
  final int records;
  final int canvases;

  bool get ok => problems.isEmpty;
}

/// Checks [backup]: its manifest checksums, then restores it into a
/// temporary folder (never the live one), opens it as a workspace and
/// compares record counts with the manifest, loads every canvas, and checks
/// that every photo/PDF an asset names is in the backup when the backup
/// holds attachments. The temporary copy is removed afterwards.
Future<RestoreCheck> verifyRestorable(
  BackupService backups,
  Directory backup,
) async {
  final problems = await backups.checkManifest(backup);
  if (problems.isNotEmpty) return RestoreCheck(problems);
  final manifest = (await backups.readManifest(backup))!;
  final temp = await Directory.systemTemp.createTemp('theapp-restore-check-');
  Workspace? ws;
  try {
    await backups.restoreTo(backup, temp);
    ws = Workspace(temp);
    await ws.load();
    var records = 0;
    final counts =
        (manifest['recordCounts'] as Map?)?.cast<String, int>() ?? const {};
    final collections = ws.allCollections;
    for (final MapEntry(key: name, value: expected) in counts.entries) {
      final c = collections[name];
      // A collection this version does not know is still in the backup
      // (its file is checksummed); it is just not opened here.
      if (c == null) continue;
      final opened = c.length + c.unreadableCount;
      records += c.length;
      if (opened != expected) {
        problems.add('$name: $opened of $expected record(s) open');
      }
    }
    final canvasRepo = FileCanvasRepository(ws.store);
    final summaries = await canvasRepo.listCanvases();
    for (final s in summaries) {
      if (await canvasRepo.load(s.id) == null) {
        problems.add('Canvas ${s.id} does not open');
      }
    }
    if (manifest['includesAttachments'] == true) {
      for (final a in ws.assets.all) {
        for (final name in [a.file, a.previewFile]) {
          if (name == null) continue;
          // Missing here but present in the live folder = lost in the copy.
          // (A file the live folder lacks too, e.g. not downloaded yet, is
          // the integrity check's business, not the backup's.)
          final live = File(
            '${backups.root.path}${Platform.pathSeparator}attachments'
            '${Platform.pathSeparator}$name',
          );
          if (!await ws.attachments.fileFor(name).exists() &&
              await live.exists()) {
            problems.add('Attachment of asset ${a.id} is not in the backup');
          }
        }
      }
    }
    if (ws.store.recoveries.isNotEmpty) {
      problems.add('Damaged file in backup: ${ws.store.recoveries.first}');
    }
    return RestoreCheck(problems, records: records, canvases: summaries.length);
  } catch (e) {
    return RestoreCheck([
      ...problems,
      'Could not open the backup (${e.runtimeType})',
    ]);
  } finally {
    ws?.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // A temporary copy left behind is harmless (system temp folder).
    }
  }
}
