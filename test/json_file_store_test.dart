import 'dart:io';

import 'package:flutter_application_1/data/storage/json_file_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late JsonFileStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('theapp_test_');
    store = JsonFileStore(dir);
  });

  tearDown(() => dir.delete(recursive: true));

  test('writes, overwrites and reads documents', () async {
    await store.write('items', 'a', {'v': 1});
    await store.write('items', 'a', {'v': 2});
    expect(await store.read('items', 'a'), {'v': 2});
    expect(await store.list('items'), ['a']);
  });

  test('rapid concurrent writes all land in order', () async {
    await Future.wait([
      for (var i = 0; i < 20; i++) store.write('items', 'a', {'v': i}),
    ]);
    expect(await store.read('items', 'a'), {'v': 19});
  });

  test('falls back to the backup when the main file is corrupt', () async {
    await store.write('items', 'a', {'v': 1});
    await store.write('items', 'a', {'v': 2});
    final main = File('${dir.path}/items/a.json');
    await main.writeAsString('{ not json');
    expect(await store.read('items', 'a'), {'v': 1});
  });

  test('a file damaged after its first save is recovered', () async {
    await store.write('items', 'a', {'v': 1});
    final bak = File('${dir.path}/items/a.json.bak');
    expect(await bak.exists(), isTrue, reason: 'first save keeps a copy');
    await File('${dir.path}/items/a.json').writeAsString('{ not json');
    expect(await store.read('items', 'a'), {'v': 1});
    expect(store.recoveries.single, contains('restored'));
  });

  test('a damaged file is never copied over the good backup', () async {
    await store.write('items', 'a', {'v': 1});
    await store.write('items', 'a', {'v': 2}); // .bak = v1
    final main = File('${dir.path}/items/a.json');
    final bak = File('${dir.path}/items/a.json.bak');
    // Damaged on disk while the app keeps running and saves again.
    await main.writeAsString('{ garbage');
    await store.write('items', 'a', {'v': 3});
    expect(await store.read('items', 'a'), {'v': 3});
    expect(
      await bak.readAsString(),
      contains('"v": 1'),
      reason: 'good copy kept',
    );
    final kept = Directory('${dir.path}/items')
        .listSync()
        .where((f) => f.path.contains('a.json.corrupt-'));
    expect(kept, hasLength(1), reason: 'the damaged file is kept, not deleted');
    // The next damage is still recoverable.
    await main.writeAsString('');
    expect(await store.read('items', 'a'), {'v': 1});
  });

  test('a damaged backup is set aside and replaced by a good copy', () async {
    await store.write('items', 'a', {'v': 1});
    final bak = File('${dir.path}/items/a.json.bak');
    await bak.writeAsString('{ broken backup');
    await store.write('items', 'a', {'v': 2});
    // v1 was valid, so it became the backup.
    expect(await bak.readAsString(), contains('"v": 1'));
    await File('${dir.path}/items/a.json').writeAsString('x');
    expect(await store.read('items', 'a'), {'v': 1});
  });

  test('trash moves files instead of deleting them', () async {
    await store.write('items', 'a', {'v': 1});
    await store.moveToTrash('items', 'a');
    expect(await store.read('items', 'a'), isNull);
    final trashed = Directory('${dir.path}/items/.trash').listSync();
    expect(trashed, hasLength(1));
  });
}
