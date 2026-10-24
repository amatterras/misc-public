// Roadmap Phase 3 (connections): canvas lock/tag/group/recolor/rotate,
// reference overlays, clean shapes, links between mindmaps, components,
// version snapshots, copying to notes, note/task/project links, mention
// suggestions, version comparison, conversion, command palette, app
// switcher, start page and activity, Archive projects and videos.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/canvas_ops.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/home/activity.dart';
import 'package:flutter_application_1/features/ink/shape_recognition.dart';
import 'package:flutter_application_1/features/notes/conversion.dart';
import 'package:flutter_application_1/features/notes/note_diff.dart';
import 'package:flutter_application_1/features/palette/app_switcher.dart';
import 'package:flutter_application_1/features/palette/command_palette.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasController controller(List<CanvasItem> items) => CanvasController(
  document: CanvasDocument(
    id: 'c1',
    title: 'Test',
    items: items,
    updatedAt: DateTime(2026),
  ),
  onSave: (_) async {},
  saveDelay: const Duration(milliseconds: 10),
);

StrokeItem stroke(String id, List<Offset> pts, {Color? color}) => StrokeItem(
  id: id,
  points: [for (final p in pts) StrokePoint(p.dx, p.dy, 0.5)],
  color: color ?? const Color(0x80E3E5E8),
  strokeWidth: 3,
);

TextItem text(String id, Offset at) =>
    TextItem(id: id, position: at, width: 200, minHeight: 40, text: id);

