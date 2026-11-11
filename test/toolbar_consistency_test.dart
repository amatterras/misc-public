// The canvas tool panels and the navigation capsule are one design system:
// same glass surface, same thickness, same icon size, same selected / hover
// treatment. Acceptance criteria:
//  - a vertical tool panel is exactly as wide as the sidebar capsule
//  - a horizontal one is exactly as tall
//  - every control is a 36 px chip with a 20 px icon
//  - the selected tool is tinted + accent-coloured; the others are muted
//  - a disabled control is faint and does not react
//  - the panels use the shared GlassSurface (blur), not a solid card
//  - the layout holds at narrow and wide windows
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_toolbar.dart';
import 'package:flutter_application_1/widgets/glass_surface.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasController make() => CanvasController(
  document: CanvasDocument(
    id: 'c',
    title: 'Ink',
    items: const [],
    updatedAt: DateTime(2026),
    viewport: const CanvasViewport(),
    schema: 3,
  ),
  onSave: (_) async {},
);

Future<void> pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(child: child),
        ),
      ),
    ),
  );
}

CanvasToolbar bar(CanvasController c, {bool horizontal = false}) =>
    CanvasToolbar(
      controller: c,
      horizontal: horizontal,
      onAddImage: () {},
      onAddLink: () {},
    );

void main() {
  testWidgets('vertical panels are as wide as the sidebar capsule', (
    tester,
  ) async {
    await pump(tester, bar(make()));
    final panels = find.byType(ToolPanel);
    expect(panels, findsNWidgets(2));
    for (final element in panels.evaluate()) {
      final size = tester.getSize(find.byWidget(element.widget));
      expect(size.width, ChromeMetrics.thickness);
    }
  });

  testWidgets('horizontal panel is as tall as the capsule is wide', (
    tester,
  ) async {
    await pump(tester, bar(make(), horizontal: true));
    expect(tester.getSize(find.byType(ToolPanel)).height, 60);
  });

  testWidgets('panels are the shared glass surface, not a solid card', (
    tester,
  ) async {
    await pump(tester, bar(make()));
    expect(find.byType(GlassSurface), findsNWidgets(2));
    expect(find.byType(BackdropFilter), findsNWidgets(2));
  });

  testWidgets('controls are 36 px chips with 20 px icons', (tester) async {
    await pump(tester, bar(make()));
    final buttons = find.byType(ToolButton);
    expect(buttons, findsWidgets);
    for (final element in buttons.evaluate()) {
      final chip = find.descendant(
        of: find.byWidget(element.widget),
        matching: find.byWidgetPredicate(
          (w) =>
              w is SizedBox &&
              w.width == ChromeMetrics.chip &&
              w.height == ChromeMetrics.chip,
        ),
      );
      expect(chip, findsOneWidget);
    }
    // Every glyph is drawn at the shared icon size.
    // (The small expand chevron on the pen, highlighter and eraser is a
    // separate, deliberately smaller mark.)
    for (final icon in tester.widgetList<Icon>(
      find.descendant(of: buttons, matching: find.byType(Icon)),
    )) {
      if (icon.icon == Icons.expand_more) continue;
      expect(icon.size, ChromeMetrics.icon);
    }
  });

  testWidgets('selected tool: accent icon and tint; others muted', (
    tester,
  ) async {
    final c = make()..tool = CanvasTool.pen;
    await pump(tester, bar(c));
    Color? iconColor(String tip) {
      final b = find.descendant(
        of: find.byTooltip(tip),
        matching: find.byType(IconTheme),
      );
      return IconTheme.of(tester.element(b.last)).color;
    }

    expect(iconColor('Draw  (P)'), AppColors.accent);
    expect(iconColor('Lasso select  (L)'), AppColors.textMuted);
    final pen = find.descendant(
      of: find.byTooltip('Draw  (P)'),
      matching: find.byType(Material),
    );
    final material = tester.widget<Material>(pen.first);
    expect(material.color, AppColors.accentSoft);
  });

  testWidgets('a disabled control is faint and does nothing', (tester) async {
    final c = make();
    await pump(tester, bar(c));
    final undo = find.byTooltip('Undo  (Ctrl+Z)');
    final theme = tester.element(
      find.descendant(of: undo, matching: find.byType(IconTheme)).last,
    );
    expect(IconTheme.of(theme).color, AppColors.textFaint);
    final ink = tester.widget<InkWell>(
      find.descendant(of: undo, matching: find.byType(InkWell)),
    );
    expect(ink.onTap, isNull);
  });

  testWidgets('tapping a tool still selects it', (tester) async {
    final c = make();
    await pump(tester, bar(c));
    await tester.tap(find.byTooltip('Draw  (P)'));
    await tester.pump();
    expect(c.tool, CanvasTool.pen);
    await tester.tap(find.byTooltip('Highlighter'));
    await tester.pump();
    expect(c.tool, CanvasTool.highlighter);
  });

  testWidgets('the selected tool shows the slim edge marker, once', (
    tester,
  ) async {
    final c = make()..tool = CanvasTool.eraser;
    await pump(tester, bar(c));
    final markers = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).gradient == AppGradients.brand,
    );
    expect(markers, findsOneWidget);
  });

  for (final size in const [Size(700, 520), Size(1600, 1000)]) {
    testWidgets('no overflow at ${size.width.round()}x${size.height.round()}', (
      tester,
    ) async {
      await pump(tester, bar(make()), size: size);
      expect(tester.takeException(), isNull);
      await pump(tester, bar(make(), horizontal: true), size: size);
      expect(tester.takeException(), isNull);
    });
  }
}
