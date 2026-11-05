// The canvas manifest must be a pure optimisation: whatever happens to the
// canvas files, the pending set found through the manifest is EXACTLY the one
// a full scan of every canvas finds (same keys, same revisions, same data).
//
// The property test drives random sequences of every kind of change (edits,
// additions, deletions, renames, canvas deletion and restore, partial and
// complete "pushes", remote changes, files replaced behind the app's back,
// damaged files, damaged / missing / stale / truncated manifests, a manifest
// from before a crash) and compares after every step. The remaining tests
// pin the unusual file states and the races one by one.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/sync/canvas_manifest.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

class Rig {
  Rig(this.dir);
  final Directory dir;
  late Workspace ws;
  late FileCanvasRepository repo;
  late SyncEngine engine;
  final state = SyncState();

  Future<void> open() async {
    ws = Workspace(dir);
    await ws.load();
    repo = FileCanvasRepository(ws.store);
    engine = SyncEngine(
      workspace: ws,
      canvases: repo,
      client: SyncClient(Uri.parse('http://127.0.0.1:1'), token: 't'),
    );
  }

  /// Opens the same data folder again, as after an app restart (the manifest
  /// is read back from disk; nothing is remembered in memory).
  Future<void> restart() async {
    await ws.flush();
    ws.dispose();
    await open();
  }

  File fileOf(String id) => File('${dir.path}${sep}canvases$sep$id.json');

  TextItem item(String id, String text) => TextItem(
    id: id,
    position: const Offset(1, 2),
    width: 100,
    minHeight: 20,
    text: text,
  );

  /// Saves a canvas the way the app does: items with stamps, a metadata
  /// stamp, tombstones for deleted items.
  Future<void> save(
    String id, {
    required Map<String, String> items,
    String? title,
    Map<String, String>? tombstones,
    Set<String> restamp = const {},
    bool restampMeta = false,
  }) async {
    final old = await repo.load(id);
    final revs = {...?old?.itemRevs};
    for (final k in items.keys) {
      if (!revs.containsKey(k) || restamp.contains(k)) {
        revs[k] = ws.clock.now();
      }
    }
    revs.removeWhere((k, _) => !items.containsKey(k));
    await repo.save(
      CanvasDocument(
        id: id,
        title: title ?? old?.title ?? 'Canvas $id',
        items: [for (final e in items.entries) item(e.key, e.value)],
        updatedAt: DateTime.now(),
        itemRevs: revs,
        tombstones: {...?old?.tombstones, ...?tombstones},
        metaRev: old?.metaRev == null || restampMeta
            ? ws.clock.now()
            : old!.metaRev,
      ),
    );
  }

  /// Marks pending changes as sent: [keys] null = everything pending.
  Future<void> markSent([Set<String>? keys]) async {
    final pending = await engine.pendingVersionsFullScan(state);
    for (final c in pending.values) {
      if (keys == null || keys.contains(c.key)) state.base[c.key] = c.rev;
    }
  }
}

