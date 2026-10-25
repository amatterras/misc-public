// Read-only integrity check of a workspace. It reports problems and how to
// recover from each; it never deletes, rewrites or "repairs" anything, so a
// check can never make data disappear to make itself pass.
import 'dart:io';

import '../../sync/sync_engine.dart' show isAttachmentFileName;
import '../models/calendar_models.dart';
import '../models/canvas_models.dart';
import '../models/library_models.dart';
import '../models/record.dart';
import '../migrations/migration_runner.dart';
import '../repositories/canvas_repository.dart';
import '../workspace.dart';

enum IntegritySeverity { problem, warning }

class IntegrityIssue {
  const IntegrityIssue({
    required this.code,
    required this.severity,
    required this.where,
    required this.detail,
    required this.recovery,
  });

  /// Stable kind, e.g. `duplicate_id`, `missing_attachment`.
  final String code;
  final IntegritySeverity severity;

  /// `collection/id` (or `canvas/<id>/<item>`); ids only, never content.
  final String where;
  final String detail;

  /// What the user can do about it (nothing is done automatically).
  final String recovery;

  @override
  String toString() => '[$code] $where: $detail';
}

class IntegrityReport {
  IntegrityReport(this.issues, {required this.checked});
  final List<IntegrityIssue> issues;

  /// Records, canvas items and files looked at.
  final int checked;

  bool get clean => issues.isEmpty;
  Iterable<IntegrityIssue> ofCode(String code) =>
      issues.where((i) => i.code == code);
}

class IntegrityChecker {
  IntegrityChecker(this.ws, this.canvases);

  final Workspace ws;
  final CanvasRepository canvases;

  static const _restoreHint =
      'Restore an earlier backup (Settings → Backups) to bring it back, or '
      'leave it: nothing else is affected.';

