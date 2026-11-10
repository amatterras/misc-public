// Full-rate Apple Pencil samples from UIKit, merged into Flutter's pointer
// stream.
//
// Why: Flutter's iOS engine sends Dart ONE sample per UIKit touch callback
// (FlutterViewController.mm dispatchTouches: no coalescedTouchesForTouch:,
// no predictedTouchesForTouch:). UIKit calls back once per display frame,
// while Apple Pencil is sampled at 240 Hz, so Dart saw only every 2nd
// sample on a 120 Hz iPad Pro and every 4th on a 60 Hz iPad. Fast
// handwriting lost its curves (straight chords between sparse samples)
// and the app had to guess the tip's position from old samples.
//
// How: InkTouchObserver (ios/Runner/AppDelegate.swift) watches the touches
// on the Flutter view without taking them, and for every Pencil touch
// callback sends all coalesced samples plus UIKit's predicted samples on
// the "theapp/ink" channel. [PencilFeed] gives them to the surface that
// owns the stroke and skips the Flutter moves they already cover. Without
// the native side (Windows, Android, an older iPad build) nothing arrives
// and every surface keeps using Flutter's events exactly as before.
//
// Message (Float64List): [1, phase, beginTimeMicros, n, m,
//   n × (timeMicros, x, y, force, maxForce, altitude, azimuth),
//   m × the same for predicted samples]
// phase: 0 began, 1 moved, 2 ended, 3 cancelled. x/y are in the Flutter
// view's coordinates (logical pixels = UIKit points), like
// PointerEvent.position. Times use UITouch.timestamp × 10⁶, exactly as the
// engine fills PointerEvent.timeStamp, so the two streams can be matched.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'ink_metrics.dart';
import 'stroke_geometry.dart';

/// One Pencil sample as UIKit reported it.
class NativeInkSample {
  const NativeInkSample({
    required this.timeMicros,
    required this.position,
    required this.pressure,
    required this.altitude,
    required this.azimuth,
  });

  final int timeMicros;

  /// Global position (Flutter view coordinates, logical pixels).
  final Offset position;

  /// 0..1 (force / maximum possible force).
  final double pressure;

  /// The pen's angle above the screen (radians, pi/2 = upright) and the
  /// direction it leans towards (radians, 0 = along +x), as UIKit
  /// measured them; kept with the stroke's points.
  final double? altitude;
  final double? azimuth;
}

/// The native samples of one Pencil touch, from touch-down to lift.
class NativeInkTrack {
  NativeInkTrack(this.beginMicros);

  final int beginMicros;
  final List<NativeInkSample> samples = [];
  List<NativeInkSample> predicted = const [];
  bool ended = false;
  bool cancelled = false;
  int touchedAt = 0;

  /// Called when samples arrive while a surface follows this track.
  VoidCallback? listener;
}

class NativeInk {
  NativeInk._();
  static final NativeInk instance = NativeInk._();

  static const channelName = 'theapp/ink';
  static const _channel = BasicMessageChannel<Object?>(
    channelName,
    StandardMessageCodec(),
  );

  bool _installed = false;

  /// Native samples have arrived in this session (the iPad build has the
  /// native observer and it works).
  bool get receiving => _receiving;
  bool _receiving = false;

  final Map<int, NativeInkTrack> _tracks = {};
  final List<PencilFeed> _waiting = [];
  final Stopwatch _clock = Stopwatch()..start();

  /// Starts listening (iOS). Safe to call more than once.
  void install() {
    if (_installed) return;
    _installed = true;
    _channel.setMessageHandler((message) async {
      if (message is Float64List) handle(message);
      return null;
    });
  }

  /// Takes one native message (also used by tests).
  @visibleForTesting
  void handle(Float64List m) {
    if (m.length < 5 || m[0] != 1) return;
    final phase = m[1].toInt();
    final begin = m[2].toInt();
    final n = m[3].toInt(), k = m[4].toInt();
    if (n < 0 || k < 0 || m.length < 5 + 7 * (n + k)) return;
    List<NativeInkSample> read(int from, int count) => [
      for (var i = 0; i < count; i++)
        () {
          final o = from + i * 7;
          final x = m[o + 1], y = m[o + 2];
          final altitude = m[o + 5], azimuth = m[o + 6];
          return NativeInkSample(
            timeMicros: m[o].toInt(),
            position: Offset(x.isFinite ? x : 0, y.isFinite ? y : 0),
            pressure: normalizedPressure(m[o + 3], m[o + 4]),
            altitude: altitude.isFinite ? altitude : null,
            azimuth: azimuth.isFinite ? azimuth : null,
          );
        }(),
    ];

    _receiving = true;
    _prune();
    final track = _tracks.putIfAbsent(begin, () => NativeInkTrack(begin));
    track.touchedAt = _clock.elapsedMilliseconds;
    track.samples.addAll(read(5, n));
    track.predicted = read(5 + 7 * n, k);
    if (phase == 2) track.ended = true;
    if (phase == 3) track.cancelled = true;
    if (track.listener == null) {
      // A surface may have seen Flutter's pointer-down first.
      for (final feed in [..._waiting]) {
        if (_matches(feed._downMicros, begin)) {
          _waiting.remove(feed);
          feed._attach(track);
          break;
        }
      }
    }
    track.listener?.call();
  }

  /// The track whose touch went down at [down] (Flutter's pointer-down
  /// time stamp), if UIKit has reported it already.
  NativeInkTrack? _claim(int downMicros) {
    for (final t in _tracks.values) {
      if (t.listener == null && _matches(downMicros, t.beginMicros)) return t;
    }
    return null;
  }