String describe(Map<String, SyncChange> m) {
  final keys = m.keys.toList()..sort();
  return [
    for (final k in keys)
      '$k ${m[k]!.rev} ${m[k]!.deleted} ${jsonEncode(m[k]!.data)}',
  ].join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Rig rig;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_manifest_');
    rig = Rig(Directory('${root.path}${sep}app'));
    await rig.open();
  });
  tearDown(() {
    try {
      rig.ws.dispose();
    } catch (_) {}
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> expectEquivalent([String? why]) async {
    final full = await rig.engine.pendingVersionsFullScan(rig.state);
    final fast = await rig.engine.pendingVersions(rig.state);
    expect(describe(fast), describe(full), reason: why);
  }

  group('equivalence with a full scan', () {
    test('an empty workspace, then one canvas, then nothing new', () async {
      await expectEquivalent('empty');
      await rig.save('c1', items: {'a': 'one', 'b': 'two'});
      await expectEquivalent('first canvas');
      await rig.markSent();
      await expectEquivalent('everything sent');
      expect(await rig.engine.pendingVersions(rig.state), isEmpty);
    });

    test('an unchanged cycle reads no canvas at all', () async {
      for (var i = 0; i < 20; i++) {
        await rig.save('c$i', items: {'a': 'x', 'b': 'y'});
      }
      await rig.markSent();
      await rig.engine.pendingVersions(rig.state);
      final manifest = rig.engine.canvasManifest!;
      await rig.engine.pendingVersions(rig.state);
      expect(manifest.lastReads, 0, reason: 'nothing changed, nothing read');
      await rig.save('c3', items: {'a': 'changed', 'b': 'y'}, restamp: {'a'});
      final pending = await rig.engine.pendingVersions(rig.state);
      expect(manifest.lastReads, 1, reason: 'only the changed canvas');
      expect(pending.keys, ['canvas_items/c3/a']);
    });

    test('property: random sequences of every kind of change', () async {
      for (var seed = 1; seed <= 12; seed++) {
        final r = Rig(Directory('${root.path}${sep}seed$seed'));
        await r.open();
        final rng = Random(seed);
        final ids = <String>[];
        var next = 0;
        Future<void> check(String step) async {
          final full = await r.engine.pendingVersionsFullScan(r.state);
          final fast = await r.engine.pendingVersions(r.state);
          expect(
            describe(fast),
            describe(full),
            reason: 'seed $seed after "$step"',
          );
        }

        for (var step = 0; step < 70; step++) {
          final kind = rng.nextInt(17);
          String what;
          switch (kind) {
            case 0 || 1: // new canvas
              final id = 'c${next++}';
              ids.add(id);
              await r.save(
                id,
                items: {
                  for (var i = 0; i < 1 + rng.nextInt(4); i++) 'i$i': 't$i',
                },
              );
              what = 'create $id';
            case 2 || 3 || 4: // edit an item
              if (ids.isEmpty) continue;
              final id = ids[rng.nextInt(ids.length)];
              final doc = await r.repo.load(id);
              if (doc == null || doc.items.isEmpty) continue;
              final it = doc.items[rng.nextInt(doc.items.length)];
              await r.save(
                id,
                items: {
                  for (final i in doc.items)
                    i.id: i.id == it.id ? 'edit$step' : (i as TextItem).text,
                },
                restamp: {it.id},
              );
              what = 'edit $id/${it.id}';
            case 5: // add an item
              if (ids.isEmpty) continue;
              final id = ids[rng.nextInt(ids.length)];
              final doc = await r.repo.load(id);
              if (doc == null) continue;
              await r.save(
                id,
                items: {
                  for (final i in doc.items) i.id: (i as TextItem).text,
                  'n$step': 'new',
                },
              );
              what = 'add item $id';
            case 6: // delete an item (tombstone)
              if (ids.isEmpty) continue;
              final id = ids[rng.nextInt(ids.length)];
              final doc = await r.repo.load(id);
              if (doc == null || doc.items.length < 2) continue;
              final gone = doc.items.first.id;
              await r.save(
                id,
                items: {
                  for (final i in doc.items.skip(1)) i.id: (i as TextItem).text,
                },
                tombstones: {gone: r.ws.clock.now()},
              );
              what = 'delete item $id/$gone';
            case 7: // rename (metadata change)
              if (ids.isEmpty) continue;
              final id = ids[rng.nextInt(ids.length)];
              final doc = await r.repo.load(id);
              if (doc == null) continue;
              await r.save(
                id,
                items: {for (final i in doc.items) i.id: (i as TextItem).text},
                title: 'Renamed $step',
                restampMeta: true,
              );
              what = 'rename $id';
            case 8: // delete a canvas (to the trash)
              if (ids.isEmpty) continue;
              final id = ids.removeAt(rng.nextInt(ids.length));
              await r.repo.delete(id);
              await r.ws.recordCanvasDeletion(id, rev: r.ws.clock.now());
              what = 'delete canvas $id';
            case 9: // everything is sent
              await r.markSent();
              what = 'sent all';
            case 10: // part of it is sent (an interrupted push)
              final pending = await r.engine.pendingVersionsFullScan(r.state);
              final some = {
                for (final k in pending.keys)
                  if (rng.nextBool()) k,
              };
              await r.markSent(some);
              what = 'sent ${some.length}';
            case 11: // the hub confirmed a version we do not have locally
              r.state.base['canvas_items/c${rng.nextInt(5)}/ghost'] = r.ws.clock
                  .now();
              what = 'remote-only key';
            case 12: // a file replaced behind the app's back
              if (ids.isEmpty) continue;
              final id = ids[rng.nextInt(ids.length)];
              final f = r.fileOf(id);
              if (!f.existsSync()) continue;
              final j =
                  jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
              (j['items'] as List).isEmpty
                  ? null
                  : ((j['items'] as List).first as Map)['text'] = 'external';
              j['metaRev'] = r.ws.clock.now();
              f.writeAsStringSync(jsonEncode(j));
              what = 'external edit $id';
            case 13: // a damaged canvas file (the backup copy is used)
              if (ids.isEmpty) continue;
              final id = ids[rng.nextInt(ids.length)];
              final f = r.fileOf(id);
              if (!f.existsSync()) continue;
              f.writeAsStringSync('{ not json');
              what = 'damage $id';
            case 14: // the manifest is damaged, removed or truncated
              final m = File(
                '${r.dir.path}${sep}sync${sep}canvas_manifest.json',
              );
              if (m.existsSync()) {
                switch (rng.nextInt(3)) {
                  case 0:
                    m.writeAsStringSync('garbage');
                  case 1:
                    m.deleteSync();
                  default:
                    m.writeAsStringSync(
                      m.readAsStringSync().substring(
                        0,
                        m.readAsStringSync().length ~/ 2,
                      ),
                    );
                }
              }
              await r.restart();
              what = 'manifest damaged + restart';
            case 15: // restart (the manifest is read back)
              await r.restart();
              what = 'restart';
            default: // a stale manifest: from before the latest changes
              final m = File(
                '${r.dir.path}${sep}sync${sep}canvas_manifest.json',
              );
              if (m.existsSync()) {
                final old = m.readAsStringSync();
                await r.engine.pendingVersions(r.state);
                if (ids.isNotEmpty) {
                  final id = ids[rng.nextInt(ids.length)];
                  final doc = await r.repo.load(id);
                  if (doc != null && doc.items.isNotEmpty) {
                    await r.save(
                      id,
                      items: {
                        for (final i in doc.items)
                          i.id: '${(i as TextItem).text}!',
                      },
                      restamp: doc.items.map((i) => i.id).toSet(),
                    );
                  }
                }
                await r.engine.pendingVersions(r.state);
                m.writeAsStringSync(old); // roll the manifest back
                await r.restart();
              }
              what = 'stale manifest';
          }
          await check(what);
        }
        r.ws.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('unusual file states', () {
    test('a canvas that only survives as its backup copy', () async {
      await rig.save('c1', items: {'a': 'one'});
      await rig.markSent();
      await rig.engine.pendingVersions(rig.state);
      rig.fileOf('c1').deleteSync(); // only c1.json.bak is left
      await expectEquivalent('main file missing');
      await rig.save('c1', items: {'a': 'two'}, restamp: {'a'});
      await expectEquivalent('rewritten');
    });

    test(
      'an empty file, a leftover temporary file and a stray backup',
      () async {
        await rig.save('c1', items: {'a': 'one'});
        await rig.markSent();
        await rig.engine.pendingVersions(rig.state);
        File('${rig.dir.path}${sep}canvases${sep}c1.json.tmp')
            .writeAsStringSync('half written');
        await expectEquivalent('stray tmp');
        rig.fileOf('c1').writeAsStringSync('');
        await expectEquivalent('zero-byte file');
        File('${rig.dir.path}${sep}canvases${sep}other.json.bak')
            .writeAsStringSync('{"id":"other"}');
        await expectEquivalent('stray bak with no document');
      },
    );

    test('a file changed without the size or the time changing is found by '
        'verify() (the case a fingerprint cannot see)', () async {
      await rig.save('c1', items: {'a': 'aaaa'});
      await rig.markSent();
      await rig.engine.pendingVersions(rig.state);
      final f = rig.fileOf('c1');
      final stat = f.statSync();
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      ((json['items'] as List).first as Map)['text'] = 'bbbb';
      json['itemRevs'] = {'a': rig.ws.clock.now()};
      final text = jsonEncode(json);
      // Same length, same modification time as before.
      final original = f.readAsStringSync();
      f.writeAsStringSync(
        text.length == original.length
            ? text
            : text.padRight(original.length).substring(0, original.length),
      );
      f.setLastModifiedSync(stat.modified);
      // The cheap path may not see it ...
      final cheap = await rig.engine.pendingVersions(rig.state);
      // ... but verify() always does, and repairs the cache.
      final wrong = await rig.engine.verifyManifest();
      final after = await rig.engine.pendingVersions(rig.state);
      final full = await rig.engine.pendingVersionsFullScan(rig.state);
      expect(describe(after), describe(full));
      expect(
        wrong > 0 || describe(cheap) == describe(full),
        isTrue,
        reason: 'either the cheap path saw it or verify() repaired it',
      );
    });

    test('a write through the store is never missed even if the file looks '
        'identical (in-process writes mark the canvas dirty)', () async {
      await rig.save('c1', items: {'a': 'aaaa'});
      await rig.markSent();
      await rig.engine.pendingVersions(rig.state);
      for (var i = 0; i < 30; i++) {
        // Same size text, rapid successive writes.
        await rig.save(
          'c1',
          items: {'a': 'bb${i % 10}${i % 7}'},
          restamp: {'a'},
        );
        final fast = await rig.engine.pendingVersions(rig.state);
        final full = await rig.engine.pendingVersionsFullScan(rig.state);
        expect(describe(fast), describe(full), reason: 'write $i');
        await rig.markSent();
      }
    });

    test('a canvas file restored from a backup copy (the copy keeps its older '
        'modification time) is noticed', () async {
      await rig.save('c1', items: {'a': 'version one'});
      await rig.markSent();
      await rig.engine.pendingVersions(rig.state);
      final backup = File('${rig.dir.path}${sep}c1.backup')
        ..writeAsBytesSync(rig.fileOf('c1').readAsBytesSync());
      backup.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 3)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await rig.save('c1', items: {'a': 'version two'}, restamp: {'a'});
      await rig.markSent();
      await rig.engine.pendingVersions(rig.state);
      // The restore: the old bytes are copied over the live file, with the
      // backup's (older) modification time, behind the app's back.
      final live = rig.fileOf('c1');
      backup.copySync(live.path);
      live.setLastModifiedSync(backup.lastModifiedSync());
      File('${live.path}.bak').existsSync()
          ? File('${live.path}.bak').deleteSync()
          : null;
      await expectEquivalent('restored from a backup');
      final pending = await rig.engine.pendingVersions(rig.state);
      expect(
        pending.keys,
        contains('canvas_items/c1/a'),
        reason: 'the restored (older) revision differs from what the hub has',
      );
    });

    test('a canvas moved to the trash and brought back', () async {
      await rig.save('c1', items: {'a': 'one'});
      await rig.markSent();
      await rig.engine.pendingVersions(rig.state);
      await rig.repo.delete('c1');
      await expectEquivalent('in the trash');
      final doc = await rig.ws.store.readFromTrash('canvases', 'c1');
      expect(doc, isNotNull);
      await rig.repo.save(CanvasDocument.fromJson(doc!));
      await expectEquivalent('restored');
    });
  });

  group('manifest file', () {
    test('a missing manifest is rebuilt from the canvases', () async {
      await rig.save('c1', items: {'a': 'one'});
      await rig.engine.pendingVersions(rig.state);
      final m = File('${rig.dir.path}${sep}sync${sep}canvas_manifest.json');
      expect(m.existsSync(), isTrue, reason: 'the cache is saved');
      m.deleteSync();
      File('${m.path}.bak').existsSync()
          ? File('${m.path}.bak').deleteSync()
          : null;
      await rig.restart();
      await expectEquivalent('rebuilt');
      expect(
        rig.engine.canvasManifest!.readsTotal,
        greaterThanOrEqualTo(1),
        reason: 'the canvas was read again to rebuild the entry',
      );
    });

    test('a damaged manifest is ignored and replaced', () async {
      await rig.save('c1', items: {'a': 'one'});
      await rig.engine.pendingVersions(rig.state);
      final m = File('${rig.dir.path}${sep}sync${sep}canvas_manifest.json');
      m.writeAsStringSync('{"v":1,"c":{"c1":"not a map"}}');
      File('${m.path}.bak').existsSync()
          ? File('${m.path}.bak').deleteSync()
          : null;
      await rig.restart();
      await expectEquivalent('damaged entry');
      m.writeAsStringSync('{"v":999,"c":{}}');
      await rig.restart();
      await expectEquivalent('unknown version');
    });

    test(
      'a manifest of another workspace never hides this one\'s changes',
      () async {
        await rig.save('c1', items: {'a': 'one'});
        await rig.engine.pendingVersions(rig.state);
        final other = Rig(Directory('${root.path}${sep}other'));
        await other.open();
        await other.save('c1', items: {'a': 'completely different'});
        await other.engine.pendingVersions(other.state);
        final stolen = File(
          '${other.dir.path}${sep}sync${sep}canvas_manifest.json',
        ).readAsStringSync();
        other.ws.dispose();
        File('${rig.dir.path}${sep}sync${sep}canvas_manifest.json')
            .writeAsStringSync(stolen);
        await rig.restart();
        await expectEquivalent('foreign manifest');
      },
    );

    test('a crash between a canvas write and the manifest write loses '
        'nothing', () async {
      await rig.save('c1', items: {'a': 'one'});
      await rig.markSent();
      await rig.engine.pendingVersions(rig.state);
      final m = File('${rig.dir.path}${sep}sync${sep}canvas_manifest.json');
      final before = m.readAsStringSync();
      await rig.save('c1', items: {'a': 'two'}, restamp: {'a'});
      // "Crash": the new canvas file is on disk, the manifest still the old one.
      await rig.ws.flush();
      m.writeAsStringSync(before);
      await rig.restart();
      final pending = await rig.engine.pendingVersions(rig.state);
      expect(pending.keys, contains('canvas_items/c1/a'));
      await expectEquivalent('after the crash');
    });
  });

  group('races', () {
    test('writes that land while a refresh is reading are picked up by the '
        'next one', () async {
      for (var i = 0; i < 15; i++) {
        await rig.save('c$i', items: {'a': 'x$i', 'b': 'y'});
      }
      await rig.markSent();
      await rig.engine.pendingVersions(rig.state);
      for (var round = 0; round < 6; round++) {
        final writes = [
          for (var i = 0; i < 15; i += 2)
            rig.save(
              'c$i',
              items: {'a': 'r$round-$i', 'b': 'y'},
              restamp: {'a'},
            ),
        ];
        final refresh = rig.engine.pendingVersions(rig.state);
        await Future.wait([...writes, refresh]);
        // Whatever the interleaving was, the next refresh sees everything.
        final fast = await rig.engine.pendingVersions(rig.state);
        final full = await rig.engine.pendingVersionsFullScan(rig.state);
        expect(describe(fast), describe(full), reason: 'round $round');
        await rig.markSent();
      }
    });

    test('two refreshes at the same time agree', () async {
      for (var i = 0; i < 10; i++) {
        await rig.save('c$i', items: {'a': 'x'});
      }
      final results = await Future.wait([
        rig.engine.pendingVersions(rig.state),
        rig.engine.pendingVersions(rig.state),
        rig.engine.pendingVersions(rig.state),
      ]);
      final full = await rig.engine.pendingVersionsFullScan(rig.state);
      for (final r in results) {
        expect(describe(r), describe(full));
      }
    });
  });

  test('the manifest holds revisions only, never item content', () async {
    await rig.save('c1', items: {'a': 'a very private sentence'});
    await rig.engine.pendingVersions(rig.state);
    final text = File('${rig.dir.path}${sep}sync${sep}canvas_manifest.json')
        .readAsStringSync();
    expect(text, isNot(contains('private')));
    expect(text, contains('c1'));
  });

  test('CanvasRevs.hasPending follows the remote\'s confirmed versions', () {
    final e = CanvasRevs(
      id: 'c',
      metaRev: '0001-m',
      itemRevs: {'a': '0002-a'},
      tombstones: {'z': '0003-z'},
      fingerprint: 'f',
    );
    expect(e.hasPending({}), isTrue);
    final base = {
      'canvases/c': '0001-m',
      'canvas_items/c/a': '0002-a',
      'canvas_items/c/z': '0003-z',
    };
    expect(e.hasPending(base), isFalse);
    base['canvas_items/c/a'] = '0000-old';
    expect(e.hasPending(base), isTrue);
  });
}