List<Offset> around(Rect r, int n, double Function(double t) wobble) => [
  for (var i = 0; i <= n; i++)
    () {
      final t = i / n;
      final side = (t * 4).floor().clamp(0, 3);
      final f = t * 4 - side;
      final p = switch (side) {
        0 => Offset.lerp(r.topLeft, r.topRight, f)!,
        1 => Offset.lerp(r.topRight, r.bottomRight, f)!,
        2 => Offset.lerp(r.bottomRight, r.bottomLeft, f)!,
        _ => Offset.lerp(r.bottomLeft, r.topLeft, f)!,
      };
      return p + Offset(wobble(t), -wobble(t));
    }(),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_r3_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> app() async {
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

  group('canvas selection tools', () {
    test('locked items cannot be moved, edited, erased or deleted', () {
      final c = controller([
        text('t', const Offset(100, 100)),
        stroke('s', const [Offset(400, 400), Offset(460, 400)]),
      ]);
      c.select(['t', 's']);
      c.toggleLockSelection();
      expect(c.isLocked('t') && c.isLocked('s'), isTrue);

      // Drag the text: it stays.
      c.pointerDown(const Offset(110, 110));
      c.pointerMove(const Offset(200, 200));
      c.pointerUp();
      expect((c.itemById('t') as TextItem).position, const Offset(100, 100));

      c.select(['t', 's']);
      c.deleteSelection();
      expect(c.items, hasLength(2));
      c.beginEditing('t');
      expect(c.editingId, isNull);

      c.tool = CanvasTool.eraser;
      c.pointerDown(const Offset(430, 400));
      c.pointerMove(const Offset(431, 401));
      c.pointerUp();
      expect(c.itemById('s'), isNotNull);

      c.select(['t', 's']);
      c.toggleLockSelection(); // all locked → unlock
      expect(c.isLocked('t'), isFalse);
      c.deleteSelection();
      expect(c.items, isEmpty);
    });

    test('tags, locks and groups are saved and synced with the item', () {
      final c = controller([
        text('a', Offset.zero),
        text('b', const Offset(300, 0)),
      ]);
      c.select(['a']);
      c.tagSelection(2);
      c.select(['a', 'b']);
      c.groupSelection();
      final doc = c.document;
      expect(doc.itemUnknownFields['a']?['tag'], 2);
      final back = CanvasDocument.fromJson(doc.toJson());
      final c2 = CanvasController(document: back, onSave: (_) async {});
      expect(c2.tagOf('a'), 2);
      expect(c2.tagOf('b'), isNull);
      expect(c2.groupOf('a'), isNotNull);
      expect(c2.groupOf('a'), c2.groupOf('b'));
      // Clicking one grouped item selects the group.
      c2.pointerDown(const Offset(10, 10));
      c2.pointerUp();
      expect(c2.selection, {'a', 'b'});
      c2.ungroupSelection();
      expect(c2.groupOf('a'), isNull);
      // A tag index outside the five chosen colors is ignored.
      c2.setMark(['b'], CanvasController.tagMark, 9);
      expect(c2.tagOf('b'), isNull);
      expect(CanvasTagColors.selected, hasLength(5));
    });

    test('recolor keeps a highlighter see-through; rotate turns ink', () {
      final c = controller([
        stroke('s', const [Offset(0, 0), Offset(100, 0)]),
        text('t', const Offset(0, 200)),
      ]);
      c.selectAll();
      c.recolorSelection(InkColors.all[5]);
      final s = c.itemById('s') as StrokeItem;
      expect(
        s.color.toARGB32() & 0xFFFFFF,
        InkColors.all[5].toARGB32() & 0xFFFFFF,
      );
      expect(s.color.a, closeTo(0x80 / 255, 0.01));
      expect((c.itemById('t') as TextItem).textColor, InkColors.all[5]);
      c.undo();
      expect((c.itemById('s') as StrokeItem).color, const Color(0x80E3E5E8));

      c.select(['s']);
      c.rotateSelection(math.pi / 2);
      final r = c.itemById('s') as StrokeItem;
      expect(r.bounds.width, lessThan(10)); // now vertical
      expect(r.bounds.height, greaterThan(95));
    });

    test('reference overlays are not selected or hit', () {
      final c = controller([
        ImageItem(
          id: 'img',
          position: Offset.zero,
          width: 300,
          minHeight: 200,
          assetId: 'x',
        ),
      ]);
      c.select(['img']);
      c.makeSelectionReference();
      expect(c.isReference('img'), isTrue);
      expect(c.selection, isEmpty);
      expect(c.hitTest(const Offset(50, 50)), isNull);
      c.releaseReferences();
      expect(c.hitTest(const Offset(50, 50))?.id, 'img');
    });

    test('rough shapes become clean ones; handwriting is left alone', () {
      final rect = recognizeShape(
        stroke(
          'r',
          around(
            const Rect.fromLTWH(0, 0, 200, 120),
            80,
            (t) => math.sin(t * 40) * 3,
          ),
        ).points,
      );
      expect(rect?.shape, RecognizedShape.rectangle);

      final circle = recognizeShape([
        for (var i = 0; i <= 60; i++)
          StrokePoint(
            100 +
                (80 + math.sin(i.toDouble()) * 2) *
                    math.cos(i / 60 * 2 * math.pi),
            100 +
                (80 + math.cos(i.toDouble()) * 2) *
                    math.sin(i / 60 * 2 * math.pi),
            0.5,
          ),
      ]);
      expect(circle?.shape, RecognizedShape.ellipse);

      final line = recognizeShape([
        for (var i = 0; i <= 20; i++)
          StrokePoint(i * 10.0, i.isEven ? 0 : 2, 0.5),
      ]);
      expect(line?.shape, RecognizedShape.line);

      final tri = recognizeShape([
        for (final (a, b) in const [
          (Offset(0, 100), Offset(60, 0)),
          (Offset(60, 0), Offset(120, 100)),
          (Offset(120, 100), Offset(2, 98)),
        ])
          for (var k = 0; k < 15; k++)
            StrokePoint(
              a.dx + (b.dx - a.dx) * k / 15,
              a.dy + (b.dy - a.dy) * k / 15,
              0.5,
            ),
      ]);
      expect(tri?.shape, RecognizedShape.triangle);

      // A scribbled "w" is not a shape.
      expect(
        recognizeShape([
          for (final p in const [
            Offset(0, 0),
            Offset(20, 60),
            Offset(40, 10),
            Offset(60, 60),
            Offset(80, 0),
          ])
            StrokePoint(p.dx, p.dy, 0.5),
        ]),
        isNull,
      );

      // Only while switched on.
      final c = controller(const []);
      c.tool = CanvasTool.pen;
      final pts = around(const Rect.fromLTWH(0, 0, 200, 120), 60, (_) => 0);
      c.pointerDown(pts.first);
      for (final p in pts.skip(1)) {
        c.pointerMove(p);
      }
      c.pointerUp();
      final raw = (c.items.single as StrokeItem).points.length;
      c.recognizeShapes = true;
      c.pointerDown(pts.first + const Offset(0, 300));
      for (final p in pts.skip(1)) {
        c.pointerMove(p + const Offset(0, 300));
      }
      c.pointerUp();
      expect(c.items, hasLength(2));
      expect((c.items.last as StrokeItem).points.length, isNot(raw));
    });
  });

  group('across mindmaps and notes', () {
    test('a link card opens the other mindmap', () async {
      final s = await app();
      await s.createCanvas(title: 'Physics');
      final physics = s.canvas!.id;
      await s.createCanvas(title: 'Chemistry');
      final c = s.canvas!;
      final card = s.linkToCanvas(c, physics, const Offset(100, 100))!;
      expect(canvasLinkTarget(s.workspace.assets[card.assetId]!.url), physics);
      s.activateCanvasItem(card);
      // Opening is asynchronous: wait for it (not a fixed delay, which is
      // too short when the whole suite runs in parallel).
      for (var i = 0; i < 100 && s.canvas!.id != physics; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(s.canvas!.id, physics);
      expect(s.page, AppPage.canvas);
      await s.flush();
      s.dispose();
    });

    test('components are saved and inserted as copies', () async {
      final s = await app();
      final c = s.canvas!;
      final start = c.items.length;
      c.addItems([text('k1', Offset.zero), text('k2', const Offset(0, 80))]);
      c.select(['k1']);
      c.tagSelection(1);
      final items = [c.itemById('k1')!, c.itemById('k2')!];
      await s.saveComponent('Header', items, c.marksOf(['k1', 'k2']));
      final list = await s.components();
      expect(list.single.name, 'Header');
      expect(list.single.items, hasLength(2));

      s.insertComponent(c, list.single, const Offset(1000, 1000));
      expect(c.items, hasLength(start + 4));
      final copies = c.items.skip(start + 2).toList();
      expect(c.groupOf(copies[0].id), isNotNull);
      expect(c.groupOf(copies[0].id), c.groupOf(copies[1].id));
      expect(copies.map((i) => c.tagOf(i.id)), contains(1));
      // The saved component is untouched.
      expect((await s.components()).single.items, hasLength(2));
      // And the components document is not listed as a mindmap.
      expect(s.canvasList.any((x) => x.id == componentsId), isFalse);
      await s.flush();
      s.dispose();
    });

    test(
      'a named version restores everything, and the restore can be undone',
      () async {
        final s = await app();
        final c = s.canvas!;
        final before = c.items.length;
        c.addItems([text('v1', const Offset(500, 500))]);
        c.select(['v1']);
        c.tagSelection(0);
        final snap = await s.saveSnapshot(c, 'Draft 1');
        c.select(['v1']);
        c.tagSelection(null);
        c.deleteSelection();
        c.addItems([text('later', Offset.zero)]);

        final list = await s.snapshotsOf(c.id);
        expect(list.single.name, 'Draft 1');
        expect(list.single.itemCount, before + 1);
        expect(await s.restoreSnapshot(c, snap.key), isTrue);
        expect(c.itemById('v1'), isNotNull);
        expect(c.itemById('later'), isNull);
        expect(c.tagOf('v1'), 0);
        c.undo();
        expect(c.itemById('later'), isNotNull);
        expect(await s.restoreSnapshot(c, 'missing'), isFalse);
        await s.flush();
        s.dispose();
      },
    );

    test('a selection is copied (or moved) onto a note\'s pages', () async {
      final s = await app();
      final c = s.canvas!;
      c.addItems([
        stroke('ink', const [
          Offset(0, 0),
          Offset(50, 50),
        ], color: InkColors.all[3]),
      ]);
      c.select(['ink']);
      c.tagSelection(4);
      final note = s.workspace.createNote(title: 'Lab');
      expect(await s.copyToNote(c, [c.itemById('ink')!], note.id), 1);
      final pages = await s.canvases.load(notebookIdFor(note.id));
      final copy = pages!.items.single as StrokeItem;
      expect(copy.id, isNot('ink'));
      expect(copy.color, InkColors.all[3]);
      expect(pages.itemUnknownFields[copy.id]?['tag'], 4);
      expect(c.itemById('ink'), isNotNull);

      await s.copyToNote(c, [c.itemById('ink')!], note.id, move: true);
      expect(c.itemById('ink'), isNull);
      expect(
        (await s.canvases.load(notebookIdFor(note.id)))!.items,
        hasLength(2),
      );
      await s.flush();
      s.dispose();
    });
  });

  group('notes connections', () {
    test('notes ↔ tasks ↔ projects link both ways and round-trip', () async {
      final s = await app();
      final ws = s.workspace;
      final note = ws.createNote(title: 'Enzymes');
      ws.projects.put(
        Project(
          id: 'bio',
          name: 'Biology',
          kind: ProjectKind.subject,
          updatedAt: DateTime(2026),
        ),
      );
      ws.notes.put(ws.notes[note.id]!.copyWith(projectIds: ['bio']));
      final t = ws.createTask('Revise enzymes');
      ws.tasks.put(t.copyWith(noteIds: [note.id]));
      expect(ws.tasksForNote(note.id).single.id, t.id);
      expect(ws.notesOfProject('bio').single.id, note.id);
      expect(Note.fromJson(ws.notes[note.id]!.toJson()).projectIds, ['bio']);
      expect(Task.fromJson(ws.tasks[t.id]!.toJson()).noteIds, [note.id]);
      expect(Note.fromJson({'id': 'x', 'title': 'x'}).projectIds, isEmpty);
      await s.flush();
      s.dispose();
    });

    test('mentions are suggested, and linked only when chosen', () async {
      final s = await app();
      final ws = s.workspace;
      ws.createNote(title: 'Photosynthesis');
      ws.createNote(title: 'Cell');
      final n = ws.createNote(
        title: 'Plants',
        body: 'Read about photosynthesis. Cellular is not Cell? [[Cell]] is.',
      );
      final suggested = ws.mentionedNotes(ws.notes[n.id]!).map((x) => x.title);
      expect(suggested, ['Photosynthesis']); // Cell is linked already
      expect(ws.notes[n.id]!.body, contains('photosynthesis.')); // unchanged
      expect(ws.linkMention(n.id, 'Photosynthesis'), isTrue);
      expect(
        ws.notes[n.id]!.body,
        startsWith('Read about [[photosynthesis]].'),
      );
      expect(ws.mentionedNotes(ws.notes[n.id]!), isEmpty);
      await s.flush();
      s.dispose();
    });

    test('version comparison marks removed and added lines', () {
      final d = diffLines(['a', 'b', 'c'], ['a', 'c', 'd']);
      expect(d.before, [LineChange.same, LineChange.removed, LineChange.same]);
      expect(d.after, [LineChange.same, LineChange.same, LineChange.added]);
    });

    testWidgets('converting selected text previews, then creates or reuses', (
      tester,
    ) async {
      final s = (await tester.runAsync(app))!;
      final ws = s.workspace;
      final note = ws.createNote(
        title: 'Plan',
        body: 'Book the lab\nBring goggles',
      );
      ws.createTask('Email tutor');
      expect(
        splitSelection('- Book the lab\nBring goggles').title,
        'Book the lab',
      );

      Future<void> run(
        String text,
        ConversionTarget target,
        String button,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    convertSelection(context, s, note.id, text, target),
                child: const Text('go'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('conversion-preview')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(ValueKey(button)));
        await tester.pumpAndSettle();
      }

      await run(
        'Book the lab\nBring goggles',
        ConversionTarget.task,
        'conversion-create',
      );
      final task = ws.tasks.all.firstWhere((t) => t.title == 'Book the lab');
      expect(task.notes, 'Bring goggles');
      expect(task.noteIds, [note.id]);
      expect(ws.notes[note.id]!.body, 'Book the lab\nBring goggles'); // kept

      await run(
        'email tutor',
        ConversionTarget.task,
        'conversion-use-existing',
      );
      expect(
        ws.tasks.all.where((t) => t.title.toLowerCase() == 'email tutor'),
        hasLength(1),
      );
      expect(ws.tasks.all.firstWhere((t) => t.title == 'Email tutor').noteIds, [
        note.id,
      ]);

      await run('Thesis', ConversionTarget.project, 'conversion-create');
      final project = ws.projects.all.firstWhere((p) => p.name == 'Thesis');
      expect(ws.notes[note.id]!.projectIds, [project.id]);

      await run('Goggles list', ConversionTarget.note, 'conversion-create');
      expect(ws.notes.all.any((n) => n.title == 'Goggles list'), isTrue);
      await tester.pump(const Duration(seconds: 4)); // toasts fade
      await tester.runAsync(s.flush);
      s.dispose();
    });
  });

  group('app-wide', () {
    test('the command palette finds commands and places', () async {
      final s = await app();
      s.workspace.createNote(title: 'Quantum notes');
      final cmds = paletteCommands(
        s,
        quickAdd: (_) {},
        search: (_) {},
        settings: (_) {},
        appSwitcher: (_) {},
      );
      expect(filterCommands(cmds, 'go cal').single.label, 'Go to calendar');
      expect(
        filterCommands(cmds, 'quantum').single.label,
        'Open note: Quantum notes',
      );
      expect(filterCommands(cmds, 'zzz'), isEmpty);
      filterCommands(cmds, 'go archive').single.run(_FakeContext());
      expect(s.page, AppPage.links);
      await s.flush();
      s.dispose();
    });

    test(
      'the app switcher can float and remembers nothing it should not',
      () async {
        final s = await app();
        final actions = switcherActions(
          s,
          quickAdd: (_) {},
          search: (_) {},
          palette: (_) {},
        );
        expect(
          actions.map((a) => a.label),
          containsAll(['mindmap', 'notes', 'calendar', 'archive', 'tasks']),
        );
        s.floating.show(appSwitcherWindow(s, () => actions));
        expect(s.floating.isOpen(appSwitcherWindowId), isTrue);
        await s.flush();
        s.dispose();
      },
    );

    test('start page sections and the activity timeline', () async {
      var s = await app();
      expect(s.homeSections, AppState.defaultHomeSections);
      await s.setHomeSections(['activity', 'today', 'bogus']);
      final n = s.workspace.createNote(title: 'Diary');
      final t = s.workspace.createTask('Run');
      s.toggleTask(t.id);
      s.openNote(n.id);
      await s.flush();
      s.dispose();

      s = await app();
      expect(s.homeSections, ['activity', 'today']);
      final events = activityTimeline(s);
      expect(
        events.map((e) => (e.kind, e.title)),
        containsAll([
          (ActivityKind.created, 'Diary'),
          (ActivityKind.completed, 'Run'),
          (ActivityKind.opened, 'Diary'),
        ]),
      );
      await s.flush();
      s.dispose();
    });

    test('Archive: projects on resources and video links', () {
      final a = Asset(
        id: 'a',
        kind: AssetKind.link,
        url: 'https://www.youtube.com/watch?v=x',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        projectIds: const ['p'],
      );
      expect(a.isVideo, isTrue);
      expect(Asset.fromJson(a.toJson()).projectIds, ['p']);
      final b = Asset(
        id: 'b',
        kind: AssetKind.link,
        url: 'https://notyoutube.com/x',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(b.isVideo, isFalse);
      expect(b.toJson().containsKey('projectIds'), isFalse);
    });
  });
}

class _FakeContext extends Fake implements BuildContext {}
