// The New interface's floating sidebar (Windows, and wide iPad windows): a
// vertical glass capsule on the same edge as Original's sidebar (the right).
// Compact (icons, hover labels) or expanded (icons with names), or hidden
// completely behind a small handle. It only presents; every action is the
// one the Original sidebar uses (state.goTo, Quick Add, command palette, app
// switcher, settings, the same drop targets and lists).
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/shell.dart' show openQuickAdd;
import '../app/navigation.dart';
import '../features/settings/settings_dialog.dart';
import '../platform/input_hints.dart';
import 'new_components.dart' show BrandPlus;
import '../app/theme.dart';

/// Places [child] (the page area) with the floating sidebar over its right
/// edge. In a normal window the page area keeps clear of the capsule so
/// nothing is covered, and hiding the capsule gives the space back.
///
/// In a narrow window (iPad Slide Over, a small window; below
/// [narrowWidth]) the pages keep the whole width: only a small handle shows,
/// and tapping it floats the compact capsule over the page until you pick
/// something or tap outside.
class NewSidebarLayout extends StatefulWidget {
  /// Below this width the compact presentation is used.
  static const narrowWidth = 640.0;

  const NewSidebarLayout({super.key, required this.state, required this.child});

  final AppState state;
  final Widget child;

  @override
  State<NewSidebarLayout> createState() => _NewSidebarLayoutState();
}

class _NewSidebarLayoutState extends State<NewSidebarLayout> {
  bool _peek = false;
  Object? _openedAt;

  AppState get state => widget.state;

  Object _where() => (state.page, state.homeActive);

  @override
  void initState() {
    super.initState();
    state.addListener(_changed);
  }

  @override
  void dispose() {
    state.removeListener(_changed);
    super.dispose();
  }

  /// Choosing a destination closes the floating capsule.
  void _changed() {
    if (_peek && _openedAt != _where()) setState(() => _peek = false);
  }

  void _open() => setState(() {
    _openedAt = _where();
    _peek = true;
  });

  @override
  Widget build(BuildContext context) {
    final narrow =
        MediaQuery.sizeOf(context).width < NewSidebarLayout.narrowWidth;
    return narrow ? _narrow() : _regular();
  }

  /// The capsule floats over the pages: they keep the whole width, and only
  /// the strip the capsule really covers is taken. It sits centred on the
  /// edge, clear of the page bar above and the quote line below, so nothing
  /// that is not under it is blocked.
  Widget _regular() {
    final hidden = state.newSidebarHidden;
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        Positioned(
          right: hidden ? 0 : AppSpace.edge,
          top: _clearTop,
          bottom: _clearBottom,
          child: AnimatedSwitcher(
            duration: AppMotion.normal,
            switchInCurve: AppMotion.standard,
            child: hidden
                ? Align(
                    key: const ValueKey('new-sidebar-handle'),
                    alignment: Alignment.centerRight,
                    child: _Handle(onTap: state.toggleNewSidebarHidden),
                  )
                : NewSidebar(key: const ValueKey('new-sidebar'), state: state),
          ),
        ),
      ],
    );
  }

  // Room kept for the page bar (34) and the quote line (~34) plus a margin.
  static const _clearTop = 34.0 + AppSpace.edge;
  static const _clearBottom = 40.0 + AppSpace.edge;

  Widget _narrow() {
    return Stack(
      children: [
        // The pages keep the full width; the small handle floats over them.
        Positioned.fill(child: widget.child),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: Align(
            alignment: Alignment.centerRight,
            child: _Handle(
              key: const ValueKey('new-sidebar-handle'),
              onTap: _open,
            ),
          ),
        ),
        if (_peek) ...[
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('new-sidebar-barrier'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _peek = false),
            ),
          ),
          Positioned(
            right: AppSpace.sm,
            top: AppSpace.sm,
            bottom: AppSpace.sm,
            child: NewSidebar(
              key: const ValueKey('new-sidebar'),
              state: state,
              narrow: true,
              onHide: () => setState(() => _peek = false),
            ),
          ),
        ],
      ],
    );
  }
}

const _handleWidth = 22.0;

