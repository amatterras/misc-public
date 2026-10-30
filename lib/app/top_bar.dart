// The page bar at the top: the pages the user added (docked, floating or
// minimized), "+" to add the current page, and a collapse control. Each
// page has a menu (also on right-click / press-and-hold) to float, dock,
// minimize, restore, pin and close. Collapsed, a slim strip keeps a handle
// to bring it back. The collapsed choice is remembered on this device.
import 'package:flutter/material.dart';

import '../data/models/canvas_models.dart' show newId;
import 'app_state.dart';
import 'page_windows.dart';
import 'sidebar.dart' show appDestinations;
import 'theme.dart';
import '../widgets/common.dart' show promptText;

IconData pageIcon(AppPage kind) => switch (kind) {
  AppPage.home => Icons.wb_sunny_outlined,
  AppPage.tasks => Icons.checklist,
  _ =>
    appDestinations.where((d) => d.$1 == kind).firstOrNull?.$2 ??
        Icons.web_asset,
};

String pageLabel(AppPage kind) => switch (kind) {
  AppPage.home => 'start',
  AppPage.tasks => 'tasks',
  _ => appDestinations.where((d) => d.$1 == kind).firstOrNull?.$3 ?? kind.name,
};

/// Adds the page shown in the main area to the bar (or focuses it).
PageInstance addCurrentPage(AppState s) {
  final page = s.page == AppPage.tasks ? AppPage.calendar : s.page;
  return switch (page) {
    AppPage.canvas when s.canvas != null => s.windows.open(
      AppPage.canvas,
      refId: s.canvas!.id,
      title: s.canvas!.title,
    ),
    // The note being read, not just the Notes list.
    AppPage.notes when s.workspace.notes[s.selectedNoteId] != null =>
      s.windows.open(
        AppPage.notes,
        refId: s.selectedNoteId,
        title: s.workspace.notes[s.selectedNoteId]!.displayTitle,
      ),
    AppPage.browser => s.windows.open(
      AppPage.browser,
      refId: newId(),
      title: 'Safari',
    ),
    AppPage.ai => s.windows.open(
      AppPage.ai,
      refId: s.aiSession.conversationId ?? 'new-${newId()}',
      title:
          s
              .workspace
              .aiConversations[s.aiSession.conversationId ?? '']
              ?.title ??
          'New chat',
    ),
    _ => s.windows.open(page, title: pageLabel(page)),
  };
}

/// What "New page" can make (each a real, fresh instance).
const newPageChoices = [
  (AppPage.notes, 'New note'),
  (AppPage.canvas, 'New mindmap'),
  (AppPage.calendar, 'New calendar view'),
  (AppPage.links, 'New Library view'),
  (AppPage.browser, 'New Safari window'),
  (AppPage.ai, 'New AI chat'),
];

/// The tab's name: the user's own, else the content's current title.
String pageTitle(AppState s, PageInstance p) {
  if (p.named && p.title.isNotEmpty) return p.title;
  final ref = p.refId;
  final live = switch (p.kind) {
    AppPage.notes when ref != null => s.workspace.notes[ref]?.displayTitle,
    AppPage.canvas when ref != null =>
      s.canvasList.where((c) => c.id == ref).firstOrNull?.title,
    AppPage.ai when ref != null => s.workspace.aiConversations[ref]?.title,
    AppPage.links when ref != null && ref.startsWith('res:') =>
      s.workspace.assets[ref.substring(4)]?.label,
    AppPage.links when ref != null && ref.startsWith('folder:') =>
      s.workspace.archiveFolders[ref.substring(7)]?.name,
    _ => null,
  };
  if (live != null && live.trim().isNotEmpty) return live;
  return p.title.isEmpty ? pageLabel(p.kind) : p.title;
}

