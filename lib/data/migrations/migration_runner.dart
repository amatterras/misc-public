// Versioned, checkpointed data migrations (see DATA_MIGRATIONS.md).
//
// The data is many JSON files, each written atomically, but there is no
// transaction across files. So every migration run is staged:
//
//  1. A checkpoint is written (`migrations/state.json`) naming the steps
//     to run and the backup that holds the original data.
//  2. A full backup (records, drawings, photos, PDFs) is made, and is
//     trusted only when its manifest checksums match AND a copy of it opens
//     as a workspace with the same record counts (`verifyRestorable`).
//  3. The steps run. Each is idempotent: running it again on data it
//     already changed changes nothing, so an interrupted run is simply run
//     again (the checkpoint still names the original backup).
//  4. A census compares every record id, canvas item id and attachment
//     file before and after: a migration may add, never lose.
//  5. Only then is the step marked done and the checkpoint cleared.
//
// A failure never deletes or re-creates anything: the data folder becomes
// read-only, the failure is recorded, and the app offers Retry or Restore
// (the verified backup).
import 'dart:io';

import '../models/calendar_models.dart';
import '../models/canvas_models.dart';
import '../repositories/canvas_repository.dart';
import '../storage/app_log.dart';
import '../storage/backup_verifier.dart';
import '../workspace.dart';

/// What a migration step may use.
class MigrationContext {
  MigrationContext(this.workspace, this.canvases);
  final Workspace workspace;
  final CanvasRepository canvases;
}

class MigrationStep {
  const MigrationStep({
    required this.id,
    required this.description,
    required this.apply,
    this.verify,
  });

  /// Stable id, never reused (recorded as done in `migrations/state.json`).
  final String id;
  final String description;

  /// Changes the data; returns how many records it changed. Must be
  /// idempotent and must not remove records.
  final Future<int> Function(MigrationContext context) apply;

  /// Extra checks after [apply]; returns problems (empty = fine).
  final Future<List<String>> Function(MigrationContext context)? verify;
}

enum MigrationStatus { upToDate, applied, failed }

class MigrationOutcome {
  const MigrationOutcome(
    this.status, {
    this.message,
    this.backup,
    this.applied = const [],
  });

  final MigrationStatus status;
  final String? message;

  /// The verified backup holding the data from before the migration.
  final Directory? backup;
  final List<String> applied;

  bool get failed => status == MigrationStatus.failed;
}

/// Thrown inside a run; its message is shown to the user.
class MigrationProblem implements Exception {
  const MigrationProblem(this.message);
  final String message;
  @override
  String toString() => message;
}

class MigrationRunner {
  MigrationRunner({
    required this.workspace,
    required this.canvases,
    List<MigrationStep>? steps,
  }) : steps = steps ?? registry;

  final Workspace workspace;
  final CanvasRepository canvases;
  final List<MigrationStep> steps;

  static const folder = 'migrations';
  static const stateName = 'state';

  /// Every migration, in order. Append only; never reorder or reuse ids.
  static final List<MigrationStep> registry = [
    readingLegacyPayloadV1,
    canvasRevisionsV1,
  ];

  Future<Map<String, dynamic>> loadState() async =>
      await workspace.store.read(folder, stateName) ??
      {'schema': 1, 'done': <String, dynamic>{}};

  Future<void> _saveState(Map<String, dynamic> state) =>
      workspace.store.write(folder, stateName, state);

  /// Steps not yet recorded as done.
  Future<List<MigrationStep>> pending() async {
    final done = ((await loadState())['done'] as Map?) ?? const {};
    return [
      for (final s in steps)
        if (!done.containsKey(s.id)) s,
    ];
  }

