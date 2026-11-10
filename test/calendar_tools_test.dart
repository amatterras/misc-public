// Calendar drawing tools on the iPad layout: Lasso, Select, Text, Photo and
// the eraser width, in the 38-day range and in the month, plus month zoom;
// and the rule that photos and items are picked by the Select and Lasso
// tools only. Simulated input (mouse / touch pointer events); nothing here
// proves anything about a real iPad.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_ink.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

/// A real 1×1 PNG (it must pass the importer's signature check).
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState s;

  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_caltools_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> boot(WidgetTester tester, {String? view}) async {
    tester.view.physicalSize = const Size(1180, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ws = Workspace(dir);
    s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await tester.runAsync(s.init);
    if (view != null) {
      await tester.runAsync(() => s.settings.set('calendarView', view));
    }
    s.goTo(AppPage.calendar);
    await tester.pumpWidget(TheApp(state: s));
    for (
      var i = 0;
      i < 20 && find.byType(DayInkLayer).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pump();
  }

  Future<void> shutDown(WidgetTester tester) async {
    await waitForBothClocks(tester, s.flush, what: 'Saving');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    s.dispose();
  }

  CanvasController ink() => s.calendarInk!;
  Finder key(String k) => find.byKey(ValueKey(k));
  Finder anyCell() => find.byType(DayInkLayer).first;

  Future<void> draw(WidgetTester tester, String tool) async {
    if (key('calendar-draw').evaluate().isNotEmpty &&
        key('calendar-tool-eraser').evaluate().isEmpty) {
      await tester.tap(key('calendar-draw'));
      await tester.pump();
    }
    if (tool != 'pen') {
      await tester.tap(key('calendar-tool-$tool'));
      await tester.pump();
    }
  }

  Future<void> mouseDrag(
    WidgetTester tester,
    Offset from,
    List<Offset> path,
  ) async {
    final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    for (final p in path) {
      await g.moveTo(p);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
  }

  group('range view', () {
    testWidgets(
      'the tools are there: lasso, select, text, photo, eraser width',
      (tester) async {
        await boot(tester);
        expect(key('calendar-add-photo'), findsOneWidget);
        await tester.tap(key('calendar-draw'));
        await tester.pump();
        for (final t in ['eraser', 'lasso', 'select', 'text']) {
          expect(key('calendar-tool-$t'), findsOneWidget, reason: t);
        }
        // Eraser: its sizes and a width slider.
        await tester.tap(key('calendar-tool-eraser'));
        await tester.pump();
        expect(ink().tool, CanvasTool.eraser);
        expect(key('eraser-panel'), findsOneWidget);
        await tester.tap(key('calendar-eraser-width'));
        await tester.pumpAndSettle();
        expect(key('eraser-width-slider'), findsOneWidget);
        await tester.tap(key('calendar-eraser-size-56'));
        await tester.pump();
        expect(ink().eraserSize, 56);
        final slider = tester.widget<Slider>(key('eraser-width-slider'));
        expect(slider.value, 56);
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        await shutDown(tester);
      },
    );

    testWidgets(
      'lasso selects what was drawn and the selection can be deleted',
      (tester) async {
        await boot(tester);
        await draw(tester, 'pen');
        final c = tester.getCenter(anyCell());
        await mouseDrag(tester, c, [
          c + const Offset(20, 10),
          c + const Offset(40, 30),
          c + const Offset(60, 10),
        ]);
        expect(ink().items.whereType<StrokeItem>(), hasLength(1));

        await draw(tester, 'lasso');
        expect(ink().tool, CanvasTool.lasso);
        // A loop around the stroke.
        await mouseDrag(tester, c + const Offset(-30, -40), [
          c + const Offset(100, -40),
          c + const Offset(100, 80),
          c + const Offset(-30, 80),
          c + const Offset(-30, -38),
        ]);
        expect(ink().selection, hasLength(1));
        expect(key('calendar-selection-delete'), findsOneWidget);
        await tester.tap(key('calendar-selection-delete'));
        await tester.pump();
        expect(ink().items.whereType<StrokeItem>(), isEmpty);
        await shutDown(tester);
      },
    );

    testWidgets('text: tap a day, type, and it stays on that day', (
      tester,
    ) async {
      await boot(tester);
      await draw(tester, 'text');
      final at = tester.getCenter(anyCell()) + const Offset(-40, -80);
      final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await g.up();
      await tester.pump();
      await tester.pump();
      expect(ink().editingItem, isNotNull);
      expect(key('calendar-text-field'), findsOneWidget);
      await tester.enterText(key('calendar-text-field'), 'Dentist 3pm');
      await tester.pump();
      ink().endEditing();
      await tester.pump();
      final texts = ink().items.whereType<TextItem>().toList();
      expect(texts, hasLength(1));
      expect(texts.single.text, 'Dentist 3pm');
      expect(texts.single.width, 150, reason: 'a day-sized box');
      expect(texts.single.fontSize, 9);
      await shutDown(tester);
    });

    testWidgets('photo: picked, placed on a day, selected for moving', (
      tester,
    ) async {
      await boot(tester);
      final photo = File('${dir.path}${Platform.pathSeparator}pic.png')
        ..writeAsBytesSync(_png);
      s.capture.pickImageFiles = () => [photo.path];
      await tester.tap(key('calendar-add-photo'));
      for (var i = 0; i < 300 && ink().items.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      final images = ink().items.whereType<ImageItem>().toList();
      expect(images, hasLength(1));
      expect(ink().tool, CanvasTool.select);
      expect(ink().selection, {images.single.id});
      // On a real day of the document, not off in space.
      expect(
        inkDayRect(inkDayAt(images.single.position))
            .overlaps(images.single.position & Size(images.single.width, 10)),
        isTrue,
      );
      await shutDown(tester);
    });
  });

  group('month view', () {
    testWidgets('zoom in and out with the buttons; 100% fills the area', (
      tester,
    ) async {
      await boot(tester, view: 'month');
      expect(key('calendar-grid-zoom'), findsOneWidget);
      double scale() => tester
          .widget<InteractiveViewer>(key('calendar-grid-zoom'))
          .transformationController!
          .value
          .getMaxScaleOnAxis();
      expect(scale(), 1);
      expect(find.text('100%'), findsOneWidget);
      final zoomIn = find.descendant(
        of: key('calendar-zoom'),
        matching: find.byIcon(Icons.add),
      );
      final zoomOut = find.descendant(
        of: key('calendar-zoom'),
        matching: find.byIcon(Icons.remove),
      );
      await tester.tap(zoomIn);
      await tester.pump();
      expect(scale(), closeTo(1.25, 0.001));
      await tester.tap(zoomIn);
      await tester.pump();
      expect(scale(), closeTo(1.5625, 0.001));
      expect(find.text('156%'), findsOneWidget);
      await tester.tap(zoomOut);
      await tester.tap(zoomOut);
      await tester.pump();
      expect(scale(), 1);
      await shutDown(tester);
    });

    testWidgets('lasso, text and photo are in the month toolbar too', (
      tester,
    ) async {
      await boot(tester, view: 'month');
      await tester.tap(key('calendar-draw'));
      await tester.pump();
      for (final t in ['eraser', 'lasso', 'select', 'text']) {
        expect(key('calendar-tool-$t'), findsOneWidget, reason: t);
      }
      expect(key('calendar-add-photo'), findsOneWidget);

      // Write text in a month cell.
      await tester.tap(key('calendar-tool-text'));
      await tester.pump();
      final at = tester.getCenter(anyCell()) + const Offset(-20, -10);
      final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await g.up();
      await tester.pump();
      await tester.pump();
      expect(key('calendar-text-field'), findsOneWidget);
      await tester.enterText(key('calendar-text-field'), 'Hi');
      ink().endEditing();
      await tester.pump();
      expect(ink().items.whereType<TextItem>().single.text, 'Hi');
      await shutDown(tester);
    });
  });

  group('only Select and Lasso pick photos and items', () {
    CanvasController withPhoto() {
      final c = CanvasController(
        document: CanvasDocument(
          id: 't',
          title: 't',
          items: [
            ImageItem(
              id: 'img',
              assetId: 'a',
              position: const Offset(100, 100),
              width: 200,
              minHeight: 150,
            ),
          ],
          updatedAt: DateTime(2026),
        ),
        onSave: (_) async {},
      );
      return c;
    }

    test('a tap or press on a photo selects it only with Select / Lasso', () {
      for (final tool in [
        CanvasTool.pen,
        CanvasTool.highlighter,
        CanvasTool.eraser,
        CanvasTool.text,
        CanvasTool.pan,
        CanvasTool.connect,
      ]) {
        final c = withPhoto();
        addTearDown(c.dispose);
        c.tool = tool;
        expect(c.selectsItems, isFalse, reason: '$tool');
        c.pointerDown(const Offset(150, 150));
        c.pointerUp(screen: const Offset(150, 150));
        // (A text box being typed in is the text tool's own; once typing
        // ends nothing stays selected.)
        c.endEditing();
        expect(c.selection, isEmpty, reason: '$tool');
        expect(c.itemById('img'), isNotNull, reason: 'the photo is untouched');
      }
      final c = withPhoto();
      addTearDown(c.dispose);
      c.tool = CanvasTool.select;
      c.pointerDown(const Offset(150, 150));
      c.pointerUp(screen: const Offset(150, 150));
      expect(c.selectsItems, isTrue);
      expect(c.selection, {'img'});
    });

    test('switching away from Select drops the selection', () {
      final c = withPhoto();
      addTearDown(c.dispose);
      c.select(const ['img']);
      c.tool = CanvasTool.pen;
      expect(c.selection, isEmpty);
    });
  });
}
