import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/shell.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_page.dart';
import 'package:flutter_application_1/features/canvas/canvas_page.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/capture/capture_dialog.dart';
import 'package:flutter_application_1/features/motivation/motivation_service.dart';
import 'package:flutter_application_1/features/search/search_dialog.dart';
import 'package:flutter_application_1/widgets/common.dart' show formatLongDate;
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

/// Boots the real app on a temporary data folder.
Future<AppState> boot(WidgetTester tester, Directory dir) async {
  tester.view.physicalSize = const Size(1700, 1050);
  tester.view.devicePixelRatio = 1;
  final ws = Workspace(dir);
  final state = AppState(
    canvases: FileCanvasRepository(ws.store),
    settings: SettingsRepository(ws.store),
    workspace: ws,
    enableSendTo: false,
  );
  state.capture.fetchPreviews = false;
  await tester.runAsync(state.init);
  await tester.pumpWidget(TheApp(state: state));
  await tester.pump();
  return state;
}

/// Lets real file I/O finish and the UI catch up (pumpAndSettle would wait
/// forever on a blinking text cursor).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> shutDown(WidgetTester tester, AppState state) async {
  await waitForBothClocks(tester, state.flush, what: 'Saving');
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 4));
  state.dispose();
  state.workspace.dispose();
}

