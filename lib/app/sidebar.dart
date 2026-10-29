import 'package:flutter/material.dart';

import '../data/models/canvas_models.dart';
import '../data/models/record.dart' show dateOnly;
import '../features/settings/settings_dialog.dart';
import '../platform/input_hints.dart';
import '../widgets/common.dart';
import '../features/motivation/motivation_service.dart';
import 'app_state.dart';
import 'page_windows.dart';
import 'shell.dart' show openAppSwitcher, openCommandPalette, openQuickAdd;
import 'theme.dart';
import '../features/transfer/transfer.dart';

/// Compact, collapsible navigation on the right side of the window.
/// The four top-level destinations, in this order and spelling. Tasks are
/// in Calendar's task column; the start page (Home, with the Inbox) opens
/// from the THEapp button at the top, not as a fifth destination.
/// The six primary destinations, in this order. Every navigation surface
/// (sidebar, phone tabs, command palette, top bar) uses this one list.
/// Home is the start page behind the THEapp identity control; Tasks live in
/// Calendar.
const appDestinations = [
  (AppPage.canvas, Icons.hub_outlined, 'mindmap'),
  (AppPage.notes, Icons.description_outlined, 'notes'),
  (AppPage.calendar, Icons.calendar_today_outlined, 'calendar'),
  (AppPage.links, Icons.bookmarks_outlined, 'archive'),
  (AppPage.browser, Icons.explore_outlined, 'safari'),
  (AppPage.ai, Icons.auto_awesome_outlined, 'ai'),
];

