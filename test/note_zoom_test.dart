import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_application_1/features/notes/notes_page.dart'
    show NoteEditor;
import 'package:flutter_test/flutter_test.dart';

class _EmptyCanvasRepository implements CanvasRepository {
  @override
  Future<void> delete(String id) async {}

  @override
  Future<CanvasDocument?> load(String id) async => null;

  @override
  Future<List<CanvasSummary>> listCanvases() async => const [];

  @override
  Future<int> newestSchema() async => CanvasDocument.schemaVersion;

  @override
  Future<int> oldestSchema() async => CanvasDocument.schemaVersion;

  @override
  Future<void> save(CanvasDocument document) async {}
}

class _MemoryCanvasRepository extends _EmptyCanvasRepository {
  final documents = <String, CanvasDocument>{};

  @override
  Future<CanvasDocument?> load(String id) async => documents[id];

  @override
  Future<void> save(CanvasDocument document) async {
    documents[document.id] = document;
  }
}

void main() {
  testWidgets(
    'note page zoom is visible, bounded, and restored after restart',
    (tester) async {
      tester.view.physicalSize = const Size(1700, 1050);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final root = Directory.systemTemp.createTempSync('theapp_note_zoom_');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });

      Future<AppState> boot() async {
        final ws = Workspace(Directory('${root.path}/data'));
        final state = AppState(
          canvases: _EmptyCanvasRepository(),
          settings: SettingsRepository(ws.store),
          workspace: ws,
          enableSendTo: false,
        );
        state.capture.fetchPreviews = false;
        await tester.runAsync(state.init);
        return state;
      }

      var state = await boot();
      final note = state.workspace.createNote(title: 'Zoom test');
      await tester.runAsync(state.flush);

      Future<void> openPage() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: NotePage(state: state, noteId: note.id),
          ),
        );
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );
        await tester.pumpAndSettle();
      }

      await openPage();
      expect(find.byKey(const ValueKey('note-zoom-value')), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(find.byTooltip('Larger pages'));
      await tester.pump();
      expect(find.text('125%'), findsOneWidget);
      await tester.runAsync(state.flush);
      state.dispose();

      state = await boot();
      addTearDown(() => state.dispose());
      await openPage();
      expect(find.text('125%'), findsOneWidget);

      await tester.tap(find.byTooltip('Fit page width'));
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);
      await tester.runAsync(state.flush);
    },
  );

  testWidgets(
    'iPad finger pinch zooms without adding ink and preserves saved geometry',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1700, 1050);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final root = Directory.systemTemp.createTempSync('theapp_note_pinch_');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });
      final ws = Workspace(Directory('${root.path}/data'));
      final canvases = _MemoryCanvasRepository();
      final state = AppState(
        canvases: canvases,
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      addTearDown(state.dispose);
      state.capture.fetchPreviews = false;
      await tester.runAsync(state.init);
      final note = state.workspace.createNote(title: 'Pinch test');
      await tester.runAsync(state.flush);

      Future<void> open() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: NotePage(state: state, noteId: note.id),
          ),
        );
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );
        await tester.pumpAndSettle();
      }

      await open();
      expect(state.workspace.notes[note.id], isNotNull);
      expect(find.byType(NotePage), findsOneWidget);
      expect(state.openNotebooks, hasLength(1));
      expect(find.byType(NoteEditor), findsOneWidget);
      expect(tester.widget<NoteEditor>(find.byType(NoteEditor)).pageCount, 1);
      final noteList = find.byType(ListView).last;
      final noteScrollable = find.descendant(
        of: noteList,
        matching: find.byType(Scrollable),
      );
      final scrollState = tester.state<ScrollableState>(noteScrollable.first);
      scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final page = tester.getRect(
        find.byKey(const ValueKey('notebook-page-0')),
      );
      final visiblePage = page.intersect(Offset.zero & const Size(1700, 1050));
      expect(visiblePage.isEmpty, isFalse);
      final pageCenter = visiblePage.center;
      final pencil = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        pointer: 80,
      );
      await pencil.down(pageCenter - const Offset(80, 0));
      await pencil.moveTo(pageCenter + const Offset(80, 0));
      await pencil.up();
      await tester.pump();
      final controller = state.openNotebooks.single;
      final points = (controller.items.single as StrokeItem).points;
      final before = points.map((p) => p.offset).toList();
      final beforeMidpoint = (before.first + before.last) / 2;

      final center = pageCenter;
      final left = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 81,
      );
      final right = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 82,
      );
      await left.down(center - const Offset(50, 0));
      await right.down(center + const Offset(50, 0));
      await tester.pump();
      await left.moveTo(center - const Offset(100, 0));
      await right.moveTo(center + const Offset(100, 0));
      await tester.pump();
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsNothing);
      expect(controller.items, hasLength(1));
      expect(
        (controller.items.single as StrokeItem).points.map((p) => p.offset),
        before,
      );
      final zoomedContent = tester.getRect(
        find
            .descendant(
              of: find.byKey(const ValueKey('notebook-page-0')),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
      final mappedMidpoint =
          zoomedContent.topLeft + beforeMidpoint * controller.scale;
      expect(
        (mappedMidpoint - center).distance,
        lessThan(8),
        reason:
            'mapped=$mappedMidpoint, centroid=$center, content=$zoomedContent, '
            'scale=${controller.scale}, doc=$beforeMidpoint',
      );

      // A touch on the page while the Pen tool is selected is navigation only.
      final finger = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 83,
      );
      await finger.down(center);
      await finger.moveTo(center + const Offset(40, 30));
      await finger.up();
      await tester.pump();
      expect(controller.items, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await open();
      final reopened = state.openNotebooks.single;
      expect(
        (reopened.items.single as StrokeItem).points.map((p) => p.offset),
        before,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'Apple Pencil writes while its stream and resting palms cannot scroll',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(640, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final root = Directory.systemTemp.createTempSync('theapp_note_pencil_');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });
      final ws = Workspace(Directory('${root.path}/data'));
      final state = AppState(
        canvases: _MemoryCanvasRepository(),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      addTearDown(state.dispose);
      state.capture.fetchPreviews = false;
      await tester.runAsync(state.init);
      final note = state.workspace.createNote(title: 'Pencil isolation');
      await tester.runAsync(
        () => state.settings.set('notebookZoom.${note.id}', 2.5),
      );
      await tester.runAsync(state.flush);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: NotePage(state: state, noteId: note.id),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
    await tester.pumpAndSettle();

    final verticalList = find.byType(ListView).last;
    final verticalScrollable = find.descendant(
      of: verticalList,
      matching: find.byType(Scrollable),
    );
    tester
        .state<ScrollableState>(verticalScrollable.first)
        .position
        .jumpTo(
          tester
              .state<ScrollableState>(verticalScrollable.first)
              .position
              .maxScrollExtent,
        );
    await tester.pumpAndSettle();
    final page = tester.getRect(
        find.byKey(const ValueKey('notebook-page-0')),
      );
      final visiblePage = page.intersect(Offset.zero & const Size(640, 600));
      expect(visiblePage.isEmpty, isFalse);
      final positions = [
        for (final finder in [
          find.byType(Scrollable).first,
          find.byType(Scrollable).last,
        ])
          tester.state<ScrollableState>(finder).position,
      ];
      final beforeOffsets = positions
          .map((position) => position.pixels)
          .toList();
      final controller = state.openNotebooks.single;
      final beforeScale = controller.scale;
      final start = visiblePage.center;
      final pencil = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        pointer: 181,
      );
      await pencil.down(start);
      await tester.pump();
      final palm = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 182,
      );
      await palm.down(start + const Offset(10, 10));
      await palm.moveTo(start + const Offset(100, 90));
      await pencil.moveTo(start + const Offset(160, 0));
      await tester.pump();
      expect(positions.map((position) => position.pixels), beforeOffsets);
      expect(controller.scale, beforeScale);
      await palm.up();
      await pencil.moveTo(start + const Offset(220, 10));
      await pencil.up();
      await tester.pump();

      expect(controller.items.whereType<StrokeItem>(), hasLength(1));
      final stroke = controller.items.whereType<StrokeItem>().single;
      expect(stroke.points.length, greaterThanOrEqualTo(3));
      expect(positions.map((position) => position.pixels), beforeOffsets);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
