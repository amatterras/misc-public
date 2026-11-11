// Requirements from MASTER_SPEC.md that had code but no direct test.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/search/search_dialog.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  calendarCellAndColourTests();
  focusTimerTests();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_spec_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppState> start() async {
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

  test('highlighter strokes are wide, translucent and saved', () {
    final c = CanvasController(
      document: CanvasDocument(
        id: 'c',
        title: 'T',
        items: const [],
        updatedAt: DateTime(2026),
        viewport: const CanvasViewport(),
        schema: 3,
      ),
      onSave: (_) async {},
    );
    c.tool = CanvasTool.pen;
    c.pointerDown(const Offset(0, 0));
    c.pointerMove(const Offset(80, 0));
    c.pointerUp();
    c.tool = CanvasTool.highlighter;
    c.pointerDown(const Offset(0, 50));
    c.pointerMove(const Offset(80, 50));
    c.pointerUp();
    final strokes = c.items.whereType<StrokeItem>().toList();
    expect(strokes, hasLength(2));
    final pen = strokes.first, marker = strokes.last;
    expect(marker.strokeWidth, c.highlighterWidth);
    expect(marker.strokeWidth, greaterThan(pen.strokeWidth));
    expect(marker.color.a, lessThan(0.5), reason: 'see-through');
    final saved = CanvasDocument.fromJson(
      jsonDecode(jsonEncode(c.document.toJson())) as Map<String, dynamic>,
    );
    final reloaded = saved.items.whereType<StrokeItem>().last;
    expect(reloaded.strokeWidth, marker.strokeWidth);
    expect(reloaded.color.toARGB32(), marker.color.toARGB32());
    c.dispose();
  });

  test('the collapsed sidebar is remembered after a restart', () async {
    var s = await start();
    expect(s.sidebarCollapsed, isFalse);
    s.toggleSidebar();
    await s.flush();
    s.dispose();
    s = await start();
    expect(s.sidebarCollapsed, isTrue);
    s.dispose();
  });

  test('the calendar range is limited to 38 days', () async {
    final s = await start();
    await s.setCalendarRange(DateTime(2026, 11, 1), 60);
    expect(s.calendarDays, AppState.maxCalendarDays);
    expect(AppState.maxCalendarDays, 38);
    await s.setCalendarRange(DateTime(2026, 11, 1), 10);
    expect(s.calendarDays, 10);
    s.dispose();
  });

  test('search finds notes, tasks, calendar entries and canvases', () async {
    final s = await start();
    final ws = s.workspace;
    ws.createNote(title: 'Quokka facts', body: 'small marsupial');
    ws.createTask('Feed the quokka');
    ws.saveEntry(
      CalendarEntry(
        id: newId(),
        category: CalendarCategory.events,
        name: 'Quokka day',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        startDate: DateTime.now(),
      ),
    );
    await s.createCanvas(title: 'Quokka board');
    final kinds = searchEverything(s, 'quokka').map((r) => r.kind).toSet();
    expect(kinds, containsAll(['Note', 'Task', 'Events', 'Mindmap']));
    expect(searchEverything(s, 'MARSUPIAL'), isNotEmpty, reason: 'any case');
    expect(searchEverything(s, 'zebra'), isEmpty);
    s.dispose();
  });

  test('tasks belong to projects and subjects; exams keep subtasks', () async {
    final s = await start();
    final ws = s.workspace;
    final project = Project(
      id: newId(),
      name: 'Thesis',
      kind: ProjectKind.project,
      updatedAt: DateTime.now(),
    );
    ws.projects.put(project);
    final t = ws.createTask('Write chapter 1', projectId: project.id);
    final exam = ws.createTask('Physics exam', isExam: true);
    ws.createTask('Revise optics', parentId: exam.id);
    await ws.flush();
    s.dispose();

    final again = Workspace(dir);
    await again.load();
    expect(again.projects[project.id]?.name, 'Thesis');
    expect(again.tasks[t.id]?.projectId, project.id);
    expect(again.tasks[exam.id]?.isExam, isTrue);
    expect(
      again.tasks.all.where((x) => x.parentId == exam.id).map((x) => x.title),
      ['Revise optics'],
    );
    again.dispose();
  });
}

void calendarCellAndColourTests() {
  test('the shared ink library keeps its canonical 19 first, in order', () {
    expect(
      [for (final c in InkColors.all.take(19)) c.toARGB32() & 0xFFFFFF],
      [
        0xE3E5E8,
        0x789BB5,
        0x829CB5,
        0x172943,
        0x4F9AA6,
        0x8FBFA9,
        0xC7D5A0,
        0xC8AED2,
        0xD5A16F,
        0xE56BDA,
        0xC6AD79,
        0x2878F0,
        0x2366AD,
        0x00BDB1,
        0xB5DC32,
        0x793BE8,
        0xF2D84A,
        0x176B4D,
        0xFF3B30,
      ],
    );
  });

  testWidgets('calendar cells: date top-left, weekday top-right, labels '
      'bottom-left', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('theapp_cells_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final ws = Workspace(dir);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await tester.runAsync(s.init);
    final start = DateTime(2026, 11, 10); // a Tuesday
    await tester.runAsync(() => s.setCalendarRange(start, 14));
    ws.saveEntry(
      CalendarEntry(
        id: newId(),
        category: CalendarCategory.events,
        name: 'Zebra talk',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        startDate: start,
      ),
    );
    s.goTo(AppPage.calendar);
    await tester.pumpWidget(TheApp(state: s));
    await tester.pump();
    await tester.pump();

    final date = tester.getRect(find.text('10'));
    final label = tester.getRect(find.text('Zebra talk').first);
    final weekday = find
        .text('TUE')
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)))
        .firstWhere((r) => (r.top - date.top).abs() < 12);
    expect(
      weekday.center.dx,
      greaterThan(date.center.dx + 60),
      reason: 'weekday on the right of the same top row',
    );
    expect(
      label.top,
      greaterThan(date.bottom + 30),
      reason: 'entry labels near the bottom',
    );
    expect(
      (label.left - date.left).abs(),
      // The 30px completion control (8ddfb4a) now sits before each label.
      lessThan(50),
      reason: 'entry labels start at the left',
    );

    await waitForBothClocks(tester, s.flush, what: 'Saving');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    s.dispose();
  });
}

void focusTimerTests() {
  testWidgets('focus timer: 25 min focus, then a 5 min break; pause works', (
    tester,
  ) async {
    final t = FocusTimer();
    expect(t.label, '25:00');
    t.start();
    await tester.pump(const Duration(seconds: 61));
    expect(t.label, '23:59');
    t.pause();
    await tester.pump(const Duration(minutes: 5));
    expect(t.label, '23:59', reason: 'paused');
    t.start();
    await tester.pump(const Duration(minutes: 24));
    expect(t.onBreak, isTrue, reason: 'focus finished: break starts');
    expect(t.running, isFalse);
    expect(t.label, '05:00');
    t.reset();
    expect(t.onBreak, isFalse);
    expect(t.label, '25:00');
    t.dispose();
  });
}
