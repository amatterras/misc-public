// Notes page zoom range. Product decision (2026-11-04, ui/new-design):
// zooming out stops where the tallest page is fully visible with about
// 2.5 cm around it (never below; the earlier "a thousandth of fit page"
// from master was superseded). Zooming in keeps its old limit (300%),
// content stays exactly where it was in document coordinates, Fit page
// recovers the view, pinch obeys the same limits, and the zoom is restored
// when the note is opened again. NotebookZoom remains the safety clamp for
// saved and pinched values (finite, never zero).
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

  testWidgets('zoom out stops with the whole page in view; content '
      'untouched; Fit page, pinch and reopening behave', (tester) async {
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
    final strokeBefore = controller.items
        .whereType<StrokeItem>()
        .single
        .points
        .map((p) => p.offset)
        .toList();
    final fitScale = controller.scale;

    // Zoom out all the way (and keep pressing past the limit).
    String label() => tester
        .widget<Text>(find.byKey(const ValueKey('note-zoom-value')))
        .data!;
    for (var i = 0; i < 30; i++) {
      await tester.tap(find.byTooltip('Smaller pages'), warnIfMissed: false);
      await tester.pump();
    }
    final minLabel = label();
    final minScale = controller.scale;
    expect(minScale.isFinite, isTrue);
    expect(minScale, lessThan(fitScale), reason: 'it did zoom out');
    // The whole page is in view with room around it (not a dot).
    final whole = pageBox(tester);
    final view = tester.getRect(
      find.byKey(const ValueKey('notebook-page-0')).first,
    );
    expect(whole.width, greaterThan(100), reason: 'still a readable page');
    expect(whole.height, lessThanOrEqualTo(1050), reason: 'fits the window');
    expect(view.width, greaterThan(0));
    // More presses change nothing.
    await tester.tap(find.byTooltip('Smaller pages'), warnIfMissed: false);
    await tester.pump();
    expect(label(), minLabel);
    expect(controller.scale, closeTo(minScale, 1e-9));
    // Nothing in the document changed.
    expect(
      controller.items.whereType<StrokeItem>().single.points.map(
        (p) => p.offset,
      ),
      strokeBefore,
    );

    // Pinching further in (fingers together) also stops at the limit.
    final f1 = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 11,
    );
    final f2 = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 12,
    );
    final mid = whole.center;
    await f1.down(mid - const Offset(150, 0));
    await f2.down(mid + const Offset(150, 0));
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      await f1.moveTo(mid - Offset(150 - i * 13.0, 0));
      await f2.moveTo(mid + Offset(150 - i * 13.0, 0));
      await tester.pump();
    }
    await f1.up();
    await f2.up();
    await tester.pump();
    expect(controller.scale, greaterThanOrEqualTo(minScale - 1e-9));
    expect(label(), minLabel);

    // Zoom back in a little, then Fit page restores exactly.
    await tester.tap(find.byTooltip('Larger pages'));
    await tester.pump();
    expect(label(), isNot(minLabel));
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
    // Leave it at 300%: the zoom is restored when the note opens again.

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
    expect(label(), '300%', reason: 'saved zoom restored');
    expect(
      reopened.items.whereType<StrokeItem>().single.points.map((p) => p.offset),
      strokeBefore,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
