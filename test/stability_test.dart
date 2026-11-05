import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/record_collection.dart';
import 'package:flutter_application_1/data/storage/json_file_store.dart';
import 'package:flutter_application_1/features/capture/capture_service.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/send_to.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_stable_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String p(String rel) => '${dir.path}${Platform.pathSeparator}$rel';
  List<String> corruptFiles() =>
      Directory(p('items'))
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .where((n) => n.contains('.corrupt-'))
          .toList();

  group('damaged files', () {
    test('a damaged file is moved aside and its backup is restored', () async {
      final store = JsonFileStore(dir);
      await store.write('items', 'a', {'v': 1});
      await store.write('items', 'a', {'v': 2}); // .bak now holds v1
      File(p('items/a.json')).writeAsStringSync('{ broken');

      final fresh = JsonFileStore(dir);
      expect(await fresh.read('items', 'a'), {'v': 1});
      expect(fresh.recoveries, hasLength(1));
      expect(corruptFiles(), hasLength(1));
      // The good copy is back in place, so the next save can't copy the
      // damaged file over the backup.
      expect(jsonDecode(File(p('items/a.json')).readAsStringSync()), {'v': 1});
      await fresh.write('items', 'a', {'v': 3});
      expect(jsonDecode(File(p('items/a.json.bak')).readAsStringSync()), {
        'v': 1,
      });
    });

    test(
      'with no usable backup, the damaged files are kept, not overwritten',
      () async {
        Directory(p('items')).createSync(recursive: true);
        File(p('items/a.json')).writeAsStringSync('{ broken');
        File(p('items/a.json.bak')).writeAsStringSync('also broken');
        final store = JsonFileStore(dir);
        expect(await store.read('items', 'a'), isNull);
        expect(store.recoveries.single, contains('no usable backup'));
        expect(corruptFiles(), hasLength(2));
        await store.write('items', 'a', {'v': 9});
        expect(corruptFiles(), hasLength(2)); // evidence preserved
      },
    );

    test('a failed save is retried by itself until it succeeds', () async {
      RecordCollection.retryDelay = const Duration(milliseconds: 100);
      addTearDown(
        () => RecordCollection.retryDelay = const Duration(seconds: 5),
      );
      // A file where the data folder should be: every write fails.
      final blocker = File(p('data'))..writeAsStringSync('in the way');
      final c = RecordCollection<Note>(
        store: JsonFileStore(dir),
        name: 'notes',
        fromJson: Note.fromJson,
        saveDelay: const Duration(milliseconds: 10),
      );
      await c.load();
      final now = DateTime.now();
      c.put(
        Note(
          id: 'n1',
          title: 'Keep me',
          body: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(File(p('data/notes.json')).existsSync(), isFalse);
      // The obstacle goes away; no further edit is made.
      blocker.deleteSync();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final saved = File(p('data/notes.json'));
      expect(saved.existsSync(), isTrue, reason: 'retried without a new edit');
      expect(saved.readAsStringSync(), contains('Keep me'));
      c.dispose();
    });

    test(
      'the workspace reports unsaved changes until a retry succeeds',
      () async {
        RecordCollection.retryDelay = const Duration(milliseconds: 100);
        addTearDown(
          () => RecordCollection.retryDelay = const Duration(seconds: 5),
        );
        final ws = Workspace(dir);
        await ws.load();
        final blocker = File(p('data'))..writeAsStringSync('in the way');
        ws.createNote(title: 'Not lost');
        await expectLater(ws.flush(), throwsA(isA<FileSystemException>()));
        expect(ws.unsaved.value, contains('notes'));
        blocker.deleteSync();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(ws.unsaved.value, isEmpty, reason: 'retry saved it');
        final again = Workspace(dir);
        await again.load();
        expect(again.notes.all.map((n) => n.title), ['Not lost']);
        again.dispose();
        ws.dispose();
      },
    );

    test('unreadable records survive load and save', () async {
      Directory(p('data')).createSync(recursive: true);
      File(p('data/notes.json')).writeAsStringSync(
        jsonEncode({
          'schema': 2,
          'records': [
            {
              'id': 'ok',
              'title': 'Fine',
              'body': '',
              'createdAt': '2026-10-21T10:00:00.000',
              'updatedAt': '2026-10-21T10:00:00.000',
            },
            {'id': 'future', 'title': 42, 'fromNewerVersion': true},
          ],
        }),
      );
      final c = RecordCollection<Note>(
        store: JsonFileStore(dir),
        name: 'notes',
        fromJson: Note.fromJson,
      );
      await c.load();
      expect(c.length, 1);
      c.put(c['ok']!.copyWith(title: 'Edited'));
      await c.flush();
      final saved =
          jsonDecode(File(p('data/notes.json')).readAsStringSync()) as Map;
      final ids = (saved['records'] as List).map((r) => r['id']);
      expect(ids, containsAll(['ok', 'future']));
      c.dispose();
    });
  });

  group('single window', () {
    test(
      'a heartbeat left by a crashed process does not block start-up',
      () async {
        final bridge = SendToBridge(dir);
        File(p('instance.json')).writeAsStringSync(
          jsonEncode({
            'pid': 999999, // not running
            'at': DateTime.now().toIso8601String(),
          }),
        );
        expect(await bridge.isAnotherInstanceRunning(), isFalse);
      },
    );

    test(
      'a live other process with a fresh heartbeat is detected',
      () async {
        final other = await Process.start('ping', ['-n', '6', '127.0.0.1']);
        addTearDown(other.kill);
        File(p('instance.json')).writeAsStringSync(
          jsonEncode({
            'pid': other.pid,
            'at': DateTime.now().toIso8601String(),
          }),
        );
        expect(await SendToBridge(dir).isAnotherInstanceRunning(), isTrue);
      },
      skip: Platform.isWindows
          ? false
          : 'Uses the Windows ping program to start a second process',
    );

    test('an old heartbeat is ignored', () async {
      File(p('instance.json')).writeAsStringSync(
        jsonEncode({
          'pid': pid + 1,
          'at': DateTime.now()
              .subtract(const Duration(minutes: 5))
              .toIso8601String(),
        }),
      );
      expect(await SendToBridge(dir).isAnotherInstanceRunning(), isFalse);
    });

    test('a second launch asks the open window to come forward', () async {
      final ws = Workspace(dir);
      await ws.load();
      final bridge = SendToBridge(dir);
      var focused = 0;
      bridge.onFocusRequested = () => focused++;
      await bridge.requestFocus();
      final count = await bridge.processRequests(
        CaptureService(ws, fetchPreviews: false),
      );
      expect(focused, 1);
      expect(count, 0);
      expect(ws.inbox.length, 0);
      ws.dispose();
    });
  });
}
