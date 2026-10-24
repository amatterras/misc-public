// The Archive library: resources in a folder tree, with their details,
// where each one is used (backlinks), and a link check that finds broken
// references and duplicates and repairs them (backed up, undoable).
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/library_models.dart';
import '../../widgets/common.dart';
import '../tags/tag_ui.dart';
import '../sharing/share_dialog.dart';
import '../../platform/input_hints.dart';
import '../transfer/transfer.dart';
import 'archive_library.dart';

Future<void> showArchiveLibrary(BuildContext context, AppState s) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 860,
          height: 560,
          child: ArchiveLibrary(state: s),
        ),
      ),
    );

class ArchiveLibrary extends StatefulWidget {
  const ArchiveLibrary({
    super.key,
    required this.state,
    this.embedded = false,
    this.initialFolder,
    this.initialSelected,
  });
  final AppState state;

  /// Shown as a page (in the main area or a window), not a dialog.
  final bool embedded;
  final String? initialFolder;
  final String? initialSelected;

  @override
  State<ArchiveLibrary> createState() => _ArchiveLibraryState();
}

class _ArchiveLibraryState extends State<ArchiveLibrary> {
  AppState get s => widget.state;

  /// The open folder ('' = top level, null = everything).
  String? _folder = '';
  String? _selected;
  Map<String, Set<ResourceRef>>? _refs;

  @override
  void initState() {
    super.initState();
    final asset = s.workspace.assets[widget.initialSelected];
    if (asset != null) {
      _selected = asset.id;
      _folder = asset.folderId ?? '';
    } else if (widget.initialFolder != null) {
      _folder = widget.initialFolder;
    }
    _loadRefs();
  }

  /// Leaves the dialog; a page stays where it is.
  void _leave(BuildContext context) {
    if (!widget.embedded) Navigator.pop(context);
  }

  Future<void> _loadRefs() async {
    final (_, refs) = await s.checkArchive();
    if (mounted) setState(() => _refs = refs);
  }