class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.state, this.motivation});

  final AppState state;

  /// The hourly motivational quote is shown at the bottom of the sidebar.
  final MotivationService? motivation;

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

  int get _inboxCount => state.workspace.inbox.length;

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
          icon: Icons.wb_sunny_outlined,
          tooltip: 'Start page',
          active: state.page == AppPage.home,
          badge: _inboxCount,
          onTap: () => state.goTo(AppPage.home),
        ),
        const SizedBox(height: Space.sm),
        _IconButton(
          icon: Icons.add,
          tooltip: 'Quick Add  (Ctrl+N)',
          filled: true,
          onTap: () => openQuickAdd(context, state),
        ),
        const SizedBox(height: Space.sm),
        _IconButton(
          icon: Icons.apps,
          tooltip: 'App switcher',
          onTap: () => openAppSwitcher(context, state),
        ),
        const SizedBox(height: Space.md),
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
        if (motivation != null)
          SidebarQuote(service: motivation!, compact: true),
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
              // The start page (today, Inbox); not a sidebar destination.
              Expanded(
                child: InkWell(
                  key: const ValueKey('sidebar-start-page'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => state.goTo(AppPage.home),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: state.page == AppPage.home
                              ? AppColors.selected
                              : AppColors.cardRaised,
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
                          'THEapp',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (_inboxCount > 0) ...[
                        const SizedBox(width: Space.sm),
                        _Badge(count: _inboxCount),
                      ],
                    ],
                  ),
                ),
              ),
              _IconButton(
                icon: Icons.apps,
                tooltip: 'App switcher',
                onTap: () => openAppSwitcher(context, state),
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
            icon: Icons.keyboard_command_key,
            label: 'Commands',
            trailing: touchFirst
                ? null
                : Text(
                    'Ctrl ⇧ P',
                    style: TextStyle(fontSize: 11, color: AppColors.textFaint),
                  ),
            active: false,
            onTap: () => openCommandPalette(context, state),
          ),
          const SizedBox(height: Space.sm),
          Expanded(
            child: ListView(
              children: [
                for (final (page, icon, label) in _pages) ...[
                  _navDropTarget(
                    page,
                    _NavItem(
                      icon: icon,
                      label: label,
                      active: state.page == page,
                      onTap: () => state.goTo(page),
                      groupId: page == AppPage.canvas
                          ? 'mindmap'
                          : page == AppPage.notes
                          ? 'notes'
                          : null,
                      expanded: page == AppPage.canvas
                          ? state.sidebarGroupExpanded('mindmap')
                          : page == AppPage.notes
                          ? state.sidebarGroupExpanded('notes')
                          : null,
                      onToggle: page == AppPage.canvas || page == AppPage.notes
                          ? () => state.toggleSidebarGroup(
                              page == AppPage.canvas ? 'mindmap' : 'notes',
                            )
                          : null,
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
                  if (page == AppPage.canvas &&
                      state.sidebarGroupExpanded('mindmap'))
                    _CanvasList(state: state),
                  if (page == AppPage.notes &&
                      state.sidebarGroupExpanded('notes'))
                    _RecentNotes(state: state),
                ],
                if (favorites.isNotEmpty) ...[
                  Padding(
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
                            Icon(
                              Icons.star_outline,
                              size: 15,
                              color: AppColors.warm,
                            ),
                            const SizedBox(width: Space.sm),
                            Expanded(
                              child: Text(
                                note.displayTitle,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
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
          if (motivation != null) SidebarQuote(service: motivation!),
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
      color: AppColors.accent,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      '$count',
      style: TextStyle(
        fontSize: 11,
        color: AppColors.text,
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
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.trailing,
    this.groupId,
    this.expanded,
    this.onToggle,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final Widget? trailing;
  final String? groupId;
  final bool? expanded;
  final VoidCallback? onToggle;

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
                if (onToggle != null)
                  IconButton(
                    key: ValueKey('sidebar-group-${groupId!}-toggle'),
                    tooltip: expanded!
                        ? 'Collapse $groupId items'
                        : 'Expand $groupId items',
                    onPressed: onToggle,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    icon: Icon(
                      expanded! ? Icons.expand_more : Icons.chevron_right,
                      size: 18,
                      color: AppColors.textFaint,
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
        PopupMenuItem(
          value: 'window',
          height: 36,
          child: Text('Open in a window'),
        ),
        PopupMenuItem(value: 'rename', height: 36, child: Text('Rename')),
        PopupMenuItem(
          value: 'delete',
          height: 36,
          child: Text('Move to trash'),
        ),
      ],
    );
    if (!context.mounted) return;
    if (choice == 'window') {
      state.windows.open(
        AppPage.canvas,
        refId: canvas.id,
        title: canvas.title,
        mode: PageMode.floating,
      );
      return;
    }
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
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final canvas in state.canvasList)
            TransferTarget(
              key: ValueKey('drop-canvas-${canvas.id}'),
              state: state,
              place: CanvasPlace(canvas.id),
              child: GestureDetector(
                onSecondaryTapUp: (d) =>
                    _menu(context, canvas, d.globalPosition),
                // Touch (iPad/iPhone): press and hold opens the same menu.
                onLongPressStart: (d) =>
                    _menu(context, canvas, d.globalPosition),
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
            ),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => state.createCanvas(),
            child: Padding(
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
                backgroundColor: AppColors.accent,
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

/// Under "notes": the five most recently edited notes, newest first.
class _RecentNotes extends StatelessWidget {
  const _RecentNotes({required this.state});

  final AppState state;

  static const count = 5;

  @override
  Widget build(BuildContext context) {
    final recent = state.workspace.notes.all.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (recent.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('sidebar-recent-notes'),
      margin: const EdgeInsets.only(left: 21, top: 2, bottom: 4),
      padding: const EdgeInsets.only(left: Space.md),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final note in recent.take(count))
            TransferTarget(
              state: state,
              place: NotePlace(note.id),
              child: TransferSource(
                transfer: () => NoteTransfer(note.id, note.displayTitle),
                touch: true,
                child: InkWell(
                  key: ValueKey('recent-note-${note.id}'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => state.openNote(note.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Text(
                      note.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The hourly motivational quote at the bottom of the sidebar (collapsed:
/// a small mark that shows the quote on hover or press).
class SidebarQuote extends StatelessWidget {
  const SidebarQuote({super.key, required this.service, this.compact = false});

  final MotivationService service;
  final bool compact;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final quote = service.quote;
      if (quote == null) return const SizedBox.shrink();
      final text = quote.attribution.isEmpty
          ? '“${quote.text}”'
          : '“${quote.text}”  ${quote.attribution}';
      if (compact) {
        return Tooltip(
          key: const ValueKey('sidebar-quote-compact'),
          message: text,
          triggerMode: TooltipTriggerMode.tap,
          child: Padding(
            padding: EdgeInsets.all(10),
            child: Icon(
              Icons.format_quote,
              size: 18,
              color: AppColors.textFaint,
              semanticLabel: 'Quote of the hour',
            ),
          ),
        );
      }
      return Container(
        key: const ValueKey('motivational-quote'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Text(
          text,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      );
    },
  );
}
