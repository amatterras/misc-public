// Implementation 1/5: canvas selection and tagging, cross-unit drag and
// drop, and Apple Pencil Pro squeeze in Calendar (controller side).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_ink.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_painter.dart';
import 'package:flutter_application_1/features/transfer/transfer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

StrokeItem stroke(String id, double x, double y) => StrokeItem(
  id: id,
  points: [StrokePoint(x, y, 0.5), StrokePoint(x + 40, y + 10, 0.5)],
  color: const Color(0xFFE3E5E8),
  strokeWidth: 3,
);

TextItem text(String id, Offset at, [String t = '']) => TextItem(
  id: id,
  position: at,
  width: 200,
  minHeight: 60,
  text: t.isEmpty ? id : t,
);

CanvasController controller(List<CanvasItem> items, {String id = 'c'}) =>
    CanvasController(
      document: CanvasDocument(
        id: id,
        title: id,
        items: items,
        updatedAt: DateTime(2026),
      ),
      onSave: (_) async {},
      saveDelay: const Duration(milliseconds: 5),
    );

/// Counts what the painter draws.
class CountingCanvas implements Canvas {
  final _centers = <Offset>{};

  /// Distinct dot positions (a dot may be filled and outlined).
  int get circles => _centers.length;
  int rrects = 0;
  @override
  void drawCircle(Offset c, double radius, Paint paint) => _centers.add(c);
  @override
  void drawRRect(RRect rrect, Paint paint) => rrects++;
  @override
  int getSaveCount() => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_core_'));
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

  group('selection and tags', () {
    test('an area of strokes has one boundary with exactly two dots', () {
      final c = controller([
        stroke('a', 0, 0),
        stroke('b', 60, 20),
        stroke('c', 120, 40),
      ]);
      final plain = CountingCanvas();
      CanvasPainter(c).paint(plain, const Size(800, 600));
      c.select(['a', 'b', 'c']);
      expect(c.selectionUnits, hasLength(3));
      expect(c.selectionBounds, c.boundsOf(c.items));
      final canvas = CountingCanvas();
      CanvasPainter(c).paint(canvas, const Size(800, 600));
      expect(
        canvas.circles - plain.circles,
        2,
        reason: 'one top-left and one top-right dot',
      );

      // Tagging the area makes it one object: the tag shows once.
      c.tagSelection(2);
      expect(c.groupOf('a'), isNotNull);
      expect({c.groupOf('a'), c.groupOf('b'), c.groupOf('c')}, hasLength(1));
      expect(c.taggedUnits, hasLength(1));
      expect(c.taggedUnits.single.$1, c.boundsOf(c.items));
      c.select(const []);
      final tagged = CountingCanvas();
      CanvasPainter(c).paint(tagged, const Size(800, 600));
      expect(
        tagged.circles,
        2,
        reason: 'tag dots once for the compound object',
      );
    });

    test('a single stroke is selected on its own; a group click narrows', () {
      final c = controller([stroke('a', 0, 0), stroke('b', 300, 0)]);
      c.pointerDown(const Offset(20, 5), timeStamp: const Duration(seconds: 1));
      c.pointerUp();
      expect(c.selection, {'a'});

      c.select(['a', 'b']);
      c.groupSelection();
      c.select(const []);
      c.pointerDown(const Offset(20, 5), timeStamp: const Duration(seconds: 2));
      c.pointerUp();
      expect(c.selection, {'a', 'b'}, reason: 'a group selects as a unit');
      expect(c.selectionUnits, hasLength(1));
      // Click again without dragging: just the stroke under the pointer.
      c.pointerDown(const Offset(20, 5), timeStamp: const Duration(seconds: 3));
      c.pointerUp();
      expect(c.selection, {'a'});

      // Dragging a selected group moves all of it.
      c.select(['a', 'b']);
      c.pointerDown(const Offset(20, 5), timeStamp: const Duration(seconds: 4));
      c.pointerMove(const Offset(70, 105));
      c.pointerUp();
      expect(
        (c.itemById('b') as StrokeItem).points.first.x,
        closeTo(350, 0.01),
      );
      expect(c.selection, {'a', 'b'});
    });

    test(
      'tags stay right after scaling, rotating, ungrouping and reopening',
      () {
        final c = controller([
          stroke('a', 0, 0),
          stroke('b', 100, 50),
          text('t', const Offset(0, 100)),
        ]);
        c.select(['a', 'b', 't']);
        c.tagSelection(4);
        final before = c.selectionBounds!;
        // The top-right dot scales the whole selection.
        final dot = c.toScreen(before.topRight);
        expect(c.resizeHandleAt(dot), isNotNull);
        c.pointerDown(dot);
        c.pointerMove(dot + Offset(before.width, 0));
        c.pointerUp();
        final after = c.selectionBounds!;
        expect(after.width, closeTo(before.width * 2, before.width * 0.1));
        expect(after.bottomLeft.dx, closeTo(before.bottomLeft.dx, 3));
        expect(c.taggedUnits.single.$2, 4);

        c.rotateSelection(1.0);
        expect(c.taggedUnits, hasLength(1));

        final reopened = CanvasController(
          document: CanvasDocument.fromJson(c.document.toJson()),
          onSave: (_) async {},
        );
        expect(reopened.taggedUnits.single.$2, 4);
        expect(reopened.unitsOf(reopened.items), hasLength(1));
        reopened.select(['a', 'b', 't']);
        reopened.ungroupSelection();
        // Ungrouped: each item keeps its tag and shows it itself.
        expect(reopened.taggedUnits, hasLength(3));
        reopened.select(['a']);
        reopened.tagSelection(null);
        expect(reopened.tagOf('a'), isNull);
        expect(reopened.tagOf('b'), 4);
      },
    );

    test('hit-testing: boxes over connections, overlaps, empty space', () {
      final c = controller([
        text('under', Offset.zero),
        text('over', const Offset(50, 10)),
        text('far', const Offset(600, 0)),
        const ConnectorItem(id: 'link', fromId: 'under', toId: 'far'),
      ]);
      // The connection is listed last but drawn underneath the boxes.
      expect(c.hitTest(const Offset(100, 30))?.id, 'over');
      expect(c.hitTest(const Offset(20, 20))?.id, 'under');
      final mid = Offset.lerp(
        c.itemBounds(c.itemById('under')!).center,
        c.itemBounds(c.itemById('far')!).center,
        0.6,
      )!;
      expect(c.hitTest(mid)?.id, 'link');
      expect(c.hitTest(const Offset(400, 500)), isNull);
    });
  });

