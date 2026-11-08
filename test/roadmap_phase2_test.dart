// Roadmap Phase 2 (planning and organization): task fields, recurring
// exceptions, bulk shifting, dependencies, completion messages, task views,
// calendar views, filters, date preferences and calendar drawing.
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_ink.dart';
import 'package:flutter_application_1/features/calendar/calendar_views.dart';
import 'package:flutter_application_1/features/tasks/completion_messages.dart';
import 'package:flutter_application_1/features/tasks/task_views.dart';
import 'package:flutter_application_1/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';

import 'interaction_test.dart' show Harness;

Task task(
  String id, {
  DateTime? due,
  Recurrence recurrence = Recurrence.none,
  String? projectId,
  String? parentId,
  bool done = false,
}) => Task(
  id: id,
  title: id,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  dueDate: due,
  recurrence: recurrence,
  projectId: projectId,
  parentId: parentId,
  done: done,
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_r2_'));
  tearDown(() {
    DatePrefs.order = DateOrder.monthDay;
    DatePrefs.firstWeekday = DateTime.monday;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> app() async {
    final ws = Workspace(dir);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await s.init();
    return s;
  }

  group('task records', () {
    test('new fields round-trip; unused ones are not written', () {
      final t = task('a', due: DateTime(2026, 3, 10)).copyWith(
        labels: ['physics', 'lab'],
        properties: {'Effort': '3h'},
        dependsOn: ['b'],
        status: TaskStatus.doing,
        startDate: () => DateTime(2026, 3, 8),
      );
      final back = Task.fromJson(t.toJson());
      expect(back.labels, ['physics', 'lab']);
      expect(back.properties, {'Effort': '3h'});
      expect(back.dependsOn, ['b']);
      expect(back.status, TaskStatus.doing);
      expect(back.startDate, DateTime(2026, 3, 8));

      final plain = task('p').toJson();
      for (final key in [
        'labels',
        'properties',
        'dependsOn',
        'status',
        'startDate',
        'seriesDate',
      ]) {
        expect(plain.containsKey(key), isFalse, reason: key);
      }
      // Odd values never crash loading.
      final odd = Task.fromJson({
        'id': 'x',
        'title': 'x',
        'labels': 'nope',
        'properties': [1],
        'status': 'flying',
        'startDate': 'soon',
      });
      expect(odd.labels, isEmpty);
      expect(odd.status, TaskStatus.todo);
      expect(odd.startDate, isNull);
    });

    test(
      'recurring: skip or move one occurrence without changing the series',
      () {
        final monday = DateTime(2026, 3, 2);
        final weekly = task('w', due: monday, recurrence: Recurrence.weekly);

        final skipped = weekly.skippedOccurrence();
        expect(skipped.dueDate, DateTime(2026, 3, 9));
        expect(skipped.done, isFalse);
        expect(skipped.completedAt, isNull);

        final moved = weekly.movedOccurrence(DateTime(2026, 3, 4));
        expect(moved.dueDate, DateTime(2026, 3, 4));
        expect(moved.seriesDate, monday);
        // Completing the moved one continues the series from Monday.
        final next = moved.completed();
        expect(next.dueDate, DateTime(2026, 3, 9));
        expect(next.seriesDate, isNull);
        expect(Task.fromJson(moved.toJson()).seriesDate, monday);

        // Moving it back to its series date clears the exception.
        expect(moved.movedOccurrence(monday).seriesDate, isNull);
      },
    );

    test(
      'dragging a recurring task on the calendar moves one occurrence',
      () async {
        final s = await app();
        final monday = DateTime(2026, 3, 2);
        s.workspace.tasks.put(
          task('w', due: monday, recurrence: Recurrence.weekly),
        );
        s.workspace.moveDayItem(
          TaskOnDay(s.workspace.tasks['w']!, 0),
          monday,
          DateTime(2026, 3, 3),
        );
        final t = s.workspace.tasks['w']!;
        expect(t.dueDate, DateTime(2026, 3, 3));
        expect(t.completed().dueDate, DateTime(2026, 3, 9));
        // An undated task dragged from the task list onto a day.
        s.workspace.tasks.put(task('loose'));
        s.workspace.moveDayItem(
          TaskOnDay(s.workspace.tasks['loose']!, 0),
          null,
          DateTime(2026, 3, 5),
        );
        expect(s.workspace.tasks['loose']!.dueDate, DateTime(2026, 3, 5));
        expect(s.workspace.tasks.length, 2);
        await s.flush();
        s.dispose();
      },
    );

    test('bulk shifting keeps the gaps between dates', () async {
      final s = await app();
      final ws = s.workspace;
      ws.tasks.put(
        task(
          'a',
          due: DateTime(2026, 5, 1),
          projectId: 'p',
        ).copyWith(startDate: () => DateTime(2026, 4, 28)),
      );
      ws.tasks.put(task('b', due: DateTime(2026, 5, 4), projectId: 'p'));
      ws.tasks.put(task('sub', due: DateTime(2026, 5, 6), parentId: 'b'));
      ws.tasks.put(
        task('old', due: DateTime(2026, 4, 1), projectId: 'p', done: true),
      );
      ws.tasks.put(task('other', due: DateTime(2026, 5, 1)));

      expect(ws.shiftProject('p', 7), 3);
      expect(ws.tasks['a']!.dueDate, DateTime(2026, 5, 8));
      expect(ws.tasks['a']!.startDate, DateTime(2026, 5, 5));
      expect(ws.tasks['b']!.dueDate, DateTime(2026, 5, 11));
      expect(ws.tasks['sub']!.dueDate, DateTime(2026, 5, 13));
      expect(ws.tasks['old']!.dueDate, DateTime(2026, 4, 1)); // finished
      expect(ws.tasks['other']!.dueDate, DateTime(2026, 5, 1));

      expect(ws.shiftTasks(['a', 'other', 'missing'], -2), 2);
      expect(ws.tasks['other']!.dueDate, DateTime(2026, 4, 29));
      await s.flush();
      s.dispose();
    });

    test('dependencies warn but never block, and loops are refused', () async {
      final s = await app();
      final ws = s.workspace;
      ws.tasks.put(task('read'));
      ws.tasks.put(task('essay').copyWith(dependsOn: ['read', 'deleted-task']));
      expect(ws.openPrerequisites(ws.tasks['essay']!).map((t) => t.id), [
        'read',
      ]);
      expect(ws.canDependOn('read', 'essay'), isFalse); // loop
      expect(ws.canDependOn('essay', 'essay'), isFalse);
      expect(ws.canDependOn('essay', 'read'), isTrue);

      s.toggleTask('essay');
      expect(ws.tasks['essay']!.done, isTrue);
      expect(s.toast.value, contains('Still open before it: read'));

      s.toggleTask('read');
      expect(ws.openPrerequisites(ws.tasks['essay']!), isEmpty);
      await s.flush();
      s.dispose();
    });

    test('completion messages: understated, funny or silent', () async {
      final s = await app();
      expect(s.completionStyle, CompletionStyle.understated);
      s.workspace.tasks.put(task('a'));
      s.workspace.tasks.put(task('b'));
      await s.setCompletionStyle(CompletionStyle.silent);
      s.toggleTask('a');
      expect(s.workspace.tasks['a']!.done, isTrue);
      expect(s.toast.value, isNull);
      await s.setCompletionStyle(CompletionStyle.funny);
      s.toggleTask('b');
      expect(s.toast.value, isNotNull);
      expect(
        completionMessage(CompletionStyle.understated, random: Random(1)),
        isNotEmpty,
      );
      expect(completionMessage(CompletionStyle.silent), isNull);
      await s.flush();
      s.dispose();
    });
  });

  group('task views use the same records', () {
    test('board columns, table filtering/sorting and Gantt spans', () async {
      final s = await app();
      final ws = s.workspace;
      ws.tasks.put(
        task(
          'b-task',
          due: DateTime(2026, 6, 2),
        ).copyWith(labels: ['lab'], properties: {'Room': 'B12'}),
      );
      ws.tasks.put(task('a-task', due: DateTime(2026, 6, 1)));
      ws.tasks.put(task('c-task'));

      moveToColumn(s, ws.tasks['a-task']!, BoardColumn.doing);
      expect(ws.tasks['a-task']!.status, TaskStatus.doing);
      moveToColumn(s, ws.tasks['a-task']!, BoardColumn.done);
      expect(ws.tasks['a-task']!.done, isTrue);
      moveToColumn(s, ws.tasks['a-task']!, BoardColumn.todo);
      expect(boardColumnOf(ws.tasks['a-task']!), BoardColumn.todo);
      expect(ws.tasks.length, 3); // never a copy

      final all = ws.tasks.all.toList();
      expect(
        TaskTableView.arrange(
          s,
          all,
          column: TaskColumn.title,
        ).map((t) => t.id),
        ['a-task', 'b-task', 'c-task'],
      );
      expect(
        TaskTableView.arrange(s, all, column: TaskColumn.due).map((t) => t.id),
        ['a-task', 'b-task', 'c-task'], // undated last
      );
      expect(TaskTableView.arrange(s, all, query: 'b12').map((t) => t.id), [
        'b-task',
      ]);
      expect(TaskTableView.arrange(s, all, query: 'LAB').map((t) => t.id), [
        'b-task',
      ]);

      final span = ganttSpan(
        ws.tasks['b-task']!.copyWith(startDate: () => DateTime(2026, 5, 30)),
      )!;
      expect(span.start, DateTime(2026, 5, 30));
      expect(span.end, DateTime(2026, 6, 2));
      expect(ganttSpan(ws.tasks['c-task']!), isNull);
      await s.flush();
      s.dispose();
    });

    testWidgets('views switch, and multi-select shifts the picked tasks', (
      tester,
    ) async {
      final h = Harness(tester, dir);
      await h.boot();
      final ws = h.s.workspace;
      final today = dateOnly(DateTime.now());
      ws.tasks.put(task('Alpha', due: today));
      ws.tasks.put(task('Beta', due: addDays(today, 2)));
      await h.nav('Tasks');
      await h.settle();

      for (final v in [TaskView.board, TaskView.table, TaskView.gantt]) {
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('task-view-switcher')),
            matching: find.byIcon(v.icon),
          ),
        );
        await tester.pump();
        final key = switch (v) {
          TaskView.board => const ValueKey('board-todo'),
          TaskView.table => const ValueKey('task-table'),
          _ => const ValueKey('task-gantt'),
        };
        expect(find.byKey(key), findsOneWidget, reason: v.name);
      }
      expect(h.s.settings.get<String>('taskView'), 'gantt');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('task-view-switcher')),
          matching: find.byIcon(TaskView.list.icon),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('task-select-toggle')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pick-Alpha')));
      await tester.tap(find.byKey(const ValueKey('pick-Beta')));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bulk-shift')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '3');
      await tester.tap(find.text('Move'));
      await tester.pumpAndSettle();
      expect(ws.tasks['Alpha']!.dueDate, addDays(today, 3));
      expect(ws.tasks['Beta']!.dueDate, addDays(today, 5));
      await h.shutDown();
    });
  });

  group('calendar', () {
    test('category and color filters', () async {
      final s = await app();
      final ws = s.workspace;
      final day = DateTime(2026, 7, 1);
      ws.entries.put(
        CalendarEntry(
          id: 'e',
          category: CalendarCategory.events,
          name: 'Concert',
          createdAt: day,
          updatedAt: day,
          startDate: day,
        ),
      );
      ws.entries.put(
        CalendarEntry(
          id: 'o',
          category: CalendarCategory.other,
          name: 'Errand',
          createdAt: day,
          updatedAt: day,
          dates: {dayKey(day)},
        ),
      );
      ws.tasks.put(task('t', due: day));
      List<String> ids({
        Set<CalendarCategory>? categories,
        bool tasks = true,
      }) => [
        for (final i in ws.itemsOn(
          day,
          categories: categories,
          includeTasks: tasks,
        ))
          i.id,
      ]..sort();
      expect(ids(), ['e', 'o', 't']);
      expect(ids(categories: {CalendarCategory.other}), ['o', 't']);
      expect(ids(categories: {CalendarCategory.other}, tasks: false), ['o']);
      // One category filter (the colour-dot filter was the same dimension
      // and was merged into it); task cards are a separate switch.
      expect(ids(categories: {CalendarCategory.events}), ['e', 't']);
      expect(ids(categories: {CalendarCategory.events}, tasks: false), ['e']);
      expect(ids(categories: const {}, tasks: false), isEmpty);
      await s.flush();
      s.dispose();
    });

    test('month, week, agenda and timeline days follow the week start', () {
      final anchor = DateTime(2026, 10, 15); // a Thursday
      DatePrefs.firstWeekday = DateTime.monday;
      final month = CalendarView.month.daysAround(anchor);
      expect(month, hasLength(42));
      expect(month.first, DateTime(2026, 9, 28)); // Monday before Oct 1
      final week = CalendarView.week.daysAround(anchor);
      expect(week.first, DateTime(2026, 10, 12));
      expect(week.last, DateTime(2026, 10, 18));
      DatePrefs.firstWeekday = DateTime.sunday;
      expect(
        CalendarView.week.daysAround(anchor).first,
        DateTime(2026, 10, 11),
      );
      expect(
        CalendarView.month.daysAround(anchor).first,
        DateTime(2026, 9, 27),
      );
      expect(CalendarView.agenda.daysAround(anchor), hasLength(30));
      expect(
        CalendarView.month.step(anchor, forward: true),
        DateTime(2026, 11),
      );
      expect(
        CalendarView.week.step(anchor, forward: false),
        DateTime(2026, 10, 8),
      );
    });

    test('the timeline shows a multi-day event as one bar', () {
      final days = [for (var i = 0; i < 6; i++) DateTime(2026, 1, 1 + i)];
      final trip = CalendarEntry(
        id: 'trip',
        category: CalendarCategory.events,
        name: 'Trip',
        createdAt: days[0],
        updatedAt: days[0],
        startDate: days[1],
        endDate: days[3],
      );
      final lanes = CalendarTimelineView.lanes(
        days,
        (d) => [if (trip.occursOn(d)) EntryOnDay(trip)],
      );
      expect(lanes, hasLength(1));
      expect(lanes.single.$2, [(1, 3)]);
    });

    test(
      'date format and week start preferences are saved per device',
      () async {
        var s = await app();
        final d = DateTime(2026, 10, 21);
        expect(formatShortDate(d), 'Oct 21');
        await s.setDatePrefs(order: DateOrder.dayMonth, firstWeekday: 7);
        expect(formatShortDate(d), '21 Oct');
        expect(formatLongDate(d), 'Wednesday, 21 October');
        await s.flush();
        s.dispose();
        DatePrefs.order = DateOrder.monthDay;
        DatePrefs.firstWeekday = DateTime.monday;

        s = await app();
        expect(DatePrefs.order, DateOrder.dayMonth);
        expect(DatePrefs.firstWeekday, DateTime.sunday);
        DatePrefs.order = DateOrder.iso;
        expect(formatShortDate(d), '2026-10-21');
        await s.flush();
        s.dispose();
      },
    );

    test('calendar drawings belong to their date', () {
      final day = DateTime(2026, 10, 23);
      final rect = inkDayRect(day);
      expect(rect.size, inkDaySize);
      expect(inkDayAt(rect.center), day);
      expect(inkDayAt(rect.topLeft), day);
      expect(inkDayAt(rect.topRight - const Offset(0.01, 0)), day);
      expect(inkDayAt(rect.topRight), addDays(day, 1));
      expect(isCalendarInkId(calendarInkId), isTrue);
    });

    testWidgets(
      'Draw mode draws on a day and keeps it; otherwise taps select',
      (tester) async {
        final h = Harness(tester, dir);
        await h.boot();
        await h.nav('calendar');
        await h.settle();
        final start = h.s.calendarStart;
        final day = addDays(start, 2);
        final cell = find.byKey(ValueKey('ink-${dayKey(day)}'));
        expect(cell, findsOneWidget);

        // Not drawing: the ink layer lets taps through to the date.
        await tester.tap(
          cell,
          kind: PointerDeviceKind.mouse,
          warnIfMissed: false,
        );
        await tester.pump();
        expect(h.s.calendarInk!.items, isEmpty);

        await tester.tap(find.byKey(const ValueKey('calendar-draw')));
        await tester.pump();
        final centre = tester.getCenter(cell);
        final g = await tester.startGesture(
          centre,
          kind: PointerDeviceKind.mouse,
        );
        for (var i = 1; i <= 6; i++) {
          await g.moveTo(centre + Offset(i * 6.0, i * 4.0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await g.up();
        await tester.pump();
        final strokes = h.s.calendarInk!.items.whereType<StrokeItem>().toList();
        expect(strokes, hasLength(1));
        expect(inkDayAt(strokes.single.bounds.center), day);

        await h.restart();
        await h.nav('calendar');
        await h.settle();
        final ink = h.s.calendarInk;
        expect(ink!.items.whereType<StrokeItem>(), hasLength(1));
        // Not a canvas: it is not listed with the mindmaps.
        expect(h.s.canvasList.any((c) => c.id == calendarInkId), isFalse);
        await h.shutDown();
      },
    );
  });
}
