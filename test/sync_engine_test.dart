// Two devices (each with its own data folder, like PC and iPad) syncing
// through a real hub on 127.0.0.1.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';

import 'dart:typed_data';

import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/features/links/archive_library.dart';
import 'package:flutter_application_1/features/templates/templates.dart';
import 'package:flutter_application_1/features/vault/vault_crypto.dart';
import 'package:flutter_application_1/features/vault/vault_service.dart';

class Device {
  Device(this.ws, this.canvases, this.engine);
  final Workspace ws;
  final FileCanvasRepository canvases;
  final SyncEngine engine;
  Future<SyncReport> sync() => engine.syncOnce();
}

Future<Uint8List> makePng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xFF35A99A), BlendMode.src);
  final image = await recorder.endRecording().toImage(3, 2);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
      .asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the local hub

  late Directory root;
  late HubServer hub;
  late int port;

  Future<HubServer> startHub() async {
    final s = await HubServer.start(
      dir: Directory('${root.path}${Platform.pathSeparator}hub'),
      port: port,
      dailyBackups: false,
    );
    port = s.port;
    return s;
  }

  Future<Device> device(String name) async {
    final dir = Directory('${root.path}${Platform.pathSeparator}$name');
    final ws = Workspace(dir);
    await ws.load();
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      ws.device!.id,
      name,
    );
    final client = SyncClient(
      Uri.parse('http://127.0.0.1:$port'),
      token: token,
    );
    final canvases = FileCanvasRepository(ws.store);
    return Device(
      ws,
      canvases,
      SyncEngine(workspace: ws, canvases: canvases, client: client),
    );
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_sync_');
    port = 0;
    hub = await startHub();
  });

  tearDown(() async {
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('pendingCounts reports unsent records by kind, then none', () async {
    final pc = await device('pc');
    expect(await pc.engine.pendingCounts(), isEmpty);
    pc.ws.createNote(title: 'Secret title', body: 'secret body');
    pc.ws.createTask('Revise');
    final before = await pc.engine.pendingCounts();
    expect(before['notes'], 1);
    expect(before['tasks'], 1);
    expect(before.keys.join(), isNot(contains('Secret')));
    await pc.sync();
    expect(await pc.engine.pendingCounts(), isEmpty);
  });

  test(
    'everything arrives on the other device, with valid links and files',
    () async {
      final pc = await device('pc');
      final ipad = await device('ipad');

      final folder = pc.ws.createFolder('School');
      final note = pc.ws.createNote(
        title: 'Plan',
        body: 'Read chapter 3',
        folderId: folder.id,
      );
      final png = await makePng();
      final photo = await pc.ws.imageAssetFromBytes(png, 'png');
      pc.ws.attachToNote(note.id, photo.id);
      final project = pc.ws.createTask('Exam', isExam: true);
      pc.ws.createTask(
        'Revise',
        parentId: project.id,
        dueDate: DateTime(2026, 11, 2),
      );
      pc.ws.saveEntry(
        CalendarEntry(
          id: 'ev1',
          category: CalendarCategory.events,
          name: 'Trip',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          startDate: DateTime(2026, 11, 1),
          endDate: DateTime(2026, 11, 3),
        ),
      );
      await pc.canvases.save(
        CanvasDocument(
          id: 'cv1',
          title: 'Ideas',
          updatedAt: DateTime.now(),
          items: [
            TextItem(
              id: 't1',
              position: const Offset(10, 20),
              width: 200,
              minHeight: 0,
              text: 'Hello',
              bold: true,
            ),
            ImageItem(
              id: 'i1',
              assetId: photo.id,
              position: const Offset(300, 0),
              width: 120,
              minHeight: 80,
            ),
          ],
          itemRevs: {'t1': pc.ws.clock.now(), 'i1': pc.ws.clock.now()},
          metaRev: pc.ws.clock.now(),
        ),
      );

      final up = await pc.sync();
      expect(up.uploaded, 1);
      expect(up.problems, isEmpty);
      final down = await ipad.sync();
      expect(down.downloaded, 1);
      expect(down.problems, isEmpty);

      final n = ipad.ws.notes[note.id]!;
      expect(n.body, 'Read chapter 3');
      expect(
        ipad.ws.folders[n.folderId],
        isNotNull,
        reason: 'folder link is valid',
      );
      final a = ipad.ws.assets[n.assetIds.single]!;
      expect(ipad.ws.attachments.fileFor(a.file!).readAsBytesSync(), png);
      final sub = ipad.ws.tasks.all.firstWhere((t) => t.title == 'Revise');
      expect(
        ipad.ws.tasks[sub.parentId],
        isNotNull,
        reason: 'subtask still points at its exam',
      );
      expect(ipad.ws.itemsOn(DateTime(2026, 11, 2)).length, 2); // event + task
      final canvas = (await ipad.canvases.load('cv1'))!;
      expect(canvas.title, 'Ideas');
      expect(canvas.items.map((i) => i.id), ['t1', 'i1']);
      expect((canvas.items.first as TextItem).bold, isTrue);
      expect(
        ipad.ws.assets[(canvas.items.last as ImageItem).assetId],
        isNotNull,
      );

      // Repeated cycles change nothing and never duplicate.
      for (var i = 0; i < 3; i++) {
        await pc.sync();
        await ipad.sync();
      }
      expect(ipad.ws.notes.length, 1);
      expect(ipad.ws.assets.length, 1);
      expect(ipad.ws.tasks.length, 2);
      expect(
        ipad.ws.attachments.dir.listSync().whereType<File>(),
        hasLength(1),
      );
      expect(pc.ws.notes.length, 1);
      final last = await pc.sync();
      expect(last.pushed, 0);
    },
  );

  test(
    'offline edits wait while the hub is down and sync after it returns',
    () async {
      final pc = await device('pc');
      final ipad = await device('ipad');
      final note = pc.ws.createNote(title: 'Groceries', body: 'Milk');
      await pc.sync();
      await ipad.sync();

      await hub.stop();
      pc.ws.notes.put(pc.ws.notes[note.id]!.copyWith(body: 'Milk, eggs'));
      await expectLater(
        pc.sync(),
        throwsA(
          isA<SyncFailure>().having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
      // The local edit is still there and the app's data is fine.
      expect(pc.ws.notes[note.id]!.body, 'Milk, eggs');

      hub = await startHub(); // same folder and port: as after a PC restart
      await pc.sync();
      await ipad.sync();
      expect(ipad.ws.notes[note.id]!.body, 'Milk, eggs');
    },
  );

  test('a PDF document arrives on the other device unchanged', () async {
    final pc = await device('pc');
    final ipad = await device('ipad');
    final source = File('${root.path}${Platform.pathSeparator}Syllabus.pdf')
      ..writeAsStringSync('%PDF-1.4\n% synthetic test document\n');
    final doc = await pc.ws.documentAssetFromFile(source);
    pc.ws.createNote(title: 'Course', assetIds: [doc.id]);
    await pc.sync();
    final r = await ipad.sync();
    expect(r.downloaded, greaterThanOrEqualTo(1));
    final there = ipad.ws.assets[doc.id]!;
    expect(there.kind, AssetKind.document);
    expect(there.label, 'Syllabus.pdf');
    final file = ipad.ws.documentFile(there)!;
    expect(file.readAsStringSync(), source.readAsStringSync());
  });

  test(
    'changes made offline survive an app restart and are sent afterwards',
    () async {
      final ipad = await device('ipad');
      final keep = ipad.ws.createNote(title: 'Keep', body: 'v1');
      final gone = ipad.ws.createNote(title: 'Delete me', body: '');
      await ipad.sync();
      final pc = await device('pc');
      await pc.sync();

      await hub.stop();
      ipad.ws.notes.put(ipad.ws.notes[keep.id]!.copyWith(body: 'v2 offline'));
      ipad.ws.notes.remove(gone.id);
      await expectLater(ipad.sync(), throwsA(isA<SyncFailure>()));
      // The app is closed while still offline.
      await ipad.ws.flush();
      final token = ipad.engine.client.token;
      ipad.ws.dispose();

      // Reopened from disk; the hub is back.
      hub = await startHub();
      final ws = Workspace(
        Directory('${root.path}${Platform.pathSeparator}ipad'),
      );
      await ws.load();
      final engine = SyncEngine(
        workspace: ws,
        canvases: FileCanvasRepository(ws.store),
        client: SyncClient(Uri.parse('http://127.0.0.1:$port'), token: token),
      );
      final report = await engine.syncOnce();
      expect(report.pushed, 2, reason: 'the edit and the deletion were queued');
      await pc.sync();
      expect(pc.ws.notes[keep.id]!.body, 'v2 offline');
      expect(pc.ws.notes[gone.id], isNull);
      expect((await engine.syncOnce()).pushed, 0, reason: 'sent exactly once');
      ws.dispose();
    },
  );

  test(
    'concurrent edits keep one version and preserve the other on both devices',
    () async {
      final pc = await device('pc');
      final ipad = await device('ipad');
      final note = pc.ws.createNote(title: 'Essay', body: 'Draft');
      await pc.sync();
      await ipad.sync();

      pc.ws.notes.put(pc.ws.notes[note.id]!.copyWith(body: 'PC paragraph'));
      ipad.ws.notes.put(
        ipad.ws.notes[note.id]!.copyWith(body: 'iPad paragraph'),
      );
      await pc.sync();
      final r = await ipad.sync();
      expect(r.conflicts, 1);
      await pc.sync();

      final pcBody = pc.ws.notes[note.id]!.body;
      expect(
        ipad.ws.notes[note.id]!.body,
        pcBody,
        reason: 'both devices agree',
      );
      final conflict = pc.ws.conflicts.all.single;
      expect(ipad.ws.conflicts.all.single.id, conflict.id);
      final versions = {pcBody, conflict.otherData!['body']};
      expect(versions, {
        'PC paragraph',
        'iPad paragraph',
      }, reason: 'neither edit was lost');
    },
  );

  test(
    'deleting on one device never wipes a newer edit made on another',
    () async {
      final pc = await device('pc');
      final ipad = await device('ipad');
      final note = pc.ws.createNote(title: 'Keep me', body: 'v1');
      await pc.sync();
      await ipad.sync();

      ipad.ws.notes.put(
        ipad.ws.notes[note.id]!.copyWith(body: 'edited on iPad'),
      );
      await ipad.sync();
      pc.ws.notes.remove(note.id); // based on the old version
      final r = await pc.sync();
      expect(r.conflicts, 1);
      expect(
        pc.ws.notes[note.id]!.body,
        'edited on iPad',
        reason: 'the edit came back',
      );
      expect(
        pc.ws.conflicts.all.single.reason,
        'deleted_here_edited_elsewhere',
      );

      // A deletion with nothing newer elsewhere does propagate.
      pc.ws.notes.remove(note.id);
      await pc.sync();
      await ipad.sync();
      expect(ipad.ws.notes[note.id], isNull);
      expect(ipad.ws.notes.tombstones[note.id], isNotNull);
    },
  );

  test('different items on the same canvas merge without conflicts', () async {
    final pc = await device('pc');
    final ipad = await device('ipad');
    await pc.canvases.save(
      CanvasDocument(
        id: 'c',
        title: 'Board',
        updatedAt: DateTime.now(),
        items: [
          TextItem(
            id: 'a',
            position: Offset.zero,
            width: 100,
            minHeight: 0,
            text: 'A',
          ),
        ],
        itemRevs: {'a': pc.ws.clock.now()},
        metaRev: pc.ws.clock.now(),
      ),
    );
    await pc.sync();
    await ipad.sync();

    Future<void> addItem(Device d, String id) async {
      final doc = (await d.canvases.load('c'))!;
      await d.canvases.save(
        CanvasDocument(
          id: 'c',
          title: doc.title,
          updatedAt: DateTime.now(),
          items: [
            ...doc.items,
            TextItem(
              id: id,
              position: Offset.zero,
              width: 100,
              minHeight: 0,
              text: id,
            ),
          ],
          itemRevs: {...doc.itemRevs, id: d.ws.clock.now()},
          tombstones: doc.tombstones,
          metaRev: doc.metaRev,
        ),
      );
    }

    await addItem(pc, 'from-pc');
    await addItem(ipad, 'from-ipad');
    await pc.sync();
    final r = await ipad.sync();
    await pc.sync();
    expect(r.conflicts, 0);
    for (final d in [pc, ipad]) {
      final ids = (await d.canvases.load('c'))!.items.map((i) => i.id).toSet();
      expect(ids, {'a', 'from-pc', 'from-ipad'});
    }
  });

  test('a sync interrupted before its results were saved is safely repeated', () async {
    final pc = await device('pc');
    pc.ws.createNote(title: 'One');
    pc.ws.createNote(title: 'Two');
    await pc.sync();
    final seq = hub.store.lastSeq;
    // Simulate the app being killed after the hub committed but before the
    // device saved its sync state: forget the state and sync again.
    await File(
      '${pc.ws.root.path}${Platform.pathSeparator}sync${Platform.pathSeparator}client_state.json',
    ).delete();
    final again = await pc.sync();
    expect(
      hub.store.lastSeq,
      seq,
      reason: 'the hub recognised every change as a repeat',
    );
    expect(again.conflicts, 0);
    expect(pc.ws.notes.length, 2);
  });

  test(
    'a hub restored from an older backup is detected and refilled',
    () async {
      final pc = await device('pc');
      pc.ws.createNote(title: 'Before backup');
      await pc.sync();
      final backup = await hub.backups.create();
      pc.ws.createNote(title: 'After backup');
      await pc.sync();

      // Replace the hub with the older backup (as a disaster recovery would).
      final hubDir = hub.store.dir;
      await hub.stop();
      final restored = Directory(
        '${root.path}${Platform.pathSeparator}hub-restored',
      );
      final copy = Directory(
        '${root.path}${Platform.pathSeparator}backup-copy',
      );
      await Process.run('xcopy', [
        backup.path,
        copy.path,
        '/E',
        '/I',
        '/Q',
      ]); // keep the backup outside the old hub
      await hubDir.rename('${root.path}${Platform.pathSeparator}hub-old');
      await restoreTo(copy, restored, hubDir.path);
      await restored.rename(hubDir.path);
      hub = await startHub();

      final r = await pc.sync();
      expect(r.problems, isEmpty);
      expect(
        hub.store.stats.records,
        2,
        reason: 'the newer note was offered again',
      );
    },
    skip: Platform.isWindows
        ? false
        : 'Copies the backup with the Windows xcopy program',
  );

  test('newer record kinds reach the other device; the vault stays '
      'encrypted on the hub and opens there with the password', () async {
    final pc = await device('pc');
    final ipad = await device('ipad');
    const fast = KdfParams(memoryKiB: 64, iterations: 1);
    final vault = VaultService(
      meta: pc.ws.vaultMeta,
      items: pc.ws.vaultItems,
      kdf: fast,
    );
    addTearDown(vault.dispose);
    await vault.create('long enough password');
    vault.save(title: 'Private', text: 'HUBMUSTNOTSEE');
    final folder = pc.ws.createArchiveFolder('Study');
    pc.ws.templates.put(noteTemplate('Daily', 'Log', 'Mood:'));
    expect((await pc.sync()).problems, isEmpty);
    expect((await ipad.sync()).problems, isEmpty);

    expect(ipad.ws.archiveFolders[folder.id]?.name, 'Study');
    expect(ipad.ws.templates.all.single.name, 'Daily');
    final journal = Directory('${root.path}${Platform.pathSeparator}hub')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .map((f) => f.readAsStringSync())
        .join();
    expect(journal, contains('vault_items'));
    expect(journal, isNot(contains('HUBMUSTNOTSEE')));
    final there = VaultService(
      meta: ipad.ws.vaultMeta,
      items: ipad.ws.vaultItems,
      kdf: fast,
    );
    addTearDown(there.dispose);
    await there.unlock('long enough password');
    expect(there.entries().single.text, 'HUBMUSTNOTSEE');
  });
}

/// Restores a backup folder (copied elsewhere) into [target], also copying
/// the device registry and hub id so existing device tokens still work.
Future<void> restoreTo(
  Directory backup,
  Directory target,
  String oldHub,
) async {
  await target.create(recursive: true);
  for (final name in ['journal.jsonl', 'devices.json']) {
    final f = File('${backup.path}${Platform.pathSeparator}$name');
    if (await f.exists()) {
      await f.copy('${target.path}${Platform.pathSeparator}$name');
    }
  }
  final oldId = File(
    '${root(oldHub)}${Platform.pathSeparator}hub-old${Platform.pathSeparator}hub-id',
  );
  if (await oldId.exists()) {
    await oldId.copy('${target.path}${Platform.pathSeparator}hub-id');
  }
}

String root(String hubPath) => Directory(hubPath).parent.path;
