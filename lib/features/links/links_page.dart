// The Links library: one board of link cards (preview image, title, tags)
// that can be arranged and written on like a canvas. It reuses the Canvas
// engine and storage: the board is a canvas document (`links-board`,
// kind `links`) that syncs per card, and each card shows a shared link
// Asset, whose tags (`linkTags`) sync with the link.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/tag_models.dart';
import '../../data/models/library_models.dart';
import '../../widgets/common.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_page.dart';
import '../canvas/canvas_toolbar.dart' show showDotOpacityDialog;
import 'archive_library_page.dart';
import 'link_tags.dart';

class LinksPage extends StatefulWidget {
  const LinksPage({super.key, required this.state});

  final AppState state;

  @override
  State<LinksPage> createState() => _LinksPageState();
}

class _LinksPageState extends State<LinksPage> {
  AppState get s => widget.state;
  LinkTag? _filter;

  /// A custom tag to filter by instead (its id); one filter at a time.
  String? _customFilter;

  /// What the active filter looks for in a resource's linkTags.
  String? get _filterRef =>
      _filter?.id ??
      (_customFilter == null ? null : CustomTag.assetRef(_customFilter!));

  /// The temporary highlight of the active filter (the tag's own colour
  /// is never changed by it).
  Color? get _filterColor =>
      _filter?.color ??
      (_customFilter == null
          ? null
          : Color(s.workspace.customTags[_customFilter!]?.color ?? 0));

  /// Show only resources of this project (others are dimmed).
  String? _project;

  bool _matches(LinkItem item) {
    final asset = s.workspace.assets[item.assetId];
    if (asset == null) return false;
    final ref = _filterRef, project = _project;
    return (ref == null || asset.linkTags.contains(ref)) &&
        (project == null || asset.projectIds.contains(project));
  }

  void _setProject(CanvasController board, String? project) {
    _project = project;
    _setFilter(board, _filter, custom: _customFilter);
  }

  void _setFilter(CanvasController board, LinkTag? tag, {String? custom}) {
    setState(() {
      _filter = tag;
      _customFilter = tag == null ? custom : null;
    });
    final ref = _filterRef, color = _filterColor;
    board.dimmed = ref == null && _project == null
        ? null
        : (item) => item is LinkItem && !_matches(item);
    board.highlighted = ref == null
        ? null
        : (item) =>
              item is LinkItem &&
                  (s.workspace.assets[item.assetId]?.linkTags.contains(ref) ??
                      false)
              ? color
              : null;
  }

  Future<void> _addLink() async {
    final text = await promptText(
      context,
      title: 'Add a link',
      hint: 'https://…',
      action: 'Add',
    );
    if (text == null) return;
    final url = extractUrl(text);
    if (url == null) {
      s.showToast('That does not look like a web address.');
      return;
    }
    final asset = s.capture.link(url);
    await s.addToLinks(asset, tags: [?_filterRef]);
  }