class NewSidebar extends StatelessWidget {
  const NewSidebar({
    super.key,
    required this.state,
    this.narrow = false,
    this.onHide,
  });

  final AppState state;

  /// Compact presentation: icons only and fewer secondary controls.
  final bool narrow;

  /// What the last button does. Default: hide the sidebar (remembered); in
  /// the compact presentation it just closes the floating capsule.
  final VoidCallback? onHide;

  @override
  Widget build(BuildContext context) {
    final expanded = state.newSidebarExpanded && !narrow;
    return Align(
      alignment: Alignment.centerRight,
      child: _GlassCapsule(
        expanded: expanded,
        child: ListenableBuilder(
          listenable: Listenable.merge([state, state.timer]),
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: AppSpace.md),
              _QuickAddButton(
                expanded: expanded,
                onTap: () => openQuickAdd(context, state),
              ),
              const SizedBox(height: AppSpace.md),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (page, icon, label) in appDestinations)
                        navDropTarget(
                          state,
                          page,
                          _NavItem(
                            key: ValueKey('new-nav-${page.name}'),
                            icon: icon,
                            label: label,
                            expanded: expanded,
                            active: state.page == page,
                            onTap: () => state.goTo(page),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Container(width: 24, height: 1, color: AppColors.glassBorder),
              const SizedBox(height: AppSpace.sm),
              if (state.timer.running)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.xs),
                  child: Text(
                    state.timer.label,
                    style: TextStyle(
                      fontSize: AppType.sizeMicro,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              _NavItem(
                key: const ValueKey('new-nav-settings'),
                icon: Icons.settings_outlined,
                label: 'Settings',
                expanded: expanded,
                onTap: () => showSettingsDialog(context, state),
              ),
              if (!narrow)
                _NavItem(
                  key: const ValueKey('new-nav-expand'),
                  icon: expanded
                      ? Icons.keyboard_double_arrow_right
                      : Icons.keyboard_double_arrow_left,
                  label: expanded ? 'Compact sidebar' : 'Expand sidebar',
                  expanded: expanded,
                  onTap: state.toggleNewSidebarExpanded,
                ),
              _NavItem(
                key: const ValueKey('new-nav-hide'),
                icon: Icons.chevron_right,
                label: narrow ? 'Close' : 'Hide sidebar',
                expanded: expanded,
                onTap: onHide ?? state.toggleNewSidebarHidden,
              ),
              const SizedBox(height: AppSpace.sm),
            ],
          ),
        ),
      ),
    );
  }
}

/// Translucent, blurred, softly lit pill that floats over the page, with a
/// faint coloured glow around it.
class _GlassCapsule extends StatelessWidget {
  const _GlassCapsule({required this.child, required this.expanded});

