// Collapsible pen / highlighter / eraser settings. Acceptance criteria:
//  1. Panels start folded, and choosing a tool leaves its panel folded.
//  2. Tapping the chosen tool again opens its panel; again folds it.
//  3. Choosing another tool folds the previous panel (any way the tool
//     changes: a button, a keyboard shortcut, the squeeze eraser).
//  4. Never more than one panel is open.
//  5. The tool settings (colour, width, eraser mode and size) survive
//     folding, unfolding and switching tools.
//  6. Each pen / highlighter / eraser button shows a chevron that turns
//     over while its panel is open; other tools have none.
//  7. Using the toolbar never draws or edits anything on the canvas.
//  8. Repeated fast taps always end in the state the tap count implies.
//  9. The selection actions are not part of this: they stay visible.
import 'package:flutter/material.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_toolbar.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasController make([List<CanvasItem> items = const []]) => CanvasController(
  document: CanvasDocument(
    id: 'c',
    title: 'Ink',
    items: items,
    updatedAt: DateTime(2026),
    viewport: const CanvasViewport(),
    schema: 3,
  ),
  onSave: (_) async {},
);

Future<void> pump(WidgetTester tester, CanvasController c) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: c,
          builder: (context, _) => Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 24,
                child: Center(
                  child: CanvasContextBar(
                    controller: c,
                    onActivate: (_) {},
                    onRefreshLink: (_) {},
                  ),
                ),
              ),
              Positioned(
                left: 24,
                top: 0,
                bottom: 0,
                child: Center(
                  child: SingleChildScrollView(
                    child: CanvasToolbar(
                      controller: c,
                      onAddImage: () {},
                      onAddLink: () {},
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> tap(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
}

// One marker control per panel.
final penPanel = find.byKey(const ValueKey('canvas-shapes'));
final highlighterPanel = find.byTooltip('Highlighter width');
final eraserPanel = find.byKey(const ValueKey('eraser-panel'));

int openPanels() => [penPanel, highlighterPanel, eraserPanel]
    .where((f) => f.evaluate().isNotEmpty)
    .length;

const pen = 'Draw  (P)';
const highlighter = 'Highlighter';
const eraser = 'Eraser — removes drawings  (E)';

void main() {
  testWidgets('panels start folded and stay folded when a tool is chosen', (
    tester,
  ) async {
    final c = make();
    await pump(tester, c);
    expect(openPanels(), 0);
    for (final tool in [pen, highlighter, eraser]) {
      await tap(tester, tool);
      expect(openPanels(), 0, reason: 'choosing $tool leaves it folded');
      expect(c.optionsExpanded, isFalse);
    }
  });

  testWidgets('tapping the chosen tool again opens, and again folds', (
    tester,
  ) async {
    final c = make();
    await pump(tester, c);
    await tap(tester, pen);
    await tap(tester, pen);
    expect(c.tool, CanvasTool.pen);
    expect(penPanel, findsOneWidget);
    expect(openPanels(), 1);
    await tap(tester, pen);
    expect(penPanel, findsNothing);
    expect(c.tool, CanvasTool.pen, reason: 'folding does not change the tool');

    await tap(tester, highlighter);
    await tap(tester, highlighter);
    expect(highlighterPanel, findsWidgets);
    await tap(tester, highlighter);
    expect(highlighterPanel, findsNothing);

    await tap(tester, eraser);
    await tap(tester, eraser);
    expect(eraserPanel, findsOneWidget);
    await tap(tester, eraser);
    expect(eraserPanel, findsNothing);
  });

  testWidgets('choosing another tool folds the previous panel', (tester) async {
    final c = make();
    await pump(tester, c);
    await tap(tester, pen);
    await tap(tester, pen);
    expect(penPanel, findsOneWidget);

    await tap(tester, highlighter);
    expect(openPanels(), 0);
    expect(c.optionsExpanded, isFalse);

    // Coming back to the pen does not bring its old panel back.
    await tap(tester, pen);
    expect(openPanels(), 0);

    // Keyboard shortcuts and the squeeze eraser change the tool directly.
    await tap(tester, pen);
    expect(penPanel, findsOneWidget);
    c.tool = CanvasTool.eraser;
    await tester.pumpAndSettle();
    expect(openPanels(), 0);
    expect(c.optionsExpanded, isFalse);
  });

  testWidgets('never two panels at once', (tester) async {
    final c = make();
    await pump(tester, c);
    for (final tool in [pen, highlighter, eraser, pen, eraser, highlighter]) {
      await tap(tester, tool);
      expect(openPanels(), lessThanOrEqualTo(1));
      await tap(tester, tool);
      expect(openPanels(), lessThanOrEqualTo(1));
    }
    // The controller cannot even be asked to open a panel for no tool.
    c.tool = CanvasTool.text;
    c.setOptionsExpanded(true);
    expect(c.optionsExpanded, isFalse);
  });

  testWidgets('tool settings survive folding, opening and switching', (
    tester,
  ) async {
    final c = make();
    await pump(tester, c);
    c.setPen(color: const Color(0xFFD64545), width: 5);
    c.setHighlighter(color: const Color(0xFF3DA5D9), width: 26);
    c.setEraser(mode: EraserMode.partial, size: 32);

    for (final tool in [pen, highlighter, eraser, pen, highlighter, eraser]) {
      await tap(tester, tool);
      await tap(tester, tool);
      await tap(tester, tool);
    }
    expect(c.penColor, const Color(0xFFD64545));
    expect(c.penWidth, 5);
    expect(c.highlighterColor, const Color(0xFF3DA5D9));
    expect(c.highlighterWidth, 26);
    expect(c.eraserMode, EraserMode.partial);
    expect(c.eraserSize, 32);
  });

  testWidgets('settings can be changed from the open panel', (tester) async {
    final c = make();
    await pump(tester, c);
    await tap(tester, eraser);
    await tap(tester, eraser);
    await tap(tester, 'Erase whole strokes');
    expect(c.eraserMode, EraserMode.stroke);
    await tap(tester, 'Erase only the part under the eraser');
    expect(c.eraserMode, EraserMode.partial);
    expect(eraserPanel, findsOneWidget, reason: 'a change keeps it open');
  });

  testWidgets('chevron on the three tools turns over with the panel', (
    tester,
  ) async {
    final c = make();
    await pump(tester, c);
    expect(find.byKey(const ValueKey('tool-chevron-closed')), findsNWidgets(3));
    expect(find.byKey(const ValueKey('tool-chevron-open')), findsNothing);
    await tap(tester, pen);
    await tap(tester, pen);
    expect(find.byKey(const ValueKey('tool-chevron-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-chevron-closed')), findsNWidgets(2));
    // The open one is the pen's.
    final penButton = find.ancestor(
      of: find.byKey(const ValueKey('tool-chevron-open')),
      matching: find.byType(ToolButton),
    );
    expect(tester.widget<ToolButton>(penButton).tooltip, pen);
    await tap(tester, pen);
    expect(find.byKey(const ValueKey('tool-chevron-open')), findsNothing);
  });

  testWidgets('using the toolbar never draws or edits', (tester) async {
    final c = make();
    await pump(tester, c);
    for (final tool in [pen, pen, pen, highlighter, highlighter, eraser]) {
      await tap(tester, tool);
    }
    expect(c.items, isEmpty);
    expect(c.liveStroke, isNull);
    expect(c.canUndo, isFalse);
  });

  testWidgets('rapid repeated taps end in the state the count implies', (
    tester,
  ) async {
    final c = make();
    await pump(tester, c);
    await tap(tester, pen); // chosen, folded
    for (var i = 1; i <= 7; i++) {
      await tester.tap(find.byTooltip(pen));
      await tester.pump(const Duration(milliseconds: 20));
      expect(c.optionsExpanded, i.isOdd, reason: 'after tap $i');
    }
    await tester.pumpAndSettle();
    expect(penPanel, findsOneWidget);
  });

  testWidgets('selection actions are not affected', (tester) async {
    const text = TextItem(
      id: 't',
      position: Offset(10, 10),
      width: 200,
      minHeight: 30,
      text: 'hello',
    );
    final c = make([text]);
    await pump(tester, c);
    c.tool = CanvasTool.select;
    c.select(['t']);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Delete  (Del)'), findsOneWidget);
    expect(openPanels(), 0);
  });
}
