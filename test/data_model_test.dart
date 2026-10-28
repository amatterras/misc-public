import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_keys.dart';

String sep = Platform.pathSeparator;

AppState appFor(Directory dir) {
  final ws = Workspace(dir);
  return AppState(
    canvases: FileCanvasRepository(ws.store),
    settings: SettingsRepository(ws.store),
    workspace: ws,
    enableSendTo: false,
  );
}

String digest(File f) => sha256.convert(f.readAsBytesSync()).toString();

/// An older-format data folder like the one on this PC before the upgrade:
/// a schema-1 canvas, schema-1 records, and a photo.
void writeOldData(Directory dir) {
  Directory('${dir.path}${sep}canvases').createSync(recursive: true);
  Directory('${dir.path}${sep}data').createSync(recursive: true);
  Directory('${dir.path}${sep}attachments').createSync(recursive: true);
  File('${dir.path}${sep}canvases${sep}c1.json').writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'id': 'c1',
      'title': 'Old canvas',
      'updatedAt': '2026-10-21T21:10:09.512624',
      'viewport': {'dx': 0.0, 'dy': 0.0, 'scale': 0.22},
      'items': [
        {
          'type': 'text',
          'id': 't1',
          'x': 1.0,
          'y': 2.0,
          'w': 420.0,
          'h': 0.0,
          'text': 'Hello',
          'fontSize': 22.0,
        },
        {
          'type': 'image',
          'id': 'i1',
          'assetId': 'a1',
          'x': 0,
          'y': 0,
          'w': 10,
          'h': 10,
        },
      ],
    }),
  );
  File('${dir.path}${sep}data${sep}assets.json').writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'records': [
        {
          'id': 'a1',
          'kind': 'image',
          'file': 'a1.png',
          'createdAt': '2026-10-20T10:00:00.000',
          'updatedAt': '2026-10-20T10:00:00.000',
        },
      ],
    }),
  );
  File('${dir.path}${sep}data${sep}notes.json').writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'records': [
        {
          'id': 'n1',
          'title': 'Note',
          'body': 'Kept',
          'folderId': 'f1',
          'assetIds': ['a1'],
          'createdAt': '2026-10-20T10:00:00.000',
          'updatedAt': '2026-10-20T11:00:00.000',
        },
      ],
      'tombstones': {'gone': '2026-10-19T09:00:00.000'},
    }),
  );
  File('${dir.path}${sep}data${sep}folders.json').writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'records': [
        {'id': 'f1', 'name': 'School', 'updatedAt': '2026-10-20T09:00:00.000'},
      ],
    }),
  );
  File('${dir.path}${sep}attachments${sep}a1.png')
      .writeAsBytesSync([1, 2, 3, 4]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_model_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('timestamps are stored in UTC and read back as the same instant', () {
    final created = DateTime(2026, 10, 21, 23, 30); // local
    final n = Note(
      id: 'n',
      title: 't',
      body: '',
      createdAt: created,
      updatedAt: created,
    );
    final json = n.toJson();
    expect(json['createdAt'], endsWith('Z'));
    final back = Note.fromJson(json);
    expect(back.createdAt.isAtSameMomentAs(created), isTrue);
    expect(back.createdAt.isUtc, isFalse, reason: 'shown in local time');
    // Older files without a timezone still mean local time.
    expect(
      Note.fromJson({...json, 'createdAt': '2026-10-21T23:30:00.000'})
          .createdAt,
      created,
    );
  });

  test('data from a newer app version is never opened or rewritten', () async {
    Directory('${dir.path}${sep}data').createSync(recursive: true);
    final file = File('${dir.path}${sep}data${sep}notes.json')
      ..writeAsStringSync(
        jsonEncode({'schema': 99, 'records': [], 'futureField': true}),
      );
    final before = digest(file);
    final app = appFor(dir);
    await app.init();
    expect(app.dataProblem, contains('newer version'));
    expect(app.canvas, isNull);
    await app.flush();
    expect(digest(file), before);
    expect(
      Directory('${dir.path}${sep}canvases').existsSync(),
      isFalse,
      reason: 'no new canvas was created',
    );
  });

  test('upgrade: verified backup with photos first, then everything at once, ids kept', () async {
    writeOldData(dir);
    final photo = File('${dir.path}${sep}attachments${sep}a1.png');
    final photoHash = digest(photo);
    final app = appFor(dir);
    await app.init();
    expect(app.dataProblem, isNull);

    final backups = await app.workspace.backups.list();
    final pre = backups.singleWhere((b) => b.path.contains('-pre-v'));
    expect(
      File('${pre.path}${sep}attachments${sep}a1.png').existsSync(),
      isTrue,
      reason: 'photos included',
    );
    expect(
      jsonDecode(
        File('${pre.path}${sep}canvases${sep}c1.json').readAsStringSync(),
      )['schema'],
      1,
      reason: 'the backup holds the original, unconverted files',
    );

    // Every file was upgraded immediately, with ids and links intact.
    final canvas = jsonDecode(
      File('${dir.path}${sep}canvases${sep}c1.json').readAsStringSync(),
    ) as Map;
    expect(canvas['schema'], CanvasDocument.schemaVersion);
    expect((canvas['itemRevs'] as Map).keys, unorderedEquals(['t1', 'i1']));
    final stamp = SyncClock.parse((canvas['itemRevs'] as Map)['t1'] as String)!;
    expect(
      stamp.$1,
      DateTime.parse('2026-10-21T21:10:09.512624')
          .toUtc()
          .millisecondsSinceEpoch,
    );
    for (final name in ['notes', 'assets', 'folders']) {
      final j = jsonDecode(
        File('${dir.path}${sep}data$sep$name.json').readAsStringSync(),
      ) as Map;
      expect(j['schema'], 2, reason: name);
      expect((j['revs'] as Map), isNotEmpty, reason: name);
    }
    final note = app.workspace.notes['n1']!;
    expect(note.body, 'Kept');
    expect(app.workspace.folders[note.folderId], isNotNull);
    expect(app.workspace.assets[note.assetIds.single], isNotNull);
    expect(app.workspace.notes.tombstones['gone'], isNotNull);
    expect(digest(photo), photoHash, reason: 'attachments are never modified');
    app.dispose();

    // A second start needs no migration and makes no second upgrade backup.
    final again = appFor(dir);
    await again.init();
    final after = await again.workspace.backups.list();
    expect(after.where((b) => b.path.contains('-pre-v')), hasLength(1));
    again.dispose();
  });

  test('if the pre-upgrade backup fails, nothing is changed and the app stops safely', () async {
    writeOldData(dir);
    File('${dir.path}${sep}backups')
        .writeAsStringSync('not a folder'); // backups impossible
    final canvasFile = File('${dir.path}${sep}canvases${sep}c1.json');
    final before = digest(canvasFile);
    final app = appFor(dir);
    await app.init();
    expect(app.dataProblem, contains('verified'));
    await app.flush();
    expect(digest(canvasFile), before);
    expect(jsonDecode(canvasFile.readAsStringSync())['schema'], 1);
  });

  test(
    'a category over the limit (after a merge) can still be edited, not grown',
    () async {
      final ws = Workspace(dir);
      await ws.load();
      CalendarEntry e(String id) => CalendarEntry(
        id: id,
        category: CalendarCategory.habits,
        name: id,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      for (var i = 0; i < 6; i++) {
        ws.entries.applyRemote(
          'h$i',
          SyncClock(deviceId: 'ipad').now(),
          e('h$i').toJson(),
        );
      }
      expect(ws.overLimitCategories, [CalendarCategory.habits]);
      ws.saveEntry(ws.entries['h0']!.copyWith(name: 'Renamed')); // allowed
      expect(ws.entries['h0']!.name, 'Renamed');
      expect(
        () => ws.saveEntry(e('h6')),
        throwsA(isA<CalendarLimitException>()),
      );
      ws.setArchived('h1', true);
      expect(
        () => ws.setArchived('h1', false),
        throwsA(isA<CalendarLimitException>()),
      );
      ws.dispose();
    },
  );

  test(
    'remote versions keep their revision and are not re-stamped locally',
    () async {
      final ws = Workspace(dir);
      await ws.load();
      final remoteRev = SyncClock(
        deviceId: 'ipad',
        wallClock: () => 5000,
      ).now();
      ws.notes.applyRemote('r1', remoteRev, {
        'id': 'r1',
        'title': 'From iPad',
        'body': '',
      });
      expect(ws.notes.revOf('r1'), remoteRev);
      ws.notes.applyRemote(
        'r1',
        SyncClock(deviceId: 'ipad', wallClock: () => 6000).now(),
        null,
      );
      expect(ws.notes['r1'], isNull);
      expect(ws.notes.tombstones['r1'], isNotNull);
      // Local edits after that sort after the remote stamp.
      final local = ws.createNote(title: 'Local');
      expect(ws.notes.revOf(local.id)!.compareTo(remoteRev), greaterThan(0));
      ws.dispose();
    },
  );

  test(
    'backups stay bounded and the newest pre-upgrade backup is kept',
    () async {
      final ws = Workspace(dir);
      await ws.load();
      ws.createNote(title: 'x');
      await ws.flush();
      await ws.backups.snapshot('pre-v3');
      for (var i = 0; i < 25; i++) {
        await ws.backups.snapshot('manual');
      }
      final all = await ws.backups.list();
      expect(all.length, lessThanOrEqualTo(21));
      expect(all.where((b) => b.path.contains('-pre-v3')), hasLength(1));
      ws.dispose();
    },
  );

  test('restore swaps folders safely and a restore can be undone', () async {
    final ws = Workspace(dir);
    await ws.load();
    ws.createNote(title: 'Original');
    await ws.flush();
    final b = await ws.backups.snapshot('manual');
    ws.createNote(title: 'Later');
    await ws.flush();
    await ws.backups.restore(b);
    final after = Workspace(dir);
    await after.load();
    expect(after.notes.all.map((n) => n.title), ['Original']);
    expect(
      dir.listSync().where(
        (e) => e.path.contains('.restore-') || e.path.contains('.replaced-'),
      ),
      isEmpty,
    );
    final undo = (await after.backups.list()).firstWhere(
      (d) => d.path.endsWith('-before-restore'),
    );
    final notes = jsonDecode(
      File('${undo.path}${sep}data${sep}notes.json').readAsStringSync(),
    ) as Map;
    expect((notes['records'] as List).length, 2);
    ws.dispose();
    after.dispose();
  });

  test(
    'the app keeps working when its hub is stopped; edits go out later',
    () async {
      HttpOverrides.global = null;
      final hubDir = Directory('${dir.path}${sep}hub');
      var hub = await HubServer.start(
        dir: hubDir,
        port: 0,
        dailyBackups: false,
      );
      final port = hub.port;
      final app = appFor(Directory('${dir.path}${sep}app'));
      await app.init();
      final code = keyedPairingCode(hub.auth);
      expect(await app.pairWithHub('http://127.0.0.1:$port', code), isNull);
      await app.syncNow();
      expect(app.syncStatus, startsWith('Synced'));
      await hub.stop();

      final n = app.workspace.createNote(title: 'Written while the hub is off');
      await app.syncNow();
      expect(app.syncStatus, contains('Will retry'));
      expect(app.workspace.notes[n.id], isNotNull);
      await app.flush();

      hub = await HubServer.start(dir: hubDir, port: port, dailyBackups: false);
      await app.syncNow();
      expect(app.syncStatus, startsWith('Synced'));
      expect(
        openedData(await hub.store.current('notes', n.id))!['title'],
        'Written while the hub is off',
      );
      await hub.stop();
      app.dispose();
    },
  );
}
