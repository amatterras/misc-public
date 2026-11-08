// Hold-to-straighten must tell a shaky straight line (straighten it) from a
// gentle wave someone drew on purpose (leave it). Both can be equally close
// to their chord and equally long for their length, so the classifier looks
// at the swings: wobble stays within a few screen pixels; a wave makes
// repeated lobes reaching well away from the line (see looksLikeLine).
import 'dart:math' as math;

import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/ink/stroke_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

List<StrokePoint> pts(Iterable<Offset> o) => [
  for (final p in o) StrokePoint(p.dx, p.dy, 0.5),
];

/// Rotates [p] around [c] by [deg] degrees.
Offset turn(Offset p, Offset c, double deg) {
  final r = deg * math.pi / 180;
  final v = p - c;
  return c +
      Offset(
        v.dx * math.cos(r) - v.dy * math.sin(r),
        v.dx * math.sin(r) + v.dy * math.cos(r),
      );
}

/// A hand-drawn straight line: small, quick side-to-side shake.
List<Offset> shaky(double length, double shake, {double step = 6}) {
  final n = math.max(4, (length / step).round());
  return [
    for (var i = 0; i <= n; i++)
      Offset(
        length * i / n,
        i == 0 || i == n ? 0 : shake * math.sin(i * 1.7),
      ),
  ];
}

/// Uneven jitter (no regular rhythm), within ±[shake].
List<Offset> jittery(double length, double shake) {
  final r = math.Random(7);
  final n = (length / 4).round();
  return [
    for (var i = 0; i <= n; i++)
      Offset(
        length * i / n,
        i == 0 || i == n ? 0 : (r.nextDouble() * 2 - 1) * shake,
      ),
  ];
}

/// A wave drawn on purpose.
List<Offset> wave(double length, double amplitude, double wavelength) {
  final n = (length / 5).round();
  return [
    for (var i = 0; i <= n; i++)
      Offset(
        length * i / n,
        amplitude * math.sin(2 * math.pi * (length * i / n) / wavelength),
      ),
  ];
}

void main() {
  const angles = [0.0, 30.0, 90.0, 145.0, 270.0];

  group('shaky straight lines still straighten', () {
    for (final length in [60.0, 200.0, 800.0]) {
      for (final shake in [1.0, 2.0, 3.0, 4.0]) {
        test('length $length, shake $shake px', () {
          for (final deg in angles) {
            final line = [
              for (final p in shaky(length, shake))
                turn(p + const Offset(100, 100), const Offset(100, 100), deg),
            ];
            expect(looksLikeLine(pts(line), 1), isTrue, reason: '$deg°');
          }
        });
      }
    }

    test('uneven jitter of a few pixels', () {
      for (final length in [120.0, 400.0]) {
        expect(looksLikeLine(pts(jittery(length, 3)), 1), isTrue);
      }
    });

    test('one slight bow (a curved-ish line) is still a line', () {
      final bow = [
        for (var i = 0; i <= 80; i++)
          Offset(i * 5.0, 9 * math.sin(math.pi * i / 80)),
      ];
      expect(looksLikeLine(pts(bow), 1), isTrue);
    });

    test('zoom: the same shake on screen is judged the same', () {
      // Drawn at 4x zoom: 1 world unit is 4 screen pixels.
      final line = [
        for (final p in shaky(100, 0.8)) p,
      ];
      expect(looksLikeLine(pts(line), 4), isTrue);
    });
  });

  group('waves drawn on purpose are left alone', () {
    for (final amplitude in [10.0, 14.0, 20.0]) {
      for (final wavelength in [60.0, 94.0, 140.0]) {
        test('amplitude $amplitude, wavelength $wavelength', () {
          for (final deg in angles) {
            final w = [
              for (final p in wave(320, amplitude, wavelength))
                turn(p + const Offset(100, 300), const Offset(100, 300), deg),
            ];
            expect(looksLikeLine(pts(w), 1), isFalse, reason: '$deg°');
          }
        });
      }
    }

    test('the wave from the hold-to-shape test', () {
      final w = [
        for (var i = 0; i <= 60; i++)
          Offset(100 + i * 5.0, 300 + 14 * math.sin(i / 3)),
      ];
      expect(looksLikeLine(pts(w), 1), isFalse);
    });

    test('zoomed out, a wave small in world units but large on screen', () {
      // At 0.5x the same screen wave is twice as large in world units; at
      // 3x, a world wave of amplitude 4 is 12 px on screen: still a wave.
      expect(looksLikeLine(pts(wave(150, 4, 40)), 3), isFalse);
    });
  });
}