class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.state});

  static const height = 34.0;
  static const collapsedHeight = 14.0;

  final AppState state;

  PageWindows get w => state.windows;

  Future<void> _menu(BuildContext context, PageInstance p, Offset at) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (p.mode != PageMode.floating)
          const PopupMenuItem(value: 'float', child: Text('Float in a window')),
        if (p.mode != PageMode.docked)
          const PopupMenuItem(
            value: 'dock',
            child: Text('Show in the main area'),
          ),
        if (p.mode != PageMode.minimized)
          const PopupMenuItem(value: 'min', child: Text('Minimize'))
        else
          const PopupMenuItem(value: 'restore', child: Text('Restore')),
        PopupMenuItem(value: 'pin', child: Text(p.pinned ? 'Unpin' : 'Pin')),
        const PopupMenuItem(value: 'rename', child: Text('Rename tab')),
        // Closing never deletes the note, mindmap or chat itself; that is
        // done only with the content's own Delete.
        const PopupMenuItem(value: 'close', child: Text('Close (keeps it)')),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'rename':
        final name = await promptText(
          context,
          title: 'Tab name',
          initial: pageTitle(state, p),
        );
        if (name != null && name.trim().isNotEmpty) w.rename(p.id, name.trim());
      case 'float':
        w.float(p.id);
      case 'dock':
        w.dock(p.id);
      case 'min':
        w.minimize(p.id);
      case 'restore':
        w.restoreInstance(p.id);
      case 'pin':
        w.togglePin(p.id);
      case 'close':
        await w.close(p.id);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Tab names follow the notes, mindmaps and chats they show.
    listenable: Listenable.merge([
      w,
      state,
      state.workspace.notes,
      state.workspace.aiConversations,
    ]),
    builder: (context, _) {
      if (w.collapsed) {
        return SizedBox(
          key: const ValueKey('top-bar-collapsed'),
          height: collapsedHeight,
          child: Center(
            child: Tooltip(
              message: 'Show the page bar (${w.all.length} pages)',
              child: InkWell(
                key: const ValueKey('top-bar-expand'),
                onTap: () => w.setCollapsed(false),
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 56,
                  height: 14,
                  child: Icon(
                    Icons.expand_more,
                    size: 14,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
            ),
          ),
        );
      }
      return Container(
        key: const ValueKey('top-bar'),
        height: height,
        decoration: BoxDecoration(
          color: AppColors.sidebar,
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('top-bar-add'),
              tooltip: 'Add this page to the bar',
              icon: const Icon(Icons.add, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              onPressed: () => addCurrentPage(state),
            ),
            PopupMenuButton<AppPage>(
              key: const ValueKey('top-bar-new'),
              tooltip: 'New page',
              icon: const Icon(Icons.note_add_outlined, size: 16),
              padding: EdgeInsets.zero,
              onSelected: (kind) => state.newPage(kind),
              itemBuilder: (_) => [
                for (final (kind, label) in newPageChoices)
                  PopupMenuItem(
                    value: kind,
                    child: Row(
                      children: [
                        Icon(pageIcon(kind), size: 16),
                        const SizedBox(width: 10),
                        Text(label),
                      ],
                    ),
                  ),
              ],
            ),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [for (final p in w.all) _chip(context, p)],
              ),
            ),
            IconButton(
              key: const ValueKey('top-bar-collapse'),
              tooltip: 'Collapse the page bar',
              icon: const Icon(Icons.expand_less, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              onPressed: () => w.setCollapsed(true),
            ),
          ],
        ),
      );
    },
  );

  Widget _chip(BuildContext context, PageInstance p) {
    final active = p.mode == PageMode.docked && w.activeId == p.id;
    final minimized = p.mode == PageMode.minimized;
    final color = active ? AppColors.text : AppColors.textMuted;
    return GestureDetector(
      onSecondaryTapUp: (d) => _menu(context, p, d.globalPosition),
      onLongPressStart: (d) => _menu(context, p, d.globalPosition),
      child: Tooltip(
        message:
            '${pageTitle(state, p)} — ${switch (p.mode) {
              PageMode.docked => active ? 'shown' : 'in the main area',
              PageMode.floating => 'floating',
              PageMode.minimized => 'minimized',
            }}',
        child: InkWell(
          key: ValueKey('page-chip-${p.id}'),
          onTap: () => w.focus(p.id),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 190),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: active ? AppColors.accent : Colors.transparent,
                  width: 2,
                ),
                right: BorderSide(color: AppColors.border),
              ),
            ),
            child: Opacity(
              opacity: minimized ? 0.55 : 1,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.pinned)
                    Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(
                        Icons.push_pin,
                        size: 11,
                        color: AppColors.textFaint,
                      ),
                    ),
                  Icon(pageIcon(p.kind), size: 14, color: color),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      pageTitle(state, p),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: color,
                        fontStyle: minimized ? FontStyle.italic : null,
                      ),
                    ),
                  ),
                  if (p.mode == PageMode.floating)
                    Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.open_in_new,
                        size: 11,
                        color: AppColors.textFaint,
                      ),
                    ),
                  InkWell(
                    key: ValueKey('page-chip-menu-${p.id}'),
                    onTap: () {
                      final box = context.findRenderObject() as RenderBox?;
                      _menu(
                        context,
                        p,
                        box?.localToGlobal(const Offset(0, 34)) ?? Offset.zero,
                      );
                    },
                    child: Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.more_vert,
                        size: 13,
                        color: AppColors.textFaint,
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