void main() {
  late Directory dir;
  late String quoteSource;
  late String greetingSource;

  setUpAll(() async {
    quoteSource = await rootBundle.loadString('assets/motivation/quotes.json');
    greetingSource = await rootBundle.loadString(
      'assets/motivation/greetings.json',
    );
  });
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_widget_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('every page opens from the sidebar', (tester) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    await tester.tap(find.byKey(const ValueKey('sidebar-start-page')));
    await tester.pump();
    expect(s.page, AppPage.home);
    // Exactly the four destinations, in order and spelling.
    for (final label in ['mindmap', 'notes', 'archive', 'calendar']) {
      await tester.tap(find.text(label).last);
      await tester.pump();
    }
    expect(s.page, AppPage.calendar);
    expect(find.text('Home'), findsNothing);
    expect(
      find.byKey(const ValueKey('calendar-tasks-toggle')),
      findsOneWidget,
      reason: 'the calendar task toggle',
    );
    await tester.pump();
    expect(find.byType(DayCell), findsNWidgets(38));
    for (final c in ['Reading', 'Habits', 'Events', 'Other']) {
      expect(find.text(c), findsWidgets);
    }
    expect(find.text('Projects'), findsNothing);
    await shutDown(tester, s);
  });

  testWidgets('motivational quote bars and 60-second greeting', (tester) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    final motivation = MotivationService(nextIndex: (_) => 0)
      ..loadFromSources(quoteSource, greetingSource);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: AppShell(state: s, motivation: motivation),
      ),
    );
    await tester.pump();
    await settle(tester);

    expect(find.byKey(const ValueKey('motivational-quote')), findsOneWidget);
    expect(find.byKey(const ValueKey('greeting-window')), findsOneWidget);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    expect(find.byKey(const ValueKey('motivational-quote')), findsOneWidget);
    expect(find.byKey(const ValueKey('greeting-window')), findsOneWidget);

    await tester.pump(const Duration(seconds: 59));
    expect(find.byKey(const ValueKey('greeting-window')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('greeting-window')), findsNothing);
    motivation.dispose();
    await shutDown(tester, s);
  });

  testWidgets('canvas: letter keys typed into a note never switch tools', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    await tester.tap(find.text('mindmap').last);
    await tester.pump();
    await tester.pump();
    final view = find.byType(CanvasView);
    final spot = tester.getTopLeft(view) + const Offset(900, 600);
    await tester.tapAt(spot, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(spot, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(s.canvas!.editingItem, isNotNull);
    final toolBefore = s.canvas!.tool;
    // Real key events, as a keyboard sends them (tool keys: V L H P I E T C).
    for (final key in [
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.keyE,
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyT,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    expect(s.canvas!.tool, toolBefore, reason: 'typing, not tool switching');
    expect(s.canvas!.editingItem, isNotNull, reason: 'still editing');
    await shutDown(tester, s);
  });

  testWidgets('canvas: double-click writes a note that survives a restart', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    var s = await boot(tester, dir);
    await tester.tap(find.text('mindmap').last);
    await tester.pump();
    await tester.pump();
    final before = s.canvas!.items.length;

    final view = find.byType(CanvasView);
    final spot = tester.getTopLeft(view) + const Offset(900, 600);
    await tester.tapAt(spot, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(spot, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(s.canvas!.editingItem, isNotNull);
    await tester.enterText(find.byType(TextField).last, 'Remember the milk');
    await tester.pump();
    s.canvas!.endEditing();
    await tester.pump();
    expect(s.canvas!.items.length, before + 1);
    final id = s.canvas!.items.last.id;
    await shutDown(tester, s);

    s = await boot(tester, dir);
    await tester.runAsync(() => s.openCanvas(s.canvasList.first.id));
    final restored = s.canvas!.itemById(id) as TextItem;
    expect(restored.text, 'Remember the milk');
    await shutDown(tester, s);
  });

  testWidgets('Quick Add on a phone: save a link to Links with tags', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    tester.view.physicalSize = const Size(375, 812);
    await tester.pump();
    showCaptureDialog(
      tester.element(find.byType(Scaffold).first),
      s,
      destination: CaptureDestination.links,
    );
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'fits a phone');
    await tester.enterText(
      find
          .descendant(
            of: find.byType(CaptureDialog),
            matching: find.byType(TextField),
          )
          .first,
      'https://example.com/recipe',
    );
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('capture-tag-shopping')),
    );
    await tester.tap(find.byKey(const ValueKey('capture-tag-shopping')));
    await tester.pump();
    await tester.ensureVisible(find.textContaining('Save').last);
    await tester.tap(find.textContaining('Save').last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await settle(tester);
    expect(s.page, AppPage.links);
    final card = s.linksBoard!.items.whereType<LinkItem>().single;
    final asset = s.workspace.assets[card.assetId]!;
    expect(asset.url, 'https://example.com/recipe');
    expect(asset.linkTags, ['shopping']);
    await shutDown(tester, s);
  });

  testWidgets(
    'Quick Add: a pasted URL becomes a link card on the canvas and a note',
    (tester) async {
      addTearDown(tester.view.reset);
      final s = await boot(tester, dir);

      showCaptureDialog(
        tester.element(find.byType(Scaffold).first),
        s,
        destination: CaptureDestination.canvas,
      );
      await settle(tester);
      await tester.enterText(
        find
            .descendant(
              of: find.byType(CaptureDialog),
              matching: find.byType(TextField),
            )
            .first,
        'https://example.com/article',
      );
      await tester.pump();
      expect(find.textContaining('Link: example.com/article'), findsOneWidget);
      await tester.tap(find.textContaining('Save'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await settle(tester);
      expect(s.page, AppPage.canvas);
      final card = s.canvas!.items.whereType<LinkItem>().single;
      final asset = s.workspace.assets[card.assetId]!;
      expect(asset.url, 'https://example.com/article');

      // Same link into Notes: reuses the same asset record.
      showCaptureDialog(
        tester.element(find.byType(Scaffold).first),
        s,
        destination: CaptureDestination.notes,
      );
      await settle(tester);
      await tester.enterText(
        find
            .descendant(
              of: find.byType(CaptureDialog),
              matching: find.byType(TextField),
            )
            .first,
        'https://example.com/article',
      );
      await tester.pump();
      await tester.tap(find.textContaining('Save'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await settle(tester);
      final note = s.workspace.notes.all.single;
      expect(note.assetIds, [asset.id]);
      expect(s.workspace.assets.length, 1);

      // Search finds both.
      final results = searchEverything(s, 'example.com');
      expect(results.map((r) => r.kind), containsAll(['Link', 'Note']));
      await shutDown(tester, s);
    },
  );

  testWidgets('calendar: labels update everywhere, drag moves an event', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    tester.view.physicalSize = const Size(1700, 1900);
    await tester.pump();
    final start = s.calendarStart;
    final ws = s.workspace;
    final e = CalendarEntry(
      id: newId(),
      category: CalendarCategory.events,
      name: 'Dentist',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      startDate: addDays(start, 1),
      endDate: addDays(start, 1),
    );
    ws.saveEntry(e);
    await tester.tap(find.text('calendar').last);
    await tester.pump();
    expect(find.text('Dentist'), findsOneWidget);

    // Category view shows the same record.
    await tester.tap(find.text('Events').first);
    await tester.pump();
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('1 of 5 active'), findsOneWidget);

    // Edit it (as the category editor does) and check the grid.
    ws.saveEntry(ws.entries[e.id]!.copyWith(name: 'Dentist 3pm'));
    await tester.tap(find.textContaining('-Day Grid'));
    await tester.pump();
    expect(find.text('Dentist 3pm'), findsOneWidget);

    // Drag the label one row down (7 days later).
    final label = find.text('Dentist 3pm');
    final gesture = await tester.startGesture(
      tester.getCenter(label),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 50));
    final destination = find.byKey(
      ValueKey('calendar-cell-${dayKey(addDays(start, 7))}'),
    );
    await gesture.moveTo(tester.getCenter(destination));
    await gesture.up();
    await tester.pump();
    final moved = ws.entries[e.id]!;
    expect(dayKey(moved.startDate!), dayKey(addDays(start, 7)));
    expect(ws.entries.length, 1);
    // The drop's result (with Undo) stays a few seconds.
    await tester.pump(const Duration(seconds: 9));

    // A task due in range shows on the grid; ticking it there completes the task.
    final t = ws.createTask('Hand in essay', dueDate: addDays(start, 2));
    await tester.pump();
    expect(find.text('Hand in essay'), findsOneWidget);
    expect(
      ws.itemsOn(addDays(start, 2)).whereType<TaskOnDay>().single.task.id,
      t.id,
    );
    await shutDown(tester, s);
  });

  testWidgets('single pen tap selects tool; double tap unfolds shared colors', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    s.goTo(AppPage.canvas);
    await settle(tester);
    s.canvas!.tool = CanvasTool.pen;
    await tester.pump();
    expect(find.byKey(const ValueKey('context-bar-collapse')), findsOneWidget);
    final pen = find.byTooltip('Draw  (P)');
    await tester.tap(pen);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('context-bar-collapse')));
    await tester.pump();
    expect(s.canvasOptionsCollapsed, isTrue);

    await tester.tap(pen);
    await tester.pump();
    expect(s.canvas!.tool, CanvasTool.pen);
    expect(
      s.canvasOptionsCollapsed,
      isTrue,
      reason: 'a single tap keeps the existing tool action',
    );

    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(pen);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(pen);
    await tester.pump();
    expect(s.canvasOptionsCollapsed, isFalse);
    expect(find.byTooltip('Bright Red'), findsOneWidget);
    await shutDown(tester, s);
  });

  testWidgets(
    'all calendar entry categories can be checked per date in every view',
    (tester) async {
      addTearDown(tester.view.reset);
      final s = await boot(tester, dir);
      final day = s.calendarStart;
      final habit = CalendarEntry(
        id: 'walk-at-830',
        category: CalendarCategory.habits,
        name: 'Morning walk',
        createdAt: day,
        updatedAt: day,
        startDate: day,
        endDate: day,
        startMinutes: 8 * 60 + 30,
      );
      s.workspace.saveEntry(habit);
      final reading = CalendarEntry(
        id: 'read-occurrence',
        category: CalendarCategory.reading,
        name: 'Read pages',
        createdAt: day,
        updatedAt: day,
        readingLog: {dayKey(day): 12},
      );
      final event = CalendarEntry(
        id: 'event-occurrence',
        category: CalendarCategory.events,
        name: 'Conference',
        createdAt: day,
        updatedAt: day,
        startDate: day,
        endDate: addDays(day, 1),
      );
      final other = CalendarEntry(
        id: 'other-occurrence',
        category: CalendarCategory.other,
        name: 'Bins out',
        createdAt: day,
        updatedAt: day,
        dates: {dayKey(day)},
      );
      s.workspace.saveEntry(reading);
      s.workspace.saveEntry(event);
      s.workspace.saveEntry(other);
      s.workspace.createTask('Ordinary task', dueDate: day);

      final plan = CalendarEntry(
        id: 'book-plan',
        category: CalendarCategory.reading,
        name: 'Plan book',
        createdAt: day,
        updatedAt: day,
        readingPlanStartDate: day,
        readingPlanEndDate: day,
      );
      s.workspace.saveReadingPlan(plan);
      final dailyId = '${plan.id}/${dayKey(day)}';
      s.workspace.saveEntry(
        s.workspace.entries[dailyId]!.copyWith(notes: 'Exact day notes'),
      );

      s.goTo(AppPage.calendar);
      await settle(tester);
      expect(find.text('08:30'), findsOneWidget);
      final expectedEntries = [habit, reading, event, other];
      for (final view in ['Range', 'Month', 'Agenda', 'Timeline', 'Day']) {
        await tester.tap(find.text(view).first);
        await tester.pumpAndSettle();
        for (final entry in expectedEntries) {
          var check = find.byKey(
            ValueKey('entry-check-${entry.id}-${dayKey(day)}'),
          );
          if (check.evaluate().isEmpty && view == 'Month') {
            final cell = find.byKey(ValueKey('calendar-cell-${dayKey(day)}'));
            final more = find.descendant(
              of: cell,
              matching: find.textContaining('more'),
            );
            expect(more, findsOneWidget, reason: 'overflow in $view view');
            await tester.tap(more);
            await tester.pumpAndSettle();
            check = find.byKey(
              ValueKey('overflow-entry-check-${entry.id}-${dayKey(day)}'),
            );
          }
          expect(check, findsOneWidget, reason: '${entry.name} in $view view');
          await tester.tap(check);
          await tester.pump();
          expect(s.workspace.entries[entry.id]!.isCheckedOn(day), isTrue);
          if (view == 'Month' &&
              check.evaluate().single.widget is CheckboxListTile) {
            final more = find.descendant(
              of: find.byKey(ValueKey('calendar-cell-${dayKey(day)}')),
              matching: find.textContaining('more'),
            );
            await tester.tap(more);
            await tester.pumpAndSettle();
            check = find.byKey(
              ValueKey('overflow-entry-check-${entry.id}-${dayKey(day)}'),
            );
          }
          await tester.tap(check);
          await tester.pump();
          expect(s.workspace.entries[entry.id]!.isCheckedOn(day), isFalse);
        }
      }

      final check = find.bySemanticsLabel(
        'Mark Morning walk complete on ${formatLongDate(day)}',
      );
      await tester.tap(find.text('Range').first);
      await tester.pumpAndSettle();
      await tester.tap(check);
      await tester.pump();
      expect(s.workspace.entries[habit.id]!.isCheckedOn(day), isTrue);
      expect(
        s.workspace.entries[habit.id]!.isCheckedOn(addDays(day, 1)),
        isFalse,
      );

      final pageLabel = '${plan.name} · ${dayKey(day)}';
      await tester.tap(find.text(pageLabel));
      await tester.pump();
      final notesField = tester.widget<TextField>(find.byType(TextField).last);
      expect(notesField.controller!.text, 'Exact day notes');
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await shutDown(tester, s);
    },
  );

  testWidgets('calendar: the sixth active entry is refused in the UI', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    for (var i = 0; i < 5; i++) {
      s.workspace.saveEntry(
        CalendarEntry(
          id: newId(),
          category: CalendarCategory.habits,
          name: 'Habit $i',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          startDate: s.calendarStart,
        ),
      );
    }
    await tester.tap(find.text('calendar').last);
    await tester.pump();
    await tester.tap(find.text('Habits').first);
    await tester.pump();
    expect(find.text('5 of 5 active'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'New Habits entry'),
    );
    expect(button.onPressed, isNull);
    await shutDown(tester, s);
  });

  testWidgets('calendar: a category over the limit after a sync is warned '
      'about, never archived automatically', (tester) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    // Six active habits arriving from two devices (as a sync merge would).
    for (var i = 0; i < 6; i++) {
      s.workspace.entries.applyRemote(
        'h$i',
        SyncClock(deviceId: 'ipad').now(),
        CalendarEntry(
          id: 'h$i',
          category: CalendarCategory.habits,
          name: 'Habit $i',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          startDate: s.calendarStart,
        ).toJson(),
      );
    }
    await tester.tap(find.text('calendar').last);
    await tester.pump();
    await tester.pump();
    final warning = find.byKey(const ValueKey('over-limit-warning'));
    expect(warning, findsOneWidget);
    expect(
      find.descendant(
        of: warning,
        matching: find.textContaining('Habits (6 active)'),
      ),
      findsOneWidget,
    );
    expect(s.workspace.activeCount(CalendarCategory.habits), 6);
    expect(s.workspace.entries.all.where((e) => e.archived), isEmpty);

    // The user archives one; the warning goes away.
    s.workspace.setArchived('h5', true);
    await tester.pump();
    await tester.pump();
    expect(warning, findsNothing);
    await shutDown(tester, s);
  });

  testWidgets('Inbox: dismissing a typed thought asks first; a link does not', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    final ws = s.workspace;
    ws.inbox.put(
      InboxItem(
        id: 'th',
        text: 'Only copy of this idea',
        createdAt: DateTime.now(),
      ),
    );
    s.goTo(AppPage.home);
    await tester.pump();
    await tester.pump();
    Finder dismissOf(String text) => find.descendant(
      of: find.ancestor(of: find.text(text), matching: find.byType(Row)).first,
      matching: find.byTooltip('Dismiss'),
    );

    await tester.tap(dismissOf('Only copy of this idea'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Delete this thought?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ws.inbox['th'], isNotNull, reason: 'cancel keeps it');

    await tester.tap(dismissOf('Only copy of this idea'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ws.inbox['th'], isNull);

    // A link keeps its own record, so it is dismissed without a question.
    final link = s.capture.link('https://example.com/kept');
    ws.inbox.put(
      InboxItem(id: 'ln', assetId: link.id, createdAt: DateTime.now()),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('Dismiss').first);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Delete this thought?'), findsNothing);
    expect(ws.inbox['ln'], isNull);
    expect(ws.assets[link.id], isNotNull, reason: 'the link record stays');
    await shutDown(tester, s);
  });

  testWidgets('a failing save shows a notice until it is saved', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    final notice = find.byKey(const ValueKey('unsaved-notice'));
    expect(notice, findsNothing);
    s.workspace.unsaved.value = {'notes'};
    await tester.pump();
    expect(notice, findsOneWidget);
    s.workspace.unsaved.value = const {};
    await tester.pump();
    expect(notice, findsNothing);
    await shutDown(tester, s);
  });

  testWidgets(
    'an open note editor shows outside changes and does not overwrite them',
    (tester) async {
      addTearDown(tester.view.reset);
      final s = await boot(tester, dir);
      final note = s.workspace.createNote(title: 'Shopping', body: 'Milk');
      s.openNote(note.id);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500)); // page slides in
      final bodyField = find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == 'Milk',
      );
      expect(bodyField, findsOneWidget);
      final controller = tester.widget<TextField>(bodyField).controller!;

      // Quick Add appends to this note while it is open.
      s.workspace.notes.put(
        s.workspace.notes[note.id]!.copyWith(body: 'Milk\n\nEggs (added)'),
      );
      await tester.pump();
      await tester.pump();
      expect(controller.text, 'Milk\n\nEggs (added)');

      // Typing afterwards keeps the added text.
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.controller == controller,
        ),
        '${controller.text}\nBread',
      );
      await tester.pump();
      expect(s.workspace.notes[note.id]!.body, 'Milk\n\nEggs (added)\nBread');
      await shutDown(tester, s);
    },
  );
}
