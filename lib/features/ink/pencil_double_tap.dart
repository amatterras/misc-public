// Apple Pencil double-tap (2nd generation and Pro) means Undo in THEapp:
// the same undo as the drawing's Undo button, on the drawing in use (the
// canvas, a note's handwriting or the Calendar's drawings). Each surface
// registers while it is shown; of those active, the one drawn on last
// receives the tap. Taps arriving twice for one press are
// dropped, and nothing happens when the user turned double-tap off in
// iPadOS Settings ("ignore") or in THEapp.
import '../canvas/canvas_controller.dart';

enum PencilTapResult { undone, nothingToUndo, noDrawing, off, ignored, repeat }

class PencilDoubleTap {
  PencilDoubleTap({
    DateTime Function()? now,
    this.minGap = const Duration(milliseconds: 300),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// Taps closer together than this are one tap delivered twice.
  final Duration minGap;

  /// THEapp's own switch (Settings); iPadOS's choice is honoured too.
  bool enabled = true;

  final List<({CanvasController controller, bool Function() active})> _targets =
      [];
  DateTime? _last;

  /// Registers [controller] as a drawing that can receive the tap while
  /// [active] is true. Returns the function that unregisters it.
  void Function() register(
    CanvasController controller, {
    required bool Function() active,
  }) {
    final target = (controller: controller, active: active);
    _targets.add(target);
    return () => _targets.remove(target);
  }

  /// The drawing a tap would undo on now: of those shown, the one drawn on
  /// last (else the one shown last), if any.
  CanvasController? get target {
    CanvasController? best;
    for (final t in _targets.reversed) {
      if (!t.active()) continue;
      final at = t.controller.lastInputAt;
      final bestAt = best?.lastInputAt;
      if (best == null ||
          (at != null && (bestAt == null || at.isAfter(bestAt)))) {
        best = t.controller;
      }
    }
    return best;
  }

  /// One double-tap from iOS with the user's preferred action.
  PencilTapResult handle(String preferredAction) {
    if (!enabled) return PencilTapResult.off;
    if (preferredAction == 'ignore') return PencilTapResult.ignored;
    final now = _now();
    final last = _last;
    if (last != null && now.difference(last) < minGap) {
      return PencilTapResult.repeat;
    }
    _last = now;
    final c = target;
    if (c == null) return PencilTapResult.noDrawing;
    if (!c.canUndo) return PencilTapResult.nothingToUndo;
    c.undo();
    return PencilTapResult.undone;
  }
}
