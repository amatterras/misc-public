// Risk G1: an older app version must never drop fields that a newer version
// added, neither when it saves a record nor when it syncs it. Simulated by
// writing records with extra fields that this version does not know.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/models/unknown_fields.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

Task task(String id, String title) => Task(
  id: id,
  title: title,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

Map<String, dynamic> readJson(Directory dir, String path) =>
    jsonDecode(File('${dir.path}$sep$path').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the local in-process hub

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_fields_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('helpers: known fields always win over kept ones', () {
    final unknown = unknownFields(
      {'id': 'a', 'title': 'T', 'colour2': 'teal'},
      const ['id', 'title'],
    );
    expect(unknown, {'colour2': 'teal'});
    expect(withUnknownFields({'title': 'new'}, {'title': 'old', 'x': 1}), {
      'title': 'new',
      'x': 1,
    });
  });

  group('records', () {
    void writeTasksFile() {
      Directory('${dir.path}${sep}data').createSync(recursive: true);
      File('${dir.path}${sep}data${sep}tasks.json').writeAsStringSync(
        jsonEncode({
          'schema': 2,
          'futureFileKey': {'kept': true},
          'records': [
            {
              ...task('t1', 'From a newer version').toJson(),
              'futureField': {'energy': 'high'},
            },
            task('t2', 'Plain').toJson(),
          ],
          'revs': <String, String>{},
          'tombstones': <String, String>{},
        }),
      );
    }

    test(
      'editing and saving keeps fields this version does not know',
      () async {
        writeTasksFile();
        final ws = Workspace(dir);
        await ws.load();
        ws.tasks.put(ws.tasks['t1']!.copyWith(title: 'Edited here'));
        ws.tasks.put(ws.tasks['t2']!.copyWith(title: 'Also edited'));
        await ws.flush();

        final file = readJson(dir, 'data${sep}tasks.json');
        final records = {
          for (final r
              in (file['records'] as List).cast<Map<String, dynamic>>())
            r['id']: r,
        };
        expect(records['t1']!['title'], 'Edited here');
        expect(records['t1']!['futureField'], {'energy': 'high'});
        expect(records['t2']!.containsKey('futureField'), isFalse);
        expect(file['futureFileKey'], {'kept': true});
        expect(ws.tasks.jsonOf('t1')!['futureField'], {'energy': 'high'});
        ws.dispose();

        // And again after a restart.
        final again = Workspace(dir);
        await again.load();
        expect(again.tasks.jsonOf('t1')!['futureField'], {'energy': 'high'});
        again.dispose();
      },
    );

    test('a deleted record does not bring its old fields back', () async {
      writeTasksFile();
      final ws = Workspace(dir);
      await ws.load();
      ws.tasks.remove('t1');
      ws.tasks.put(task('t1', 'New record, same id'));
      expect(ws.tasks.jsonOf('t1')!.containsKey('futureField'), isFalse);
      ws.dispose();
    });

    test('a newer version removing a field is respected', () async {
      final ws = Workspace(dir);
      await ws.load();
      ws.tasks.applyRemote('t1', ws.clock.now(), {
        ...task('t1', 'A').toJson(),
        'futureField': 1,
      });
      expect(ws.tasks.jsonOf('t1')!['futureField'], 1);
      ws.tasks.applyRemote('t1', ws.clock.now(), task('t1', 'B').toJson());
      expect(ws.tasks.jsonOf('t1')!.containsKey('futureField'), isFalse);
      ws.dispose();
    });
  });

  group('canvases', () {
    Map<String, dynamic> canvasWithFutureFields() {
      final json = CanvasDocument(
        id: 'cv1',
        title: 'Ideas',
        updatedAt: DateTime.utc(2026, 10, 1),
        items: [
          TextItem(
            id: 'a',
            position: Offset.zero,
            width: 200,
            minHeight: 40,
            text: 'Newer note',
          ),
          TextItem(
            id: 'b',
            position: const Offset(400, 0),
            width: 200,
            minHeight: 40,
            text: 'Plain',
          ),
        ],
      ).toJson();
      (json['items'] as List).first['futureStyle'] = 'wavy';
      json['futureRoot'] = [1, 2];
      json['metaUnknownFields'] = {
        'tags': ['school'],
      };
      return json;
    }

    test('moving, deleting and undoing items keeps unknown fields', () async {
      final repo = FileCanvasRepository(Workspace(dir).store);
      await repo.store.write('canvases', 'cv1', canvasWithFutureFields());
      final doc = (await repo.load('cv1'))!;
      expect(doc.itemUnknownFields['a'], {'futureStyle': 'wavy'});

      final saved = <CanvasDocument>[];
      final c = CanvasController(
        document: doc,
        onSave: (d) async {
          saved.add(d);
          await repo.save(d);
        },
        saveDelay: const Duration(milliseconds: 1),
      );
      // Drag item "a" to the right (selected first, as the lasso would).
      c.select(['a']);
      c.pointerDown(
        const Offset(20, 20),
        timeStamp: const Duration(seconds: 1),
      );
      c.pointerMove(const Offset(70, 20));
      c.pointerUp();
      await c.flush();
      var file = readJson(dir, 'canvases${sep}cv1.json');
      var a = (file['items'] as List).firstWhere((i) => i['id'] == 'a');
      expect(a['x'], greaterThan(0));
      expect(a['futureStyle'], 'wavy');
      expect(file['futureRoot'], [1, 2]);
      expect(file['metaUnknownFields'], {
        'tags': ['school'],
      });

      // Deleted: gone from the file; undo: back with its fields.
      c.select(['a']);
      c.deleteSelection();
      await c.flush();
      file = readJson(dir, 'canvases${sep}cv1.json');
      expect((file['items'] as List).map((i) => i['id']), ['b']);
      c.undo();
      await c.flush();
      file = readJson(dir, 'canvases${sep}cv1.json');
      a = (file['items'] as List).firstWhere((i) => i['id'] == 'a');
      expect(a['futureStyle'], 'wavy');
      c.dispose();
    });

    test('renaming a closed canvas keeps unknown fields', () async {
      final repo = FileCanvasRepository(Workspace(dir).store);
      await repo.store.write('canvases', 'cv1', canvasWithFutureFields());
      final doc = (await repo.load('cv1'))!;
      await repo.save(doc.copyWith(title: 'Renamed'));
      final file = readJson(dir, 'canvases${sep}cv1.json');
      expect(file['title'], 'Renamed');
      expect(file['futureRoot'], [1, 2]);
      expect((file['items'] as List).first['futureStyle'], 'wavy');
    });
  });

  test(
    'sync: a newer device\'s fields survive an edit on an older one',
    () async {
      final hub = await HubServer.start(
        dir: Directory('${dir.path}${sep}hub'),
        port: 0,
        dailyBackups: false,
      );
      Future<(Workspace, FileCanvasRepository, SyncEngine)> device(
        String name,
      ) async {
        final ws = Workspace(Directory('${dir.path}$sep$name'));
        await ws.load();
        final token = await hub.auth.register(
          hub.auth.createPairingCode(),
          ws.device!.id,
          name,
        );
        final repo = FileCanvasRepository(ws.store);
        return (
          ws,
          repo,
          SyncEngine(
            workspace: ws,
            canvases: repo,
            client: SyncClient(
              Uri.parse('http://127.0.0.1:${hub.port}'),
              token: token,
            ),
          ),
        );
      }

      try {
        final (newWs, newRepo, newSync) = await device('newer');
        final (oldWs, oldRepo, oldSync) = await device('older');

        // The "newer" device has a task and a canvas with extra fields.
        newWs.tasks.applyRemote('t1', newWs.clock.now(), {
          ...task('t1', 'Revise').toJson(),
          'futureField': 'kept',
        });
        final stamp = newWs.clock.now();
        final doc = CanvasDocument(
          id: 'cv1',
          title: 'Ideas',
          updatedAt: DateTime.now(),
          items: [
            TextItem(
              id: 'a',
              position: Offset.zero,
              width: 200,
              minHeight: 40,
              text: 'Hello',
            ),
          ],
          itemRevs: {'a': stamp},
          metaRev: stamp,
          itemUnknownFields: {
            'a': {'futureStyle': 'wavy'},
          },
          metaUnknownFields: {
            'tags': ['school'],
          },
          unknownKeys: {'futureRoot': true},
        );
        await newRepo.save(doc);
        await newWs.flush();
        await newSync.syncOnce();

        // The older device receives them and edits both.
        await oldSync.syncOnce();
        expect(oldWs.tasks.jsonOf('t1')!['futureField'], 'kept');
        oldWs.tasks.put(oldWs.tasks['t1']!.copyWith(title: 'Revise (old app)'));
        final received = (await oldRepo.load('cv1'))!;
        expect(received.itemUnknownFields['a'], {'futureStyle': 'wavy'});
        final c = CanvasController(
          document: received,
          onSave: oldRepo.save,
          saveDelay: const Duration(milliseconds: 1),
          clock: oldWs.clock,
        );
        c.select(['a']); // as the lasso would
        c.pointerDown(
          const Offset(20, 20),
          timeStamp: const Duration(seconds: 1),
        );
        c.pointerMove(const Offset(90, 20));
        c.pointerUp();
        c.title = 'Ideas (renamed on old app)';
        await c.flush();
        c.dispose();
        await oldWs.flush();
        await oldSync.syncOnce();

        // Back on the newer device: the edits arrived, the fields are intact.
        await newSync.syncOnce();
        final t = newWs.tasks.jsonOf('t1')!;
        expect(t['title'], 'Revise (old app)');
        expect(t['futureField'], 'kept');
        final back = (await newRepo.load('cv1'))!;
        expect(back.title, 'Ideas (renamed on old app)');
        expect((back.items.single as TextItem).position, isNot(Offset.zero));
        expect(back.itemUnknownFields['a'], {'futureStyle': 'wavy'});
        expect(back.metaUnknownFields, {
          'tags': ['school'],
        });
        expect(back.unknownKeys, {
          'futureRoot': true,
        }, reason: 'local file key');
        newWs.dispose();
        oldWs.dispose();
      } finally {
        await hub.stop();
      }
    },
  );
}
