import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../data/models/library_models.dart';
import '../../data/workspace.dart';
import '../../platform/input_hints.dart';
import '../../widgets/common.dart';
import '../ai/ai_service.dart';
import '../ai/ai_session.dart';
import '../ai/similarity.dart';
import '../import/import_dialog.dart';
import 'conversion.dart';
import '../smartlinks/smart_links.dart';
import '../smartlinks/smart_links_ui.dart';
import 'note_connections.dart';
import 'note_diff.dart';
import 'note_page.dart';
import '../transfer/transfer.dart';
import '../interaction/item_actions.dart';

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

/// Notes that belong to no project or study subject (smart view).
class UnlinkedNotes extends NoteFilter {
  const UnlinkedNotes();
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
      // Notes open as their own page.
      if (note != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _open(requested);
        });
      }
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
            // The library; a note opens as its own page ([NotePage]).
            Expanded(child: _buildList(context)),
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
    UnlinkedNotes() => n.projectIds.isEmpty,
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
        (UnlinkedNotes(), UnlinkedNotes()) => true,
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
        // Dropping a note on "All notes" takes it out of its folder.
        TransferTarget(
          state: s,
          place: const NoteFolderPlace(null),
          child: item(
            'All notes',
            Icons.notes,
            const AllNotes(),
            trailing: _count(ws.notes.length),
          ),
        ),
        item('Favorites', Icons.star_outline, const FavoriteNotes()),
        item(
          'Not in a project',
          Icons.link_off,
          const UnlinkedNotes(),
          trailing: _count(
            ws.notes.all.where((n) => n.projectIds.isEmpty).length,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 18, 4, 6),
          child: Row(
            children: [
              Expanded(
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
            // Drop a note here to move it into this folder.
            child: TransferTarget(
              state: s,
              place: NoteFolderPlace(folder.id),
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
          ),
        if (ws.folders.length == 0)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              'Folders are shared with Canvas.',
              style: TextStyle(fontSize: 12, color: AppColors.textFaint),
            ),
          ),
        if (tags.isNotEmpty) ...[
          Padding(
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

  Widget _count(int n) =>
      Text('$n', style: TextStyle(fontSize: 11, color: AppColors.textFaint));

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
              IconButton(
                onPressed: _importPdf,
                tooltip: 'Import a PDF as a note',
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
              ),
              PopupMenuButton<String>(
                key: const ValueKey('notes-more'),
                tooltip: 'More: import notes, find similar notes',
                icon: const Icon(Icons.more_horiz, size: 18),
                onSelected: (v) => v == 'import'
                    ? showImportDialog(context, s)
                    : showSimilarNotes(context, s),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'import',
                    child: Text(
                      'Import notes (Obsidian, Notion, Apple Notes)…',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'similar',
                    child: Text('Find similar notes…'),
                  ),
                ],
              ),
              IconButton(
                key: const ValueKey('notes-recently-deleted'),
                onPressed: () => showRecentlyDeleted(context, s),
                tooltip: 'Recently deleted',
                icon: const Icon(Icons.restore_from_trash_outlined, size: 18),
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
          // Dropping on the list (not on a note) makes a new note.
          child: TransferTarget(
            state: s,
            place: const NewNotePlace(),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              children: [
                for (final c in canvases)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.grid_view,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                    title: Text(c.title),
                    subtitle: Text(
                      'Canvas',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textFaint,
                      ),
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
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _noteTile(Note n) => TransferTarget(
    state: s,
    place: NotePlace(n.id),
    child: TransferSource(
      transfer: () => NoteTransfer(n.id, n.displayTitle),
      touch: true,
      child: ItemActionRegion(
        state: s,
        item: NoteActionItem(n),
        child: _noteTileBody(n),
      ),
    ),
  );

  Widget _noteTileBody(Note n) {
    final selected = n.id == _selectedId;
    final excerpt = n.body.trim().replaceAll('\n', ' ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? AppColors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _open(n.id),
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
                      Icon(Icons.star, size: 14, color: AppColors.warm),
                    if (n.assetIds.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Icon(
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
                    style: TextStyle(
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
                  style: TextStyle(fontSize: 11, color: AppColors.textFaint),
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
    _open(note.id);
  }

  /// Opens a note as its own page (Back returns to the library).
  void _open(String id) {
    setState(() => _selectedId = id);
    unawaited(openNotePage(context, s, id));
  }

  Future<void> _importPdf() async {
    final filter = _filter;
    final id = await importPdfAsNote(
      s,
      folderId: filter is FolderNotes ? filter.folderId : null,
    );
    if (id != null && mounted) _open(id);
  }
}

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.state,
    required this.noteId,
    required this.onOpenNote,
    required this.onDeleted,
    this.pageCount = 0,
    this.pageBuilder,
    this.scrollController,
  });

  final AppState state;
  final String noteId;
  final ValueChanged<String> onOpenNote;
  final VoidCallback onDeleted;

  /// Notebook pages shown after the note's details (full-page editor).
  final int pageCount;
  final IndexedWidgetBuilder? pageBuilder;
  final ScrollController? scrollController;

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

  /// Text selected in the body (for the conversion bar).
  String _selected = '';

  // Text zoom of this note (its title and body only; the app, the toolbar
  // and the sidebar keep their size). Remembered per note, like the zoom
  // of its handwritten pages. Done with a text scaler, not a transform:
  // the text is laid out at the new size, so the caret, selection and
  // scrolling stay exactly on the visible text.
  static const minTextZoom = 0.6, maxTextZoom = 2.5;
  String get _zoomKey => 'noteTextZoom.${widget.noteId}';
  late double _textZoom = (s.settings.get<num>(_zoomKey)?.toDouble() ?? 1.0)
      .clamp(minTextZoom, maxTextZoom);

  @visibleForTesting
  void setTextZoomForTest(double z) => _setTextZoom(z);

  void _setTextZoom(double z) {
    final v = (z.clamp(minTextZoom, maxTextZoom) * 100).round() / 100;
    if (v == _textZoom) return;
    setState(() => _textZoom = v);
    unawaited(s.settings.set(_zoomKey, v));
  }

  /// [child] with this note's text zoom on top of the system text size.
  Widget _zoomed(Widget child) => Builder(
    builder: (context) {
      final base = MediaQuery.textScalerOf(context);
      return MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(base.scale(1) * _textZoom)),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(
              LogicalKeyboardKey.equal,
              control: true,
            ): () =>
                _setTextZoom(_textZoom * 1.15),
            const SingleActivator(LogicalKeyboardKey.add, control: true): () =>
                _setTextZoom(_textZoom * 1.15),
            const SingleActivator(
              LogicalKeyboardKey.minus,
              control: true,
            ): () =>
                _setTextZoom(_textZoom / 1.15),
            const SingleActivator(
              LogicalKeyboardKey.digit0,
              control: true,
            ): () =>
                _setTextZoom(1),
          },
          child: child,
        ),
      );
    },
  );

  @override
  void initState() {
    super.initState();
    _body.addListener(_onSelection);
    s.workspace.notes.addListener(_onNoteChanged);
    s.activeNoteId.value = widget.noteId;
  }

  /// Shows changes made elsewhere (a move of selected text, Undo of a drop,
  /// sync) in the open editor; otherwise the next keystroke would write the
  /// old text back. Changes typed here are already equal and untouched.
  void _onNoteChanged() {
    final n = note;
    if (n == null || !mounted) return;
    if (n.body != _body.text) {
      final sel = _body.selection;
      _body.value = TextEditingValue(
        text: n.body,
        selection: sel.isValid && sel.end <= n.body.length
            ? TextSelection.collapsed(offset: sel.start)
            : TextSelection.collapsed(offset: n.body.length),
      );
    }
    if (n.title != _title.text) {
      _title.value = TextEditingValue(
        text: n.title,
        selection: TextSelection.collapsed(offset: n.title.length),
      );
    }
  }

  void _onSelection() {
    final sel = _body.selection;
    final text = sel.isValid && !sel.isCollapsed
        ? sel.textInside(_body.text)
        : '';
    if (text.trim() != _selected.trim()) setState(() => _selected = text);
  }

  bool get _conversionOpen => s.settings.get<bool>('conversionBarOpen') ?? true;

  @override
  void dispose() {
    if (s.activeNoteId.value == widget.noteId) s.activeNoteId.value = null;
    _body.removeListener(_onSelection);
    s.workspace.notes.removeListener(_onNoteChanged);
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
                Text(
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

    final header = <Widget>[
      LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: box.maxWidth < 520 ? 520 : box.maxWidth,
            child: Row(
              children: [
                Expanded(
                  child: FolderDropdown(
                    workspace: ws,
                    value: n.folderId,
                    onChanged: (v) =>
                        _update((x) => x.copyWith(folderId: () => v)),
                  ),
                ),
                const SizedBox(width: Space.md),
                GhostIconButton(
                  icon: n.favorite ? Icons.star : Icons.star_outline,
                  tooltip: n.favorite
                      ? 'Remove from favorites'
                      : 'Add to favorites',
                  active: n.favorite,
                  onTap: () =>
                      _update((x) => x.copyWith(favorite: !x.favorite)),
                ),
                GhostIconButton(
                  icon: Icons.grid_view,
                  tooltip: 'Place on canvas (as a reference)',
                  onTap: _placeOnCanvas,
                ),
                GhostIconButton(
                  key: const ValueKey('insert-workspace-link'),
                  icon: Icons.add_link,
                  tooltip:
                      'Link to a note, mindmap, calendar item or Archive item',
                  onTap: () async {
                    await insertLinkInto(
                      context,
                      s,
                      _body,
                      owner: WorkspaceRef(RefKind.note, n.id),
                    );
                    _update((x) => x.copyWith(body: _body.text));
                  },
                ),
                if (s.ai.enabled)
                  GhostIconButton(
                    key: const ValueKey('note-ask-ai'),
                    icon: Icons.auto_awesome_outlined,
                    tooltip:
                        'Ask AI about this note (you review it before sending)',
                    onTap: () => s.sendToAi(
                      AiContext(
                        title: n.displayTitle,
                        source: AiSource.notes,
                        text: '${n.displayTitle}\n${n.body}',
                        noteId: n.id,
                      ),
                    ),
                  ),
                GhostIconButton(
                  key: const ValueKey('note-text-zoom-out'),
                  icon: Icons.text_decrease,
                  tooltip: 'Smaller text (Ctrl −)',
                  onTap: _textZoom > minTextZoom
                      ? () => _setTextZoom(_textZoom / 1.15)
                      : null,
                ),
                Tooltip(
                  message: 'Text size of this note; tap for 100% (Ctrl 0)',
                  child: InkWell(
                    onTap: () => _setTextZoom(1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        'Text ${(_textZoom * 100).round()}%',
                        key: const ValueKey('note-text-zoom-value'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
                GhostIconButton(
                  key: const ValueKey('note-text-zoom-in'),
                  icon: Icons.text_increase,
                  tooltip: 'Larger text (Ctrl +)',
                  onTap: _textZoom < maxTextZoom
                      ? () => _setTextZoom(_textZoom * 1.15)
                      : null,
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
                          'You can bring it back, with its handwriting, from '
                          '“Recently deleted” in Notes.',
                    );
                    if (ok) {
                      // All of it is kept: a version for Recently deleted, the
                      // handwriting in the trash folder.
                      unawaited(s.deleteNote(n.id));
                      widget.onDeleted();
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      _zoomed(
        TextField(
          key: const ValueKey('note-title'),
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
      _zoomed(
        TextField(
          key: const ValueKey('note-body'),
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
      ),
      if (_selected.trim().isNotEmpty)
        Row(
          children: [
            TransferSource(
              key: const ValueKey('text-transfer-grip'),
              transfer: () => TextTransfer(
                _selected,
                sourceNoteId: widget.noteId,
                sourceNoteTitle: s.workspace.notes[widget.noteId]?.displayTitle,
                start: _body.selection.start,
                end: _body.selection.end,
              ),
              child: const Tooltip(
                message:
                    'Drag the selected text to a mindmap, day, task '
                    'list or another note',
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.drag_indicator, size: 18),
                ),
              ),
            ),
            Expanded(
              child: ConversionBar(
                open: _conversionOpen,
                onToggle: () => setState(
                  () => s.settings.set('conversionBarOpen', !_conversionOpen),
                ),
                onConvert: (target) => convertSelection(
                  context,
                  s,
                  widget.noteId,
                  _selected,
                  target,
                ),
                onAskAi: s.ai.enabled
                    ? () => s.sendToAi(
                        AiContext(
                          title: 'Part of “${n.displayTitle}”',
                          source: AiSource.notes,
                          text: _selected,
                          noteId: n.id,
                        ),
                      )
                    : null,
              ),
            ),
          ],
        ),
      const Divider(),
      const SizedBox(height: Space.md),
      Wrap(
        spacing: 4,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'ATTACHMENTS',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.6,
              color: AppColors.textFaint,
            ),
          ),
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
            // Drag to another note, a day or a mindmap: attach there too,
            // or move it off this note.
            TransferSource(
              key: ValueKey('note-asset-drag-${a.id}'),
              transfer: () =>
                  AssetsTransfer([a.id], sourceNoteId: widget.noteId),
              touch: touchFirst,
              feedback: Text(a.label),
              child: AssetChip(
                workspace: ws,
                asset: a,
                onRemove: () => _update(
                  (x) => x.copyWith(assetIds: [...x.assetIds]..remove(a.id)),
                ),
              ),
            ),
        ],
      ),
      if (ws.mentionedNotes(n) case final mentions when mentions.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Space.md),
          child: Wrap(
            key: const ValueKey('mention-suggestions'),
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Mentions other notes:',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint),
              ),
              for (final m in mentions.take(6))
                ActionChip(
                  avatar: const Icon(Icons.add_link, size: 14),
                  label: Text(
                    'Link “${m.displayTitle}”',
                    style: const TextStyle(fontSize: 12),
                  ),
                  tooltip: 'Turn the mention into a [[link]]',
                  onPressed: () => ws.linkMention(n.id, m.displayTitle),
                ),
            ],
          ),
        ),
      const SizedBox(height: Space.xl),
      NoteConnections(state: s, note: n, onOpenNote: widget.onOpenNote),
      const SizedBox(height: Space.xl),
      SmartLinksPanel(
        state: s,
        owner: WorkspaceRef(RefKind.note, n.id),
        text: n.body,
        onRemoveLink: (target) => _update(
          (x) => x.copyWith(body: removeLinkTo(x.body, target)),
        ),
      ),
      if (linked.isNotEmpty || backlinks.isNotEmpty) ...[
        const SizedBox(height: Space.xl),
        Text(
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
    ];
    // Notebook pages (full-page note): built only when scrolled into view.
    final pages = widget.pageBuilder == null ? 0 : widget.pageCount;
    return TransferTarget(
      state: s,
      place: NotePlace(widget.noteId),
      child: ListView.builder(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(40, 28, 40, 40),
        itemCount: header.length + pages,
        itemBuilder: (context, i) => i < header.length
            ? header[i]
            : widget.pageBuilder!(context, i - header.length),
      ),
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
              ? Text(
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
                        trailing: Wrap(
                          children: [
                            if (ws.notes[noteId] case final current?)
                              TextButton(
                                onPressed: () =>
                                    showVersionComparison(context, v, current),
                                child: const Text('Compare'),
                              ),
                            TextButton(
                              onPressed: () {
                                ws.restoreNoteVersion(v.id);
                                Navigator.pop(context);
                              },
                              child: const Text('Restore'),
                            ),
                          ],
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

/// Deleted notes that can be brought back (on this device), each with its
/// text, folder, tags, attachments and — from the trash folder — its
/// handwriting and PDF pages.
Future<void> showRecentlyDeleted(BuildContext context, AppState s) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final deleted = s.workspace.deletedNotes();
      return AlertDialog(
        title: const Text('Recently deleted', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 460,
          child: deleted.isEmpty
              ? Text(
                  'No deleted notes on this device.',
                  style: TextStyle(color: AppColors.textMuted),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final v in deleted)
                      ListTile(
                        key: ValueKey('deleted-${v.noteId}'),
                        dense: true,
                        title: Text(
                          v.title.isEmpty ? 'Untitled note' : v.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${v.deleted ? 'Deleted' : 'Last kept'} '
                          '${formatShortDate(v.savedAt)}'
                          '${v.body.isEmpty ? '' : ' · ${v.body.split('\n').first}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: TextButton(
                          onPressed: () async {
                            Navigator.pop(context);
                            final note = await s.restoreDeletedNote(v.id);
                            if (note != null) {
                              s.showToast('Restored “${note.displayTitle}”');
                            }
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

/// Pairs of notes with nearly the same wording (possible duplicates). They
/// are only listed; nothing is merged or deleted.
Future<void> showSimilarNotes(BuildContext context, AppState s) {
  final pairs = similarNotes(s.workspace.notes.all);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Similar notes', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 480,
        child: pairs.isEmpty
            ? Text(
                'No notes with nearly the same wording.',
                style: TextStyle(color: AppColors.textMuted),
              )
            : ListView(
                key: const ValueKey('similar-notes'),
                shrinkWrap: true,
                children: [
                  for (final (a, b, score) in pairs.take(30))
                    ListTile(
                      dense: true,
                      title: Text('${a.displayTitle}  ↔  ${b.displayTitle}'),
                      subtitle: Text(
                        '${(score * 100).round()}% the same words',
                      ),
                      trailing: Wrap(
                        children: [
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              s.openNote(a.id);
                            },
                            child: const Text('Open first'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              s.openNote(b.id);
                            },
                            child: const Text('Open second'),
                          ),
                        ],
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
    ),
  );
}
