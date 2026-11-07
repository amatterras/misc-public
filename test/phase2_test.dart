// Phase 2: one writing engine for Canvas and note pages, notes as pages,
// PDF annotation, Apple Pencil input (pressure, prediction, squeeze,
// draw-and-hold straight lines). The Swift side (PDFKit, UIPencilInteraction)
// is checked here only through a SIMULATED channel.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/ink/stroke_geometry.dart';
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_application_1/features/notes/notebook_layout.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

CanvasDocument rt(CanvasDocument d) => CanvasDocument.fromJson(
  jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>,
);

CanvasController make({
  List<CanvasItem> items = const [],
  String id = 'c1',
  String? kind,
  List<CanvasDocument>? saved,
}) => CanvasController(
  document: CanvasDocument(
    id: id,
    title: 'Test',
    items: items,
    updatedAt: DateTime(2026),
    kind: kind,
  ),
  onSave: (doc) async => saved?.add(doc),
  saveDelay: const Duration(milliseconds: 10),
);

StrokeItem dot(String id, double x, double y) => StrokeItem(
  id: id,
  points: [StrokePoint(x, y)],
  color: const Color(0xFF000000),
  strokeWidth: 2,
);

/// Draws with the Pencil from [from] through [points] (screen positions).
void pencil(CanvasController c, Offset from, List<Offset> points) {
  c.pointerDown(from, kind: PointerDeviceKind.stylus, pressure: 0.3);
  var t = 0;
  for (final p in points) {
    t += 8;
    c.pointerMove(p, pressure: 0.7, timeStamp: Duration(milliseconds: t));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stroke format', () {
    test('a pressure stroke keeps its pressures and flag through JSON', () {
      final s = StrokeItem(
        id: 's',
        points: const [StrokePoint(0, 0, 0.2), StrokePoint(10, 5, 0.9)],
        color: const Color(0xFF112233),
        strokeWidth: 3,
        pressureWidth: true,
      );
      expect(s.toJson()['pw'], true);
      final back = CanvasItem.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      ) as StrokeItem;
      expect(back.pressureWidth, isTrue);
      expect(back.points.map((p) => p.pressure), [0.2, 0.9]);
      expect(back.translated(const Offset(1, 1)), isA<StrokeItem>());
      expect(back.translated(const Offset(1, 1)).pressureWidth, isTrue);
    });

    test('older strokes (no flag, no pressure) load unchanged', () {
      final old = {
        'type': 'stroke',
        'id': 'old',
        'points': [
          [1, 2],
          [3, 4, 0.5],
        ],
        'color': 0xFF000000,
        'width': 2,
      };
      final s = CanvasItem.fromJson(old) as StrokeItem;
      expect(s.pressureWidth, isFalse);
      expect(s.points.first.pressure, 0.5);
      // Written back without a new key, so older app versions read it.
      expect(s.toJson().containsKey('pw'), isFalse);
    });

    test('pressure is normalized (iOS force up to ~4.2, mice report 0..1)', () {
      expect(normalizedPressure(2.1, 4.2), closeTo(0.5, 1e-9));
      expect(normalizedPressure(9, 4.2), 1);
      expect(normalizedPressure(0.3, 1), 0.3);
      expect(pressureFactor(0), lessThan(pressureFactor(1)));
    });

    test('a pressure outline is wider where the pen pressed harder', () {
      Path line(double p) => pressureOutline([
        StrokePoint(0, 0, p),
        StrokePoint(50, 0, p),
        StrokePoint(100, 0, p),
      ], 4);
      expect(
        line(1).getBounds().height,
        greaterThan(line(0).getBounds().height),
      );
    });
  });

  group('live ink layer', () {
    test('drawing repaints only the live layer, not the whole canvas', () {
      final c = make();
      c.tool = CanvasTool.pen;
      var whole = 0, live = 0;
      c.addListener(() => whole++);
      c.liveInk.addListener(() => live++);
      c.pointerDown(const Offset(10, 10), kind: PointerDeviceKind.stylus);
      final afterDown = whole;
      for (var i = 1; i <= 20; i++) {
        c.pointerMove(
          Offset(10 + i * 3, 10),
          // A Pencil that reports pressure (it varies while writing).
          pressure: 0.3 + i / 100,
          timeStamp: Duration(milliseconds: i * 8),
        );
      }
      expect(whole, afterDown, reason: 'moves must not rebuild everything');
      expect(live, greaterThanOrEqualTo(20));
      c.pointerUp();
      expect(c.items.whereType<StrokeItem>(), hasLength(1));
      expect(c.items.single.toJson()['pw'], true, reason: 'Pencil stroke');
      c.dispose();
    });

    test('prediction is short, ahead of the pen and off after lifting', () {
      final c = make();
      c.tool = CanvasTool.pen;
      pencil(c, const Offset(0, 0), [
        for (var i = 1; i <= 10; i++) Offset(i * 5.0, 0),
      ]);
      final p = c.predictedPoint!;
      expect(p.dx, greaterThan(50));
      expect(p.dx - 50, lessThanOrEqualTo(12.0001));
      c.pointerUp();
      expect(c.predictedPoint, isNull);
      // The prediction is never stored.
      final stroke = c.items.single as StrokeItem;
      expect(stroke.points.last.x, 50);
      c.dispose();
    });

    test('a mouse stroke keeps one width (old behaviour)', () {
      final c = make();
      c.tool = CanvasTool.pen;
      c.pointerDown(const Offset(0, 0));
      c.pointerMove(const Offset(40, 0));
      c.pointerUp();
      expect((c.items.single as StrokeItem).pressureWidth, isFalse);
      c.dispose();
    });
  });

  group('idle line straightening', () {
    testWidgets(
      'a line straightens exactly after 1.2 idle seconds and undoes',
      (tester) async {
        final c = make();
        c.tool = CanvasTool.pen;
        pencil(c, Offset.zero, [
          for (var i = 1; i <= 20; i++) Offset(i * 10.0, i.isEven ? 3 : -3),
        ]);
        c.pointerUp();
        final original = c.items.single as StrokeItem;
        await tester.pump(const Duration(milliseconds: 1199));
        expect(identical(c.items.single, original), isTrue);
        await tester.pump(const Duration(milliseconds: 1));
        final straight = c.items.single as StrokeItem;
        expect(straight.points.first.offset, Offset.zero);
        expect(straight.points.last.offset, const Offset(200, 3));
        expect(straight.points.length, greaterThan(2));
        for (final point in straight.points) {
          expect(
            distanceToSegment(point.offset, Offset.zero, const Offset(200, 3)),
            lessThan(1e-6),
          );
        }
        expect(
          (rt(c.document).items.single as StrokeItem).points
              .map((point) => point.offset)
              .toList(),
          straight.points.map((point) => point.offset).toList(),
        );
        c.undo();
        expect(c.items.single, same(original));
        c.redo();
        expect(
          (c.items.single as StrokeItem).points.length,
          straight.points.length,
        );
        c.dispose();
      },
    );

    testWidgets('curves, scribbles, short lines and taps remain unchanged', (
      tester,
    ) async {
      final c = make();
      c.tool = CanvasTool.pen;
      pencil(c, const Offset(50, 0), [
        for (var a = 0; a <= 12; a++)
          Offset(
            50 + 30 * math.cos(a / 12 * 6.28),
            30 * math.sin(a / 12 * 6.28),
          ),
      ]);
      c.pointerUp();
      pencil(c, const Offset(0, 100), [
        const Offset(40, 100),
        const Offset(20, 100),
        const Offset(60, 100),
      ]);
      c.pointerUp();
      pencil(c, const Offset(0, 200), [const Offset(15, 200)]);
      c.pointerUp();
      c.pointerDown(const Offset(300, 300), kind: PointerDeviceKind.stylus);
      c.pointerUp();
      await tester.pump(const Duration(seconds: 3));
      expect(c.items, hasLength(4));
      expect((c.items[0] as StrokeItem).points.length, greaterThan(10));
      expect((c.items[1] as StrokeItem).points.length, greaterThan(2));
      expect((c.items[2] as StrokeItem).points.length, 2);
      expect((c.items[3] as StrokeItem).points.length, 1);
      c.dispose();
    });

    testWidgets('movement resets dwell and a tool switch cancels it', (
      tester,
    ) async {
      final c = make();
      c.tool = CanvasTool.pen;
      pencil(c, Offset.zero, [for (var i = 1; i <= 10; i++) Offset(i * 10, 0)]);
      await tester.pump(const Duration(milliseconds: 1100));
      c.pointerMove(const Offset(110, 0));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(c.lineStraightenPreview, isNull);
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.lineStraightenPreview, isNotNull);
      c.pointerUp();
      expect(c.lineStraightenPreview, isNull);

      pencil(c, Offset.zero, [for (var i = 1; i <= 10; i++) Offset(i * 10, 0)]);
      c.pointerUp();
      c.tool = CanvasTool.select;
      await tester.pump(const Duration(seconds: 3));
      expect(c.lineStraightenPreview, isNull);
      c.dispose();
    });

    testWidgets('disposing the controller removes its pending timer', (
      tester,
    ) async {
      final c = make();
      c.tool = CanvasTool.pen;
      pencil(c, Offset.zero, [for (var i = 1; i <= 10; i++) Offset(i * 10, 0)]);
      c.pointerUp();
      final original = c.items.single;
      c.dispose();
      await tester.pump(const Duration(seconds: 3));
      expect(c.items.single, same(original));
    });
  });
  group('Apple Pencil Pro squeeze', () {
    test('eraser while squeezed, then the tool before', () {
      final c = make();
      c.tool = CanvasTool.highlighter;
      c.squeezeBegan();
      expect(c.tool, CanvasTool.eraser);
      expect(c.squeezeEraser, isTrue);
      c.squeezeEnded();
      expect(c.tool, CanvasTool.highlighter);
      expect(c.squeezeEraser, isFalse);
      c.dispose();
    });

    test('already on the eraser: squeeze changes nothing', () {
      final c = make();
      c.tool = CanvasTool.eraser;
      c.squeezeBegan();
      c.squeezeEnded();
      expect(c.tool, CanvasTool.eraser);
      c.dispose();
    });

    test('picking a tool during the squeeze keeps that tool', () {
      final c = make();
      c.tool = CanvasTool.pen;
      c.squeezeBegan();
      c.tool = CanvasTool.text;
      c.squeezeEnded();
      expect(c.tool, CanvasTool.text);
      c.dispose();
    });

    test('a second "began" does not lose the original tool', () {
      final c = make();
      c.tool = CanvasTool.pen;
      c.squeezeBegan();
      c.squeezeBegan();
      c.squeezeEnded();
      expect(c.tool, CanvasTool.pen);
      c.squeezeEnded(); // a late "cancelled" is harmless
      expect(c.tool, CanvasTool.pen);
      c.dispose();
    });

    test('ending after the view closed does not throw', () {
      final c = make();
      c.tool = CanvasTool.pen;
      c.squeezeBegan();
      c.dispose();
      expect(c.squeezeEnded, returnsNormally);
    });
  });

  group('note pages', () {
    test('a new note has one page', () {
      expect(NotebookLayout().pageCount, 1);
    });

    test('a single dot on the last page adds exactly one blank page', () {
      final top1 = NotebookLayout().pageRect(1).top;
      expect(
        NotebookLayout(content: [Rect.fromLTWH(400, 500, 1, 1)]).pageCount,
        2,
      );
      expect(
        NotebookLayout(content: [Rect.fromLTWH(400, top1 + 10, 1, 1)])
            .pageCount,
        3,
      );
      // More ink on the same page adds nothing more.
      expect(
        NotebookLayout(
          content: [
            Rect.fromLTWH(400, 500, 1, 1),
            Rect.fromLTWH(10, 20, 300, 300),
          ],
        ).pageCount,
        2,
      );
    });

    test('pages are worked out from content: no blank records, no growth', () {
      final c = make(id: notebookIdFor('n1'), kind: 'notebook');
      int pages() => NotebookLayout(
        backgrounds: c.pageBackgrounds,
        content: NotebookLayout.contentOf(c.items, c.itemBounds),
      ).pageCount;
      // Scrolling / looking at pages changes nothing.
      for (var i = 0; i < 5; i++) {
        c.setView(Offset(0, -i * 1000.0), 1);
        expect(pages(), 1);
      }
      c.tool = CanvasTool.pen;
      c.setView(Offset.zero, 1);
      c.pointerDown(const Offset(100, 100), kind: PointerDeviceKind.stylus);
      c.pointerUp();
      expect(pages(), 2);
      expect(c.items, hasLength(1), reason: 'only the dot is stored');
      // Reopened: same pages, nothing lost or duplicated.
      final again = CanvasController(
        document: rt(c.document),
        onSave: (_) async {},
      );
      expect(again.items.map((i) => i.id), c.items.map((i) => i.id));
      expect(
        NotebookLayout(
          content: NotebookLayout.contentOf(again.items, again.itemBounds),
        ).pageCount,
        2,
      );
      expect(again.isNotebook, isTrue);
      c.dispose();
      again.dispose();
    });

    test('a position in the gap belongs to the page above', () {
      final l = NotebookLayout();
      final bottom = l.pageRect(0).bottom;
      expect(l.pageAt(bottom + NotebookLayout.gap / 2), 0);
      expect(l.pageAt(l.pageRect(1).top + 1), 1);
      expect(l.pageAt(-50), 0);
    });

    test('PDF pages keep their shape and count as content', () {
      const bg = [
        PageBackground(
          pageIndex: 0,
          assetId: 'a',
          pdfPage: 0,
          width: 600,
          height: 300,
        ),
        PageBackground(
          pageIndex: 1,
          assetId: 'a',
          pdfPage: 1,
          width: 612,
          height: 792,
        ),
      ];
      final l = NotebookLayout(backgrounds: bg);
      expect(l.pageCount, 2, reason: 'the PDF pages, nothing added yet');
      final ink = Rect.fromLTWH(10, l.pageRect(1).top + 5, 1, 1);
      expect(
        NotebookLayout(backgrounds: bg, content: [ink]).pageCount,
        3,
        reason: 'writing on the last PDF page adds one blank page',
      );
      expect(l.pageHeight(0), closeTo(NotebookLayout.pageWidth / 2, 1e-9));
      expect(l.pageRect(1).top, l.pageHeight(0) + NotebookLayout.gap);
      expect(l.background(1)!.pdfPage, 1);
    });

    test('page backgrounds and kind survive save and reload', () {
      final saved = <CanvasDocument>[];
      final c = make(id: notebookIdFor('n2'), kind: 'notebook', saved: saved);
      c.setPageBackgrounds(const [
        PageBackground(
          pageIndex: 0,
          assetId: 'pdf1',
          pdfPage: 3,
          width: 612,
          height: 792,
        ),
      ]);
      final back = rt(c.document);
      expect(back.kind, 'notebook');
      expect(back.isNotebook, isTrue);
      expect(back.pageBackgrounds.single.pdfPage, 3);
      expect(back.pageBackgrounds.single.assetId, 'pdf1');
      // A plain canvas file has no new keys.
      expect(make().document.toJson().containsKey('kind'), isFalse);
      c.dispose();
    });
  });

  group('PDF annotation coordinates', () {
    test('ink is converted to PDF points from the page corner', () {
      const bg = PageBackground(
        pageIndex: 1,
        assetId: 'a',
        pdfPage: 0,
        width: 408, // half the notebook page width → scale 0.5
        height: 528,
      );
      final l = NotebookLayout(backgrounds: const [bg]);
      final page = l.pageRect(1);
      final stroke = StrokeItem(
        id: 's',
        points: [
          StrokePoint(page.left + 100, page.top + 200),
          StrokePoint(page.left + 300, page.top + 400),
        ],
        color: const Color(0xFFFF0000),
        strokeWidth: 4,
      );
      final elsewhere = StrokeItem(
        id: 'x',
        points: const [StrokePoint(10, 10), StrokePoint(20, 20)],
        color: const Color(0xFF000000),
        strokeWidth: 4,
      );
      final out = annotationStrokes([stroke, elsewhere], page, bg);
      expect(out, hasLength(1), reason: 'only ink on this page');
      final pts = out.single['points']! as List<List<double>>;
      expect(pts.first, [50, 100, 2]);
      expect(pts.last, [150, 200, 2]);
      expect(out.single['color'], 0xFFFF0000);
    });

    test('annotations stay put when pages are added after them', () {
      final stroke = dot('d', 100, 100);
      final before = NotebookLayout(content: [stroke.bounds]).pageRect(0);
      final after = NotebookLayout(
        content: [stroke.bounds, Rect.fromLTWH(0, 3000, 1, 1)],
      ).pageRect(0);
      expect(after, before);
    });
  });

  group('saving', () {
    test('repeated saves while drawing keep every stroke once', () async {
      final saved = <CanvasDocument>[];
      final c = make(saved: saved);
      c.tool = CanvasTool.pen;
      for (var i = 0; i < 5; i++) {
        c.pointerDown(Offset(i * 10.0, 0), kind: PointerDeviceKind.stylus);
        c.pointerMove(Offset(i * 10.0, 40));
        c.pointerUp();
        await c.flush();
      }
      await c.flush();
      final ids = saved.last.items.map((i) => i.id).toList();
      expect(ids, hasLength(5));
      expect(ids.toSet(), hasLength(5));
      c.dispose();
    });

    test('a failed save keeps the ink and the next save writes it', () async {
      var fail = true;
      final saved = <CanvasDocument>[];
      final c = CanvasController(
        document: CanvasDocument(
          id: 'c',
          title: 't',
          items: const [],
          updatedAt: DateTime(2026),
        ),
        onSave: (d) async {
          if (fail) throw const FileSystemException('disk full');
          saved.add(d);
        },
        saveDelay: const Duration(milliseconds: 10),
      );
      c.tool = CanvasTool.pen;
      c.pointerDown(Offset.zero, kind: PointerDeviceKind.stylus);
      c.pointerMove(const Offset(30, 30));
      c.pointerUp();
      try {
        await c.flush();
      } catch (_) {}
      expect(c.saveState, SaveState.failed);
      expect(c.items, hasLength(1));
      fail = false;
      await c.flush();
      expect(saved.last.items, hasLength(1));
      c.dispose();
    });
  });

  group('storage and sync', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('theapp_p2_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('notebooks are hidden from the Canvas list', () async {
      final ws = Workspace(dir);
      await ws.load();
      final repo = FileCanvasRepository(ws.store);
      await repo.save(
        CanvasDocument(
          id: notebookIdFor('n'),
          title: 'Note ink',
          items: [dot('d', 1, 1)],
          updatedAt: DateTime(2026),
          kind: 'notebook',
        ),
      );
      final list = await repo.listCanvases();
      expect(list.single.isNotebook, isTrue);
      final s = AppState(
        canvases: repo,
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      await s.init();
      expect(s.canvasList.map((c) => c.id), isNot(contains('nb-n')));
      // The notebook itself is untouched.
      expect((await repo.load('nb-n'))!.items, hasLength(1));
      await s.flush();
      s.dispose();
    });

    test('older canvas files (schema 1, no kind) still open as canvases', () {
      final doc = CanvasDocument.fromJson({
        'id': 'old',
        'title': 'Old board',
        'updatedAt': DateTime(2024).toIso8601String(),
        'items': [
          {
            'type': 'stroke',
            'id': 's',
            'points': [
              [0, 0],
              [5, 5],
            ],
            'color': 0xFF000000,
            'width': 2,
          },
        ],
      });
      expect(doc.isNotebook, isFalse);
      expect(doc.pageBackgrounds, isEmpty);
      expect(doc.items.single, isA<StrokeItem>());
    });

    test(
      'a note\'s ink and PDF pages reach the other device as a notebook',
      () async {
        HttpOverrides.global = null;
        final hub = await HubServer.start(
          dir: Directory('${dir.path}${sep}hub'),
          port: 0,
          dailyBackups: false,
        );
        addTearDown(hub.stop);
        Future<(Workspace, FileCanvasRepository, SyncEngine)> device(
          String name,
        ) async {
          final ws = Workspace(Directory('${dir.path}$sep$name'));
          await ws.load();
          final token = await hub.auth.register(
            hub.auth.createPairingCode(),
            ws.device!.id,
            name,
          );
          final repo = FileCanvasRepository(ws.store);
          return (
            ws,
            repo,
            SyncEngine(
              workspace: ws,
              canvases: repo,
              client: SyncClient(
                Uri.parse('http://127.0.0.1:${hub.port}'),
                token: token,
              ),
            ),
          );
        }

        final (pcWs, pc, pcSync) = await device('pc');
        final (_, ipad, ipadSync) = await device('ipad');
        await pc.save(
          CanvasDocument(
            id: notebookIdFor('n'),
            title: 'Lecture',
            kind: 'notebook',
            items: [dot('d', 400, 1200)],
            itemRevs: {'d': pcWs.clock.now()},
            metaRev: pcWs.clock.now(),
            updatedAt: DateTime.now(),
            pageBackgrounds: const [
              PageBackground(
                pageIndex: 0,
                assetId: 'pdf',
                pdfPage: 0,
                width: 612,
                height: 792,
              ),
            ],
          ),
        );
        await pcSync.syncOnce();
        await ipadSync.syncOnce();
        final got = (await ipad.load('nb-n'))!;
        expect(got.isNotebook, isTrue);
        expect(got.kind, 'notebook');
        expect(got.pageBackgrounds.single.width, 612);
        expect(got.items.single.id, 'd');
        expect((await ipad.listCanvases()).single.isNotebook, isTrue);
      },
    );
  });

  group('native bridge (simulated channel)', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(IosBridge.channelName);
    late List<MethodCall> calls;
    setUp(() {
      calls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'pdfInfo' => [
            [612.0, 792.0],
            [792, 612],
          ],
          'pdfRenderPage' => Uint8List.fromList([1, 2, 3]),
          'pdfExport' => true,
          'enablePencilSqueeze' => true,
          _ => null,
        };
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('PDF page sizes, page rendering and export', () async {
      final b = IosBridge();
      expect(await b.pdfPageSizes('/x.pdf'), const [
        Size(612, 792),
        Size(792, 612),
      ]);
      expect(await b.renderPdfPage('/x.pdf', 1, 800), [1, 2, 3]);
      expect(calls.last.arguments, {'path': '/x.pdf', 'page': 1, 'width': 800});
      expect(
        await b.exportAnnotatedPdf('/x.pdf', '/y.pdf', [
          {'page': 0, 'strokes': <Object>[]},
        ]),
        isTrue,
      );
      expect((calls.last.arguments as Map)['source'], '/x.pdf');
    });

    test('squeezes from iOS arrive as began / ended', () async {
      final b = IosBridge();
      expect(await b.enablePencilSqueeze(), isTrue);
      final got = <String>[];
      final sub = b.pencilSqueeze.listen(got.add);
      for (final phase in ['began', 'ended']) {
        await messenger.handlePlatformMessage(
          IosBridge.channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('pencilSqueeze', phase),
          ),
          (_) {},
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(got, ['began', 'ended']);
      await sub.cancel();
    });

    test('without a native side everything fails softly', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final b = IosBridge();
      expect(await b.pdfPageSizes('/x.pdf'), isNull);
      expect(await b.enablePencilSqueeze(), isFalse);
      expect(await b.exportAnnotatedPdf('/x', '/y', const []), isFalse);
    });
  });
}
