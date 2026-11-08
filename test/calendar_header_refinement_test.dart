// UI refinement phase 1 (Calendar): one source of truth for category
// visibility (the Filter menu; the old colour dots are gone), "Show tasks"
// (task cards) kept apart from the "Tasks panel", every view and category
// page still reachable, and the day panel's contextual actions.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/calendar_sync_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_page.dart';
import 'package:flutter_application_1/features/calendar/calendar_views.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

void main() {
  late Directory dir;
  late AppState s;
  late DateTime day;

  Future<void> boot(
    WidgetTester tester, {
    Size size = const Size(1600, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    dir = Directory.systemTemp.createTempSync('theapp_cal_refine_');
    final ws = Workspace(dir);
    s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await tester.runAsync(s.init);
    s.setCalendarTasksOpen(false);
    day = s.calendarStart;
    final now = DateTime.now();
    ws.entries.put(
      CalendarEntry(
        id: 'event',
        category: CalendarCategory.events,
        name: 'Concert',
        createdAt: now,
        updatedAt: now,
        startDate: day,
        endDate: day,
      ),
    );
    ws.entries.put(
      CalendarEntry(
        id: 'other',
        category: CalendarCategory.other,
        name: 'Errand',
        createdAt: now,
        updatedAt: now,
        dates: {dayKey(day)},
      ),
    );
    ws.createTask('Essay', dueDate: day);
    ws.externalEvents.put(
      ExternalEvent(
        id: 'x1',
        provider: 'google',
        calendarId: 'c',
        remoteId: 'r',
        title: 'Dentist',
        start: day.add(const Duration(hours: 9)),
        end: day.add(const Duration(hours: 10)),
        updatedAt: now,
      ),
    );
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          // The app shell rebuilds the page when the Tasks panel opens.
          body: ListenableBuilder(
            listenable: s,
            builder: (_, _) => CalendarPage(state: s),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await waitForBothClocks(tester, s.flush, what: 'Saving');
    await tester.pump(const Duration(seconds: 4));
    s.dispose();
    s.workspace.dispose(); // also cancels the archive-purge timer
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The ids shown in the grid cell of [day].
  List<String> cellIds(WidgetTester tester) {
    final cell = tester.widget<DayCell>(
      find.descendant(
        of: find.byKey(ValueKey('calendar-cell-${dayKey(day)}')),
        matching: find.byType(DayCell),
      ),
    );
    return [for (final i in cell.items) i.id]..sort();
  }

  String taskId() => s.workspace.tasks.all.single.id;

  testWidgets('header: Quick Add, Tasks panel and Archive; no colour dots', (
    tester,
  ) async {
    await boot(tester);
    await show(tester);
    expect(find.text('Quick Add'), findsOneWidget);
    expect(find.text('Tasks panel'), findsOneWidget);
    expect(find.textContaining('Archive'), findsWidgets);
    // The duplicate colour-dot filter is gone; one Filter trigger remains.
    expect(find.byTooltip('All colours'), findsNothing);
    expect(find.byKey(const ValueKey('calendar-filter')), findsOneWidget);
    expect(find.text('Show'), findsNothing);
    // Every view and every category page is still there.
    for (final v in CalendarView.values) {
      expect(find.text(v.label), findsWidgets, reason: v.label);
    }
    expect(find.text('${s.calendarDays}-Day Grid'), findsOneWidget);
    for (final c in CalendarCategory.values) {
      expect(find.text(c.label), findsWidgets, reason: c.label);
    }
    await finish(tester);
  });

  testWidgets('one filter drives every category; task cards are separate', (
    tester,
  ) async {
    await boot(tester);
    await show(tester);
    final all = ['event', 'other', 'x1', taskId()]..sort();
    expect(cellIds(tester), all);

    // (CheckboxMenuButton passes its key on to its inner button, so each
    // key matches twice: the first match is the checkbox row.)
    Finder row(String name) =>
        find.byKey(ValueKey('calendar-filter-$name')).first;
    await tester.tap(find.byKey(const ValueKey('calendar-filter')));
    await settle(tester);
    for (final c in CalendarCategory.values) {
      expect(row(c.name), findsOneWidget);
    }
    expect(find.text('Show tasks'), findsOneWidget);

    // Events off: the event and the external (Google) event go, tasks stay.
    await tester.tap(row('events'));
    await settle(tester);
    expect(cellIds(tester), ['other', taskId()]..sort());
    // The menu stays open while several switches are changed.
    expect(row('other'), findsOneWidget);
    expect(find.text('Filter · 1 hidden'), findsOneWidget);

    // Task cards off: tasks go; the Tasks panel is not touched.
    await tester.tap(row('tasks'));
    await settle(tester);
    expect(cellIds(tester), ['other']);
    expect(s.calendarTasksOpen, isFalse);
    expect(find.text('Filter · 2 hidden'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('calendar-filter-all')));
    await settle(tester);
    expect(cellIds(tester), all);
    expect(find.text('Filter'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the Tasks panel opens and closes without changing task cards', (
    tester,
  ) async {
    await boot(tester);
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-tasks-toggle')));
    await settle(tester);
    expect(s.calendarTasksOpen, isTrue);
    expect(find.byKey(const ValueKey('calendar-tasks')), findsOneWidget);
    expect(cellIds(tester), contains(taskId()), reason: 'cards unchanged');
    await tester.tap(find.byKey(const ValueKey('calendar-tasks-toggle')));
    await settle(tester);
    expect(s.calendarTasksOpen, isFalse);
    await finish(tester);
  });

  testWidgets('category pages and other views still work', (tester) async {
    await boot(tester);
    await show(tester);
    await tester.tap(find.text('Events').first);
    await settle(tester);
    expect(find.byType(CategoryView), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-filter')), findsNothing);
    await tester.tap(find.text('${s.calendarDays}-Day Grid'));
    await settle(tester);
    for (final v in [
      CalendarView.month,
      CalendarView.week,
      CalendarView.day,
      CalendarView.agenda,
      CalendarView.timeline,
      CalendarView.range,
    ]) {
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('calendar-view-switcher')),
          matching: find.text(v.label),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull, reason: v.label);
      if (v != CalendarView.range) {
        expect(find.text('Today'), findsOneWidget, reason: v.label);
      }
    }
    await finish(tester);
  });

  testWidgets('a selected day offers entry, task and reminder; an entry '
      'offers edit, duplicate and archive', (tester) async {
    await boot(tester);
    await show(tester);
    await tester.tap(find.byKey(ValueKey('calendar-cell-${dayKey(day)}')));
    await settle(tester);
    expect(find.byType(DayPanel), findsOneWidget);
    expect(find.text('Concert'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('day-add-reminder')));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'Call mum');
    await tester.tap(find.text('Add'));
    await settle(tester);
    final reminder = s.workspace.tasks.all.firstWhere(
      (t) => t.title == 'Call mum',
    );
    expect(dayKey(reminder.dueDate!), dayKey(day));
    expect(reminder.remindBefore, 0);

    await tester.tap(find.byKey(const ValueKey('day-add-task')));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'Buy paper');
    await tester.tap(find.text('Add'));
    await settle(tester);
    final task = s.workspace.tasks.all.firstWhere(
      (t) => t.title == 'Buy paper',
    );
    expect(task.remindBefore, isNull);

    await tester.tap(find.byKey(const ValueKey('entry-more-event')));
    await settle(tester);
    await tester.tap(find.text('Duplicate'));
    await settle(tester);
    final copies = s.workspace.entries.all.where(
      (e) => e.name == 'Concert (copy)',
    );
    expect(copies, hasLength(1));
    expect(copies.single.id, isNot('event'));
    expect(copies.single.category, CalendarCategory.events);

    await tester.tap(find.byKey(const ValueKey('entry-more-event')));
    await settle(tester);
    await tester.tap(find.text('Archive').last);
    await settle(tester);
    expect(s.workspace.entries['event']!.archived, isTrue);

    // Change category: the Other entry moves to Habits, keeps its id and
    // stays on this day.
    await tester.tap(find.byKey(const ValueKey('entry-more-other')));
    await settle(tester);
    expect(find.byKey(const ValueKey('entry-move-reading')), findsNothing);
    expect(find.byKey(const ValueKey('entry-move-other')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('entry-move-habits')));
    await settle(tester);
    final moved = s.workspace.entries['other']!;
    expect(moved.category, CalendarCategory.habits);
    expect(moved.colorIndex, CalendarCategory.habits.index);
    expect(moved.occursOn(day), isTrue);
    await tester.pump(const Duration(seconds: 4)); // toasts
    await finish(tester);
  });

  test('change category keeps the entry on the day; Reading and full '
      'categories are refused', () async {
    final dir = Directory.systemTemp.createTempSync('theapp_cal_move_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final ws = Workspace(dir);
    await ws.load();
    addTearDown(ws.dispose);
    final d = DateTime(2026, 11, 10);
    final now = DateTime.now();
    CalendarEntry entry(String id, CalendarCategory c) => CalendarEntry(
      id: id,
      category: c,
      name: id,
      createdAt: now,
      updatedAt: now,
      startDate: c == CalendarCategory.other ? null : d,
      endDate: c == CalendarCategory.events ? d : null,
      dates: c == CalendarCategory.other ? {dayKey(d)} : const {},
      startMinutes: 9 * 60,
      checkoffs: {dayKey(d)},
    );
    ws.entries.put(entry('o', CalendarCategory.other));
    ws.entries.put(entry('r', CalendarCategory.reading));

    // Other → Events → Habits → Other: always on [d], same id, details kept.
    for (final to in [
      CalendarCategory.events,
      CalendarCategory.habits,
      CalendarCategory.other,
    ]) {
      expect(ws.changeEntryCategory('o', to, d), isTrue, reason: to.label);
      final e = ws.entries['o']!;
      expect(e.category, to);
      expect(e.occursOn(d), isTrue, reason: to.label);
      expect(e.startMinutes, 9 * 60);
      expect(e.isCheckedOn(d), isTrue);
    }
    expect(ws.entries.all.where((e) => e.name == 'o'), hasLength(1));

    // Reading has pages, logs and plans: never moved either way.
    expect(ws.changeEntryCategory('r', CalendarCategory.events, d), isFalse);
    expect(ws.changeEntryCategory('o', CalendarCategory.reading, d), isFalse);
    expect(ws.entries['r']!.category, CalendarCategory.reading);

    // The five-active rule: a full category accepts no move.
    for (var i = 0; i < CalendarEntry.maxActivePerCategory; i++) {
      ws.entries.put(entry('h$i', CalendarCategory.habits));
    }
    expect(ws.canChangeEntryCategory('o', CalendarCategory.habits), isFalse);
    expect(ws.changeEntryCategory('o', CalendarCategory.habits, d), isFalse);
    expect(ws.entries['o']!.category, CalendarCategory.other);
    await ws.flush();
  });

  for (final (name, size) in [
    ('Windows desktop', const Size(1600, 1000)),
    ('narrow window', const Size(700, 900)),
    ('iPad', const Size(1180, 820)),
    ('iPhone', const Size(390, 844)),
  ]) {
    testWidgets('header and filter lay out without overflow: $name', (
      tester,
    ) async {
      await boot(tester, size: size);
      await show(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('calendar-filter')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  }
}
