// Interrupted transfers leave partial files behind. They used to stay for
// ever (the sync notes listed "stale partial downloads are not swept" as an
// open limit). They are removed after a while; anything still wanted is not.
import 'dart:io';

import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

void main() {
  late Directory root;
  late Workspace ws;
  late SyncEngine engine;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_sweep_');
    ws = Workspace(Directory('${root.path}${sep}app'));
    await ws.load();
    engine = SyncEngine(
      workspace: ws,
      canvases: FileCanvasRepository(ws.store),
      client: SyncClient(Uri.parse('http://127.0.0.1:1'), token: 't'),
    );
  });
  tearDown(() {
    ws.dispose();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  File put(String folder, String name, {required int daysOld}) {
    final dir = Directory('${ws.root.path}$sep$folder')
      ..createSync(recursive: true);
    final f = File('${dir.path}$sep$name')..writeAsBytesSync([1, 2, 3]);
    f.setLastModifiedSync(DateTime.now().subtract(Duration(days: daysOld)));
    return f;
  }

  test('old partial downloads and stray staged uploads go; fresh ones, wanted '
      'ones and other files stay', () async {
    final oldDl = put('incoming', 'aaa.dl', daysOld: 9);
    final freshDl = put('incoming', 'bbb.dl', daysOld: 1);
    final other = put('incoming', 'notes.txt', daysOld: 30);
    final strayUp = put('outbox', 'stray.up', daysOld: 3);
    final freshUp = put('outbox', 'fresh.up', daysOld: 0);
    final wantedUp = put('outbox', 'wanted.up', daysOld: 40);
    await ws.store.write('sync', 'outbox', {
      'pending': {'plainsha': 'wanted'},
    });
    await engine.sweepTransferLeftovers(force: true);
    expect(oldDl.existsSync(), isFalse, reason: 'partial download, 9 days');
    expect(freshDl.existsSync(), isTrue, reason: 'may still be resumed');
    expect(other.existsSync(), isTrue, reason: 'not a transfer file');
    expect(strayUp.existsSync(), isFalse, reason: 'nothing refers to it');
    expect(freshUp.existsSync(), isTrue, reason: 'too new to judge');
    expect(
      wantedUp.existsSync(),
      isTrue,
      reason: 'a pending upload is kept however old',
    );
  });

  test('a missing folder and an empty workspace are fine, and it runs once '
      'per run unless forced', () async {
    await engine.sweepTransferLeftovers(force: true);
    final late = put('incoming', 'late.dl', daysOld: 9);
    await engine.sweepTransferLeftovers(); // already swept in this run? no:
    // the first call above counted, so this one is skipped
    expect(late.existsSync(), isTrue);
    await engine.sweepTransferLeftovers(force: true);
    expect(late.existsSync(), isFalse);
  });
}
