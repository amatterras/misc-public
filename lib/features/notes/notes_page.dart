import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../data/models/library_models.dart';
import '../../data/workspace.dart';
import '../../platform/input_hints.dart';
import '../../widgets/common.dart';

/// Which notes the middle column shows.
sealed class NoteFilter {
  const NoteFilter();
}

class AllNotes extends NoteFilter {
  const AllNotes();
}

class FavoriteNotes extends NoteFilter {
  const FavoriteNotes();
}

class FolderNotes extends NoteFilter {
  const FolderNotes(this.folderId);
  final String folderId;
}

class TagNotes extends NoteFilter {
  const TagNotes(this.tag);
  final String tag;
}

class NotesPage extends StatefulWidget {
  const NotesPage({super.key, required this.state});

  final AppState state;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  NoteFilter _filter = const AllNotes();
  String _search = '';
  String? _selectedId;

  AppState get s => widget.state;

  @override
  Widget build(BuildContext context) {
    // Another page asked to open a specific note.
    final requested = s.selectedNoteId;
    if (requested != null) {
      _selectedId = requested;
      s.selectedNoteId = null;
      final note = s.workspace.notes[requested];
      if (note != null && !_matchesFilter(note)) _filter = const AllNotes();
    }
    return WorkspaceBuilder(
      state: s,
      // Side columns shrink in narrow windows so the editor keeps room.
      builder: (context) => LayoutBuilder(
        builder: (context, box) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: (box.maxWidth * 0.22).clamp(110, 230),
              child: _buildFolders(context),
            ),
            const VerticalDivider(width: 1),
            SizedBox(
              width: (box.maxWidth * 0.3).clamp(130, 320),
              child: _buildList(context),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _buildEditor(context)),
          ],
        ),
      ),
    );
  }

  bool _matchesFilter(Note n) => switch (_filter) {
    AllNotes() => true,
    FavoriteNotes() => n.favorite,
    FolderNotes(:final folderId) =>
      n.folderId != null &&
          s.workspace.folderAndDescendants(folderId).contains(n.folderId),
    TagNotes(:final tag) => n.tags.contains(tag),
  };

  // ------------------------------------------------------------ folders --

  Widget _buildFolders(BuildContext context) {
    final ws = s.workspace;
    final tags = {for (final n in ws.notes.all) ...n.tags}.toList()..sort();
    Widget item(
      String label,
      IconData icon,
      NoteFilter filter, {
      int depth = 0,
      Widget? trailing,
    }) {
      final selected = switch ((filter, _filter)) {
        (AllNotes(), AllNotes()) => true,
        (FavoriteNotes(), FavoriteNotes()) => true,
        (FolderNotes(folderId: final a), FolderNotes(folderId: final b)) =>
          a == b,
        (TagNotes(tag: final a), TagNotes(tag: final b)) => a == b,
        _ => false,
      };
      return Padding(
        padding: EdgeInsets.only(left: depth * 14.0),
        child: Material(
          color: selected ? AppColors.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _filter = filter),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: selected ? AppColors.text : AppColors.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: selected ? AppColors.text : AppColors.textMuted,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(Space.md),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(10, 20, 10, 12),
          child: Text(
            'Notes',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
        ),
        item(
          'All notes',
          Icons.notes,
          const AllNotes(),
          trailing: _count(ws.notes.length),
        ),
        item('Favorites', Icons.star_outline, const FavoriteNotes()),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 18, 4, 6),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'FOLDERS',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.6,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
              GhostIconButton(
                icon: Icons.create_new_folder_outlined,
                tooltip: 'New folder',
                size: 16,
                onTap: () => _newFolder(null),
              ),
            ],
          ),
        ),
        for (final (folder, depth) in ws.folderTree())
          GestureDetector(
            onSecondaryTapUp: (d) => _folderMenu(folder, d.globalPosition),
            onLongPressStart: (d) => _folderMenu(folder, d.globalPosition),
            child: item(
              folder.name,
              Icons.folder_outlined,
              FolderNotes(folder.id),
              depth: depth,
              trailing: Builder(
                builder: (buttonContext) => GhostIconButton(
                  icon: Icons.more_horiz,
                  tooltip: 'Folder options',
                  size: 14,
                  onTap: () {
                    final box = buttonContext.findRenderObject() as RenderBox;
                    _folderMenu(
                      folder,
                      box.localToGlobal(box.size.bottomLeft(Offset.zero)),
                    );
                  },
                ),
              ),
            ),
          ),
        if (ws.folders.length == 0)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              'Folders are shared with Canvas.',
              style: TextStyle(fontSize: 12, color: AppColors.textFaint),
            ),
          ),
        if (tags.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 18, 10, 6),
            child: Text(
              'TAGS',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.6,
                color: AppColors.textFaint,
              ),
            ),
          ),
          for (final tag in tags) item('#$tag', Icons.tag, TagNotes(tag)),
        ],
      ],
    );
  }

  Widget _count(int n) => Text(
    '$n',
    style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
  );

  Future<void> _newFolder(String? parentId) async {
    final name = await promptText(
      context,
      title: parentId == null ? 'New folder' : 'New subfolder',
      hint: 'Folder name',
      action: 'Create',
    );
    if (name == null) return;
    final folder = s.workspace.createFolder(name, parentId: parentId);
    setState(() => _filter = FolderNotes(folder.id));
  }

  Future<void> _folderMenu(Folder folder, Offset at) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(value: 'sub', height: 36, child: Text('New subfolder')),
        PopupMenuItem(value: 'rename', height: 36, child: Text('Rename')),
        PopupMenuItem(
          value: 'delete',
          height: 36,
          child: Text('Delete folder'),
        ),
      ],
    );
    if (!mounted) return;
    final ws = s.workspace;
    switch (choice) {
      case 'sub':
        await _newFolder(folder.id);
      case 'rename':
        final name = await promptText(
          context,
          title: 'Rename folder',
          initial: folder.name,
        );
        if (name != null) ws.folders.put(folder.copyWith(name: name));
      case 'delete':
        final ok = await confirm(
          context,
          title: 'Delete “${folder.name}”?',
          message: 'Notes and subfolders inside it move up one level. Nothing is deleted.',
          action: 'Delete folder',
        );
        if (ok) {
          ws.deleteFolder(folder.id);
          setState(() => _filter = const AllNotes());
        }
    }
  }

  // --------------------------------------------------------------- list --

  Widget _buildList(BuildContext context) {
    final ws = s.workspace;
    final q = _search.trim().toLowerCase();
    final notes = ws.notes.all.where(_matchesFilter).where((n) {
      if (q.isEmpty) return true;
      return n.title.toLowerCase().contains(q) ||
          n.body.toLowerCase().contains(q) ||
          n.tags.any((t) => t.toLowerCase().contains(q));
    }).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final filter = _filter;
    final canvases = filter is FolderNotes
        ? s.canvasList
              .where(
                (c) =>
                    c.folderId != null &&
                    ws
                        .folderAndDescendants(filter.folderId)
                        .contains(c.folderId),
              )
              .toList()
        : const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 32, Space.lg, Space.md),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 16),
                    hintText: 'Search notes',
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(width: Space.sm),
              // Icon only when the list column is narrow.
              if (MediaQuery.sizeOf(context).width < 1000)
                IconButton.filled(
                  onPressed: _newNote,
                  tooltip: 'New note',
                  icon: const Icon(Icons.add, size: 16),
                )
              else
                FilledButton.icon(
                  onPressed: _newNote,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('New'),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            children: [
              for (final c in canvases)
                ListTile(
                  dense: true,
                  leading: const Icon(
                    Icons.grid_view,
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                  title: Text(c.title),
                  subtitle: const Text(
                    'Canvas',
                    style: TextStyle(fontSize: 11, color: AppColors.textFaint),
                  ),
                  onTap: () => s.openCanvas(c.id),
                ),
              for (final n in notes) _noteTile(n),
              if (notes.isEmpty && canvases.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Space.xl),
                  child: Text(
                    touchFirst
                        ? 'No notes here yet. Tap New, or use Quick Add.'
                        : 'No notes here yet. Click New, or use Quick Add (Ctrl+N).',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textFaint,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _noteTile(Note n) {
    final selected = n.id == _selectedId;
    final excerpt = n.body.trim().replaceAll('\n', ' ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? AppColors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _selectedId = n.id),
          child: Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        n.displayTitle,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (n.favorite)
                      const Icon(
                        Icons.star,
                        size: 14,
                        color: OrganizerColors.amber,
                      ),
                    if (n.assetIds.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.attach_file,
                        size: 14,
                        color: AppColors.textFaint,
                      ),
                    ],
                  ],
                ),
                if (excerpt.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    excerpt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                      height: 1.4,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  [
                    formatShortDate(n.updatedAt),
                    if (n.folderId != null) s.workspace.folderLabel(n.folderId),
                    ...n.tags.map((t) => '#$t'),
                  ].join('  ·  '),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
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

  void _newNote() {
    final filter = _filter;
    final note = s.workspace.createNote(
      folderId: filter is FolderNotes ? filter.folderId : null,
    );
    if (filter is TagNotes) {
      s.workspace.notes.put(note.copyWith(tags: [filter.tag]));
    }
    if (filter is FavoriteNotes) {
      s.workspace.notes.put(note.copyWith(favorite: true));
    }
    setState(() => _selectedId = note.id);
  }

  // ------------------------------------------------------------- editor --

  Widget _buildEditor(BuildContext context) {
    final note = s.workspace.notes[_selectedId];
    if (note == null) {
      return const Center(
        child: Text(
          'Select a note, or create a new one.',
          style: TextStyle(color: AppColors.textFaint),
        ),
      );
    }
    return NoteEditor(
      key: ValueKey(note.id),
      state: s,
      noteId: note.id,
      onOpenNote: (id) => setState(() => _selectedId = id),
      onDeleted: () => setState(() => _selectedId = null),
    );
  }
}

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.state,
    required this.noteId,
    required this.onOpenNote,
    required this.onDeleted,
  });

  final AppState state;
  final String noteId;
  final ValueChanged<String> onOpenNote;
  final VoidCallback onDeleted;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late final Note _initial = widget.state.workspace.notes[widget.noteId]!;
  late final _title = TextEditingController(text: _initial.title);
  late final _body = TextEditingController(text: _initial.body);
  final _tag = TextEditingController();

  AppState get s => widget.state;
  Note? get note => s.workspace.notes[widget.noteId];

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _tag.dispose();
    super.dispose();
  }

  void _update(Note Function(Note) change) {
    final n = note;
    if (n != null) s.workspace.notes.put(change(n));
  }

  Future<void> _addLink() async {
    final input = await promptText(
      context,
      title: 'Attach link',
      hint: 'https://…',
      action: 'Attach',
    );
    final url = input == null ? null : extractUrl(input);
    if (url == null) return;
    s.workspace.attachToNote(widget.noteId, s.capture.link(url).id);
  }

  Future<void> _addPhotos() async {
    for (final a in await s.capture.pickImages()) {
      s.workspace.attachToNote(widget.noteId, a.id);
    }
  }

  Future<void> _addDocuments() async {
    for (final a in await s.capture.pickDocuments()) {
      s.workspace.attachToNote(widget.noteId, a.id);
    }
  }

  Future<void> _paste() async {
    final clip = await s.capture.readClipboard();
    if (clip.imageBytes != null) {
      final a = await s.capture.imageFromBytes(
        clip.imageBytes!,
        clip.imageExtension,
      );
      s.workspace.attachToNote(widget.noteId, a.id);
    } else if (clip.imageFiles.isNotEmpty) {
      for (final a in await s.capture.imagesFromFiles(clip.imageFiles)) {
        s.workspace.attachToNote(widget.noteId, a.id);
      }
    } else if (clip.url != null) {
      s.workspace.attachToNote(widget.noteId, s.capture.link(clip.url!).id);
    } else {
      s.showToast('No link or image on the clipboard.');
    }
  }

  Future<void> _placeOnCanvas() async {
    String? canvasId = s.canvas?.id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Place on canvas', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Adds a card that shows this note. It is the same note, not a '
                  'copy — edits appear in both places.',
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                ),
                const SizedBox(height: Space.md),
                DropdownButton<String>(
                  isExpanded: true,
                  value: canvasId,
                  items: [
                    for (final c in s.canvasList)
                      DropdownMenuItem(value: c.id, child: Text(c.title)),
                  ],
                  onChanged: (v) => setState(() => canvasId = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Place'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && canvasId != null) {
      await s.placeNoteOnCanvas(widget.noteId, canvasId: canvasId);
    }
  }

  void _openLinked(String title) {
    final ws = s.workspace;
    final target =
        ws.noteByTitle(title) ??
        ws.createNote(title: title, folderId: note?.folderId);
    widget.onOpenNote(target.id);
  }

  @override
  Widget build(BuildContext context) {
    final n = note;
    if (n == null) return const SizedBox.shrink();
    syncText(this, _title, n.title);
    syncText(this, _body, n.body);
    final ws = s.workspace;
    final assets = assetsFor(s, n.assetIds);
    final linked = n.linkedTitles.toSet().toList();
    final backlinks = ws.notes.all
        .where(
          (o) =>
              o.id != n.id &&
              o.linkedTitles.any(
                (t) => t.toLowerCase() == n.displayTitle.toLowerCase(),
              ),
        )
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 40),
      children: [
        Row(
          children: [
            Expanded(
              child: FolderDropdown(
                workspace: ws,
                value: n.folderId,
                onChanged: (v) => _update((x) => x.copyWith(folderId: () => v)),
              ),
            ),
            const SizedBox(width: Space.md),
            GhostIconButton(
              icon: n.favorite ? Icons.star : Icons.star_outline,
              tooltip: n.favorite
                  ? 'Remove from favorites'
                  : 'Add to favorites',
              active: n.favorite,
              onTap: () => _update((x) => x.copyWith(favorite: !x.favorite)),
            ),
            GhostIconButton(
              icon: Icons.grid_view,
              tooltip: 'Place on canvas (as a reference)',
              onTap: _placeOnCanvas,
            ),
            GhostIconButton(
              icon: Icons.history,
              tooltip: 'Version history',
              onTap: () => showNoteHistory(context, ws, n.id),
            ),
            GhostIconButton(
              icon: Icons.delete_outline,
              tooltip: 'Delete note',
              onTap: () async {
                final ok = await confirm(
                  context,
                  title: 'Delete “${n.displayTitle}”?',
                  message:
                      'Canvas cards that show this note will say it was deleted. '
                      'The note stays in your backups.',
                );
                if (ok) {
                  ws.notes.remove(n.id);
                  widget.onDeleted();
                }
              },
            ),
          ],
        ),
        TextField(
          controller: _title,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
          decoration: const InputDecoration(
            hintText: 'Untitled note',
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
          onChanged: (v) => _update((x) => x.copyWith(title: v)),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final t in n.tags)
              InputChip(
                label: Text('#$t', style: const TextStyle(fontSize: 12)),
                onDeleted: () =>
                    _update((x) => x.copyWith(tags: [...x.tags]..remove(t))),
                visualDensity: VisualDensity.compact,
              ),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _tag,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  hintText: '+ add tag',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                ),
                onSubmitted: (v) {
                  final tag = v.trim().replaceAll('#', '').replaceAll(' ', '-');
                  if (tag.isNotEmpty && !n.tags.contains(tag)) {
                    _update((x) => x.copyWith(tags: [...x.tags, tag]));
                  }
                  _tag.clear();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        TextField(
          controller: _body,
          maxLines: null,
          minLines: 12,
          style: const TextStyle(fontSize: 15, height: 1.6),
          decoration: const InputDecoration(
            hintText: 'Write here…  Link another note with [[Its title]].',
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
          onChanged: (v) => _update((x) => x.copyWith(body: v)),
        ),
        const Divider(),
        const SizedBox(height: Space.md),
        Row(
          children: [
            const Text(
              'ATTACHMENTS',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.6,
                color: AppColors.textFaint,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _paste,
              icon: const Icon(Icons.content_paste, size: 15),
              label: const Text('Paste'),
            ),
            TextButton.icon(
              onPressed: _addLink,
              icon: const Icon(Icons.add_link, size: 15),
              label: const Text('Link'),
            ),
            TextButton.icon(
              onPressed: _addPhotos,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 15),
              label: const Text('Photos'),
            ),
            TextButton.icon(
              onPressed: _addDocuments,
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 15),
              label: const Text('PDF'),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final a in assets)
              AssetChip(
                workspace: ws,
                asset: a,
                onRemove: () => _update(
                  (x) => x.copyWith(assetIds: [...x.assetIds]..remove(a.id)),
                ),
              ),
          ],
        ),
        if (linked.isNotEmpty || backlinks.isNotEmpty) ...[
          const SizedBox(height: Space.xl),
          const Text(
            'LINKED NOTES',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.6,
              color: AppColors.textFaint,
            ),
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in linked)
                ActionChip(
                  avatar: Icon(
                    ws.noteByTitle(t) == null ? Icons.add : Icons.north_east,
                    size: 14,
                  ),
                  label: Text(t, style: const TextStyle(fontSize: 12)),
                  tooltip: ws.noteByTitle(t) == null
                      ? 'Create this note'
                      : 'Open',
                  onPressed: () => _openLinked(t),
                ),
              for (final b in backlinks)
                ActionChip(
                  avatar: const Icon(Icons.subdirectory_arrow_left, size: 14),
                  label: Text(
                    b.displayTitle,
                    style: const TextStyle(fontSize: 12),
                  ),
                  tooltip: 'Links here',
                  onPressed: () => widget.onOpenNote(b.id),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Earlier versions of a note, newest first; restoring one keeps the
/// current text as a version too, so it can be undone.
Future<void> showNoteHistory(
  BuildContext context,
  Workspace ws,
  String noteId,
) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final versions = ws.versionsOf(noteId);
      return AlertDialog(
        title: const Text('Version history', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 460,
          child: versions.isEmpty
              ? const Text(
                  'No earlier versions yet. A version is kept when you change '
                  'this note (at most one per 10 minutes of editing).',
                  style: TextStyle(color: AppColors.textMuted),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final v in versions)
                      ListTile(
                        dense: true,
                        title: Text(
                          v.title.isEmpty ? 'Untitled note' : v.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${formatShortDate(v.savedAt)} '
                          '${v.savedAt.hour.toString().padLeft(2, '0')}:'
                          '${v.savedAt.minute.toString().padLeft(2, '0')}'
                          ' · ${v.body.split('\n').first}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: TextButton(
                          onPressed: () {
                            ws.restoreNoteVersion(v.id);
                            Navigator.pop(context);
                          },
                          child: const Text('Restore'),
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
