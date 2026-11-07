// Acceptance tests for requirement 7.15 "Zero-Friction Reliability and
// Seamless User Experience", section H: one test per scenario, plus checks of
// the pieces added for it (10-second safety net, reconnect pause, attachment
// budget, storage-full notices, crash leftovers).
//
// Sync scenarios use the scenario lab (test/support/sync_rig.dart): a real
// hub on 127.0.0.1, production AppState devices, and a controllable network
// per device. Everything runs in temporary folders, never on real data.
//
// Run alone (RAM is limited):  flutter test -j 1 test/reliability_7_15_test.dart
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/repositories/record_collection.dart';
import 'package:flutter_application_1/data/storage/backup_service.dart';
import 'package:flutter_application_1/data/storage/json_file_store.dart';
import 'package:flutter_application_1/data/storage/storage_issue.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/data/sync/sync_clock.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pre_update_fixture.dart';
import 'support/sync_keys.dart';
import 'support/sync_rig.dart';

/// The status line must not claim a working connection.
void expectNotClaimingSync(AppState s, String when) {
  expect(
    s.syncStatus,
    isNot(anyOf(startsWith('Synced'), contains('· live'))),
    reason: '$when: "${s.syncStatus}"',
  );
}

/// A disk-full error as the operating system reports it.
FileSystemException diskFull(String path) => FileSystemException(
  'Cannot write file',
  path,
  OSError(
    Platform.isWindows
        ? 'There is not enough space on the disk.'
        : 'No space left on device',
    Platform.isWindows ? 112 : 28,
  ),
);

/// A store whose writes fail with "disk full" while [full] is set.
class FullDiskStore extends JsonFileStore {
  FullDiskStore(super.root);
  bool full = false;
  int attempts = 0;

  @override
  Future<void> write(String collection, String id, Map<String, dynamic> json) {
    attempts++;
    if (full) return Future.error(diskFull('${root.path}/$collection/$id'));
    return super.write(collection, id, json);
  }
}

/// A canvas repository whose saves fail with "disk full" while [full] is set.
class FullDiskCanvases extends FileCanvasRepository {
  FullDiskCanvases(super.store);
  bool full = false;

  @override
  Future<void> save(CanvasDocument document) async {
    if (full) throw diskFull('${store.root.path}/canvases/${document.id}');
    return super.save(document);
  }
}

TextItem text(String id, String body) => TextItem(
  id: id,
  position: const Offset(0, 0),
  width: 200,
  minHeight: 40,
  text: body,
);

