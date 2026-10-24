// Freeform drawing on the Calendar. All of it is one synced document
// ("calendar-ink") laid out as an endless strip of days: day d owns the
// world rectangle [inkDayRect]. So every stroke belongs to its date, stays
// with it when the shown range or view changes, and syncs per stroke like
// any canvas item. Drawing happens only in Draw mode, so taps on dates and
// entries work as usual otherwise.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/models/record.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_painter.dart';
import '../ink/stroke_geometry.dart';

/// Size of one day in the ink document (world units, the 38-day grid's
/// cell size).
const inkDaySize = Size(196, 312);

final _epoch = DateTime(2000);

/// The world rectangle of [day] in the calendar ink document.
Rect inkDayRect(DateTime day) => Rect.fromLTWH(
  daysBetween(_epoch, day) * inkDaySize.width,
  0,
  inkDaySize.width,
  inkDaySize.height,
);

/// The day a world position belongs to.
DateTime inkDayAt(Offset world) =>
    addDays(_epoch, (world.dx / inkDaySize.width).floor());

/// Decides, for every pointer on the Calendar, whether it draws or
/// navigates while Draw mode is on. One for the whole grid, shared by every
/// day cell (a stroke and a pinch can start in different cells):
/// - the Pencil and the mouse always draw (one stroke at a time);
/// - one finger draws;
/// - a second finger makes it a pinch / two-finger pan: the finger stroke
///   in progress is cancelled (nothing half-drawn is kept);
/// - fingers that touch while the Pencil draws are a resting palm: they
///   neither draw nor move the Calendar.
/// Nothing stays locked: every up or cancel is forgotten at once.
class CalendarInkArbiter extends ChangeNotifier {
  CalendarInkArbiter(this.controller);

  final CanvasController controller;
  final _touches = <int>{};
  int? _stylus;

  /// The pointer drawing the current stroke, and its kind.
  int? drawingPointer;
  PointerDeviceKind? _drawingKind;

  /// Two or more fingers and no Pencil: the Calendar may pinch and pan.
  bool get navigating => _touches.length >= 2 && _stylus == null;

  /// The Pencil is on the screen (palm rejection).
  bool get stylusDown => _stylus != null;

  bool _isStylus(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;

  /// Every pointer that goes down on the grid (repeats are harmless).
  void down(PointerDownEvent e) {
    final wasNavigating = navigating, wasStylus = stylusDown;
    if (e.kind == PointerDeviceKind.touch && _touches.add(e.pointer)) {
      if (_touches.length >= 2 && _drawingKind == PointerDeviceKind.touch) {
        // The first finger was the start of a pinch, not a line.
        controller.pointerCancel();
        drawingPointer = null;
        _drawingKind = null;
      }
    } else if (_isStylus(e)) {
      _stylus = e.pointer;
    }
    if (navigating != wasNavigating || stylusDown != wasStylus) {
      notifyListeners();
    }
  }

  /// Whether [e] (going down) starts a stroke; if so it owns the stroke.
  bool claim(PointerDownEvent e) {
    if (drawingPointer != null) return false;
    final ok = switch (e.kind) {
      PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => true,
      PointerDeviceKind.mouse => e.buttons & kPrimaryButton != 0,
      PointerDeviceKind.touch => _touches.length <= 1 && _stylus == null,
      _ => false,
    };
    if (ok) {
      drawingPointer = e.pointer;
      _drawingKind = e.kind;
    }
    return ok;
  }

  bool owns(int pointer) => drawingPointer == pointer;

  /// A pointer went up or was cancelled.
  void release(int pointer) {
    final wasNavigating = navigating, wasStylus = stylusDown;
    _touches.remove(pointer);
    if (_stylus == pointer) _stylus = null;
    if (drawingPointer == pointer) {
      drawingPointer = null;
      _drawingKind = null;
    }
    if (navigating != wasNavigating || stylusDown != wasStylus) {
      notifyListeners();
    }
  }
}

/// Draws (and, in Draw mode, records) the ink of one day cell.
class DayInkLayer extends StatefulWidget {
  const DayInkLayer({
    super.key,
    required this.controller,
    required this.day,
    required this.drawing,
    this.arbiter,
  });

  final CanvasController controller;
  final DateTime day;
  final bool drawing;

  /// Shared by every cell of a grid (see [CalendarInkArbiter]); without
  /// one, this cell decides alone.
  final CalendarInkArbiter? arbiter;

  @override
  State<DayInkLayer> createState() => _DayInkLayerState();
}

class _DayInkLayerState extends State<DayInkLayer> {
  late CalendarInkArbiter _own = CalendarInkArbiter(widget.controller);
  CalendarInkArbiter get _arbiter => widget.arbiter ?? _own;