  /// Runs every pending step (see the file comment). [hasData] false (a new,
  /// empty data folder) marks the steps done without a backup.
  Future<MigrationOutcome> run({required bool hasData}) async {
    final state = await loadState();
    final done = Map<String, dynamic>.of(
      (state['done'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    final todo = [
      for (final s in steps)
        if (!done.containsKey(s.id)) s,
    ];
    if (todo.isEmpty) return const MigrationOutcome(MigrationStatus.upToDate);

    if (!hasData) {
      final at = DateTime.now().toUtc().toIso8601String();
      for (final s in todo) {
        done[s.id] = {'at': at, 'changed': 0, 'emptyWorkspace': true};
      }
      await _saveState({'schema': 1, 'done': done});
      return MigrationOutcome(
        MigrationStatus.applied,
        applied: [for (final s in todo) s.id],
      );
    }

    final previous = (state['checkpoint'] as Map?)?.cast<String, dynamic>();
    Directory? backup;
    try {
      // An interrupted earlier run: its backup is still the original data.
      if (previous != null) {
        AppLog.warn(
          'Migration: an earlier run did not finish; running it again',
        );
        final path = previous['backup'] as String?;
        final dir = path == null ? null : Directory(path);
        if (dir != null &&
            await dir.exists() &&
            (await workspace.backups.checkManifest(dir)).isEmpty) {
          backup = dir;
        }
      }
      if (backup == null) {
        await workspace.flush();
        backup = await workspace.backups.snapshot(
          'pre-migration-${todo.first.id}',
          includeAttachments: true,
        );
        final check = await verifyRestorable(workspace.backups, backup);
        if (!check.ok) {
          throw MigrationProblem(
            'The backup made before upgrading your data could not be '
            'verified (${check.problems.first}).',
          );
        }
        AppLog.info('Migration: verified backup ${backup.path}');
      }
      await _saveState(
        {
          ...state,
          'schema': 1,
          'done': done,
          'checkpoint': {
            'steps': [for (final s in todo) s.id],
            'backup': backup.path,
            'startedAt':
                previous?['startedAt'] ??
                DateTime.now().toUtc().toIso8601String(),
            'attempt': ((previous?['attempt'] as int?) ?? 0) + 1,
          },
        }..remove('failed'),
      );

      final context = MigrationContext(workspace, canvases);
      final applied = <String>[];
      for (final step in todo) {
        final before = await WorkspaceCensus.take(workspace, canvases);
        final changed = await step.apply(context);
        await workspace.flush();
        final after = await WorkspaceCensus.take(workspace, canvases);
        final lost = before.missingFrom(after);
        if (lost.isNotEmpty) {
          throw MigrationProblem(
            'Upgrade step "${step.id}" would have lost ${lost.length} '
            'item(s); stopped before going further.',
          );
        }
        final problems = await step.verify?.call(context) ?? const [];
        if (problems.isNotEmpty) {
          throw MigrationProblem(
            'Upgrade step "${step.id}" did not verify: ${problems.first}',
          );
        }
        done[step.id] = {
          'at': DateTime.now().toUtc().toIso8601String(),
          'changed': changed,
          'backup': backup.path,
        };
        // Each finished step is recorded at once, so a crash in the next
        // one does not repeat this one's census.
        await _saveState({...await loadState(), 'done': done});
        applied.add(step.id);
        AppLog.info('Migration ${step.id}: $changed record(s) updated');
      }
      final finished = await loadState()
        ..remove('checkpoint')
        ..['done'] = done;
      await _saveState(finished);
      return MigrationOutcome(
        MigrationStatus.applied,
        backup: backup,
        applied: applied,
      );
    } catch (e, s) {
      final message = e is MigrationProblem
          ? e.message
          : 'An upgrade step failed (${e.runtimeType}).';
      // Only the error's type and where it happened: an exception's text
      // can quote record content (a note body, a URL with a key in it).
      AppLog.error(
        'Migration failed: ${e is MigrationProblem ? message : e.runtimeType}',
        null,
        s,
      );
      try {
        await _saveState({
          ...await loadState(),
          'failed': {
            'at': DateTime.now().toUtc().toIso8601String(),
            'error': message,
            'backup': backup?.path,
          },
        });
      } catch (_) {
        // Recording the failure is best effort; the data is still protected.
      }
      return MigrationOutcome(
        MigrationStatus.failed,
        message: message,
        backup: backup,
      );
    }
  }
}

/// Every id that must survive a migration: records per collection, canvas
/// items per canvas, and attachment files.
class WorkspaceCensus {
  WorkspaceCensus._(this.ids);

  /// Keys like `notes/<id>`, `canvas/<canvasId>/<itemId>`, `file/<name>`.
  final Set<String> ids;

  static Future<WorkspaceCensus> take(
    Workspace ws,
    CanvasRepository canvases,
  ) async {
    final ids = <String>{};
    for (final MapEntry(key: name, value: c) in ws.allCollections.entries) {
      for (final r in c.all) {
        ids.add('$name/${r.id}');
      }
    }
    for (final summary in await canvases.listCanvases()) {
      ids.add('canvas/${summary.id}');
      final doc = await canvases.load(summary.id);
      for (final item in doc?.items ?? const []) {
        ids.add('canvas/${summary.id}/${item.id}');
      }
    }
    final dir = ws.attachments.dir;
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        if (f is File) ids.add('file/${f.uri.pathSegments.last}');
      }
    }
    return WorkspaceCensus._(ids);
  }

  /// Ids present here but not in [after].
  Set<String> missingFrom(WorkspaceCensus after) => ids.difference(after.ids);
}

// ------------------------------------------------------------- the steps --

/// Reading entries: copy author, highlights and quotes into the versioned
/// `legacyReading` payload, so they stay recoverable once the Reading
/// editor stops showing them. The original fields are left as they are.
final readingLegacyPayloadV1 = MigrationStep(
  id: 'reading-legacy-payload-v1',
  description:
      'Keep Reading author/highlights/quotes in a versioned legacy payload',
  apply: (ctx) async {
    final entries = ctx.workspace.entries;
    var changed = 0;
    for (final e in entries.all.toList()) {
      if (e.category != CalendarCategory.reading) continue;
      final payload = legacyReadingPayload(
        e,
        entries.jsonOf(e.id) ?? e.toJson(),
      );
      // Kept already (an earlier, interrupted run): never overwritten.
      if (payload == null || e.legacyReading != null) continue;
      entries.put(e.copyWith(legacyReading: () => payload));
      changed++;
    }
    return changed;
  },
  verify: (ctx) async {
    final problems = <String>[];
    final entries = ctx.workspace.entries;
    for (final e in entries.all) {
      if (e.category != CalendarCategory.reading) continue;
      final payload = legacyReadingPayload(
        e,
        entries.jsonOf(e.id) ?? e.toJson(),
      );
      if (payload != null && e.legacyReading == null) {
        problems.add('Reading entry ${e.id} has no legacy payload');
      }
    }
    return problems;
  },
);

/// Canvases saved without revision stamps (a new canvas or the welcome
/// canvas that was never edited afterwards) were invisible to sync and to
/// backups' sync re-offer. Give every unstamped item, and the title, the
/// stamp of the canvas's last edit time, as the schema-3 upgrade does.
/// Items, positions and content are unchanged.
final canvasRevisionsV1 = MigrationStep(
  id: 'canvas-revisions-v1',
  description: 'Give unstamped canvas items revision stamps so they sync',
  apply: (ctx) async {
    var changed = 0;
    for (final summary in await ctx.canvases.listCanvases()) {
      final doc = await ctx.canvases.load(summary.id);
      if (doc == null) continue;
      final missing =
          doc.metaRev == null ||
          doc.items.any((i) => !doc.itemRevs.containsKey(i.id));
      if (!missing) continue;
      final stamp = ctx.workspace.clock.stampAt(doc.updatedAt);
      await ctx.canvases.save(
        CanvasDocument(
          id: doc.id,
          title: doc.title,
          items: doc.items,
          updatedAt: doc.updatedAt,
          viewport: doc.viewport,
          folderId: doc.folderId,
          schema: doc.schema,
          itemRevs: {
            for (final i in doc.items) i.id: doc.itemRevs[i.id] ?? stamp,
          },
          tombstones: doc.tombstones,
          metaRev: doc.metaRev ?? stamp,
          unknownItems: doc.unknownItems,
          itemUnknownFields: doc.itemUnknownFields,
          unknownKeys: doc.unknownKeys,
          metaUnknownFields: doc.metaUnknownFields,
          kind: doc.kind,
          pageBackgrounds: doc.pageBackgrounds,
          layers: doc.layers,
        ),
      );
      changed++;
    }
    return changed;
  },
  verify: (ctx) async => [
    for (final summary in await ctx.canvases.listCanvases())
      if (await ctx.canvases.load(summary.id) case final doc?)
        if (doc.metaRev == null ||
            doc.items.any((i) => !doc.itemRevs.containsKey(i.id)))
          'Canvas ${doc.id} still has unstamped items',
  ],
);

/// The legacy Reading values of [entry] ([raw] is its stored JSON, which
/// may hold a `quotes` field written by another version), or null when it
/// has none.
Map<String, dynamic>? legacyReadingPayload(
  CalendarEntry entry,
  Map<String, dynamic> raw,
) {
  final quotes = raw['quotes'];
  final hasQuotes =
      quotes != null &&
      !(quotes is String && quotes.trim().isEmpty) &&
      !(quotes is List && quotes.isEmpty);
  if (entry.author.trim().isEmpty &&
      entry.highlights.trim().isEmpty &&
      !hasQuotes) {
    return null;
  }
  return {
    'version': 1,
    'author': entry.author,
    'highlights': entry.highlights,
    if (hasQuotes) 'quotes': quotes,
  };
}
