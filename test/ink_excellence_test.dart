// Regression tests of the 2026-11-10 Pencil engineering pass: pressure
// from the first stroke, pen opacity, pen angle and time kept with every
// point, clean-ups that keep the stroke's character, the last samples
// before lift-off, erasing and selecting by the ink as drawn, the cached
// picture updated only where the eraser was, and no save in mid-stroke.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_painter.dart';
import 'package:flutter_application_1/features/ink/ink_input.dart';
import 'package:flutter_application_1/features/ink/native_ink.dart';
import 'package:flutter_application_1/features/ink/partial_erase.dart';
import 'package:flutter_application_1/features/ink/stroke_geometry.dart';
import 'package:flutter_application_1/features/ink/stylus_pressure.dart';
import 'package:flutter_application_1/features/notes/note_page.dart'
    show annotationStrokes;
import 'package:flutter_test/flutter_test.dart';

CanvasController make({
  List<CanvasItem> items = const [],
  Future<void> Function(CanvasDocument)? onSave,
  Duration saveDelay = const Duration(minutes: 5),
}) => CanvasController(
  document: CanvasDocument(
    id: 'ink',
    title: 'Ink',
    items: items,
    updatedAt: DateTime(2026),
  ),
  onSave: onSave ?? (_) async {},
  saveDelay: saveDelay,
);

/// Draws one pen stroke through [path] with the given pressures.
StrokeItem draw(
  CanvasController c,
  List<Offset> path,
  double Function(int i) pressure, {
  PointerDeviceKind kind = PointerDeviceKind.stylus,
}) {
  c.pointerDown(path.first, kind: kind, pressure: pressure(0));
  for (var i = 1; i < path.length; i++) {
    c.pointerMove(
      path[i],
      pressure: pressure(i),
      timeStamp: Duration(milliseconds: i * 4),
    );
  }
  c.pointerUp();
  return c.items.last as StrokeItem;
}

List<Offset> line(Offset a, Offset b, [int n = 40]) => [
  for (var i = 0; i <= n; i++) Offset.lerp(a, b, i / n)!,
];

Float64List nativeMessage(
  int phase,
  int begin,
  List<(int, Offset, double)> samples, {
  double altitude = 1.1,
  double azimuth = 0.4,
}) => Float64List.fromList([
  1,
  phase.toDouble(),
  begin.toDouble(),
  samples.length.toDouble(),
  0,
  for (final (t, p, f) in samples) ...[
    t.toDouble(),
    p.dx,
    p.dy,
    f,
    4.0,
    altitude,
    azimuth,
  ],
]);

