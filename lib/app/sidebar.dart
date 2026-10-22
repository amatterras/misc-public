import 'package:flutter/material.dart';

import '../data/models/canvas_models.dart';
import '../features/search/search_dialog.dart';
import '../features/settings/settings_dialog.dart';
import '../platform/input_hints.dart';
import '../widgets/common.dart';
import 'app_state.dart';
import 'shell.dart' show openQuickAdd;
import 'theme.dart';

/// Compact, collapsible navigation on the right side of the window.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.state});

  final AppState state;

  static const expandedWidth = 272.0;
  static const collapsedWidth = 60.0;

  static const _pages = [
    (AppPage.home, Icons.home_outlined, 'Home'),
    (AppPage.canvas, Icons.grid_view, 'Canvas'),
    (AppPage.notes, Icons.description_outlined, 'Notes'),
    (AppPage.calendar, Icons.calendar_today_outlined, 'Calendar'),
    (AppPage.tasks, Icons.check_box_outlined, 'Tasks'),
  ];

  @override
  Widget build(BuildContext context) {
    final collapsed = state.sidebarCollapsed;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: collapsed ? collapsedWidth : expandedWidth,
      decoration: const BoxDecoration(
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

  int get _inboxCount => state.workspace.inbox.length;

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
        const SizedBox(height: Space.sm),
        _IconButton(
          icon: Icons.search,
          tooltip: 'Search  (Ctrl+K)',
          onTap: () => showSearchDialog(context, state),
        ),
        const SizedBox(height: Space.md),
        for (final (page, icon, label) in _pages)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: _IconButton(
              icon: icon,
              tooltip: label,
              active: state.page == page,
              badge: page == AppPage.home ? _inboxCount : 0,
              onTap: () => state.goTo(page),
            ),
          ),
        const Spacer(),
        if (state.timer.running)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Text(
              state.timer.label,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
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
    final favorites =
        state.workspace.notes.all.where((n) => n.favorite).toList()
          ..sort((a, b) => a.displayTitle.compareTo(b.displayTitle));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: Space.lg),
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.cardRaised,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Icon(
                  Icons.laptop_windows_outlined,
                  size: 16,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(width: Space.md),
              const Expanded(
                child: Text(
                  'Local Space',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              _IconButton(
                icon: Icons.settings_outlined,
                tooltip: 'Settings, backups & Send to',
                onTap: () => showSettingsDialog(context, state),
              ),
              _IconButton(
                icon: Icons.chevron_right,
                tooltip: 'Collapse sidebar',
                onTap: state.toggleSidebar,
              ),
            ],
          ),
          const SizedBox(height: Space.lg),
          _NewButton(onTap: () => openQuickAdd(context, state)),
          const SizedBox(height: Space.sm),
          _NavItem(
            icon: Icons.search,
            label: 'Search',
            trailing: touchFirst
                ? null
                : const Text(
                    'Ctrl K',
                    style: TextStyle(fontSize: 11, color: AppColors.textFaint),
                  ),
            active: false,
            onTap: () => showSearchDialog(context, state),
          ),
          const SizedBox(height: Space.sm),
          Expanded(
            child: ListView(
              children: [
                for (final (page, icon, label) in _pages) ...[
                  _NavItem(
                    icon: icon,
                    label: label,
                    active: state.page == page,
                    onTap: () => state.goTo(page),
                    trailing: page == AppPage.home && _inboxCount > 0
                        ? _Badge(count: _inboxCount)
                        : page == AppPage.tasks && state.timer.running
                        ? Text(
                            state.timer.label,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textMuted,
                            ),
                          )
                        : null,
                  ),
                  if (page == AppPage.canvas) _CanvasList(state: state),
                ],
                if (favorites.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 20, 12, 6),
                    child: Text(
                      'FAVORITES',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 0.6,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ),
                  for (final note in favorites)
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => state.openNote(note.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.star_outline,
                              size: 15,
                              color: OrganizerColors.amber,
                            ),
                            const SizedBox(width: Space.sm),
                            Expanded(
                              child: Text(
                                note.displayTitle,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: OrganizerColors.blue,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      '$count',
      style: const TextStyle(
        fontSize: 11,
        color: Colors.white,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
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
          child: const SizedBox(
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

/// The canvas boards listed under "Canvas".
class _CanvasList extends StatelessWidget {
  const _CanvasList({required this.state});

  final AppState state;

  Future<void> _menu(
    BuildContext context,
    CanvasSummary canvas,
    Offset at,
  ) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(value: 'rename', height: 36, child: Text('Rename')),
        PopupMenuItem(
          value: 'delete',
          height: 36,
          child: Text('Move to trash'),
        ),
      ],
    );
    if (!context.mounted) return;
    if (choice == 'rename') {
      final title = await promptText(
        context,
        title: 'Rename canvas',
        initial: canvas.title,
      );
      if (title != null) await state.renameCanvas(canvas.id, title);
    } else if (choice == 'delete') {
      final ok = await confirm(
        context,
        title: 'Move “${canvas.title}” to trash?',
        message:
            'The file is moved to a trash folder inside your data folder, '
            'not erased.',
        action: 'Move to trash',
      );
      if (ok) await state.deleteCanvas(canvas.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentId = state.canvas?.id;
    return Container(
      margin: const EdgeInsets.only(left: 21, top: 2, bottom: 4),
      padding: const EdgeInsets.only(left: Space.md),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final canvas in state.canvasList)
            GestureDetector(
              onSecondaryTapUp: (d) => _menu(context, canvas, d.globalPosition),
              // Touch (iPad/iPhone): press and hold opens the same menu.
              onLongPressStart: (d) => _menu(context, canvas, d.globalPosition),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                hoverColor: AppColors.hover,
                onTap: () => state.openCanvas(canvas.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.crop_square,
                        size: 14,
                        color:
                            canvas.id == currentId &&
                                state.page == AppPage.canvas
                            ? AppColors.text
                            : AppColors.textFaint,
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          canvas.title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color:
                                canvas.id == currentId &&
                                    state.page == AppPage.canvas
                                ? AppColors.text
                                : AppColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => state.createCanvas(),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                children: [
                  Icon(Icons.add, size: 14, color: AppColors.textFaint),
                  SizedBox(width: Space.sm),
                  Text(
                    'New canvas',
                    style: TextStyle(fontSize: 13, color: AppColors.textFaint),
                  ),
                ],
              ),
            ),
          ),
        ],
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
    this.badge = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool filled;
  final int badge;

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
              child: Badge(
                isLabelVisible: badge > 0,
                label: Text('$badge'),
                backgroundColor: OrganizerColors.blue,
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
      ),
    );
  }
}
