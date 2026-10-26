// Calendar workload: per-day load from existing entries and tasks, optional
// capacity, over-capacity marking, overdue / unscheduled lists, filters, and
// proof that nothing in the workspace is changed by looking at it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/workload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState s;
  final monday = weekStart(DateTime.now());
  final tuesday = monday.add(const Duration(days: 1));

  Task task(
    String id,
    DateTime? due, {
    bool done = false,
    int priority = 0,
    TaskStatus status = TaskStatus.todo,
  }) => Task(
    id: id,
    title: 'Task $id',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    dueDate: due,
    done: done,
    priority: priority,
    status: status,
  );

  CalendarEntry event(
    String id,
    DateTime day,
    int minutes, {
    CalendarCategory c = CalendarCategory.events,
  }) => CalendarEntry(
    id: id,
    category: c,
    name: 'Event $id',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    startDate: day,
    dates: {dayKey(day)},
    startMinutes: 9 * 60,
    durationMinutes: minutes,
  );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_workload_');
    final ws = Workspace(Directory('${dir.path}/data'));
    s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await s.init();
  });

  DayLoad tue(
    WorkloadSettings st, [
    WorkloadFilter f = const WorkloadFilter(),
  ]) => workloadFor(s.workspace, tuesday, 1, st, f).single;

  test('counts events and tasks and their time', () {
    s.workspace.entries.put(event('a', tuesday, 90));
    s.workspace.tasks.put(task('t1', tuesday));
    s.workspace.tasks.put(task('t2', tuesday));
    final d = tue(const WorkloadSettings());
    expect(d.eventCount, 1);
    expect(d.taskCount, 2);
    expect(d.minutes, 90 + 2 * 30);
    expect(d.over, isFalse, reason: 'no capacity means never over');
  });

  test('capacity marks only the days that exceed it', () {
    s.workspace.entries.put(event('a', tuesday, 240));
    s.workspace.tasks.put(task('t1', tuesday));
    expect(tue(const WorkloadSettings(capacityMinutes: 300)).over, isFalse);
    expect(tue(const WorkloadSettings(capacityMinutes: 240)).over, isTrue);
    expect(tue(const WorkloadSettings(capacityTasks: 1)).over, isFalse);
    s.workspace.tasks.put(task('t2', tuesday));
    expect(tue(const WorkloadSettings(capacityTasks: 1)).over, isTrue);
    expect(
      tue(const WorkloadSettings(minutesPerTask: 10, capacityMinutes: 270)).over,
      isFalse,
    );
  });

  test('filters: status, category, priority', () {
    s.workspace.tasks.put(task('open', tuesday));
    s.workspace.tasks.put(task('doing', tuesday, status: TaskStatus.doing));
    s.workspace.tasks.put(task('done', tuesday, done: true));
    s.workspace.tasks.put(task('high', tuesday, priority: 3));
    s.workspace.entries.put(event('e', tuesday, 60));
    s.workspace.entries.put(event('o', tuesday, 60, c: CalendarCategory.other));
    const st = WorkloadSettings();
    expect(tue(st).taskCount, 3, reason: 'done hidden by default');
    expect(tue(st, const WorkloadFilter(showDoneTasks: true)).taskCount, 4);
    expect(tue(st, const WorkloadFilter(showOpenTasks: false)).taskCount, 1);
    expect(tue(st, const WorkloadFilter(minPriority: 3)).taskCount, 1);
    expect(
      tue(
        st,
        const WorkloadFilter(categories: {CalendarCategory.events}),
      ).eventCount,
      1,
    );
  });

  test('overdue and unscheduled lists', () {
    final y = DateTime.now().subtract(const Duration(days: 3));
    s.workspace.tasks.put(task('late', y));
    s.workspace.tasks.put(task('lateDone', y, done: true));
    s.workspace.tasks.put(task('loose', null));
    s.workspace.tasks.put(
      task('future', DateTime.now().add(const Duration(days: 3))),
    );
    const f = WorkloadFilter();
    expect([
      for (final t in overdueTasks(s.workspace, DateTime.now(), f)) t.id,
    ], ['late']);
    expect([for (final t in unscheduledTasks(s.workspace, f)) t.id], ['loose']);
  });

  test('reading the workload changes nothing', () {
    s.workspace.entries.put(event('a', tuesday, 60));
    s.workspace.tasks.put(task('late', DateTime(2020, 1, 1)));
    s.workspace.tasks.put(task('loose', null));
    String snap() => [
      for (final t in s.workspace.tasks.all)
        '${t.id}|${t.dueDate}|${t.updatedAt}',
      for (final e in s.workspace.entries.all)
        '${e.id}|${e.startDate}|${e.updatedAt}',
    ].join(';');
    final before = snap();
    workloadFor(
      s.workspace,
      monday,
      28,
      const WorkloadSettings(capacityMinutes: 60),
      const WorkloadFilter(),
    );
    overdueTasks(s.workspace, DateTime.now(), const WorkloadFilter());
    unscheduledTasks(s.workspace, const WorkloadFilter());
    expect(snap(), before);
  });

  test('settings and filter survive JSON; damaged data falls back', () {
    const st = WorkloadSettings(
      capacityMinutes: 360,
      capacityTasks: 5,
      minutesPerTask: 45,
    );
    final back = WorkloadSettings.fromJson(st.toJson());
    expect([back.capacityMinutes, back.capacityTasks, back.minutesPerTask], [
      360,
      5,
      45,
    ]);
    final f = WorkloadFilter.fromJson(
      const WorkloadFilter(
        showDoneTasks: true,
        minPriority: 2,
        categories: {CalendarCategory.events},
      ).toJson(),
    );
    expect(f.showDoneTasks, isTrue);
    expect(f.minPriority, 2);
    expect(f.categories, {CalendarCategory.events});
    expect(WorkloadSettings.fromJson('junk').capacityMinutes, isNull);
    expect(WorkloadFilter.fromJson(7).showOpenTasks, isTrue);
    expect(formatMinutes(150), '2 h 30 min');
  });

  for (final mode in ['dark', 'light']) {
    testWidgets('view shows the Over marker in $mode theme', (t) async {
      // Real file IO must run outside the fake-async test zone.
      await t.runAsync(() async {
        await s.setThemeMode(mode);
        s.workspace.entries.put(event('a', tuesday, 600));
        await s.settings.set('workloadSettings', {'capacityMinutes': 300});
      });
      await t.binding.setSurfaceSize(const Size(1000, 800));
      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: mode == 'dark' ? Brightness.dark : Brightness.light,
          ),
          home: Scaffold(
            body: CalendarWorkloadView(state: s, anchor: monday, onDay: (_) {}),
          ),
        ),
      );
      await t.pump();
      expect(find.byKey(const ValueKey('workload-view')), findsOneWidget);
      expect(
        find.byKey(ValueKey('workload-over-${dayKey(tuesday)}')),
        findsOneWidget,
      );
      expect(find.text('Over'), findsWidgets);
      expect(t.takeException(), isNull);
      await t.binding.setSurfaceSize(null);
    });
  }
}
