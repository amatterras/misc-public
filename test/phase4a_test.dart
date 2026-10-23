// Phase 4A data safety: build id (D2a), data feature level with a verified
// backup and rollback protection (D5), restoring deleted notes with their
// handwriting and PDF pages (D1), keeping both devices' tags and PDF pages
// on a sync conflict (D3), and backups with attachments / copies outside
// the data folder (D4). Real local hub for the two-device tests; never the
// user's data.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/build_info.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/backup_service.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/record_merge.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

StrokeItem dot(String id, double x, double y) => StrokeItem(
  id: id,
  points: [StrokePoint(x, y)],
  color: const Color(0xFF000000),
  strokeWidth: 2,
);

const pdfPage0 = PageBackground(
  pageIndex: 0,
  assetId: 'pdf-a',
  pdfPage: 0,
  width: 612,
  height: 792,
);

/// Hashes of every file under [dir] (to prove nothing was written).
Map<String, String> fingerprint(Directory dir) => {
  for (final f in dir.listSync(recursive: true).whereType<File>())
    f.path.substring(dir.path.length): base64Encode(f.readAsBytesSync()),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_p4a_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory folder(String name) => Directory('${dir.path}$sep$name');

  Future<AppState> appState([String name = 'app']) async {
    final ws = Workspace(folder(name));
    await ws.load();
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await s.init();
    return s;
  }

  /// A note with handwriting and one PDF page, as NotePage saves it.
  Future<Note> noteWithInk(AppState s, {String title = 'Lecture'}) async {
    final ws = s.workspace;
    final folderRec = ws.createFolder('School');
    final pdf = await ws.attachments.importBytes(
      Uint8List.fromList(utf8.encode('%PDF-1.4 test')),
      'pdf',
    );
    final asset = Asset(
      id: 'pdf-a',
      kind: AssetKind.document,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      file: pdf,
      title: 'Slides.pdf',
    );
    ws.assets.put(asset);
    final note = ws.createNote(
      title: title,
      body: 'Body text',
      folderId: folderRec.id,
      assetIds: [asset.id],
    );
    ws.notes.put(ws.notes[note.id]!.copyWith(tags: ['exam'], favorite: true));
    await s.canvases.save(
      CanvasDocument(
        id: notebookIdFor(note.id),
        title: title,
        kind: 'notebook',
        items: [dot('d1', 100, 100), dot('d2', 300, 1200)],
        itemRevs: {'d1': ws.clock.now(), 'd2': ws.clock.now()},
        metaRev: ws.clock.now(),
        updatedAt: DateTime.now(),
        pageBackgrounds: const [pdfPage0],
      ),
    );
    return ws.notes[note.id]!;
  }

  group('D2a build id', () {
    test('defaults to "dev" when not set at build time', () {
      expect(appBuild, 'dev');
    });
  });

  group('D5 data feature level', () {
    test('new, empty data: level set, no backup needed', () async {
      final s = await appState();
      expect(
        s.settings.get<int>('dataFeatureLevel'),
        AppState.dataFeatureLevel,
      );
      final names = [for (final b in await s.workspace.backups.list()) b.path];
      expect(names.where((n) => n.contains('pre-level')), isEmpty);
      s.dispose();
    });

    test(
      'existing data from an earlier build: verified backup first',
      () async {
        // Data written by a build without the level (as Phases 1–3 did).
        final ws = Workspace(folder('app'));
        await ws.load();
        ws.createNote(title: 'Old note', body: 'kept');
        await ws.attachments.importBytes(Uint8List.fromList([1, 2, 3]), 'png');
        await ws.flush();

        final s = await appState();
        expect(s.dataProblem, isNull);
        final pre = (await s.workspace.backups.list())
            .where(
              (b) => b.path.endsWith('pre-level${AppState.dataFeatureLevel}'),
            )
            .toList();
        expect(pre, hasLength(1));
        expect(
          Directory('${pre.single.path}${sep}attachments').existsSync(),
          isTrue,
          reason: 'with photos and PDFs',
        );
        expect(
          s.settings.get<int>('dataFeatureLevel'),
          AppState.dataFeatureLevel,
        );
        await s.flush();
        s.dispose();

        // Second start: no second pre-upgrade backup.
        final again = await appState();
        final count = (await again.workspace.backups.list())
            .where((b) => b.path.contains('pre-level'))
            .length;
        expect(count, 1);
        again.dispose();
      },
    );

    test(
      'data marked by a newer build opens read-only, writes nothing',
      () async {
        final first = await appState();
        first.workspace.createNote(title: 'Mine', body: 'x');
        await first.settings.set(
          'dataFeatureLevel',
          AppState.dataFeatureLevel + 5,
        );
        await first.flush();
        first.dispose();
        final before = fingerprint(folder('app'));

        final s = await appState();
        expect(s.workspace.store.readOnly, isTrue);
        expect(s.dataProblem, contains('newer build'));
        s.workspace.createNote(title: 'Not saved', body: '');
        await s.workspace.flush();
        expect(fingerprint(folder('app')), before);
        s.dispose();
      },
    );
  });

  group('D1 restoring deleted notes', () {
    test(
      'everything comes back: text, folder, tags, PDF, ink, pages',
      () async {
        final s = await appState();
        final note = await noteWithInk(s);
        await s.deleteNote(note.id);
        expect(s.workspace.notes[note.id], isNull);
        expect(await s.canvases.load(notebookIdFor(note.id)), isNull);
        expect(s.workspace.canvasTombstones, contains(notebookIdFor(note.id)));

        final deleted = s.workspace.deletedNotes();
        expect(deleted.single.noteId, note.id);
        expect(deleted.single.deleted, isTrue);

        final restored = (await s.restoreDeletedNote(deleted.single.id))!;
        expect(restored.id, note.id);
        expect(restored.title, 'Lecture');
        expect(restored.body, 'Body text');
        expect(restored.folderId, note.folderId);
        expect(restored.tags, ['exam']);
        expect(restored.favorite, isTrue);
        expect(restored.assetIds, ['pdf-a']);

        final nb = (await s.canvases.load(notebookIdFor(note.id)))!;
        expect(nb.items.map((i) => i.id), ['d1', 'd2']);
        expect(nb.pageBackgrounds.single.assetId, 'pdf-a');
        expect(nb.isNotebook, isTrue);
        expect(
          s.workspace.canvasTombstones,
          isNot(contains(notebookIdFor(note.id))),
        );
        expect(s.workspace.deletedNotes(), isEmpty);
        // Restoring again changes nothing and duplicates nothing.
        expect(await s.restoreNotebookOf(note.id), isFalse);
        expect(
          s.workspace.notes.all.where((n) => n.id == note.id),
          hasLength(1),
        );
        s.dispose();
      },
    );

    test('a note never edited twice can still be restored', () async {
      final s = await appState();
      final note = s.workspace.createNote(title: 'Quick', body: 'once');
      await s.deleteNote(note.id);
      final v = s.workspace.deletedNotes().single;
      expect((await s.restoreDeletedNote(v.id))!.body, 'once');
      s.dispose();
    });

    test('older history versions (title and body only) still restore', () {
      final v = NoteVersion.fromJson({
        'id': 'v1',
        'noteId': 'n1',
        'title': 'Old',
        'body': 'old body',
        'savedAt': '2026-01-01T00:00:00Z',
      });
      expect(v.deleted, isFalse);
      expect(v.assetIds, isEmpty);
      expect(v.toJson().keys, isNot(contains('deleted')));
    });

    test('restored on one device, the other device gets it back too', () async {
      HttpOverrides.global = null;
      final hub = await HubServer.start(
        dir: folder('hub'),
        port: 0,
        dailyBackups: false,
      );
      addTearDown(hub.stop);
      Future<SyncEngine> engine(AppState s, String name) async => SyncEngine(
        workspace: s.workspace,
        canvases: s.canvases as FileCanvasRepository,
        client: SyncClient(
          Uri.parse('http://127.0.0.1:${hub.port}'),
          token: await hub.auth.register(
            hub.auth.createPairingCode(),
            s.workspace.device!.id,
            name,
          ),
        ),
      );
      final pc = await appState('pc');
      final ipad = await appState('ipad');
      final pcSync = await engine(pc, 'pc');
      final ipadSync = await engine(ipad, 'ipad');
      final note = await noteWithInk(pc);
      await pc.flush();
      await pcSync.syncOnce();
      await ipadSync.syncOnce();
      final nbId = notebookIdFor(note.id);
      expect((await ipad.canvases.load(nbId))!.items, hasLength(2));

      await pc.deleteNote(note.id);
      await pc.flush();
      await pcSync.syncOnce();
      await ipadSync.syncOnce();
      expect(await ipad.canvases.load(nbId), isNull);
      expect(ipad.workspace.notes[note.id], isNull);

      final v = pc.workspace.deletedNotes().single;
      await pc.restoreDeletedNote(v.id);
      await pc.flush();
      await pcSync.syncOnce();
      await ipadSync.syncOnce();
      await ipadSync.syncOnce();
      final back = (await ipad.canvases.load(nbId))!;
      expect(back.items.map((i) => i.id).toSet(), {'d1', 'd2'});
      expect(back.pageBackgrounds.single.assetId, 'pdf-a');
      expect(ipad.workspace.notes[note.id]?.title, 'Lecture');
      expect(ipad.workspace.canvasTombstones, isNot(contains(nbId)));
      // And it stays: a further round on both changes nothing.
      await pcSync.syncOnce();
      expect((await pc.canvases.load(nbId))!.items, hasLength(2));
      pc.dispose();
      ipad.dispose();
    });
  });

  group('D3 merges', () {
    test('link tags: three-way merge keeps both devices\' changes', () {
      expect(mergeLinkTags(local: ['shopping'], ours: ['resource'], base: []), [
        'shopping',
        'resource',
      ]);
      // We removed "resource"; the other device added "shopping".
      expect(
        mergeLinkTags(
          local: ['resource', 'shopping'],
          ours: [],
          base: ['resource'],
        ),
        ['shopping'],
      );
      // No base: only adds.
      expect(mergeLinkTags(local: ['projects'], ours: ['other', 'projects']), [
        'projects',
        'other',
      ]);
    });

    test(
      'PDF pages: nothing dropped, no duplicates, clashes move to the end',
      () {
        const other = PageBackground(
          pageIndex: 0,
          assetId: 'pdf-b',
          pdfPage: 0,
          width: 612,
          height: 792,
        );
        expect(mergePageBackgrounds([pdfPage0], [pdfPage0]), isNull);
        final merged = mergePageBackgrounds([other], [pdfPage0])!;
        expect(merged.map((b) => (b.pageIndex, b.assetId)), [
          (0, 'pdf-b'),
          (1, 'pdf-a'),
        ]);
      },
    );

    test('sync state keeps tag bases and merged conflicts', () {
      final s = SyncState(cursor: 3)
        ..rememberTags('a1', {
          'linkTags': ['resource'],
        })
        ..rememberTagBase('a1', 'rev-1', [])
        ..mergedConflicts.add('cf-1');
      final back = SyncState.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.tagBase['a1'], ['resource']);
      expect(back.tagBaseByRev['a1']?['rev-1'], isEmpty);
      expect(back.mergedConflicts, {'cf-1'});
      // Older state files load as before.
      expect(SyncState.fromJson({'cursor': 1}).tagBase, isEmpty);
    });

    group('two devices through a real hub', () {
      late HubServer hub;
      late AppState pc, ipad;
      late SyncEngine pcSync, ipadSync;
      setUp(() async {
        HttpOverrides.global = null;
        hub = await HubServer.start(
          dir: folder('hub'),
          port: 0,
          dailyBackups: false,
        );
        Future<SyncEngine> engine(AppState s, String name) async => SyncEngine(
          workspace: s.workspace,
          canvases: s.canvases as FileCanvasRepository,
          client: SyncClient(
            Uri.parse('http://127.0.0.1:${hub.port}'),
            token: await hub.auth.register(
              hub.auth.createPairingCode(),
              s.workspace.device!.id,
              name,
            ),
          ),
        );
        pc = await appState('pc');
        ipad = await appState('ipad');
        pcSync = await engine(pc, 'pc');
        ipadSync = await engine(ipad, 'ipad');
      });
      tearDown(() async {
        pc.dispose();
        ipad.dispose();
        await hub.stop();
      });

      Future<void> rounds() async {
        for (var i = 0; i < 3; i++) {
          await pcSync.syncOnce();
          await ipadSync.syncOnce();
        }
      }

      test(
        'tags added on both devices: both kept (newer pushed second)',
        () async {
          final link = pc.capture.link('https://shared.example');
          await rounds();
          pc.setLinkTags(link.id, ['resource']);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          ipad.setLinkTags(link.id, ['shopping']); // newer edit
          await pcSync.syncOnce();
          await ipadSync.syncOnce(); // the iPad's newer edit wins on the hub
          await rounds();
          for (final s in [pc, ipad]) {
            expect(s.workspace.assets[link.id]!.linkTags.toSet(), {
              'resource',
              'shopping',
            });
          }
        },
      );

      test(
        'tags added on both devices: both kept (older pushed second)',
        () async {
          final link = pc.capture.link('https://shared.example');
          await rounds();
          pc.setLinkTags(link.id, ['resource']); // older edit
          await Future<void>.delayed(const Duration(milliseconds: 5));
          ipad.setLinkTags(link.id, ['shopping']);
          await ipadSync.syncOnce();
          await pcSync.syncOnce(); // the hub keeps the iPad's version
          await rounds();
          for (final s in [pc, ipad]) {
            expect(s.workspace.assets[link.id]!.linkTags.toSet(), {
              'resource',
              'shopping',
            });
          }
        },
      );

      test('a tag removed here while another is added there', () async {
        final link = pc.capture.link('https://shared.example');
        pc.setLinkTags(link.id, ['resource']);
        await rounds();
        pc.setLinkTags(link.id, []); // older: removes "resource"
        await Future<void>.delayed(const Duration(milliseconds: 5));
        ipad.setLinkTags(link.id, ['resource', 'other']); // newer: adds
        await ipadSync.syncOnce();
        await pcSync.syncOnce(); // hub keeps the iPad's; PC merges 3-way
        await rounds();
        for (final s in [pc, ipad]) {
          expect(s.workspace.assets[link.id]!.linkTags, ['other']);
        }
      });

      test('a newer removal is respected while the other side\'s addition '
          'is kept', () async {
        final link = pc.capture.link('https://shared.example');
        pc.setLinkTags(link.id, ['resource']);
        await rounds();
        ipad.setLinkTags(link.id, ['resource', 'other']); // older: adds
        await Future<void>.delayed(const Duration(milliseconds: 5));
        pc.setLinkTags(link.id, []); // newer: removes "resource"
        await ipadSync.syncOnce();
        await pcSync.syncOnce(); // PC's newer edit wins on the hub
        await rounds();
        // "resource" was in the common base and the PC removed it; "other"
        // was independently added on the iPad and is preserved.
        for (final s in [pc, ipad]) {
          expect(s.workspace.assets[link.id]!.linkTags, ['other']);
        }
      });

      test(
        'different PDFs added to one note on both devices: both kept',
        () async {
          const nbId = 'nb-n1';
          await pc.canvases.save(
            CanvasDocument(
              id: nbId,
              title: 'Note',
              kind: 'notebook',
              items: [dot('d', 10, 10)],
              itemRevs: {'d': pc.workspace.clock.now()},
              metaRev: pc.workspace.clock.now(),
              updatedAt: DateTime.now(),
            ),
          );
          await rounds();
          Future<void> addPage(AppState s, String asset) async {
            final doc = (await s.canvases.load(nbId))!;
            await s.canvases.save(
              CanvasDocument(
                id: nbId,
                title: doc.title,
                kind: doc.kind,
                items: doc.items,
                itemRevs: doc.itemRevs,
                tombstones: doc.tombstones,
                metaRev: s.workspace.clock.now(),
                updatedAt: DateTime.now(),
                pageBackgrounds: [
                  PageBackground(
                    pageIndex: 0,
                    assetId: asset,
                    pdfPage: 0,
                    width: 612,
                    height: 792,
                  ),
                ],
              ),
            );
          }

          await addPage(pc, 'pdf-pc');
          await addPage(ipad, 'pdf-ipad');
          await pcSync.syncOnce();
          await ipadSync.syncOnce();
          await rounds();
          for (final s in [pc, ipad]) {
            final doc = (await s.canvases.load(nbId))!;
            expect(doc.pageBackgrounds.map((b) => b.assetId).toSet(), {
              'pdf-pc',
              'pdf-ipad',
            });
            expect(
              doc.pageBackgrounds.map((b) => b.pageIndex).toSet(),
              hasLength(2),
              reason: 'no two PDF pages on one notebook page',
            );
            expect(doc.items.single.id, 'd', reason: 'ink untouched');
          }
        },
      );
    });
  });

  group('D4 backups', () {
    late Directory root;
    late BackupService backups;
    setUp(() async {
      root = folder('data');
      await Directory('${root.path}${sep}data').create(recursive: true);
      File('${root.path}${sep}data${sep}notes.json').writeAsStringSync('{}');
      await Directory('${root.path}${sep}attachments').create();
      File('${root.path}${sep}attachments${sep}a.pdf').writeAsStringSync('pdf');
      backups = BackupService(root);
    });

    String name(Directory d) =>
        d.uri.pathSegments.where((p) => p.isNotEmpty).last;

    test(
      'weekly backup holds photos and PDFs; daily ones only records',
      () async {
        await backups.automaticBackup();
        var all = await backups.list();
        expect(all.map(name).single, endsWith('-auto-full'));
        expect(
          File('${all.single.path}${sep}attachments${sep}a.pdf').existsSync(),
          isTrue,
        );
        expect(await backups.verify(all.single), isTrue);
        // Same day: nothing more.
        await backups.automaticBackup();
        expect(await backups.list(), hasLength(1));
        // Next day: a records-only backup.
        await backups.automaticBackup(
          now: DateTime.now().add(const Duration(days: 1)),
        );
        all = await backups.list();
        expect(all.map(name).where((n) => n.endsWith('-auto')), hasLength(1));
        // A week later: a full one again.
        await backups.automaticBackup(
          now: DateTime.now().add(const Duration(days: 8)),
        );
        expect(
          (await backups.list())
              .map(name)
              .where((n) => n.endsWith('-auto-full')),
          hasLength(2),
        );
      },
    );

    test(
      'copies outside the data folder: complete, listed, never pruned',
      () async {
        final copies = folder('Files${sep}THEapp Backups');
        backups.copiesDir = copies;
        final b = await backups.snapshot('manual', includeAttachments: true);
        final copy = await backups.copyTo(b, copies);
        expect(fingerprint(copy), fingerprint(b));
        expect(Directory('${copy.path}.partial').existsSync(), isFalse);
        expect((await backups.list()).map((d) => d.path), contains(copy.path));
        expect(backups.isCopy(copy), isTrue);
        await expectLater(
          backups.copyTo(b, copies),
          throwsA(isA<FileSystemException>()),
        );
        for (var i = 0; i < BackupService.keepOther + 3; i++) {
          await backups.snapshot('manual');
        }
        expect(copy.existsSync(), isTrue, reason: 'copies are the user\'s');
        // Restoring from the copy works like any backup.
        File('${root.path}${sep}data${sep}notes.json')
            .writeAsStringSync('{"x":1}');
        await backups.restore(copy);
        expect(
          File('${root.path}${sep}data${sep}notes.json').readAsStringSync(),
          '{}',
        );
      },
    );

    test(
      'the newest pre-upgrade backup ("pre-level") is never pruned',
      () async {
        await backups.snapshot('pre-level1');
        for (var i = 0; i < BackupService.keepOther + 3; i++) {
          await backups.snapshot('manual');
        }
        expect(
          (await backups.list())
              .map(name)
              .where((n) => n.contains('pre-level1')),
          hasLength(1),
        );
      },
    );

    test('restoring a backup keeps the trash folders', () async {
      final trash = Directory('${root.path}${sep}canvases$sep.trash');
      await trash.create(recursive: true);
      File('${trash.path}${sep}nb-n1-123.json')
          .writeAsStringSync('{"id":"nb-n1"}');
      final b = await backups.snapshot('manual');
      await backups.restore(b);
      expect(File('${trash.path}${sep}nb-n1-123.json').existsSync(), isTrue);
    });

    test('"Save a copy to Files": a verified full backup copied out', () async {
      final s = await appState();
      await noteWithInk(s);
      s.workspace.backups.copiesDir = folder('Files${sep}THEapp Backups');
      final copy = (await s.saveBackupCopy())!;
      expect(copy.parent.path, s.workspace.backups.copiesDir!.path);
      expect(Directory('${copy.path}${sep}attachments').existsSync(), isTrue);
      expect(
        Directory('${copy.path}${sep}canvases')
            .listSync()
            .whereType<File>()
            .any((f) => f.path.contains('nb-')),
        isTrue,
        reason: 'the handwriting is in it',
      );
      s.dispose();
    });

    test('on Windows there is no Files folder, so no copy is made', () async {
      expect(AppState.backupCopiesFolder(), isNull);
      final s = await appState();
      expect(await s.saveBackupCopy(), isNull);
      s.dispose();
    });
  });
}
