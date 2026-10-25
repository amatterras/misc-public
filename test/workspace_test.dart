import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart'
    show newId;
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/storage/backup_service.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/link_preview.dart';
import 'package:flutter_application_1/features/capture/send_to.dart';
import 'package:flutter_application_1/features/capture/capture_service.dart';
import 'package:flutter_application_1/platform/windows_native.dart';
import 'package:flutter_test/flutter_test.dart';

CalendarEntry entry(
  CalendarCategory c,
  String name, {
  DateTime? start,
  DateTime? end,
  Set<String> dates = const {},
  Set<int> weekdays = const {},
}) {
  final now = DateTime(2026, 10, 1);
  return CalendarEntry(
    id: newId(),
    category: c,
    name: name,
    createdAt: now,
    updatedAt: now,
    startDate: start,
    endDate: end,
    dates: dates,
    weekdays: weekdays,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Workspace ws;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('theapp_ws_');
    ws = Workspace(dir);
    await ws.load();
  });

  tearDown(() async {
    ws.dispose();
    await dir.delete(recursive: true);
  });

  Future<Workspace> reopen() async {
    await ws.flush();
    final again = Workspace(dir);
    await again.load();
    return again;
  }

  group('calendar', () {
    test('at most five active entries per category; archive frees a slot', () {
      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        final e = entry(
          CalendarCategory.events,
          'E$i',
          start: DateTime(2026, 10, 20),
        );
        ws.saveEntry(e);
        ids.add(e.id);
      }
      expect(
        () => ws.saveEntry(entry(CalendarCategory.events, 'sixth')),
        throwsA(isA<CalendarLimitException>()),
      );
      // Other categories are independent.
      ws.saveEntry(entry(CalendarCategory.other, 'fine'));

      ws.setArchived(ids.first, true);
      ws.saveEntry(entry(CalendarCategory.events, 'now fits'));
      expect(ws.activeCount(CalendarCategory.events), 5);
      // Restoring while full is refused, so the old entry stays archived.
      expect(
        () => ws.setArchived(ids.first, false),
        throwsA(isA<CalendarLimitException>()),
      );
      expect(ws.entries[ids.first]!.archived, isTrue);
    });

    test(
      'grid and category views read the same record (no duplicates)',
      () async {
        final e = entry(
          CalendarCategory.events,
          'Trip',
          start: DateTime(2026, 10, 20),
          end: DateTime(2026, 10, 22),
        );
        ws.saveEntry(e);
        for (final d in [20, 21, 22]) {
          final items = ws.itemsOn(DateTime(2026, 10, d));
          expect(
            items.single,
            isA<EntryOnDay>().having((x) => x.entry.id, 'id', e.id),
          );
        }
        expect(ws.itemsOn(DateTime(2026, 10, 23)), isEmpty);

        // Editing (as the category view does) changes what the grid shows.
        ws.saveEntry(
          ws.entries[e.id]!.copyWith(name: 'Holiday', colorIndex: 2),
        );
        final onGrid = ws.itemsOn(DateTime(2026, 10, 21)).single as EntryOnDay;
        expect(onGrid.entry.name, 'Holiday');
        expect(onGrid.entry.colorIndex, 2);
        expect(ws.entries.length, 1);

        final again = await reopen();
        expect(
          (again.itemsOn(DateTime(2026, 10, 22)).single as EntryOnDay)
              .entry
              .name,
          'Holiday',
        );
        again.dispose();
      },
    );

    test(
      'a habit is one record with occurrences and check-offs on many days',
      () async {
        final h = entry(
          CalendarCategory.habits,
          'Walk',
          start: DateTime(2026, 10, 19),
          weekdays: {1, 3, 5},
        );
        ws.saveEntry(h);
        final days = [for (var i = 0; i < 14; i++) DateTime(2026, 10, 19 + i)];
        final on = days.where((d) => ws.itemsOn(d).isNotEmpty).toList();
        expect(on.map((d) => d.weekday).toSet(), {1, 3, 5});
        expect(on, hasLength(6));
        ws.toggleHabit(h.id, DateTime(2026, 10, 21));
        ws.toggleHabit(h.id, DateTime(2026, 10, 23));
        expect(ws.entries.length, 1);
        final again = await reopen();
        final saved = again.entries[h.id]!;
        expect(saved.isCheckedOn(DateTime(2026, 10, 21)), isTrue);
        expect(saved.isCheckedOn(DateTime(2026, 10, 19)), isFalse);
        again.dispose();
      },
    );

    test(
      'habit time is local wall-clock metadata and legacy null stays null',
      () {
        final untimed = entry(
          CalendarCategory.habits,
          'Legacy walk',
        ).copyWith(checkoffs: {'2026-10-19'});
        expect(untimed.needsTimeConfiguration, isTrue);
        final restored = CalendarEntry.fromJson(untimed.toJson());
        expect(restored.startMinutes, isNull);
        expect(restored.checkoffs, {'2026-10-19'});
        final timed = restored.copyWith(startMinutes: () => 8 * 60 + 30);
        expect(timed.timeLabel, '08:30');
        expect(CalendarEntry.fromJson(timed.toJson()).timeLabel, '08:30');
      },
    );

    test(
      'date stepping follows local calendar dates instead of 24-hour spans',
      () {
        final before = DateTime(2026, 3, 28, 12, 15);
        final after = addDays(before, 1);
        expect(dayKey(after), '2026-03-29');
        expect(after.isUtc, isFalse, reason: 'date math stays in local time');
        expect(daysBetween(before, after), 1);
      },
    );

    test('dragging moves events (keeping length) and other-entry dates', () {
      final ev = entry(
        CalendarCategory.events,
        'Conf',
        start: DateTime(2026, 10, 20),
        end: DateTime(2026, 10, 21),
      );
      final other = entry(
        CalendarCategory.other,
        'Bin day',
        dates: {'2026-10-20', '2026-10-27'},
      );
      ws.saveEntry(ev);
      ws.saveEntry(other);
      ws.moveDayItem(
        EntryOnDay(ev),
        DateTime(2026, 10, 20),
        DateTime(2026, 10, 25),
      );
      ws.moveDayItem(
        EntryOnDay(other),
        DateTime(2026, 10, 20),
        DateTime(2026, 10, 22),
      );
      expect(ws.entries[ev.id]!.startDate, DateTime(2026, 10, 25));
      expect(ws.entries[ev.id]!.endDate, DateTime(2026, 10, 26));
      expect(ws.entries[other.id]!.dates, {'2026-10-22', '2026-10-27'});
    });

    test('reading logs show on the days read', () {
      final r = entry(CalendarCategory.reading, 'Dune').copyWith(
        readingLog: {'2026-10-20': 30},
        totalPages: () => 600,
        currentPage: 30,
      );
      ws.saveEntry(r);
      expect(ws.itemsOn(DateTime(2026, 10, 20)), hasLength(1));
      expect(ws.itemsOn(DateTime(2026, 10, 21)), isEmpty);
    });

    test(
      'reading plans materialize stable inclusive daily pages safely',
      () async {
        final series = entry(CalendarCategory.reading, 'The Book').copyWith(
          readingPlanStartDate: () => DateTime(2026, 2, 27),
          readingPlanEndDate: () => DateTime(2026, 3, 2),
        );
        ws.saveReadingPlan(series);
        final ids = [
          for (
            var day = DateTime(2026, 2, 27);
            daysBetween(day, DateTime(2026, 3, 2)) >= 0;
            day = addDays(day, 1)
          )
            '${series.id}/${dayKey(day)}',
        ];
        expect(ids, hasLength(4));
        expect(ids.toSet(), hasLength(4));
        expect(ws.itemsOn(DateTime(2026, 3, 2)).single, isA<EntryOnDay>());
        expect(
          (ws.itemsOn(DateTime(2026, 3, 2)).single as EntryOnDay).entry.id,
          ids.last,
        );
        expect(ws.activeCount(CalendarCategory.reading), 1);

        final day12 = ws.entries[ids[1]]!.copyWith(notes: 'Only page two');
        ws.saveEntry(day12);
        ws.saveReadingPlan(series);
        expect(ws.entries[ids[1]]!.notes, 'Only page two');
        expect(ws.entries[ids[2]]!.notes, isEmpty);
        expect(
          ws.entries.all.where((e) => e.readingPlanId == series.id),
          hasLength(4),
        );

        // A changed range reuses matching IDs, adds missing dates, and detaches
        // removed user-authored pages without clearing their notes.
        ws.saveReadingPlan(
          series.copyWith(
            readingPlanStartDate: () => DateTime(2026, 2, 28),
            readingPlanEndDate: () => DateTime(2026, 3, 3),
          ),
        );
        expect(ws.entries[ids.first]!.readingPlanDetached, isTrue);
        expect(ws.entries[ids.first]!.notes, isEmpty);
        expect(ws.entries[ids[1]]!.notes, 'Only page two');
        expect(ws.entries['${series.id}/2026-03-03'], isNotNull);
        expect(ws.itemsOn(DateTime(2026, 2, 27)), isEmpty);

        final again = await reopen();
        expect(again.entries['${series.id}/2026-03-03'], isNotNull);
        expect(again.entries[ids[1]]!.notes, 'Only page two');
        expect(
          again.entries.all.where((e) => e.readingPlanId == series.id),
          hasLength(5),
        );
        again.dispose();
      },
    );

    test('reversed reading plan writes no parent or partial pages', () {
      final invalid = entry(CalendarCategory.reading, 'Invalid').copyWith(
        readingPlanStartDate: () => DateTime(2026, 3, 2),
        readingPlanEndDate: () => DateTime(2026, 2, 27),
      );
      expect(() => ws.saveReadingPlan(invalid), throwsArgumentError);
      expect(ws.entries[invalid.id], isNull);
      expect(
        ws.entries.all.where((e) => e.readingPlanId == invalid.id),
        isEmpty,
      );
    });

    test(
      'calendar-date iteration includes leap day without fixed durations',
      () {
        final series = entry(CalendarCategory.reading, 'Leap').copyWith(
          readingPlanStartDate: () => DateTime(2024, 2, 28),
          readingPlanEndDate: () => DateTime(2024, 3, 1),
        );
        ws.saveReadingPlan(series);
        expect(ws.entries['${series.id}/2024-02-28'], isNotNull);
        expect(ws.entries['${series.id}/2024-02-29'], isNotNull);
        expect(ws.entries['${series.id}/2024-03-01'], isNotNull);
        expect(
          ws.entries.all.where((e) => e.readingPlanId == series.id),
          hasLength(3),
        );
      },
    );

    test(
      'tasks with a due date appear on the calendar as the original record',
      () {
        final t = ws.createTask('Essay', dueDate: DateTime(2026, 10, 24));
        final shown = ws.itemsOn(DateTime(2026, 10, 24)).single as TaskOnDay;
        expect(identical(shown.task, ws.tasks[t.id]), isTrue);
        // Checking it off from the calendar completes the task itself.
        ws.toggleTask(shown.task.id);
        expect(ws.tasks[t.id]!.done, isTrue);
        // It stays on its day, ticked: still the one record, not removed.
        final after = ws.itemsOn(DateTime(2026, 10, 24)).single as TaskOnDay;
        expect(after.task.id, t.id);
        expect(after.task.done, isTrue);
        expect(ws.tasks.length, 1);
        // Moving it on the grid changes the task's due date.
        ws.toggleTask(t.id);
        ws.moveDayItem(
          TaskOnDay(ws.tasks[t.id]!, 9),
          DateTime(2026, 10, 24),
          DateTime(2026, 10, 26),
        );
        expect(ws.tasks[t.id]!.dueDate, DateTime(2026, 10, 26));
      },
    );

    test(
      'day notes and attachments persist; empty days are not stored',
      () async {
        final link = ws.linkAsset('https://example.com/a');
        ws.attachToDay(DateTime(2026, 10, 20), link.id);
        ws.saveDay(
          ws.dayRecord(DateTime(2026, 10, 20)).copyWith(text: 'Dentist 3pm'),
        );
        ws.saveDay(ws.dayRecord(DateTime(2026, 10, 21)));
        expect(ws.days.length, 1);
        final again = await reopen();
        final day = again.dayRecord(DateTime(2026, 10, 20));
        expect(day.text, 'Dentist 3pm');
        expect(again.assets[day.assetIds.single]!.url, 'https://example.com/a');
        again.dispose();
      },
    );
  });

  group('tasks', () {
    test('recurring task moves to its next date instead of duplicating', () {
      final t = ws.createTask('Water plants', dueDate: DateTime(2026, 10, 21));
      ws.tasks.put(ws.tasks[t.id]!.copyWith(recurrence: Recurrence.weekly));
      ws.toggleTask(t.id);
      expect(ws.tasks.length, 1);
      expect(ws.tasks[t.id]!.done, isFalse);
      expect(ws.tasks[t.id]!.dueDate, DateTime(2026, 10, 28));
    });

    test('deleting a task removes its subtasks', () {
      final exam = ws.createTask('Maths exam', isExam: true);
      ws.createTask('Revise algebra', parentId: exam.id);
      ws.createTask('Past paper', parentId: exam.id);
      expect(ws.tasks.length, 3);
      ws.deleteTask(exam.id);
      expect(ws.tasks.length, 0);
    });
  });

  group('library', () {
    test('the same link captured twice is one asset', () {
      final a = ws.linkAsset('https://flutter.dev');
      final b = ws.linkAsset('https://flutter.dev');
      expect(a.id, b.id);
      expect(ws.assets.length, 1);
    });

    test('spellings of the same address are one link record', () {
      final a = ws.linkAsset('https://example.com/a');
      for (final same in [
        'https://Example.COM/a',
        'HTTPS://example.com/a',
        'https://example.com:443/a',
      ]) {
        expect(ws.linkAsset(same).id, a.id, reason: same);
      }
      expect(
        ws.linkAsset('https://example.com').id,
        ws.linkAsset('https://example.com/').id,
      );
      // Different pages stay different (paths are case-sensitive).
      expect(ws.linkAsset('https://example.com/b').id, isNot(a.id));
      expect(ws.linkAsset('https://example.com/A').id, isNot(a.id));
      expect(ws.linkAsset('https://example.com:8443/a').id, isNot(a.id));
      expect(ws.linkAsset('https://example.com/a?x=1').id, isNot(a.id));
      expect(
        ws.assets[a.id]!.url,
        'https://example.com/a',
        reason: 'kept as first captured',
      );
    });

    test('nested folders: tree, descendants and safe delete', () {
      final school = ws.createFolder('School');
      final maths = ws.createFolder('Maths', parentId: school.id);
      final algebra = ws.createFolder('Algebra', parentId: maths.id);
      final n = ws.createNote(title: 'Groups', folderId: algebra.id);
      expect(ws.folderTree().map((f) => (f.$1.name, f.$2)), [
        ('School', 0),
        ('Maths', 1),
        ('Algebra', 2),
      ]);
      expect(ws.folderAndDescendants(school.id), {
        school.id,
        maths.id,
        algebra.id,
      });
      expect(ws.folderLabel(algebra.id), 'School / Maths / Algebra');
      ws.deleteFolder(algebra.id);
      expect(ws.notes[n.id]!.folderId, maths.id);
    });

    test('notes, tags, favourites and links persist', () async {
      final n = ws.createNote(title: 'Ideas', body: 'See [[Plan]]');
      ws.notes.put(ws.notes[n.id]!.copyWith(tags: ['work'], favorite: true));
      ws.attachToNote(n.id, ws.linkAsset('https://example.com').id);
      final again = await reopen();
      final saved = again.notes[n.id]!;
      expect(saved.tags, ['work']);
      expect(saved.favorite, isTrue);
      expect(saved.linkedTitles, ['Plan']);
      expect(again.assets[saved.assetIds.single]!.url, 'https://example.com');
      again.dispose();
    });

    test('photos are copied into the attachments folder', () async {
      final src = File('${dir.path}${Platform.pathSeparator}outside.png');
      // 1x1 transparent PNG.
      await src.writeAsBytes(base64Png);
      final asset = await ws.imageAssetFromFile(src);
      await src.delete();
      expect(await ws.attachments.fileFor(asset.file!).exists(), isTrue);
      expect(asset.width, 1);
      expect(asset.height, 1);
    });
  });

  group('capture helpers', () {
    test('URL detection', () {
      expect(
        extractUrl('https://example.com/x?y=1'),
        'https://example.com/x?y=1',
      );
      expect(extractUrl('  www.example.org '), 'https://www.example.org');
      expect(extractUrl('not a link'), isNull);
      expect(extractUrl('hello https://a.com'), isNull);
      expect(extractUrl('file:///C:/x'), isNull);
      expect(displayUrl('https://www.example.com/a/b'), 'example.com/a/b');
    });

    test('link preview parsing', () {
      const html = '''
        <html><head>
        <title>Fallback &amp; title</title>
        <meta property="og:title" content="Real Title">
        <meta name="description" content="A &quot;quoted&quot; page">
        <meta property="og:image" content="/img/cover.png">
        <meta property="og:site_name" content="Example">
        </head></html>''';
      final p = LinkPreviewFetcher.parseHtml(
        html,
        Uri.parse('https://example.com/post/1'),
      );
      expect(p.title, 'Real Title');
      expect(p.description, 'A "quoted" page');
      expect(p.imageUrl, 'https://example.com/img/cover.png');
      expect(p.siteName, 'Example');
      final q = LinkPreviewFetcher.parseHtml(
        '<title>Only &amp; this</title>',
        Uri.parse('https://x.y'),
      );
      expect(q.title, 'Only & this');
    });

    test('clipboard bitmaps become valid BMP files', () {
      // 40-byte BITMAPINFOHEADER, 1x1, 32 bpp, no compression + 4 pixel bytes.
      final dib = List<int>.filled(44, 0);
      dib[0] = 40;
      dib[4] = 1;
      dib[8] = 1;
      dib[12] = 1;
      dib[14] = 32;
      final bmp = dibToBmp(Uint8List.fromList(dib));
      expect(bmp[0], 0x42);
      expect(bmp[1], 0x4D);
      expect(bmp.length, 14 + 44);
      expect(bmp[10], 54); // pixel data offset
    });

    test('Send to: requests from a second launch become Inbox items', () async {
      final bridge = SendToBridge(dir);
      final img = File('${dir.path}${Platform.pathSeparator}sent.png');
      await img.writeAsBytes(base64Png);
      final handedOff = await bridge.forward([
        '--send-to',
        img.path,
        'https://example.com/shared',
        'just text',
      ]);
      expect(handedOff, isFalse); // no other instance is running in the test
      final capture = CaptureService(ws, fetchPreviews: false);
      final count = await bridge.processRequests(capture);
      expect(count, 3);
      final items = ws.inbox.all.toList();
      expect(items, hasLength(3));
      final kinds = items.map((i) => ws.assets[i.assetId]?.kind).toSet();
      expect(kinds, containsAll([AssetKind.image, AssetKind.link, null]));
      expect(items.any((i) => i.text == 'just text'), isTrue);
      expect(await bridge.requestsDir.list().isEmpty, isTrue);
    });
  });

  test('the before-first-sync backup is never pruned', () async {
    ws.createNote(title: 'Before sync');
    await ws.flush();
    final keep = await ws.backups.snapshot('before-first-sync');
    for (var i = 0; i < BackupService.keepOther + 3; i++) {
      await ws.backups.snapshot('manual');
    }
    final names = (await ws.backups.list()).map((d) => d.path).toList();
    expect(names, contains(keep.path));
    expect(
      names.where((p) => p.contains('-manual')),
      hasLength(BackupService.keepOther),
      reason: 'other backups are still trimmed',
    );
  });

  test('backups: automatic daily snapshot and restore', () async {
    ws.createNote(title: 'Before');
    await ws.flush();
    await ws.backups.automaticBackup();
    await ws.backups.automaticBackup(); // second call the same day: no new one
    var list = await ws.backups.list();
    expect(
      list.where(
        (d) => d.path.endsWith('-auto') || d.path.endsWith('-auto-full'),
      ),
      hasLength(1),
    );

    ws.createNote(title: 'After');
    await ws.flush();
    await ws.backups.restore(list.first);
    final again = Workspace(dir);
    await again.load();
    expect(again.notes.all.map((n) => n.title), ['Before']);
    list = await ws.backups.list();
    expect(list.any((d) => d.path.endsWith('-before-restore')), isTrue);
    again.dispose();
  });

  test('a damaged record file falls back to its backup copy', () async {
    ws.createNote(title: 'One');
    await ws.flush();
    ws.createNote(title: 'Two');
    await ws.flush();
    final file = File(
      '${dir.path}${Platform.pathSeparator}data${Platform.pathSeparator}notes.json',
    );
    await file.writeAsString('{ broken');
    final again = Workspace(dir);
    await again.load();
    expect(again.notes.all.map((n) => n.title), ['One']);
    again.dispose();
  });

  test('day keys are DST-safe', () {
    expect(daysBetween(DateTime(2026, 10, 24), DateTime(2026, 10, 26)), 2);
    expect(dayKey(addDays(DateTime(2026, 3, 28), 2)), '2026-03-30');
  });
}

final base64Png = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
