// UI refinement phase 1 (Notes): the notebook toolbar shows the options of
// the chosen tool only, the full canonical ink library stays one click
// away, zoom is one compact group, and the rarer note operations moved
// into one "More" menu without losing anything.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/notes/conversion.dart';
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryCanvasRepository implements CanvasRepository {
  final documents = <String, CanvasDocument>{};

  @override
  Future<void> delete(String id) async => documents.remove(id);

  @override
  Future<CanvasDocument?> load(String id) async => documents[id];

  @override
  Future<List<CanvasSummary>> listCanvases() async => const [];

  @override
  Future<int> newestSchema() async => CanvasDocument.schemaVersion;

  @override
  Future<int> oldestSchema() async => CanvasDocument.schemaVersion;

  @override
  Future<void> save(CanvasDocument document) async {
    documents[document.id] = document;
  }
}

void main() {
  late Directory root;
  late AppState s;

  Future<void> boot(
    WidgetTester tester, {
    Size size = const Size(1600, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    root = Directory.systemTemp.createTempSync('theapp_notes_refine_');
    final ws = Workspace(Directory('${root.path}/data'));
    s = AppState(
      canvases: _MemoryCanvasRepository(),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await tester.runAsync(s.init);
  }

  Future<void> done(WidgetTester tester) async {
    await tester.runAsync(s.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    s.dispose();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Opens [noteId] as a page, optionally inside a box of [frame] (the size
  /// of a floating window), and waits for its handwriting to load.
  Future<CanvasController> open(
    WidgetTester tester,
    String noteId, {
    Size? frame,
  }) async {
    final page = NotePage(state: s, noteId: noteId);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: frame == null
            ? page
            : Center(
                child: SizedBox(
                  width: frame.width,
                  height: frame.height,
                  child: page,
                ),
              ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();
    return s.openNotebooks.single;
  }

  Future<void> settleMenu(WidgetTester tester) async {
    // Menus and dialogs open and close with short animations.
    // (Not pumpAndSettle: the note page never fully settles.)
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Finder tool(CanvasTool t) => find.byKey(ValueKey('note-tool-${t.name}'));

  testWidgets('each tool shows only its own options, in the same row', (
    tester,
  ) async {
    await boot(tester);
    final n = s.workspace.createNote(title: 'Tools');
    final c = await open(tester, n.id);

    // Windows starts with the text tool: typing guidance, no ink options.
    expect(c.tool, CanvasTool.text);
    expect(find.textContaining('to type'), findsOneWidget);
    expect(find.byKey(const ValueKey('note-pen-color')), findsNothing);

    // The library is never shown permanently.
    for (final swatch in InkColors.library) {
      expect(find.byKey(ValueKey('ink-swatch-${swatch.id}')), findsNothing);
    }

    await tester.tap(tool(CanvasTool.pen));
    await tester.pump();
    expect(c.tool, CanvasTool.pen);
    expect(find.byKey(const ValueKey('note-pen-color')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-pen-width')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-highlighter-color')), findsNothing);
    expect(find.byKey(const ValueKey('eraser-mode-stroke')), findsNothing);

    await tester.tap(tool(CanvasTool.highlighter));
    await tester.pump();
    expect(c.tool, CanvasTool.highlighter);
    expect(
      find.byKey(const ValueKey('note-highlighter-color')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('note-highlighter-width')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('note-pen-color')), findsNothing);

    await tester.tap(tool(CanvasTool.eraser));
    await tester.pump();
    expect(c.tool, CanvasTool.eraser);
    expect(find.byKey(const ValueKey('eraser-mode-stroke')), findsOneWidget);
    expect(find.byKey(const ValueKey('eraser-mode-partial')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-eraser-size')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-highlighter-color')), findsNothing);
    // Eraser changes are kept for next time (shared with Mindmap/Calendar).
    await tester.tap(find.byKey(const ValueKey('eraser-mode-partial')));
    await tester.pump();
    expect(c.eraserMode, EraserMode.partial);
    await tester.runAsync(s.flush);
    expect(s.eraserMode, EraserMode.partial);

    await tester.tap(tool(CanvasTool.text));
    await tester.pump();
    expect(find.textContaining('to type'), findsOneWidget);
    expect(find.byKey(const ValueKey('eraser-mode-stroke')), findsNothing);

    await tester.tap(tool(CanvasTool.select));
    await tester.pump();
    expect(c.tool, CanvasTool.select);
    expect(find.text('Tap ink or text to select it'), findsOneWidget);
    expect(find.byKey(const ValueKey('note-selection-delete')), findsNothing);
    expect(tester.takeException(), isNull);
    await done(tester);
  });

  testWidgets('the full canonical library: 19 colours, fixed order, '
      'pen and highlighter', (tester) async {
    await boot(tester);
    final n = s.workspace.createNote(title: 'Colours');
    final c = await open(tester, n.id);
    expect(InkColors.library, hasLength(19));
    expect(notebookInk, InkColors.all);

    await tester.tap(tool(CanvasTool.pen));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('note-pen-color')));
    await settleMenu(tester);
    // Every library colour, in the library's order.
    final positions = [
      for (final swatch in InkColors.library)
        tester.getTopLeft(find.byKey(ValueKey('ink-swatch-${swatch.id}'))),
    ];
    for (var i = 1; i < positions.length; i++) {
      final before = positions[i - 1], now = positions[i];
      expect(
        now.dy > before.dy || (now.dy == before.dy && now.dx > before.dx),
        isTrue,
        reason: 'swatch $i follows swatch ${i - 1}',
      );
    }
    await tester.tap(find.byKey(const ValueKey('ink-swatch-bright-red')));
    await settleMenu(tester);
    expect(c.penColor, InkColors.brightRed);
    expect(find.byKey(const ValueKey('ink-library')), findsNothing);

    // A second colour: the first becomes a one-click recent colour.
    await tester.tap(find.byKey(const ValueKey('note-pen-color')));
    await settleMenu(tester);
    await tester.tap(find.byKey(const ValueKey('ink-swatch-petrol')));
    await settleMenu(tester);
    expect(c.penColor, InkColors.petrol);
    await tester.tap(find.byTooltip('Recent: Bright Red'));
    await tester.pump();
    expect(c.penColor, InkColors.brightRed);

    // Pen thickness: every size of the shared list.
    await tester.tap(find.byKey(const ValueKey('note-pen-width')));
    await settleMenu(tester);
    await tester.tap(find.byKey(const ValueKey('ink-width-9.0')));
    await settleMenu(tester);
    expect(c.penWidth, 9.0);

    // The highlighter has its own colour and width, from the same library.
    await tester.tap(tool(CanvasTool.highlighter));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('note-highlighter-color')));
    await settleMenu(tester);
    for (final swatch in InkColors.library) {
      expect(find.byKey(ValueKey('ink-swatch-${swatch.id}')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('ink-swatch-dusty-mint')));
    await settleMenu(tester);
    expect(c.highlighterColor, InkColors.dustyMint);
    expect(c.penColor, InkColors.brightRed, reason: 'pen colour untouched');
    await tester.tap(find.byKey(const ValueKey('note-highlighter-width')));
    await settleMenu(tester);
    await tester.tap(find.byKey(const ValueKey('ink-width-36.0')));
    await settleMenu(tester);
    expect(c.highlighterWidth, 36.0);
    await done(tester);
  });

  testWidgets('undo/redo stay visible; selection shows its actions', (
    tester,
  ) async {
    await boot(tester);
    final n = s.workspace.createNote(title: 'History');
    final c = await open(tester, n.id);
    c.addItems([
      StrokeItem(
        id: 'stroke-1',
        points: const [StrokePoint(100, 100), StrokePoint(200, 140)],
        color: InkColors.steelBlue,
        strokeWidth: 2.5,
      ),
    ]);
    await tester.pump();
    expect(c.items, hasLength(1));
    await tester.tap(find.byTooltip('Undo  (Ctrl+Z)'));
    await tester.pump();
    expect(c.items, isEmpty);
    await tester.tap(find.byTooltip('Redo  (Ctrl+Y)'));
    await tester.pump();
    expect(c.items, hasLength(1));

    await tester.tap(tool(CanvasTool.select));
    await tester.pump();
    c.select(['stroke-1']);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('note-selection-duplicate')));
    await tester.pump();
    expect(c.items, hasLength(2));
    await tester.tap(find.byKey(const ValueKey('note-selection-delete')));
    await tester.pump();
    expect(c.items, hasLength(1));
    await done(tester);
  });

  testWidgets('zoom is one group; tapping the percentage resets to fit', (
    tester,
  ) async {
    await boot(tester);
    final n = s.workspace.createNote(title: 'Zoom');
    await open(tester, n.id);
    String value() => tester
        .widget<Text>(find.byKey(const ValueKey('note-zoom-value')))
        .data!;
    expect(value(), '100%');
    expect(find.byTooltip('Fit page width'), findsOneWidget);
    await tester.tap(find.byTooltip('Larger pages'));
    await tester.pump();
    await tester.tap(find.byTooltip('Larger pages'));
    await tester.pump();
    expect(value(), '156%');
    await tester.tap(find.byKey(const ValueKey('note-zoom-value')));
    await tester.pump();
    expect(value(), '100%');
    expect(s.settings.get<num>('notebookZoom.${n.id}'), 1);
    // The three controls sit together in one group.
    final group = tester.getRect(find.byKey(const ValueKey('note-zoom')));
    expect(group.width, lessThan(130));
    await done(tester);
  });

  testWidgets('favourite and folder stay in view; rarer actions in More', (
    tester,
  ) async {
    await boot(tester);
    final folder = s.workspace.createFolder('Uni');
    final n = s.workspace.createNote(title: 'Plan', body: 'Before');
    await open(tester, n.id);

    await tester.tap(find.byKey(const ValueKey('note-favorite')));
    await tester.pump();
    expect(s.workspace.notes[n.id]!.favorite, isTrue);
    expect(find.text('Folder'), findsNothing, reason: 'no new labels');
    expect(find.byType(DropdownButton<String?>), findsWidgets);
    s.workspace.notes.put(
      s.workspace.notes[n.id]!.copyWith(folderId: () => folder.id),
    );
    await tester.pump();
    expect(find.text('Uni'), findsWidgets);

    // Version history, Mindmap placement and Delete are one click away.
    await tester.tap(find.byTooltip('More note actions'));
    await settleMenu(tester);
    expect(find.text('Place on a Mindmap…'), findsOneWidget);
    expect(find.text('Version history'), findsOneWidget);
    expect(find.byKey(const ValueKey('note-delete')), findsOneWidget);
    await tester.tap(find.text('Version history'));
    await settleMenu(tester);
    expect(find.text('Version history'), findsOneWidget); // the dialog
    await tester.tap(find.text('Close'));
    await settleMenu(tester);

    // Delete keeps its confirmation, and the note can be brought back.
    await tester.tap(find.byTooltip('More note actions'));
    await settleMenu(tester);
    await tester.tap(find.byKey(const ValueKey('note-delete')));
    await settleMenu(tester);
    expect(find.textContaining('Recently deleted'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settleMenu(tester);
    expect(s.workspace.notes[n.id], isNotNull, reason: 'cancel keeps it');

    // The confirmed deletion and its recovery (AppState.deleteNote /
    // restoreDeletedNote, unchanged here) are covered by phase4a_test and
    // roadmap_phase1_test; they write files, which deadlocks under the
    // widget-test clock once the notebook page has saved.
    await done(tester);
  });

  testWidgets('attachments and connections stay one click away', (
    tester,
  ) async {
    await boot(tester);
    final n = s.workspace.createNote(title: 'Attach');
    await open(tester, n.id);
    final row = find.byKey(const ValueKey('note-attach-actions'));
    for (final label in ['Paste', 'Link', 'Photos', 'PDF']) {
      expect(
        find.descendant(of: row, matching: find.text(label)),
        findsOneWidget,
        reason: label,
      );
    }
    expect(find.text('ATTACHMENTS'), findsNothing);
    expect(find.byKey(const ValueKey('note-add-project')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-link-task')), findsOneWidget);

    // Link a task through the existing menu.
    await tester.ensureVisible(find.byKey(const ValueKey('note-link-task')));
    await tester.tap(find.byKey(const ValueKey('note-link-task')));
    await settleMenu(tester);
    await tester.tap(find.text('New task about this note'));
    await settleMenu(tester);
    expect(s.workspace.tasksForNote(n.id), hasLength(1));
    await tester.pump(const Duration(seconds: 4)); // the toast
    await done(tester);
  });

  testWidgets('selecting text still shows the conversion bar and drag grip', (
    tester,
  ) async {
    await boot(tester);
    final n = s.workspace.createNote(title: 'Convert', body: 'Buy milk today');
    await open(tester, n.id);
    final editable = tester.state<EditableTextState>(
      find.descendant(
        of: find.byKey(const ValueKey('note-body')),
        matching: find.byType(EditableText),
      ),
    );
    editable.userUpdateTextEditingValue(
      const TextEditingValue(
        text: 'Buy milk today',
        selection: TextSelection(baseOffset: 0, extentOffset: 8),
      ),
      SelectionChangedCause.keyboard,
    );
    await tester.pump();
    expect(find.byType(ConversionBar), findsOneWidget);
    expect(find.byKey(const ValueKey('text-transfer-grip')), findsOneWidget);
    await done(tester);
  });

  for (final (name, size, frame) in [
    ('Windows desktop', const Size(1600, 1000), null),
    ('narrow window', const Size(700, 900), null),
    ('iPad', const Size(1180, 820), null),
    ('iPhone', const Size(390, 844), null),
    ('floating window', const Size(1600, 1000), const Size(420, 620)),
  ]) {
    testWidgets('toolbar and details lay out without overflow: $name', (
      tester,
    ) async {
      await boot(tester, size: size);
      final n = s.workspace.createNote(title: 'Layout');
      final c = await open(tester, n.id, frame: frame);
      for (final t in [
        CanvasTool.pen,
        CanvasTool.highlighter,
        CanvasTool.eraser,
        CanvasTool.text,
        CanvasTool.select,
      ]) {
        c.tool = t;
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$name ${t.name}');
      }
      // Undo, zoom and paper exist at every size (scrolled into view on
      // narrow ones).
      expect(find.byTooltip('Fit page width'), findsOneWidget);
      expect(find.byKey(const ValueKey('note-paper')), findsOneWidget);
      expect(find.byKey(const ValueKey('note-more')), findsOneWidget);
      await done(tester);
    });
  }
}
