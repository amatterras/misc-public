import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/sync/sync_clock.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SyncClock', () {
    test('stamps are unique, ordered, and never go backwards', () {
      var wall = 1000;
      final clock = SyncClock(deviceId: 'pc', wallClock: () => wall);
      final a = clock.now();
      final b = clock.now(); // same millisecond → counter increases
      wall = 500; // the PC clock jumps back
      final c = clock.now();
      wall = 2000;
      final d = clock.now();
      expect([a, b, c, d], [a, b, c, d]..sort());
      expect({a, b, c, d}, hasLength(4));
    });

    test('observing a later stamp moves the clock past it', () {
      final clock = SyncClock(deviceId: 'pc', wallClock: () => 1000);
      clock.observe(SyncClock.format(5000, 7, 'ipad'));
      expect(
        clock.now().compareTo(SyncClock.format(5000, 7, 'ipad')),
        greaterThan(0),
      );
    });

    test('equal times on two devices still give a deterministic order', () {
      final pc = SyncClock(deviceId: 'aaaa', wallClock: () => 1000).now();
      final phone = SyncClock(deviceId: 'bbbb', wallClock: () => 1000).now();
      expect(pc.compareTo(phone), lessThan(0));
    });

    test('old ISO tombstones are converted to stamps', () {
      final clock = SyncClock(deviceId: 'pc');
      final s = clock.normalize('2026-10-21T21:10:09.512624');
      expect(SyncClock.parse(s), isNotNull);
      expect(clock.normalize(s), s);
    });
  });

  group('workspace records', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('theapp_sync_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('device identity is created once and kept', () async {
      final a = Workspace(dir);
      await a.load();
      final b = Workspace(dir);
      await b.load();
      expect(a.device!.id, b.device!.id);
      expect(a.clock.deviceId, a.device!.id);
      a.dispose();
      b.dispose();
    });

    test(
      'a copied data folder on another machine gets its own identity',
      () async {
        final a = Workspace(dir);
        await a.load();
        final file = File('${dir.path}/sync/device.json');
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        json['host'] = 'some-other-pc';
        file.writeAsStringSync(jsonEncode(json));
        final b = Workspace(dir);
        await b.load();
        expect(b.device!.id, isNot(a.device!.id));
        a.dispose();
        b.dispose();
      },
    );

    test('revisions change only when content really changes', () async {
      final ws = Workspace(dir);
      await ws.load();
      final n = ws.createNote(title: 'A');
      final r1 = ws.notes.revOf(n.id)!;
      ws.notes.put(n.copyWith()); // same content, new updatedAt
      expect(ws.notes.revOf(n.id), r1);
      ws.notes.put(n.copyWith(title: 'B'));
      final r2 = ws.notes.revOf(n.id)!;
      expect(r2.compareTo(r1), greaterThan(0));
      ws.notes.remove(n.id);
      expect(ws.notes.revOf(n.id), isNull);
      expect(ws.notes.tombstones[n.id]!.compareTo(r2), greaterThan(0));

      await ws.flush();
      final again = Workspace(dir);
      await again.load();
      expect(again.notes.tombstones[n.id], ws.notes.tombstones[n.id]);
      // New edits after a restart sort after everything already on disk.
      final m = again.createNote(title: 'C');
      expect(
        again.notes.revOf(m.id)!.compareTo(ws.notes.tombstones[n.id]!),
        greaterThan(0),
      );
      ws.dispose();
      again.dispose();
    });

    test('version-1 record files are upgraded without losing data', () async {
      Directory('${dir.path}/data').createSync(recursive: true);
      File('${dir.path}/data/notes.json').writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'records': [
            {
              'id': 'n1',
              'title': 'Old note',
              'body': 'Kept',
              'createdAt': '2026-10-20T10:00:00.000',
              'updatedAt': '2026-10-20T11:00:00.000',
            },
          ],
          'tombstones': {'gone': '2026-10-19T09:00:00.000'},
        }),
      );
      final ws = Workspace(dir);
      await ws.load();
      expect(ws.oldestRecordSchema, 1);
      expect(ws.notes['n1']!.body, 'Kept');
      final rev = SyncClock.parse(ws.notes.revOf('n1')!)!;
      expect(
        rev.$1,
        DateTime.parse('2026-10-20T11:00:00.000')
            .toUtc()
            .millisecondsSinceEpoch,
      );
      expect(SyncClock.parse(ws.notes.tombstones['gone']!), isNotNull);
      await ws.flush();
      final saved = jsonDecode(
        File('${dir.path}/data/notes.json').readAsStringSync(),
      ) as Map;
      expect(saved['schema'], 2);
      expect((saved['revs'] as Map).keys, ['n1']);
      ws.dispose();
    });

    test('deleted canvases are remembered', () async {
      final ws = Workspace(dir);
      await ws.load();
      await ws.recordCanvasDeletion('c1');
      final again = Workspace(dir);
      await again.load();
      expect(again.canvasTombstones.keys, ['c1']);
      ws.dispose();
      again.dispose();
    });
  });

  group('canvas items', () {
    TextItem note(String id, {String text = 'x'}) => TextItem(
      id: id,
      position: Offset.zero,
      width: 200,
      minHeight: 0,
      text: text,
    );

    CanvasController make(
      List<CanvasItem> items,
      List<CanvasDocument> saved, {
      Map<String, String> revs = const {},
    }) => CanvasController(
      document: CanvasDocument(
        id: 'c',
        title: 'T',
        items: items,
        updatedAt: DateTime(2026),
        itemRevs: revs,
      ),
      onSave: (d) async => saved.add(d),
      clock: SyncClock(deviceId: 'pc'),
      saveDelay: const Duration(milliseconds: 1),
    );

    test('each save stamps only the items that changed', () async {
      final saved = <CanvasDocument>[];
      final c = make([note('a'), note('b')], saved)..select(['a']);
      c.setFontSize(30); // marks dirty
      await c.flush();
      final first = saved.last.itemRevs;
      expect(first.keys, unorderedEquals(['a', 'b']));

      c.select(['b']);
      c.setFontSize(22);
      await c.flush();
      final second = saved.last.itemRevs;
      expect(second['a'], first['a']);
      expect(second['b']!.compareTo(first['b']!), greaterThan(0));
      c.dispose();
    });

    test('deleting an item leaves a tombstone; undo brings it back', () async {
      final saved = <CanvasDocument>[];
      final c = make([note('a'), note('b')], saved)..select(['a']);
      c.deleteSelection();
      await c.flush();
      expect(saved.last.tombstones.keys, ['a']);
      expect(saved.last.itemRevs.containsKey('a'), isFalse);
      c.undo();
      await c.flush();
      expect(saved.last.tombstones, isEmpty);
      expect(saved.last.itemRevs.containsKey('a'), isTrue);
      c.dispose();
    });

    test('revs, tombstones and unknown items survive a round trip', () {
      final json = {
        'schema': 3,
        'id': 'c',
        'title': 'T',
        'updatedAt': '2026-10-21T10:00:00.000',
        'items': [
          {
            'type': 'text',
            'id': 't',
            'x': 0,
            'y': 0,
            'w': 100,
            'h': 0,
            'text': 'hi',
          },
          {'type': 'mindmapEdge', 'id': 'future', 'from': 't', 'to': 'x'},
        ],
        'itemRevs': {'t': SyncClock.format(1, 0, 'pc')},
        'tombstones': {'old': SyncClock.format(2, 0, 'pc')},
        'metaRev': SyncClock.format(3, 0, 'pc'),
      };
      final doc = CanvasDocument.fromJson(json);
      expect(doc.items, hasLength(1));
      expect(doc.unknownItems.single['type'], 'mindmapEdge');
      final back = jsonDecode(jsonEncode(doc.toJson())) as Map<String, dynamic>;
      expect((back['items'] as List).map((i) => i['id']), ['t', 'future']);
      expect(back['itemRevs'], json['itemRevs']);
      expect(back['tombstones'], json['tombstones']);
      expect(back['metaRev'], json['metaRev']);
    });

    test('renaming a canvas stamps its metadata', () async {
      final saved = <CanvasDocument>[];
      final c = make(
        [note('a')],
        saved,
        revs: {'a': SyncClock.format(1, 0, 'pc')},
      );
      c.title = 'New name';
      await c.flush();
      final meta = saved.last.metaRev!;
      expect(saved.last.itemRevs['a'], SyncClock.format(1, 0, 'pc'));
      c.title = 'Again';
      await c.flush();
      expect(saved.last.metaRev!.compareTo(meta), greaterThan(0));
      c.dispose();
    });
  });

  test('assets keep one record per URL across the workspace', () async {
    final dir = Directory.systemTemp.createTempSync('theapp_sync_');
    final ws = Workspace(dir);
    await ws.load();
    final a = ws.linkAsset('https://example.com');
    expect(ws.linkAsset('https://example.com').id, a.id);
    expect(ws.assets.all.where((x) => x.kind == AssetKind.link), hasLength(1));
    ws.dispose();
    dir.deleteSync(recursive: true);
  });
}
