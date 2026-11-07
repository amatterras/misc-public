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
    _dragging ?? widget.windows.rectOf(widget.spec, viewport: widget.area),
    widget.area,
    widget.spec.minSize,
  );

  /// Tells native views (Safari on Windows) where this window is.
  void _publish() {
    final box = context.findRenderObject() as RenderBox?;
    if (!mounted || box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final all = floatingWindowRects.value;
    if (all[widget.spec.id] == rect) return;
    floatingWindowRects.value = {...all, widget.spec.id: rect};
  }

  @override
  void dispose() {
    final id = widget.spec.id;
    // After this frame: the map must not change while widgets build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      floatingWindowRects.value = {...floatingWindowRects.value}..remove(id);
    });
    super.dispose();
  }

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
    return Positioned.fromRect(
      rect: rect,
      child: Listener(
        onPointerDown: (_) => widget.windows.toFront(spec.id),
        child: _PanelEntrance(
          child: DecoratedBox(
            // Shadow outside the clip; surface, hairline and corners shared
            // with popups and menus (AppRadii.popup, AppElevation.floating).
            decoration: BoxDecoration(
              borderRadius: AppRadii.all(AppRadii.popup),
              boxShadow: AppElevation.floating,
            ),
            child: Material(
              color: AppColors.light ? AppColors.card : AppColors.cardRaised,
              shape: RoundedRectangleBorder(
                borderRadius: AppRadii.all(AppRadii.popup),
                side: BorderSide(color: AppColors.border),
              ),
              clipBehavior: Clip.antiAlias,
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
                        // Double-click / double-tap: small corner window and back.
                        onDoubleTap: () => widget.windows.toggleCompact(
                          spec.id,
                          rect,
                          widget.area,
                        ),
                        child: Container(
                          height: AppSizes.panelHeader,
                          padding: const EdgeInsets.only(
                            left: AppSpace.md + 2,
                            right: AppSpace.xs,
                          ),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: AppColors.border),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  spec.liveTitle?.call() ?? spec.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppType.chrome.copyWith(
                                    color: AppColors.text,
                                  ),
                                ),
                              ),
                              GhostIconButton(
                                key: ValueKey('floating-${spec.id}-compact'),
                                icon: widget.windows.isCompact(spec.id)
                                    ? Icons.open_in_full
                                    : Icons.picture_in_picture_alt_outlined,
                                tooltip: widget.windows.isCompact(spec.id)
                                    ? 'Back to full size'
                                    : 'Small corner window',
                                size: 16,
                                onTap: () => widget.windows.toggleCompact(
                                  spec.id,
                                  rect,
                                  widget.area,
                                ),
                              ),
                              if (spec.onMinimize != null)
                                GhostIconButton(
                                  key: ValueKey('floating-${spec.id}-minimize'),
                                  icon: Icons.minimize,
                                  tooltip: 'Minimize',
                                  size: 16,
                                  onTap: spec.onMinimize,
                                ),
                              if (spec.onDock != null)
                                GhostIconButton(
                                  key: ValueKey('floating-${spec.id}-dock'),
                                  icon: Icons.fullscreen_exit,
                                  tooltip: 'Put back in the main area',
                                  size: 16,
                                  onTap: spec.onDock,
                                ),
                              GhostIconButton(
                                key: ValueKey('floating-${spec.id}-close'),
                                icon: Icons.close,
                                tooltip: 'Close',
                                size: 16,
                                onTap:
                                    spec.onClose ??
                                    () => widget.windows.close(spec.id),
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
                      child: MouseRegion(
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
      ),
    );
  }
}

/// A floating panel fades and settles in (scale 0.97 to 1) when it opens. Moving
/// and resizing are never animated: the panel follows the pointer 1:1.
class _PanelEntrance extends StatelessWidget {
  const _PanelEntrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.of(context, AppMotion.panel),
      curve: AppMotion.standard,
      child: child,
      // Same widget shape at every value, so the content is never remounted
      // (opacity 1 adds no layer; scale 1 is the identity).
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.97 + 0.03 * t, child: child),
      ),
    );
  }
}
