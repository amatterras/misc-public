// The ink engine (docs/INK_ENGINE_REPORT.md): curve geometry, live/finished
// consistency, the pointer lifecycle, pressure capability, full-rate
// Apple Pencil samples merged from UIKit, and the raster cache of the
// finished drawing. Deterministic sample sequences only; what needs real
// hardware (latency to the screen, palm rejection, the Swift observer) is
// listed in the report as unverified.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_painter.dart';
import 'package:flutter_application_1/features/ink/native_ink.dart';
import 'package:flutter_application_1/features/ink/stroke_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ink_samples.dart';

CanvasController make({List<CanvasItem> items = const []}) => CanvasController(
  document: CanvasDocument(
    id: 'ink',
    title: 'Ink',
    items: items,
    updatedAt: DateTime(2026),
  ),
  onSave: (_) async {},
  saveDelay: const Duration(minutes: 5),
);

List<StrokePoint> pts(List<PenSample> s) => [
  for (final p in s) StrokePoint(p.position.dx, p.position.dy, p.pressure),
];

/// Largest distance from any of [truth] to the polyline that [path] flattens
/// into (sampled every 0.25 units).
double maxDeviation(Path path, List<Offset> truth) {
  final poly = <Offset>[];
  for (final m in path.computeMetrics()) {
    for (var d = 0.0; d <= m.length; d += 0.25) {
      poly.add(m.getTangentForOffset(d)!.position);
    }
  }
  var worst = 0.0;
  for (final t in truth) {
    var best = double.infinity;
    for (final p in poly) {
      best = math.min(best, (p - t).distance);
    }
    worst = math.max(worst, best);
  }
  return worst;
}

Float64List nativeMessage(
  int phase,
  int begin,
  List<(int, Offset, double)> samples, [
  List<(int, Offset, double)> predicted = const [],
]) => Float64List.fromList([
  1,
  phase.toDouble(),
  begin.toDouble(),
  samples.length.toDouble(),
  predicted.length.toDouble(),
  for (final (t, p, f) in [...samples, ...predicted]) ...[
    t.toDouble(),
    p.dx,
    p.dy,
    f,
    4.0,
    1.2,
    0.4,
  ],
]);

