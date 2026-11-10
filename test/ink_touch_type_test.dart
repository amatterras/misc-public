// Tap to type on a note page with a finger (iPad Type tool, iPhone), and
// what a finger must NOT do there: draw, or leave a text box behind when
// it scrolls. Before 2026-11-10 a finger on iOS was refused outright, so
// typing could not be started by touch at all.
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
import 'package:flutter_test/flutter_test.dart';

class _MemoryCanvasRepository implements CanvasRepository {
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
  Future<void> save(CanvasDocument document) async {
    documents[document.id] = document;
  }
}

void main() {
  Future<(CanvasController, Rect)> open(
    WidgetTester tester,
    Size screen, {
    required bool ios,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final root = Directory.systemTemp.createTempSync('theapp_tap_type_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    if (ios) {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    }
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
    final note = state.workspace.createNote(title: 'Tap to type');
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
    // The page lies below the note's text: bring it into view.
    final vertical = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    vertical.position.jumpTo(vertical.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final page = tester
        .getRect(find.byKey(const ValueKey('notebook-page-0')))
        .intersect(Offset.zero & screen);
    return (state.openNotebooks.single, page);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    debugDefaultTargetPlatformOverride = null;
  }

  for (final (name, size) in const [
    ('iPad', Size(1024, 768)),
    ('iPhone', Size(390, 844)),
  ]) {
    testWidgets('$name: a finger tap with the Type tool places text; a '
        'scrolling finger does not; a finger never draws', (tester) async {
      final (c, page) = await open(tester, size, ios: true);
      c.tool = CanvasTool.text;
      await tester.pump();
      final at = page.center;

      // A finger that moves (scrolling the note) leaves nothing behind.
      final scroll = await tester.createGesture(kind: PointerDeviceKind.touch);
      await scroll.down(at);
      await scroll.moveBy(const Offset(0, -60));
      await scroll.up();
      await tester.pumpAndSettle();
      expect(c.items.whereType<TextItem>(), isEmpty);
      expect(c.editingId, isNull);

      // A long press is not a tap either.
      final hold = await tester.createGesture(kind: PointerDeviceKind.touch);
      await hold.down(at);
      await tester.pump(const Duration(milliseconds: 700));
      await hold.up(timeStamp: const Duration(milliseconds: 700));
      await tester.pump();
      expect(c.items.whereType<TextItem>(), isEmpty);

      // A tap places a text box and starts typing in it.
      await tester.tapAt(at);
      await tester.pump();
      expect(c.items.whereType<TextItem>(), hasLength(1));
      expect(c.editingId, c.items.whereType<TextItem>().single.id);
      c.endEditing();
      await tester.pump();

      // With the pen chosen, a finger neither draws nor types.
      c.tool = CanvasTool.pen;
      await tester.pump();
      final before = c.items.length;
      await tester.tapAt(at + const Offset(0, 40));
      final finger = await tester.createGesture(kind: PointerDeviceKind.touch);
      await finger.down(at + const Offset(20, 20));
      await finger.moveBy(const Offset(30, 0));
      await finger.up();
      await tester.pumpAndSettle();
      expect(c.items.length, before);
      expect(c.items.whereType<StrokeItem>(), isEmpty);

      // The Pencil still draws.
      final pencil = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await pencil.down(at + const Offset(-40, 60));
      await pencil.moveBy(const Offset(30, 5));
      await pencil.moveBy(const Offset(30, 5));
      await pencil.up();
      await tester.pump();
      expect(c.items.whereType<StrokeItem>(), hasLength(1));
      c.cancelPendingLineStraightening();
      await close(tester);
    });
  }

  testWidgets('Windows: the Type tool still types where the finger or '
      'mouse goes down', (tester) async {
    final (c, page) = await open(tester, const Size(1200, 800), ios: false);
    expect(c.tool, CanvasTool.text);
    await tester.tapAt(page.center, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(c.items.whereType<TextItem>(), hasLength(1));
    await close(tester);
  });
}
