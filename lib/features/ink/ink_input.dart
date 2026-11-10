// What every drawing surface (Canvas, note pages, PDF pages, Calendar days)
// does the same way with a pointer, in one place:
//  * telling the pen from a finger and a mouse;
//  * reading the pen's pressure and angle from an event;
//  * feeding one stroke to its CanvasController, with every Apple Pencil
//    sample when the native observer sends them (PencilFeed);
//  * finishing the stroke without losing the last samples before lift-off.
// Each surface keeps its own rules about WHO may draw (a finger pans the
// canvas, scrolls a note and navigates the calendar in different ways);
// those rules call [mayUseTool] and then hand the stroke to an
// [InkStrokeInput].
import 'dart:math' as math;

import 'package:flutter/gestures.dart';

import '../canvas/canvas_controller.dart';
import 'native_ink.dart';
import 'stroke_geometry.dart';

/// Apple Pencil, a Windows pen or its eraser end.
bool isStylusKind(PointerDeviceKind kind) =>
    kind == PointerDeviceKind.stylus ||
    kind == PointerDeviceKind.invertedStylus;

/// Pen pressure as 0..1 (Apple Pencil reports a raw force on iOS); fingers
/// and mice have none, so they draw at the middle value.
double inkPressure(PointerEvent e) =>
    isStylusKind(e.kind) ? normalizedPressure(e.pressure, e.pressureMax) : 0.5;

/// The pen's angle from a Flutter event as (altitude, azimuth) in the
/// units strokes store (radians; altitude pi/2 = upright; azimuth 0 = the
/// pen leans towards +x), or (null, null) when the event carries none. An
/// event with tilt and orientation both exactly 0 comes from a platform
/// that reports no angle (or a pen held perfectly upright): nothing is
/// stored rather than a made-up angle.
(double?, double?) inkAngle(PointerEvent e) {
  if (!isStylusKind(e.kind)) return (null, null);
  final tilt = e.tilt, orientation = e.orientation;
  if (!tilt.isFinite || !orientation.isFinite) return (null, null);
  if (tilt == 0 && orientation == 0) return (null, null);
  return (
    (math.pi / 2 - tilt).clamp(0.0, math.pi / 2),
    orientation + math.pi / 2,
  );
}

/// Whether a pointer going down may use the current tool on a drawing
/// surface. The pen always may; the mouse with its primary button; a
/// finger only where the surface allows it now ([finger]), and never
/// while the pen is on the screen (a resting palm).
bool mayUseTool(
  PointerDownEvent e, {
  required bool finger,
  bool stylusDown = false,
}) => switch (e.kind) {
  PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => true,
  PointerDeviceKind.mouse => e.buttons & kPrimaryButton != 0,
  PointerDeviceKind.touch => finger && !stylusDown,
  _ => false,
};

/// One pointer's stroke (or drag) on one drawing surface, from down to up.
class InkStrokeInput {
  final PencilFeed _feed = PencilFeed();
  _Stroke? _stroke;

  /// A stroke is being followed (until its up, cancel or [release]).
  bool get active => _stroke != null;

  /// The pointer went down and owns the tool. [toScreen] turns the event's
  /// local position into the controller's screen units; it is kept for
  /// the whole stroke.
  void down(
    PointerDownEvent e,
    CanvasController c,
    Offset Function(Offset local) toScreen, {
    int buttons = kPrimaryButton,
    bool shift = false,
    bool ctrl = false,
  }) {
    // The stroke before this one may still wait for its last samples.
    _feed.completePending();
    final stroke = _Stroke(c, toScreen);
    _stroke = stroke;
    final (altitude, azimuth) = inkAngle(e);
    c.pointerDown(
      toScreen(e.localPosition),
      buttons: buttons,
      kind: e.kind,
      pressure: inkPressure(e),
      shift: shift,
      ctrl: ctrl,
      timeStamp: e.timeStamp,
      altitude: altitude,
      azimuth: azimuth,
    );
    _feed.begin(
      e,
      move: (local, sample) {
        if (!stroke.open) return;
        c.pointerMove(
          toScreen(local),
          pressure: sample.pressure,
          timeStamp: Duration(microseconds: sample.timeMicros),
          altitude: sample.altitude,
          azimuth: sample.azimuth,
        );
      },
      predict: (local) {
        if (identical(_stroke, stroke)) {
          c.setPredictedPoint(local == null ? null : toScreen(local));
        }
      },
    );
  }

  /// A Flutter move of the stroke's pointer.
  void move(PointerMoveEvent e) {
    final stroke = _stroke;
    if (stroke == null) return;
    // Native Pencil samples may already have delivered this moment.
    if (!_feed.flutterMove(e)) return;
    final (altitude, azimuth) = inkAngle(e);
    stroke.controller.pointerMove(
      stroke.toScreen(e.localPosition),
      pressure: inkPressure(e),
      timeStamp: e.timeStamp,
      altitude: altitude,
      azimuth: azimuth,
    );
  }

  /// The pointer lifted. The stroke is finished with every sample that
  /// belongs to it: UIKit's last coalesced Pencil samples can reach Dart
  /// just after Flutter's own "up", so the stroke waits for them (at most
  /// [PencilFeed.endGrace]; not at all without the native observer). The
  /// ink stays on screen meanwhile, so nothing is seen of the wait.
  void up(PointerUpEvent e) {
    final stroke = _stroke;
    if (stroke == null) return;
    _stroke = null;
    final screen = stroke.toScreen(e.localPosition);
    final timeStamp = e.timeStamp;
    _feed.finish(() {
      stroke.open = false;
      if (stroke.controller.disposed) return;
      stroke.controller.pointerUp(screen: screen, timeStamp: timeStamp);
    });
  }

  /// The platform took the pointer away. Pencil writing interrupted by
  /// the system is kept ([keepInk]), not erased.
  void cancel({required bool keepInk}) {
    final stroke = _stroke;
    if (stroke == null) return;
    _stroke = null;
    stroke.open = false;
    _feed.end();
    stroke.controller.pointerCancel(keepInk: keepInk);
  }

  /// Stops following without telling the controller (the surface ends or
  /// cancels the stroke itself, e.g. a second finger starts a pinch).
  void release() {
    _stroke?.open = false;
    _stroke = null;
    _feed.end();
  }

  /// The surface goes away: a stroke still waiting for its last samples
  /// is finished now.
  void dispose() {
    _feed.completePending();
    release();
  }
}

class _Stroke {
  _Stroke(this.controller, this.toScreen);

  final CanvasController controller;
  final Offset Function(Offset local) toScreen;

  /// Samples may still be added (until the stroke is committed).
  bool open = true;
}
