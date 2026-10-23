// Task reminders: computed from the due date/time, shown while the app
// runs (and after a restart if missed), dismissed per device.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/sidebar.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

Task task({
  DateTime? due,
  int? minutes,
  int? before,
  Recurrence rec = Recurrence.none,
}) {
  final now = DateTime(2026, 11, 1);
  return Task(
    id: 't',
    title: 'Hand in essay',
    createdAt: now,
    updatedAt: now,
    dueDate: due,
    dueMinutes: minutes,
    remindBefore: before,
    recurrence: rec,
  );
}

void main() {
  group('model', () {
    test('reminder time counts back from the due time', () {
      expect(
        task(due: DateTime(2026, 11, 2), minutes: 600, before: 15).reminderTime,
        DateTime(2026, 11, 2, 9, 45),
      );
      // A date without a time reminds at 09:00 on that day, minus the offset.
      expect(
        task(due: DateTime(2026, 11, 2), before: 24 * 60).reminderTime,
        DateTime(2026, 11, 1, 9),
      );
      expect(task(due: DateTime(2026, 11, 2)).reminderTime, isNull);
      expect(task(before: 0).reminderTime, isNull, reason: 'no due date');
    });

    test('saved and loaded; older files without the field still load', () {
      final t = task(due: DateTime(2026, 11, 2), minutes: 600, before: 60);
      expect(Task.fromJson(t.toJson()).remindBefore, 60);
      final old = t.toJson()..remove('remindBefore');
      expect(Task.fromJson(old).remindBefore, isNull);
    });

    test('a recurring task keeps its reminder for the next date', () {
      final t = task(
        due: DateTime(2026, 11, 2),
        minutes: 600,
        before: 0,
        rec: Recurrence.daily,
      );
      final next = t.completed();
      expect(next.done, isFalse);
      expect(next.reminderTime, DateTime(2026, 11, 3, 10));
    });
  });

  group('app', () {
    late Directory dir;
    late DateTime now;
    late int attention;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('theapp_remind_');
      now = DateTime(2026, 11, 2, 9);
      attention = 0;
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<AppState> start() async {
      final ws = Workspace(dir);
      final s =
          AppState(
              canvases: FileCanvasRepository(ws.store),
              settings: SettingsRepository(ws.store),
              workspace: ws,
              enableSendTo: false,
            )
            ..clock = (() => now)
            ..attention = (() => attention++);
      await s.init();
      return s;
    }

    test('due reminders appear once; dismissal survives a restart', () async {
      var s = await start();
      final ws = s.workspace;
      final t = ws.createTask('Hand in essay', dueDate: DateTime(2026, 11, 2));
      ws.tasks.put(
        ws.tasks[t.id]!.copyWith(dueMinutes: () => 600, remindBefore: () => 15),
      );
      final done = ws.createTask(
        'Already done',
        dueDate: DateTime(2026, 11, 2),
      );
      ws.tasks.put(
        ws.tasks[done.id]!.copyWith(remindBefore: () => 0, done: true),
      );

      s.checkReminders();
      expect(s.dueReminders.value, isEmpty, reason: 'not yet 09:45');
      now = DateTime(2026, 11, 2, 9, 46);
      s.checkReminders();
      expect(s.dueReminders.value.map((x) => x.id), [t.id]);
      expect(attention, 1);
      s.checkReminders();
      expect(attention, 1, reason: 'no repeated alert for the same one');

      s.dismissReminder(t.id);
      expect(s.dueReminders.value, isEmpty);
      await s.flush();
      s.dispose();

      s = await start();
      expect(s.dueReminders.value, isEmpty, reason: 'stays dismissed');
      s.dispose();
    });

    test('a reminder missed while closed shows at the next start', () async {
      var s = await start();
      final t = s.workspace.createTask(
        'Call dentist',
        dueDate: DateTime(2026, 11, 2),
      );
      s.workspace.tasks.put(
        s.workspace.tasks[t.id]!.copyWith(
          dueMinutes: () => 480,
          remindBefore: () => 0,
        ),
      );
      await s.flush();
      s.dispose();
      now = DateTime(2026, 11, 2, 12); // app reopened later
      s = await start();
      expect(s.dueReminders.value.map((x) => x.id), [t.id]);
      s.dispose();
    });

    test('a recurring task reminds again for its next date', () async {
      final s = await start();
      final ws = s.workspace;
      final t = ws.createTask('Stretch', dueDate: DateTime(2026, 11, 2));
      ws.tasks.put(
        ws.tasks[t.id]!.copyWith(
          dueMinutes: () => 480,
          remindBefore: () => 0,
          recurrence: Recurrence.daily,
        ),
      );
      s.checkReminders();
      s.dismissReminder(t.id);
      ws.toggleTask(t.id); // completed: moves to Nov 3, 08:00
      now = DateTime(2026, 11, 3, 8, 1);
      s.checkReminders();
      expect(s.dueReminders.value.map((x) => x.id), [t.id]);
      await s.flush();
      s.dispose();
    });

    testWidgets('the reminder notice opens the task', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await tester.runAsync(start);
      final t = s!.workspace.createTask(
        'Revise chapter 3',
        dueDate: DateTime(2026, 11, 2),
      );
      s.workspace.tasks.put(
        s.workspace.tasks[t.id]!.copyWith(remindBefore: () => 60),
      );
      s.checkReminders(); // 09:00 - 60 min = 08:00 < now
      await tester.pumpWidget(TheApp(state: s));
      await tester.pump();
      expect(find.byKey(const ValueKey('reminders')), findsOneWidget);
      // It sits in the workspace, never over the sidebar's controls.
      final notice = tester.getRect(find.byKey(const ValueKey('reminders')));
      expect(notice.right, lessThanOrEqualTo(1600 - Sidebar.expandedWidth));
      expect(find.text('Revise chapter 3'), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, 'Open'));
      await tester.pump();
      expect(s.page, AppPage.calendar); // Tasks live in its task column
      expect(s.calendarTasksOpen, isTrue);
      expect(find.byKey(const ValueKey('reminders')), findsNothing);
      await waitForBothClocks(tester, s.flush, what: 'Saving');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      s.dispose();
    });
  });
}
