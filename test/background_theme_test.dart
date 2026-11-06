// Mindmap dots and Notes paper follow the theme; their size and opacity do not.
//
// Root cause found in the audit: the Mindmap painter drew its dots in a
// hard-coded white (invisible on the light canvas), and every note stores a
// dark page and dark grid colour of its own (0xFF191A1D / 0xFF41444A), which
// the paper painter drew as stored in any theme. BackgroundPalette is now the
// one place that maps theme -> colours; it is applied while drawing and never
// written to a note.
import 'dart:io';
import 'dart:typed_data' show ByteData;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/background_palette.dart';
import 'package:flutter_application_1/app/theme.dart' show AppColors;
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/paper.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_painter.dart';
import 'package:flutter_application_1/features/notes/paper_dialog.dart';
import 'package:flutter_application_1/features/notes/paper_painter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CanvasController controller() => CanvasController(
    document: CanvasDocument(
      id: 'c1',
      title: 'T',
      items: const [],
      updatedAt: DateTime(2026),
      viewport: const CanvasViewport(),
      schema: 3,
    ),
    onSave: (_) async {},
    saveDelay: const Duration(milliseconds: 5),
  );

  /// Renders [paint] into a [size] image and returns its RGBA bytes.
  Future<ByteData> render(
    WidgetTester tester,
    Size size,
    void Function(Canvas, Size) paint,
  ) async {
    final bytes = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      paint(Canvas(recorder), size);
      final image = await recorder.endRecording().toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!;
    });
    return bytes!;
  }

  /// (r, g, b, a) of the pixel at [x], [y].
  List<int> pixel(ByteData d, int width, int x, int y) {
    final i = (y * width + x) * 4;
    return [for (var k = 0; k < 4; k++) d.getUint8(i + k)];
  }

  group('BackgroundPalette', () {
    test('light: black dots, white paper, black lines; dark: as before', () {
      expect(BackgroundPalette.dot(light: true), const Color(0xFF000000));
      expect(BackgroundPalette.dot(light: false), const Color(0xFFFFFFFF));
      const stored = NotePaper(
        gridSpacing: 40,
        lineOpacity: 0.3,
        dotSpacing: 18,
        dotOpacity: 0.7,
        template: PaperTemplate.splitGridDots,
      );
      final light = BackgroundPalette.paperFor(stored, light: true);
      expect(light.background, 0xFFFFFFFF);
      expect(light.dotBackground, 0xFFFFFFFF);
      expect(light.lineColor, 0xFF000000);
      expect(light.dotColor, 0xFF000000);
      // the user's own settings come through untouched
      expect(light.gridSpacing, 40);
      expect(light.lineOpacity, 0.3);
      expect(light.dotSpacing, 18);
      expect(light.dotOpacity, 0.7);
      expect(light.template, PaperTemplate.splitGridDots);
      // dark: exactly the stored paper (the established dark colours)
      expect(
        identical(BackgroundPalette.paperFor(stored, light: false), stored),
        isTrue,
      );
      expect(stored.background, NotePaper.defaultBackground);
    });

    test('resolving never changes what would be saved', () {
      const stored = NotePaper(gridSpacing: 33, lineOpacity: 0.41);
      final before = stored.toJson();
      BackgroundPalette.paperFor(stored, light: true);
      expect(stored.toJson(), before);
      expect(NotePaper.fromJson(before), stored);
    });
  });

  group('Mindmap dots', () {
    // The painter fills the canvas colour first, so the theme the app is in
    // (AppColors.mode) and the theme the dots are drawn for must agree, as
    // they do in the app.
    Future<(List<int> dot, List<int> background)> dotAndBackground(
      WidgetTester tester, {
      required bool light,
      double opacity = 0.4,
      double size = 5,
    }) async {
      AppColors.mode = light ? ThemeMode.light : ThemeMode.dark;
      addTearDown(() => AppColors.mode = ThemeMode.dark);
      final c = controller()
        ..setDotOpacity(opacity)
        ..setDotSize(size);
      final data = await render(
        tester,
        const Size(100, 100),
        (canvas, s) => CanvasPainter(c, lightTheme: light).paint(canvas, s),
      );
      c.dispose();
      // dots are on a 24 px grid starting at the origin; (12, 12) is empty
      return (pixel(data, 100, 24, 24), pixel(data, 100, 12, 12));
    }

    testWidgets('light theme: the dots are black (darker than the canvas)', (
      tester,
    ) async {
      final (dot, bg) = await dotAndBackground(tester, light: true);
      expect(dot[0], lessThan(bg[0]));
      expect(dot[1], lessThan(bg[1]));
      expect(dot[2], lessThan(bg[2]));
      // black at 40%: every channel is 60% of the canvas's
      expect(dot[0], closeTo(bg[0] * 0.6, 3));
    });

    testWidgets('dark theme: the dots are white (lighter than the canvas)', (
      tester,
    ) async {
      final (dot, bg) = await dotAndBackground(tester, light: false);
      expect(dot[0], greaterThan(bg[0]));
      // white at 40%: bg + 40% of the way to 255
      expect(dot[0], closeTo(bg[0] + (255 - bg[0]) * 0.4, 3));
    });

    testWidgets('the same opacity gives the same strength in both themes', (
      tester,
    ) async {
      final (ld, lb) = await dotAndBackground(
        tester,
        light: true,
        opacity: 0.2,
        size: 4,
      );
      final (dd, db) = await dotAndBackground(
        tester,
        light: false,
        opacity: 0.2,
        size: 4,
      );
      expect((lb[0] - ld[0]) / lb[0], closeTo(0.2, 0.03));
      expect((dd[0] - db[0]) / (255 - db[0]), closeTo(0.2, 0.03));
    });

    test('a theme change repaints (the painter knows the theme)', () {
      final c = controller();
      final light = CanvasPainter(c, lightTheme: true);
      final dark = CanvasPainter(c, lightTheme: false);
      expect(dark.shouldRepaint(light), isTrue);
      expect(light.shouldRepaint(CanvasPainter(c, lightTheme: true)), isFalse);
      c.dispose();
    });
  });

  group('Notes paper', () {
    // A 1 px line on an integer coordinate is spread over two pixels, so the
    // strength of a line is the sum of both.
    int darkness(ByteData d, int x, int y) =>
        (255 - pixel(d, 100, x - 1, y)[0]) + (255 - pixel(d, 100, x, y)[0]);

    testWidgets('light: white page, black grid; dark: the stored dark page', (
      tester,
    ) async {
      const paper = NotePaper(gridSpacing: 24, lineOpacity: 1);
      const size = Size(100, 100);
      final light = await render(
        tester,
        size,
        (canvas, s) => PaperPainter(paper, light: true).paint(canvas, s),
      );
      expect(pixel(light, 100, 5, 5), [255, 255, 255, 255]);
      // black line at full opacity: the two pixels together are fully dark
      expect(darkness(light, 24, 5), closeTo(255, 2));
      expect(pixel(light, 100, 24, 5).take(3).toSet().length, 1);

      final dark = await render(
        tester,
        size,
        (canvas, s) => PaperPainter(paper, light: false).paint(canvas, s),
      );
      expect(pixel(dark, 100, 5, 5), [0x19, 0x1A, 0x1D, 255]);
      // the stored dark grid colour is lighter than the dark page
      expect(pixel(dark, 100, 24, 5)[0], greaterThan(0x19));
    });

    testWidgets("grid size and opacity are the user's in either theme", (
      tester,
    ) async {
      const paper = NotePaper(gridSpacing: 40, lineOpacity: 0.5);
      const size = Size(100, 100);
      final light = await render(
        tester,
        size,
        (canvas, s) => PaperPainter(paper, light: true).paint(canvas, s),
      );
      // black at 50% over white: the pair of pixels holds half a line
      expect(darkness(light, 40, 5), closeTo(255 * 0.5, 3));
      // no line at the default 24 px spacing
      expect(pixel(light, 100, 24, 5), [255, 255, 255, 255]);
    });

    test('a theme change repaints', () {
      const paper = NotePaper();
      expect(
        PaperPainter(
          paper,
          light: true,
        ).shouldRepaint(PaperPainter(paper, light: false)),
        isTrue,
      );
    });
  });

  group('settings stay apart from the theme', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('theapp_bgtheme_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    AppState make() {
      final ws = Workspace(dir);
      return AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      )..capture.fetchPreviews = false;
    }

    test('dot size/opacity survive theme switches and a restart', () async {
      final s = make();
      await s.init();
      final c = controller();
      await s.setDotSize(c, 3.2);
      await s.setDotOpacity(c, 0.3);
      final surface = s.dotSurfaceOf(c);
      await s.setThemeMode('light');
      await s.setThemeMode('dark');
      await s.setThemeMode('light');
      expect(s.dotSizeFor(surface), closeTo(3.2, 1e-9));
      expect(s.dotOpacityFor(surface), closeTo(0.3, 1e-9));
      await s.flush();
      final again = SettingsRepository(Workspace(dir).store);
      await again.load();
      expect(again.get<num>('dotSize.${surface.name}'), 3.2);
      expect(again.get<num>('dotOpacity.${surface.name}'), 0.3);
      expect(again.get<String>('themeMode'), 'light');
      c.dispose();
      s.dispose();
    });

    test('theme changes never touch a saved note', () async {
      final s = make();
      await s.init();
      final note = s.workspace.createNote(title: 'Maths');
      s.workspace.notes.put(
        note.copyWith(
          paper: const NotePaper(gridSpacing: 36, lineOpacity: 0.4),
        ),
      );
      final before = s.workspace.notes[note.id]!.toJson();
      await s.setThemeMode('light');
      await s.setThemeMode('dark');
      await s.flush();
      expect(s.workspace.notes[note.id]!.toJson(), before);
      s.dispose();
    });
  });

  group('paper dialog (existing controls)', () {
    Future<AppState> boot(WidgetTester tester) async {
      final dir = Directory.systemTemp.createTempSync('theapp_bgdlg_');
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
      )..capture.fetchPreviews = false;
      await tester.runAsync(s.init);
      return s;
    }

    for (final light in [true, false]) {
      testWidgets('${light ? 'light' : 'dark'}: size and opacity are there', (
        tester,
      ) async {
        final s = await boot(tester);
        final note = s.workspace.createNote(title: 'Maths');
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: light ? Brightness.light : Brightness.dark,
            ),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPaperDialog(context, s, note.id),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('paper-grid-spacing')),
          findsOneWidget,
        );
        expect(find.text('Line opacity'), findsOneWidget);
        expect(find.text('Line color'), light ? findsNothing : findsOneWidget);
        expect(
          find.byKey(const ValueKey('paper-light-note')),
          light ? findsOneWidget : findsNothing,
        );
        await tester.runAsync(s.flush);
        s.dispose();
      });
    }
  });
}
