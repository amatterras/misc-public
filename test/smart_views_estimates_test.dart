// Smart Views (Calendar Tasks column) and task time estimates: parsing and
// formatting, old-task compatibility, the filters and built-in views, saved
// views (create, rename, edit, delete, reload), sync through a real hub on
// 127.0.0.1, and where the selector and the clock label appear.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/models/smart_view_models.dart';
import 'package:flutter_application_1/data/models/task_estimate.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_page.dart';
import 'package:flutter_application_1/features/tasks/smart_views.dart';
import 'package:flutter_application_1/features/tasks/tasks_page.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/e2ee.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';
import 'support/sync_keys.dart';

final sep = Platform.pathSeparator;

Task _task(
  String id, {
  bool done = false,
  DateTime? due,
  int priority = 0,
  String? projectId,
  String? parentId,
  List<String> labels = const [],
  List<String> dependsOn = const [],
  int? estimate,
}) => Task(
  id: id,
  title: id,
  createdAt: DateTime(2026, 11, 1),
  updatedAt: DateTime(2026, 11, 1),
  done: done,
  dueDate: due,
  priority: priority,
  projectId: projectId,
  parentId: parentId,
  labels: labels,
  dependsOn: dependsOn,
  estimateMinutes: estimate,
);

Project _project(
  String id,
  String name, {
  ProjectKind kind = ProjectKind.project,
}) => Project(id: id, name: name, kind: kind, updatedAt: DateTime(2026, 11, 1));

