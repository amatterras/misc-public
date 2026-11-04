// New interface, iPhone: Home and the five-item bottom navigation. Home
// exists only on a phone; Windows and iPad never show it. Everything is
// driven through the existing Calendar/Task data and actions.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/interface_version.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/platform/device_idiom.dart';
import 'package:flutter_application_1/new_ui/home_agenda.dart';
import 'package:flutter_application_1/new_ui/new_home.dart';
import 'package:flutter_application_1/new_ui/new_sidebar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_home_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final today = dateOnly(DateTime.now());

  CalendarEntry entry(
    CalendarCategory category,
    String name, {
    int? minutes,
    int? duration,
    DateTime? day,
  }) {
    final now = DateTime.now();
    final d = day ?? today;
    return CalendarEntry(
      id: newId(),
      category: category,
      name: name,
      createdAt: now,
      updatedAt: now,
      startDate:
          category == CalendarCategory.events ||
              category == CalendarCategory.habits
          ? d
          : null,
      endDate: category == CalendarCategory.events ? d : null,
      dates: category == CalendarCategory.other ? {dayKey(d)} : const {},
      startMinutes: minutes,
      durationMinutes: duration,
    );
  }

  group('HomeAgenda', () {
    late Workspace ws;
    setUp(() => ws = Workspace(dir));

    test('sorts the day into overdue, all day, timeline and unscheduled', () {
      ws.saveEntry(
        entry(
          CalendarCategory.events,
          'Standup',
          minutes: 9 * 60,
          duration: 30,
        ),
      );
      ws.saveEntry(entry(CalendarCategory.habits, 'Stretch', minutes: 7 * 60));
      ws.saveEntry(entry(CalendarCategory.other, 'Call mum'));
      final timedTask = ws.createTask('Pay rent', dueDate: today);
      ws.tasks.put(timedTask.copyWith(dueMinutes: () => 14 * 60));
      ws.createTask('Water plants', dueDate: today);
      ws.createTask('Late report', dueDate: addDays(today, -2));
      ws.createTask('Someday');

      final noon = today.add(const Duration(hours: 12));
      final a = HomeAgenda.build(ws, today, now: noon);

      expect(a.overdue.map((i) => i.title), ['Late report']);
      expect(a.allDay.map((i) => i.title), ['Call mum']);
      expect(a.hours, [7, 9, 14]);
      expect(a.timed[9]!.single.timeLabel, '09:00–09:30');
      expect(a.timed[7]!.single.kind, HomeKind.habit);
      expect(
        a.unscheduled.map((i) => i.title),
        containsAll(['Water plants', 'Someday']),
      );
      // Empty hours are not part of the timeline at all.
      expect(a.timed.containsKey(10), isFalse);
      // Upcoming events: Standup (09:00) is already behind us at noon.
      expect(a.upcomingEvents, 0);
      expect(
        HomeAgenda.build(
          ws,
          today,
          now: today.add(const Duration(hours: 8)),
        ).upcomingEvents,
        1,
      );
    });

    test('overdue and undated tasks only belong to today', () {
      ws.createTask('Late report', dueDate: addDays(today, -2));
      ws.createTask('Someday');
      final tomorrow = HomeAgenda.build(ws, addDays(today, 1));
      expect(tomorrow.overdue, isEmpty);
      expect(tomorrow.unscheduled, isEmpty);
      expect(tomorrow.total, 0);
    });

    test('progress counts finished and open items of the day', () {
      final a = ws.createTask('A', dueDate: today);
      ws.createTask('B', dueDate: today);
      ws.toggleTask(a.id);
      ws.createTask('Backlog'); // undated: not part of today's progress
      final r = HomeAgenda.build(ws, today);
      expect(r.completed, 1);
      expect(r.remaining, 1);
      expect(r.progress, closeTo(0.5, 1e-9));
    });

    test('date markers use the existing Calendar colours', () {
      ws.saveEntry(entry(CalendarCategory.habits, 'Stretch', minutes: 7 * 60));
      ws.saveEntry(entry(CalendarCategory.other, 'Call mum'));
      final marks = HomeAgenda.markers(ws, today);
      expect(marks, contains(HomeKind.habit.color));
      expect(marks, contains(HomeKind.reminder.color));
      expect(marks.length, lessThanOrEqualTo(4));
    });
  });

  Future<AppState> boot(
    WidgetTester tester, {
    required Size size,
    InterfaceVersion version = InterfaceVersion.newDesign,
    bool ios = false,
    bool phone = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (ios) {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      DeviceIdiom.debugIsPhone = phone;
    }
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
    await tester.runAsync(state.init);
    await tester.runAsync(() => state.setInterfaceVersion(version));
    return state;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
    debugDefaultTargetPlatformOverride = null;
    DeviceIdiom.debugIsPhone = null;
  }

  testWidgets('iPhone: opens on Home with five icon-only destinations', (
    tester,
  ) async {
    final state = await boot(tester, size: const Size(390, 844), ios: true);
    final ws = state.workspace;
    final t = ws.createTask('Pay rent', dueDate: today);
    ws.createTask('Late report', dueDate: addDays(today, -1));
    ws.saveEntry(entry(CalendarCategory.other, 'Call mum'));

    await tester.pumpWidget(TheApp(state: state));
    await settle(tester);

    expect(find.byType(NewHome), findsOneWidget);
    expect(find.byType(NewSidebar), findsNothing);
    for (final k in const [
      'phone-nav-home',
      'phone-nav-canvas',
      'phone-nav-notes',
      'phone-nav-calendar',
      'phone-nav-links',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    // Icons only: no permanent labels in the bar.
    expect(find.text('mindmap'), findsNothing);

    // Today's data comes from the existing records.
    expect(find.byKey(ValueKey('home-card-${t.id}')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-section-overdue')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-section-unscheduled')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('home-summary')), findsOneWidget);

    // Completing uses the existing task toggle, and the data really changes.
    expect(ws.tasks[t.id]!.done, isFalse);
    await tester.tap(find.byKey(ValueKey('home-toggle-${t.id}')));
    await settle(tester);
    expect(ws.tasks[t.id]!.done, isTrue);

    // Other destinations leave Home; Home comes back from its icon.
    await tester.tap(find.byKey(const ValueKey('phone-nav-notes')));
    await settle(tester);
    expect(state.page, AppPage.notes);
    expect(find.byType(NewHome), findsNothing);
    await tester.tap(find.byKey(const ValueKey('phone-nav-home')));
    await settle(tester);
    expect(find.byType(NewHome), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('iPhone Home: date strip, swiping weeks and the month grid', (
    tester,
  ) async {
    final state = await boot(tester, size: const Size(390, 844), ios: true);
    final tomorrow = addDays(today, 1);
    final later = state.workspace.createTask('Tomorrow job', dueDate: tomorrow);
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester);

    expect(find.byKey(ValueKey('home-card-${later.id}')), findsNothing);
    // Tapping a date changes the day shown (when it is in this week).
    final target = weekContains(today, tomorrow)
        ? tomorrow
        : addDays(today, -1);
    await tester.tap(find.byKey(ValueKey('home-date-${dayKey(target)}')));
    await settle(tester);
    if (target == tomorrow) {
      expect(find.byKey(ValueKey('home-card-${later.id}')), findsOneWidget);
    }

    // Swiping the strip shows the next week.
    await tester.drag(
      find.byKey(const ValueKey('home-week-strip')),
      const Offset(-380, 0),
    );
    await settle(tester);
    final inNextWeek = addDays(today, 7);
    expect(
      find.byKey(ValueKey('home-date-${dayKey(inNextWeek)}')),
      findsWidgets,
    );

    // The month name opens the whole month; choosing a day closes it again.
    await tester.tap(find.byKey(const ValueKey('home-month-label')));
    await settle(tester);
    expect(find.byKey(const ValueKey('home-month-grid')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-month-label')));
    await settle(tester);
    expect(find.byKey(const ValueKey('home-month-grid')), findsNothing);
    await close(tester, state);
  });

  testWidgets('iPhone Home: long-press menu and Quick Add reuse the actions', (
    tester,
  ) async {
    final state = await boot(tester, size: const Size(390, 844), ios: true);
    final ws = state.workspace;
    final t = ws.createTask('Pay rent', dueDate: today);
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester);

    await tester.longPress(find.byKey(ValueKey('home-card-${t.id}')));
    await settle(tester);
    for (final k in const ['edit', 'duplicate', 'move', 'delete']) {
      expect(find.byKey(ValueKey('home-menu-$k')), findsOneWidget, reason: k);
    }
    await tester.tap(find.byKey(const ValueKey('home-menu-duplicate')));
    await settle(tester);
    final titles = [for (final x in ws.tasks.all) x.title];
    expect(titles, containsAll(['Pay rent', 'Pay rent (copy)']));

    await tester.tap(find.byKey(const ValueKey('home-quick-add')));
    await settle(tester);
    for (final k in const ['task', 'event', 'habit', 'reminder']) {
      expect(find.byKey(ValueKey('home-menu-$k')), findsOneWidget, reason: k);
    }
    await tester.tapAt(const Offset(190, 60)); // dismiss the sheet
    await settle(tester);
    await close(tester, state);
  });

  testWidgets('Windows and iPad never show Home', (tester) async {
    for (final size in const [Size(1280, 800), Size(820, 1180)]) {
      final state = await boot(tester, size: size);
      await tester.pumpWidget(TheApp(state: state));
      await settle(tester);
      expect(find.byType(NewHome), findsNothing);
      expect(find.byKey(const ValueKey('phone-nav-home')), findsNothing);
      expect(find.byType(NewSidebar), findsOneWidget);
      await close(tester, state);
      dir.deleteSync(recursive: true);
      dir = Directory.systemTemp.createTempSync('theapp_home_');
    }
  });

  testWidgets('iPad keeps the iPad layout at every width, never Home', (
    tester,
  ) async {
    // Full screen, landscape, portrait, a narrow Split View window and a
    // Slide Over window (320 pt).
    for (final size in const [
      Size(1180, 820),
      Size(820, 1180),
      Size(507, 1000),
      Size(320, 900),
    ]) {
      final state = await boot(tester, size: size, ios: true, phone: false);
      await tester.pumpWidget(TheApp(state: state));
      await settle(tester);
      expect(find.byType(NewHome), findsNothing, reason: '$size');
      expect(find.byKey(const ValueKey('phone-nav-home')), findsNothing);
      if (size.width >= 640) {
        expect(find.byType(NewSidebar), findsOneWidget, reason: '$size');
      } else {
        // Narrow window: pages keep the full width; a handle opens the
        // compact capsule over them.
        expect(find.byType(NewSidebar), findsNothing, reason: '$size');
        await tester.tap(find.byKey(const ValueKey('new-sidebar-show')));
        await settle(tester);
        expect(find.byType(NewSidebar), findsOneWidget, reason: '$size');
      }
      expect(tester.takeException(), isNull, reason: '$size');
      await close(tester, state);
      dir.deleteSync(recursive: true);
      dir = Directory.systemTemp.createTempSync('theapp_home_');
    }
  });

  testWidgets('narrow iPad windows use the compact capsule', (tester) async {
    final state = await boot(
      tester,
      size: const Size(320, 900),
      ios: true,
      phone: false,
    );
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('new-sidebar-show')));
    await settle(tester);
    // Icons only: no expand toggle, expanded mode ignored.
    await tester.runAsync(() async => state.toggleNewSidebarExpanded());
    await settle(tester);
    expect(state.newSidebarExpanded, isTrue);
    expect(find.byKey(const ValueKey('new-nav-expand')), findsNothing);
    expect(find.text('notes'), findsNothing);
    // Picking a destination closes the floating capsule again.
    await tester.tap(find.byKey(const ValueKey('new-nav-calendar')));
    await settle(tester);
    expect(state.page, AppPage.calendar);
    expect(find.byType(NewSidebar), findsNothing);
    await tester.tap(find.byKey(const ValueKey('new-sidebar-show')));
    await settle(tester);
    // The essentials stay reachable.
    for (final k in const [
      'new-nav-notes',
      'new-nav-settings',
      'new-nav-hide',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    await close(tester, state);
  });

  testWidgets('an iPhone always gets Home, also in landscape', (tester) async {
    final state = await boot(tester, size: const Size(844, 390), ios: true);
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester);
    expect(find.byType(NewHome), findsOneWidget);
    expect(find.byType(NewSidebar), findsNothing);
    await close(tester, state);
  });

  testWidgets('Original on an iPhone has no Home', (tester) async {
    final state = await boot(
      tester,
      size: const Size(390, 844),
      ios: true,
      version: InterfaceVersion.original,
    );
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester);
    expect(find.byType(NewHome), findsNothing);
    expect(find.byKey(const ValueKey('phone-nav-home')), findsNothing);
    await close(tester, state);
  });
}

bool weekContains(DateTime week, DateTime day) {
  final start = week.subtract(
    Duration(days: (week.weekday - DateTime.monday) % 7),
  );
  final d = dateOnly(day);
  return !d.isBefore(dateOnly(start)) &&
      d.isBefore(dateOnly(start).add(const Duration(days: 7)));
}
