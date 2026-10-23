// Draws the open floating windows over the pages (see FloatingWindows).
import 'package:flutter/material.dart';

import '../app/floating_windows.dart';
import '../app/theme.dart';
import '../platform/input_hints.dart';
import 'common.dart' show GhostIconButton;

class FloatingLayer extends StatelessWidget {
  const FloatingLayer({super.key, required this.windows});

  final FloatingWindows windows;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: windows,
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        final area = box.biggest;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final spec in windows.open)
              _FloatingWindow(
                key: ValueKey('floating-${spec.id}'),
                spec: spec,
                windows: windows,
                area: area,
              ),
          ],
        );
      },
    ),
  );
}

class _FloatingWindow extends StatefulWidget {
  const _FloatingWindow({
    super.key,
    required this.spec,
    required this.windows,
    required this.area,
  });

  final FloatingWindowSpec spec;
  final FloatingWindows windows;
  final Size area;

  @override
  State<_FloatingWindow> createState() => _FloatingWindowState();
}

class _FloatingWindowState extends State<_FloatingWindow> {
  Rect? _dragging; // while moving or resizing; saved when let go

  Rect get _rect => FloatingWindows.fit(
    _dragging ?? widget.windows.rectOf(widget.spec),
    widget.area,
    widget.spec.minSize,
  );

  void _end() {
    final r = _dragging;
    if (r == null) return;
    widget.windows.place(
      widget.spec.id,
      FloatingWindows.fit(r, widget.area, widget.spec.minSize),
    );
    setState(() => _dragging = null);
  }

  @override
  Widget build(BuildContext context) {
    final rect = _rect;
    final spec = widget.spec;
    final handle = touchFirst ? 44.0 : 20.0;
    return Positioned.fromRect(
      rect: rect,
      child: Listener(
        onPointerDown: (_) => widget.windows.toFront(spec.id),
        child: Material(
          color: AppColors.cardRaised,
          elevation: 12,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GestureDetector(
                      key: ValueKey('floating-${spec.id}-title'),
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => setState(() => _dragging = rect),
                      onPanUpdate: (d) => setState(
                        () => _dragging = (_dragging ?? rect).shift(d.delta),
                      ),
                      onPanEnd: (_) => _end(),
                      onPanCancel: _end,
                      child: Container(
                        height: 36,
                        padding: const EdgeInsets.only(left: Space.md),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: AppColors.border),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                spec.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            GhostIconButton(
                              icon: Icons.close,
                              tooltip: 'Close',
                              size: 16,
                              onTap: () => widget.windows.close(spec.id),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(child: spec.builder(context)),
                  ],
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  width: handle,
                  height: handle,
                  child: GestureDetector(
                    key: ValueKey('floating-${spec.id}-resize'),
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => setState(() => _dragging = rect),
                    onPanUpdate: (d) => setState(() {
                      final r = _dragging ?? rect;
                      _dragging = Rect.fromLTWH(
                        r.left,
                        r.top,
                        r.width + d.delta.dx,
                        r.height + d.delta.dy,
                      );
                    }),
                    onPanEnd: (_) => _end(),
                    onPanCancel: _end,
                    child: const MouseRegion(
                      cursor: SystemMouseCursors.resizeDownRight,
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.all(3),
                          child: Icon(
                            Icons.south_east,
                            size: 12,
                            color: AppColors.textFaint,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
