// The Links library: one board of link cards (preview image, title, tags)
// that can be arranged and written on like a canvas. It reuses the Canvas
// engine and storage: the board is a canvas document (`links-board`,
// kind `links`) that syncs per card, and each card shows a shared link
// Asset, whose tags (`linkTags`) sync with the link.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../widgets/common.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_page.dart';
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

  void _setFilter(CanvasController board, LinkTag? tag) {
    setState(() => _filter = tag);
    board.dimmed = tag == null
        ? null
        : (item) =>
              item is LinkItem &&
              !(s.workspace.assets[item.assetId]?.linkTags.contains(tag.id) ??
                  false);
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
    await s.addToLinks(asset, tags: [?_filter?.id]);
  }

  @override
  Widget build(BuildContext context) {
    final board = s.linksBoard;
    if (board == null) {
      return const ColoredBox(color: AppColors.canvas);
    }
    return ListenableBuilder(
      listenable: Listenable.merge([board, s.workspace.assets]),
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
                    const Positioned(
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
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Text(
            'Links',
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
                ],
              ),
            ),
          ),
          TextButton.icon(
            key: const ValueKey('links-add'),
            onPressed: _addLink,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add link'),
          ),
        ],
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
      child: Row(
        children: [
          Flexible(
            flex: 2,
            child: Text(
              link.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
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
                ],
              ),
            ),
          ),
        ],
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
