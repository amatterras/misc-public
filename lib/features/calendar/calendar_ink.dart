// Freeform drawing on the Calendar. All of it is one synced document
// ("calendar-ink") laid out as an endless strip of days: day d owns the
// world rectangle [inkDayRect]. So every stroke belongs to its date, stays
// with it when the shown range or view changes, and syncs per stroke like
// any canvas item. Drawing happens only in Draw mode, so taps on dates and
// entries work as usual otherwise.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

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

/// Draws (and, in Draw mode, records) the ink of one day cell.
class DayInkLayer extends StatefulWidget {
  const DayInkLayer({
    super.key,
    required this.controller,
    required this.day,
    required this.drawing,
  });

  final CanvasController controller;
  final DateTime day;
  final bool drawing;

  @override
  State<DayInkLayer> createState() => _DayInkLayerState();
}

class _DayInkLayerState extends State<DayInkLayer> {
  int? _pointer;

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
          if (_pointer != null) return;
          if (e.kind == PointerDeviceKind.mouse &&
              e.buttons & kPrimaryButton == 0) {
            return;
          }
          _pointer = e.pointer;
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
          if (e.pointer != _pointer) return;
          c.pointerMove(
            screen(e.localPosition),
            pressure: e.kind == PointerDeviceKind.stylus
                ? normalizedPressure(e.pressure, e.pressureMax)
                : 0.5,
            timeStamp: e.timeStamp,
          );
        },
        onPointerUp: (e) {
          if (e.pointer != _pointer) return;
          _pointer = null;
          c.pointerUp();
        },
        onPointerCancel: (e) {
          if (e.pointer != _pointer) return;
          _pointer = null;
          c.pointerCancel();
        },
        child: paint,
      );
    },
  );
}