  group('drag and drop between units', () {
    test(
      'mindmap → mindmap: copy keeps, move removes only after arrival',
      () async {
        final s = await app();
        final a = s.canvas!;
        a.addItems([stroke('s1', 0, 0), text('t1', const Offset(0, 80))]);
        a.select(['s1']);
        a.tagSelection(1);
        await s.createCanvas(title: 'B');
        final bId = s.canvas!.id;
        await s.openCanvas(a.id, show: false);
        final src = s.canvas!;
        final t = CanvasItemsTransfer(src, ['s1', 't1']);
        expect(s.transferChoices(t, CanvasPlace(src.id)), isEmpty);
        final ops = s.transferChoices(t, CanvasPlace(bId)).map((c) => c.op);
        expect(
          ops,
          containsAll([TransferOp.copy, TransferOp.move, TransferOp.link]),
        );

        await s.performTransfer(
          t,
          CanvasPlace(bId, at: Offset.zero),
          TransferOp.copy,
        );
        expect(src.itemById('s1'), isNotNull);
        final b = (await s.canvases.load(bId))!;
        expect(b.items, hasLength(2));
        expect(b.items.map((i) => i.id), isNot(contains('s1')));
        expect(b.itemUnknownFields.values.any((m) => m['tag'] == 1), isTrue);

        await s.openCanvas(src.id, show: false);
        src.select(['t1']);
        src.toggleLockSelection();
        await s.performTransfer(
          CanvasItemsTransfer(s.canvas!, ['s1', 't1']),
          CanvasPlace(bId),
          TransferOp.move,
        );
        expect(s.canvas!.itemById('s1'), isNull, reason: 'moved');
        expect(s.canvas!.itemById('t1'), isNotNull, reason: 'locked stays');
        await s.flush();
        s.dispose();
      },
    );

    test(
      'mindmap text → tasks on a day, with undo; note → day; task → day',
      () async {
        final s = await app();
        final ws = s.workspace;
        final c = s.canvas!;
        c.addItems([text('x', Offset.zero, '# Buy goggles\nfor the lab')]);
        final day = DateTime(2026, 11, 5);
        final r = await s.performTransfer(
          CanvasItemsTransfer(c, ['x']),
          DayPlace(day),
          TransferOp.convert,
        );
        final made = ws.tasks.all
            .where((t) => t.title == 'Buy goggles')
            .toList();
        expect(made.single.dueDate, day);
        expect(
          c.itemById('x'),
          isNotNull,
          reason: 'conversion keeps the original',
        );
        await r.undo!();
        expect(ws.tasks.all.where((t) => t.title == 'Buy goggles'), isEmpty);

        final note = ws.createNote(title: 'Lab rules');
        final m = await s.performTransfer(
          NoteTransfer(note.id, note.displayTitle),
          DayPlace(day),
          TransferOp.link,
        );
        expect(ws.dayRecord(day).text, contains('[[Lab rules]]'));
        await m.undo!();
        expect(ws.dayRecord(day).text, isNot(contains('[[Lab rules]]')));

        final task = ws.createTask('Essay', dueDate: DateTime(2026, 11, 1));
        expect(
          s.transferChoices(
            TaskTransfer(task.id, task.title, from: DateTime(2026, 11, 1)),
            DayPlace(DateTime(2026, 11, 1)),
          ),
          isEmpty,
          reason: 'same day: nothing to do',
        );
        await s.performTransfer(
          TaskTransfer(task.id, task.title, from: DateTime(2026, 11, 1)),
          DayPlace(day),
          TransferOp.move,
        );
        expect(ws.tasks[task.id]!.dueDate, day);
        expect(ws.tasks.length, 1, reason: 'same record, no copy');
        await s.flush();
        s.dispose();
      },
    );

    test('calendar entries move between days and back with undo', () async {
      final s = await app();
      final ws = s.workspace;
      final d1 = DateTime(2026, 3, 2), d2 = DateTime(2026, 3, 9);
      ws.entries.put(
        CalendarEntry(
          id: 'e',
          category: CalendarCategory.events,
          name: 'Trip',
          createdAt: d1,
          updatedAt: d1,
          startDate: d1,
        ),
      );
      final r = await s.performTransfer(
        CalendarItemTransfer(EntryOnDay(ws.entries['e']!), d1),
        DayPlace(d2),
        TransferOp.move,
      );
      expect(ws.entries['e']!.startDate, d2);
      await r.undo!();
      expect(ws.entries['e']!.startDate, d1);
      await s.flush();
      s.dispose();
    });

    test(
      'text, attachments and notes reach notes, tasks and mindmaps',
      () async {
        final s = await app();
        final ws = s.workspace;
        final note = ws.createNote(title: 'Target', body: 'start');
        final link = ws.linkAsset('https://example.com');
        final a = await s.performTransfer(
          AssetsTransfer([link.id]),
          NotePlace(note.id),
          TransferOp.link,
        );
        expect(ws.notes[note.id]!.assetIds, [link.id]);
        expect(ws.assets.length, 1, reason: 'a reference, not a copy');
        await a.undo!();
        expect(ws.notes[note.id]!.assetIds, isEmpty);

        await s.performTransfer(
          const TextTransfer('Call the dentist\nbefore Friday'),
          const TasksPlace(),
          TransferOp.convert,
        );
        expect(ws.tasks.all.any((t) => t.title == 'Call the dentist'), isTrue);

        final c = s.canvas!;
        final count = c.items.length;
        await s.performTransfer(
          NoteTransfer(note.id, note.displayTitle),
          CanvasPlace(c.id, at: const Offset(10, 10)),
          TransferOp.link,
        );
        expect(c.items.length, count + 1);
        expect(c.items.last, isA<NoteCardItem>());
        expect((c.items.last as NoteCardItem).noteId, note.id);
        await s.flush();
        s.dispose();
      },
    );

    testWidgets(
      'dragging the selection grip onto a note copies onto its pages',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final s = (await tester.runAsync(app))!;
        final note = s.workspace.createNote(title: 'Drop here');
        final c = s.canvas!;
        c.addItems([stroke('ink', 100, 100)]);
        c.tool = CanvasTool.select;
        c.select(['ink']);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  SizedBox(
                    width: 200,
                    height: 200,
                    child: TransferTarget(
                      state: s,
                      place: NotePlace(note.id),
                      child: const ColoredBox(
                        key: ValueKey('note-target'),
                        color: Colors.black,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 600,
                    height: 600,
                    child: Stack(
                      children: [
                        Positioned(
                          left: 50,
                          top: 50,
                          width: 22,
                          height: 22,
                          child: TransferSource(
                            key: const ValueKey('grip'),
                            transfer: () => CanvasItemsTransfer(c, ['ink']),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final from = tester.getCenter(find.byKey(const ValueKey('grip')));
        final to = tester.getCenter(find.byKey(const ValueKey('note-target')));
        final g = await tester.startGesture(from);
        await g.moveTo(from + const Offset(5, 5));
        await tester.pump();
        await g.moveTo(to);
        await tester.pump();
        await g.up();
        await tester.pumpAndSettle();
        // Copy or move: the menu offers both; cancelling would change nothing.
        expect(find.byKey(const ValueKey('transfer-copy')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('transfer-copy')));
        // The copy saves with real file I/O and the test's simulated clock.
        CanvasDocument? pages;
        for (var i = 0; i < 100 && (pages?.items.isEmpty ?? true); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          pages = await tester.runAsync<CanvasDocument?>(
            () => s.canvases.load(notebookIdFor(note.id)),
          );
        }
        expect(pages!.items, hasLength(1));
        expect(c.itemById('ink'), isNotNull);
        await waitForBothClocks(tester, s.flush, what: 'Saving');
        await tester.pump(const Duration(seconds: 9)); // result bar timer
        s.dispose();
      },
    );
  });

  group('Apple Pencil Pro squeeze in Calendar', () {
    test('erases while squeezed, then everything goes back', () {
      final ink = controller(const [], id: calendarInkId)
        ..tool = CanvasTool.pen;
      var drawing = false, visible = true;
      final squeeze = CalendarSqueeze(
        ink,
        visible: () => visible,
        drawing: () => drawing,
        setDrawing: (on) => drawing = on,
      );
      squeeze.phase('began');
      expect(ink.tool, CanvasTool.eraser);
      expect(ink.squeezeEraser, isTrue);
      expect(drawing, isTrue, reason: 'Draw mode on while squeezed');
      squeeze.phase('began'); // a repeat is ignored
      squeeze.phase('ended');
      expect(ink.tool, CanvasTool.pen);
      expect(drawing, isFalse);

      // Cancelled (e.g. Pencil lifted away) restores as well.
      drawing = true;
      squeeze.phase('began');
      squeeze.phase('cancelled');
      expect(ink.tool, CanvasTool.pen);
      expect(drawing, isTrue);

      // Calendar not shown: nothing happens.
      visible = false;
      squeeze.phase('began');
      expect(ink.tool, CanvasTool.pen);
      expect(squeeze.active, isFalse);

      // Going to the background or another page ends it.
      visible = true;
      squeeze.phase('began');
      squeeze.end();
      expect(ink.tool, CanvasTool.pen);
      squeeze.end(); // twice is harmless
      squeeze.phase('something else');
      expect(ink.tool, CanvasTool.pen);
    });

    test('a stroke drawn while squeezed erases calendar ink', () {
      final day = DateTime(2026, 10, 23);
      final rect = inkDayRect(day);
      final ink = controller([
        StrokeItem(
          id: 'old',
          points: [
            StrokePoint(rect.left + 20, 40, 0.5),
            StrokePoint(rect.left + 120, 40, 0.5),
          ],
          color: const Color(0xFFE3E5E8),
          strokeWidth: 3,
        ),
      ], id: calendarInkId)..tool = CanvasTool.pen;
      final squeeze = CalendarSqueeze(
        ink,
        visible: () => true,
        drawing: () => true,
        setDrawing: (_) {},
      );
      squeeze.phase('began');
      ink.setView(Offset.zero, 1);
      ink.pointerDown(Offset(rect.left + 70, 30));
      ink.pointerMove(Offset(rect.left + 70, 50));
      ink.pointerUp();
      squeeze.phase('ended');
      expect(ink.itemById('old'), isNull);
      expect(ink.tool, CanvasTool.pen);
    });
  });
}
