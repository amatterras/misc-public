import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/object_library_models.dart';
import '../../data/storage/attachment_image.dart';
import '../../data/storage/attachment_store.dart';
import '../../data/models/library_models.dart'
    show Asset, AssetKind, extractUrl;
import '../../data/repositories/library_repository.dart';
import '../../data/models/tag_models.dart';
import '../../new_ui/archive_model.dart' show archiveImageFileOf;
import '../../platform/platform.dart' as native;
import '../../widgets/common.dart';
import '../capture/sorting.dart';
import '../links/link_tags.dart';
import '../tags/tag_ui.dart';
import '../transfer/transfer.dart';
import 'duplicate_prompt.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.state,
    this.initialObjectId,
    this.closeAfterInitialObject = false,
  });
  final AppState state;
  final String? initialObjectId;

  /// Pop this page once the first object's dialog is closed (the New
  /// Archive opens an item through this page's own detail dialog).
  final bool closeAfterInitialObject;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _query = TextEditingController();
  String? _space;
  final _categories = <String>{};
  final _tags = <String>{};
  String _sort = 'newest';
  AppState get s => widget.state;
  LibraryRepository get repo => s.library;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final item = widget.initialObjectId == null
          ? null
          : s.workspace.libraryObjects[widget.initialObjectId!];
      if (item != null && mounted) {
        await _open(item);
        if (widget.closeAfterInitialObject && mounted) {
          Navigator.of(context).maybePop();
        }
      }
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _saveUrl() async {
    final raw = await promptText(
      context,
      title: 'Save a website',
      hint: 'https://example.com',
      action: 'Save',
    );
    if (raw == null) return;
    final url = extractUrl(raw);
    if (url == null) {
      s.showToast('Enter a valid http or https address.');
      return;
    }
    final dup = repo.findDuplicate(sourceUrl: url);
    if (dup != null) {
      if (!mounted) return;
      if (!await _askDuplicate(dup)) return;
    }
    final result = await repo.save(
      type: LibraryObjectType.website,
      sourceUrl: url,
      title: Uri.parse(url).host,
      spaceId: _space,
      allowDuplicate: dup != null,
    );
    if (mounted) setState(() {});
    s.showToast(
      result.sourceUrl == null ? 'Saved.' : 'Saved locally. Open the source to view it; page extraction is not enabled.',
    );
  }

  Future<void> _newNote() async {
    final title = await promptText(
      context,
      title: 'New library note',
      hint: 'Title',
      action: 'Continue',
    );
    if (!mounted || title == null) return;
    final body = await promptText(
      context,
      title: 'Note content',
      hint: 'Write a note…',
      action: 'Save',
    );
    if (body == null) return;
    final dup = repo.findDuplicate(content: body);
    if (dup != null) {
      if (!mounted) return;
      if (!await _askDuplicate(dup)) return;
    }
    await repo.save(
      type: LibraryObjectType.note,
      title: title,
      content: body,
      spaceId: _space,
      allowDuplicate: dup != null,
    );
    if (mounted) setState(() {});
  }

  Future<void> _importFiles({required bool images}) async {
    final assets = images
        ? await s.capture.pickImages()
        : await s.capture.pickDocuments();
    for (final asset in assets) {
      // Hashes the file (off the UI thread when big; a stored hash is
      // reused) and asks first when the same file is already saved.
      final dup = await s.capture.archiveDuplicateOfAsset(asset);
      if (dup != null) {
        if (!mounted) return;
        if (!await _askDuplicate(dup)) continue;
      }
      await repo.save(
        type: asset.kind == AssetKind.image
            ? LibraryObjectType.image
            : LibraryObjectType.document,
        title: asset.label,
        attachmentIds: [asset.id],
        metadata: {'legacyAssetId': asset.id},
        spaceId: _space,
        allowDuplicate: dup != null,
      );
    }
    if (mounted) setState(() {});
  }

  /// The "Already in Archive" popup. True: save anyway. "Open existing"
  /// opens it right here.
  Future<bool> _askDuplicate(ArchiveDuplicate dup) async {
    final choice = await showArchiveDuplicatePrompt(context, s, dup);
    if (choice == DuplicateChoice.openExisting && mounted) {
      await _open(dup.existing);
    }
    return choice == DuplicateChoice.saveAnyway;
  }

  Future<void> _newSpace({required bool smart}) async {
    final name = await promptText(
      context,
      title: smart ? 'New Smart Space' : 'New Space',
      hint: 'Name',
      action: 'Continue',
    );
    if (!mounted || name == null) return;
    final query = smart
        ? await promptText(
                context,
                title: 'Smart Space search',
                hint: 'type:image object:chair',
                action: 'Save',
              ) ??
              ''
        : '';
    final parsed = LibraryQuery.parse(query);
    if (smart && parsed.error != null) {
      s.showToast(parsed.error!);
      return;
    }
    final space = await repo.createSpace(
      name,
      kind: smart ? LibrarySpaceKind.smart : LibrarySpaceKind.regular,
      query: query,
    );
    if (mounted) setState(() => _space = space.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        s.workspace.libraryObjects,
        s.workspace.librarySpaces,
        s.workspace.libraryIndex,
        s.workspace.libraryRelations,
        s.workspace.libraryJobs,
        s.workspace.customTags,
      ]),
      builder: (context, _) {
        final result = repo.search(_query.text);
        final visible =
            repo
                .withLabels(
                  _space == null ? result.items : repo.inSpace(_space!),
                  categories: _categories,
                  tagIds: _tags,
                )
                .toList()
              ..sort(
                (a, b) => switch (_sort) {
                  'oldest' => a.createdAt.compareTo(b.createdAt),
                  'title' => a.title.toLowerCase().compareTo(
                    b.title.toLowerCase(),
                  ),
                  _ => (b.lastSavedAt ?? b.createdAt).compareTo(
                    a.lastSavedAt ?? a.createdAt,
                  ),
                },
              );
        final spaces = s.workspace.librarySpaces.all.toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
        return ColoredBox(
          color: AppColors.background,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Library',
                        style: TextStyle(
                          color: AppColors.text,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Add to library',
                      onSelected: (v) {
                        switch (v) {
                          case 'url':
                            _saveUrl();
                          case 'note':
                            _newNote();
                          case 'image':
                            _importFiles(images: true);
                          case 'document':
                            _importFiles(images: false);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'url',
                          child: Text('Save website'),
                        ),
                        PopupMenuItem(value: 'note', child: Text('New note')),
                        PopupMenuItem(
                          value: 'image',
                          child: Text('Import images'),
                        ),
                        PopupMenuItem(
                          value: 'document',
                          child: Text('Import documents'),
                        ),
                      ],
                      child: ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('Add item'),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(color: AppColors.text),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText:
                        'Search your library · type:image object:chair tag:…',
                    filled: true,
                    fillColor: AppColors.card,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 58,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  children: [
                    _spaceChip('All items', null),
                    for (final sp in spaces) _spaceButton(sp),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: PopupMenuButton<bool>(
                        onSelected: (smart) => _newSpace(smart: smart),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: false,
                            child: Text('Regular Space'),
                          ),
                          PopupMenuItem(
                            value: true,
                            child: Text('Smart Space'),
                          ),
                        ],
                        child: ActionChip(
                          avatar: const Icon(Icons.add, size: 16),
                          label: const Text('New Space'),
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Sort items',
                      onSelected: (value) => setState(() => _sort = value),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'newest',
                          child: Text('Recently saved'),
                        ),
                        PopupMenuItem(
                          value: 'oldest',
                          child: Text('Oldest first'),
                        ),
                        PopupMenuItem(value: 'title', child: Text('Title')),
                      ],
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.sort),
                      ),
                    ),
                  ],
                ),
              ),
              _labelFilters(),
              if (result.error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    result.error!,
                    style: TextStyle(color: AppColors.danger),
                  ),
                ),
              if (_space == null &&
                  _query.text.isNotEmpty &&
                  visible.isEmpty &&
                  result.error == null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No matching items. Semantic search and visual recognition are not configured.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          _categories.isNotEmpty || _tags.isNotEmpty
                              ? 'No items have these labels.'
                              : 'Your library is ready for its first item.',
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, c) {
                          final cols = (c.maxWidth / 240).floor().clamp(1, 6);
                          return GridView.builder(
                            padding: const EdgeInsets.all(20),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: cols,
                                  crossAxisSpacing: 14,
                                  mainAxisSpacing: 14,
                                  childAspectRatio: .88,
                                ),
                            itemCount: visible.length,
                            itemBuilder: (context, i) => _ObjectCard(
                              state: s,
                              object: visible[i],
                              onTap: () => _open(visible[i]),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Filter by the five canonical categories and the custom tags (every
  /// chosen label must be on the item). Only library objects are filtered.
  Widget _labelFilters() => SizedBox(
    height: 48,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        for (final c in LinkTag.values)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilterChip(
              key: ValueKey('library-filter-${c.id}'),
              avatar: CircleAvatar(backgroundColor: c.color, radius: 6),
              label: Text(c.label),
              selected: _categories.contains(c.id),
              onSelected: (on) => setState(
                () => on ? _categories.add(c.id) : _categories.remove(c.id),
              ),
            ),
          ),
        for (final tag in s.workspace.tagsByName)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilterChip(
              key: ValueKey('library-filter-tag-${tag.id}'),
              avatar: CircleAvatar(
                backgroundColor: Color(tag.color),
                radius: 6,
              ),
              label: Text(tag.name),
              selected: _tags.contains(tag.id),
              onSelected: (on) =>
                  setState(() => on ? _tags.add(tag.id) : _tags.remove(tag.id)),
            ),
          ),
        if (_categories.isNotEmpty || _tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ActionChip(
              key: const ValueKey('library-filter-clear'),
              label: const Text('Clear'),
              onPressed: () => setState(() {
                _categories.clear();
                _tags.clear();
              }),
            ),
          ),
      ],
    ),
  );

  Widget _spaceChip(String label, String? id) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: ChoiceChip(
      label: Text(label),
      selected: _space == id,
      onSelected: (_) => setState(() => _space = id),
    ),
  );

  Widget _spaceButton(LibrarySpace space) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: PopupMenuButton<String>(
      onSelected: (action) {
        if (action == 'edit') _editSpace(space);
        if (action == 'delete') _deleteSpace(space);
      },
      itemBuilder: (_) => [
        if (space.kind == LibrarySpaceKind.smart)
          const PopupMenuItem(
            value: 'edit',
            child: Text('Edit search conditions'),
          ),
        if (space.kind == LibrarySpaceKind.regular)
          const PopupMenuItem(value: 'edit', child: Text('Rename Space')),
        const PopupMenuItem(value: 'delete', child: Text('Delete Space')),
      ],
      child: ChoiceChip(
        label: Text(
          '${space.kind == LibrarySpaceKind.smart ? '✦' : '◈'} ${space.name}',
        ),
        selected: _space == space.id,
        onSelected: (_) => setState(() => _space = space.id),
      ),
    ),
  );

  Future<void> _editSpace(LibrarySpace space) async {
    if (space.kind == LibrarySpaceKind.smart) {
      final query = await promptText(
        context,
        title: 'Edit Smart Space conditions',
        initial: space.query,
        hint: 'type:image object:chair',
        action: 'Save',
      );
      if (query == null) return;
      final parsed = LibraryQuery.parse(query);
      if (parsed.error != null) {
        s.showToast(parsed.error!);
        return;
      }
      s.workspace.librarySpaces.put(space.copyWith(query: query));
      await s.workspace.librarySpaces.flush();
    } else {
      final name = await promptText(
        context,
        title: 'Rename Space',
        initial: space.name,
        action: 'Save',
      );
      if (name == null || name.trim().isEmpty) return;
      s.workspace.librarySpaces.put(space.copyWith(name: name.trim()));
      await s.workspace.librarySpaces.flush();
    }
  }

  Future<void> _deleteSpace(LibrarySpace space) async {
    final ok = await confirm(
      context,
      title: 'Delete "${space.name}"?',
      message: 'The objects themselves will remain in your library.',
      action: 'Delete',
    );
    if (!ok) return;
    for (final relation
        in s.workspace.libraryRelations.all
            .where((r) => r.kind == 'space' && r.targetId == space.id)
            .toList()) {
      s.workspace.libraryRelations.remove(relation.id);
    }
    s.workspace.librarySpaces.remove(space.id);
    await s.workspace.libraryRelations.flush();
    await s.workspace.librarySpaces.flush();
    if (_space == space.id) setState(() => _space = null);
  }

  Future<void> _open(LibraryObject object) async {
    final controller = TextEditingController(text: object.content ?? '');
    final titleController = TextEditingController(text: object.title);
    final noteController = TextEditingController(
      text: s.workspace.libraryRelations.all
          .where((r) => r.objectId == object.id && r.kind == 'note')
          .map((r) => r.value['text'])
          .whereType<String>()
          .join('\n'),
    );
    final attachedAsset = object.attachmentIds
        .map((id) => s.workspace.assets[id])
        .whereType<Asset>()
        .firstOrNull;
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(object.title.isEmpty ? 'Untitled' : object.title),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${object.type.name.toUpperCase()}  ·  ${object.mainEntity?.type.name ?? 'No main entity'}',
                  style: TextStyle(color: AppColors.textMuted),
                ),
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                if (object.description != null)
                  Text(
                    object.description!,
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                if (object.sourceUrl != null)
                  SelectableText(
                    object.sourceUrl!,
                    style: TextStyle(color: AppColors.accent),
                  ),
                if (attachedAsset?.kind == AssetKind.image &&
                    attachedAsset?.file != null) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    key: const ValueKey('archive-image-preview'),
                    onTap: () =>
                        showImageViewer(ctx, s.workspace, attachedAsset),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: Image(
                          image: AttachmentImageProvider(
                            s.workspace.attachments,
                            attachedAsset!.file!,
                          ),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              'This image is not on this device yet. It '
                              'arrives with the next sync.',
                              style: TextStyle(color: AppColors.textMuted),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Wrap(
                    children: [
                      TextButton.icon(
                        key: const ValueKey('archive-image-open'),
                        onPressed: () =>
                            showImageViewer(ctx, s.workspace, attachedAsset),
                        icon: const Icon(Icons.zoom_out_map, size: 16),
                        label: const Text('View'),
                      ),
                      if (s.ios != null)
                        TextButton.icon(
                          key: const ValueKey('archive-image-share'),
                          onPressed: () => _shareAsset(attachedAsset),
                          icon: const Icon(Icons.ios_share, size: 16),
                          label: const Text('Share'),
                        ),
                      if (native.hasSaveDialog)
                        TextButton.icon(
                          key: const ValueKey('archive-image-save'),
                          onPressed: () => _saveAssetCopy(attachedAsset),
                          icon: const Icon(Icons.save_alt, size: 16),
                          label: const Text('Save a copy'),
                        ),
                      if (native.canCopyImages)
                        TextButton.icon(
                          key: const ValueKey('archive-image-copy'),
                          onPressed: () => _copyImage(attachedAsset),
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy image'),
                        ),
                    ],
                  ),
                ],
                if (attachedAsset?.kind == AssetKind.document &&
                    attachedAsset?.file != null)
                  Wrap(
                    children: [
                      TextButton.icon(
                        key: const ValueKey('archive-open-document'),
                        // PDFs open in the in-app page viewer where this
                        // device renders them; otherwise the default app.
                        onPressed: () =>
                            openDocumentAsset(ctx, s.workspace, attachedAsset!),
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('Open document'),
                      ),
                      if (s.ios != null)
                        TextButton.icon(
                          key: const ValueKey('archive-document-share'),
                          onPressed: () => _shareAsset(attachedAsset!),
                          icon: const Icon(Icons.ios_share, size: 16),
                          label: const Text('Share'),
                        ),
                      if (native.hasSaveDialog)
                        TextButton.icon(
                          key: const ValueKey('archive-document-save'),
                          onPressed: () => _saveAssetCopy(attachedAsset!),
                          icon: const Icon(Icons.save_alt, size: 16),
                          label: const Text('Save a copy'),
                        ),
                    ],
                  ),
                if (object.sourceUrl != null)
                  Wrap(
                    children: [
                      TextButton.icon(
                        key: const ValueKey('archive-open-link'),
                        // Always the saved address itself, never a
                        // canonicalized or shortened form of it.
                        onPressed: () => s.openUrl(object.sourceUrl!),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open link'),
                      ),
                      TextButton.icon(
                        key: const ValueKey('archive-copy-link'),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: object.sourceUrl!),
                          );
                          s.showToast('Link copied.');
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy link'),
                      ),
                    ],
                  ),
                if (_canSend(object)) ...[
                  const Divider(height: 20),
                  Wrap(
                    children: [
                      TextButton.icon(
                        key: const ValueKey('archive-copy-to'),
                        onPressed: () => _sendTo(ctx, object, move: false),
                        icon: const Icon(Icons.library_add_outlined, size: 16),
                        label: const Text('Copy to…'),
                      ),
                      TextButton.icon(
                        key: const ValueKey('archive-move-to'),
                        onPressed: () => _sendTo(ctx, object, move: true),
                        icon: const Icon(
                          Icons.drive_file_move_outlined,
                          size: 16,
                        ),
                        label: const Text('Move to…'),
                      ),
                      TextButton.icon(
                        key: const ValueKey('archive-make-note'),
                        onPressed: () => _makeNote(ctx, object),
                        icon: const Icon(Icons.note_add_outlined, size: 16),
                        label: const Text('New note'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                if (object.summary != null)
                  Text(
                    object.summary!,
                    style: TextStyle(color: AppColors.text),
                  ),
                if (object.type == LibraryObjectType.note)
                  TextField(
                    controller: controller,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: 'Saved content',
                    ),
                  )
                else if (object.content?.isNotEmpty == true)
                  SelectableText(
                    object.content!,
                    style: TextStyle(color: AppColors.text, height: 1.55),
                  ),
                TextField(
                  controller: noteController,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Your notes'),
                ),
                StatefulBuilder(
                  builder: (ctx, setLabels) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      Text(
                        'Category',
                        style: TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final c in LinkTag.values)
                            FilterChip(
                              key: ValueKey('library-category-${c.id}'),
                              avatar: CircleAvatar(
                                backgroundColor: c.color,
                                radius: 6,
                              ),
                              label: Text(c.label),
                              selected: repo
                                  .categoriesOf(object.id)
                                  .contains(c.id),
                              onSelected: (on) async {
                                await repo.setCategory(object.id, c.id, on);
                                setLabels(() {});
                                setState(() {});
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tags',
                        style: TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final id in repo.tagIdsOf(object.id))
                            if (s.workspace.customTags[id] case final tag?)
                              Chip(
                                avatar: CircleAvatar(
                                  backgroundColor: Color(tag.color),
                                  radius: 6,
                                ),
                                label: Text(
                                  tag.name,
                                  style: TextStyle(color: AppColors.text),
                                ),
                              ),
                          for (final r
                              in s.workspace.libraryRelations.all.where(
                                (r) =>
                                    r.objectId == object.id &&
                                    r.kind == 'tag' &&
                                    CustomTag.idOfAssetRef(r.targetId) == null,
                              ))
                            Chip(
                              label: Text(
                                r.targetId,
                                style: TextStyle(color: AppColors.text),
                              ),
                              onDeleted: () async {
                                await repo.removeRelation(r.id);
                                setLabels(() {});
                                setState(() {});
                              },
                            ),
                          ActionChip(
                            key: const ValueKey('library-edit-tags'),
                            avatar: const Icon(Icons.sell_outlined, size: 16),
                            label: const Text('Edit tags'),
                            onPressed: () async {
                              final chosen = await showTagPicker(
                                ctx,
                                s,
                                selected: repo.tagIdsOf(object.id),
                                what: 'this item',
                              );
                              if (chosen == null) return;
                              await repo.setTags(object.id, chosen);
                              setLabels(() {});
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _manageSpaces(object),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Manage Regular Spaces'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Processing',
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                for (final job in s.workspace.libraryJobs.all.where(
                  (j) =>
                      j.objectId == object.id &&
                      j.stage != LibraryJobStage.extract,
                ))
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${job.stage.name}: ${job.status.name}${job.error == null ? '' : ' · ${job.error}'}',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: AppType.sizeLabel,
                          ),
                        ),
                      ),
                      if (job.status == LibraryJobStatus.failed ||
                          job.status == LibraryJobStatus.retry)
                        TextButton(
                          onPressed: () => repo.retryJob(job.id),
                          child: const Text('Retry'),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final ok = await confirm(
                ctx,
                title: 'Remove this item from the library?',
                message: 'The saved object will be hidden. Its attached files remain untouched.',
                action: 'Remove',
              );
              if (ok) {
                await repo.delete(object.id);
                if (ctx.mounted) Navigator.pop(ctx);
                setState(() {});
              }
            },
            child: const Text('Remove'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () async {
              final latest = s.workspace.libraryObjects[object.id] ?? object;
              await repo.update(
                latest.copyWith(
                  title: titleController.text,
                  content: controller.text,
                ),
              );
              await repo.setUserNote(object.id, noteController.text);
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    titleController.dispose();
    noteController.dispose();
  }

  // ---- the item's content, out of the Archive ---------------------------

  /// iPhone/iPad share sheet for the stored file (a decrypted view copy).
  Future<void> _shareAsset(Asset asset) async {
    final name = asset.file;
    final file = name == null ? null : s.workspace.attachments.viewFile(name);
    if (file == null) {
      s.showToast('This file is not on this device yet.');
      return;
    }
    await s.ios?.shareFile(file.path);
  }

  /// Windows "Save as" with the decrypted content.
  Future<void> _saveAssetCopy(Asset asset) async {
    final name = asset.file;
    if (name == null) return;
    final ext = AttachmentStore.extensionOf(name);
    final suggested = asset.title?.trim().isNotEmpty == true
        ? asset.title!.trim()
        : 'archive-item.$ext';
    final path = native.askSavePath(
      suggestedName: suggested,
      extension: ext.isEmpty ? 'bin' : ext,
      typeLabel: asset.kind == AssetKind.image ? 'Image' : 'Document',
    );
    if (path == null) return;
    try {
      final bytes = await s.workspace.attachments.readBytes(name);
      await File(path).writeAsBytes(bytes, flush: true);
      s.showToast('Saved.');
    } catch (e) {
      s.showToast('Could not save the file: $e');
    }
  }

  /// Puts the actual image on the system clipboard (Windows).
  Future<void> _copyImage(Asset asset) async {
    final name = asset.file;
    if (name == null) return;
    ui.Codec? codec;
    ui.Image? image;
    try {
      final bytes = await s.workspace.attachments.readBytes(name);
      codec = await ui.instantiateImageCodec(bytes);
      image = (await codec.getNextFrame()).image;
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) throw StateError('undecodable');
      final png = AttachmentStore.extensionOf(name) == 'png'
          ? bytes
          : (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))?.buffer.asUint8List();
      final ok = native.copyImageToClipboard(
        rgba: raw.buffer.asUint8List(),
        width: image.width,
        height: image.height,
        png: png,
      );
      s.showToast(ok ? 'Image copied.' : 'Could not copy the image.');
    } catch (_) {
      s.showToast('Could not copy the image.');
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// Whether the item has content that can be placed in a note or mindmap.
  bool _canSend(LibraryObject object) =>
      object.attachmentIds.any((id) => s.workspace.assets[id] != null) ||
      (object.sourceUrl ?? '').isNotEmpty ||
      (object.content ?? '').trim().isNotEmpty ||
      (object.description ?? '').trim().isNotEmpty;

  /// The item's content as a drag-and-drop transfer: its stored files, or
  /// its link (as the shared link asset, the saved address unchanged), or
  /// its text. Null when there is nothing to place.
  Transfer? _transferOf(LibraryObject object) {
    final assetIds = [
      for (final id in object.attachmentIds)
        if (s.workspace.assets[id] != null) id,
    ];
    if (assetIds.isNotEmpty) return AssetsTransfer(assetIds);
    final url = object.sourceUrl;
    if (url != null && url.isNotEmpty) {
      final title = object.title.trim();
      return AssetsTransfer([
        s.workspace.linkAsset(url, title: title.isEmpty ? null : title).id,
      ]);
    }
    final text = [
      for (final part in [object.content, object.description])
        if ((part ?? '').trim().isNotEmpty) part!.trim(),
    ].join('\n\n');
    return text.isEmpty ? null : TextTransfer(text);
  }

  /// Copies (or, with [move], moves) the item's content into a note or a
  /// mindmap the user picks. A copy never changes the item; a move removes
  /// the item from the Archive only after the content arrived, and the
  /// stored file itself always stays.
  Future<void> _sendTo(
    BuildContext dialogContext,
    LibraryObject object, {
    required bool move,
  }) async {
    final verb = move ? 'Move' : 'Copy';
    final dest = await showAppDialog<String>(
      context: dialogContext,
      builder: (c) => SimpleDialog(
        backgroundColor: AppColors.card,
        title: Text('$verb to'),
        children: [
          SimpleDialogOption(
            key: const ValueKey('archive-dest-note'),
            onPressed: () => Navigator.pop(c, 'note'),
            child: const ListTile(
              leading: Icon(Icons.description_outlined),
              title: Text('A note'),
            ),
          ),
          SimpleDialogOption(
            key: const ValueKey('archive-dest-mindmap'),
            onPressed: () => Navigator.pop(c, 'mindmap'),
            child: const ListTile(
              leading: Icon(Icons.account_tree_outlined),
              title: Text('A mindmap'),
            ),
          ),
        ],
      ),
    );
    if (dest == null || !dialogContext.mounted) return;
    final transfer = _transferOf(object);
    if (transfer == null) {
      s.showToast('There is nothing to place from this item.');
      return;
    }
    final DropPlace place;
    if (dest == 'note') {
      final noteId = await _pickNote(dialogContext);
      if (noteId == null) return;
      place = NotePlace(noteId);
    } else {
      final canvasId = await _pickMindmap(dialogContext);
      if (canvasId == null) return;
      place = CanvasPlace(canvasId);
    }
    final choices = s.transferChoices(transfer, place);
    if (choices.isEmpty) {
      s.showToast('That cannot be placed there.');
      return;
    }
    final TransferResult result;
    try {
      result = await s.performTransfer(transfer, place, choices.first.op);
    } catch (e) {
      s.showToast('The $verb did not complete; nothing was changed. ($e)');
      return;
    }
    if (!move) {
      s.showTransferResult((message: result.message, undo: result.undo));
      if (mounted) setState(() {});
      return;
    }
    // Move: the content arrived, so take the item out of the Archive (its
    // stored file stays, now referenced from the destination). Undo puts
    // the item back with its folder memberships.
    final relations = [
      for (final r in s.workspace.libraryRelations.all)
        if (r.kind == 'space' && r.objectId == object.id) r,
    ];
    await repo.delete(object.id);
    if (dialogContext.mounted) Navigator.pop(dialogContext);
    s.showTransferResult((
      message: '${result.message} Moved out of the Archive.',
      undo: () async {
        await result.undo?.call();
        final item = s.workspace.libraryObjects[object.id];
        if (item != null) await repo.update(item.copyWith(deleted: false));
        for (final r in relations) {
          s.workspace.libraryRelations.put(r);
        }
        await s.workspace.libraryRelations.flush();
      },
    ));
    if (mounted) setState(() {});
  }

  /// A standalone note made from the item (text, link and files); the item
  /// itself stays in the Archive. Doing it again opens the same note.
  Future<void> _makeNote(BuildContext dialogContext, LibraryObject object) async {
    final sorter = CaptureSorter(s.workspace, repo);
    final result = await sorter.convertToNote(object.id);
    if (result == null) return;
    // The note is already visible and undoable; persistence finishes in
    // the background (as the phone's sort sheet does).
    unawaited(
      result.persisted.catchError(
        (Object e) => s.showToast('Could not save that change: $e'),
      ),
    );
    s.showTransferResult((
      message: result.already
          ? 'This item already has that note (in Notes).'
          : '${result.undo.message} Find it in Notes.',
      undo: result.already ? null : result.undo.undo,
    ));
    if (dialogContext.mounted) Navigator.pop(dialogContext);
  }

  /// Picks an existing note (most recently edited first, searchable).
  Future<String?> _pickNote(BuildContext context) {
    final all = s.workspace.notes.all.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    var query = '';
    return showAppDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialogState) {
          final q = query.toLowerCase();
          final notes = [
            for (final n in all)
              if (q.isEmpty || n.displayTitle.toLowerCase().contains(q)) n,
          ];
          return AlertDialog(
            backgroundColor: AppColors.card,
            title: const Text('Which note?'),
            content: SizedBox(
              width: 380,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('archive-pick-note-search'),
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search notes',
                    ),
                    onChanged: (v) => setDialogState(() => query = v),
                  ),
                  Expanded(
                    child: notes.isEmpty
                        ? Center(
                            child: Text(
                              'No matching note.',
                              style: TextStyle(color: AppColors.textMuted),
                            ),
                          )
                        : ListView.builder(
                            itemCount: notes.length,
                            itemBuilder: (c2, i) => ListTile(
                              key: ValueKey(
                                'archive-pick-note-${notes[i].id}',
                              ),
                              title: Text(notes[i].displayTitle, maxLines: 1),
                              onTap: () => Navigator.pop(c, notes[i].id),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Picks an existing mindmap.
  Future<String?> _pickMindmap(BuildContext context) {
    final list = s.canvasList;
    return showAppDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Which mindmap?'),
        content: SizedBox(
          width: 380,
          height: 360,
          child: list.isEmpty
              ? Center(
                  child: Text(
                    'There are no mindmaps yet.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (c2, i) => ListTile(
                    key: ValueKey('archive-pick-canvas-${list[i].id}'),
                    title: Text(
                      list[i].title.isEmpty ? 'Untitled' : list[i].title,
                      maxLines: 1,
                    ),
                    onTap: () => Navigator.pop(c, list[i].id),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _manageSpaces(LibraryObject object) async {
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final spaces = s.workspace.librarySpaces.all
              .where((sp) => sp.kind == LibrarySpaceKind.regular)
              .toList();
          final memberships = s.workspace.libraryRelations.all
              .where((r) => r.objectId == object.id && r.kind == 'space')
              .map((r) => r.targetId)
              .toSet();
          return AlertDialog(
            backgroundColor: AppColors.card,
            title: const Text('Regular Spaces'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final space in spaces)
                    CheckboxListTile(
                      value: memberships.contains(space.id),
                      title: Text(space.name),
                      onChanged: (checked) {
                        if (checked == true) {
                          repo.addToRegularSpace(space.id, object.id);
                        } else {
                          repo.removeFromRegularSpace(space.id, object.id);
                        }
                        setDialogState(() {});
                        setState(() {});
                      },
                    ),
                  if (spaces.isEmpty)
                    const Text('Create a Regular Space from the library view.'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ObjectCard extends StatelessWidget {
  const _ObjectCard({
    required this.state,
    required this.object,
    required this.onTap,
  });
  final AppState state;
  final LibraryObject object;
  final VoidCallback onTap;

  /// Small dots in the colours of the item's categories and tags.
  Widget _labelDots() {
    final repo = state.library;
    final colors = [
      for (final id in repo.categoriesOf(object.id)) LinkTag.byId(id)!.color,
      for (final id in repo.tagIdsOf(object.id))
        Color(state.workspace.customTags[id]!.color),
    ];
    if (colors.isEmpty) return const SizedBox(height: 10);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 4,
        children: [
          for (final c in colors) CircleAvatar(backgroundColor: c, radius: 5),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The thumbnail reference is an asset id, resolved to its stored file
    // (see archiveImageFileOf); using it as a file name shows nothing.
    final imageName = archiveImageFileOf(state.workspace, object);
    return Card(
      color: AppColors.card,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ColoredBox(
                color: AppColors.cardRaised,
                child: Center(
                  child: imageName != null
                      ? Image(
                          image: AttachmentImageProvider(
                            state.workspace.attachments,
                            imageName,
                          ),
                          fit: BoxFit.cover,
                          width: double.infinity,
                        )
                      : Icon(
                          switch (object.type) {
                            LibraryObjectType.image => Icons.image_outlined,
                            LibraryObjectType.article => Icons.article_outlined,
                            LibraryObjectType.website => Icons.language,
                            LibraryObjectType.document =>
                              Icons.picture_as_pdf_outlined,
                            LibraryObjectType.note => Icons.notes,
                            LibraryObjectType.video => Icons.movie_outlined,
                            _ => Icons.bookmark_border,
                          },
                          size: 44,
                          color: AppColors.textMuted,
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    object.title.isEmpty ? 'Untitled' : object.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    object.mainEntity?.name ??
                        object.sourceUrl ??
                        object.type.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: AppType.sizeLabel,
                    ),
                  ),
                  _labelDots(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
