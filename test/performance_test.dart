// Measured performance on a large synthetic workspace. Targets are generous
// upper bounds for a normal PC; the measured times are printed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/search/search_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_perf_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    '2,000 notes, 1,000 tasks, 200 calendar entries: load and search',
    () async {
      final ws = Workspace(dir);
      await ws.load();
      final body = List.filled(
        40,
        'synthetic words for a realistic note',
      ).join(' ');
      for (var i = 0; i < 2000; i++) {
        ws.createNote(title: 'Note $i', body: '$body #$i');
      }
      for (var i = 0; i < 1000; i++) {
        ws.createTask('Task $i', dueDate: DateTime(2026, 11, 1 + i % 28));
      }
      final now = DateTime.now();
      for (var i = 0; i < 200; i++) {
        ws.entries.applyRemote(
          'e$i',
          '0001792610475963-${(i % 9999).toString().padLeft(4, '0')}-perf',
          CalendarEntry(
            id: 'e$i',
            category: CalendarCategory.values[i % 4],
            name: 'Entry $i',
            createdAt: now,
            updatedAt: now,
            archived: i >= 20,
          ).toJson(),
        );
      }
      var sw = Stopwatch()..start();
      await ws.flush();
      final saveMs = sw.elapsedMilliseconds;
      ws.dispose();

      sw = Stopwatch()..start();
      final again = Workspace(dir);
      await again.load();
      final loadMs = sw.elapsedMilliseconds;
      expect(again.notes.all.length, 2000);

      final s = AppState(
        canvases: FileCanvasRepository(again.store),
        settings: SettingsRepository(again.store),
        workspace: again,
        enableSendTo: false,
      );
      await s.init();
      sw = Stopwatch()..start();
      final hits = searchEverything(s, '#1999');
      final searchMs = sw.elapsedMilliseconds;
      expect(hits, isNotEmpty);
      // ignore: avoid_print
      print('PERF save=${saveMs}ms load=${loadMs}ms search=${searchMs}ms');
      expect(loadMs, lessThan(3000), reason: 'load target < 3 s');
      expect(searchMs, lessThan(500), reason: 'search target < 0.5 s');
      await s.flush();
      s.dispose();
    },
  );

  test('a canvas with 3,000 items and 500 connections saves and reloads', () {
    final items = <CanvasItem>[
      for (var i = 0; i < 2500; i++)
        TextItem(
          id: 't$i',
          position: Offset((i % 50) * 260.0, (i ~/ 50) * 140.0),
          width: 220,
          minHeight: 60,
          text: 'Idea $i',
        ),
      for (var i = 0; i < 500; i++)
        StrokeItem(
          id: 's$i',
          color: const Color(0xFFFFFFFF),
          strokeWidth: 2,
          points: [
            for (var p = 0; p < 30; p++) StrokePoint(i * 3.0 + p, p * 2.0),
          ],
        ),
      for (var i = 0; i < 500; i++)
        ConnectorItem(id: 'c$i', fromId: 't$i', toId: 't${i + 1}'),
    ];
    final doc = CanvasDocument(
      id: 'big',
      title: 'Big',
      items: items,
      updatedAt: DateTime(2026),
      viewport: const CanvasViewport(),
      schema: 3,
    );
    final sw = Stopwatch()..start();
    final text = jsonEncode(doc.toJson());
    final back = CanvasDocument.fromJson(
      jsonDecode(text) as Map<String, dynamic>,
    );
    final ms = sw.elapsedMilliseconds;
    expect(back.items, hasLength(3500));
    // ignore: avoid_print
    print(
      'PERF canvas 3500 items: round trip ${ms}ms, '
      '${(text.length / 1024).round()} KB',
    );
    expect(ms, lessThan(2000), reason: 'save+load target < 2 s');
  });
}
