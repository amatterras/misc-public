// Notes page zoom range: zooming out reaches a thousandth of "fit page",
// zooming in keeps its old limit, content stays exactly where it was in
// document coordinates, and Fit page recovers the view at any point.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_application_1/features/notes/notebook_layout.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repo implements CanvasRepository {
  final documents = <String, CanvasDocument>{};
  @override
  Future<void> delete(String id) async {}
  @override
  Future<CanvasDocument?> load(String id) async => documents[id];
  @override
  Future<List<CanvasSummary>> listCanvases() async => const [];
  @override
  Future<int> newestSchema() async => CanvasDocument.schemaVersion;
  @override
  Future<int> oldestSchema() async => CanvasDocument.schemaVersion;
  @override
  Future<void> save(CanvasDocument document) async =>
      documents[document.id] = document;
}

Rect pageBox(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byKey(const ValueKey('notebook-page-0')),
        matching: find.byType(CustomPaint),
      )
      .first,
);

void main() {
  test('zoom limits: a thousandth out, the old limit in, always finite', () {
    expect(NotebookZoom.min, lessThanOrEqualTo(1 / 1000));
    expect(NotebookZoom.max, 3.0);
    expect(NotebookZoom.clampZoom(0), NotebookZoom.min);
    expect(NotebookZoom.clampZoom(-5), NotebookZoom.min);
    expect(NotebookZoom.clampZoom(99), 3.0);
    expect(NotebookZoom.clampZoom(double.nan), 1.0);
    expect(NotebookZoom.clampZoom(double.infinity), 1.0);
    expect(NotebookZoom.clampScale(0), NotebookZoom.minScale);
    expect(NotebookZoom.clampScale(0.5 * NotebookZoom.min), greaterThan(0));
    // Stepping out from fit reaches the minimum, and back in reaches fit.
    var z = 1.0;
    var steps = 0;
    while (z > NotebookZoom.min && steps < 100) {
      z = NotebookZoom.step(z, inward: false);
      steps++;
    }
    expect(z, NotebookZoom.min);
    expect(steps, lessThan(25));
    expect(NotebookZoom.label(1), '100%');
    expect(NotebookZoom.label(0.001), '0.10%');
    expect(NotebookZoom.label(0.05), '5.0%');
  });

  testWidgets('zoom out to 1/1000, content untouched, Fit page recovers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1700, 1050);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final root = Directory.systemTemp.createTempSync('theapp_zoom_range_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    final ws = Workspace(Directory('${root.path}/data'));
    final state = AppState(
      canvases: _Repo(),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    addTearDown(state.dispose);
    state.capture.fetchPreviews = false;
    await tester.runAsync(state.init);
    final note = state.workspace.createNote(title: 'Range');
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

    // Write a stroke at 100%.
    state.openNotebooks.single.tool = CanvasTool.pen;
    final page = pageBox(tester);
    final c0 = page.intersect(Offset.zero & const Size(1700, 1050)).center;
    final pen = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
      pointer: 5,
    );
    await pen.down(c0 - const Offset(60, 0));
    await pen.moveTo(c0 + const Offset(0, 30));
    await pen.moveTo(c0 + const Offset(60, 0));
    await pen.up();
    await tester.pump();
    final controller = state.openNotebooks.single;
    final strokeBefore = controller.items.whereType<StrokeItem>().single.points
        .map((p) => p.offset)
        .toList();
    final fitScale = controller.scale;

    // Zoom out all the way (and keep pressing).
    for (var i = 0; i < 30; i++) {
      await tester.tap(find.byTooltip('Smaller pages'));
      await tester.pump();
    }
    expect(find.text('0.10%'), findsOneWidget);
    expect(controller.scale, closeTo(fitScale * 0.001, fitScale * 1e-6));
    expect(controller.scale.isFinite, isTrue);
    // The whole page is a tiny object in the workspace.
    final tiny = pageBox(tester);
    expect(tiny.width, lessThan(2));
    expect(tiny.width, greaterThan(0));
    // Nothing in the document changed.
    expect(
      controller.items.whereType<StrokeItem>().single.points.map((p) => p.offset),
      strokeBefore,
    );

    // Zoom back in a little, then Fit page restores exactly.
    await tester.tap(find.byTooltip('Larger pages'));
    await tester.pump();
    expect(find.text('0.10%'), findsNothing);
    await tester.tap(find.byTooltip('Fit page width'));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    expect(controller.scale, closeTo(fitScale, 1e-9));
    final back = pageBox(tester);
    expect(back.width, closeTo(page.width, 0.5));

    // The old zoom-in limit is unchanged.
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.byTooltip('Larger pages'));
      await tester.pump();
    }
    expect(find.text('300%'), findsOneWidget);

    // Closed and reopened: still the same ink, at its document coordinates.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
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
    final reopened = state.openNotebooks.single;
    expect(
      reopened.items.whereType<StrokeItem>().single.points.map((p) => p.offset),
      strokeBefore,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
