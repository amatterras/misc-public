// Before/after measurements, on deterministic
// synthetic handwriting. Prints a table; the assertions only guard against
// regressions far outside the measured values.
//
// Run alone:  flutter test test/ink_benchmark_test.dart
//
// These run in the Dart VM of `flutter test` (JIT, software rendering), so
// absolute times are NOT iPad times: compare the columns with each other.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_painter.dart';
import 'package:flutter_application_1/features/ink/ink_metrics.dart';
import 'package:flutter_application_1/features/ink/stroke_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ink_samples.dart';
import 'support/legacy_stroke_geometry.dart';

List<StrokePoint> pts(List<PenSample> s) => [
  for (final p in s) StrokePoint(p.position.dx, p.position.dy, p.pressure),
];

double maxDeviation(ui.Path path, List<ui.Offset> truth) {
  final poly = <ui.Offset>[];
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

/// Per-frame cost (µs) of rebuilding the live stroke's shape while
/// [samples] arrive, one frame every [perFrame] samples.
List<int> liveFrameCosts(
  List<StrokePoint> samples,
  int perFrame,
  void Function(List<StrokePoint>) build,
) {
  final costs = <int>[];
  final sw = Stopwatch()..start();
  for (var n = perFrame; n <= samples.length; n += perFrame) {
    final upTo = samples.sublist(0, n);
    final t = sw.elapsedMicroseconds;
    build(upTo);
    costs.add(sw.elapsedMicroseconds - t);
  }
  return costs;
}

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
  final report = StringBuffer();
  void row(String s) => report.writeln(s);

  test('curve fidelity: deviation from the true pen path', () {
    final truth = cursiveLoops(loops: 8, radius: 10, seconds: 1.0);
    final t = [for (final s in truth) s.position];
    row('| input | old curve (midpoints) | new curve (centripetal CR) |');
    row('|---|---|---|');
    for (final (label, step) in [
      ('240 Hz (native, all samples)', 1),
      ('120 Hz (Flutter on 120 Hz iPad)', 2),
      ('60 Hz (Flutter on 60 Hz iPad)', 4),
    ]) {
      final s = pts(everyNth(truth, step));
      final old = maxDeviation(legacyCentreLine(s), t);
      final neu = maxDeviation(centreLine(s), t);
      row('| $label | ${old.toStringAsFixed(2)} px | '
          '${neu.toStringAsFixed(2)} px |');
      expect(neu, lessThanOrEqualTo(old + 0.01));
    }
  });

  test('loop size kept (radius 4 loop, 8 samples)', () {
    final circle = [
      for (var i = 0; i <= 8; i++)
        StrokePoint(
          50 + 4 * math.cos(i * math.pi / 4),
          50 + 4 * math.sin(i * math.pi / 4),
        ),
    ];
    final old = tightBounds(legacyCentreLine(circle)).width / 8;
    final neu = tightBounds(centreLine(circle)).width / 8;
    row('');
    row('Loop width kept: old ${(old * 100).toStringAsFixed(0)} %, '
        'new ${(neu * 100).toStringAsFixed(0)} %');
  });

  test('live geometry cost per frame (4 s stroke)', () {
    final samples = pts(cursiveLoops(loops: 24, seconds: 4));
    // Warm the JIT so the first variant measured is not penalised.
    for (var i = 0; i < 3; i++) {
      liveFrameCosts(samples, 2, (p) => legacyPressureOutline(p, 3));
      liveFrameCosts(samples, 2, (p) => pressureShape(p, 3));
      final warm = LiveInkGeometry();
      liveFrameCosts(
        samples,
        2,
        (p) => warm.shapes(
          StrokeItem(
            id: 'w',
            points: p,
            color: const ui.Color(0xFF000000),
            strokeWidth: 3,
            pressureWidth: true,
          ),
          null,
        ),
      );
    }
    row('');
    row('| live geometry per frame (JIT, µs) | p50 | p95 | max |');
    row('|---|---|---|---|');
    for (final (label, perFrame, kind) in [
      ('old, 60 Hz input @ 60 fps (1 sample/frame)', 4, 0),
      ('old, 240 Hz input @ 120 fps', 2, 0),
      ('new, whole stroke each frame, 240 Hz @ 120 fps', 2, 1),
      ('new, live pieces + tail (the app), 240 Hz @ 120 fps', 2, 2),
    ]) {
      final input = perFrame == 4
          ? [for (var i = 0; i < samples.length; i += 4) samples[i]]
          : samples;
      final live = LiveInkGeometry();
      final costs = liveFrameCosts(
        input,
        perFrame == 4 ? 1 : perFrame,
        (p) => switch (kind) {
          0 => legacyPressureOutline(p, 3),
          1 => pressureShape(p, 3),
          _ => live.shapes(
            StrokeItem(
              id: 'live',
              points: p,
              color: const ui.Color(0xFF000000),
              strokeWidth: 3,
              pressureWidth: true,
            ),
            null,
          ),
        },
      )..sort();
      int at(double q) => costs[((costs.length - 1) * q).round()];
      row('| $label | ${at(.5)} | ${at(.95)} | ${costs.last} |');
    }
  });

  test('finished drawing: per-frame paint with 2000 strokes', () async {
    final items = <CanvasItem>[
      for (var i = 0; i < 2000; i++)
        StrokeItem(
          id: 's$i',
          points: [
            for (var k = 0; k < 40; k++)
              StrokePoint(
                (i % 40) * 30.0 + k * 0.7,
                (i ~/ 40) * 16.0 + 5 * math.sin(k / 3),
                0.3,
              ),
          ],
          color: const ui.Color(0xFF203040),
          strokeWidth: 2,
          pressureWidth: true,
        ),
    ];
    final c = CanvasController(
      document: CanvasDocument(
        id: 'b',
        title: 'b',
        items: items,
        updatedAt: DateTime(2026),
      ),
      onSave: (_) async {},
      saveDelay: const Duration(minutes: 5),
    );
    c.setView(ui.Offset.zero, 1);
    const size = ui.Size(1200, 820);
    Future<(int, int)> frame(InkRasterCache? cache) async {
      final sw = Stopwatch()..start();
      final recorder = ui.PictureRecorder();
      CanvasPainter(
        c,
        rasterCache: cache,
        devicePixelRatio: 1,
      ).paint(ui.Canvas(recorder), size);
      final picture = recorder.endRecording();
      final record = sw.elapsedMicroseconds;
      final image = await picture.toImage(1200, 820);
      final raster = sw.elapsedMicroseconds - record;
      image.dispose();
      picture.dispose();
      return (record, raster);
    }

    for (var i = 0; i < 3; i++) {
      await frame(null);
    }
    final direct = <(int, int)>[];
    for (var i = 0; i < 5; i++) {
      direct.add(await frame(null));
    }
    final cache = InkRasterCache();
    await frame(cache); // direct (first paint of this view)
    await frame(cache); // builds the image
    final cached = <(int, int)>[];
    for (var i = 0; i < 5; i++) {
      cached.add(await frame(cache));
    }
    expect(cache.lastPaint, 'image');
    int med(List<int> v) => (v..sort())[v.length ~/ 2];
    row('');
    row('| unchanged drawing, 2000 strokes (median ms) | record (UI thread) '
        '| raster (software, proxy for GPU) |');
    row('|---|---|---|');
    row('| before: every stroke each frame | '
        '${(med([for (final d in direct) d.$1]) / 1000).toStringAsFixed(2)} | '
        '${(med([for (final d in direct) d.$2]) / 1000).toStringAsFixed(2)} |');
    row('| after: raster cache image | '
        '${(med([for (final d in cached) d.$1]) / 1000).toStringAsFixed(2)} | '
        '${(med([for (final d in cached) d.$2]) / 1000).toStringAsFixed(2)} |');

    // Saving: the JSON encoding that used to run on the UI thread.
    final sw = Stopwatch()..start();
    final text = const JsonEncoder.withIndent(' ').convert(c.document.toJson());
    row('');
    row('Saving this drawing: JSON encoding '
        '${(sw.elapsedMicroseconds / 1000).toStringAsFixed(1)} ms for '
        '${(text.length / 1e6).toStringAsFixed(1)} MB of text '
        '(now off the UI thread above 20 000 samples; this one has 80 000)');
    cache.dispose();
    c.dispose();
  });

  test('erasing, selecting and hit-testing in large drawings', () async {
    List<CanvasItem> drawing(int n) => [
      for (var i = 0; i < n; i++)
        StrokeItem(
          id: 's$i',
          points: [
            for (var k = 0; k < 40; k++)
              StrokePoint(
                (i % 40) * 30.0 + k * 0.7,
                (i ~/ 40) * 16.0 + 5 * math.sin(k / 3),
                0.2 + 0.3 * (k % 7) / 7,
              ),
          ],
          color: const ui.Color(0xFF203040),
          strokeWidth: 2,
          pressureWidth: true,
        ),
    ];
    CanvasController open(int n) => CanvasController(
      document: CanvasDocument(
        id: 'b',
        title: 'b',
        items: drawing(n),
        updatedAt: DateTime(2026),
      ),
      onSave: (_) async {},
      saveDelay: const Duration(minutes: 5),
    )..setView(ui.Offset.zero, 1);
    const size = ui.Size(1200, 820);
    int med(List<int> v) => (v..sort())[v.length ~/ 2];
    int p95(List<int> v) => (v..sort())[(v.length * 0.95).floor()];
    String ms(int micros) => (micros / 1000).toStringAsFixed(2);

    // One frame: paint (UI thread) + software raster of the result.
    Future<(int, int)> frame(CanvasController c, InkRasterCache cache) async {
      final sw = Stopwatch()..start();
      final recorder = ui.PictureRecorder();
      CanvasPainter(
        c,
        rasterCache: cache,
        devicePixelRatio: 1,
      ).paint(ui.Canvas(recorder), size);
      final picture = recorder.endRecording();
      final record = sw.elapsedMicroseconds;
      final image = await picture.toImage(1200, 820);
      final raster = sw.elapsedMicroseconds - record;
      image.dispose();
      picture.dispose();
      return (record, raster);
    }

    // The eraser dragged across a 2000-stroke page, a frame per movement.
    // "before": every movement redrew the whole drawing into the image
    // (what happens when the change log is not used); "after": only the
    // touched area. Same drag, same drawing.
    Future<(List<(int, int)>, List<(int, int)>)> drag({
      required bool regional,
      required bool overInk,
    }) async {
      final c = open(2000)
        ..setEraser(mode: EraserMode.partial, size: 12)
        ..tool = CanvasTool.eraser;
      final cache = InkRasterCache();
      await frame(c, cache);
      await frame(c, cache);
      c.pointerDown(overInk ? const ui.Offset(5, 4) : const ui.Offset(1190, 810));
      await frame(c, cache);
      final frames = <(int, int)>[];
      for (var i = 1; i <= 40; i++) {
        c.pointerMove(
          overInk
              ? ui.Offset(5 + i * 12.0, 4 + i * 9.0)
              : ui.Offset(1190 - i * 0.2, 810),
        );
        if (!regional) {
          c.inkChanges.clear();
          if (!overInk) c.setEraser(); // a full notification, as before
        }
        frames.add(await frame(c, cache));
      }
      final mode = cache.lastPaint;
      c.pointerUp();
      cache.dispose();
      c.dispose();
      expect(
        mode,
        regional ? (overInk ? 'region' : 'image') : 'rebuild',
      );
      return (frames, frames);
    }

    final beforeInk = (await drag(regional: false, overInk: true)).$1;
    final afterInk = (await drag(regional: true, overInk: true)).$1;
    final beforeIdle = (await drag(regional: false, overInk: false)).$1;
    final afterIdle = (await drag(regional: true, overInk: false)).$1;
    row('');
    row('| eraser drag, 2000 strokes, per frame (ms) | paint p50 | paint p95 '
        '| raster p50 (software) |');
    row('|---|---|---|---|');
    for (final (name, f) in [
      ('erasing ink, before: whole drawing redrawn', beforeInk),
      ('erasing ink, after: touched area only', afterInk),
      ('eraser over nothing, before', beforeIdle),
      ('eraser over nothing, after', afterIdle),
    ]) {
      row('| $name | ${ms(med([for (final d in f) d.$1]))} | '
          '${ms(p95([for (final d in f) d.$1]))} | '
          '${ms(med([for (final d in f) d.$2]))} |');
    }
    // Regression thresholds: the touched-area repaint must stay well
    // under the whole-drawing repaint, and an idle eraser must not paint
    // the drawing at all.
    expect(
      med([for (final d in afterInk) d.$1]),
      lessThan(med([for (final d in beforeInk) d.$1]) * 0.6),
    );
    expect(
      med([for (final d in afterIdle) d.$1]),
      lessThan(med([for (final d in beforeIdle) d.$1]) * 0.25),
    );

    // Controller work per pointer event (no painting), 10 000 strokes.
    final c = open(10000);
    final sw = Stopwatch()..start();
    List<int> timed(int n, void Function(int i) run) {
      final out = <int>[];
      for (var i = 0; i < n; i++) {
        final t = sw.elapsedMicroseconds;
        run(i);
        out.add(sw.elapsedMicroseconds - t);
      }
      return out;
    }

    final hits = timed(
      200,
      (i) => c.hitTest(ui.Offset(7.0 * (i % 170), 19.0 * (i % 200))),
    );
    c
      ..setEraser(mode: EraserMode.stroke, size: 12)
      ..tool = CanvasTool.eraser
      ..pointerDown(const ui.Offset(3, 3000));
    final whole = timed(
      200,
      (i) => c.pointerMove(ui.Offset(3 + i * 5.0, 3000 + (i % 9))),
    );
    c
      ..pointerUp()
      ..setEraser(mode: EraserMode.partial, size: 12)
      ..pointerDown(const ui.Offset(3, 3400));
    final partial = timed(
      200,
      (i) => c.pointerMove(ui.Offset(3 + i * 5.0, 3400 + (i % 9))),
    );
    c
      ..pointerUp()
      ..tool = CanvasTool.lasso
      ..pointerDown(const ui.Offset(100, 100));
    for (final p in const [
      ui.Offset(900, 100),
      ui.Offset(900, 1500),
      ui.Offset(100, 1500),
    ]) {
      c.pointerMove(p);
    }
    final lasso = timed(1, (_) => c.pointerUp());
    row('');
    row('| controller work per event, 10 000 strokes (µs, JIT) | p50 | p95 |');
    row('|---|---|---|');
    row('| hit test (tap) | ${med(hits)} | ${p95(hits)} |');
    row('| whole-stroke eraser movement | ${med(whole)} | ${p95(whole)} |');
    row('| partial eraser movement | ${med(partial)} | ${p95(partial)} |');
    row('| lasso release selecting ${c.selection.length} strokes | '
        '${lasso.single} | - |');
    // A pointer event must stay a small part of an 8.3 ms frame even in a
    // very large drawing. Medians, and generous: this is an unoptimized
    // test build on a shared PC, where single events are held up by the
    // garbage collector (see the p95 column).
    expect(med(hits), lessThan(2000));
    expect(med(whole), lessThan(4000));
    expect(med(partial), lessThan(8000));
    expect(c.selection, isNotEmpty);
    c.dispose();
  });

  test('metrics summary format', () {
    final m = InkMetrics.instance..reset();
    m.strokeStarted();
    m.sampleKept();
    m.livePainted(120);
    m.strokeFinished(300);
    expect(m.summary(), contains('Ink: 1 strokes'));
    m.reset();
  });

  tearDownAll(() {
    // ignore: avoid_print
    print('\n===== INK BENCHMARK =====\n$report');
  });
}