  Future<String?> _pickFolder(String title, {String? exclude}) async {
    final ws = s.workspace;
    final skip = exclude == null ? <String>{} : ws.archiveSubtree(exclude);
    final folders =
        ws.archiveFolders.all.where((f) => !skip.contains(f.id)).toList()..sort(
          (a, b) => ws
              .archiveFolderLabel(a.id)
              .compareTo(ws.archiveFolderLabel(b.id)),
        );
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Top level'),
          ),
          for (final f in folders)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, f.id),
              child: Text(ws.archiveFolderLabel(f.id)),
            ),
        ],
      ),
    );
  }

  Future<void> _folderMenu(String id) async {
    final ws = s.workspace;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(ws.archiveFolderLabel(id)),
        children: [
          for (final (v, l) in const [
            ('new', 'New folder inside'),
            ('rename', 'Rename'),
            ('move', 'Move'),
            ('delete', 'Delete (contents move up)'),
            ('page', 'Open in its own page'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, v),
              child: Text(l),
            ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'page':
        _leave(context);
        s.openArchiveItem(folderId: id);
      case 'new':
        final name = await promptText(context, title: 'Folder name');
        if (name != null) ws.createArchiveFolder(name, parentId: id);
      case 'rename':
        final name = await promptText(
          context,
          title: 'Rename folder',
          initial: ws.archiveFolders[id]?.name ?? '',
        );
        if (name != null) ws.renameArchiveFolder(id, name);
      case 'move':
        final to = await _pickFolder('Move into', exclude: id);
        if (to != null && !ws.moveArchiveFolder(id, to.isEmpty ? null : to)) {
          s.showToast('A folder cannot go inside itself.');
        }
      case 'delete':
        if (await confirm(
          context,
          title: 'Delete this folder?',
          message: 'What is inside moves up one level. Nothing is deleted.',
        )) {
          ws.deleteArchiveFolder(id);
          if (_folder == id) setState(() => _folder = '');
        }
    }
  }

  /// "Everything" (only a view) and "Top level" (a drop there takes things
  /// out of their folder).
  Widget _viewTile(String? id, String label) {
    final tile = ListTile(
      dense: true,
      selected: _folder == id,
      title: Text(label),
      onTap: () => setState(() => _folder = id),
    );
    return id == ''
        ? TransferTarget(state: s, place: const ArchivePlace(null), child: tile)
        : tile;
  }

  Widget _tree(String? parent, int depth) {
    final ws = s.workspace;
    final children =
        ws.archiveFolders.all.where((f) => f.parentId == parent).toList()..sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in children) ...[
          // Drop resources (or link cards from a mindmap) to file them here.
          TransferTarget(
            state: s,
            place: ArchivePlace(f.id),
            child: InkWell(
              key: ValueKey('archive-folder-${f.id}'),
              onTap: () => setState(() => _folder = f.id),
              onLongPress: () => _folderMenu(f.id),
              onSecondaryTap: () => _folderMenu(f.id),
              child: Container(
                color: _folder == f.id ? AppColors.card : null,
                padding: EdgeInsets.fromLTRB(8.0 + depth * 14, 6, 4, 6),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_outlined,
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(f.name, overflow: TextOverflow.ellipsis),
                    ),
                    InkWell(
                      onTap: () => _folderMenu(f.id),
                      child: const Icon(
                        Icons.more_horiz,
                        size: 14,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _tree(f.id, depth + 1),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ws = s.workspace;
    return ListenableBuilder(
      listenable: Listenable.merge([
        ws.assets,
        ws.archiveFolders,
        ws.customTags,
        s,
      ]),
      builder: (context, _) {
        final items =
            ws.assets.all
                .where(
                  (a) =>
                      _folder == null ||
                      (a.folderId ?? '') == _folder ||
                      (_folder == '' && ws.archiveFolders[a.folderId] == null),
                )
                .toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final sel = ws.assets[_selected];
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Text(
                    'Archive library',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (s.lastArchiveRepair != null)
                    TextButton(
                      key: const ValueKey('archive-undo'),
                      onPressed: () {
                        s.undoArchiveRepair();
                        _loadRefs();
                      },
                      child: Text('Undo ${s.lastArchiveRepair!.label}'),
                    ),
                  TextButton.icon(
                    key: const ValueKey('archive-check'),
                    onPressed: () => _check(context),
                    icon: const Icon(Icons.rule, size: 16),
                    label: const Text('Check links'),
                  ),
                  if (!widget.embedded)
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 210,
                    child: ListView(
                      children: [
                        for (final (id, label) in const [
                          (null, 'Everything'),
                          ('', 'Top level'),
                        ])
                          _viewTile(id, label),
                        _tree(null, 0),
                        TextButton.icon(
                          key: const ValueKey('archive-new-folder'),
                          onPressed: () async {
                            final name = await promptText(
                              context,
                              title: 'New folder',
                              action: 'Create',
                            );
                            if (name == null) return;
                            final f = ws.createArchiveFolder(
                              name,
                              parentId: (_folder ?? '').isEmpty
                                  ? null
                                  : _folder,
                            );
                            setState(() => _folder = f.id);
                          },
                          icon: const Icon(Icons.create_new_folder_outlined),
                          label: const Text('New folder'),
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: items.isEmpty
                        ? const Center(
                            child: Text(
                              'Nothing in this folder.',
                              style: TextStyle(color: AppColors.textFaint),
                            ),
                          )
                        : ListView(
                            children: [
                              for (final a in items)
                                // Drag to a folder, a note, a day, a mindmap…
                                TransferSource(
                                  transfer: () => AssetsTransfer([a.id]),
                                  touch: touchFirst,
                                  feedback: Text(a.label),
                                  child: ListTile(
                                    key: ValueKey('archive-item-${a.id}'),
                                    dense: true,
                                    selected: a.id == _selected,
                                    leading: Icon(switch (a.kind) {
                                      AssetKind.link => Icons.link,
                                      AssetKind.image => Icons.image_outlined,
                                      AssetKind.document =>
                                        Icons.picture_as_pdf_outlined,
                                    }, size: 18),
                                    title: Text(
                                      a.label,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${_refs?[a.id]?.length ?? 0} uses'
                                          '${a.folderId == null ? '' : ' · ${ws.archiveFolderLabel(a.folderId)}'}',
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        // The user's own tags, in their colours.
                                        if (ws.tagsOfAsset(a) case final tags
                                            when tags.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 3,
                                            ),
                                            child: Wrap(
                                              spacing: 4,
                                              runSpacing: 3,
                                              children: [
                                                for (final t in tags)
                                                  TagChip(t, small: true),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                    onTap: () =>
                                        setState(() => _selected = a.id),
                                  ),
                                ),
                            ],
                          ),
                  ),
                  if (sel != null) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(width: 280, child: _details(context, sel)),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _details(BuildContext context, Asset a) {
    final ws = s.workspace;
    final refs = (_refs?[a.id] ?? const <ResourceRef>{}).toList();
    Future<void> edit(String field) async {
      final v = await promptText(
        context,
        title: field == 'title' ? 'Title' : 'Description',
        initial: (field == 'title' ? a.title : a.description) ?? '',
      );
      if (v == null) return;
      ws.assets.put(
        field == 'title'
            ? a.copyWith(title: v.trim())
            : a.copyWith(description: v.trim()),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        InkWell(
          onTap: () => edit('title'),
          child: Text(
            a.label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 4),
        InkWell(
          onTap: () => edit('description'),
          child: Text(
            (a.description ?? '').isEmpty
                ? 'Add a description…'
                : a.description!,
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ),
        if (a.url != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(
              a.url!,
              style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Added ${formatShortDate(a.createdAt)}'
            '${a.fileSize == null ? '' : ' · ${(a.fileSize! / 1024).round()} KB'}',
            style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 4,
          children: [
            TextButton(
              key: const ValueKey('archive-tags'),
              onPressed: () async {
                final chosen = await showTagPicker(
                  context,
                  s,
                  selected: {for (final t in ws.tagsOfAsset(a)) t.id},
                  what: '“${a.label}”',
                );
                if (chosen != null) ws.setAssetTags(a.id, chosen);
              },
              child: const Text('Tags'),
            ),
            TextButton(
              key: const ValueKey('archive-move'),
              onPressed: () async {
                final to = await _pickFolder('Move to');
                if (to != null) {
                  ws.moveAssetToFolder(a.id, to.isEmpty ? null : to);
                }
              },
              child: const Text('Move'),
            ),
            TextButton(
              onPressed: () => showShareDialog(
                context,
                s,
                kind: 'link',
                sourceId: a.id,
                title: a.label,
                body: [a.label, ?a.url, ?a.description].join('\n\n'),
              ),
              child: const Text('Share'),
            ),
            if (!widget.embedded || widget.initialSelected != a.id)
              TextButton(
                key: const ValueKey('archive-open-page'),
                onPressed: () {
                  _leave(context);
                  s.openArchiveItem(assetId: a.id);
                },
                child: const Text('Own page'),
              ),
          ],
        ),
        const Divider(),
        Text(
          refs.isEmpty ? 'Not used anywhere yet.' : 'Used in',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        for (final r in refs)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(switch (r.kind) {
              'note' => Icons.description_outlined,
              'task' => Icons.check_box_outlined,
              'canvas' => Icons.hub_outlined,
              _ => Icons.calendar_today_outlined,
            }, size: 16),
            title: Text(r.title, overflow: TextOverflow.ellipsis),
            onTap: () {
              _leave(context);
              switch (r.kind) {
                case 'note':
                  s.openNote(r.id);
                case 'task':
                  s.openTask(r.id);
                case 'canvas':
                  s.openCanvas(r.id);
                default:
                  s.goTo(AppPage.calendar);
              }
            },
          ),
      ],
    );
  }

  Future<void> _check(BuildContext context) async {
    final (report, refs) = await s.checkArchive();
    if (!context.mounted) return;
    setState(() => _refs = refs);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Link check', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 480,
          height: 340,
          child: report.isClean
              ? const Center(child: Text('Everything is in order.'))
              : ListView(
                  children: [
                    if (report.broken.isNotEmpty) ...[
                      Text(
                        '${report.broken.length} missing resources are still '
                        'referred to:',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      for (final MapEntry(:value) in report.broken.entries)
                        Text(
                          '• ${value.map((r) => r.title).join(', ')}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      TextButton(
                        key: const ValueKey('archive-fix-broken'),
                        onPressed: () async {
                          var onCanvases = 0;
                          await s.repairArchive(() {
                            final (undo, n) = removeBrokenReferences(
                              s.workspace,
                              report,
                            );
                            onCanvases = n;
                            return undo;
                          });
                          if (context.mounted) Navigator.pop(context);
                          s.showToast(
                            onCanvases == 0
                                ? 'Broken references removed.'
                                : 'Broken references removed. $onCanvases '
                                      'mindmaps still show a missing card; '
                                      'delete it there.',
                          );
                          _loadRefs();
                        },
                        child: const Text('Remove broken references'),
                      ),
                    ],
                    if (report.duplicates.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${report.duplicates.length} resources are saved more '
                        'than once:',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      for (final g in report.duplicates)
                        ListTile(
                          dense: true,
                          title: Text(g.first.label),
                          subtitle: Text('${g.length} copies'),
                          trailing: TextButton(
                            onPressed: () async {
                              var kept = 0;
                              await s.repairArchive(() {
                                final (undo, k) = mergeDuplicates(
                                  s.workspace,
                                  g,
                                  refs,
                                );
                                kept = k.length;
                                return undo;
                              });
                              if (context.mounted) Navigator.pop(context);
                              s.showToast(
                                kept == 0
                                    ? 'Merged.'
                                    : 'Merged. $kept copies stay because a '
                                          'mindmap shows them.',
                              );
                              _loadRefs();
                            },
                            child: const Text('Merge'),
                          ),
                        ),
                    ],
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
