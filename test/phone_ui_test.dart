// The iPhone interface (lib/phone): which devices get it, how it navigates,
// that it uses the same data and actions as the other interfaces, that it
// lays out at every iPhone size in both themes, and that Windows and iPad are
// left exactly as they were.
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
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/new_ui/home_agenda.dart';
import 'package:flutter_application_1/new_ui/new_sidebar.dart';
import 'package:flutter_application_1/phone/phone_archive.dart';
import 'package:flutter_application_1/phone/phone_profile.dart';
import 'package:flutter_application_1/phone/phone_shell.dart';
import 'package:flutter_application_1/phone/phone_widgets.dart';
import 'package:flutter_application_1/platform/device_idiom.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_phone_'));
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

  // ── harness ──────────────────────────────────────────────────────────

  Future<AppState> boot(
    WidgetTester tester, {
    required Size size,
    InterfaceVersion version = InterfaceVersion.newDesign,
    bool ios = false,
    bool? phone,
    bool forced = false,
    String theme = 'dark',
    bool seed = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (ios) debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    DeviceIdiom.debugIsPhone = phone;
    PhoneProfile.forced = forced;
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
    await tester.runAsync(() async {
      await state.init();
      await state.setInterfaceVersion(version);
      await state.setThemeMode(theme);
      if (seed) {
        ws.createTask('Pay rent', dueDate: today);
        ws.createTask('Late report', dueDate: addDays(today, -2));
        ws.createTask('Someday');
        ws.saveEntry(entry(CalendarCategory.other, 'Call mum'));
        ws.createNote(title: 'Groceries', body: 'Lemons and bread');
        ws.createNote(title: 'Ideas', body: 'A plant app');
        await state.library.createSpace('Lisbon trip');
      }
    });
    return state;
  }

  Future<void> settle(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
    debugDefaultTargetPlatformOverride = null;
    DeviceIdiom.debugIsPhone = null;
    PhoneProfile.forced = false;
  }

  Future<void> open(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester, 12);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  const iphone = Size(390, 844);

  // ── who gets the iPhone interface ────────────────────────────────────

  testWidgets('an iPhone gets the phone interface, on Today first', (
    tester,
  ) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    expect(find.byType(PhoneShell), findsOneWidget);
    expect(find.byType(NewSidebar), findsNothing);
    expect(state.homeActive, isTrue);
    for (final k in const ['today', 'notes', 'calendar', 'archive', 'map']) {
      expect(find.byKey(ValueKey('phone-tab-$k')), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('phone-new')), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('an iPhone always gets it, also in landscape and on Original', (
    tester,
  ) async {
    for (final (size, version) in const [
      (Size(844, 390), InterfaceVersion.newDesign),
      (Size(390, 844), InterfaceVersion.original),
    ]) {
      final state = await boot(
        tester,
        size: size,
        ios: true,
        phone: true,
        version: version,
        seed: false,
      );
      await open(tester, state);
      expect(find.byType(PhoneShell), findsOneWidget, reason: '$size $version');
      // The stored choice of this device is left alone; the phone just does
      // not use it.
      expect(state.interfaceVersion, InterfaceVersion.newDesign);
      expect(
        InterfaceVersion.fromStored(
          state.settings.get<String>(InterfaceVersion.settingsKey),
        ),
        version,
      );
      await close(tester, state);
      dir.deleteSync(recursive: true);
      dir = Directory.systemTemp.createTempSync('theapp_phone_');
    }
  });

  testWidgets('the iPhone build is the phone interface on any device', (
    tester,
  ) async {
    final state = await boot(tester, size: iphone, forced: true, seed: false);
    await open(tester, state);
    expect(find.byType(PhoneShell), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('Windows and iPad never get it, at any width', (tester) async {
    for (final (size, ios, phone) in const [
      (Size(1280, 800), false, null),
      (Size(820, 1180), true, false),
      (Size(507, 1000), true, false),
      (Size(320, 900), true, false), // Slide Over
    ]) {
      final state = await boot(
        tester,
        size: size,
        ios: ios,
        phone: phone,
        seed: false,
      );
      await open(tester, state);
      expect(find.byType(PhoneShell), findsNothing, reason: '$size');
      expect(find.byKey(const ValueKey('phone-tab-today')), findsNothing);
      expect(state.homeActive, isFalse);
      await close(tester, state);
      dir.deleteSync(recursive: true);
      dir = Directory.systemTemp.createTempSync('theapp_phone_');
    }
  });

  testWidgets('Original on Windows and iPad is untouched', (tester) async {
    for (final (size, ios, phone) in const [
      (Size(1280, 800), false, null),
      (Size(820, 1180), true, false),
    ]) {
      final state = await boot(
        tester,
        size: size,
        ios: ios,
        phone: phone,
        version: InterfaceVersion.original,
        seed: false,
      );
      await open(tester, state);
      expect(find.byType(PhoneShell), findsNothing);
      expect(state.interfaceVersion, InterfaceVersion.original);
      await close(tester, state);
      dir.deleteSync(recursive: true);
      dir = Directory.systemTemp.createTempSync('theapp_phone_');
    }
  });

  // ── Today ────────────────────────────────────────────────────────────

  testWidgets('Today shows the day and ticking uses the existing action', (
    tester,
  ) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    expect(find.text('Pay rent'), findsOneWidget);
    expect(find.text('Late report'), findsOneWidget); // overdue
    expect(state.workspace.tasks.all.where((t) => t.done), isEmpty);
    await tester.tap(find.byType(TickRing).first);
    await settle(tester);
    expect(
      state.workspace.tasks.all.where((t) => t.done).length,
      1,
      reason: 'one task is now done in the shared data',
    );
    await close(tester, state);
  });

  testWidgets('a task opens on its own page with Back', (tester) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    await tester.tap(find.text('Pay rent'));
    await settle(tester, 12);
    expect(find.text('TASK'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
    await settle(tester, 12);
    expect(find.byKey(const ValueKey('phone-tab-today')), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('something asking to open a task opens the phone task page', (
    tester,
  ) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    final id = state.workspace.tasks.all.first.id;
    state.openTask(id);
    await settle(tester, 14);
    expect(state.selectedTaskId, isNull);
    expect(find.text('TASK'), findsOneWidget);
    await close(tester, state);
  });

  // ── navigation and creating ──────────────────────────────────────────

  testWidgets('the dock moves between places', (tester) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    await tapKey(tester, 'phone-tab-notes');
    expect(state.page, AppPage.notes);
    expect(state.homeActive, isFalse);
    expect(find.text('Groceries'), findsOneWidget);
    await tapKey(tester, 'phone-tab-calendar');
    expect(state.page, AppPage.calendar);
    await tapKey(tester, 'phone-tab-archive');
    expect(state.page, AppPage.links);
    expect(find.text('Lisbon trip'), findsOneWidget);
    await tapKey(tester, 'phone-tab-today');
    expect(state.homeActive, isTrue);
    await close(tester, state);
  });

  testWidgets('a note opens on its own page', (tester) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    await tapKey(tester, 'phone-tab-notes');
    await tester.tap(find.text('Groceries'));
    await settle(tester, 14);
    expect(find.byType(NotePage), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('something asking to open a note opens its page', (tester) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    final id = state.workspace.notes.all.first.id;
    state.openNote(id);
    await settle(tester, 14);
    expect(find.byType(NotePage), findsOneWidget);
    expect(state.selectedNoteId, isNull);
    await close(tester, state);
  });

  testWidgets('notes search narrows the list', (tester) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    await tapKey(tester, 'phone-tab-notes');
    await tester.enterText(
      find.byKey(const ValueKey('phone-notes-search')),
      'plant',
    );
    await settle(tester);
    expect(find.text('Ideas'), findsOneWidget);
    expect(find.text('Groceries'), findsNothing);
    await close(tester, state);
  });

  testWidgets('the + lists what can be made; Note creates one and opens it', (
    tester,
  ) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    final before = state.workspace.notes.length;
    await tapKey(tester, 'phone-new');
    for (final w in const [
      'Task',
      'Note',
      'Event',
      'Link or photo',
      'Habit',
      'Reading',
      'Reminder',
      'Mindmap',
    ]) {
      expect(find.text(w), findsWidgets, reason: w);
    }
    await tester.tap(find.widgetWithText(SheetItem, 'Note'));
    await settle(tester, 14);
    expect(state.workspace.notes.length, before + 1);
    expect(find.byType(NotePage), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('Calendar: a month, a chosen day, and the Tasks tab', (
    tester,
  ) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    await tapKey(tester, 'phone-tab-calendar');
    expect(find.text('Call mum'), findsOneWidget);
    await tester.tap(find.text('Tasks'));
    await settle(tester);
    expect(find.text('Pay rent'), findsOneWidget);
    expect(find.text('Someday'), findsOneWidget);
    expect(find.text('Late report'), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('Archive: folders as an index, a folder opens as a list', (
    tester,
  ) async {
    final state = await boot(tester, size: iphone, ios: true, phone: true);
    await open(tester, state);
    await tapKey(tester, 'phone-tab-archive');
    await tester.tap(find.text('Lisbon trip'));
    await settle(tester, 12);
    expect(find.byType(PhoneFolderPage), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('AI takes the screen with a Back arrow', (tester) async {
    final state = await boot(
      tester,
      size: iphone,
      ios: true,
      phone: true,
      seed: false,
    );
    await open(tester, state);
    await tapKey(tester, 'phone-more');
    await tester.tap(find.text('AI'));
    await settle(tester, 12);
    expect(state.page, AppPage.ai);
    expect(find.byKey(const ValueKey('phone-tool-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-new')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('phone-tool-back')));
    await settle(tester, 12);
    // Back returns to where the tool was opened from (Today).
    expect(state.homeActive, isTrue);
    expect(find.byKey(const ValueKey('phone-new')), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('Settings on the phone has no interface switch', (tester) async {
    final state = await boot(
      tester,
      size: iphone,
      ios: true,
      phone: true,
      seed: false,
    );
    await open(tester, state);
    // The test font is much wider than the real one, so one row of the
    // Appearance page is reported as too wide here only.
    final previous = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.toString().contains('overflowed')) previous?.call(d);
    };
    addTearDown(() => FlutterError.onError = previous);
    await tapKey(tester, 'phone-more');
    await tester.tap(find.text('Settings'));
    await settle(tester, 12);
    await tester.tap(find.text('Appearance'));
    await settle(tester, 12);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.byKey(const ValueKey('interface-version')), findsNothing);
    await close(tester, state);
  });

  testWidgets(
    'search: ranked results say why they matched and can be filtered',
    (tester) async {
      final state = await boot(tester, size: iphone, ios: true, phone: true);
      await open(tester, state);
      await tapKey(tester, 'phone-search');
      await tester.enterText(
        find.byKey(const ValueKey('global-search-field')),
        'groceries',
      );
      await settle(tester);
      final inDialog = find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Groceries'),
      );
      expect(inDialog, findsOneWidget);
      expect(find.textContaining('in title'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('search-filter-tasks')));
      await settle(tester);
      expect(inDialog, findsNothing, reason: 'a note is not a task');
      await tester.tap(find.byKey(const ValueKey('search-filter-notes')));
      await settle(tester);
      expect(inDialog, findsOneWidget);
      await close(tester, state);
    },
  );

  // ── every place at every iPhone size, both themes ────────────────────

  for (final size in const [
    Size(375, 667), // SE
    Size(390, 844), // 12 to 15
    Size(430, 932), // Pro Max
    Size(844, 390), // landscape
  ]) {
    for (final theme in const ['dark', 'light']) {
      testWidgets(
        'every place lays out at ${size.width.toInt()}x${size.height.toInt()} '
        '$theme',
        (tester) async {
          final state = await boot(
            tester,
            size: size,
            ios: true,
            phone: true,
            theme: theme,
          );
          await open(tester, state);
          expect(tester.takeException(), isNull, reason: 'Today');
          for (final k in const [
            'notes',
            'calendar',
            'archive',
            'map',
            'today',
          ]) {
            await tapKey(tester, 'phone-tab-$k');
            expect(tester.takeException(), isNull, reason: k);
          }
          await close(tester, state);
        },
      );
    }
  }
}
