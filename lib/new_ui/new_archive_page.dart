// The New Archive. Landing: vertically scrolling, layered, folder-like
// collection cards built from the real saved items (about two previews in
// front, "2/5", the rest peeking out behind). Tapping a card opens that
// collection with every item. "Whole Look" is the existing all-items Archive
// page, unchanged. All data and actions are the library's own: folders are
// LibrarySpace records, items are LibraryObject records, saving, deleting,
// moving and searching call LibraryRepository.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../data/models/object_library_models.dart';
import '../data/repositories/library_repository.dart';
import '../data/storage/attachment_image.dart';
import '../data/workspace.dart';
import '../features/library/duplicate_prompt.dart';
import '../features/library/library_page.dart';
import '../widgets/common.dart' show confirm, promptText;
import 'archive_model.dart';
import 'new_components.dart';
import 'new_folder_colors.dart';
import '../app/theme.dart';

/// Opens one saved item in the Archive's existing detail dialog.
Future<void> openArchiveItem(
  BuildContext context,
  AppState state,
  String objectId,
) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => Visibility(
        visible: false,
        maintainState: true,
        child: LibraryPage(
          state: state,
          initialObjectId: objectId,
          closeAfterInitialObject: true,
        ),
      ),
    ),
  );
}

enum _View { landing, whole, collection }

/// An item being dragged between folders.
class _ItemDrag {
  const _ItemDrag(this.ids);
  final List<String> ids;
}

class NewArchivePage extends StatefulWidget {
  const NewArchivePage({super.key, required this.state});

  final AppState state;

  @override
  State<NewArchivePage> createState() => _NewArchivePageState();
}

class _NewArchivePageState extends State<NewArchivePage> {
  final _query = TextEditingController();
  _View _view = _View.landing;
  final _path = <String>[]; // collection ids, outermost first
  bool _selectMode = false;
  final _selected = <String>{};
  bool _dragging = false;
  bool _colorsQueued = false;

  AppState get s => widget.state;
  Workspace get ws => s.workspace;
  LibraryRepository get repo => s.library;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  // ── saving a link in one tap ───────────────────────────────────────────

  /// Saves the link on the clipboard, filed in [folderId] (none: Unfiled).
  /// The save is durable at once with the host as its title; the library's own
  /// background job then fills in the page title and preview, so nothing
  /// waits on the network and it works offline. A link that is already saved
  /// asks first (open it, save anyway, or cancel).
  Future<void> _pasteLink({String? folderId}) async {
    if (_pasting) return; // a second quick tap saves nothing extra
    _pasting = true;
    try {
      await _pasteLinkOnce(folderId: folderId);
    } finally {
      _pasting = false;
    }
  }

  bool _pasting = false;

  Future<void> _pasteLinkOnce({String? folderId}) async {
    final clip = await s.capture.readClipboard();
    final url = clip.url;
    if (url == null) {
      s.showToast('No link on the clipboard. Copy one, then tap again.');
      return;
    }
    final canonical = LibraryRepository.canonicalizeUrl(url);
    if (canonical == null) {
      s.showToast('That link cannot be saved (only public web links).');
      return;
    }
    final host = Uri.parse(canonical).host;
    final folder = folderId == null ? null : ws.librarySpaces[folderId]?.name;
    final duplicate = repo.findDuplicate(sourceUrl: url);
    if (duplicate != null) {
      if (!mounted) return;
      final saveAnyway = await proceedDespiteArchiveDuplicate(
        context,
        s,
        duplicate,
      );
      if (!saveAnyway) return;
    }
    await repo.save(
      type: LibraryObjectType.website,
      sourceUrl: url,
      title: host,
      spaceId: folderId,
      allowDuplicate: duplicate != null,
    );
    s.showToast(folder == null ? 'Saved $host.' : 'Saved $host to $folder.');
  }

  // ── folder actions (existing records, additive fields) ─────────────────