double heightOf(ui.Path path) {
  var top = double.infinity, bottom = -double.infinity;
  for (final m in path.computeMetrics()) {
    for (var d = 0.0; d <= m.length; d += 0.1) {
      final y = m.getTangentForOffset(d)!.position.dy;
      top = math.min(top, y);
      bottom = math.max(bottom, y);
    }
  }
  return bottom - top;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    StylusPressure.instance.reset();
    NativeInk.instance.resetForTest();
  });

  group('pressure from the first stroke', () {
    test('the first stroke after launch is pressure ink from its first '
        'sample, and so is a short tap', () {
      final c = make()..tool = CanvasTool.pen;
      c.pointerDown(
        const Offset(10, 10),
        kind: PointerDeviceKind.stylus,
        pressure: 0.2,
      );
      expect(c.liveStroke!.pressureWidth, isTrue, reason: 'no later switch');
      c.pointerUp();
      expect((c.items.single as StrokeItem).pressureWidth, isTrue);

      // A short tick of four samples.
      final tick = draw(
        c,
        line(const Offset(30, 10), const Offset(36, 14), 3),
        (i) => 0.2 + i * 0.05,
      );
      expect(tick.pressureWidth, isTrue);
      c.dispose();
    });

    test('light, heavy and gradually changing pressure set the width', () {
      final c = make()..tool = CanvasTool.pen;
      c.setPen(width: 10);
      final light = draw(
        c,
        line(const Offset(0, 0), const Offset(200, 0)),
        (i) => 0.05 + (i.isEven ? 0.01 : 0),
      );
      final heavy = draw(
        c,
        line(const Offset(0, 50), const Offset(200, 50)),
        (i) => 0.95 - (i.isEven ? 0.01 : 0),
      );
      final lightHeight = heightOf(strokeShape(light).path);
      final heavyHeight = heightOf(strokeShape(heavy).path);
      expect(lightHeight, closeTo(10 * pressureFactor(0.055), 0.4));
      expect(heavyHeight, closeTo(10 * pressureFactor(0.945), 0.4));
      expect(heavyHeight, greaterThan(lightHeight * 1.5));

      final gradual = draw(
        c,
        line(const Offset(0, 100), const Offset(200, 100)),
        (i) => 0.1 + 0.8 * i / 40,
      );
      expect(gradual.pressureWidth, isTrue);
      final w = [for (final p in gradual.points) gradual.halfWidthAt(p)];
      for (var i = 1; i < w.length; i++) {
        expect(w[i], greaterThanOrEqualTo(w[i - 1]), reason: 'no jump back');
      }
      c.dispose();
    });

    test('mouse and finger never give pressure ink', () {
      final c = make()..tool = CanvasTool.pen;
      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
        final s = draw(
          c,
          line(const Offset(0, 0), const Offset(100, 20)),
          (i) => 0.1 + i * 0.02,
          kind: kind,
        );
        expect(s.pressureWidth, isFalse);
      }
      expect(StylusPressure.instance.state, StylusPressureState.unknown);
      c.dispose();
    });

    test('a pen without pressure is recognized, and a swapped pen too', () {
      final c = make()..tool = CanvasTool.pen;
      final path = line(const Offset(0, 0), const Offset(200, 0));
      // Unknown pen sending one value: stored at the chosen width.
      expect(draw(c, path, (_) => 1).pressureWidth, isFalse);
      expect(StylusPressure.instance.state, StylusPressureState.flat);
      // Its next stroke is even from the first sample.
      c.pointerDown(path.first, kind: PointerDeviceKind.stylus, pressure: 1);
      expect(c.liveStroke!.pressureWidth, isFalse);
      c.pointerUp();
      // A pressure pen is picked up: followed within the stroke.
      expect(draw(c, path, (i) => 0.2 + i * 0.01).pressureWidth, isTrue);
      expect(StylusPressure.instance.state, StylusPressureState.varies);
      // Back to the pen without pressure.
      expect(draw(c, path, (_) => 0).pressureWidth, isFalse);
      expect(StylusPressure.instance.state, StylusPressureState.flat);
      c.dispose();
    });

    test('pressing harder on the spot widens the dot', () {
      final c = make()..tool = CanvasTool.pen;
      c.pointerDown(
        const Offset(10, 10),
        kind: PointerDeviceKind.stylus,
        pressure: 0.2,
      );
      c.pointerMove(const Offset(10.1, 10), pressure: 0.7);
      c.pointerMove(const Offset(10.1, 10.1), pressure: 0.5);
      c.pointerUp();
      final dot = c.items.single as StrokeItem;
      expect(dot.points, hasLength(1));
      expect(dot.points.single.pressure, 0.7);
      c.dispose();
    });
  });

  group('clean-ups keep the stroke\'s character', () {
    test('the hold is 0.9 seconds', () {
      expect(
        CanvasController.holdToStraighten,
        const Duration(milliseconds: 900),
      );
    });

    test('a straightened line keeps its pressure profile', () {
      final points = [
        for (var i = 0; i <= 50; i++)
          StrokePoint(
            i * 4.0,
            math.sin(i / 3) * 1.5,
            0.1 + 0.8 * i / 50,
            i * 4,
            1.0,
            0.2,
          ),
      ];
      final straight = straightened(points);
      expect(straight.first.pressure, closeTo(0.1, 1e-9));
      expect(straight.last.pressure, closeTo(0.9, 1e-9));
      for (var i = 1; i < straight.length; i++) {
        expect(
          straight[i].pressure,
          greaterThanOrEqualTo(straight[i - 1].pressure),
        );
      }
      // Still a straight line between the same ends, with the pen's angle
      // and time carried over.
      for (final p in straight) {
        expect(
          distanceToSegment(p.offset, points.first.offset, points.last.offset),
          lessThan(1e-9),
        );
        expect(p.altitude, closeTo(1.0, 1e-9));
        expect(p.time, isNotNull);
      }
      expect(straight.last.time, 200);
    });

    test('a recognized shape stays pressure ink with varying width', () {
      final c = make()
        ..tool = CanvasTool.pen
        ..recognizeShapes = true;
      const corners = [
        Offset(50, 50),
        Offset(250, 50),
        Offset(250, 170),
        Offset(50, 170),
        Offset(50, 50),
      ];
      final path = <Offset>[
        for (var k = 0; k < 4; k++)
          ...line(corners[k], corners[k + 1], 30).skip(k == 0 ? 0 : 1),
      ];
      final shape = draw(c, path, (i) => 0.15 + 0.6 * i / path.length);
      expect(shape.pressureWidth, isTrue, reason: 'was reset to even width');
      final pressures = [for (final p in shape.points) p.pressure];
      expect(
        pressures.reduce(math.max) - pressures.reduce(math.min),
        greaterThan(0.3),
        reason: 'was flattened to the average pressure',
      );
      // Closed: no step in width where the outline meets itself.
      expect(pressures.last, closeTo(pressures.first, 0.02));
      for (var i = 1; i < pressures.length; i++) {
        expect((pressures[i] - pressures[i - 1]).abs(), lessThan(0.08));
      }
      c.dispose();
    });
  });

  group('pen opacity', () {
    test('is stored in the stroke, kept through save and undo, and is not '
        'a highlighter', () {
      final c = make()..tool = CanvasTool.pen;
      c.setPen(color: const Color(0xFF102030), opacity: 0.4);
      final s = draw(
        c,
        line(const Offset(0, 0), const Offset(120, 30)),
        (i) => 0.2 + i * 0.01,
      );
      expect(s.color.a, closeTo(0.4, 0.01));
      expect(s.penInk, isTrue);
      expect(s.isHighlighter, isFalse);
      expect(isPressureInk(s), isTrue, reason: 'opacity and pressure together');

      final json = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
      final back = StrokeItem.fromJson(json);
      expect(back.color, s.color);
      expect(back.penInk, isTrue);
      expect(back.pressureWidth, isTrue);

      // The "highlighter only" eraser leaves it alone.
      c.setEraser(mode: EraserMode.stroke, highlighterOnly: true);
      c.tool = CanvasTool.eraser;
      c.pointerDown(const Offset(60, 15));
      c.pointerMove(const Offset(61, 16));
      c.pointerUp();
      expect(c.items, hasLength(1));

      c.undo();
      expect(c.items, isEmpty);
      c.redo();
      expect(identical(c.items.single, s), isTrue);

      // Out-of-range values are made safe; full opacity writes no marker.
      c.setPen(opacity: 7);
      expect(c.penOpacity, 1);
      c.setPen(opacity: 0);
      expect(c.penOpacity, CanvasController.penOpacityMin);
      c.setPen(opacity: 1);
      c.tool = CanvasTool.pen;
      final solid = draw(
        c,
        line(const Offset(0, 60), const Offset(120, 60)),
        (i) => 0.3,
        kind: PointerDeviceKind.mouse,
      );
      expect(solid.penInk, isFalse);
      expect(solid.toJson().containsKey('pen'), isFalse);
      c.dispose();
    });

    test('see-through pressure ink has one opacity everywhere, also at '
        'sharp turns and where the stroke crosses itself', () async {
      final points = [
        for (var i = 0; i <= 24; i++)
          StrokePoint(20.0 + i * 5, i.isEven ? 30 : 70, 0.5),
      ];
      final stroke = StrokeItem(
        id: 'z',
        points: points,
        color: const Color(0x80000000),
        strokeWidth: 14,
        pressureWidth: true,
        penInk: true,
      );
      final shape = strokeShape(stroke);
      expect(shape.discs, isNotEmpty, reason: 'hairpin turns have discs');
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)
        ..drawRect(
          const Rect.fromLTWH(0, 0, 180, 100),
          Paint()..color = const Color(0xFFFFFFFF),
        );
      paintStroke(canvas, stroke);
      final image = await recorder.endRecording().toImage(180, 100);
      final data = (await image.toByteData())!.buffer.asUint8List();
      image.dispose();
      var darkest = 255;
      for (var i = 0; i < data.length; i += 4) {
        darkest = math.min(darkest, data[i]);
      }
      // Black at 50 % over white is 127; painting any part twice gave 63.
      expect(darkest, inInclusiveRange(120, 134));
    });
  });

  group('pen angle and time', () {
    test('are stored with every point and survive JSON, moving and '
        'cutting; old points load unchanged', () {
      final c = make()..tool = CanvasTool.pen;
      c.pointerDown(
        const Offset(0, 0),
        kind: PointerDeviceKind.stylus,
        pressure: 0.3,
        timeStamp: const Duration(milliseconds: 1000),
        altitude: 1.1,
        azimuth: 0.4,
      );
      for (var i = 1; i <= 10; i++) {
        c.pointerMove(
          Offset(i * 5.0, 0),
          pressure: 0.3 + i * 0.01,
          timeStamp: Duration(milliseconds: 1000 + i * 4),
          altitude: 1.1 - i * 0.01,
          azimuth: 0.4,
        );
      }
      c.pointerUp();
      final s = c.items.single as StrokeItem;
      expect(
        [for (final p in s.points) p.time],
        [for (var i = 0; i <= 10; i++) i * 4],
      );
      expect(s.points.last.altitude, closeTo(1.0, 1e-9));
      expect(s.points.first.azimuth, 0.4);

      final back = StrokeItem.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      for (var i = 0; i < s.points.length; i++) {
        expect(back.points[i].time, s.points[i].time);
        expect(back.points[i].altitude, closeTo(s.points[i].altitude!, 1e-3));
        expect(back.points[i].azimuth, closeTo(0.4, 1e-3));
      }
      expect(s.translated(const Offset(3, 4)).points[5].time, 20);
      expect(s.translated(const Offset(3, 4)).points[5].altitude, isNotNull);

      final cut = erasePolyline(
        s.points,
        const Offset(22, -5),
        const Offset(22, 5),
        2,
      )!;
      expect(cut, hasLength(2));
      expect(cut.first.last.time, inInclusiveRange(12, 16));
      expect(cut.first.last.altitude, isNotNull);

      // Points saved by earlier versions: nothing is invented.
      final old = StrokePoint.fromJson([1, 2, 0.3]);
      expect([old.time, old.altitude, old.azimuth], [null, null, null]);
      expect(old.toJson(), [1, 2, 0.3]);
      expect(StrokePoint.fromJson([1, 2]).pressure, 0.5);
      // Input without times stores none.
      final plain = draw(
        make()..tool = CanvasTool.pen,
        [Offset.zero, const Offset(9, 9)],
        (_) => 0.5,
        kind: PointerDeviceKind.mouse,
      );
      expect(plain.points.first.toJson().length, 4);
      final c2 = make()..tool = CanvasTool.pen;
      c2.pointerDown(Offset.zero);
      c2.pointerMove(const Offset(9, 9));
      c2.pointerUp();
      expect(
        (c2.items.single as StrokeItem).points.last.toJson(),
        hasLength(3),
      );
      c.dispose();
      c2.dispose();
    });

    test('tilt shading widens the line only when chosen and only where '
        'the pen is laid flat', () {
      expect(tiltWidthFactor(null), 1);
      expect(tiltWidthFactor(math.pi / 2), 1);
      expect(tiltWidthFactor(70 * math.pi / 180), 1);
      expect(tiltWidthFactor(0.2), 3);
      final upright = [
        for (var i = 0; i <= 20; i++) StrokePoint(i * 5.0, 0, 0.5, i, 1.3, 0),
      ];
      final flat = [
        for (var i = 0; i <= 20; i++) StrokePoint(i * 5.0, 0, 0.5, i, 0.3, 0),
      ];
      StrokeItem item(List<StrokePoint> p, bool tilt) => StrokeItem(
        id: 't',
        points: p,
        color: const Color(0xFF000000),
        strokeWidth: 4,
        pressureWidth: true,
        tiltWidth: tilt,
      );
      final base = heightOf(strokeShape(item(flat, false)).path);
      expect(
        heightOf(strokeShape(item(upright, true)).path),
        closeTo(base, 0.05),
      );
      expect(
        heightOf(strokeShape(item(flat, true)).path),
        closeTo(base * tiltWidthFactor(0.3), 0.3),
      );
      // Not forced on: the pen tool leaves it off by default.
      final c = make()..tool = CanvasTool.pen;
      expect(
        draw(
          c,
          line(Offset.zero, const Offset(50, 0)),
          (i) => 0.2 + i * 0.01,
        ).tiltWidth,
        isFalse,
      );
      c.setPen(tilt: true);
      expect(
        draw(
          c,
          line(Offset.zero, const Offset(50, 0)),
          (i) => 0.2 + i * 0.01,
        ).tiltWidth,
        isTrue,
      );
      c.dispose();
    });
  });

  group('the end of a stroke', () {
    PointerDownEvent down(int micros, Offset at) => PointerDownEvent(
      timeStamp: Duration(microseconds: micros),
      pointer: 7,
      kind: PointerDeviceKind.stylus,
      position: at,
      pressure: 1,
      pressureMax: 4,
    );
    PointerUpEvent up(int micros, Offset at) => PointerUpEvent(
      timeStamp: Duration(microseconds: micros),
      pointer: 7,
      kind: PointerDeviceKind.stylus,
      position: at,
    );

    testWidgets('samples that arrive after Flutter\'s "up" still belong to '
        'the stroke', (tester) async {
      final ink = NativeInk.instance;
      final c = make()..tool = CanvasTool.pen;
      final input = InkStrokeInput();
      ink.handle(nativeMessage(0, 1000, [(1000, const Offset(10, 10), 1)]));
      input.down(down(1000, const Offset(10, 10)), c, (l) => l);
      ink.handle(
        nativeMessage(1, 1000, [
          (5000, const Offset(20, 10), 1.2),
          (9000, const Offset(30, 11), 1.4),
        ]),
      );
      // Flutter reports the lift before UIKit's last samples get here.
      input.up(up(17000, const Offset(50, 14)));
      expect(c.items, isEmpty, reason: 'waits for the touch\'s last samples');
      expect(c.liveStroke, isNotNull, reason: 'the ink stays on screen');
      ink.handle(
        nativeMessage(2, 1000, [
          (13000, const Offset(40, 12), 1.0),
          (17000, const Offset(50, 14), 0.6),
        ]),
      );
      final s = c.items.single as StrokeItem;
      expect(
        [for (final p in s.points) p.offset],
        const [
          Offset(10, 10),
          Offset(20, 10),
          Offset(30, 11),
          Offset(40, 12),
          Offset(50, 14),
        ],
        reason: 'the stretch before lift-off is not cut short',
      );
      expect(s.points.last.pressure, closeTo(0.15, 1e-9));
      expect(s.points.last.altitude, closeTo(1.1, 1e-9));
      expect(s.points.last.time, 16);
      input.dispose();
      c.dispose();
    });

    testWidgets('a lift whose native end never comes is finished after a '
        'short wait; the next stroke never waits', (tester) async {
      final ink = NativeInk.instance;
      final c = make()..tool = CanvasTool.pen;
      final input = InkStrokeInput();
      ink.handle(nativeMessage(0, 1000, [(1000, const Offset(10, 10), 1)]));
      input.down(down(1000, const Offset(10, 10)), c, (l) => l);
      ink.handle(nativeMessage(1, 1000, [(5000, const Offset(20, 10), 1.2)]));
      input.up(up(9000, const Offset(30, 10)));
      expect(c.items, isEmpty);
      await tester.pump(PencilFeed.endGrace + const Duration(milliseconds: 1));
      expect(
        (c.items.single as StrokeItem).points.last.offset,
        const Offset(30, 10),
      );

      // A second stroke begins before the first one's wait is over.
      ink.handle(nativeMessage(0, 50000, [(50000, const Offset(10, 40), 1)]));
      input.down(down(50000, const Offset(10, 40)), c, (l) => l);
      ink.handle(nativeMessage(1, 50000, [(54000, const Offset(20, 40), 1.2)]));
      input.up(up(58000, const Offset(30, 40)));
      ink.handle(nativeMessage(0, 90000, [(90000, const Offset(10, 70), 1)]));
      input.down(down(90000, const Offset(10, 70)), c, (l) => l);
      expect(c.items, hasLength(2), reason: 'finished before the new stroke');
      input.cancel(keepInk: true);
      expect(c.items, hasLength(3));
      input.dispose();
      c.dispose();
    });

    test('without the native observer the stroke is finished at once', () {
      final c = make()..tool = CanvasTool.pen;
      final input = InkStrokeInput();
      input.down(down(1000, const Offset(10, 10)), c, (l) => l);
      input.move(
        PointerMoveEvent(
          timeStamp: const Duration(microseconds: 5000),
          pointer: 7,
          kind: PointerDeviceKind.stylus,
          position: const Offset(20, 10),
          pressure: 2,
          pressureMax: 4,
          tilt: 0.5,
          orientation: 0.1,
        ),
      );
      input.up(up(9000, const Offset(30, 12)));
      final s = c.items.single as StrokeItem;
      expect(s.points, hasLength(3));
      expect(s.points[1].pressure, 0.5);
      // Flutter's tilt (from upright) and orientation, in stored units.
      expect(s.points[1].altitude, closeTo(math.pi / 2 - 0.5, 1e-9));
      expect(s.points[1].azimuth, closeTo(0.1 + math.pi / 2, 1e-9));
      // An event without an angle stores none.
      expect(s.points.first.altitude, isNull);
      input.dispose();
      c.dispose();
    });
  });

  group('erasing and selecting by the ink as drawn', () {
    StrokeItem wedge() => StrokeItem(
      id: 'w',
      points: [
        for (var i = 0; i <= 40; i++)
          StrokePoint(i * 5.0, 0, i < 20 ? 0.0 : 1.0),
      ],
      color: const Color(0xFF000000),
      strokeWidth: 10,
      pressureWidth: true,
    );

    test('a pressure line is hit where its ink is, not at one width', () {
      final s = wedge();
      // Thin end: half width 3.1; thick end: 6.9.
      expect(s.hitTest(const Offset(40, 4), 0), isFalse);
      expect(s.hitTest(const Offset(40, 3), 0), isTrue);
      expect(s.hitTest(const Offset(160, 6), 0), isTrue);
      expect(s.hitTest(const Offset(160, 7.5), 0), isFalse);
      // A line without pressure is as before.
      final even = s.withPressureWidth(false);
      expect(even.hitTest(const Offset(40, 4.9), 0), isTrue);
      expect(even.hitTest(const Offset(160, 5.1), 0), isFalse);
    });

    test('the whole-stroke and the partial eraser follow the drawn width', () {
      for (final mode in [EraserMode.stroke, EraserMode.partial]) {
        final c = make(items: [wedge()])
          ..tool = CanvasTool.eraser
          ..setEraser(mode: mode, size: 4);
        final before = c.items.single;
        // 2 units of eraser reach, 6 above the thin end (half width 3.1):
        // no ink there. One width for the whole line (5) erased it.
        c.pointerDown(const Offset(40, 6));
        c.pointerMove(const Offset(42, 6));
        c.pointerUp();
        expect(c.items, hasLength(1), reason: '$mode at the thin end');
        expect(identical(c.items.single, before), isTrue);
        // 8 above the thick end (half width 6.9) touches ink; one width
        // for the whole line missed it.
        c.pointerDown(const Offset(160, 8));
        c.pointerMove(const Offset(162, 8));
        c.pointerUp();
        if (mode == EraserMode.stroke) {
          expect(c.items, isEmpty);
        } else {
          final left = c.items.whereType<StrokeItem>().toList();
          expect(left, hasLength(2), reason: 'cut in two around the eraser');
          expect(left.every((s) => s.pressureWidth), isTrue);
        }
        c.dispose();
      }
    });

    test('the lasso chooses a line by its ink, not its bounding box', () {
      final diagonal = StrokeItem(
        id: 'd',
        points: [for (var i = 0; i <= 40; i++) StrokePoint(i * 5.0, i * 5.0)],
        color: const Color(0xFF000000),
        strokeWidth: 2,
      );
      void lasso(CanvasController c, List<Offset> loop) {
        c.tool = CanvasTool.lasso;
        c.pointerDown(loop.first);
        for (final p in loop.skip(1)) {
          c.pointerMove(p);
        }
        c.pointerUp();
      }

      final c = make(items: [diagonal]);
      // A loop in the empty corner of the line's bounding box.
      lasso(c, const [
        Offset(140, 20),
        Offset(180, 20),
        Offset(180, 60),
        Offset(140, 60),
        Offset(140, 20),
      ]);
      expect(c.selection, isEmpty);
      // A loop around a part of the line.
      lasso(c, const [
        Offset(80, 80),
        Offset(120, 80),
        Offset(120, 120),
        Offset(80, 120),
        Offset(80, 80),
      ]);
      expect(c.selection, {'d'});
      c.dispose();
    });

    test('a thick pen\'s small zigzag is drawn whole (set-down trimming is '
        'limited to the first and last samples)', () {
      final points = [
        for (var i = 0; i <= 30; i++)
          StrokePoint(i * 2.0, i.isEven ? 0 : 6, 0.3 + (i % 5) * 0.15),
      ];
      final shape = pressureShape(points, 24);
      var outside = 0;
      for (final p in points.skip(3).take(points.length - 6)) {
        if (!shape.path.contains(p.offset)) outside++;
      }
      expect(outside, 0, reason: 'the stroke used to be trimmed to its ends');
    });
  });

  group('the cached picture', () {
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
          color: i % 3 == 0 ? const Color(0x80203040) : const Color(0xFF203040),
          strokeWidth: 2.5,
          pressureWidth: i.isEven,
          penInk: i % 3 == 0,
        ),
    ];

    Future<Uint8List> render(
      CanvasController c, [
      InkRasterCache? cache,
    ]) async {
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

    /// The same picture, except that single soft-edge pixels may differ a
    /// little: a line drawn through a clip is anti-aliased slightly
    /// differently by the rasterizer than the same line drawn whole.
    void expectSameInk(Uint8List a, Uint8List b) {
      var worst = 0, off = 0;
      for (var i = 0; i < a.length; i++) {
        final d = (a[i] - b[i]).abs();
        worst = math.max(worst, d);
        if (d > 2) off++;
      }
      expect(worst, lessThanOrEqualTo(24), reason: 'edge pixels only');
      expect(off, lessThan(a.length * 0.002), reason: 'a handful of values');
    }

    for (final mode in [EraserMode.stroke, EraserMode.partial]) {
      test('erasing ($mode) redraws only the touched area and looks like a '
          'full redraw; an eraser over nothing redraws nothing', () async {
        final c = make(items: strokes(14));
        c.setView(Offset.zero, 1);
        c.setEraser(mode: mode, size: 6);
        c.tool = CanvasTool.eraser;
        final cache = InkRasterCache();
        await render(c, cache);
        await render(c, cache);
        expect(cache.lastPaint, 'rebuild');

        c.pointerDown(const Offset(150, 4)); // empty corner
        await render(c, cache);
        c.pointerMove(const Offset(148, 6));
        await render(c, cache);
        expect(cache.lastPaint, 'image', reason: 'only the ring moved');

        final before = c.items.length;
        c.pointerMove(const Offset(70, 40));
        expect(c.items.length == before && mode == EraserMode.stroke, isFalse);
        final erased = await render(c, cache);
        expect(cache.lastPaint, 'region');
        expectSameInk(erased, await render(c));

        // Two movements between two frames are applied together.
        c.pointerMove(const Offset(40, 70));
        c.pointerMove(const Offset(90, 95));
        final again = await render(c, cache);
        expect(cache.lastPaint, 'region');
        expectSameInk(again, await render(c));

        // When the eraser lifts the picture is made afresh: exact again.
        c.pointerUp();
        final lifted = await render(c, cache);
        expect(cache.lastPaint, 'rebuild');
        expectSame(lifted, await render(c));
        c.undo();
        final undone = await render(c, cache);
        expect(cache.lastPaint, 'rebuild', reason: 'undo is a full change');
        expectSame(undone, await render(c));
        cache.dispose();
        c.dispose();
      });
    }

    test('drawing the lasso line leaves the picture untouched', () async {
      final c = make(items: strokes(14));
      c.setView(Offset.zero, 1);
      c.tool = CanvasTool.lasso;
      final cache = InkRasterCache();
      await render(c, cache);
      await render(c, cache);
      c.pointerDown(const Offset(150, 4));
      await render(c, cache);
      for (final p in const [
        Offset(140, 30),
        Offset(120, 60),
        Offset(90, 80),
      ]) {
        c.pointerMove(p);
        await render(c, cache);
        expect(cache.lastPaint, 'image');
      }
      c.pointerUp();
      cache.dispose();
      c.dispose();
    });
  });

  test('the PDF export is given the shapes that are drawn on screen', () {
    const bg = PageBackground(
      pageIndex: 0,
      assetId: 'a',
      pdfPage: 0,
      width: 300,
      height: 400,
    );
    const page = Rect.fromLTWH(100, 100, 600, 800); // twice the PDF size
    final pen = StrokeItem(
      id: 'p',
      points: [
        for (var i = 0; i <= 20; i++)
          StrokePoint(200.0 + i * 8, i.isEven ? 300 : 330, 0.2 + i * 0.03),
      ],
      color: const Color(0x80112233),
      strokeWidth: 6,
      pressureWidth: true,
      penInk: true,
    );
    final marker = StrokeItem(
      id: 'h',
      points: const [StrokePoint(200, 500), StrokePoint(400, 520)],
      color: const Color(0x61FFD400),
      strokeWidth: 16,
    );
    final out = annotationStrokes([pen, marker], page, bg);
    expect(out, hasLength(2));

    // Pressure ink: the outlines the app fills, in PDF points.
    final fill = out[0]['fill']! as List<List<double>>;
    final contours = inkContours(pen)!;
    expect(fill, hasLength(contours.length));
    expect(contours.length, greaterThan(1), reason: 'outline + turn discs');
    for (var k = 0; k < fill.length; k++) {
      expect(fill[k].length, contours[k].length * 2);
      expect(fill[k][0], closeTo((contours[k][0].dx - 100) / 2, 1e-9));
      expect(fill[k][1], closeTo((contours[k][0].dy - 100) / 2, 1e-9));
    }
    expect(out[0].containsKey('line'), isFalse);
    // The outlines together are exactly the path painted on screen.
    final union = ui.Path();
    for (final c in contours) {
      union.addPolygon(c, true);
    }
    final painted = strokeShape(pen).path;
    for (var x = 195.0; x < 370; x += 3.5) {
      for (var y = 290.0; y < 340; y += 3.5) {
        expect(
          union.contains(Offset(x, y)),
          painted.contains(Offset(x, y)),
          reason: 'at $x, $y',
        );
      }
    }

    // An even line: one centre line stroked once, with its width.
    final line = out[1]['line']! as List<double>;
    expect(out[1]['width'], 8);
    expect(line.sublist(0, 2), [50, 200]);
    expect(line.sublist(line.length - 2), [150, 210]);
    expect(out[1].containsKey('fill'), isFalse);
    expect(out[1]['color'], 0x61FFD400);
  });

  testWidgets('no save starts while the pen is down', (tester) async {
    var saves = 0;
    final c = make(
      onSave: (_) async => saves++,
      saveDelay: const Duration(milliseconds: 100),
    )..tool = CanvasTool.pen;
    draw(c, line(Offset.zero, const Offset(50, 5)), (i) => 0.3 + i * 0.005);
    await tester.pump(const Duration(milliseconds: 50));
    c.pointerDown(const Offset(0, 30), kind: PointerDeviceKind.stylus);
    c.pointerMove(const Offset(20, 30));
    await tester.pump(const Duration(milliseconds: 600));
    expect(saves, 0, reason: 'the stroke is still being written');
    c.pointerUp();
    await tester.pump(const Duration(milliseconds: 400));
    expect(saves, 1);
    // Leaving the page still saves at once.
    c.pointerDown(const Offset(0, 60), kind: PointerDeviceKind.stylus);
    c.pointerMove(const Offset(20, 60));
    c.pointerUp();
    await tester.runAsync(c.flush);
    expect(saves, 2);
    c.cancelPendingLineStraightening();
    c.dispose();
  });
}