  final Widget child;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(_CapsuleSizes.width / 2));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [...AppElevation.floating, ...AppElevation.glow],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppBlur.glass,
            sigmaY: AppBlur.glass,
          ),
          child: AnimatedContainer(
            duration: AppMotion.normal,
            curve: AppMotion.standard,
            width: expanded
                ? _CapsuleSizes.expandedWidth
                : _CapsuleSizes.width,
            decoration: BoxDecoration(
              color: AppColors.glass,
              borderRadius: radius,
              border: Border.all(color: AppColors.glassBorder),
            ),
            foregroundDecoration: BoxDecoration(
              gradient: AppGradients.lighting,
              borderRadius: radius,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _QuickAddButton extends StatelessWidget {
  const _QuickAddButton({required this.onTap, required this.expanded});

  final VoidCallback onTap;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final label = touchFirst ? 'Quick Add' : 'Quick Add  Ctrl N';
    return _HoverLabel(
      label: label,
      enabled: !expanded,
      builder: (context, hovered) => GestureDetector(
        key: const ValueKey('new-quick-add'),
        onTap: onTap,
        child: BrandPlus(
          width: expanded ? _CapsuleSizes.expandedWidth - 24 : 40,
          hovered: hovered,
          label: expanded ? 'Quick Add' : null,
        ),
      ),
    );
  }
}

/// One entry in the capsule. The selected one gets a slim gradient marker on
/// the edge and an accent icon (no large highlight bubble).
class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.expanded,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool expanded;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return _HoverLabel(
      label: label,
      enabled: !expanded,
      builder: (context, hovered) => Semantics(
        button: true,
        selected: active,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            // Inside the capsule's 1 px border, so the selected marker
            // sits against the border, not over it.
            width:
                (expanded
                    ? _CapsuleSizes.expandedWidth
                    : _CapsuleSizes.width) -
                2 * _CapsuleSizes.border,
            height: _CapsuleSizes.navItem,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (active)
                  Positioned(
                    right: 0,
                    child: Container(
                      width: 3,
                      height: 20,
                      decoration: const BoxDecoration(
                        gradient: AppGradients.brand,
                        borderRadius: BorderRadius.horizontal(
                          left: Radius.circular(AppRadii.xs),
                        ),
                      ),
                    ),
                  ),
                AnimatedContainer(
                  duration: AppMotion.quick,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  height: 36,
                  decoration: BoxDecoration(
                    color: active
                        ? AppColors.accentSoft
                        : hovered
                        ? AppColors.hover
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadii.popup),
                  ),
                  child: Row(
                    mainAxisAlignment: expanded
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.center,
                    children: [
                      if (expanded) const SizedBox(width: 6),
                      Icon(
                        icon,
                        size: _CapsuleSizes.icon,
                        color: active
                            ? AppColors.accent
                            : hovered
                            ? AppColors.text
                            : AppColors.textMuted,
                      ),
                      if (expanded) ...[
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.sizeBodySmall,
                              fontWeight: active
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: active
                                  ? AppColors.text
                                  : AppColors.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ],
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

/// Shows [label] in a small glass pill to the left of the child (the capsule
/// is on the right edge) while the pointer (mouse, or a hovering Apple
/// Pencil) is over it.
class _HoverLabel extends StatefulWidget {
  const _HoverLabel({
    required this.label,
    required this.builder,
    this.enabled = true,
  });

  final String label;
  final bool enabled;
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_HoverLabel> createState() => _HoverLabelState();
}

class _HoverLabelState extends State<_HoverLabel> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  bool _hovered = false;

  void _set(bool hovered) {
    if (_hovered == hovered) return;
    setState(() => _hovered = hovered);
    if (hovered && widget.enabled) {
      _portal.show();
    } else if (_portal.isShowing) {
      _portal.hide();
    }
  }

  @override
  void didUpdateWidget(_HoverLabel old) {
    super.didUpdateWidget(old);
    // An overlay may not be changed while the tree is being built (clicking
    // "Expand" while its label was showing used to throw here); do it right
    // after this frame.
    if (!widget.enabled && _portal.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.enabled && _portal.isShowing) _portal.hide();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _set(true),
      onExit: (_) => _set(false),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) => CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.centerLeft,
            followerAnchor: Alignment.centerRight,
            offset: const Offset(-AppSpace.sm, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: IgnorePointer(child: _LabelPill(text: widget.label)),
            ),
          ),
          child: widget.builder(context, _hovered),
        ),
      ),
    );
  }
}

class _LabelPill extends StatelessWidget {
  const _LabelPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.cardRaised,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: AppColors.glassBorder),
          boxShadow: AppElevation.floating,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            text,
            style: AppType.label.copyWith(color: AppColors.text),
          ),
        ),
      ),
    );
  }
}

/// Small tab at the right edge that brings a hidden sidebar back.
class _Handle extends StatelessWidget {
  const _Handle({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _HoverLabel(
      label: 'Show sidebar',
      builder: (context, hovered) => GestureDetector(
        key: const ValueKey('new-sidebar-show'),
        onTap: onTap,
        child: Container(
          width: _handleWidth,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.glass,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(AppRadii.popup),
            ),
            border: Border.all(color: AppColors.glassBorder),
            boxShadow: AppElevation.floating,
          ),
          child: Icon(
            Icons.chevron_left,
            size: 18,
            color: hovered ? AppColors.text : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Measurements of the sidebar capsule (only this file draws it).
abstract final class _CapsuleSizes {
  static const icon = 20.0;
  static const navItem = 44.0;
  static const width = 60.0;
  static const expandedWidth = 188.0;
  static const border = 1.0;
}