  // Both sides compute UITouch.timestamp × 10⁶ and truncate; allow a
  // microsecond of rounding difference.
  static bool _matches(int a, int b) => (a - b).abs() <= 1;

  void _prune() {
    final now = _clock.elapsedMilliseconds;
    _tracks.removeWhere(
      (_, t) =>
          t.listener == null &&
          (now - t.touchedAt > 3000 ||
              ((t.ended || t.cancelled) && now - t.touchedAt > 1000)),
    );
    if (_tracks.length > 64) {
      final oldest = _tracks.values.where((t) => t.listener == null).toList()
        ..sort((a, b) => a.touchedAt.compareTo(b.touchedAt));
      for (final t in oldest.take(_tracks.length - 64)) {
        _tracks.remove(t.beginMicros);
      }
    }
  }

  void _release(NativeInkTrack track) {
    track.listener = null;
    if (track.ended || track.cancelled) _tracks.remove(track.beginMicros);
  }

  @visibleForTesting
  void resetForTest() {
    _tracks.clear();
    _waiting.clear();
    _receiving = false;
  }
}

/// Feeds one surface's stroke from Flutter pointer events, upgraded to
/// every Pencil sample (and UIKit's prediction) when the native side sends
/// them. One per surface; it follows one Pencil touch at a time.
class PencilFeed {
  int? _pointer;
  int _downMicros = 0;
  Matrix4? _transform;
  NativeInkTrack? _track;
  int _consumed = 0;
  int _lastMicros = -1;
  void Function(Offset local, NativeInkSample sample)? _move;
  void Function(Offset? local)? _predict;
  VoidCallback? _pendingCommit;
  Timer? _pendingTimer;

  /// How long a lifted stroke waits for UIKit's last samples (see
  /// [finish]): about two frames at 120 Hz. They normally arrive before
  /// Flutter's own "up"; this only covers the rare other order.
  static Duration endGrace = const Duration(milliseconds: 24);

  /// Whether native samples drive the current stroke.
  bool get native => _track != null;

  /// Starts following the Pencil touch [down]. [move] receives every
  /// native sample (in the same local coordinates as [down]); [predict]
  /// UIKit's predicted tip, or null when there is none.
  void begin(
    PointerDownEvent down, {
    required void Function(Offset local, NativeInkSample sample) move,
    required void Function(Offset? local) predict,
  }) {
    completePending();
    end();
    if (down.kind != PointerDeviceKind.stylus) return;
    _pointer = down.pointer;
    _downMicros = down.timeStamp.inMicroseconds;
    _lastMicros = _downMicros;
    _transform = down.transform;
    _move = move;
    _predict = predict;
    final ink = NativeInk.instance;
    if (!ink.receiving) return;
    final track = ink._claim(_downMicros);
    if (track != null) {
      _attach(track);
    } else {
      ink._waiting.add(this);
    }
  }

  void _attach(NativeInkTrack track) {
    _track = track;
    // Samples up to the touch-down are already in the stroke (the down
    // event itself); the rest are new.
    _consumed = 0;
    track.listener = _drain;
    _drain();
  }

  /// A Flutter move of the followed pointer. Returns whether the caller
  /// should still feed it to the controller: false when native samples
  /// already delivered that moment (Flutter's move is the last of them).
  bool flutterMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return true;
    InkMetrics.instance.flutterMove();
    final t = e.timeStamp.inMicroseconds;
    if (_track == null) {
      _lastMicros = math.max(_lastMicros, t);
      return true;
    }
    if (t <= _lastMicros) return false;
    // Native samples are late for once: use Flutter's, never lose input.
    _lastMicros = t;
    return true;
  }

  void _drain() {
    final track = _track;
    final move = _move;
    if (track == null || move == null) return;
    final samples = track.samples;
    for (var i = _consumed; i < samples.length; i++) {
      final s = samples[i];
      if (s.timeMicros <= _lastMicros) continue;
      _lastMicros = s.timeMicros;
      InkMetrics.instance.nativeSample();
      move(_local(s.position), s);
    }
    _consumed = samples.length;
    final over = track.ended || track.cancelled;
    final predicted = over || track.predicted.isEmpty
        ? null
        : _local(track.predicted.last.position);
    _predict?.call(predicted);
    // The touch's last samples have arrived: a stroke waiting for them
    // is finished now.
    if (over && _pendingCommit != null) completePending();
  }

  /// The pointer lifted (Flutter's "up"). Calls [commit] once every native
  /// sample of the touch has been delivered to `move`: at once when UIKit
  /// has already reported the touch's end (or nothing native drives the
  /// stroke), otherwise when that report arrives, or after [endGrace].
  /// Before this, a touch whose last coalesced samples reached Dart after
  /// Flutter's "up" lost them (the end of the stroke was cut short).
  void finish(VoidCallback commit) {
    final track = _track;
    if (track == null || track.ended || track.cancelled) {
      _drain();
      end();
      commit();
      return;
    }
    _pendingCommit = commit;
    _pendingTimer?.cancel();
    _pendingTimer = Timer(endGrace, completePending);
  }

  /// Finishes a stroke that is waiting in [finish] now.
  void completePending() {
    final commit = _pendingCommit;
    if (commit == null) return;
    _pendingCommit = null;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _drain();
    end();
    commit();
  }

  Offset _local(Offset global) =>
      PointerEvent.transformPosition(_transform, global);

  /// Stops following (pointer up or cancel, or the surface goes away).
  void end() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingCommit = null;
    final track = _track;
    if (track != null) NativeInk.instance._release(track);
    NativeInk.instance._waiting.remove(this);
    _track = null;
    _pointer = null;
    _move = null;
    _predict = null;
    _consumed = 0;
  }
}