/// Bounds of what [path] actually draws (Path.getBounds includes curve
/// control points, which lie outside the curve).
ui.Rect tightBounds(ui.Path path) {
  var r = ui.Rect.zero;
  var first = true;
  for (final m in path.computeMetrics()) {
    for (var d = 0.0; d <= m.length; d += 0.05) {
      final p = m.getTangentForOffset(d)!.position;
      r = first ? ui.Rect.fromPoints(p, p) : r.expandToInclude(ui.Rect.fromPoints(p, p));
      first = false;
    }
  }
  return r;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CanvasController.pencilPressureSeen = false;
    NativeInk.instance.resetForTest();
  });

  group('geometry', () {
    test('the curve passes through every pen sample', () {
      final s = pts(cursiveLoops(hz: 60));
      final dense = <Offset>[];
      catmullRomDense([for (final p in s) p.offset], null, 1, dense);
      for (final p in s) {
        expect(
          dense.any((d) => (d - p.offset).distance < 1e-9),
          isTrue,
          reason: 'sample $p must lie on the drawn curve',
        );
      }
    });

    test('small loops keep their size (no corner cutting)', () {
      // A loop of radius 4 sampled only 8 times (fast writing): the old
      // curve through midpoints shrank it to ~70 %; this one keeps ≥ 95 %.
      final circle = [
        for (var i = 0; i <= 8; i++)
          StrokePoint(
            50 + 4 * math.cos(i * math.pi / 4),
            50 + 4 * math.sin(i * math.pi / 4),
          ),
      ];
      final b = tightBounds(centreLine(circle));
      expect(b.width, greaterThanOrEqualTo(8 * 0.95));
      expect(b.height, greaterThanOrEqualTo(8 * 0.95));
      // And no overshoot beyond the loop either.
      expect(b.width, lessThanOrEqualTo(8 * 1.08));
    });

    test('drawn ink follows real handwriting closely', () {
      final truth = cursiveLoops();
      final full = centreLine(pts(truth));
      final sparse = centreLine(pts(everyNth(truth, 4)));
      // 240 Hz samples: within a hair of the true path.
      expect(
        maxDeviation(full, [for (final t in truth) t.position]),
        lessThan(0.3),
      );
      // Even at 60 Hz the curve stays within ~1.5 px on 14 px loops.
      expect(
        maxDeviation(sparse, [for (final t in truth) t.position]),
        lessThan(1.5),
      );
    });

    test('hairpin turns get a round tip, not a pinched one', () {
      final s = pts(zigZag());
      final shape = pressureShape(s, 6);
      expect(shape.discs, isNotEmpty);
      // The disc at each turn has the local half width.
      for (final (_, r) in shape.discs) {
        expect(r, closeTo(6 * pressureFactor(0.3) / 2, 0.01));
      }
      // A smooth curve has none.
      expect(pressureShape(pts(cursiveLoops(loops: 1, radius: 60)), 6).discs,
          isEmpty);
    });

    test('degenerate input never produces NaN geometry', () {
      final cases = [
        [const StrokePoint(1, 1)],
        [const StrokePoint(1, 1), const StrokePoint(1, 1)],
        [const StrokePoint(1, 1), const StrokePoint(1, 1.0000001)],
        [
          const StrokePoint(0, 0),
          const StrokePoint(10, 0),
          const StrokePoint(0, 0),
          const StrokePoint(10, 0),
        ],
        [const StrokePoint(1e7, 1e7), const StrokePoint(1e7 + 3, 1e7 + 1)],
      ];
      for (final c in cases) {
        for (final pressure in [true, false]) {
          final stroke = StrokeItem(
            id: 's',
            points: c,
            color: const ui.Color(0xFF000000),
            strokeWidth: 3,
            pressureWidth: pressure,
          );
          final b = strokeShape(stroke).path.getBounds();
          expect(
            [b.left, b.top, b.right, b.bottom].every((v) => v.isFinite),
            isTrue,
            reason: '$c pressure $pressure',
          );
        }
      }
    });

    test('pressure curve: chosen size for normal writing, gentle range', () {
      expect(pressureFactor(0), closeTo(0.62, 1e-9));
      expect(pressureFactor(1), closeTo(1.38, 1e-9));
      expect(pressureFactor(0.3), inInclusiveRange(0.95, 1.05));
      for (var p = 0.0; p < 1; p += 0.05) {
        expect(pressureFactor(p + 0.05), greaterThan(pressureFactor(p)));
      }
      // Within the bounds every stroke reserves (1.6 × width).
      expect(pressureFactor(1), lessThan(1.6));
    });
  });

  group('live stroke and finished stroke', () {
    test('the finished stroke draws exactly the last live frame', () {
      for (final stylus in [false, true]) {
        final c = make();
        c.tool = CanvasTool.pen;
        final s = cursiveLoops(hz: 120);
        final kind = stylus ? PointerDeviceKind.stylus : PointerDeviceKind.mouse;
        c.pointerDown(s.first.position, kind: kind, pressure: s.first.pressure);
        for (final p in s.skip(1)) {
          c.pointerMove(p.position, pressure: p.pressure);
        }
        // No time stamps: no prediction, so live = finished exactly.
        expect(c.predictedPoint, isNull);
        final live = strokeShape(c.liveStroke!);
        c.pointerUp();
        final done = strokeShape(c.items.single as StrokeItem);
        expect(done.path.getBounds(), live.path.getBounds());
        expect(done.discs.length, live.discs.length);
        for (var x = 60.0; x < 260; x += 2.3) {
          for (var y = 160.0; y < 220; y += 1.9) {
            expect(
              done.path.contains(Offset(x, y)),
              live.path.contains(Offset(x, y)),
            );
          }
        }
        c.dispose();
      }
    });

    test('a long live stroke: kept pieces + tail draw the whole stroke', () async {
      final s = cursiveLoops(loops: 10, seconds: 2.5);
      final points = pts(s);
      final live = LiveInkGeometry();
      // Feed it frame by frame (2 samples a frame), as the painter does.
      var shapes = <StrokeShape>[];
      for (var n = 2; n <= points.length; n += 2) {
        shapes = live.shapes(
          StrokeItem(
            id: 'live',
            points: points.sublist(0, n),
            color: const ui.Color(0xFF000000),
            strokeWidth: 4,
            pressureWidth: true,
          ),
          null,
        );
      }
      expect(live.frozenPieces, greaterThan(5), reason: 'pieces are kept');
      final whole = pressureShape(points.sublist(0, points.length ~/ 2 * 2), 4);
      Future<Uint8List> draw(List<StrokeShape> list) async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)..translate(-60, -150);
        final paint = ui.Paint()..color = const ui.Color(0xFF000000);
        for (final shape in list) {
          shape.paint(canvas, paint);
        }
        final image = await recorder.endRecording().toImage(420, 80);
        final data = await image.toByteData();
        image.dispose();
        return data!.buffer.asUint8List();
      }

      final a = await draw(shapes), b = await draw([whole]);
      var differing = 0, ink = 0;
      for (var i = 3; i < a.length; i += 4) {
        if (b[i] > 0) ink++;
        if ((a[i] - b[i]).abs() > 24) differing++;
      }
      // Identical except anti-aliasing noise on a handful of edge pixels.
      expect(ink, greaterThan(2000));
      expect(differing / ink, lessThan(0.003));
    });

    test('the lift-off position is the last point of the stroke', () {
      final c = make();
      c.tool = CanvasTool.pen;
      c.pointerDown(const Offset(0, 0));
      c.pointerMove(const Offset(20, 0));
      c.pointerUp(screen: const Offset(31, 4));
      final stroke = c.items.single as StrokeItem;
      expect(stroke.points.last.offset, const Offset(31, 4));
      // A lift where the last move was is not added twice.
      c.pointerDown(const Offset(0, 50));
      c.pointerMove(const Offset(20, 50));
      c.pointerUp(screen: const Offset(20.2, 50));
      expect((c.items.last as StrokeItem).points, hasLength(2));
      c.dispose();
    });

    test('pen-down repaints only the live layer', () {
      final c = make();
      c.tool = CanvasTool.pen;
      var whole = 0, live = 0;
      c.addListener(() => whole++);
      c.liveInk.addListener(() => live++);
      c.pointerDown(const Offset(5, 5), kind: PointerDeviceKind.stylus);
      expect(whole, 0, reason: 'the first ink must not wait for a rebuild');
      expect(live, greaterThan(0));
      c.pointerUp();
      expect(whole, greaterThan(0), reason: 'the finished stroke is drawn');
      c.dispose();
    });

    test('platform prediction is drawn, clamped, and never stored', () {
      final c = make();
      c.tool = CanvasTool.pen;
      c.pointerDown(const Offset(0, 0), kind: PointerDeviceKind.stylus);
      c.pointerMove(const Offset(10, 0), timeStamp: const Duration(milliseconds: 4));
      c.setPredictedPoint(const Offset(16, 1));
      expect(c.predictedPoint, const Offset(16, 1));
      c.setPredictedPoint(const Offset(200, 0)); // a wild guess
      expect(c.predictedPoint!.dx, closeTo(10 + 24, 1e-9));
      c.setPredictedPoint(null); // UIKit has nothing: no tip, no guess
      expect(c.predictedPoint, isNull);
      c.setPredictedPoint(const Offset(16, 1));
      c.pointerUp();
      expect(c.predictedPoint, isNull);
      final stroke = c.items.single as StrokeItem;
      expect(stroke.points.map((p) => p.x), [0, 10]);
      c.dispose();
    });
  });

  group('lifecycle', () {
    test('a cancelled Pencil stroke is kept; a cancelled finger is not', () {
      final c = make();
      c.tool = CanvasTool.pen;
      c.pointerDown(const Offset(0, 0), kind: PointerDeviceKind.stylus);
      c.pointerMove(const Offset(30, 10));
      c.pointerCancel(keepInk: true);
      expect(c.items, hasLength(1));
      expect(c.isDragging, isFalse);
      c.pointerDown(const Offset(0, 40), kind: PointerDeviceKind.touch);
      c.pointerMove(const Offset(30, 40));
      c.pointerCancel();
      expect(c.items, hasLength(1), reason: 'start of a pinch, not ink');
      // A kept stroke is one undo step, like any other.
      c.undo();
      expect(c.items, isEmpty);
      c.dispose();
    });

    test('pens without pressure draw at exactly the chosen width', () {
      final c = make();
      c.tool = CanvasTool.pen;
      // Apple Pencil USB-C: the same pressure on every sample.
      c.pointerDown(const Offset(0, 0), kind: PointerDeviceKind.stylus);
      for (var i = 1; i < 10; i++) {
        c.pointerMove(Offset(i * 5.0, 0));
      }
      expect(c.liveStroke!.pressureWidth, isFalse);
      c.pointerUp();
      expect((c.items.single as StrokeItem).pressureWidth, isFalse);
      // A Pencil that reports pressure switches it on (this stroke on).
      c.pointerDown(const Offset(0, 20), kind: PointerDeviceKind.stylus,
          pressure: 0.2);
      c.pointerMove(const Offset(5, 20), pressure: 0.3);
      expect(c.liveStroke!.pressureWidth, isTrue);
      c.pointerUp();
      expect((c.items.last as StrokeItem).pressureWidth, isTrue);
      expect(CanvasController.pencilPressureSeen, isTrue);
      c.dispose();
    });

    test('hover and saving do not count as drawing changes', () async {
      final c = make();
      final before = c.paintEpoch;
      c.pointerHover(const Offset(3, 3));
      expect(c.paintEpoch, before);
      c.tool = CanvasTool.pen;
      final afterTool = c.paintEpoch;
      c.pointerDown(Offset.zero);
      c.pointerMove(const Offset(10, 10));
      c.pointerUp();
      expect(c.lastStrokeAppend, isNotNull);
      expect(c.lastStrokeAppend!.fromEpoch, afterTool);
      expect(c.lastStrokeAppend!.toEpoch, c.paintEpoch);
      final epoch = c.paintEpoch;
      await c.flush();
      expect(c.paintEpoch, epoch);
      c.dispose();
    });
  });

  group('full-rate Pencil samples (UIKit coalesced touches)', () {
    PointerDownEvent down(int micros, Offset at, {Offset shift = Offset.zero}) =>
        PointerDownEvent(
          timeStamp: Duration(microseconds: micros),
          pointer: 7,
          kind: PointerDeviceKind.stylus,
          position: at,
        ).transformed(Matrix4.translationValues(shift.dx, shift.dy, 0));
    PointerMoveEvent move(int micros, Offset at) => PointerMoveEvent(
      timeStamp: Duration(microseconds: micros),
      pointer: 7,
      kind: PointerDeviceKind.stylus,
      position: at,
    );

    test('every coalesced sample reaches the stroke, in local units', () {
      final ink = NativeInk.instance;
      ink.handle(nativeMessage(0, 1000, [(1000, const Offset(110, 110), 1)]));
      final got = <(Offset, double, int)>[];
      final predicted = <Offset?>[];
      final feed = PencilFeed()
        ..begin(
          down(1000, const Offset(110, 110), shift: const Offset(-100, -100)),
          move: (l, p, t) => got.add((l, p, t.inMicroseconds)),
          predict: predicted.add,
        );
      expect(feed.native, isTrue);
      ink.handle(
        nativeMessage(
          1,
          1000,
          [
            (5166, const Offset(112, 110), 2),
            (9333, const Offset(114, 111), 2),
          ],
          [(17666, const Offset(118, 112), 2)],
        ),
      );
      expect(got, [
        (const Offset(12, 10), 0.5, 5166),
        (const Offset(14, 11), 0.5, 9333),
      ]);
      expect(predicted.last, const Offset(18, 12));
      // Flutter's own move for the same moment is already covered ...
      expect(feed.flutterMove(move(9333, const Offset(114, 111))), isFalse);
      // ... but a later one (native samples late for once) is not lost.
      expect(feed.flutterMove(move(13500, const Offset(116, 111))), isTrue);
      ink.handle(nativeMessage(2, 1000, [(13500, const Offset(116, 111), 1)]));
      expect(got, hasLength(2), reason: 'no duplicate of 13500');
      expect(predicted.last, isNull, reason: 'no prediction after lift');
      feed.end();
    });

    test('Flutter pointer-down first, native samples a moment later', () {
      final ink = NativeInk.instance;
      // An earlier stroke proved the native side works.
      ink.handle(nativeMessage(0, 1, [(1, Offset.zero, 1)]));
      final got = <Offset>[];
      final feed = PencilFeed()
        ..begin(
          down(2000, const Offset(5, 5)),
          move: (l, p, t) => got.add(l),
          predict: (_) {},
        );
      expect(feed.native, isFalse);
      ink.handle(
        nativeMessage(0, 2000, [(2000, const Offset(5, 5), 1)]),
      );
      ink.handle(
        nativeMessage(1, 2000, [(6000, const Offset(7, 5), 1)]),
      );
      expect(feed.native, isTrue);
      expect(got, [const Offset(7, 5)]);
      feed.end();
    });

    test('another touch\'s samples never leak into the stroke', () {
      final ink = NativeInk.instance;
      ink.handle(nativeMessage(0, 3000, [(3000, Offset.zero, 1)]));
      final got = <Offset>[];
      final feed = PencilFeed()
        ..begin(
          down(3000, Offset.zero),
          move: (l, p, t) => got.add(l),
          predict: (_) {},
        );
      ink.handle(nativeMessage(1, 999999, [(4000, const Offset(50, 50), 1)]));
      expect(got, isEmpty);
      feed.end();
    });

    test('without a native side Flutter events are used as before', () {
      final feed = PencilFeed()
        ..begin(
          down(1000, Offset.zero),
          move: (_, _, _) => fail('no native samples expected'),
          predict: (_) => fail('no native prediction expected'),
        );
      expect(feed.native, isFalse);
      expect(feed.flutterMove(move(5000, const Offset(1, 1))), isTrue);
      expect(feed.flutterMove(move(9000, const Offset(2, 1))), isTrue);
      feed.end();
    });

    test('malformed messages are ignored', () {
      final ink = NativeInk.instance;
      ink.handle(Float64List.fromList([1, 1, 5]));
      ink.handle(Float64List.fromList([2, 1, 5, 1, 0, 0, 0, 0, 0, 0, 0, 0]));
      ink.handle(Float64List.fromList([1, 1, 5, 3, 0, 1, 2]));
      expect(ink.receiving, isFalse);
    });
  });

  group('raster cache of the finished drawing', () {
    setUp(() => InkRasterCache.minItems = 1);
    tearDown(() => InkRasterCache.minItems = 120);

    List<CanvasItem> strokes(int n) => [
      for (var i = 0; i < n; i++)
        StrokeItem(
          id: 's$i',
          points: [
            for (var k = 0; k < 12; k++)
              StrokePoint(10.0 + k * 9, 12.0 + i * 7 + 3 * math.sin(k), 0.3),
          ],
          color: const ui.Color(0xFF203040),
          strokeWidth: 2.5,
          pressureWidth: i.isEven,
        ),
    ];

    Future<Uint8List> render(CanvasController c, [InkRasterCache? cache]) async {
      final recorder = ui.PictureRecorder();
      CanvasPainter(
        c,
        rasterCache: cache,
        devicePixelRatio: 1,
        lightTheme: true,
      ).paint(ui.Canvas(recorder), const ui.Size(160, 120));
      final image = await recorder.endRecording().toImage(160, 120);
      final data = await image.toByteData();
      image.dispose();
      return data!.buffer.asUint8List();
    }

    void expectSame(Uint8List a, Uint8List b) {
      var worst = 0;
      for (var i = 0; i < a.length; i++) {
        worst = math.max(worst, (a[i] - b[i]).abs());
      }
      expect(worst, lessThanOrEqualTo(2));
    }

    test('image, appended stroke and direct drawing look the same', () async {
      final c = make(items: strokes(12));
      c.setView(Offset.zero, 1);
      final cache = InkRasterCache();
      await render(c, cache);
      expect(cache.lastPaint, 'direct', reason: 'first paint of a view');
      await render(c, cache);
      expect(cache.lastPaint, 'rebuild');
      final fromImage = await render(c, cache);
      expect(cache.lastPaint, 'image');
      expectSame(fromImage, await render(c));

      c.tool = CanvasTool.pen;
      await render(c, cache); // the tool change is a drawing change
      c.pointerDown(const Offset(20, 100), kind: PointerDeviceKind.stylus,
          pressure: 0.2);
      c.pointerMove(const Offset(60, 90), pressure: 0.4);
      c.pointerMove(const Offset(100, 105), pressure: 0.3);
      c.pointerUp();
      final appended = await render(c, cache);
      expect(cache.lastPaint, 'append');
      expectSame(appended, await render(c));

      c.setView(const Offset(-5, 3), 1.5); // zoom: drawn directly
      await render(c, cache);
      expect(cache.lastPaint, 'direct');
      cache.dispose();
      c.dispose();
    });

    test('small drawings are always drawn directly', () async {
      InkRasterCache.minItems = 120;
      final c = make(items: strokes(3));
      final cache = InkRasterCache();
      await render(c, cache);
      await render(c, cache);
      expect(cache.lastPaint, 'direct');
      cache.dispose();
      c.dispose();
    });
  });
}
