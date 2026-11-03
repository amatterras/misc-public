// Regression tests for defects found in the code audit (October 2026):
// inbound capture, pen/finger handling on touch screens, the lasso tool and
// the phone-width layout.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_page.dart';
import 'package:flutter_application_1/features/capture/capture_service.dart';
import 'package:flutter_application_1/features/capture/send_to.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

final sep = Platform.pathSeparator;

// A valid 1x1 PNG.
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_audit_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('inbound capture', () {
    late Workspace ws;
    late CaptureService capture;
    setUp(() async {
      ws = Workspace(dir);
      await ws.load();
      capture = CaptureService(ws, fetchPreviews: false);
    });
    tearDown(() => ws.dispose());

    test('every shared photo gets its own Inbox item', () async {
      final files = [
        for (final n in ['a', 'b', 'c'])
          (File(
            '${dir.path}$sep$n.png',
          )..writeAsBytesSync([...png, n.codeUnitAt(0)])).path,
      ];
      final items = await capture.captureInbound(files: files);
      expect(items, hasLength(3));
      expect(ws.inbox.all, hasLength(3));
      final assets = items.map((i) => ws.assets[i.assetId]).toList();
      expect(assets.every((a) => a?.kind == AssetKind.image), isTrue);
      expect(assets.map((a) => a!.id).toSet(), hasLength(3));
      // No photo was imported without a place to find it.
      expect(
        ws.assets.all.where((a) => a.kind == AssetKind.image),
        hasLength(3),
      );
    });

    test(
      'text that comes with a link is kept; a repeated link is not',
      () async {
        var items = await capture.captureInbound(
          url: 'https://example.com/a',
          text: 'read this later',
        );
        expect(items, hasLength(2));
        expect(ws.inbox.all.any((i) => i.text == 'read this later'), isTrue);

        items = await capture.captureInbound(
          url: 'https://example.com/a',
          text: 'https://example.com/a',
        );
        expect(items, hasLength(1), reason: 'text only repeats the link');
        final links = ws.assets.all.where((a) => a.kind == AssetKind.link);
        expect(links, hasLength(1), reason: 'same link, same record');
      },
    );

    test('a Send-to request is only removed once its item is saved', () async {
      final bridge = SendToBridge(dir);
      await bridge.forward(['saved before the request goes']);
      expect(await bridge.processRequests(capture), 1);
      expect(await bridge.requestsDir.list().isEmpty, isTrue);
      // A crash right now must not lose it: read the files as a new launch.
      final again = Workspace(dir);
      await again.load();
      expect(
        again.inbox.all.map((i) => i.text),
        contains('saved before the request goes'),
      );
      again.dispose();
    });

    test('untrusted text is capped; other schemes are ignored', () async {
      final items = await capture.captureInbound(text: 'x' * 50000);
      expect(items.single.text!.length, CaptureService.maxInboundText);

      final bridge = SendToBridge(dir);
      expect(
        await bridge.handleUri(
          Uri.parse('https://evil.example/capture?text=hi'),
          capture,
        ),
        isEmpty,
      );
      final viaLink = await bridge.handleUri(
        Uri.parse(
          'theapp://capture?url=https%3A%2F%2Fexample.com%2Fb&text=note',
        ),
        capture,
      );
      expect(viaLink, hasLength(2));
    });
  });

  group('canvas controller', () {
    CanvasController make(List<CanvasItem> items) => CanvasController(
      document: CanvasDocument(
        id: 'c1',
        title: 'T',
        items: items,
        updatedAt: DateTime(2026),
        viewport: const CanvasViewport(),
        schema: 3,
      ),
      onSave: (_) async {},
      saveDelay: const Duration(milliseconds: 5),
    );

    void drag(
      CanvasController c,
      List<Offset> path, {
      PointerDeviceKind kind = PointerDeviceKind.mouse,
    }) {
      c.pointerDown(path.first, kind: kind);
      for (final p in path.skip(1)) {
        c.pointerMove(p);
      }
      c.pointerUp();
    }

    test('lassoed items can be moved with the lasso tool', () {
      final c = make([
        TextItem(
          id: 'n',
          position: const Offset(100, 100),
          width: 200,
          minHeight: 40,
          text: 'x',
        ),
      ]);
      final screenNote = c.toScreen(const Offset(150, 110));
      c.tool = CanvasTool.lasso;
      final p = c.toScreen(const Offset(50, 50));
      drag(c, [
        p,
        p + const Offset(400, 0),
        p + const Offset(400, 200),
        p + const Offset(0, 200),
        p,
      ]);
      expect(c.selection, {'n'});
      drag(c, [
        screenNote,
        screenNote + const Offset(60, 0),
        screenNote + const Offset(100, 0),
      ]);
      final moved = (c.itemById('n') as TextItem).position;
      expect(moved.dx, closeTo(100 + 100 / c.scale, 1));
      expect(c.selection, {'n'}, reason: 'still selected after the move');
      expect(c.tool, CanvasTool.lasso);
    });

    test('the back of a stylus erases whatever tool is chosen', () {
      final c = make(const []);
      c.tool = CanvasTool.pen;
      final a = c.toScreen(const Offset(0, 0));
      drag(c, [a, a + const Offset(50, 0), a + const Offset(100, 0)]);
      expect(c.items.whereType<StrokeItem>(), hasLength(1));
      drag(c, [
        a + const Offset(50, -20),
        a + const Offset(50, 0),
        a + const Offset(50, 20),
      ], kind: PointerDeviceKind.invertedStylus);
      expect(c.items.whereType<StrokeItem>(), isEmpty);
      expect(c.tool, CanvasTool.pen);
    });
  });

  group('app on screen', () {
    late AppState state;

    Future<void> boot(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ws = Workspace(dir);
      state = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      state.capture.fetchPreviews = false;
      await tester.runAsync(state.init);
      await tester.pumpWidget(TheApp(state: state));
      await tester.pump();
    }

    Future<void> shutDown(WidgetTester tester) async {
      await waitForBothClocks(tester, state.flush, what: 'Saving');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      state.dispose();
    }

    Future<CanvasController> emptyCanvas(WidgetTester tester) async {
      state.goTo(AppPage.canvas);
      await tester.pump();
      await tester.pump();
      final c = state.canvas!;
      c.selectAll();
      c.deleteSelection();
      c.tool = CanvasTool.pen;
      await tester.pump();
      return c;
    }

    double strokeSpan(StrokeItem s) {
      final xs = s.points.map((p) => p.offset.dx);
      return xs.reduce((a, b) => a > b ? a : b) -
          xs.reduce((a, b) => a < b ? a : b);
    }

    testWidgets('lifting the palm does not end the pen stroke', (tester) async {
      await boot(tester, const Size(1600, 1000));
      final c = await emptyCanvas(tester);
      final mid = tester.getCenter(find.byType(CanvasPage));

      final pen = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        pointer: 11,
      );
      await pen.down(mid);
      await pen.moveTo(mid + const Offset(40, 0));
      final palm = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 12,
      );
      await palm.down(mid + const Offset(0, 150));
      await palm.moveTo(mid + const Offset(10, 160));
      await palm.up();
      await pen.moveTo(mid + const Offset(120, 0));
      await pen.moveTo(mid + const Offset(200, 0));
      await pen.up();
      await tester.pump();

      final strokes = c.items.whereType<StrokeItem>().toList();
      expect(strokes, hasLength(1));
      expect(strokeSpan(strokes.single), greaterThan(180 / c.scale));
      await shutDown(tester);
    });

    testWidgets('a finger stroke is kept when the pen touches down', (
      tester,
    ) async {
      await boot(tester, const Size(1600, 1000));
      final c = await emptyCanvas(tester);
      final mid = tester.getCenter(find.byType(CanvasPage));

      final finger = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 21,
      );
      await finger.down(mid + const Offset(0, -100));
      await finger.moveTo(mid + const Offset(60, -100));
      await finger.moveTo(mid + const Offset(120, -100));
      final pen = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        pointer: 22,
      );
      await pen.down(mid + const Offset(0, 100));
      await pen.moveTo(mid + const Offset(80, 100));
      await pen.up();
      await finger.up();
      await tester.pump();

      expect(c.items.whereType<StrokeItem>(), hasLength(2));
      await shutDown(tester);
    });

    testWidgets('phone layout: shared items reach the Archive; pages keep their state', (
      tester,
    ) async {
      await boot(tester, const Size(1280, 800));
      state.goTo(AppPage.notes);
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Search notes'),
        'kept',
      );
      await tester.pump();

      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.pump();
      expect(
        find.text('kept'),
        findsOneWidget,
        reason: 'typed text survives the switch',
      );

      await tester.runAsync(
        () => state.capture.captureToArchive(text: 'from outside'),
      );
      await tester.pump();
      expect(
        state.library.objects.map((o) => o.content),
        ['from outside'],
        reason: 'the shared item is saved in the Archive',
      );
      expect(
        find.byKey(const ValueKey('compact-start-page')),
        findsNothing,
        reason: 'there is no start-page button or Inbox badge any more',
      );

      tester.view.physicalSize = const Size(1280, 800);
      await tester.pump();
      await tester.pump();
      expect(find.text('kept'), findsOneWidget);
      await shutDown(tester);
    });
  });
}
