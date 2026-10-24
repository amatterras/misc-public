// The 10-second work (maintenance.dart) and the frequent backups it makes
// (BackupService.liveSnapshot): started once, the 10-second cadence on a
// fake clock, no overlapping runs (a missed tick runs once afterwards),
// separate truthful outcomes, a clean stop, backups that are checked
// before they count, interrupted backups cleaned up, and bounded disk use.
import 'dart:async';
import 'dart:io';

import 'package:flutter_application_1/app/maintenance.dart';
import 'package:flutter_application_1/data/storage/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('scheduler', () {
    testWidgets('starts once and runs every job every 10 seconds', (
      tester,
    ) async {
      var syncs = 0, backups = 0;
      final m = MaintenanceScheduler([
        MaintenanceJob('sync', () async {
          syncs++;
          return true;
        }),
        MaintenanceJob('backup', () async {
          backups++;
          return true;
        }),
      ]);
      m.start();
      m.start(); // again, e.g. a page rebuilt: no second timer
      m.start();
      expect(m.timersStarted, 1);
      await tester.pump(); // the first round runs at once
      expect((syncs, backups), (1, 1));
      await tester.pump(const Duration(seconds: 9));
      expect((syncs, backups), (1, 1));
      await tester.pump(const Duration(seconds: 1));
      expect((syncs, backups), (2, 2));
      await tester.pump(const Duration(seconds: 50));
      expect((syncs, backups), (7, 7));
      await m.stop();
      await tester.pump(const Duration(seconds: 30));
      expect((syncs, backups), (7, 7)); // nothing after stop
    });

    testWidgets('a slow job never overlaps; missed ticks run once after', (
      tester,
    ) async {
      var running = 0, most = 0, runs = 0;
      Completer<void>? gate;
      final m = MaintenanceScheduler([
        MaintenanceJob('backup', () async {
          runs++;
          running++;
          most = running > most ? running : most;
          await gate?.future;
          running--;
          return true;
        }),
      ]);
      gate = Completer<void>();
      m.start();
      await tester.pump();
      // Three more ticks while the first run is still going.
      await tester.pump(const Duration(seconds: 30));
      expect(runs, 1);
      expect(m.current?.name, 'backup');
      final first = gate;
      gate = null; // the catch-up run finishes at once
      first.complete();
      await tester.pump();
      await tester.pump();
      expect(runs, 2); // one catch-up, not three
      expect(most, 1); // never two at once
      await m.stop();
    });

    testWidgets('outcomes are separate and truthful', (tester) async {
      var syncFails = true;
      final m = MaintenanceScheduler([
        MaintenanceJob('sync', () async {
          if (syncFails) throw StateError('Hub not reachable');
          return true;
        }),
        MaintenanceJob('backup', () async => true),
        MaintenanceJob('nothing', () async => false), // nothing to do
      ]);
      m.start();
      await tester.pump();
      final sync = m.job('sync'), backup = m.job('backup');
      expect(sync.lastSuccess, isNull); // a failure is never a success
      expect(sync.lastError, contains('Hub not reachable'));
      expect(sync.failures, 1);
      expect(backup.lastSuccess, isNotNull); // unaffected by sync
      expect(m.job('nothing').lastSuccess, isNull);
      expect(m.job('nothing').lastRun, isNotNull);
      await tester.pump(const Duration(seconds: 10));
      expect(sync.failures, 2);
      syncFails = false;
      await tester.pump(const Duration(seconds: 10));
      expect(sync.lastSuccess, isNotNull);
      expect(sync.lastError, isNull);
      expect(sync.failures, 0);
      await m.stop();
    });

    test('stop waits for a running job, then nothing runs', () async {
      final gate = Completer<void>();
      var finished = false;
      final m = MaintenanceScheduler([
        MaintenanceJob('backup', () async {
          await gate.future;
          finished = true;
          return true;
        }),
      ]);
      m.start();
      final stopping = m.stop();
      Timer(const Duration(milliseconds: 50), gate.complete);
      await stopping;
      expect(finished, isTrue); // not cut in half
      m.tick();
      m.start();
      expect(m.job('backup').runs, 1);
    });

    test('the data lock runs actions one at a time, in order', () async {
      final lock = SerialLock();
      final order = <String>[];
      var inside = 0, most = 0;
      Future<void> act(String name, int ms) => lock.run(() async {
        inside++;
        most = inside > most ? inside : most;
        await Future<void>.delayed(Duration(milliseconds: ms));
        order.add(name);
        inside--;
      });
      await Future.wait([act('sync', 30), act('backup', 1), act('sync2', 1)]);
      expect(order, ['sync', 'backup', 'sync2']);
      expect(most, 1);
      // A failed action does not block the next one.
      await expectLater(
        lock.run(() async => throw StateError('x')),
        throwsStateError,
      );
      expect(await lock.run(() async => 42), 42);
    });
  });

  group('frequent backups', () {
    late Directory root;
    late BackupService backups;
    setUp(() {
      root = Directory.systemTemp.createTempSync('theapp_live_');
      Directory('${root.path}/data').createSync();
      File('${root.path}/data/notes.json').writeAsStringSync('{"n":1}');
      Directory('${root.path}/attachments').createSync();
      File('${root.path}/attachments/big.jpg')
          .writeAsBytesSync(List.filled(4096, 7));
      backups = BackupService(root);
    });
    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    List<String> names() => [
      for (final d in backups.backupsDir.listSync().whereType<Directory>())
        d.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ]..sort();

    test('a checked copy of the records, listed only when complete', () async {
      final b = await backups.liveSnapshot();
      expect(await backups.verify(b), isTrue);
      expect(File('${b.path}/data/notes.json').readAsStringSync(), '{"n":1}');
      // Records only: photos are in the weekly full backup.
      expect(Directory('${b.path}/attachments').existsSync(), isFalse);
      expect((await backups.list()).map((d) => d.path), [b.path]);
      expect(names().where((n) => n.startsWith('.')), isEmpty);
    });

    test('a failed backup leaves the last good one and no half copy', () async {
      final at = DateTime(2026, 10, 24, 12);
      final good = await backups.liveSnapshot(now: at);
      // The hidden folder's place is taken by a file: the copy cannot be
      // written (as with a full disk or a locked folder).
      final next = at.add(const Duration(seconds: 10));
      final stamp = '20261024-120010-live';
      File('${backups.backupsDir.path}/${BackupService.partialPrefix}$stamp')
          .writeAsStringSync('in the way');
      await expectLater(
        backups.liveSnapshot(now: next),
        throwsA(isA<FileSystemException>()),
      );
      expect((await backups.list()).map((d) => d.path), [good.path]);
      expect(await backups.verify(good), isTrue); // still a good backup
    });

    test('an interrupted backup is never listed and is cleaned up', () async {
      final good = await backups.liveSnapshot();
      final half = Directory(
        '${backups.backupsDir.path}/${BackupService.partialPrefix}20261024-120000-live/data',
      )..createSync(recursive: true);
      File('${half.path}/notes.json').writeAsStringSync('{"n":');
      expect((await backups.list()).map((d) => d.path), [good.path]);
      expect(await backups.removeInterrupted(), 1);
      expect(names().where((n) => n.startsWith('.')), isEmpty);
      expect(Directory(good.path).existsSync(), isTrue);
    });

    test(
      'repeated backups keep a bounded set and never push out others',
      () async {
        final manual = await backups.snapshot('manual');
        final start = DateTime(2026, 10, 24, 12);
        for (var i = 0; i < BackupService.keepLive + 8; i++) {
          File('${root.path}/data/notes.json').writeAsStringSync('{"n":$i}');
          await backups.liveSnapshot(now: start.add(Duration(seconds: 10 * i)));
        }
        final live = names().where((n) => n.endsWith('-live')).toList();
        expect(live, hasLength(BackupService.keepLive));
        expect(live.first, '20261024-120120-live'); // the oldest 8 went
        expect(Directory(manual.path).existsSync(), isTrue);
        // Disk use: records only, so each is the size of the records.
        final sizes = [
          for (final n in live)
            Directory('${backups.backupsDir.path}/$n')
                .listSync(recursive: true)
                .whereType<File>()
                .fold<int>(0, (s, f) => s + f.lengthSync()),
        ];
        expect(sizes.every((s) => s < 100), isTrue);
      },
    );
  });
}
