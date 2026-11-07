// Measurements of the ink pipeline, taken while people actually write.
//
// Cheap enough to stay on: a few integer counters and one clock read per
// pen sample. Every [summaryEvery] strokes a one-line summary goes to the
// app log (THEapp-log.txt; on iPad: Files → On My iPad → THEapp), so real
// device numbers can be read without a Mac or a debugger.
//
// What is measured (INK_ENGINE_REPORT.md §Instrumentation):
//  * samples: Flutter pointer moves, native (coalesced) Pencil samples,
//    samples kept, samples merged away as closer than half a pixel;
//  * input→paint: from the moment a sample is handled in Dart to the moment
//    the live layer paints it (includes waiting for the next frame);
//  * geometry: time to build the live stroke's shape in each paint;
//  * finish: time to turn the live stroke into a saved stroke on lift;
//  * frames: frames during writing whose build + raster took longer than
//    one refresh interval (SchedulerBinding frame timings).
// It cannot see the time before Dart receives an event (touch screen,
// UIKit, engine) or after the frame is handed to the GPU; those need a
// high-speed camera (see the report).
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';

import '../../data/storage/app_log.dart';

class InkMetrics {
  InkMetrics._();
  static final InkMetrics instance = InkMetrics._();

  /// Strokes between two log summaries (0 turns logging off).
  static int summaryEvery = 50;

  final Stopwatch _clock = Stopwatch()..start();
  int get _now => _clock.elapsedMicroseconds;

  // Current stroke.
  bool _inStroke = false;
  int _strokeStart = 0;
  int? _pendingSince;

  // Totals since the last summary.
  int strokes = 0;
  int flutterMoves = 0;
  int nativeSamples = 0;
  int keptSamples = 0;
  int mergedSamples = 0;
  int cancelledKept = 0;
  int cancelledDropped = 0;
  int slowFrames = 0;
  int frames = 0;
  final List<int> inputToPaint = [];
  final List<int> geometry = [];
  final List<int> finish = [];
  bool _timingsHooked = false;

  void strokeStarted() {
    _inStroke = true;
    _strokeStart = _now;
    _pendingSince = null;
    _hookTimings();
  }

  void flutterMove() => flutterMoves++;

  void nativeSample() => nativeSamples++;

  /// A sample was added to the live stroke (now waiting to be painted).
  void sampleKept() {
    keptSamples++;
    _pendingSince ??= _now;
  }

  void sampleMerged() => mergedSamples++;

  /// The live layer painted; [geometryMicros] spent building the shape.
  void livePainted(int geometryMicros) {
    final since = _pendingSince;
    if (since != null) _add(inputToPaint, _now - since);
    _pendingSince = null;
    _add(geometry, geometryMicros);
  }

  int startTimer() => _now;
  int elapsedSince(int start) => _now - start;

  void strokeFinished(int finishMicros) {
    if (!_inStroke) return;
    _inStroke = false;
    _add(finish, finishMicros);
    strokes++;
    if (summaryEvery > 0 && strokes >= summaryEvery) logSummary();
  }

  void strokeCancelled({required bool kept}) {
    kept ? cancelledKept++ : cancelledDropped++;
    _inStroke = false;
  }

  bool get inStroke => _inStroke;
  int get strokeAgeMicros => _inStroke ? _now - _strokeStart : 0;

  void _hookTimings() {
    if (_timingsHooked) return;
    _timingsHooked = true;
    try {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    } catch (_) {
      // No binding (plain unit tests): frame timings are simply not taken.
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_inStroke) return;
    for (final t in timings) {
      frames++;
      // 8.4 ms: one refresh at 120 Hz. At 60 Hz this counts frames that
      // were merely busy, so the log also states the counts, not a verdict.
      if (t.totalSpan.inMicroseconds > 8400) slowFrames++;
    }
  }

  void _add(List<int> list, int v) {
    if (list.length < 20000) list.add(v);
  }

  /// p50 / p95 / p99 / max of [values] in milliseconds.
  static String percentiles(List<int> values) {
    if (values.isEmpty) return 'n/a';
    final s = [...values]..sort();
    String at(double q) {
      final i = math.min(s.length - 1, (q * (s.length - 1)).round());
      return (s[i] / 1000).toStringAsFixed(2);
    }

    return 'p50 ${at(.5)} p95 ${at(.95)} p99 ${at(.99)} '
        'max ${(s.last / 1000).toStringAsFixed(2)} ms';
  }

  String summary() =>
      'Ink: $strokes strokes; samples flutter=$flutterMoves '
      'native=$nativeSamples kept=$keptSamples merged=$mergedSamples; '
      'cancel kept=$cancelledKept dropped=$cancelledDropped; '
      'input→paint ${percentiles(inputToPaint)}; '
      'geometry ${percentiles(geometry)}; '
      'finish ${percentiles(finish)}; '
      'frames while writing $frames, over 8.4 ms $slowFrames';

  void logSummary() {
    AppLog.info(summary());
    reset();
  }

  void reset() {
    strokes = flutterMoves = nativeSamples = keptSamples = mergedSamples = 0;
    cancelledKept = cancelledDropped = slowFrames = frames = 0;
    inputToPaint.clear();
    geometry.clear();
    finish.clear();
  }
}
