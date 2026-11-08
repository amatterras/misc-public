// Regression tests for defects found by the QA / reliability audit of
// 2026-11-08. Each test names the defect it pins down.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/ics.dart';
import 'package:flutter_application_1/features/export/exports.dart';
import 'package:flutter_application_1/features/search/ranked_search.dart';
import 'package:flutter_application_1/sync/canvas_merge.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Task _task({
  required DateTime due,
  Recurrence recurrence = Recurrence.monthly,
  int? dueMinutes,
  int? remindBefore,
}) {
  final now = DateTime(2026, 1, 1);
  return Task(
    id: 't',
    title: 'Pay rent',
    createdAt: now,
    updatedAt: now,
    dueDate: due,
    dueMinutes: dueMinutes,
    remindBefore: remindBefore,
    recurrence: recurrence,
  );
}

void main() {
  group('monthly recurrence near the end of a month', () {
    // Defect: DateTime(y, m + 1, 31) overflows into the month after, so a
    // task due on Jan 31 jumped to Mar 3 and February had no occurrence.
    test('Jan 31 is followed by the last day of February', () {
      final t = _task(due: DateTime(2026, 1, 31));
      expect(t.nextOccurrence(DateTime(2026, 1, 31)), DateTime(2026, 2, 28));
      expect(t.nextOccurrence(DateTime(2028, 1, 31)), DateTime(2028, 2, 29));
      expect(t.nextOccurrence(DateTime(2026, 3, 31)), DateTime(2026, 4, 30));
      expect(t.nextOccurrence(DateTime(2026, 12, 31)), DateTime(2027, 1, 31));
    });

    test('completing it never skips a month', () {
      var t = _task(due: DateTime(2026, 1, 31));
      final months = <int>[];
      for (var i = 0; i < 12; i++) {
        t = t.completed();
        months.add(t.dueDate!.month);
      }
      expect(months, [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 1]);
    });

    test('ordinary days are unchanged', () {
      final t = _task(due: DateTime(2026, 1, 15));
      expect(t.nextOccurrence(DateTime(2026, 1, 15)), DateTime(2026, 2, 15));
      expect(t.nextOccurrence(DateTime(2026, 12, 15)), DateTime(2027, 1, 15));
    });
  });

  group('reminder time', () {
    // Defect: the reminder was midnight + N minutes of elapsed time, which
    // is an hour off on a daylight-saving change day. Wall-clock fields are
    // used now. (This PC's zone has no DST, so here the test pins the
    // wall-clock result; the DST case itself is covered by construction.)
    test('is the wall-clock time before the due time', () {
      final t = _task(
        due: DateTime(2026, 3, 29),
        recurrence: Recurrence.none,
        dueMinutes: 9 * 60 + 30,
        remindBefore: 15,
      );
      expect(t.reminderTime, DateTime(2026, 3, 29, 9, 15));
    });

    test('a reminder a day before lands on the previous day', () {
      final t = _task(
        due: DateTime(2026, 3, 1),
        recurrence: Recurrence.none,
        dueMinutes: 8 * 60,
        remindBefore: 24 * 60,
      );
      expect(t.reminderTime, DateTime(2026, 2, 28, 8));
    });
  });

  group('calendar files (.ics)', () {
    late Directory dir;
    late Workspace ws;
    final now = DateTime(2026, 10, 1);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('theapp_qa_ics_');
      ws = Workspace(dir);
    });
    tearDown(() => dir.delete(recursive: true));

    // Defect: the export only looked at `dates`, which events do not use
    // (they span startDate..endDate), so no real event was ever exported.
    test('an event is exported on every day it spans', () {
      ws.entries.put(
        CalendarEntry(
          id: 'trip',
          category: CalendarCategory.events,
          name: 'Trip',
          createdAt: now,
          updatedAt: now,
          startDate: DateTime(2026, 10, 30),
          endDate: DateTime(2026, 11, 1),
        ),
      );
      ws.entries.put(
        CalendarEntry(
          id: 'talk',
          category: CalendarCategory.events,
          name: 'Talk',
          createdAt: now,
          updatedAt: now,
          startDate: DateTime(2026, 10, 5),
          startMinutes: 14 * 60,
          durationMinutes: 90,
        ),
      );
      final ics = calendarIcs(ws, now: now);
      for (final d in ['20261030', '20261031', '20261101']) {
        expect(ics, contains('DTSTART;VALUE=DATE:$d'));
      }
      expect(ics, contains('DTSTART:20261005T140000'));
      expect(ics, contains('DTEND:20261005T153000'));
      expect('SUMMARY:Trip'.allMatches(ics), hasLength(3));
    });

    // Defect: unescaping replaced `\n` before `\\`, so a title with a
    // backslash followed by n came back with a line break.
    test('backslashes survive export and import', () {
      ws.createTask(r'C:\new\notes; draft', dueDate: DateTime(2026, 10, 7));
      final other = Workspace(Directory('${dir.path}/other'));
      expect(importIcs(other, calendarIcs(ws, now: now)), 1);
      expect(
        other.dayRecord(DateTime(2026, 10, 7)).text,
        r'• C:\new\notes; draft',
      );
    });

    // Defect: a summary with a line break became a multi-line day note, so
    // the "already imported" check never matched and every import of the
    // same file added it again.
    test('a multi-line summary is imported once', () {
      const file =
          'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20261009\r\n'
          'SUMMARY:Line one\\nline two\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
      expect(importIcs(ws, file), 1);
      expect(importIcs(ws, file), 0);
      expect(ws.dayRecord(DateTime(2026, 10, 9)).text, '• Line one line two');
    });

    // Defect: lines were folded every 75 UTF-16 units, which can cut an
    // emoji in half (written as U+FFFD) and makes non-ASCII lines longer
    // than the 75 octets RFC 5545 allows.
    test('long lines fold without breaking characters', () {
      final title = '${'ğüşöç' * 12} 🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉 end';
      ws.createTask(title, dueDate: DateTime(2026, 10, 8));
      final ics = calendarIcs(ws, now: now);
      expect(ics, isNot(contains(String.fromCharCode(0xFFFD))));
      for (final line in ics.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75), reason: line);
      }
      final other = Workspace(Directory('${dir.path}/other'));
      expect(importIcs(other, ics), 1);
      expect(other.dayRecord(DateTime(2026, 10, 8)).text, '• $title');
    });
  });

  // Defect: moving an occurrence by drag and drop left its completion
  // tick on the old date, so a finished event showed as not done on its
  // new day (and a stale tick stayed on a day it no longer occurs on).
  group('moving a completed occurrence keeps it completed', () {
    final now = DateTime(2026, 10, 1);
    test('a multi-day event keeps the ticks of every day', () {
      final e = CalendarEntry(
        id: 'e',
        category: CalendarCategory.events,
        name: 'Conference',
        createdAt: now,
        updatedAt: now,
        startDate: DateTime(2026, 10, 5),
        endDate: DateTime(2026, 10, 6),
        checkoffs: const {'2026-10-05', '2026-10-06'},
      );
      final moved = e.movedOccurrence(DateTime(2026, 10, 5), DateTime(2026, 10, 8));
      expect(moved.isCheckedOn(DateTime(2026, 10, 8)), isTrue);
      expect(moved.isCheckedOn(DateTime(2026, 10, 9)), isTrue);
      expect(moved.checkoffs, {'2026-10-08', '2026-10-09'});
    });

    test('an "other" date moves its tick with it', () {
      final e = CalendarEntry(
        id: 'o',
        category: CalendarCategory.other,
        name: 'Library',
        createdAt: now,
        updatedAt: now,
        dates: const {'2026-10-05', '2026-10-07'},
        checkoffs: const {'2026-10-05', '2026-10-07'},
      );
      final moved = e.movedOccurrence(DateTime(2026, 10, 5), DateTime(2026, 10, 10));
      expect(moved.checkoffs, {'2026-10-07', '2026-10-10'});
    });
  });

  // Defect: a search hit on a reading-plan page opened today, not the
  // page's date (only startDate, dates and the reading log were looked at).
  test('a reading-plan page found by search opens on its own day', () {
    final now = DateTime(2026, 10, 1);
    final page = CalendarEntry(
      id: 'plan/2026-11-20',
      category: CalendarCategory.reading,
      name: 'Dune · 2026-11-20',
      createdAt: now,
      updatedAt: now,
      readingPlanId: 'plan',
      readingPlanDate: DateTime(2026, 11, 20),
    );
    expect(searchHitDay(page), DateTime(2026, 11, 20));
    final other = CalendarEntry(
      id: 'o',
      category: CalendarCategory.other,
      name: 'Errand',
      createdAt: now,
      updatedAt: now,
      dates: const {'2026-12-03', '2026-10-09'},
    );
    expect(searchHitDay(other), DateTime(2026, 10, 9));
  });

  // Defect: two devices moving folders into each other (A into B here, B
  // into A there) merge into a loop with no top-level folder, and the tree
  // left both folders (and the notes inside) out entirely.
  test('folders caught in a parent loop still appear in the tree', () async {
    final dir = await Directory.systemTemp.createTemp('theapp_qa_folders_');
    addTearDown(() => dir.delete(recursive: true));
    final ws = Workspace(dir);
    final now = DateTime(2026, 10, 1);
    ws.folders.put(Folder(id: 'a', name: 'A', parentId: 'b', updatedAt: now));
    ws.folders.put(Folder(id: 'b', name: 'B', parentId: 'a', updatedAt: now));
    ws.folders.put(Folder(id: 'c', name: 'C', parentId: 'a', updatedAt: now));
    ws.folders.put(Folder(id: 'top', name: 'Top', updatedAt: now));
    final tree = ws.folderTree();
    expect({for (final (f, _) in tree) f.id}, {'a', 'b', 'c', 'top'});
    expect(tree, hasLength(4), reason: 'each folder once');
  });

  // Defects: a title such as "CON" or "aux" became a reserved Windows
  // device name (the export could not be written), and cutting a long
  // title at 80 UTF-16 units could split an emoji in half.
  group('export file names', () {
    test('reserved Windows device names are avoided', () {
      for (final t in ['CON', 'con', 'Aux', 'nul', 'COM1', 'lpt9', 'PRN']) {
        final name = safeFileName(t);
        expect(
          RegExp(r'^(con|prn|aux|nul|com\d|lpt\d)$', caseSensitive: false)
              .hasMatch(name),
          isFalse,
          reason: '$t -> $name',
        );
        expect(name.toLowerCase(), startsWith(t.toLowerCase()));
      }
      expect(safeFileName('Console notes'), 'Console notes');
    });

    test('long names are cut between characters', () {
      final name = safeFileName('${'a' * 79}🎉🎉');
      expect(name.runes.every((r) => r < 0xD800 || r > 0xDFFF), isTrue);
      expect(utf8.decode(utf8.encode(name)), name);
      expect(name.length, lessThanOrEqualTo(80));
    });
  });

  // Defect: the import read files as strict UTF-8, so a calendar file in
  // another encoding threw inside the command (nothing imported, nothing
  // said). The file is now decoded tolerantly.
  test('a calendar file that is not valid UTF-8 still imports', () async {
    final dir = await Directory.systemTemp.createTemp('theapp_qa_icsenc_');
    addTearDown(() => dir.delete(recursive: true));
    final ws = Workspace(dir);
    final bytes = <int>[
      0xEF, 0xBB, 0xBF, // UTF-8 byte order mark
      ...latin1.encode(
        'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20261012\r\n'
        'SUMMARY:Caf\xe9\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n',
      ),
    ];
    expect(() => utf8.decode(bytes), throwsFormatException);
    final text = decodeCalendarFile(bytes);
    expect(text, startsWith('BEGIN:VCALENDAR'));
    expect(importIcs(ws, text), 1);
    expect(ws.dayRecord(DateTime(2026, 10, 12)).text, startsWith('• Caf'));
  });

  // Suspected defect: incoming canvas items that cannot be read are skipped
  // (left on the hub), but a canvas metadata record with a malformed field
  // threw, so the whole canvas's batch, items included, failed every sync.
  test('a malformed canvas metadata record does not block its items', () {
    final state = CanvasSyncState(
      items: [],
      itemRevs: {},
      tombstones: {},
      title: 'Map',
      folderId: null,
      metaRev: null,
    );
    const goodItem = SyncChange(
      collection: 'canvas_items',
      id: 'c1/t1',
      rev: '0001792610475963-0001-dev2',
      deleted: false,
      data: {
        'id': 't1',
        'type': 'text',
        'x': 0.0,
        'y': 0.0,
        'w': 100.0,
        'h': 40.0,
        'text': 'From the other device',
      },
    );
    const badMeta = SyncChange(
      collection: 'canvases',
      id: 'c1',
      rev: '0001792610475963-0002-dev2',
      deleted: false,
      data: {
        'title': 42, // not text
        'backgrounds': [
          {'at': 'x'},
        ],
      },
    );
    late Set<String> applied;
    expect(
      () => applied = applyCanvasChanges(
        state,
        'c1',
        [goodItem, badMeta],
        (_, _) => false,
      ),
      returnsNormally,
    );
    expect(applied, contains('canvas_items/c1/t1'));
    expect(applied, isNot(contains('canvases/c1')));
    expect(state.items.single.id, 't1');
    expect(state.title, 'Map', reason: 'the unreadable metadata is left alone');
  });
}
