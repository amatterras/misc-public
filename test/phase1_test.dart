// Phase 1 regressions: completing a task never removes it, dated tasks show
// on the calendar (also when done), calendar days are twice as tall, and
// canvas items can be connected by tapping one item and then another.
// Synthetic data in temporary folders only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_page.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

final sep = Platform.pathSeparator;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the local in-process hub

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_phase1_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  // ------------------------------------------------------------ tasks --

  group('completing a task', () {
    test('ticks the same record on and off; nothing is removed or copied, '
        'and every other field is kept', () async {
      final ws = Workspace(dir);
      await ws.load();
      ws.projects.put(
        Project(
          id: 'p1',
          name: 'Thesis',
          kind: ProjectKind.project,
          updatedAt: DateTime(2026),
        ),
      );
      final t = ws.createTask(
        'Write chapter 1',
        projectId: 'p1',
        dueDate: DateTime(2026, 11, 3),
      );
      ws.tasks.put(
        ws.tasks[t.id]!.copyWith(
          notes: 'Draft first',
          priority: 2,
          dueMinutes: () => 600,
          remindBefore: () => 30,
        ),
      );
      final sub = ws.createTask('Outline', parentId: t.id);
      final before = ws.tasks[t.id]!.toJson();

      for (var i = 0; i < 5; i++) {
        ws.toggleTask(t.id);
        expect(ws.tasks[t.id]!.done, isTrue, reason: 'round $i: completed');
        expect(ws.tasks[t.id]!.completedAt, isNotNull);
        ws.toggleTask(t.id);
        expect(ws.tasks[t.id]!.done, isFalse, reason: 'round $i: reopened');
        expect(ws.tasks[t.id]!.completedAt, isNull);
      }
      ws.toggleTask(t.id); // finish completed
      expect(ws.tasks.length, 2, reason: 'no copies, nothing removed');
      expect(ws.tasks.tombstones, isEmpty, reason: 'never deleted');
      final after = ws.tasks[t.id]!.toJson();
      for (final key in before.keys) {
        if ({'done', 'completedAt', 'updatedAt'}.contains(key)) continue;
        expect(after[key], before[key], reason: '$key kept');
      }
      expect(ws.tasks[sub.id]!.parentId, t.id, reason: 'subtask still linked');
      await ws.flush();
      ws.dispose();

      // After a restart.
      final again = Workspace(dir);
      await again.load();
      expect(again.tasks.length, 2);
      expect(again.tasks[t.id]!.done, isTrue);
      expect(again.tasks[t.id]!.remindBefore, 30);
      expect(again.tasks[t.id]!.projectId, 'p1');
      again.dispose();
    });

    test('completion syncs both ways without copies', () async {
      final hub = await HubServer.start(
        dir: Directory('${dir.path}${sep}hub'),
        port: 0,
        dailyBackups: false,
      );
      Future<(Workspace, SyncEngine)> device(String name) async {
        final ws = Workspace(Directory('${dir.path}$sep$name'));
        await ws.load();
        final token = await hub.auth.register(
          hub.auth.createPairingCode(),
          ws.device!.id,
          name,
        );
        return (
          ws,
          SyncEngine(
            workspace: ws,
            canvases: FileCanvasRepository(ws.store),
            client: SyncClient(
              Uri.parse('http://127.0.0.1:${hub.port}'),
              token: token,
            ),
          ),
        );
      }

      try {
        final (pc, pcSync) = await device('pc');
        final (ipad, ipadSync) = await device('ipad');
        final t = pc.createTask('Revise', dueDate: DateTime(2026, 11, 4));
        await pcSync.syncOnce();
        await ipadSync.syncOnce();
        ipad.toggleTask(t.id); // completed on the iPad
        await ipadSync.syncOnce();
        await pcSync.syncOnce();
        expect(pc.tasks[t.id]!.done, isTrue);
        pc.toggleTask(t.id); // reopened on the PC
        await pcSync.syncOnce();
        await ipadSync.syncOnce();
        expect(ipad.tasks[t.id]!.done, isFalse);
        expect(pc.tasks.length, 1);
        expect(ipad.tasks.length, 1);
        expect(ipad.conflicts.length, 0);
        pc.dispose();
        ipad.dispose();
      } finally {
        await hub.stop();
      }
    });

    test('task files from before Phase 1 load and keep every record', () async {
      // Representative older file: open, done, subtask, project task.
      Directory('${dir.path}${sep}data').createSync(recursive: true);
      Map<String, dynamic> task(
        String id, {
        bool done = false,
        String? parent,
      }) => Task(
        id: id,
        title: 'Task $id',
        createdAt: DateTime.utc(2026, 10, 1),
        updatedAt: DateTime.utc(2026, 10, 1),
        done: done,
        completedAt: done ? DateTime.utc(2026, 10, 2) : null,
        parentId: parent,
        dueDate: DateTime(2026, 10, 5),
      ).toJson();
      File('${dir.path}${sep}data${sep}tasks.json').writeAsStringSync(
        jsonEncode({
          'schema': 2,
          'records': [
            task('open'),
            task('done', done: true),
            task('sub', parent: 'open'),
          ],
          'revs': <String, String>{},
          'tombstones': <String, String>{},
        }),
      );
      final ws = Workspace(dir);
      await ws.load();
      expect(ws.tasks.length, 3);
      expect(ws.tasks['done']!.done, isTrue);
      ws.toggleTask('open');
      await ws.flush();
      final saved =
          (jsonDecode(
                File('${dir.path}${sep}data${sep}tasks.json')
                    .readAsStringSync(),
              ) as Map)['records']
              as List;
      expect(saved.map((r) => r['id']).toSet(), {'open', 'done', 'sub'});
      ws.dispose();
    });
  });

  // ------------------------------------------------- app (iPad layout) --

  Future<AppState> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1180, 820);
    tester.view.devicePixelRatio = 1;
    final ws = Workspace(dir);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await tester.runAsync(s.init);
    await tester.pumpWidget(TheApp(state: s));
    await tester.pump();
    return s;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shutDown(WidgetTester tester, AppState s) async {
    await waitForBothClocks(tester, s.flush, what: 'Saving');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  }

  testWidgets('a ticked task stays in its list, struck through, with a '
      'green tick; unticking restores it', (tester) async {
    final s = await boot(tester);
    final t = s.workspace.createTask('Hand in essay');
    s.goTo(AppPage.tasks);
    await settle(tester);
    final title = find.text('Hand in essay');
    expect(title, findsOneWidget);

    final box = find.descendant(
      of: find.ancestor(of: title, matching: find.byType(Row)).first,
      matching: find.byType(Checkbox),
    );
    await tester.tap(box);
    await settle(tester);
    expect(s.workspace.tasks[t.id]!.done, isTrue);
    expect(title, findsOneWidget, reason: 'still in "All tasks"');
    expect(
      tester.widget<Text>(title).style?.decoration,
      TextDecoration.lineThrough,
    );
    final checkbox = tester.widget<Checkbox>(box);
    expect(checkbox.value, isTrue);
    expect(checkbox.activeColor, OrganizerColors.green);

    await tester.tap(box);
    await settle(tester);
    expect(s.workspace.tasks[t.id]!.done, isFalse);
    expect(s.workspace.tasks.length, 1);
    await shutDown(tester, s);
  });

  testWidgets('dated tasks show on the right calendar day after a restart; '
      'done ones stay ticked; undated ones are not invented a date', (
    tester,
  ) async {
    var s = await boot(tester);
    final start = s.calendarStart;
    final open = s.workspace.createTask(
      'Lab report',
      dueDate: addDays(start, 2),
    );
    final done = s.workspace.createTask(
      'Read chapter',
      dueDate: addDays(start, 2),
    );
    s.workspace.toggleTask(done.id);
    s.workspace.createTask('No date yet');
    await shutDown(tester, s);

    s = await boot(tester);
    s.goTo(AppPage.calendar);
    await settle(tester);
    expect(find.text('Lab report'), findsOneWidget);
    expect(find.text('Read chapter'), findsOneWidget, reason: 'done stays');
    expect(find.text('No date yet'), findsNothing);
    final items = s.workspace.itemsOn(addDays(start, 2));
    expect(items.whereType<TaskOnDay>().map((i) => i.task.id), [
      open.id,
      done.id,
    ], reason: 'once each, open first');
    final doneLabel = tester.widget<Text>(find.text('Read chapter'));
    expect(doneLabel.style?.decoration, TextDecoration.lineThrough);
    await shutDown(tester, s);
  });

  testWidgets('calendar days are twice as tall and show 11 items', (
    tester,
  ) async {
    final s = await boot(tester);
    final day = addDays(s.calendarStart, 1);
    for (var i = 0; i < 11; i++) {
      s.workspace.createTask('Item $i', dueDate: day);
    }
    s.goTo(AppPage.calendar);
    await settle(tester);
    expect(CalendarPage.cellHeight, 312, reason: 'was 156');
    final cell = find.byType(DayCell).at(1);
    expect(tester.getSize(cell).height, 312);
    for (var i = 0; i < 11; i++) {
      expect(find.text('Item $i'), findsOneWidget, reason: 'Item $i shown');
    }
    expect(find.textContaining('more'), findsNothing);
    expect(tester.takeException(), isNull, reason: 'no overflow');
    await shutDown(tester, s);
  });

  // ----------------------------------------------------------- canvas --

  group('canvas connections by tapping', () {
    TextItem box(String id, Offset at) =>
        TextItem(id: id, position: at, width: 200, minHeight: 80, text: id);
    const a = Offset(100, 40), b = Offset(500, 340);
    CanvasController make([List<CanvasItem>? items]) => CanvasController(
      document: CanvasDocument(
        id: 'c',
        title: 'Map',
        items:
            items ?? [box('a', Offset.zero), box('b', const Offset(400, 300))],
        updatedAt: DateTime(2026),
      ),
      onSave: (_) async {},
    );
    void tap(
      CanvasController c,
      Offset at, [
      PointerDeviceKind kind = PointerDeviceKind.touch,
    ]) {
      c.pointerDown(at, kind: kind);
      c.pointerUp();
    }

    Iterable<ConnectorItem> lines(CanvasController c) =>
        c.items.whereType<ConnectorItem>();

    test('tap one item, then another: one connection, source highlighted '
        'in between', () {
      final c = make()..tool = CanvasTool.connect;
      tap(c, a);
      expect(c.connectSource, 'a', reason: 'waiting for the second tap');
      expect(lines(c), isEmpty);
      tap(c, b);
      expect(c.connectSource, isNull);
      final line = lines(c).single;
      expect({line.fromId, line.toId}, {'a', 'b'});
      // The same pair again, either way round: still one.
      tap(c, b);
      tap(c, a);
      expect(lines(c), hasLength(1));
    });

    test('Apple Pencil taps work the same way', () {
      final c = make()..tool = CanvasTool.connect;
      tap(c, a, PointerDeviceKind.stylus);
      tap(c, b, PointerDeviceKind.stylus);
      expect(lines(c), hasLength(1));
    });

    test('tapping the same item, empty space, Esc or another tool '
        'cancels', () {
      final c = make()..tool = CanvasTool.connect;
      tap(c, a);
      tap(c, a);
      expect(c.connectSource, isNull);
      tap(c, a);
      tap(c, const Offset(1200, 1200));
      expect(c.connectSource, isNull);
      tap(c, a);
      c.cancelConnect();
      expect(c.connectSource, isNull);
      tap(c, a);
      c.tool = CanvasTool.select;
      expect(c.connectSource, isNull);
      expect(lines(c), isEmpty);
    });

    test('a pinch between the two taps keeps the source waiting', () {
      final c = make()..tool = CanvasTool.connect;
      tap(c, a);
      c.pointerDown(const Offset(900, 900), kind: PointerDeviceKind.touch);
      c.pointerCancel(); // second finger: the page starts a pinch
      expect(c.connectSource, 'a');
      tap(c, b);
      expect(lines(c), hasLength(1));
    });

    test('dragging still connects, also right after a pending tap', () {
      final c = make()..tool = CanvasTool.connect;
      tap(c, a); // waiting...
      c.pointerDown(b, kind: PointerDeviceKind.touch);
      c.pointerMove(b + const Offset(-30, -30));
      c.pointerMove(a);
      c.pointerUp(); // ...but a drag from b to a is an ordinary connect drag
      expect(lines(c), hasLength(1));
      expect(c.connectSource, isNull);
    });

    test('the connection survives saving and reopening, with item ids and '
        'positions', () async {
      final store = FileCanvasRepository(Workspace(dir).store);
      final c = make()..tool = CanvasTool.connect;
      tap(c, a);
      tap(c, b);
      await store.save(c.document);
      final reopened = CanvasController(
        document: (await store.load('c'))!,
        onSave: (_) async {},
      );
      final line = reopened.items.whereType<ConnectorItem>().single;
      expect({line.fromId, line.toId}, {'a', 'b'});
      expect(
        (reopened.itemById('b')! as TextItem).position,
        const Offset(400, 300),
      );
      expect(reopened.connectorEnds(line), isNotNull, reason: 'drawn');
    });
  });
}
