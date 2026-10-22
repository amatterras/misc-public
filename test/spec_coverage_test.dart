// Requirements from MASTER_SPEC.md that had code but no direct test.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/search/search_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    expect(kinds, containsAll(['Note', 'Task', 'Events', 'Canvas']));
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