/// Bytes that look like a PDF (the import check reads the signature).
Uint8List fakePdf(int size, {int seed = 1}) {
  final r = Random(seed);
  final b = Uint8List(size);
  for (var i = 0; i < size; i++) {
    b[i] = r.nextInt(256);
  }
  b.setAll(0, '%PDF-1.4\n'.codeUnits);
  return b;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to local test servers only

  // ------------------------------------------------- the pieces themselves
  group('7.15 building blocks', () {
    test('B: the safety-net interval is at most 10 seconds, and so is the '
        'longest pause between reconnection attempts', () {
      expect(
        AppState.syncInterval,
        lessThanOrEqualTo(const Duration(seconds: 10)),
      );
      final s = SyncScheduler(
        run: () async {},
        cursor: () async => 0,
        client: SyncClient(Uri.parse('http://127.0.0.1:1'), token: 't'),
      );
      expect(s.fallback, lessThanOrEqualTo(const Duration(seconds: 10)));
      expect(s.maxRetry, lessThanOrEqualTo(const Duration(seconds: 10)));
    });

    test('B: with no trigger at all, a cycle still runs within the safety '
        'interval of the previous one, again and again', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // A hub whose live wait never reports a change: only the safety-net
      // timer triggers cycles.
      server.listen((r) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        r.response.headers.contentType = ContentType.json;
        r.response.write('{"lastSeq":0,"hubId":"fake"}');
        await r.response.close();
      });
      final at = <DateTime>[];
      final s = SyncScheduler(
        run: () async => at.add(DateTime.now()),
        cursor: () async => 0,
        client: SyncClient(
          Uri.parse('http://127.0.0.1:${server.port}'),
          token: 't',
        ),
        fallback: const Duration(milliseconds: 300),
      );
      s.start();
      try {
        await until(() => at.length >= 5, what: '5 cycles from the timer');
      } finally {
        await s.close();
        await server.close(force: true);
      }
      for (var i = 1; i < at.length; i++) {
        // Never more than the interval (+ scheduling slack) between cycles.
        expect(
          at[i].difference(at[i - 1]),
          lessThan(const Duration(milliseconds: 900)),
        );
      }
    });

    test('F: storage errors are told apart (full, location lost, refused, '
        'temporary) and explained in plain words', () {
      expect(classifyStorageError(diskFull('x')), StorageIssue.full);
      expect(
        classifyStorageError(
          FileSystemException(
            'Cannot open',
            'x',
            OSError('gone', Platform.isWindows ? 3 : 2),
          ),
        ),
        StorageIssue.locationLost,
      );
      expect(
        classifyStorageError(
          FileSystemException(
            'Cannot open',
            'x',
            OSError('denied', Platform.isWindows ? 5 : 13),
          ),
        ),
        StorageIssue.denied,
      );
      expect(
        classifyStorageError(const FileSystemException('locked')),
        StorageIssue.temporary,
      );
      expect(
        worstIssue([StorageIssue.temporary, StorageIssue.full]),
        StorageIssue.full,
      );
      final full = unsavedNoticeText(StorageIssue.full);
      expect(full, contains('Storage is full'));
      expect(full, contains('not saved'));
      expect(full, contains('safe'));
      for (final i in [...StorageIssue.values, null]) {
        final t = unsavedNoticeText(i).toLowerCase();
        expect(t, isNot(contains('saved.')), reason: 'never claims success');
        expect(t, isNot(contains('error code')));
        expect(t, isNot(contains('exception')));
      }
    });
  });

  // ------------------------------------------------- H: sync scenarios
  group('H. acceptance scenarios (sync)', () {
    late SyncRig rig;
    setUp(() async => rig = await SyncRig.start());
    tearDown(() => rig.close());

    test('H1 normal editing: rapid edits are saved without any save step, '
        'never block, and arrive on the other device', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      final note = ipad.s.workspace.createNote(title: 'Typing', body: '');
      final watch = Stopwatch()..start();
      for (var i = 1; i <= 30; i++) {
        // Each keystroke is a synchronous in-memory change: no wait on disk.
        ipad.s.workspace.notes.put(
          ipad.s.workspace.notes[note.id]!.copyWith(body: 'x' * i),
        );
      }
      expect(
        watch.elapsedMilliseconds,
        lessThan(200),
        reason: '30 edits never wait for saving',
      );
      // On disk by itself (batched), with no flush or save prompt.
      await until(() async {
        final raw = await ipad.s.workspace.store.read('data', 'notes');
        final records = (raw?['records'] as List?) ?? const [];
        return records.any(
          (r) => r is Map && r['id'] == note.id && r['body'] == 'x' * 30,
        );
      }, what: 'the last edit on disk');
      await until(
        () => pc.s.workspace.notes[note.id]?.body == 'x' * 30,
        what: 'the last edit on the PC',
      );
      expect(ipad.s.workspace.unsaved.value, isEmpty);
      expect(pc.s.openConflictCount, 0);
    });

    test('H2 changing pages: a mindmap edit is saved when another page '
        'opens, and syncs', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      await pc.s.createCanvas(title: 'First');
      final first = pc.s.canvas!;
      first.addItems([text('t1', 'written just before switching')]);
      // Switching away at once: no prompt, nothing waits for the user.
      await pc.s.createCanvas(title: 'Second');
      pc.s.goTo(AppPage.notes);
      final saved = await pc.s.canvases.load(first.id);
      expect(
        saved!.items.whereType<TextItem>().map((t) => t.text),
        contains('written just before switching'),
      );
      await until(() async {
        final doc = await ipad.s.canvases.load(first.id);
        return doc?.items.any((i) => i.id == 't1') ?? false;
      }, what: 'the mindmap edit on the iPad');
    });

    test('H3 switching devices: continue on the iPad what was started on '
        'the PC and back, without conflicts', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      final n = pc.s.workspace.createNote(title: 'Essay', body: 'one');
      await until(
        () => ipad.s.workspace.notes[n.id]?.body == 'one',
        what: 'PC version on the iPad',
      );
      ipad.s.workspace.notes.put(
        ipad.s.workspace.notes[n.id]!.copyWith(body: 'one two'),
      );
      await until(
        () => pc.s.workspace.notes[n.id]?.body == 'one two',
        what: 'iPad version on the PC',
      );
      pc.s.workspace.notes.put(
        pc.s.workspace.notes[n.id]!.copyWith(body: 'one two three'),
      );
      await until(
        () => ipad.s.workspace.notes[n.id]?.body == 'one two three',
        what: 'PC version on the iPad again',
      );
      expect(pc.s.openConflictCount, 0);
      expect(ipad.s.openConflictCount, 0);
    });

    test('H4 losing internet: edits stay on the device, are reported as '
        'waiting, and are never claimed as synced', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      await ipad.proxy.down();
      await until(
        () => ipad.s.syncConnection == SyncConnection.offline,
        what: 'offline noticed',
      );
      final n = ipad.s.workspace.createNote(title: 'Offline', body: 'kept');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(ipad.s.syncPendingLocal, isTrue);
      expectNotClaimingSync(ipad.s, 'offline');
      expect(ipad.s.workspace.notes[n.id]!.body, 'kept');
      expect(ipad.s.workspace.unsaved.value, isEmpty, reason: 'on disk');
      expect(pc.s.workspace.notes[n.id], isNull);
    });

    test('H5 reconnecting: after a long outage the device finds the hub by '
        'itself within the 10-second retry cap', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      await ipad.proxy.down();
      final n = ipad.s.workspace.createNote(title: 'During the outage');
      // Long enough for the retry pause to grow to its cap.
      await Future<void>.delayed(const Duration(seconds: 20));
      await ipad.proxy.up();
      final took = await until(
        () => pc.s.workspace.notes[n.id] != null,
        what: 'the outage note on the PC',
        limit: const Duration(seconds: 20),
      );
      // Cap (10 s) + jitter (0.5 s) + one cycle on each side.
      expect(took, lessThan(const Duration(seconds: 14)));
      await until(() => !ipad.s.syncPendingLocal, what: 'nothing waiting');
    });

    test('H6 hub restart: edits from both sides made while the hub was '
        'down converge once it is back', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      await rig.stopHub();
      final a = pc.s.workspace.createNote(title: 'PC while down');
      final b = ipad.s.workspace.createNote(title: 'iPad while down');
      await until(
        () => ipad.s.syncConnection == SyncConnection.offline,
        what: 'iPad offline',
      );
      expectNotClaimingSync(ipad.s, 'hub down');
      await rig.startHub();
      await until(
        () =>
            pc.s.workspace.notes[b.id] != null &&
            ipad.s.workspace.notes[a.id] != null,
        what: 'both notes on both devices',
        limit: const Duration(seconds: 30),
      );
    });

    test('H7 interrupted transfer: a large upload cut by the network '
        'finishes after reconnecting, complete and intact', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      ipad.s.syncEngineForTests!.client.uploadChunkBytes = 64 * 1024;
      final bytes = fakePdf(3 * 1024 * 1024);
      final src = File('${rig.root.path}${sep}big.pdf')
        ..writeAsBytesSync(bytes);
      final asset = await ipad.s.workspace.documentAssetFromFile(src);
      final engine = ipad.s.syncEngineForTests!;
      await until(
        () => engine.transfers.all.any((t) => t.upload && t.bytes > 0),
        what: 'the upload under way',
      );
      await ipad.proxy.down(); // cut mid-transfer
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await ipad.proxy.up();
      await until(
        () async {
          final a = pc.s.workspace.assets[asset.id];
          if (a?.file == null) return false;
          return pc.s.workspace.attachments.fileFor(a!.file!).exists();
        },
        what: 'the file on the PC',
        limit: const Duration(seconds: 60),
      );
      final got = await pc.s.workspace.attachments.readBytes(
        pc.s.workspace.assets[asset.id]!.file!,
      );
      expect(got, bytes, reason: 'arrived complete and unchanged');
    });

    test('H8 conflicting edits: both versions are kept, nothing is '
        'overwritten, and the user is told once', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      final n = pc.s.workspace.createNote(title: 'Shared', body: 'start');
      await until(
        () => ipad.s.workspace.notes[n.id] != null,
        what: 'note on the iPad',
      );
      await pc.proxy.down();
      await ipad.proxy.down();
      pc.s.workspace.notes.put(
        pc.s.workspace.notes[n.id]!.copyWith(body: 'PC wording'),
      );
      ipad.s.workspace.notes.put(
        ipad.s.workspace.notes[n.id]!.copyWith(body: 'iPad wording'),
      );
      await ipad.proxy.up();
      await until(
        () async =>
            openedData(await rig.hub.store.current('notes', n.id))?['body'] ==
            'iPad wording',
        what: 'the iPad edit on the hub',
        limit: const Duration(seconds: 30),
      );
      await pc.proxy.up();
      await until(
        () => pc.s.openConflictCount == 1 && ipad.s.openConflictCount == 1,
        what: 'one conflict on both devices',
        limit: const Duration(seconds: 30),
      );
      final c = pc.s.conflictResolver.open().single;
      expect(
        {pc.s.workspace.notes[n.id]!.body, c.otherData!['body']},
        {'PC wording', 'iPad wording'},
        reason: 'both versions kept',
      );
      // Independent edits of other records were not affected.
      expect(pc.s.workspace.notes.length, 1);
    });

    test('H10 device restart: unsynced offline edits survive a restart and '
        'go out afterwards', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      await ipad.proxy.down();
      final n = ipad.s.workspace.createNote(title: 'Before restart', body: 'b');
      await rig.restart(ipad); // the iPad is switched off and on again
      expect(ipad.s.workspace.notes[n.id]?.body, 'b');
      await ipad.proxy.up();
      await until(
        () => pc.s.workspace.notes[n.id]?.body == 'b',
        what: 'the note on the PC after the restart',
        limit: const Duration(seconds: 30),
      );
    });

    test('H13 large attachments: small changes are not held back by a big '
        'file, which arrives in slices over several cycles', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      final engine = ipad.s.syncEngineForTests!
        ..transferBudget = const Duration(milliseconds: 1);
      engine.client.uploadChunkBytes = 128 * 1024;
      pc.s.syncEngineForTests!.transferBudget = const Duration(milliseconds: 1);
      final statuses = <String>{};
      void watch() => statuses.add(ipad.s.syncStatus);
      ipad.s.addListener(watch);
      final bytes = fakePdf(3 * 1024 * 1024, seed: 7);
      final src = File('${rig.root.path}${sep}huge.pdf')
        ..writeAsBytesSync(bytes);
      final asset = await ipad.s.workspace.documentAssetFromFile(src);
      final first = ipad.s.workspace.createNote(title: 'Right after');
      await until(
        () => statuses.any((s) => s.contains('still transferring')),
        what: 'the big file paused for the next cycle',
      );
      // A note written while the file is still on its way overtakes it.
      final later = ipad.s.workspace.createNote(title: 'During the upload');
      await until(
        () => pc.s.workspace.notes[later.id] != null,
        what: 'the small note on the PC',
      );
      expect(pc.s.workspace.notes[first.id], isNotNull);
      expect(
        await rig.hub.store.current('assets', asset.id),
        isNull,
        reason: 'the big file was still on its way',
      );
      await until(
        () async {
          final a = pc.s.workspace.assets[asset.id];
          if (a?.file == null) return false;
          return pc.s.workspace.attachments.fileFor(a!.file!).exists();
        },
        what: 'the big file on the PC',
        limit: const Duration(seconds: 90),
      );
      expect(
        await pc.s.workspace.attachments.readBytes(
          pc.s.workspace.assets[asset.id]!.file!,
        ),
        bytes,
      );
      ipad.s.removeListener(watch);
    });

    test('H14 database maintenance: compacting the hub journal while devices '
        'sync loses nothing, and a new device still gets everything', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      final n = pc.s.workspace.createNote(title: 'Rev', body: '0');
      for (var i = 1; i <= 15; i++) {
        pc.s.workspace.notes.put(
          pc.s.workspace.notes[n.id]!.copyWith(body: '$i'),
        );
        await pc.s.syncNow();
      }
      await rig.hub.store.compact();
      ipad.s.workspace.createNote(title: 'After compaction');
      await until(
        () => pc.s.workspace.notes.length == 2,
        what: 'the iPad note after compaction',
      );
      final fresh = await rig.device('fresh', ipad: true);
      await until(
        () =>
            fresh.s.workspace.notes.length == 2 &&
            fresh.s.workspace.notes[n.id]?.body == '15',
        what: 'everything on a device paired after compaction',
      );
      expect(ipad.s.workspace.notes[n.id]?.body, '15');
    });
  });

  // ------------------------------------------- H: local (single device)
  group('H. acceptance scenarios (this device)', () {
    late Directory root;
    final opened = <Workspace>[];
    setUp(() => root = Directory.systemTemp.createTempSync('theapp_715_'));
    tearDown(() async {
      for (final ws in opened) {
        ws.dispose();
      }
      opened.clear();
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    Future<Workspace> open(Directory dir) async {
      final ws = Workspace(dir);
      await ws.load();
      opened.add(ws);
      return ws;
    }

    test('H9 app crash: a torn save, its leftover temporary file and an '
        'unfinished multi-step change are repaired at the next start, '
        'without asking, and only once', () async {
      final dir = Directory('${root.path}${sep}app');
      var ws = await open(dir);
      final keep = ws.createNote(title: 'Keep', body: 'v1');
      await ws.flush();
      ws.notes.put(ws.notes[keep.id]!.copyWith(body: 'v2'));
      await ws.flush(); // v1 is now the previous-version copy
      ws.dispose();
      opened.remove(ws);
      // The "crash": a save that never finished renaming, and the main file
      // torn in the middle of writing.
      final notes = File('${dir.path}${sep}data${sep}notes.json');
      File('${notes.path}.tmp').writeAsStringSync('{"records": [');
      notes.writeAsStringSync('{"records": [{"id": "${keep.id}", "bo');
      ws = await open(dir);
      expect(ws.notes[keep.id], isNotNull, reason: 'restored, not lost');
      expect(ws.lastTempCleanup, 1, reason: 'the leftover was removed');
      expect(File('${notes.path}.tmp').existsSync(), isFalse);
      expect(ws.store.recoveries, hasLength(1), reason: 'said once');
      await ws.flush();
      ws.dispose();
      opened.remove(ws);
      // The next start finds nothing to repair: no repeated message.
      ws = await open(dir);
      expect(ws.store.recoveries, isEmpty);
      expect(ws.lastTempCleanup, 0);
      expect(ws.notes[keep.id], isNotNull);
    });

    test('E: a file that is only locked for a moment is never treated as '
        'damaged (not moved aside, not replaced by an older copy)', () async {
      final dir = Directory('${root.path}${sep}lock')..createSync();
      final store = JsonFileStore(dir);
      await store.write('data', 'notes', {'v': 1});
      await store.write('data', 'notes', {'v': 2});
      final file = File('${dir.path}${sep}data${sep}notes.json');
      if (Platform.isWindows) {
        // Another program holds the file exclusively for a moment.
        final raf = file.openSync(mode: FileMode.append);
        raf.lockSync(FileLock.exclusive);
        Timer(const Duration(milliseconds: 150), () {
          raf.unlockSync();
          raf.closeSync();
        });
      }
      expect(await store.read('data', 'notes'), {'v': 2});
      expect(store.recoveries, isEmpty);
      final names = dir
          .listSync(recursive: true)
          .map((e) => e.uri.pathSegments.last)
          .where((n) => n.contains('corrupt'));
      expect(names, isEmpty, reason: 'nothing quarantined');
    });

    test('H11 backup creation: background backups are verified and several '
        'recovery points are kept', () async {
      final ws = await open(Directory('${root.path}${sep}app'));
      ws.createNote(title: 'One');
      await ws.flush();
      final t = DateTime(2026, 11, 6, 12);
      final b1 = await ws.backups.liveSnapshot(now: t);
      ws.createNote(title: 'Two');
      await ws.flush();
      final b2 = await ws.backups.liveSnapshot(
        now: t.add(const Duration(seconds: 10)),
      );
      // Each one is intact (checked against its own manifest); the newest
      // also equals the live data.
      expect(await ws.backups.checkManifest(b1), isEmpty);
      expect(await ws.backups.checkManifest(b2), isEmpty);
      expect(await ws.backups.verify(b2), isTrue);
      final listed = (await ws.backups.list()).map((d) => d.path).toSet();
      expect(listed, containsAll([b1.path, b2.path]));
    });

    test('H12 backup failure: a failed backup never replaces the last good '
        'one, leaves no half copy, and the next attempt succeeds', () async {
      final ws = await open(Directory('${root.path}${sep}app'));
      ws.createNote(title: 'Precious');
      await ws.flush();
      final t = DateTime(2026, 11, 6, 12);
      final good = await ws.backups.liveSnapshot(now: t);
      // Something occupies the place of the next copy (as a full disk or a
      // locked folder would).
      final blocker = File(
        '${ws.backups.backupsDir.path}$sep'
        '${BackupService.partialPrefix}20261106-120010-live',
      )..writeAsStringSync('in the way');
      await expectLater(
        ws.backups.liveSnapshot(now: t.add(const Duration(seconds: 10))),
        throwsA(isA<FileSystemException>()),
      );
      expect((await ws.backups.list()).map((d) => d.path), [good.path]);
      expect(await ws.backups.verify(good), isTrue);
      blocker.deleteSync();
      final retried = await ws.backups.liveSnapshot(
        now: t.add(const Duration(seconds: 20)),
      );
      expect(await ws.backups.verify(retried), isTrue);
      expect((await ws.backups.list()).map((d) => d.path).toSet(), {
        good.path,
        retried.path,
      });
    });

    test('H12b backup failure in the app: the automatic backup is retried '
        'by itself with growing pauses and reported until it works', () async {
      final dir = Directory('${root.path}${sep}auto')..createSync();
      // The backups folder's place is taken by a file: every backup fails.
      final blocker = File('${dir.path}${sep}backups')
        ..writeAsStringSync('in the way');
      final ws = Workspace(dir);
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      s.capture.fetchPreviews = false;
      final unit = AppState.autoBackupRetryUnit;
      AppState.autoBackupRetryUnit = const Duration(milliseconds: 100);
      addTearDown(() => AppState.autoBackupRetryUnit = unit);
      await shareSyncKey(s);
      try {
        await s.init();
        expect(s.autoBackupError, isNotNull, reason: 'not hidden');
        expect(s.autoBackupError, contains('untouched'));
        blocker.deleteSync();
        await until(
          () => s.autoBackupError == null,
          what: 'the retried backup',
        );
        final list = await s.workspace.backups.list();
        expect(list, isNotEmpty);
        expect(await s.workspace.backups.verify(list.first), isTrue);
      } finally {
        await s.flush();
        s.dispose();
      }
    });

    test('H15 app update / migration: a workspace from an older version '
        'opens in the new app with everything in it', () async {
      final f = await buildPreUpdateWorkspace(
        Directory('${root.path}${sep}old'),
      );
      final ws = Workspace(f.dir);
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      s.capture.fetchPreviews = false;
      await shareSyncKey(s);
      await s.init();
      try {
        expect(s.dataProblem, isNull);
        expect(s.workspace.notes[f.noteId], isNotNull);
        expect(s.workspace.notes[f.noteId]!.body, contains(secretBodyMarker));
        final backups = await s.workspace.backups.list();
        expect(
          backups.any((b) => b.path.contains('pre-')),
          isTrue,
          reason: 'a backup taken before the upgrade',
        );
      } finally {
        await s.flush();
        s.dispose();
      }
    });

    test('H16 storage exhaustion: a full disk keeps every change, shows a '
        'calm plain-language notice, retries with growing pauses, and saves '
        'by itself once space is free', () async {
      final dir = Directory('${root.path}${sep}app')..createSync();
      final ws = await open(dir);
      final store = FullDiskStore(dir);
      final notes = RecordCollection<Note>(
        store: store,
        name: 'notes_715',
        fromJson: Note.fromJson,
        clock: SyncClock(),
        saveDelay: const Duration(milliseconds: 10),
      );
      notes.onSaveResult = (n, ok) =>
          ws.noteSaveResult(n, ok, notes.lastSaveError);
      final oldDelay = RecordCollection.retryDelay;
      final oldMax = RecordCollection.maxRetryDelay;
      RecordCollection.retryDelay = const Duration(milliseconds: 100);
      RecordCollection.maxRetryDelay = const Duration(milliseconds: 400);
      addTearDown(() {
        RecordCollection.retryDelay = oldDelay;
        RecordCollection.maxRetryDelay = oldMax;
        notes.dispose();
      });
      store.full = true;
      final now = DateTime.now();
      notes.put(
        Note(
          id: 'n1',
          title: 'Written on a full disk',
          body: 'must survive',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await until(
        () => ws.unsaved.value.contains('notes_715'),
        what: 'the unsaved notice',
      );
      expect(ws.saveIssue.value, StorageIssue.full);
      final notice = unsavedNoticeText(ws.saveIssue.value);
      expect(notice, contains('Storage is full'));
      expect(notice, contains('Everything saved earlier is safe'));
      expect(notes['n1']!.body, 'must survive', reason: 'kept in the app');
      // Retried by itself, but with growing pauses (not hammering the disk).
      final a0 = store.attempts;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final tries = store.attempts - a0;
      expect(tries, greaterThanOrEqualTo(2), reason: 'it keeps retrying');
      expect(tries, lessThanOrEqualTo(8), reason: 'with growing pauses');
      // Space is freed: saved without anything from the user.
      store.full = false;
      await until(() => ws.unsaved.value.isEmpty, what: 'saved by itself');
      expect(ws.saveIssue.value, isNull);
      final raw = await JsonFileStore(dir).read('data', 'notes_715');
      expect(((raw!['records'] as List).single as Map)['body'], 'must survive');
    });

    test('H16b storage exhaustion while drawing: a mindmap that could not be '
        'saved is kept even after its page is closed, and saved once space '
        'is free', () async {
      final dir = Directory('${root.path}${sep}draw');
      final ws = Workspace(dir);
      final canvases = FullDiskCanvases(ws.store);
      final s = AppState(
        canvases: canvases,
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      s.capture.fetchPreviews = false;
      await shareSyncKey(s);
      await s.init();
      final oldDelay = RecordCollection.retryDelay;
      RecordCollection.retryDelay = const Duration(milliseconds: 100);
      addTearDown(() => RecordCollection.retryDelay = oldDelay);
      try {
        await s.createCanvas(title: 'Other');
        final otherId = s.canvas!.id;
        await s.createCanvas(title: 'Sketch');
        final c = s.canvas!;
        final id = c.id;
        canvases.full = true;
        c.addItems([text('ink', 'drawn on a full disk')]);
        await c.flush();
        expect(c.saveState, SaveState.failed);
        expect(s.workspace.unsaved.value, contains('canvas:$id'));
        expect(s.workspace.saveIssue.value, StorageIssue.full);
        // The page is closed (another one opens) while the disk is full.
        await s.openCanvas(otherId);
        expect(s.canvas!.id, otherId);
        canvases.full = false;
        await until(
          () => s.workspace.unsaved.value.isEmpty,
          what: 'the closed mindmap saved by itself',
        );
        final doc = await canvases.load(id);
        expect(doc!.items.map((i) => i.id), contains('ink'));
      } finally {
        await s.flush();
        s.dispose();
      }
    });
  });
}