  Future<void> _newFolder({String? parentId}) async {
    final name = await promptText(
      context,
      title: parentId == null ? 'New folder' : 'New subfolder',
      hint: 'Name',
      action: 'Create',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final siblings = ArchiveModel.folders(ws, parentId: parentId);
    final created = await repo.createSpace(name);
    final order = siblings.fold<int>(0, (m, f) {
      final o = f.sortOrder ?? 0;
      return o > m ? o : m;
    });
    ws.librarySpaces.put(
      created.copyWith(
        sortOrder: order + 10,
        parentId: parentId == null ? null : () => parentId,
      ),
    );
    ArchiveModel.ensureColors(ws);
    await ws.librarySpaces.flush();
  }

  Future<void> _rename(LibrarySpace space) async {
    final name = await promptText(
      context,
      title: 'Rename folder',
      initial: space.name,
      action: 'Save',
    );
    if (name == null || name.trim().isEmpty) return;
    ws.librarySpaces.put(space.copyWith(name: name.trim()));
  }

  Future<void> _pickColor(LibrarySpace space) async {
    final chosen = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardRaised,
        title: Text('Colour', style: TextStyle(color: AppColors.text)),
        content: SizedBox(
          width: 300,
          child: Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.md,
            children: [
              for (final c in NewFolderColors.all)
                Tooltip(
                  message: c.name,
                  child: GestureDetector(
                    key: ValueKey('archive-color-${c.id}'),
                    onTap: () => Navigator.pop(context, c.id),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: c.color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: space.colorId == c.id
                              ? AppColors.text
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: space.colorId == c.id
                          ? Icon(Icons.check, size: 18, color: c.onColor)
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) ws.librarySpaces.put(space.copyWith(colorId: chosen));
  }

  Future<void> _deleteFolder(LibrarySpace space) async {
    final ok = await confirm(
      context,
      title: 'Delete "${space.name}"?',
      message: 'The saved items themselves stay in your Archive.',
      action: 'Delete',
    );
    if (!ok) return;
    for (final r
        in ws.libraryRelations.all
            .where((r) => r.kind == 'space' && r.targetId == space.id)
            .toList()) {
      ws.libraryRelations.remove(r.id);
    }
    // Subfolders move up one level instead of disappearing.
    for (final child in ws.librarySpaces.all.where(
      (c) => c.parentId == space.id,
    )) {
      ws.librarySpaces.put(child.copyWith(parentId: () => space.parentId));
    }
    ws.librarySpaces.remove(space.id);
    await ws.libraryRelations.flush();
    await ws.librarySpaces.flush();
    if (_path.contains(space.id)) {
      setState(() {
        _path.removeRange(_path.indexOf(space.id), _path.length);
        if (_path.isEmpty) _view = _View.landing;
      });
    }
  }

  Future<void> _folderMenu(LibrarySpace space) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.cardRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.xl)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetRow(Icons.drive_file_rename_outline, 'Rename', 'rename'),
              _sheetRow(Icons.palette_outlined, 'Colour', 'color'),
              _sheetRow(
                space.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                space.pinned ? 'Unpin' : 'Pin to top',
                'pin',
              ),
              _sheetRow(Icons.arrow_upward, 'Move up', 'up'),
              _sheetRow(Icons.arrow_downward, 'Move down', 'down'),
              _sheetRow(
                Icons.create_new_folder_outlined,
                'New subfolder',
                'sub',
              ),
              _sheetRow(
                Icons.delete_outline,
                'Delete folder',
                'delete',
                color: AppColors.danger,
              ),
              const SizedBox(height: AppSpace.sm),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'rename':
        await _rename(space);
      case 'color':
        await _pickColor(space);
      case 'pin':
        ws.librarySpaces.put(space.copyWith(pinned: !space.pinned));
      case 'up':
        ArchiveModel.nudge(ws, space.id, -1);
      case 'down':
        ArchiveModel.nudge(ws, space.id, 1);
      case 'sub':
        await _newFolder(parentId: space.id);
      case 'delete':
        await _deleteFolder(space);
    }
  }

  Widget _sheetRow(IconData icon, String label, String value, {Color? color}) =>
      ListTile(
        key: ValueKey('archive-menu-$value'),
        leading: Icon(icon, color: color ?? AppColors.textMuted),
        title: Text(label, style: TextStyle(color: color ?? AppColors.text)),
        onTap: () => Navigator.pop(context, value),
      );

  // ── item actions ───────────────────────────────────────────────────────

  Future<void> _moveItems(List<String> ids, {String? toFolder}) async {
    String? target = toFolder;
    if (target == null) {
      target = await _chooseFolder();
      if (target == null || !mounted) return;
    }
    for (final id in ids) {
      for (final r
          in ws.libraryRelations.all
              .where((r) => r.kind == 'space' && r.objectId == id)
              .toList()) {
        if (ws.librarySpaces[r.targetId]?.kind == LibrarySpaceKind.regular) {
          await repo.removeFromRegularSpace(r.targetId, id);
        }
      }
      if (target != unfiledId) await repo.addToRegularSpace(target, id);
    }
    s.showToast(ids.length == 1 ? 'Moved.' : 'Moved ${ids.length} items.');
  }

  Future<String?> _chooseFolder() {
    final regular = [
      for (final f in ws.librarySpaces.all)
        if (f.kind == LibrarySpaceKind.regular) f,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.cardRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.xl)),
      ),
      builder: (context) => SafeArea(
        child: ListView(
          key: const ValueKey('archive-choose-folder'),
          shrinkWrap: true,
          children: [
            for (final f in regular)
              ListTile(
                key: ValueKey('archive-target-${f.id}'),
                leading: CircleAvatar(
                  radius: 8,
                  backgroundColor:
                      NewFolderColors.byId(f.colorId)?.color ??
                      AppColors.accent,
                ),
                title: Text(f.name, style: TextStyle(color: AppColors.text)),
                onTap: () => Navigator.pop(context, f.id),
              ),
            ListTile(
              key: const ValueKey('archive-target-unfiled'),
              leading: Icon(Icons.inbox_outlined, color: AppColors.textMuted),
              title: Text(
                'Unfiled',
                style: TextStyle(color: AppColors.textMuted),
              ),
              onTap: () => Navigator.pop(context, unfiledId),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleFavorite(LibraryObject o) async {
    final favorite = o.metadata['favorite'] == true;
    await repo.update(
      o.copyWith(metadata: {...o.metadata, 'favorite': !favorite}),
    );
  }

  /// Deletes with the library's own delete, then offers Undo (restores the
  /// item and its folder memberships).
  Future<void> _deleteItems(List<LibraryObject> items) async {
    final relations = [
      for (final r in ws.libraryRelations.all)
        if (r.kind == 'space' && items.any((o) => o.id == r.objectId)) r,
    ];
    for (final o in items) {
      await repo.delete(o.id);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            items.length == 1
                ? 'Deleted “${items.first.title.isEmpty ? 'Untitled' : items.first.title}”.'
                : 'Deleted ${items.length} items.',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              for (final o in items) {
                await repo.update(o.copyWith(deleted: false));
              }
              for (final r in relations) {
                ws.libraryRelations.put(r);
              }
              await ws.libraryRelations.flush();
            },
          ),
        ),
      );
  }

  // ── building ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Transparent: the app-wide atmosphere (shell) is the page background.
    return ColoredBox(
      color: Colors.transparent,
      child: ListenableBuilder(
        listenable: Listenable.merge([s, ws.changes]),
        builder: (context, _) {
          if (!_colorsQueued &&
              ws.librarySpaces.all.any((f) => f.colorId == null)) {
            _colorsQueued = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _colorsQueued = false;
              if (mounted) ArchiveModel.ensureColors(ws);
            });
          }
          return switch (_view) {
            _View.landing => _landing(),
            _View.whole => _whole(),
            _View.collection => _collection(),
          };
        },
      ),
    );
  }

  // ── landing ───────────────────────────────────────────────────────────

  Widget _landing() {
    final searching = _query.text.trim().isNotEmpty;
    final collections = ArchiveModel.landing(repo, ws);
    return Column(
      children: [
        NewPageHeader(
          title: 'Archive',
          actions: [
            NewHeaderButton(
              key: const ValueKey('archive-paste-link'),
              icon: Icons.add_link,
              label: 'Paste link',
              filled: true,
              onPressed: _pasteLink,
            ),
            NewHeaderButton(
              key: const ValueKey('archive-whole-look'),
              icon: Icons.grid_view_rounded,
              label: 'Whole Look',
              onPressed: () => setState(() => _view = _View.whole),
            ),
            NewHeaderIconButton(
              key: const ValueKey('archive-new-folder'),
              tooltip: 'New folder',
              icon: Icons.create_new_folder_outlined,
              onPressed: _newFolder,
            ),
          ],
          search: _searchField(),
        ),
        Expanded(
          child: searching
              ? _results(_query.text)
              : collections.isEmpty
              ? Center(
                  child: Text(
                    'Nothing saved yet.',
                    style: AppType.body.copyWith(color: AppColors.textFaint),
                  ),
                )
              : _stack(collections),
        ),
      ],
    );
  }

  Widget _searchField() => NewSearchField(
    key: const ValueKey('archive-search'),
    controller: _query,
    hint: 'Search the Archive',
    onChanged: (_) => setState(() {}),
    onClear: () => setState(_query.clear),
  );

  Widget _results(String raw) {
    final result = repo.search(raw);
    if (result.error != null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Text(
          result.error!,
          style: AppType.body.copyWith(color: AppColors.danger),
        ),
      );
    }
    if (result.items.isEmpty) {
      return Center(
        child: Text(
          'No matches.',
          style: AppType.body.copyWith(color: AppColors.textFaint),
        ),
      );
    }
    return ListView(
      key: const ValueKey('archive-results'),
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, 96),
      children: [
        for (final o in result.items)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: _ItemRow(
              key: ValueKey('archive-item-${o.id}'),
              state: s,
              object: o,
              onTap: () => openArchiveItem(context, s, o.id),
            ),
          ),
      ],
    );
  }

  /// The layered stack: every card overlaps the bottom of the one above.
  Widget _stack(List<ArchiveCollection> collections) {
    return ListView(
      key: const ValueKey('archive-stack'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.lg,
        96,
      ),
      children: [
        for (var i = 0; i < collections.length; i++)
          Align(
            alignment: Alignment.topCenter,
            heightFactor: i == collections.length - 1 ? 1 : 0.9,
            child: _draggableCard(collections[i]),
          ),
      ],
    );
  }

  Widget _draggableCard(ArchiveCollection c) {
    final card = _CollectionCard(
      key: ValueKey('archive-collection-${c.id}'),
      state: s,
      collection: c,
      onOpen: () => setState(() {
        _path
          ..clear()
          ..add(c.id);
        _view = _View.collection;
        _selectMode = false;
        _selected.clear();
      }),
      onMenu: c.space == null ? null : () => _folderMenu(c.space!),
    );
    if (c.space == null) return card;
    return DragTarget<Object>(
      onWillAcceptWithDetails: (d) => d.data is String || d.data is _ItemDrag,
      onAcceptWithDetails: (d) {
        final data = d.data;
        if (data is String) {
          ArchiveModel.moveBefore(ws, data, c.id);
        } else if (data is _ItemDrag) {
          _moveItems(data.ids, toFolder: c.id);
        }
      },
      builder: (context, candidate, _) => LongPressDraggable<String>(
        data: c.id,
        hapticFeedbackOnStart: true,
        feedback: SizedBox(
          width: MediaQuery.sizeOf(context).width - 2 * AppSpace.lg,
          child: Opacity(opacity: 0.9, child: card),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: card),
        child: AnimatedScale(
          scale: candidate.isEmpty ? 1 : 0.98,
          duration: AppMotion.quick,
          child: card,
        ),
      ),
    );
  }

  // ── Whole Look: the existing all-items Archive, unchanged ──────────────

  Widget _whole() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.sm,
          AppSpace.sm,
          AppSpace.lg,
          AppSpace.xs,
        ),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('archive-back'),
              tooltip: 'Back to Archive',
              icon: Icon(Icons.chevron_left, color: AppColors.textMuted),
              onPressed: () => setState(() => _view = _View.landing),
            ),
            Text(
              'Whole Look',
              style: AppType.heading.copyWith(color: AppColors.text),
            ),
          ],
        ),
      ),
      Expanded(child: LibraryPage(state: s)),
    ],
  );

  // ── one collection ────────────────────────────────────────────────────

  ArchiveCollection? _current() {
    if (_path.isEmpty) return null;
    final id = _path.last;
    if (id == unfiledId) return ArchiveModel.unfiled(repo, ws);
    final space = ws.librarySpaces[id];
    return space == null ? null : ArchiveModel.collection(repo, space);
  }

  Widget _collection() {
    final c = _current();
    if (c == null) {
      // The folder was deleted elsewhere.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _view = _View.landing);
      });
      return const SizedBox.shrink();
    }
    final subfolders = c.space == null
        ? const <LibrarySpace>[]
        : ArchiveModel.folders(ws, parentId: c.id);
    final selectedItems = [
      for (final o in c.items)
        if (_selected.contains(o.id)) o,
    ];
    return Column(
      children: [
        _collectionHeader(c),
        if (_selectMode) _selectionBar(c, selectedItems),
        if (_dragging) _dropStrip(c),
        Expanded(
          child: ListView(
            key: const ValueKey('archive-collection-items'),
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.sm,
              AppSpace.lg,
              96,
            ),
            children: [
              if (subfolders.isNotEmpty)
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final f in subfolders)
                        Padding(
                          padding: const EdgeInsets.only(right: AppSpace.sm),
                          child: ActionChip(
                            key: ValueKey('archive-sub-${f.id}'),
                            avatar: CircleAvatar(
                              radius: 7,
                              backgroundColor: NewFolderColors.byId(f.colorId)
                                  ?.color,
                            ),
                            label: Text(f.name),
                            onPressed: () => setState(() => _path.add(f.id)),
                          ),
                        ),
                    ],
                  ),
                ),
              if (c.items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(AppSpace.xl),
                  child: Center(
                    child: Text(
                      'Nothing in this folder yet.',
                      style: AppType.body.copyWith(color: AppColors.textFaint),
                    ),
                  ),
                ),
              for (final o in c.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: _itemWithActions(c, o),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _collectionHeader(ArchiveCollection c) {
    final color = c.color;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.xs,
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('archive-back'),
            tooltip: 'Back',
            icon: Icon(Icons.chevron_left, color: AppColors.textMuted),
            onPressed: () => setState(() {
              _path.removeLast();
              if (_path.isEmpty) _view = _View.landing;
              _selectMode = false;
              _selected.clear();
            }),
          ),
          if (!c.virtual)
            Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.only(right: AppSpace.sm),
              decoration: BoxDecoration(
                color: color.color,
                shape: BoxShape.circle,
              ),
            ),
          Expanded(
            child: Text(
              c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.heading.copyWith(color: AppColors.text),
            ),
          ),
          NewPill('${c.total}'),
          IconButton(
            key: const ValueKey('archive-paste-link'),
            tooltip: 'Paste the link on the clipboard into this folder',
            icon: Icon(Icons.add_link, color: AppColors.accent),
            onPressed: () =>
                _pasteLink(folderId: c.space == null ? null : c.id),
          ),
          IconButton(
            key: const ValueKey('archive-select'),
            tooltip: _selectMode ? 'Done selecting' : 'Select',
            icon: Icon(
              _selectMode ? Icons.check_circle : Icons.checklist,
              color: _selectMode ? AppColors.accent : AppColors.textMuted,
            ),
            onPressed: () => setState(() {
              _selectMode = !_selectMode;
              _selected.clear();
            }),
          ),
          if (c.space != null)
            IconButton(
              key: const ValueKey('archive-folder-menu'),
              tooltip: 'Folder options',
              icon: Icon(Icons.more_horiz, color: AppColors.textMuted),
              onPressed: () => _folderMenu(c.space!),
            ),
        ],
      ),
    );
  }

  Widget _selectionBar(ArchiveCollection c, List<LibraryObject> chosen) {
    final n = chosen.length;
    return Container(
      key: const ValueKey('archive-selection-bar'),
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadii.popup),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              n == 0 ? 'Select items' : '$n selected',
              style: AppType.label.copyWith(color: AppColors.textMuted),
            ),
          ),
          TextButton(
            key: const ValueKey('archive-select-all'),
            onPressed: () => setState(() {
              _selected
                ..clear()
                ..addAll(c.items.map((o) => o.id));
            }),
            child: const Text('All'),
          ),
          IconButton(
            key: const ValueKey('archive-bulk-move'),
            tooltip: 'Move',
            icon: const Icon(Icons.drive_file_move_outlined),
            onPressed: n == 0
                ? null
                : () async {
                    await _moveItems([for (final o in chosen) o.id]);
                    if (mounted) setState(() => _selected.clear());
                  },
          ),
          IconButton(
            key: const ValueKey('archive-bulk-favorite'),
            tooltip: 'Favorite',
            icon: const Icon(Icons.star_outline),
            onPressed: n == 0
                ? null
                : () async {
                    for (final o in chosen) {
                      if (o.metadata['favorite'] != true) {
                        await _toggleFavorite(o);
                      }
                    }
                  },
          ),
          IconButton(
            key: const ValueKey('archive-bulk-delete'),
            tooltip: 'Delete',
            icon: Icon(Icons.delete_outline, color: AppColors.danger),
            onPressed: n == 0
                ? null
                : () async {
                    await _deleteItems(chosen);
                    if (mounted) setState(() => _selected.clear());
                  },
          ),
        ],
      ),
    );
  }

  /// While an item is dragged: the other folders to drop it on.
  Widget _dropStrip(ArchiveCollection from) {
    final folders = [
      for (final f in ws.librarySpaces.all)
        if (f.kind == LibrarySpaceKind.regular && f.id != from.id) f,
    ];
    return SizedBox(
      key: const ValueKey('archive-drop-strip'),
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        children: [
          for (final f in folders)
            DragTarget<_ItemDrag>(
              onAcceptWithDetails: (d) {
                _moveItems(d.data.ids, toFolder: f.id);
                setState(() => _dragging = false);
              },
              builder: (context, candidate, _) => Padding(
                padding: const EdgeInsets.only(right: AppSpace.sm),
                child: Chip(
                  key: ValueKey('archive-drop-${f.id}'),
                  avatar: CircleAvatar(
                    radius: 7,
                    backgroundColor: NewFolderColors.byId(f.colorId)?.color,
                  ),
                  label: Text(f.name),
                  side: BorderSide(
                    color: candidate.isEmpty
                        ? AppColors.border
                        : AppColors.accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _itemWithActions(ArchiveCollection c, LibraryObject o) {
    final row = _ItemRow(
      key: ValueKey('archive-item-${o.id}'),
      state: s,
      object: o,
      selecting: _selectMode,
      selected: _selected.contains(o.id),
      onTap: () {
        if (_selectMode) {
          setState(() {
            if (!_selected.add(o.id)) _selected.remove(o.id);
          });
        } else {
          openArchiveItem(context, s, o.id);
        }
      },
    );
    if (_selectMode) return row;
    return LongPressDraggable<_ItemDrag>(
      data: _ItemDrag([o.id]),
      hapticFeedbackOnStart: true,
      onDragStarted: () => setState(() => _dragging = true),
      onDragEnd: (_) => setState(() => _dragging = false),
      feedback: SizedBox(
        width: MediaQuery.sizeOf(context).width - 2 * AppSpace.lg,
        child: Opacity(opacity: 0.9, child: row),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: row),
      child: SwipeActions(
        key: ValueKey('archive-swipe-${o.id}'),
        actions: [
          SwipeAction(
            key: ValueKey('archive-swipe-move-${o.id}'),
            icon: Icons.drive_file_move_outlined,
            label: 'Move',
            color: AppColors.accent,
            onTap: () => _moveItems([o.id]),
          ),
          SwipeAction(
            key: ValueKey('archive-swipe-favorite-${o.id}'),
            icon: o.metadata['favorite'] == true
                ? Icons.star
                : Icons.star_outline,
            label: 'Favorite',
            color: BrandColors.warmCoral,
            onTap: () => _toggleFavorite(o),
          ),
          SwipeAction(
            key: ValueKey('archive-swipe-delete-${o.id}'),
            icon: Icons.delete_outline,
            label: 'Delete',
            color: AppColors.danger,
            onTap: () => _deleteItems([o]),
          ),
        ],
        child: row,
      ),
    );
  }
}

// ── the layered collection card ─────────────────────────────────────────

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    super.key,
    required this.state,
    required this.collection,
    required this.onOpen,
    this.onMenu,
  });

  final AppState state;
  final ArchiveCollection collection;
  final VoidCallback onOpen;
  final VoidCallback? onMenu;

  static const height = 236.0;

  @override
  Widget build(BuildContext context) {
    final c = collection;
    final light = AppColors.background.computeLuminance() > 0.5;
    final folder = c.color.color;
    final base = c.virtual
        ? AppColors.surfaceSecondary
        // Light: a gentle wash of the folder colour (the saturated colour is
        // kept for the border and the count), dark: a deeper tint.
        : Color.lerp(AppColors.card, folder, light ? 0.22 : 0.3)!;
    final fg = contrastOn(base);
    final shown = c.items.take(ArchiveCollection.visibleCount).toList();
    final hidden = c.hidden;
    final tilesTop = 56.0 + hidden * 7;
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: base,
          borderRadius: BorderRadius.circular(AppRadii.xl + 2),
          border: Border.all(
            color: folder.withValues(alpha: light ? 0.4 : 0.55),
          ),
          boxShadow: AppElevation.subtle,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.xl + 2),
          child: Stack(
            children: [
              // Previews that do not fit in front, peeking out behind.
              for (var k = hidden; k >= 1; k--)
                Positioned(
                  top: tilesTop - 7.0 * k,
                  left: 14.0 + 9 * k,
                  right: 14.0 + 9 * k,
                  height: 44,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color.lerp(
                        base,
                        light ? Colors.white : folder,
                        light
                            ? 0.55 + 0.1 * (4 - k) / 3
                            : 0.18 + 0.05 * (4 - k),
                      ),
                      borderRadius: BorderRadius.circular(AppRadii.popup),
                    ),
                  ),
                ),
              Positioned(
                top: 12,
                left: 18,
                right: 4,
                height: 36,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: fg,
                        ),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: fg.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(AppRadii.capsule),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        child: Text(
                          c.countLabel,
                          key: ValueKey('archive-count-${c.id}'),
                          style: TextStyle(
                            fontSize: AppType.sizeLabel,
                            fontWeight: FontWeight.w600,
                            color: fg,
                          ),
                        ),
                      ),
                    ),
                    if (onMenu != null)
                      IconButton(
                        key: ValueKey('archive-card-menu-${c.id}'),
                        tooltip: 'Folder options',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.more_horiz, color: fg),
                        onPressed: onMenu,
                      )
                    else
                      const SizedBox(width: AppSpace.md),
                  ],
                ),
              ),
              Positioned(
                top: tilesTop,
                left: 14,
                right: 14,
                bottom: 14,
                child: shown.isEmpty
                    ? Center(
                        child: Text(
                          'Empty',
                          style: TextStyle(
                            color: fg.withValues(alpha: 0.6),
                            fontSize: AppType.sizeBodySmall,
                          ),
                        ),
                      )
                    : Row(
                        children: [
                          for (var i = 0; i < shown.length; i++) ...[
                            if (i > 0) const SizedBox(width: AppSpace.sm + 2),
                            Expanded(
                              child: _PreviewTile(
                                key: ValueKey('archive-preview-${shown[i].id}'),
                                state: state,
                                object: shown[i],
                                tint: folder,
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
    );
  }
}

/// ImageProvider for an item's real picture or thumbnail, if it has one.
/// (The file is resolved by archiveImageFileOf in archive_model.dart.)
ImageProvider? archiveImageOf(AppState state, LibraryObject object) {
  final name = archiveImageFileOf(state.workspace, object);
  if (name == null) return null;
  return AttachmentImageProvider(state.workspace.attachments, name);
}

IconData archiveIconOf(LibraryObject o) => switch (o.type) {
  LibraryObjectType.image => Icons.image_outlined,
  LibraryObjectType.article => Icons.article_outlined,
  LibraryObjectType.website => Icons.language,
  LibraryObjectType.document => Icons.picture_as_pdf_outlined,
  LibraryObjectType.note => Icons.notes,
  LibraryObjectType.video => Icons.movie_outlined,
  _ => Icons.bookmark_border,
};

/// What an item says about itself without inventing anything: its source
/// host, entity, or type; for notes the start of their text.
String archiveMetaOf(LibraryObject o) {
  final host = o.sourceUrl == null ? null : Uri.tryParse(o.sourceUrl!)?.host;
  return o.mainEntity?.name ??
      (host != null && host.isNotEmpty ? host : null) ??
      o.type.name;
}

class _PreviewTile extends StatelessWidget {
  const _PreviewTile({
    super.key,
    required this.state,
    required this.object,
    required this.tint,
  });

  final AppState state;
  final LibraryObject object;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    // Paper-like tiles (cream / tinted) with dark text, as saved cards.
    final paper = Color.lerp(const Color(0xFFFFFBFA), tint, 0.16)!;
    final ink = contrastOn(paper);
    final image = archiveImageOf(state, object);
    final title = object.title.isEmpty ? 'Untitled' : object.title;
    final snippet = object.type == LibraryObjectType.note
        ? (object.content ?? '').trim()
        : (object.description ?? object.summary ?? '').trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: ColoredBox(
        color: paper,
        child: image != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  Image(image: image, fit: BoxFit.cover),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0xCC000000)],
                        ),
                      ),
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: AppType.sizeLabel,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(archiveIconOf(object), size: 15, color: ink),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            archiveMetaOf(object),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.sizeMeta,
                              color: ink.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.sizeBodySmall,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                    if (snippet.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Expanded(
                        child: Text(
                          snippet,
                          overflow: TextOverflow.fade,
                          style: TextStyle(
                            fontSize: AppType.sizeMeta,
                            height: 1.3,
                            color: ink.withValues(alpha: 0.75),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

// ── an item as a row ────────────────────────────────────────────────────

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.state,
    required this.object,
    required this.onTap,
    this.selecting = false,
    this.selected = false,
  });

  final AppState state;
  final LibraryObject object;
  final VoidCallback onTap;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final image = archiveImageOf(state, object);
    final favorite = object.metadata['favorite'] == true;
    return NewCard(
      padding: const EdgeInsets.all(AppSpace.sm),
      onTap: onTap,
      borderColor: selected ? AppColors.accent : null,
      child: Row(
        children: [
          if (selecting)
            Padding(
              padding: const EdgeInsets.only(right: AppSpace.sm),
              child: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected ? AppColors.accent : AppColors.textFaint,
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.md),
            child: SizedBox(
              width: 56,
              height: 56,
              child: image != null
                  ? Image(image: image, fit: BoxFit.cover)
                  : ColoredBox(
                      color: AppColors.surfaceSecondary,
                      child: Icon(
                        archiveIconOf(object),
                        color: AppColors.textMuted,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  object.title.isEmpty ? 'Untitled' : object.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  archiveMetaOf(object),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption.copyWith(color: AppColors.textFaint),
                ),
              ],
            ),
          ),
          if (favorite) Icon(Icons.star, size: 18, color: BrandColors.warmCoral),
        ],
      ),
    );
  }
}

