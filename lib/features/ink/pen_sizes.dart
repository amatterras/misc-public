// The pen thickness choices, shared by the canvas toolbar and the Calendar
// pen (world units: 1 = one point at 100% zoom). The original four (1.5,
// 2.5, 5, 9) are unchanged; two thinner and two thicker were added on
// 2026-10-24, and on 2026-10-26 two even thinner (0.45, 0.6) and one
// thicker (30). Only new strokes use a new choice: strokes keep the width
// they were drawn with.
library;

const penSizes = [0.45, 0.6, 0.8, 1.1, 1.5, 2.5, 5.0, 9.0, 14.0, 20.0, 30.0];

/// The thickness a new canvas or note page starts with.
const defaultPenSize = 2.5;

/// A saved thickness made safe: missing, not a number, or outside the
/// choices gives the default or the nearest end (older saved values in
/// range are kept exactly).
double savedPenWidth(Object? saved) {
  final v = saved is num ? saved.toDouble() : null;
  if (v == null || !v.isFinite || v <= 0) return defaultPenSize;
  return v.clamp(penSizes.first, penSizes.last);
}