  @override
  void didUpdateWidget(DayInkLayer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _own = CalendarInkArbiter(widget.controller);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final rect = inkDayRect(widget.day);
      final scale = box.maxWidth / inkDaySize.width;
      final c = widget.controller;
      Offset screen(Offset local) => (rect.topLeft + local / scale) * scale;
      final paint = Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: CanvasPainter(c, page: rect, pageScale: scale),
            ),
          ),
          RepaintBoundary(
            child: CustomPaint(
              painter: LiveInkPainter(c, page: rect, pageScale: scale),
            ),
          ),
        ],
      );
      if (!widget.drawing) return IgnorePointer(child: paint);
      return Listener(
        key: ValueKey('calendar-ink-${dayKey(widget.day)}'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          final arbiter = _arbiter..down(e);
          if (!arbiter.claim(e)) return;
          c.setView(Offset.zero, scale);
          c.pointerDown(
            screen(e.localPosition),
            kind: e.kind,
            pressure: e.kind == PointerDeviceKind.stylus
                ? normalizedPressure(e.pressure, e.pressureMax)
                : 0.5,
            timeStamp: e.timeStamp,
          );
        },
        onPointerMove: (e) {
          if (!_arbiter.owns(e.pointer)) return;
          c.pointerMove(
            screen(e.localPosition),
            pressure: e.kind == PointerDeviceKind.stylus
                ? normalizedPressure(e.pressure, e.pressureMax)
                : 0.5,
            timeStamp: e.timeStamp,
          );
        },
        onPointerUp: (e) {
          final owned = _arbiter.owns(e.pointer);
          _arbiter.release(e.pointer);
          if (owned) c.pointerUp();
        },
        onPointerCancel: (e) {
          final owned = _arbiter.owns(e.pointer);
          _arbiter.release(e.pointer);
          if (owned) c.pointerCancel();
        },
        child: paint,
      );
    },
  );
}

/// Apple Pencil Pro squeeze while the Calendar is shown: the pen becomes
/// the eraser while the squeeze is held (Draw mode is switched on for that
/// time if it was off), and everything goes back as it was when the
/// squeeze ends, is cancelled, the app goes to the background or another
/// page opens. Only the native squeeze event (iOS 17.5+, Pencil Pro)
/// calls [phase]; ordinary pointer events never do.
class CalendarSqueeze {
  CalendarSqueeze(
    this.ink, {
    required this.visible,
    required this.drawing,
    required this.setDrawing,
  });

  final CanvasController ink;
  final bool Function() visible;
  final bool Function() drawing;
  final void Function(bool on) setDrawing;

  bool? _drawingBefore;

  /// Whether a squeeze is being held now.
  bool get active => _drawingBefore != null;

  /// A squeeze phase from iOS: "began", "ended" or "cancelled".
  void phase(String phase) {
    switch (phase) {
      case 'began':
        if (!visible() || active) return;
        _drawingBefore = drawing();
        setDrawing(true);
        ink.squeezeBegan();
      case 'ended' || 'cancelled':
        end();
    }
  }

  /// Ends a held squeeze (also on lifecycle and page changes).
  void end() {
    final before = _drawingBefore;
    if (before == null) return;
    _drawingBefore = null;
    ink.squeezeEnded();
    setDrawing(before);
  }
}

/// Pen thickness for Calendar drawings, with a live preview in the pen's
/// colour. The change applies to the next strokes (drawn ones keep theirs)
/// and is remembered on this device.
Future<void> showPenWidthDialog(
  BuildContext context,
  AppState state,
  CanvasController ink,
) => showDialog<void>(
  context: context,
  builder: (context) => StatefulBuilder(
    builder: (context, setState) {
      final width = ink.penWidth;
      return AlertDialog(
        title: const Text('Pen thickness', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const ValueKey('pen-width-preview'),
                height: 60,
                width: double.infinity,
                child: CustomPaint(
                  painter: PenPreviewPainter(width, ink.penColor),
                ),
              ),
              Slider(
                key: const ValueKey('pen-width-slider'),
                value: width,
                min: AppState.calendarPenMin,
                max: AppState.calendarPenMax,
                divisions: 39,
                label: width.toStringAsFixed(1),
                onChanged: (v) {
                  ink.setPen(width: v);
                  setState(() {});
                },
                onChangeEnd: state.setCalendarPenWidth,
              ),
              Text(
                '${width.toStringAsFixed(1)} · new strokes only',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
    },
  ),
);

/// A sample stroke at [width] (as drawn on the 38-day grid).
class PenPreviewPainter extends CustomPainter {
  const PenPreviewPainter(this.width, this.color);
  final double width;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final path = Path()..moveTo(12, h * 0.65);
    path.cubicTo(
      size.width * 0.3,
      h * 0.1,
      size.width * 0.55,
      h * 0.95,
      size.width - 12,
      h * 0.35,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = width,
    );
  }

  @override
  bool shouldRepaint(PenPreviewPainter old) =>
      old.width != width || old.color != color;
}
