// Data-safety baseline (DATA_MIGRATIONS.md): versioned migrations on a
// realistic pre-update workspace, verified backups and restore, integrity
// checks on deliberately damaged data, recoverable deletion with sync
// tombstones, and logs without personal content. Everything runs on
// temporary folders; never on real data.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/integrity/integrity_check.dart';
import 'package:flutter_application_1/data/migrations/migration_runner.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/app_log.dart';
import 'package:flutter_application_1/data/storage/backup_service.dart';
import 'package:flutter_application_1/data/storage/backup_verifier.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pre_update_fixture.dart';

final sep = Platform.pathSeparator;

/// SHA-256 of every file under [dir] (relative path → hash), skipping the
/// folders a check may legitimately add to (backups, logs).
Future<Map<String, String>> treeHashes(Directory dir) async {
  final out = <String, String>{};
  await for (final e in dir.list(recursive: true)) {
    if (e is! File) continue;
    final rel = e.path.substring(dir.path.length + 1);
    if (rel.startsWith('backups') || rel.startsWith('logs')) continue;
    out[rel] = sha256.convert(await e.readAsBytes()).toString();
  }
  return out;
}

Future<Map<String, String>> attachmentHashes(Workspace ws) async => {
  for (final f in ws.attachments.dir.listSync().whereType<File>())
    f.uri.pathSegments.last: sha256.convert(f.readAsBytesSync()).toString(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to local hubs only

  late Directory root;
  late PreUpdateFixture f;
  final opened = <Workspace>[];

  Future<(Workspace, FileCanvasRepository)> open([Directory? dir]) async {
    final ws = Workspace(dir ?? f.dir);
    await ws.load();
    opened.add(ws);
    return (ws, FileCanvasRepository(ws.store));
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_safety_');
    f = await buildPreUpdateWorkspace(Directory('${root.path}${sep}app'));
  });

  tearDown(() async {
    for (final ws in opened) {
      ws.dispose();
    }
    opened.clear();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('migrations', () {
    test('a pre-update workspace migrates without losing anything', () async {
      final (ws, canvases) = await open();
      final before = await WorkspaceCensus.take(ws, canvases);
      final filesBefore = await attachmentHashes(ws);
      final tombstonesBefore = {
        for (final e in ws.allCollections.entries) e.key: e.value.tombstones,
      };

      final outcome = await MigrationRunner(
        workspace: ws,
        canvases: canvases,
      ).run(hasData: true);
      expect(outcome.status, MigrationStatus.applied);
      expect(outcome.applied, [
        'reading-legacy-payload-v1',
        'canvas-revisions-v1',
        'object-library-foundation-v1',
        'inbox-to-archive-v1',
      ]);
      expect((await verifyRestorable(ws.backups, outcome.backup!)).ok, isTrue);

      // Reopen from disk: what a restart sees.
      ws.dispose();
      opened.remove(ws);
      final (re, reCanvases) = await open();
      final after = await WorkspaceCensus.take(re, reCanvases);
      expect(before.missingFrom(after), isEmpty, reason: 'nothing lost');
      // Only the Archive objects made from the waiting Inbox item are new
      // (the Inbox record itself stays, as the check above shows).
      final added = after.ids.difference(before.ids);
      expect(
        added.where((id) => !id.startsWith('library_')),
        isEmpty,
        reason: 'nothing duplicated or added besides Archive objects',
      );
      expect(
        added.where((id) => id.startsWith('library_objects/')),
        hasLength(1),
      );
      expect(await attachmentHashes(re), filesBefore);
      for (final e in re.allCollections.entries) {
        expect(e.value.tombstones, tombstonesBefore[e.key], reason: e.key);
      }

      // Reading: legacy fields kept in the versioned payload, originals too.
      final reading = re.entries[f.readingId]!;
      expect(reading.legacyReading, {
        'version': 1,
        'author': 'E. Hecht',
        'highlights': 'Chapter 4 on refraction',
      });
      expect(reading.author, 'E. Hecht');
      expect(reading.readingLog.length, 2);
      expect(reading.assetIds, [f.pdfAssetId]);
      final essays = re.entries[f.readingQuotesId]!;
      expect(essays.legacyReading!['quotes'], [
        'Que sais-je?',
        'Every man bears the whole form',
      ]);
      expect(re.entries.jsonOf(f.readingQuotesId)!['quotes'], isNotNull);

      // Habits: no invented times; history unchanged.
      final untimed = re.entries[f.untimedHabitId]!;
      expect(untimed.startMinutes, isNull);
      expect(untimed.needsTimeConfiguration, isTrue);
      expect(untimed.checkoffs, f.untimedCheckoffs);
      final timed = re.entries[f.timedHabitId]!;
      expect(timed.startMinutes, 450);
      expect(timed.needsTimeConfiguration, isFalse);

      // Links, relationships, colours.
      expect(re.assets[f.linkAssetId]!.url, archiveUrl);
      expect(re.assets[f.linkAssetId]!.linkTags, contains('tag:${f.tagId}'));
      expect(re.customTags[f.tagId]!.color, f.tagColor);
      expect(re.notes[f.noteId]!.folderId, f.subfolderId);
      expect(re.notes[f.noteId]!.assetIds, [f.photoAssetId, f.pdfAssetId]);
      expect(re.folders[f.subfolderId]!.parentId, f.folderId);
      expect(re.tasks[f.taskId]!.noteIds, [f.noteId]);
      expect(re.tasks[f.subtaskId]!.parentId, f.taskId);
      expect(re.calendarLinks[f.calendarLinkId]!.entryId, f.eventId);
      expect(re.inbox['inbox-1'], isNotNull);
      expect(re.inbox.tombstones.containsKey('inbox-0'), isTrue);
      final doc = (await reCanvases.load(f.canvasId))!;
      final stroke = doc.items.whereType<StrokeItem>().single;
      expect(stroke.color, f.strokeColor);
      expect(stroke.points.length, 3);
      expect(
        doc.items.whereType<TextItem>().single.textColor,
        const Color(0xFFE56BDA),
      );
      final link = doc.items.whereType<ConnectorItem>().single;
      expect((link.fromId, link.toId), ('t1', 'n1'));
      expect(doc.items.whereType<NoteCardItem>().single.noteId, f.noteId);
      // Every item now has a revision stamp, so the canvas syncs.
      expect(doc.metaRev, isNotNull);
      expect(doc.itemRevs.keys.toSet(), {for (final i in doc.items) i.id});
    });

    test(
      'running the migration twice is safe and duplicates nothing',
      () async {
        final (ws, canvases) = await open();
        final runner = MigrationRunner(workspace: ws, canvases: canvases);
        await runner.run(hasData: true);
        final once = await treeHashes(f.dir);
        final counts = {
          for (final e in ws.allCollections.entries) e.key: e.value.length,
        };
        final again = await runner.run(hasData: true);
        expect(again.status, MigrationStatus.upToDate);
        // The step itself is idempotent too (forced to run again).
        expect(
          await readingLegacyPayloadV1.apply(MigrationContext(ws, canvases)),
          0,
        );
        await ws.flush();
        expect(await treeHashes(f.dir), once);
        expect({
          for (final e in ws.allCollections.entries) e.key: e.value.length,
        }, counts);
      },
    );

    test('an interrupted migration keeps the original backup and finishes on retry', () async {
      final (ws, canvases) = await open();
      final originalDescription = ws.entries[f.eventId]!.description;
      var crash = true;
      final step = MigrationStep(
        id: 'test-partial',
        description: 'changes one record, then the power goes',
        apply: (ctx) async {
          final e = ctx.workspace.entries[f.eventId]!;
          if (!e.description.contains('[migrated]')) {
            ctx.workspace.entries.put(
              e.copyWith(description: '${e.description}[migrated]'),
            );
          }
          await ctx.workspace.flush();
          if (crash) throw StateError('power cut');
          return 1;
        },
      );
      final first = await MigrationRunner(
        workspace: ws,
        canvases: canvases,
        steps: [step],
      ).run(hasData: true);
      expect(first.failed, isTrue);
      final state = await ws.store.read('migrations', 'state');
      expect(state!['checkpoint'], isNotNull);
      expect(state['failed'], isNotNull);
      final originalBackup = first.backup!;
      // The backup holds the data from before the step.
      final (copy, _) = await open(Directory('${root.path}${sep}inspect'));
      await ws.backups.restoreTo(originalBackup, copy.root);
      await copy.load();
      expect(copy.entries[f.eventId]!.description, originalDescription);

      crash = false;
      final second = await MigrationRunner(
        workspace: ws,
        canvases: canvases,
        steps: [step],
      ).run(hasData: true);
      expect(second.status, MigrationStatus.applied);
      expect(second.backup!.path, originalBackup.path);
      final done = await ws.store.read('migrations', 'state');
      expect(done!['checkpoint'], isNull);
      expect((done['done'] as Map)['test-partial'], isNotNull);
      expect(
        ws.entries[f.eventId]!.description,
        '$originalDescription[migrated]',
        reason: 'applied exactly once',
      );
    });

    test(
      'a step that would lose a record is stopped; the backup restores it',
      () async {
        final (ws, canvases) = await open();
        final outcome = await MigrationRunner(
          workspace: ws,
          canvases: canvases,
          steps: [
            MigrationStep(
              id: 'test-lossy',
              description: 'a buggy step',
              apply: (ctx) async {
                ctx.workspace.notes.remove(f.noteId);
                return 1;
              },
            ),
          ],
        ).run(hasData: true);
        expect(outcome.failed, isTrue);
        expect(outcome.message, contains('lost'));
        await ws.backups.restore(outcome.backup!);
        ws.dispose();
        opened.remove(ws);
        final (re, _) = await open();
        expect(re.notes[f.noteId]!.body, contains(secretBodyMarker));
      },
    );

    test(
      'a failed upgrade at start-up writes nothing and offers restore',
      () async {
        final (ws, canvases) = await open();
        final census = await WorkspaceCensus.take(ws, canvases);
        final state = AppState(
          canvases: canvases,
          settings: SettingsRepository(ws.store),
          workspace: ws,
          enableSendTo: false,
        );
        state.migrationSteps = [
          MigrationStep(
            id: 'test-fails',
            description: 'always fails',
            apply: (_) async => throw const FormatException('unexpected shape'),
          ),
        ];
        await state.init();
        expect(state.dataProblem, contains('could not finish upgrading'));
        expect(state.dataProblem, contains('Nothing was deleted'));
        expect(ws.store.readOnly, isTrue);
        final backup = state.migrationFailure!.backup!;
        expect((await verifyRestorable(ws.backups, backup)).ok, isTrue);

        // Even with pending saves, the read-only store writes nothing.
        final frozen = await treeHashes(f.dir);
        ws.notes.put(ws.notes[f.noteId]!.copyWith(title: 'changed'));
        await ws.flush();
        expect(await treeHashes(f.dir), frozen);

        expect(await state.restoreBeforeMigration(), startsWith('Restored'));
        final (re, reCanvases) = await open();
        final after = await WorkspaceCensus.take(re, reCanvases);
        expect(census.missingFrom(after), isEmpty);
        expect(re.notes[f.noteId]!.title, 'Lab notes');
      },
    );
  });

  group('backups', () {
    test(
      'verified backup: manifest, no keys, tamper detected, restore works',
      () async {
        final (ws, canvases) = await open();
        // A device key (DPAPI/Keychain-protected in the app; plain here).
        final token = File('${f.dir.path}${sep}sync${sep}hub.token')
          ..writeAsStringSync('device-secret-xyz');
        final backup = await ws.backups.snapshot(
          'manual',
          includeAttachments: true,
        );
        final manifest = (await ws.backups.readManifest(backup))!;
        expect(manifest['secretsIncluded'], isFalse);
        final paths = [
          for (final e in manifest['files'] as List)
            (e as Map)['path'] as String,
        ];
        expect(paths.any((p) => p.endsWith('.token')), isFalse);
        expect(paths, contains('data/notes.json'));
        expect(paths.where((p) => p.startsWith('attachments/')).length, 2);
        expect((manifest['recordCounts'] as Map)['notes'], greaterThan(0));
        expect(await ws.backups.checkManifest(backup), isEmpty);
        final check = await verifyRestorable(ws.backups, backup);
        expect(check.ok, isTrue, reason: check.problems.join('; '));
        expect(check.canvases, 1);

        // A damaged copy is detected and never restored.
        final damagedDir = Directory('${root.path}${sep}damaged');
        await ws.backups.restoreTo(backup, damagedDir);
        File('${backup.path}${sep}manifest.json')
            .copySync('${damagedDir.path}${sep}manifest.json');
        final notesCopy = File('${damagedDir.path}${sep}data${sep}notes.json');
        notesCopy.writeAsStringSync(
          notesCopy.readAsStringSync().replaceFirst('Lab notes', 'Lab notez'),
        );
        expect(
          (await ws.backups.checkManifest(damagedDir)).single,
          contains('Checksum mismatch: data/notes.json'),
        );
        final liveBefore = await treeHashes(f.dir);
        await expectLater(
          ws.backups.restore(damagedDir),
          throwsA(isA<FileSystemException>()),
        );
        expect(await treeHashes(f.dir), liveBefore);

        // Changes after the backup, then restore: the backup's state returns,
        // this device keeps its own key.
        ws.notes.remove(f.noteId);
        ws.createNote(title: 'After backup');
        await ws.flush();
        await ws.backups.restore(backup);
        expect(token.readAsStringSync(), 'device-secret-xyz');
        ws.dispose();
        opened.remove(ws);
        final (re, _) = await open();
        expect(re.notes[f.noteId], isNotNull);
        expect(re.notes.all.any((n) => n.title == 'After backup'), isFalse);
        expect(
          jsonDecode(
            File('${f.dir.path}${sep}settings${sep}app.json')
                .readAsStringSync(),
          ),
          containsPair('dotOpacity.mindmap', 0.35),
        );
      },
    );

    test(
      'a backup restores into a separate working workspace intact',
      () async {
        final (ws, _) = await open();
        final ids = {
          for (final e in ws.allCollections.entries)
            e.key: {for (final r in e.value.all) r.id},
        };
        final files = await attachmentHashes(ws);
        final backup = await ws.backups.snapshot(
          'export',
          includeAttachments: true,
        );
        final target = Directory('${root.path}${sep}restored');
        await ws.backups.restoreTo(backup, target);
        final (copy, copyCanvases) = await open(target);
        expect({
          for (final e in copy.allCollections.entries)
            e.key: {for (final r in e.value.all) r.id},
        }, ids);
        expect(await attachmentHashes(copy), files);
        final doc = (await copyCanvases.load(f.canvasId))!;
        expect(doc.items.whereType<StrokeItem>().single.color, f.strokeColor);
        expect(copy.customTags[f.tagId]!.color, f.tagColor);
        expect(copy.assets[f.linkAssetId]!.url, archiveUrl);
        // The copy is a working workspace: it can be edited and reopened.
        copy.createNote(title: 'Works');
        await copy.flush();
        final (again, _) = await open(target);
        expect(again.notes.all.any((n) => n.title == 'Works'), isTrue);
      },
    );
  });

  group('integrity', () {
    test('damaged data is reported, never "fixed" by erasing', () async {
      {
        final (ws, canvases) = await open();
        final clean = await IntegrityChecker(ws, canvases).run();
        expect(
          clean.issues.where((i) => i.severity == IntegritySeverity.problem),
          isEmpty,
          reason: clean.issues.join('\n'),
        );
        ws.dispose();
        opened.remove(ws);
      }
      // Damage the files the way bugs, crashes or bad merges could.
      Map<String, dynamic> read(String rel) =>
          jsonDecode(f.file(rel).readAsStringSync()) as Map<String, dynamic>;
      void write(String rel, Object json) => f.file(rel)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(json));
      final notes = read('data/notes.json');
      final records = notes['records'] as List;
      final first = records.first as Map;
      records.add(Map.of(first)); // duplicate id
      for (final r in records) {
        if (r['id'] == f.linkedNoteId) r['folderId'] = 'missing-folder';
      }
      write('data/notes.json', notes);
      final links = read('data/calendar_links.json');
      (links['records'] as List).first['entryId'] = 'missing-entry';
      write('data/calendar_links.json', links);
      final entries = read('data/calendar_entries.json');
      final today = dateOnly(DateTime.now());
      var sunday = today.subtract(const Duration(days: 1));
      while (sunday.weekday != DateTime.sunday) {
        sunday = sunday.subtract(const Duration(days: 1));
      }
      for (final r in entries['records'] as List) {
        if (r['id'] == f.timedHabitId) {
          (r['checkoffs'] as List).add(dayKey(sunday));
        }
      }
      write('data/calendar_entries.json', entries);
      final canvas = read('canvases/${f.canvasId}.json');
      for (final i in canvas['items'] as List) {
        if (i['id'] == 'c1') i['to'] = 'ghost';
      }
      write('canvases/${f.canvasId}.json', canvas);
      write('migrations/state.json', {
        'schema': 1,
        'done': {},
        'checkpoint': {
          'steps': ['x'],
          'backup': 'somewhere',
        },
        'failed': {'error': 'test failure'},
      });
      final (ws, canvases) = await open();
      final photo = ws.assets[f.photoAssetId]!.file!;
      ws.attachments.fileFor(photo).deleteSync();
      // Saving does not drop the duplicate either (it is kept aside).
      ws.notes.put(ws.notes[f.noteId]!.copyWith(title: 'Lab notes 2'));
      await ws.flush();
      final saved = read('data/notes.json')['records'] as List;
      expect(saved.where((r) => r['id'] == first['id']).length, 2);

      final before = await treeHashes(f.dir);
      final report = await IntegrityChecker(ws, canvases).run();
      final codes = report.issues.map((i) => i.code).toSet();
      expect(
        codes,
        containsAll([
          'duplicate_id',
          'missing_attachment',
          'missing_reference',
          'dangling_calendar_link',
          'habit_completion_outside_schedule',
          'dangling_connection',
          'migration_unfinished',
          'migration_failed',
        ]),
      );
      expect(
        report.ofCode('duplicate_id').single.where,
        'notes/${first['id']}',
      );
      expect(
        report.ofCode('missing_attachment').single.where,
        'assets/${f.photoAssetId}',
      );
      for (final i in report.issues) {
        expect(i.recovery, isNotEmpty);
        expect(i.toString(), isNot(contains(secretBodyMarker)));
      }
      // Reading only: nothing changed, nothing removed.
      await ws.flush();
      expect(await treeHashes(f.dir), before);
      expect(ws.notes[f.linkedNoteId], isNotNull);
      expect(ws.calendarLinks[f.calendarLinkId], isNotNull);
    });
  });

  group('deletion, restore and sync tombstones', () {
    test('restore brings back only that record, on every device', () async {
      final hub = await HubServer.start(
        dir: Directory('${root.path}${sep}hub'),
        port: 0,
        dailyBackups: false,
      );
      addTearDown(hub.stop);
      Future<(Workspace, SyncEngine)> device(Directory dir, String name) async {
        final (ws, canvases) = await open(dir);
        final token = await hub.auth.register(
          hub.auth.createPairingCode(),
          ws.device!.id,
          name,
        );
        final client = SyncClient(
          Uri.parse('http://127.0.0.1:${hub.port}'),
          token: token,
        );
        addTearDown(client.close);
        return (
          ws,
          SyncEngine(workspace: ws, canvases: canvases, client: client),
        );
      }

      final (pc, pcSync) = await device(f.dir, 'pc');
      final (ipad, ipadSync) = await device(
        Directory('${root.path}${sep}ipad'),
        'ipad',
      );
      await pcSync.syncOnce();
      await ipadSync.syncOnce();
      expect(ipad.notes[f.noteId], isNotNull);
      expect(ipad.customTags[f.tagId]!.color, f.tagColor);

      // Delete two notes on the PC. No cascade: attachments, folders and
      // the mindmap card's note reference are untouched.
      pc.notes.remove(f.noteId);
      pc.notes.remove(f.linkedNoteId);
      expect(pc.assets[f.photoAssetId], isNotNull);
      expect(
        pc.attachments.fileFor(pc.assets[f.photoAssetId]!.file!).existsSync(),
        isTrue,
      );
      expect(pc.folders[f.subfolderId], isNotNull);
      await pcSync.syncOnce();
      await ipadSync.syncOnce();
      expect(ipad.notes[f.noteId], isNull);
      expect(ipad.notes[f.linkedNoteId], isNull);
      // Deleted elsewhere, still recoverable here.
      expect(
        ipad.notes.recentlyDeleted.keys,
        containsAll([f.noteId, f.linkedNoteId]),
      );

      // Restore one on the PC: a new edit, newer than the deletion.
      final tombstone = pc.notes.tombstones[f.noteId]!;
      final restored = pc.notes.restoreDeleted(f.noteId)!;
      expect(restored.body, contains(secretBodyMarker));
      expect(pc.notes.revOf(f.noteId)!.compareTo(tombstone), greaterThan(0));
      expect(pc.notes.restoreDeleted(f.noteId), isNull, reason: 'once');
      await pcSync.syncOnce();
      final ipadReport = await ipadSync.syncOnce();
      expect(ipad.notes[f.noteId]!.assetIds, [f.photoAssetId, f.pdfAssetId]);
      expect(ipad.notes[f.linkedNoteId], isNull, reason: 'not resurrected');
      expect(ipad.notes.recentlyDeleted.containsKey(f.noteId), isFalse);
      expect(ipadReport.conflicts, 0);
      expect(ipad.tasks[f.taskId]!.noteIds, [f.noteId]);
      // A further sync changes nothing on either side.
      final p = await pcSync.syncOnce();
      final i = await ipadSync.syncOnce();
      expect((p.pushed, i.pushed, p.pulled, i.pulled), (0, 0, 0, 0));
    });

    test('an expired calendar entry stays unrecoverable', () async {
      final (ws, _) = await open();
      final old = DateTime.now().toUtc().subtract(const Duration(days: 9));
      ws.entries.put(
        ws.entries[f.eventId]!.copyWith(archived: true, archivedAt: () => old),
      );
      await ws.purgeExpiredArchivedEntries();
      expect(ws.entries[f.eventId], isNull);
      expect(ws.entries.recentlyDeleted.containsKey(f.eventId), isFalse);
      expect(ws.entries.restoreDeleted(f.eventId), isNull);
      // A normal deletion is recoverable.
      ws.entries.remove(f.readingId);
      expect(ws.entries.restoreDeleted(f.readingId), isNotNull);
    });
  });

  test('logs never contain note text, URL queries or keys', () async {
    AppLog.init(f.dir);
    final (ws, canvases) = await open();
    File('${f.dir.path}${sep}sync${sep}hub.token')
        .writeAsStringSync('tok-123456');
    final outcome = await MigrationRunner(
      workspace: ws,
      canvases: canvases,
      steps: [
        readingLegacyPayloadV1,
        MigrationStep(
          id: 'test-noisy-failure',
          description: 'fails with content in the exception',
          apply: (_) async =>
              throw StateError('bad record $secretBodyMarker $archiveUrl'),
        ),
      ],
    ).run(hasData: true);
    expect(outcome.failed, isTrue);
    expect(outcome.message, isNot(contains(secretBodyMarker)));
    await IntegrityChecker(ws, canvases).run();
    await ws.backups.snapshot('manual', includeAttachments: true);
    final log = File('${f.dir.path}${sep}logs${sep}app.log').readAsStringSync();
    expect(log, isNot(contains(secretBodyMarker)));
    expect(log, isNot(contains(secretQueryMarker)));
    expect(log, isNot(contains('tok-123456')));
    expect(BackupService.isSecret('sync/hub.token'), isTrue);
  });
}