Set<String> _ids(Iterable<Task> tasks) => {for (final t in tasks) t.id};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('duration parsing and formatting', () {
    test('natural input is read as minutes', () {
      const cases = {
        '15 min': 15,
        '45 minutes': 45,
        '1 hour': 60,
        '1 hour 30 minutes': 90,
        '1 hour and 30 minutes': 90,
        '1h30': 90,
        '1h 30m': 90,
        '1H30M': 90,
        '2 hours': 120,
        '2 hrs': 120,
        '1.5 h': 90,
        '1,5 h': 90,
        '1:30': 90,
        '90': 90,
        '  20 mins ': 20,
        'an hour': 60,
        'half an hour': 30,
        '45m': 45,
      };
      cases.forEach((input, minutes) {
        expect(parseEstimate(input), minutes, reason: input);
      });
    });

    test('anything else is rejected', () {
      for (final input in [
        '',
        '   ',
        'soon',
        '0',
        '0 min',
        '-5 min',
        '30 min 1 hour', // hours after minutes
        '1 hour 2 hours',
        '10 min 5 min',
        '1h30x',
        '9999 hours', // over a week
        'min',
      ]) {
        expect(parseEstimate(input), isNull, reason: input);
      }
      expect(parseEstimate('$maxEstimateMinutes min'), maxEstimateMinutes);
    });

    test('estimates are shown in short words', () {
      expect(formatEstimate(5), '5 min');
      expect(formatEstimate(45), '45 min');
      expect(formatEstimate(60), '1 hr');
      expect(formatEstimate(90), '1 hr 30 min');
      expect(formatEstimate(120), '2 hr');
      // What is shown can be typed back in.
      for (final m in [5, 45, 60, 90, 125, 600]) {
        expect(parseEstimate(formatEstimate(m)), m);
      }
    });
  });

  group('task compatibility', () {
    test('an old task without estimate loads and saves unchanged', () {
      final old = {
        'id': 't1',
        'title': 'Old task',
        'notes': '',
        'done': false,
        'completedAt': null,
        'dueDate': '2026-11-10',
        'dueMinutes': null,
        'priority': 2,
        'projectId': null,
        'parentId': null,
        'isExam': false,
        'recurrence': 'none',
        'assetIds': <String>[],
        'remindBefore': null,
        'createdAt': '2026-11-01T10:00:00.000Z',
        'updatedAt': '2026-11-01T10:00:00.000Z',
      };
      final t = Task.fromJson(old);
      expect(t.estimateMinutes, isNull);
      expect(t.effort, isNull);
      expect(jsonEncode(t.toJson()), jsonEncode(old));
    });

    test('estimate and effort round-trip; bad values are ignored', () {
      final t = _task('t')
          .copyWith(estimateMinutes: () => 45, effort: () => TaskEffort.heavy);
      final back = Task.fromJson(t.toJson());
      expect(back.estimateMinutes, 45);
      expect(back.effort, TaskEffort.heavy);
      final cleared = back.copyWith(
        estimateMinutes: () => null,
        effort: () => null,
      );
      expect(cleared.toJson().containsKey('estimateMinutes'), isFalse);
      expect(cleared.toJson().containsKey('effort'), isFalse);
      final odd = Task.fromJson({
        ...t.toJson(),
        'estimateMinutes': 'soon',
        'effort': 'extreme',
      });
      expect(odd.estimateMinutes, isNull);
      expect(odd.effort, isNull);
    });

    test('editing, moving and duplicating keep the estimate', () async {
      final dir = Directory.systemTemp.createTempSync('theapp_est_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace(dir);
      await ws.load();
      ws.projects.put(_project('p1', 'Thesis'));
      ws.projects.put(_project('p2', 'Work'));
      ws.tasks.put(
        _task(
          't',
          projectId: 'p1',
          estimate: 90,
        ).copyWith(effort: () => TaskEffort.medium),
      );
      ws.tasks.put(ws.tasks['t']!.copyWith(title: 'Renamed'));
      ws.tasks.put(ws.tasks['t']!.copyWith(projectId: () => 'p2'));
      ws.tasks.put(ws.tasks['t']!.shifted(3));
      expect(ws.tasks['t']!.estimateMinutes, 90);
      expect(ws.tasks['t']!.effort, TaskEffort.medium);
      ws.toggleTask('t');
      ws.toggleTask('t');
      expect(ws.tasks['t']!.estimateMinutes, 90);
      final copy = ws.duplicateTask('t')!;
      expect(copy.id, isNot('t'));
      expect(copy.estimateMinutes, 90);
      expect(copy.effort, TaskEffort.medium);
      expect(copy.projectId, 'p2');
      expect(copy.done, isFalse);
      // Saved and read back from disk.
      await ws.flush();
      final again = Workspace(dir);
      await again.load();
      expect(again.tasks['t']!.estimateMinutes, 90);
      expect(again.tasks[copy.id]!.estimateMinutes, 90);
      ws.dispose();
      again.dispose();
    });

    test(
      'fields from a newer version are kept when a task is edited',
      () async {
        // An older build does not know some field: it keeps it as unknown and
        // writes it back. Here a future field and a future effort value play
        // that part, through the same RecordCollection code.
        final dir = Directory.systemTemp.createTempSync('theapp_est_');
        addTearDown(() => dir.deleteSync(recursive: true));
        final ws = Workspace(dir);
        await ws.load();
        ws.tasks.put(_task('t', estimate: 30));
        await ws.flush();
        final file = File('${dir.path}${sep}data${sep}tasks.json');
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final rec = (json['records'] as List).single as Map<String, dynamic>;
        rec['futureField'] = {'x': 1};
        rec['effort'] = 'extreme';
        file.writeAsStringSync(jsonEncode(json));
        ws.dispose();

        final again = Workspace(dir);
        await again.load();
        again.tasks.put(again.tasks['t']!.copyWith(title: 'edited'));
        await again.flush();
        final saved =
            ((jsonDecode(file.readAsStringSync()) as Map)['records'] as List)
                    .single
                as Map;
        expect(saved['title'], 'edited');
        expect(saved['estimateMinutes'], 30);
        expect(saved['futureField'], {'x': 1});
        expect(saved['effort'], 'extreme');
        again.dispose();
      },
    );
  });

  group('filters and built-in views', () {
    late Directory dir;
    late Workspace ws;
    final today = DateTime(2026, 11, 8);

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('theapp_views_');
      ws = Workspace(dir);
      await ws.load();
      ws.projects.put(_project('uni', 'University'));
      ws.projects.put(
        _project('math', 'Linear algebra', kind: ProjectKind.subject),
      );
      ws.projects.put(_project('home', 'Home'));
      ws.projects.put(_project('build', 'Website'));
      for (final t in [
        _task('overdue', due: DateTime(2026, 11, 5), projectId: 'home'),
        _task('overdueDone', done: true, due: DateTime(2026, 11, 5)),
        _task('today', due: today, priority: 3),
        _task('later', due: DateTime(2026, 11, 20), priority: 1),
        _task('nodate', labels: ['errand']),
        _task('nodateDone', done: true),
        _task('high', priority: 3, projectId: 'uni'),
        _task('highDone', priority: 3, done: true),
        _task('essay', projectId: 'math', due: DateTime(2026, 11, 12)),
        _task('uniLabel', labels: ['University']),
        _task('sub', parentId: 'essay', due: DateTime(2026, 11, 1)),
        _task('design', projectId: 'build'),
        _task('launch', projectId: 'build', dependsOn: ['design']),
      ]) {
        ws.tasks.put(t);
      }
    });

    tearDown(() {
      ws.dispose();
      dir.deleteSync(recursive: true);
    });

    Set<String> view(BuiltInView v) => _ids(smartViewTasks(ws, v.id, today));

    test('Overdue: unfinished and past their deadline', () {
      expect(view(BuiltInView.overdue), {'overdue'});
    });

    test('University: study subjects, a University project or label', () {
      expect(view(BuiltInView.university), {'high', 'essay', 'uniLabel'});
    });

    test('High Priority: unfinished high-priority tasks', () {
      expect(view(BuiltInView.highPriority), {'today', 'high'});
    });

    test('No Deadline: unfinished tasks without a date', () {
      expect(view(BuiltInView.noDeadline), {
        'nodate',
        'high',
        'uniLabel',
        'design',
        'launch',
      });
    });

    test('Blocked Projects: open tasks of projects waiting on a task', () {
      expect(blockedProjectIds(ws), {'build'});
      expect(view(BuiltInView.blockedProjects), {'design', 'launch'});
      // Once the prerequisite is done the project is no longer blocked.
      ws.toggleTask('design');
      expect(view(BuiltInView.blockedProjects), isEmpty);
    });

    test('Today’s Habits: planned today and not ticked off', () {
      CalendarEntry habit(String id, Set<int> weekdays) => CalendarEntry(
        id: id,
        category: CalendarCategory.habits,
        name: id,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        startDate: DateTime(2026, 1, 1),
        weekdays: weekdays,
      );
      ws.entries.put(habit('daily', const {}));
      ws.entries.put(habit('sunday', const {DateTime.sunday}));
      ws.entries.put(habit('monday', const {DateTime.monday}));
      // 2026-11-08 is a Sunday.
      expect(
        {for (final e in habitsDueToday(ws, today)) e.id},
        {'daily', 'sunday'},
      );
      ws.toggleEntryCompletion('daily', today);
      expect({for (final e in habitsDueToday(ws, today)) e.id}, {'sunday'});
      expect(view(BuiltInView.todaysHabits), isEmpty); // habits, not tasks
    });

    test('views follow the live tasks: completing removes, edits add', () {
      expect(view(BuiltInView.overdue), contains('overdue'));
      ws.toggleTask('overdue');
      expect(view(BuiltInView.overdue), isNot(contains('overdue')));
      ws.tasks.put(ws.tasks['later']!.copyWith(priority: 3));
      expect(view(BuiltInView.highPriority), contains('later'));
    });

    test('custom conditions combine (all must hold)', () {
      final kinds = {for (final p in ws.projects.all) p.id: p.kind};
      bool m(ViewFilter f, String id) =>
          f.matches(ws.tasks[id]!, today: today, kindOf: (p) => kinds[p]);

      const open = ViewFilter();
      expect(m(open, 'overdue'), isTrue);
      expect(m(open, 'overdueDone'), isFalse);
      const done = ViewFilter(completion: ViewCompletion.done);
      expect(m(done, 'overdueDone'), isTrue);
      expect(m(done, 'overdue'), isFalse);
      const any = ViewFilter(completion: ViewCompletion.any);
      expect(m(any, 'overdueDone') && m(any, 'overdue'), isTrue);

      expect(m(const ViewFilter(due: ViewDue.today), 'today'), isTrue);
      expect(m(const ViewFilter(due: ViewDue.today), 'later'), isFalse);
      expect(m(const ViewFilter(due: ViewDue.next7), 'essay'), isTrue);
      expect(m(const ViewFilter(due: ViewDue.next7), 'later'), isFalse);
      expect(m(const ViewFilter(due: ViewDue.hasDeadline), 'later'), isTrue);
      expect(m(const ViewFilter(due: ViewDue.noDeadline), 'later'), isFalse);
      expect(m(const ViewFilter(due: ViewDue.overdue), 'overdue'), isTrue);

      const highUni = ViewFilter(priorities: {3}, projectIds: {'uni'});
      expect(m(highUni, 'high'), isTrue);
      expect(m(highUni, 'today'), isFalse); // high, but no project

      const subjects = ViewFilter(projectKinds: {ProjectKind.subject});
      expect(m(subjects, 'essay'), isTrue);
      expect(m(subjects, 'high'), isFalse);
      expect(m(subjects, 'nodate'), isFalse);

      const errands = ViewFilter(labels: {'errand'}, due: ViewDue.noDeadline);
      expect(m(errands, 'nodate'), isTrue);
      expect(m(errands, 'uniLabel'), isFalse);
    });

    test('a saved view shows only top-level matching tasks', () {
      final v = createSmartView(
        ws,
        'Subjects',
        const ViewFilter(projectKinds: {ProjectKind.subject}),
      );
      expect(_ids(smartViewTasks(ws, v.id, today)), {'essay'});
      expect(smartViewName(ws, v.id), 'Subjects');
      expect(smartViewExists(ws, v.id), isTrue);
      expect(smartViewExists(ws, 'gone'), isFalse);
      expect(smartViewExists(ws, BuiltInView.overdue.id), isTrue);
    });

    test('a new task typed into a view gets its simple conditions', () {
      final v = createSmartView(
        ws,
        'Home errands',
        const ViewFilter(
          projectIds: {'home'},
          priorities: {2},
          labels: {'errand'},
        ),
      );
      final d = smartViewDefaults(ws, v.id);
      expect(d.projectId, 'home');
      expect(d.priority, 2);
      expect(d.labels, ['errand']);
      expect(smartViewDefaults(ws, BuiltInView.highPriority.id).priority, 3);
      expect(smartViewDefaults(ws, BuiltInView.overdue.id).priority, isNull);
    });
  });

  group('saved views', () {
    test('create, rename, edit and delete; kept across a reload', () async {
      final dir = Directory.systemTemp.createTempSync('theapp_views_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace(dir);
      await ws.load();
      final v = createSmartView(
        ws,
        '  Deep   work ',
        const ViewFilter(priorities: {3}, due: ViewDue.next7),
      );
      expect(v.name, 'Deep work');
      renameSmartView(ws, v.id, 'Focus');
      ws.smartViews.put(
        ws.smartViews[v.id]!.copyWith(
          filter: ws.smartViews[v.id]!.filter.copyWith(
            labels: {'deep'},
            completion: ViewCompletion.any,
          ),
        ),
      );
      final gone = createSmartView(ws, 'Temp', const ViewFilter());
      ws.smartViews.remove(gone.id);
      await ws.flush();
      ws.dispose();

      final again = Workspace(dir);
      await again.load();
      expect(again.smartViews.all, hasLength(1));
      final back = again.smartViews[v.id]!;
      expect(back.name, 'Focus');
      expect(back.filter.priorities, {3});
      expect(back.filter.due, ViewDue.next7);
      expect(back.filter.labels, {'deep'});
      expect(back.filter.completion, ViewCompletion.any);
      expect(again.smartViews[gone.id], isNull);
      expect(again.smartViews.tombstones.keys, contains(gone.id));
      again.dispose();
    });

    test('view conditions from a newer version are kept', () {
      final j = {
        'id': 'v',
        'name': 'V',
        'filter': {
          'completion': 'open',
          'due': 'today',
          'effortIn': ['heavy'],
        },
        'createdAt': '2026-11-01T10:00:00.000Z',
        'updatedAt': '2026-11-01T10:00:00.000Z',
      };
      final v = SmartView.fromJson(j);
      final edited = v.copyWith(name: 'W');
      expect(edited.toJson()['filter']['effortIn'], ['heavy']);
      expect(edited.filter.due, ViewDue.today);
    });

    test('the collection syncs and older hubs are handled', () async {
      expect(syncedCollections, contains('smart_views'));
      expect(newerCollections, contains('smart_views'));
      final dir = Directory.systemTemp.createTempSync('theapp_views_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace(dir);
      expect(ws.syncCollections['smart_views'], same(ws.smartViews));
      ws.dispose();
    });
  });

  group('sync between two devices (real hub)', () {
    late Directory root;
    late HubServer hub;
    late Uri url;

    setUp(() async {
      HttpOverrides.global = null;
      root = Directory.systemTemp.createTempSync('theapp_views_sync_');
      hub = await HubServer.start(
        dir: Directory('${root.path}${sep}hub'),
        port: 0,
        dailyBackups: false,
      );
      url = Uri.parse('http://127.0.0.1:${hub.port}');
    });

    tearDown(() async {
      await hub.stop();
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<(Workspace, SyncEngine)> device(String name) async {
      final ws = Workspace(Directory('${root.path}$sep$name'));
      await ws.load();
      final secret = PairingSecret.generate();
      hub.auth.createPairingOffer(
        registerCode: secret.registerCode,
        wrappedKey: 'unused',
      );
      final token = (await hub.auth.registerWithKey(
        secret.registerCode,
        ws.device!.id,
        name,
      )).token;
      return (
        ws,
        SyncEngine(
          workspace: ws,
          canvases: FileCanvasRepository(ws.store),
          client: SyncClient(url, token: token, crypto: testSyncCrypto),
        ),
      );
    }

    test('saved views and estimates reach the other device', () async {
      final (a, syncA) = await device('windows');
      final (b, syncB) = await device('ipad');
      final view = createSmartView(
        a,
        'Uni this week',
        const ViewFilter(
          due: ViewDue.next7,
          projectKinds: {ProjectKind.subject},
        ),
      );
      a.tasks.put(
        _task('essay', estimate: 45).copyWith(effort: () => TaskEffort.light),
      );
      await syncA.syncOnce();
      await syncB.syncOnce();
      expect(b.smartViews[view.id]!.name, 'Uni this week');
      expect(b.smartViews[view.id]!.filter.due, ViewDue.next7);
      expect(b.tasks['essay']!.estimateMinutes, 45);
      expect(b.tasks['essay']!.effort, TaskEffort.light);

      // Renamed and re-estimated on the iPad: back on Windows.
      renameSmartView(b, view.id, 'Uni');
      b.tasks.put(b.tasks['essay']!.copyWith(estimateMinutes: () => 90));
      await syncB.syncOnce();
      await syncA.syncOnce();
      expect(a.smartViews[view.id]!.name, 'Uni');
      expect(a.tasks['essay']!.estimateMinutes, 90);

      // Deleted on Windows: gone on the iPad too.
      a.smartViews.remove(view.id);
      await syncA.syncOnce();
      await syncB.syncOnce();
      expect(b.smartViews[view.id], isNull);
      a.dispose();
      b.dispose();
    });
  });

  group('widgets', () {
    Future<AppState> boot(WidgetTester tester, Directory dir) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ws = Workspace(dir);
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      await tester.runAsync(s.init);
      return s;
    }

    Future<void> finish(WidgetTester tester, AppState s) async {
      await tester.pumpWidget(const SizedBox());
      await waitForBothClocks(tester, s.flush, what: 'Saving');
      await tester.pump(const Duration(seconds: 4));
    }

    testWidgets('the selector sits in the Tasks column and switches views; '
        'the clock shows only for tasks with an estimate', (tester) async {
      final dir = Directory.systemTemp.createTempSync('theapp_views_w_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final s = await boot(tester, dir);
      final ws = s.workspace;
      final today = dateOnly(DateTime.now());
      ws.tasks.put(_task('withEstimate', estimate: 45, priority: 3));
      ws.tasks.put(_task('plain', due: addDays(today, -2)));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TasksPage(state: s)),
        ),
      );
      await tester.pump();

      final selector = find.byKey(const ValueKey('smart-view-selector'));
      expect(selector, findsOneWidget);
      expect(find.text('withEstimate'), findsOneWidget);
      expect(find.text('plain'), findsOneWidget);
      // The clock label: on the estimated task only.
      expect(
        find.byKey(const ValueKey('task-estimate-withEstimate')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('task-estimate-plain')), findsNothing);
      expect(find.text('45 min'), findsOneWidget);

      // Overdue: only the overdue task.
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Overdue').last);
      await tester.pumpAndSettle();
      expect(find.text('plain'), findsOneWidget);
      expect(find.text('withEstimate'), findsNothing);

      // Completing it removes it, and the view says why it is empty.
      ws.toggleTask('plain');
      await tester.pump();
      expect(find.text('plain'), findsNothing);
      expect(find.byKey(const ValueKey('smart-view-empty')), findsOneWidget);
      expect(find.text('Nothing overdue.'), findsOneWidget);

      // Back to All tasks.
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('All tasks').last);
      await tester.pumpAndSettle();
      expect(find.text('withEstimate'), findsOneWidget);

      // Create a saved view from the selector.
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a new view…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('smart-view-name')),
        'Urgent',
      );
      await tester.tap(find.widgetWithText(FilterChip, 'High'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('smart-view-save')));
      await tester.pumpAndSettle();
      expect(ws.smartViews.all.single.name, 'Urgent');
      expect(ws.smartViews.all.single.filter.priorities, {3});
      expect(find.text('withEstimate'), findsOneWidget);
      expect(find.text('Urgent'), findsWidgets);

      // Delete it from the same menu: back to All tasks.
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete view'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(ws.smartViews.all, isEmpty);
      expect(find.text('plain'), findsOneWidget); // done, still in All tasks

      await finish(tester, s);
    });

    testWidgets('the estimate is typed in the task details and shown on the '
        'Calendar day', (tester) async {
      final dir = Directory.systemTemp.createTempSync('theapp_views_w_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final s = await boot(tester, dir);
      final ws = s.workspace;
      final today = dateOnly(DateTime.now());
      ws.tasks.put(_task('read', due: today));
      ws.tasks.put(_task('other', due: today));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskDetail(state: s, taskId: 'read', onClose: () {}),
          ),
        ),
      );
      await tester.pump();
      final field = find.byKey(const ValueKey('task-estimate-field'));
      expect(field, findsOneWidget);
      await tester.enterText(field, 'soon');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(ws.tasks['read']!.estimateMinutes, isNull);
      expect(find.textContaining('Try “45 min”'), findsOneWidget);
      await tester.enterText(field, '1 hour 30 minutes');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(ws.tasks['read']!.estimateMinutes, 90);
      expect(find.text('1 hr 30 min'), findsOneWidget);

      // The Calendar's day details show it for that task only.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DayPanel(
              state: s,
              day: today,
              onClose: () {},
              onNewEntry: (_) {},
              onRecognizeHandwriting: (_) async {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('task-estimate-read')), findsOneWidget);
      expect(find.byKey(const ValueKey('task-estimate-other')), findsNothing);

      await finish(tester, s);
    });

    testWidgets('no selector on Calendar while the Tasks column is closed', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('theapp_views_w_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final s = await boot(tester, dir);
      s.setCalendarTasksOpen(false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // The app shell rebuilds the page when the column opens.
            body: ListenableBuilder(
              listenable: s,
              builder: (_, _) => CalendarPage(state: s),
            ),
          ),
        ),
      );
      await tester.pump();
      final selector = find.byKey(const ValueKey('smart-view-selector'));
      expect(selector, findsNothing);
      s.setCalendarTasksOpen(true);
      await tester.pump();
      expect(selector, findsOneWidget);
      s.setCalendarTasksOpen(false);
      await tester.pump();
      await finish(tester, s);
    });

    testWidgets('Today’s Habits lists habits and hides the task tools', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('theapp_views_w_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final s = await boot(tester, dir);
      final ws = s.workspace;
      ws.entries.put(
        CalendarEntry(
          id: 'walk',
          category: CalendarCategory.habits,
          name: 'Morning walk',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          startDate: DateTime(2026, 1, 1),
          startMinutes: 7 * 60,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TasksPage(state: s)),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('smart-view-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today’s Habits').last);
      await tester.pumpAndSettle();
      expect(find.text('Morning walk'), findsOneWidget);
      expect(find.text('Add a task and press Enter'), findsNothing);
      expect(find.byKey(const ValueKey('task-view-switcher')), findsNothing);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(find.text('Morning walk'), findsNothing);
      expect(find.text('All of today’s habits are done.'), findsOneWidget);

      await finish(tester, s);
    });
  });
}