// ── swipe to reveal actions (Archive items only) ────────────────────────

class SwipeAction {
  const SwipeAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final Key key;
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
}

/// Swipe the row left to reveal [actions]. A deliberate threshold (it must
/// be pulled more than a third of the way open) keeps an accidental brush
/// from opening them.
class SwipeActions extends StatefulWidget {
  const SwipeActions({super.key, required this.actions, required this.child});

  final List<SwipeAction> actions;
  final Widget child;

  @override
  State<SwipeActions> createState() => _SwipeActionsState();
}

class _SwipeActionsState extends State<SwipeActions> {
  static const _each = 68.0;
  double _dx = 0; // 0 … -open

  double get _open => _each * widget.actions.length;

  void _end() {
    final snapOpen = -_dx > _open / 3;
    if (snapOpen) HapticFeedback.selectionClick();
    setState(() => _dx = snapOpen ? -_open : 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) =>
          setState(() => _dx = (_dx + d.delta.dx).clamp(-_open, 0).toDouble()),
      onHorizontalDragEnd: (_) => _end(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: Stack(
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final a in widget.actions)
                      GestureDetector(
                        key: a.key,
                        onTap: () {
                          setState(() => _dx = 0);
                          a.onTap();
                        },
                        child: Container(
                          width: _each,
                          color: a.color,
                          alignment: Alignment.center,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                a.icon,
                                size: 20,
                                color: contrastOn(a.color),
                              ),
                              Text(
                                a.label,
                                style: TextStyle(
                                  fontSize: AppType.sizeMeta,
                                  color: contrastOn(a.color),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            AnimatedContainer(
              duration: _dx == 0 || _dx == -_open
                  ? AppMotion.quick
                  : Duration.zero,
              transform: Matrix4.translationValues(_dx, 0, 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }
}
