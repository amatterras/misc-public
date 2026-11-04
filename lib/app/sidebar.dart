import 'package:flutter/material.dart';

import '../data/models/canvas_models.dart';
import '../data/models/record.dart' show dateOnly;
import '../features/settings/settings_dialog.dart';
import 'app_state.dart';
import 'shell.dart' show openQuickAdd;
import 'theme.dart';
import '../features/transfer/transfer.dart';

/// Compact, collapsible navigation on the right side of the window.
/// The six primary destinations, in this order. Every navigation surface
/// (sidebar, phone tabs, command palette, top bar) uses this one list.
/// There is no Home page; Tasks live in Calendar.
const appDestinations = [
  (AppPage.canvas, Icons.hub_outlined, 'mindmap'),
  (AppPage.notes, Icons.description_outlined, 'notes'),
  (AppPage.calendar, Icons.calendar_today_outlined, 'calendar'),
  (AppPage.links, Icons.bookmarks_outlined, 'archive'),
  (AppPage.browser, Icons.explore_outlined, 'safari'),
  (AppPage.ai, Icons.auto_awesome_outlined, 'ai'),
];

class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.state});

  final AppState state;

  static const expandedWidth = 272.0;
  static const collapsedWidth = 60.0;

  static const _pages = appDestinations;

  @override
  Widget build(BuildContext context) {
    final collapsed = state.sidebarCollapsed;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: collapsed ? collapsedWidth : expandedWidth,
      decoration: BoxDecoration(
        color: AppColors.sidebar,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: collapsed ? collapsedWidth : expandedWidth,
          child: ListenableBuilder(
            listenable: Listenable.merge([
              state.workspace.changes,
              state.timer,
            ]),
            builder: (context, _) =>
                collapsed ? _buildCollapsed(context) : _buildExpanded(context),
          ),
        ),
      ),
    );
  }

  /// The same drop behaviour for other navigation surfaces (the New
  /// interface's sidebar), so drops on a destination mean one thing.
  Widget navDropTarget(AppPage page, Widget child) =>
      _navDropTarget(page, child);

  /// Dropping on a top-level entry: notes → a new note, archive → the
  /// Archive board, calendar → today, mindmap → the open mindmap.
  Widget _navDropTarget(AppPage page, Widget child) {
    final open = state.canvas;
    final DropPlace? place = switch (page) {
      AppPage.notes => const NewNotePlace(),
      AppPage.links => const CanvasPlace(linksBoardId),
      AppPage.calendar => DayPlace(dateOnly(DateTime.now())),
      AppPage.canvas when open != null => CanvasPlace(open.id),
      _ => null,
    };
    if (place == null) return child;
    return TransferTarget(
      key: ValueKey('drop-nav-${page.name}'),
      state: state,
      place: place,
      child: child,
    );
  }

  Widget _buildCollapsed(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: Space.lg),
        _IconButton(
          icon: Icons.chevron_left,
          tooltip: 'Expand sidebar',
          onTap: state.toggleSidebar,
        ),
        const SizedBox(height: Space.md),
        _IconButton(
          icon: Icons.add,
          tooltip: 'Quick Add  (Ctrl+N)',
          filled: true,
          onTap: () => openQuickAdd(context, state),
        ),
        const SizedBox(height: Space.lg),
        for (final (page, icon, label) in _pages)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: _IconButton(
              icon: icon,
              tooltip: label,
              active: state.page == page,
              onTap: () => state.goTo(page),
            ),
          ),
        const Spacer(),
        if (state.timer.running)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Text(
              state.timer.label,
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ),
        _IconButton(
          icon: Icons.settings_outlined,
          tooltip: 'Settings, backups & Send to',
          onTap: () => showSettingsDialog(context, state),
        ),
        const SizedBox(height: Space.lg),
      ],
    );
  }

  Widget _buildExpanded(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: Space.lg),
          Row(
            children: [
              // The app's name and mark; it is not a button.
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppColors.cardRaised,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Icon(
                        Icons.wb_sunny_outlined,
                        size: 16,
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    const Flexible(
                      child: Text(
                        'misc.',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _IconButton(
                icon: Icons.chevron_right,
                tooltip: 'Collapse sidebar',
                onTap: state.toggleSidebar,
              ),
            ],
          ),
          const SizedBox(height: Space.xl),
          _NewButton(onTap: () => openQuickAdd(context, state)),
          const SizedBox(height: Space.lg),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final (page, icon, label) in _pages)
                  _navDropTarget(
                    page,
                    _NavItem(
                      icon: icon,
                      label: label,
                      active: state.page == page,
                      onTap: () => state.goTo(page),
                      trailing: page == AppPage.calendar && state.timer.running
                          ? Text(
                              state.timer.label,
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textMuted,
                              ),
                            )
                          : null,
                    ),
                  ),
              ],
            ),
          ),
          // Settings sits at the bottom, apart from the destinations.
          _NavItem(
            key: const ValueKey('sidebar-settings'),
            icon: Icons.settings_outlined,
            label: 'Settings',
            active: false,
            onTap: () => showSettingsDialog(context, state),
          ),
          const SizedBox(height: Space.lg),
        ],
      ),
    );
  }
}

class _NewButton extends StatelessWidget {
  const _NewButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Capture text, links and photos into Canvas, Notes or Calendar  (Ctrl+N)',
      child: Material(
        color: AppColors.text,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
            height: 40,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 18, color: AppColors.background),
                SizedBox(width: Space.sm),
                Text(
                  'Quick Add',
                  style: TextStyle(
                    color: AppColors.background,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
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

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: active ? AppColors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppColors.hover,
          onTap: onTap,
          child: SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: Space.md),
                Icon(
                  icon,
                  size: 18,
                  color: active ? AppColors.text : AppColors.textMuted,
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active ? AppColors.text : AppColors.textMuted,
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  trailing!,
                  const SizedBox(width: Space.md),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.filled = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled
            ? AppColors.text
            : active
            ? AppColors.selected
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppColors.hover,
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: Icon(
                icon,
                size: 18,
                color: filled
                    ? AppColors.background
                    : active
                    ? AppColors.text
                    : AppColors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