  Future<IntegrityReport> run() async {
    final issues = <IntegrityIssue>[];
    var checked = 0;
    void add(
      String code,
      String where,
      String detail,
      String recovery, {
      IntegritySeverity severity = IntegritySeverity.problem,
    }) => issues.add(
      IntegrityIssue(
        code: code,
        severity: severity,
        where: where,
        detail: detail,
        recovery: recovery,
      ),
    );

    // 1. Duplicate ids inside the stored files (the loader keeps only one,
    //    so the others would be invisible).
    for (final name in ws.allCollections.keys) {
      final raw = await ws.store.read('data', name);
      final ids = <String, int>{};
      for (final r in (raw?['records'] as List? ?? const [])) {
        if (r is Map && r['id'] is String) {
          ids.update(r['id'] as String, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      for (final e in ids.entries.where((e) => e.value > 1)) {
        add(
          'duplicate_id',
          '$name/${e.key}',
          '${e.value} records share this id; only one is shown.',
          'Every copy is still in the file. Restore a backup taken before '
              'the duplicate appeared, or export and compare the copies.',
        );
      }
      final c = ws.allCollections[name]!;
      checked += c.length;
      if (c.unreadableCount > 0) {
        add(
          'unreadable_records',
          name,
          '${c.unreadableCount} record(s) this version cannot read are kept '
              'aside unchanged.',
          'Update THEapp on this device; the records are preserved.',
          severity: IntegritySeverity.warning,
        );
      }
    }

    // 2. Attachments: records whose bytes are missing, and files no record
    //    names (reported, never removed).
    final referencedFiles = <String>{};
    for (final a in ws.assets.all) {
      for (final name in [a.file, a.previewFile]) {
        if (name == null) continue;
        referencedFiles.add(name);
        if (!isAttachmentFileName(name) ||
            !await ws.attachments.fileFor(name).exists()) {
          add(
            'missing_attachment',
            'assets/${a.id}',
            'The file for this ${a.kind.name} is not on this device.',
            'If another device has it, the next sync downloads it. '
                'Otherwise restore a full backup (one with photos and PDFs).',
          );
        }
      }
      if (a.kind == AssetKind.link &&
          (a.url == null || a.url!.trim().isEmpty)) {
        add(
          'missing_source_url',
          'assets/${a.id}',
          'This saved link has no address.',
          _restoreHint,
        );
      }
    }
    if (await ws.attachments.dir.exists()) {
      await for (final f in ws.attachments.dir.list()) {
        if (f is! File) continue;
        checked++;
        final name = f.uri.pathSegments.last;
        if (name.endsWith('.download')) continue; // an unfinished download
        if (!referencedFiles.contains(name)) {
          add(
            'unreferenced_attachment',
            'attachments/$name',
            'No record uses this file. It is kept (files are never removed '
                'automatically).',
            'Nothing to do; it can be re-attached or ignored.',
            severity: IntegritySeverity.warning,
          );
        }
      }
    }

    // 3. References between records.
    void ref(
      String code,
      String where,
      String? id,
      Map<String, Object?> pool,
      String what,
    ) {
      if (id == null || pool.containsKey(id)) return;
      add(
        code,
        where,
        'Refers to a $what ($id) that does not exist here.',
        'The $what may still arrive by sync; otherwise $_restoreHint',
      );
    }

    final assets = {for (final a in ws.assets.all) a.id: a};
    final notes = {for (final n in ws.notes.all) n.id: n};
    final folders = {for (final f in ws.folders.all) f.id: f};
    final archiveFolders = {for (final f in ws.archiveFolders.all) f.id: f};
    final tasks = {for (final t in ws.tasks.all) t.id: t};
    final projects = {for (final p in ws.projects.all) p.id: p};
    final entries = {for (final e in ws.entries.all) e.id: e};

    for (final n in ws.notes.all) {
      ref('missing_reference', 'notes/${n.id}', n.folderId, folders, 'folder');
      for (final id in n.assetIds) {
        ref('missing_reference', 'notes/${n.id}', id, assets, 'attachment');
      }
    }
    for (final f in ws.folders.all) {
      ref(
        'missing_reference',
        'folders/${f.id}',
        f.parentId,
        folders,
        'parent folder',
      );
    }
    for (final a in ws.assets.all) {
      ref(
        'missing_reference',
        'assets/${a.id}',
        a.folderId,
        archiveFolders,
        'Archive folder',
      );
    }
    for (final t in ws.tasks.all) {
      ref(
        'missing_reference',
        'tasks/${t.id}',
        t.parentId,
        tasks,
        'parent task',
      );
      ref(
        'missing_reference',
        'tasks/${t.id}',
        t.projectId,
        projects,
        'project',
      );
      for (final id in t.assetIds) {
        ref('missing_reference', 'tasks/${t.id}', id, assets, 'attachment');
      }
      for (final id in t.noteIds) {
        ref('missing_reference', 'tasks/${t.id}', id, notes, 'note');
      }
    }
    for (final i in ws.inbox.all) {
      ref(
        'missing_reference',
        'inbox/${i.id}',
        i.assetId,
        assets,
        'attachment',
      );
    }
    for (final d in ws.days.all) {
      for (final id in d.assetIds) {
        ref(
          'missing_reference',
          'calendar_days/${d.id}',
          id,
          assets,
          'attachment',
        );
      }
    }

    // 4. Calendar: entries' attachments, links to Google/Outlook, habits.
    for (final e in ws.entries.all) {
      for (final id in e.assetIds) {
        ref(
          'missing_reference',
          'calendar_entries/${e.id}',
          id,
          assets,
          'attachment',
        );
      }
      if (e.category == CalendarCategory.habits) {
        for (final key in e.checkoffs) {
          DateTime? day;
          try {
            day = parseDayKey(key);
          } catch (_) {
            day = null;
          }
          if (day == null) {
            add(
              'bad_habit_completion',
              'calendar_entries/${e.id}',
              'A completion has an unreadable date.',
              'It is kept as it is; the habit still works.',
            );
          } else if (!e.occursOn(day)) {
            add(
              'habit_completion_outside_schedule',
              'calendar_entries/${e.id}',
              'A completion on $key falls outside the habit\'s schedule '
                  '(the schedule was probably changed later).',
              'It is kept in the history; change the schedule back to show '
                  'it, or leave it.',
              severity: IntegritySeverity.warning,
            );
          }
        }
      }
    }
    for (final l in ws.calendarLinks.all) {
      final entryId = l.entryId;
      if (entryId == null || entries.containsKey(entryId)) continue;
      if (ws.calendarExpirations[entryId] != null) continue; // expired: fine
      add(
        'dangling_calendar_link',
        'calendar_links/${l.id}',
        'Links a ${l.provider} event to an entry that is not here.',
        'The entry may still arrive by sync; otherwise $_restoreHint',
      );
    }

    // 5. Canvases: duplicate item ids, and items naming missing records.
    for (final summary in await canvases.listCanvases()) {
      final raw = await ws.store.read('canvases', summary.id);
      final seen = <String, int>{};
      for (final i in (raw?['items'] as List? ?? const [])) {
        if (i is Map && i['id'] is String) {
          seen.update(i['id'] as String, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      for (final e in seen.entries.where((e) => e.value > 1)) {
        add(
          'duplicate_id',
          'canvas/${summary.id}/${e.key}',
          '${e.value} canvas items share this id.',
          'Every copy is still in the file. $_restoreHint',
        );
      }
      final doc = await canvases.load(summary.id);
      if (doc == null) continue;
      final itemIds = {for (final i in doc.items) i.id};
      for (final item in doc.items) {
        checked++;
        final where = 'canvas/${doc.id}/${item.id}';
        switch (item) {
          case ImageItem(:final assetId) || LinkItem(:final assetId):
            ref('missing_reference', where, assetId, assets, 'attachment');
          case NoteCardItem(:final noteId):
            ref('missing_reference', where, noteId, notes, 'note');
          case ConnectorItem(:final fromId, :final toId):
            for (final end in [fromId, toId]) {
              if (!itemIds.contains(end)) {
                add(
                  'dangling_connection',
                  where,
                  'A connection ends at an item ($end) that is not on this '
                      'canvas; it is hidden.',
                  _restoreHint,
                  severity: IntegritySeverity.warning,
                );
              }
            }
          default:
            break;
        }
      }
      for (final page in doc.pageBackgrounds) {
        ref(
          'missing_reference',
          'canvas/${doc.id}',
          page.assetId,
          assets,
          'page background',
        );
      }
    }

    // 6. Migrations that did not finish or failed.
    final state = await ws.store.read(
      MigrationRunner.folder,
      MigrationRunner.stateName,
    );
    if (state?['checkpoint'] != null) {
      add(
        'migration_unfinished',
        'migrations',
        'A data upgrade started but did not finish.',
        'Restart THEapp to finish it; the backup made before it is kept '
            '(${(state!['checkpoint'] as Map)['backup']}).',
      );
    }
    if (state?['failed'] != null) {
      add(
        'migration_failed',
        'migrations',
        'The last data upgrade failed: ${(state!['failed'] as Map)['error']}',
        'Retry from the upgrade screen, or restore the backup it names.',
      );
    }
    return IntegrityReport(issues, checked: checked);
  }
}
