// Benchmark: what one sync cycle costs as the amount of canvas data grows.
// Not part of the test suite (it lives in tool/ and prints numbers):
//
//   flutter test tool/sync_bench_test.dart
//
// A real hub on 127.0.0.1 and one device (SyncEngine, the same engine the app
// runs). For each size it measures, on this PC, with data at rest NOT
// encrypted (the real app also decrypts every file it reads, so real times
// are higher, never lower):
//   - the first full sync (everything is pushed);
//   - a cycle after nothing changed          (the common case: it runs
//     every 10 s on Windows and after every edit);
//   - a cycle after ONE item changed;
//   - how long localVersions() alone takes (the per-cycle "what changed?"
//     pass that reads every canvas file).
import 'dart:io';

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

({int canvases, int items, int bytesPerItem, String label}) size(
  int canvases,
  int items,
  int bytesPerItem,
  String label,
) => (
  canvases: canvases,
  items: items,
  bytesPerItem: bytesPerItem,
  label: label,
);

Future<T> timed<T>(List<int> sink, Future<T> Function() f) async {
  final w = Stopwatch()..start();
  final r = await f();
  sink.add(w.elapsedMilliseconds);
  return r;
}

String median(List<int> ms) {
  final s = [...ms]..sort();
  return '${s[s.length ~/ 2]} ms';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final sizes = [
    size(5, 20, 200, 'small: 5 notes x 20 items (100 items)'),
    size(25, 100, 300, 'medium: 25 canvases x 100 items (2.5k items)'),
    size(100, 100, 300, 'large: 100 canvases x 100 items (10k items)'),
    size(
      25,
      100,
      8000,
      'handwriting-heavy: 25 canvases x 100 items x 8 KB (20 MB)',
    ),
    size(
      100,
      100,
      8000,
      'handwriting-heavy+: 100 canvases x 100 items x 8 KB (80 MB)',
    ),
  ];

  for (final sz in sizes) {
    test(sz.label, () async {
      final root = Directory.systemTemp.createTempSync('theapp_bench_');
      final hub = await HubServer.start(
        dir: Directory('${root.path}${sep}hub'),
        port: 0,
        dailyBackups: false,
      );
      try {
        final ws = Workspace(Directory('${root.path}${sep}pc'));
        await ws.load();
        final repo = FileCanvasRepository(ws.store);
        final text = 'x' * sz.bytesPerItem;
        for (var c = 0; c < sz.canvases; c++) {
          final items = [
            for (var i = 0; i < sz.items; i++)
              TextItem(
                id: 'i$c-$i',
                position: Offset(i * 3.0, i * 2.0),
                width: 200,
                minHeight: 40,
                text: text,
              ),
          ];
          await repo.save(
            CanvasDocument(
              id: 'c$c',
              title: 'Canvas $c',
              items: items,
              updatedAt: DateTime.now(),
              itemRevs: {for (final i in items) i.id: ws.clock.now()},
              metaRev: ws.clock.now(),
            ),
          );
        }
        final token = await hub.auth.register(
          hub.auth.createPairingCode(),
          ws.device!.id,
          'pc',
        );
        final client = SyncClient(
          Uri.parse('http://127.0.0.1:${hub.port}'),
          token: token,
        );
        final engine = SyncEngine(
          workspace: ws,
          canvases: repo,
          client: client,
        );

        final first = <int>[];
        final report = await timed(first, engine.syncOnce);

        final idle = <int>[];
        for (var i = 0; i < 5; i++) {
          await timed(idle, engine.syncOnce);
        }
        final versions = <int>[];
        for (var i = 0; i < 5; i++) {
          await timed(versions, engine.localVersions);
        }
        final one = <int>[];
        for (var i = 0; i < 3; i++) {
          final doc = (await repo.load('c0'))!;
          final item = doc.items.first as TextItem;
          await repo.save(
            CanvasDocument(
              id: doc.id,
              title: doc.title,
              items: [
                item.copyWith(text: '${item.text}!'),
                ...doc.items.skip(1),
              ],
              updatedAt: DateTime.now(),
              itemRevs: {...doc.itemRevs, item.id: ws.clock.now()},
              metaRev: doc.metaRev,
            ),
          );
          await timed(one, engine.syncOnce);
        }
        final bytes = await _dirBytes(Directory('${root.path}${sep}pc'));
        // ignore: avoid_print
        print(
          'BENCH | ${sz.label}\n'
          '      | data on disk ${(bytes / 1048576).toStringAsFixed(1)} MB, '
          '${sz.canvases * sz.items} items\n'
          '      | first full sync   ${first.single} ms ($report)\n'
          '      | idle cycle        ${median(idle)}  (nothing changed; runs every 10 s on the PC)\n'
          '      | localVersions()   ${median(versions)}  (the "what changed?" pass alone)\n'
          '      | cycle, 1 item     ${median(one)}',
        );
        client.close();
      } finally {
        await hub.stop();
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      }
    }, timeout: const Timeout(Duration(minutes: 20)));
  }
}

Future<int> _dirBytes(Directory d) async {
  var n = 0;
  await for (final f in d.list(recursive: true)) {
    if (f is File) n += await f.length();
  }
  return n;
}