  @override
  Widget build(BuildContext context) {
    final board = s.linksBoard;
    if (board == null) {
      return ColoredBox(color: AppColors.canvas);
    }
    return ListenableBuilder(
      listenable: Listenable.merge([
        board,
        s.workspace.assets,
        s.workspace.customTags, // tag chips follow new, renamed, deleted tags
      ]),
      builder: (context, _) {
        final selected = board.selectedItems;
        final link = selected.length == 1 && selected.single is LinkItem
            ? s.workspace.assets[(selected.single as LinkItem).assetId]
            : null;
        final hasLinks = board.items.any((i) => i is LinkItem);
        return Column(
          children: [
            _header(board),
            if (link != null) _tagEditor(link),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CanvasView(
                      key: const ValueKey('links-board'),
                      controller: board,
                      state: s,
                      page: AppPage.links,
                    ),
                  ),
                  if (!hasLinks)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 80,
                      child: IgnorePointer(
                        child: Text(
                          'No links yet. Share a link to THEapp, paste one '
                          'here, or use + Add link.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(CanvasController board) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.sm,
        Space.sm,
        Space.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.sidebar,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final row = Row(
            children: [
              const Text(
                'archive',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _chip(
                        key: const ValueKey('links-filter-all'),
                        label: 'All',
                        color: AppColors.textMuted,
                        on: _filter == null,
                        onTap: () => _setFilter(board, null),
                      ),
                      for (final tag in LinkTag.values)
                        _chip(
                          key: ValueKey('links-filter-${tag.id}'),
                          label: tag.label,
                          color: tag.color,
                          on: _filter == tag,
                          onTap: () =>
                              _setFilter(board, _filter == tag ? null : tag),
                        ),
                      // The user's own tags (shared with the Mindmap).
                      for (final t in s.workspace.tagsByName)
                        _chip(
                          key: ValueKey('links-filter-tag-${t.id}'),
                          label: t.name,
                          color: Color(t.color),
                          on: _customFilter == t.id,
                          onTap: () => _setFilter(
                            board,
                            null,
                            custom: _customFilter == t.id ? null : t.id,
                          ),
                        ),
                      const SizedBox(width: Space.sm),
                      _projectMenu(
                        key: const ValueKey('links-filter-project'),
                        label: _project == null
                            ? 'Project ▾'
                            : '${s.workspace.projects[_project]?.name ?? 'Project'} ▾',
                        includeAll: true,
                        onSelected: (id) =>
                            _setProject(board, id.isEmpty ? null : id),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('links-dots'),
                tooltip: 'Background dots',
                onPressed: () async {
                  final board = await s.openLinksBoard();
                  if (!context.mounted) return;
                  await showDotOpacityDialog(context, board, s.setDotOpacity);
                },
                icon: const Icon(Icons.grain, size: 18),
              ),
              IconButton(
                key: const ValueKey('links-library'),
                tooltip: 'Library: folders, where things are used, link check',
                onPressed: () => showArchiveLibrary(context, s),
                icon: const Icon(Icons.folder_copy_outlined, size: 18),
              ),
              TextButton.icon(
                key: const ValueKey('links-add'),
                onPressed: _addLink,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add link'),
              ),
            ],
          );
          return constraints.maxWidth < 500
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  // The filter row's natural width grows with custom tags.
                  // Give it enough room inside its horizontal scroller so a
                  // narrow app window never triggers a RenderFlex overflow.
                  child: SizedBox(width: 500, child: row),
                )
              : row;
        },
      ),
    );
  }

  Widget _tagEditor(Asset link) {
    return Container(
      key: const ValueKey('links-tag-editor'),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.xs,
      ),
      color: AppColors.card,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final row = Row(
            children: [
              Flexible(
                flex: 2,
                child: Text(
                  link.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              ),
              const SizedBox(width: Space.sm),
              Flexible(
                flex: 5,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final tag in LinkTag.values)
                        _chip(
                          key: ValueKey('links-tag-${tag.id}'),
                          label: tag.label,
                          color: tag.color,
                          on: link.linkTags.contains(tag.id),
                          onTap: () {
                            final tags = [...link.linkTags];
                            tags.contains(tag.id)
                                ? tags.remove(tag.id)
                                : tags.add(tag.id);
                            s.setLinkTags(link.id, tags);
                          },
                        ),
                      const SizedBox(width: Space.sm),
                      for (final id in link.projectIds)
                        if (s.workspace.projects[id] case final p?)
                          _chip(
                            key: ValueKey('links-project-$id'),
                            label: p.name,
                            color: AppColors.accent,
                            on: true,
                            onTap: () => s.workspace.assets.put(
                              link.copyWith(
                                projectIds: [...link.projectIds]..remove(id),
                              ),
                            ),
                          ),
                      _projectMenu(
                        key: const ValueKey('links-add-project'),
                        label: '+ Project',
                        onSelected: (id) {
                          if (id.isEmpty || link.projectIds.contains(id)) {
                            return;
                          }
                          s.workspace.assets.put(
                            link.copyWith(projectIds: [...link.projectIds, id]),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
          return constraints.maxWidth < 500
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: 520, child: row),
                )
              : row;
        },
      ),
    );
  }

  Widget _chip({
    required Key key,
    required String label,
    required Color color,
    required bool on,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: Space.xs),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: on ? color.withValues(alpha: 0.22) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: on ? 0.9 : 0.4)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: on ? AppColors.text : color,
            ),
          ),
        ),
      ),
    );
  }
}

extension on _LinksPageState {
  /// A menu of the open projects and study subjects.
  Widget _projectMenu({
    Key? key,
    required String label,
    required ValueChanged<String> onSelected,
    bool includeAll = false,
  }) {
    final projects = s.workspace.projects.all.where((p) => !p.archived).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return PopupMenuButton<String>(
      key: key,
      tooltip: 'Projects',
      onSelected: onSelected,
      itemBuilder: (_) => [
        if (includeAll)
          const PopupMenuItem(value: '', child: Text('All projects')),
        for (final p in projects)
          PopupMenuItem(value: p.id, child: Text(p.name)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
      ),
    );
  }
}
