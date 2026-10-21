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

  test('trash moves files instead of deleting them', () async {
    await store.write('items', 'a', {'v': 1});
    await store.moveToTrash('items', 'a');
    expect(await store.read('items', 'a'), isNull);
    final trashed = Directory('${dir.path}/items/.trash').listSync();
    expect(trashed, hasLength(1));
  });
}
