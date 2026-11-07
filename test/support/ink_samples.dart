// Deterministic pen-sample sequences for ink tests and benchmarks:
// handwriting-like curves sampled as Apple Pencil would (240 Hz), and the
// sparser streams Flutter used to see (one sample per display frame).
import 'dart:math' as math;
import 'dart:ui';

/// One pen sample: position (logical pixels), pressure 0..1, time (µs).
class PenSample {
  const PenSample(this.position, this.pressure, this.micros);
  final Offset position;
  final double pressure;
  final int micros;
}

/// Loops like a row of cursive "l"s (a prolate cycloid): [loops] loops of
/// radius [radius], drawn in [seconds] at [hz] samples per second.
List<PenSample> cursiveLoops({
  int loops = 6,
  double radius = 14,
  double seconds = 1.2,
  int hz = 240,
  Offset origin = const Offset(100, 200),
}) {
  final n = (seconds * hz).round();
  return [
    for (var i = 0; i <= n; i++)
      () {
        final t = i / n;
        final a = t * loops * 2 * math.pi;
        final x = origin.dx + t * loops * radius * 1.6 - radius * math.sin(a);
        final y = origin.dy - radius + radius * math.cos(a);
        // Pressure rises into each down-stroke, like real writing.
        final p = 0.25 + 0.12 * math.sin(a + 1);
        return PenSample(Offset(x, y), p, (i * 1e6 / hz).round());
      }(),
  ];
}

/// A zig-zag with hairpin turns (the points of "w" / "v"): [teeth] teeth.
List<PenSample> zigZag({
  int teeth = 6,
  double height = 30,
  double seconds = 0.8,
  int hz = 240,
}) {
  final n = (seconds * hz).round();
  return [
    for (var i = 0; i <= n; i++)
      () {
        final t = i / n;
        final phase = (t * teeth) % 1;
        final tri = phase < 0.5 ? phase * 2 : 2 - phase * 2;
        return PenSample(
          Offset(50 + t * teeth * 12, 100 + tri * height),
          0.3,
          (i * 1e6 / hz).round(),
        );
      }(),
  ];
}

/// Every [step]-th sample (the first and last always kept): what Flutter's
/// engine delivered when UIKit coalesced [step] Pencil samples per frame.
List<PenSample> everyNth(List<PenSample> s, int step) => [
  for (var i = 0; i < s.length; i++)
    if (i % step == 0 || i == s.length - 1) s[i],
];
