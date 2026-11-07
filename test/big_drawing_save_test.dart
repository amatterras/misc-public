// Large drawings are encoded and checked on a background isolate when saved,
// so saving does not pause the app. Same file content, same order of saves.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/json_file_store.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasDocument drawing(int samples, {String title = 'Big'}) {
  final strokes = <CanvasItem>[];
  var left = samples;
  var n = 0;
  while (left > 0) {
    final count = left < 400 ? left : 400;
    strokes.add(
      StrokeItem(
        id: 's${n++}',
        points: [
          for (var i = 0; i < count; i++)
            StrokePoint(i * 0.5, n * 3.0 + (i % 7), 0.3 + (i % 5) / 10),
        ],
        color: const Color(0xFF000000),
        strokeWidth: 3,
        pressureWidth: true,
      ),
    );
    left -= count;
  }
  return CanvasDocument(
    id: 'big',
    title: title,
    items: strokes,
    updatedAt: DateTime.utc(2026, 11, 7),
  );
}

void main() {
  late Directory dir;
  late JsonFileStore store;
  late FileCanvasRepository repo;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('theapp_bigsave_');
    store = JsonFileStore(dir);
    repo = FileCanvasRepository(store);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String fileText() =>
      File('${dir.path}/canvases/big.json').readAsStringSync();

  test('a large drawing is saved with exactly the usual file content', () async {
    final doc = drawing(FileCanvasRepository.bigDrawing + 500);
    await repo.save(doc);
    expect(
      fileText(),
      const JsonEncoder.withIndent(' ').convert(doc.toJson()),
    );
    final back = await repo.load('big');
    expect(back!.items, hasLength(doc.items.length));
    expect(
      (back.items.first as StrokeItem).points.length,
      (doc.items.first as StrokeItem).points.length,
    );
  });

  test('a later small save is never overtaken by an earlier large one', () async {
    final big = repo.save(drawing(FileCanvasRepository.bigDrawing * 2));
    final small = repo.save(drawing(10, title: 'Small'));
    await Future.wait([big, small]);
    expect(jsonDecode(fileText())['title'], 'Small');
  });

  test('saving over a large drawing keeps a readable backup', () async {
    await repo.save(drawing(FileCanvasRepository.bigDrawing + 1));
    await repo.save(drawing(FileCanvasRepository.bigDrawing + 2, title: 'Two'));
    final bak = File('${dir.path}/canvases/big.json.bak').readAsStringSync();
    expect(jsonDecode(bak)['items'], isNotEmpty);
    expect(jsonDecode(fileText())['title'], 'Two');
  });
}
