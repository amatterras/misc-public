// Roadmap Phase 1 (foundations): the three notebook paper templates,
// platform writing defaults, floating windows and Always on top.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/floating_windows.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/paper.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_application_1/features/notes/paper_dialog.dart';
import 'package:flutter_application_1/widgets/floating_layer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_r1_'));
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

  group('notebook paper', () {
    test('exactly three templates exist', () {
      expect(PaperTemplate.values, hasLength(3));
      expect(PaperTemplate.values.map((t) => t.label), [
        'Standard square grid',
        'Larger square grid',
        'Split grid + dot grid',
      ]);
      expect(
        PaperTemplate.largeGrid.defaultGridSpacing,
        greaterThan(PaperTemplate.squareGrid.defaultGridSpacing),
      );
      expect(NotePaper.splitGridFraction, 2 / 5);
    });

    test('settings round-trip, are clamped, and bad data falls back', () {
      final p = NotePaper.of(PaperTemplate.splitGridDots).copyWith(
        gridSpacing: 30,
        dotSpacing: 500, // clamped
        lineColor: paperLineColors[2],
        lineOpacity: 0.3,
        dotColor: paperLineColors[4],
        dotOpacity: 0, // clamped
        dotBackground: paperBackgroundColors[1],
      );
      expect(p.dotSpacing, NotePaper.maxSpacing);
      expect(p.dotOpacity, NotePaper.minOpacity);
      expect(NotePaper.fromJson(p.toJson()), p);
      expect(NotePaper.fromJson(null), isNull);
      final odd = NotePaper.fromJson({
        'template': 'sevenMoreTemplates',
        'gridSpacing': 'x',
        'lineColor': 'red',
      })!;
      expect(odd.template, PaperTemplate.squareGrid);
      expect(odd.gridSpacing, 24);
      expect(odd.lineColor, NotePaper.defaultLine);
    });

    test(
      'a note keeps its paper through save, reload and delete/restore',
      () async {
        var s = await app();
        final note = s.workspace.createNote(title: 'Physics');
        const paper = NotePaper(
          template: PaperTemplate.largeGrid,
          gridSpacing: 52,
          background: 0xFF222429,
        );
        s.workspace.notes.put(
          s.workspace.notes[note.id]!.copyWith(paper: paper),
        );
        await s.flush();
        s.dispose();

        s = await app();
        expect(s.workspace.notes[note.id]!.paper, paper);
        expect(
          Note.fromJson({'id': 'n', 'title': 't'}).paperOrDefault.template,
          PaperTemplate.squareGrid,
        );
        await s.deleteNote(note.id);
        final version = s.workspace.deletedNotes().single;
        final restored = await s.restoreDeletedNote(version.id);
        expect(restored!.paper, paper);
        await s.flush();
        s.dispose();
      },
    );

    testWidgets('the picker previews the three templates and saves a choice', (
      tester,
    ) async {
      final s = (await tester.runAsync(app))!;
      final note = s.workspace.createNote(title: 'Maths');
      await tester.pumpWidget(
        MaterialApp(
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
      for (final t in PaperTemplate.values) {
        expect(find.byKey(ValueKey('paper-${t.name}')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('paper-dot-spacing')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('paper-splitGridDots')));
      await tester.pumpAndSettle();
      expect(
        s.workspace.notes[note.id]!.paper!.template,
        PaperTemplate.splitGridDots,
      );
      // The split template has its own dot-side controls.
      expect(find.byKey(const ValueKey('paper-dot-spacing')), findsOneWidget);
      expect(find.text('Dots (right 3/5)'), findsOneWidget);
      await tester.runAsync(s.flush);
      s.dispose();
    });
  });

  test(
    'Windows and iPhone notebooks start typing; iPad starts with the pen',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(notebookStartsWithPen(const Size(1600, 1000)), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(notebookStartsWithPen(const Size(390, 844)), isFalse); // iPhone
      expect(notebookStartsWithPen(const Size(1180, 820)), isTrue); // iPad
      debugDefaultTargetPlatformOverride = null;
    },
  );

  group('floating windows', () {
    test(
      'fit keeps a window inside the area and at least its minimum size',
      () {
        const min = Size(200, 100);
        expect(
          FloatingWindows.fit(
            const Rect.fromLTWH(900, -50, 300, 50),
            const Size(1000, 800),
            min,
          ),
          const Rect.fromLTWH(700, 0, 300, 100),
        );
        expect(
          FloatingWindows.fit(
            const Rect.fromLTWH(0, 0, 5000, 5000),
            const Size(1000, 800),
            min,
          ),
          const Rect.fromLTWH(0, 0, 1000, 800),
        );
      },
    );

    testWidgets('drag and resize move the window and are remembered', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ws = Workspace(dir);
      final settings = SettingsRepository(ws.store);
      await tester.runAsync(settings.load);
      final windows = FloatingWindows(settings);
      final spec = FloatingWindowSpec(
        id: 'test',
        title: 'Test window',
        initialRect: const Rect.fromLTWH(100, 100, 300, 200),
        builder: (_) => const Center(child: Text('inside')),
      );
      windows.show(spec);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FloatingLayer(windows: windows)),
        ),
      );
      expect(find.text('inside'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('floating-test'))),
        const Offset(100, 100),
      );

      await tester.drag(
        find.byKey(const ValueKey('floating-test-title')),
        const Offset(150, 60),
      );
      await tester.pump();
      final moved = windows.rectOf(spec);
      expect(moved.left, closeTo(250, 20));
      expect(moved.top, closeTo(160, 20));

      await tester.drag(
        find.byKey(const ValueKey('floating-test-resize')),
        const Offset(100, 80),
      );
      await tester.pump();
      final resized = windows.rectOf(spec);
      expect(resized.width, closeTo(400, 20));
      expect(resized.height, closeTo(280, 20));
      expect(resized.topLeft, moved.topLeft);

      // Remembered on this device: a fresh start finds the same place.
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await waitForBothClocks(tester, ws.store.flush, what: 'Saving');
      final again = SettingsRepository(Workspace(dir).store);
      await tester.runAsync(again.load);
      expect(FloatingWindows(again).rectOf(spec), resized);

      windows.close('test');
      await tester.pump();
      expect(find.text('inside'), findsNothing);
    });
  });

  test('Always on top is a device setting applied at start', () async {
    var s = await app();
    final applied = <bool>[];
    s.applyAlwaysOnTop = (on) {
      applied.add(on);
      return true;
    };
    expect(s.alwaysOnTop, isFalse);
    await s.setAlwaysOnTop(true);
    expect(s.alwaysOnTop, isTrue);
    expect(applied, Platform.isWindows ? [true] : isEmpty);
    await s.flush();
    s.dispose();

    s = await app();
    expect(s.alwaysOnTop, isTrue);
    await s.flush();
    s.dispose();
  });
}
