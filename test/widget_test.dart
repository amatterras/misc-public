import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_page.dart';
import 'package:flutter_application_1/features/canvas/canvas_page.dart';
import 'package:flutter_application_1/features/capture/capture_dialog.dart';
import 'package:flutter_application_1/features/search/search_dialog.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_test/flutter_test.dart';

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
  await tester.runAsync(state.flush);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 4));
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_widget_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('every page opens from the sidebar', (tester) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    for (final label in ['Home', 'Canvas', 'Notes', 'Calendar', 'Tasks']) {
      await tester.tap(find.text(label).last);
      await tester.pump();
    }
    expect(s.page, AppPage.tasks);
    await tester.tap(find.text('Calendar').last);
    await tester.pump();
    expect(find.byType(DayCell), findsNWidgets(38));
    for (final c in ['Reading', 'Habits', 'Events', 'Other']) {
      expect(find.text(c), findsWidgets);
    }
    expect(find.text('Projects'), findsNothing);
    await shutDown(tester, s);
  });

  testWidgets('canvas: double-click writes a note that survives a restart', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    var s = await boot(tester, dir);
    await tester.tap(find.text('Canvas').last);
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
    await tester.tap(find.text('Calendar').last);
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
    for (var i = 1; i <= 10; i++) {
      await gesture.moveBy(Offset(0, CalendarPage.cellHeight / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
    final moved = ws.entries[e.id]!;
    expect(dayKey(moved.startDate!), dayKey(addDays(start, 8)));
    expect(ws.entries.length, 1);

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
    await tester.tap(find.text('Calendar').last);
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
    await tester.tap(find.text('Calendar').last);
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

  testWidgets(
    'an open note editor shows outside changes and does not overwrite them',
    (tester) async {
      addTearDown(tester.view.reset);
      final s = await boot(tester, dir);
      final note = s.workspace.createNote(title: 'Shopping', body: 'Milk');
      s.openNote(note.id);
      await tester.pump();
      await tester.pump();
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
