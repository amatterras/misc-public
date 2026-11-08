import 'dart:async';

// Archive on the phone: every saved item is a folder (phone_folder_card.dart):
// a tab with its Archive tag, a picture of what was saved, its title and
// source. Your own folders sit above as a row of tabs and open as a list of
// the same folder cards. Same library records as the full Archive (reachable
// under More); nothing is stored differently.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/models/object_library_models.dart';
import '../features/capture/sorting.dart';
import '../new_ui/archive_model.dart';
import '../features/library/library_page.dart' show LibraryPage;
import '../new_ui/new_folder_colors.dart' show NewFolderColors;
import '../app/theme.dart';
import 'phone_folder_card.dart';
import 'phone_more.dart';
import 'phone_page.dart';
import 'phone_tokens.dart';
import 'phone_widgets.dart';

class PhoneArchive extends StatefulWidget {
  const PhoneArchive({super.key, required this.state});

  final AppState state;

  @override
  State<PhoneArchive> createState() => _PhoneArchiveState();
}

class _PhoneArchiveState extends State<PhoneArchive> {
  String _query = '';
  final _search = TextEditingController();

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    // Folders without a colour get one (once, saved), as in the full Archive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ArchiveModel.ensureColors(s.workspace);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<LibraryObject> _found() {
    final q = _query.trim().toLowerCase();
    final list = [
      for (final o in s.library.objects)
        if (o.title.toLowerCase().contains(q) ||
            (o.description ?? '').toLowerCase().contains(q) ||
            (o.sourceUrl ?? '').toLowerCase().contains(q))
          o,
    ];
    list.sort(
      (a, b) => (b.lastSavedAt ?? b.createdAt).compareTo(
        a.lastSavedAt ?? a.createdAt,
      ),
    );
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s.workspace.changes,
      builder: (context, _) {
        final collections = ArchiveModel.landing(s.library, s.workspace);
        final objects = s.library.objects;
        final searching = _query.trim().isNotEmpty;
        final recent = [...objects]
          ..sort(
            (a, b) => (b.lastSavedAt ?? b.createdAt).compareTo(
              a.lastSavedAt ?? a.createdAt,
            ),
          );
        final found = searching ? _found() : const <LibraryObject>[];
        return CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: PhoneHeader(
                eyebrow: objects.length == 1
                    ? '1 saved'
                    : '${objects.length} saved',
                title: 'Archive',
                actions: [
                  PhoneMoreButtons(state: s, tab: PhoneTabKind.archive),
                ],
              ),
            ),
            SliverToBoxAdapter(child: _searchField()),
            const SliverToBoxAdapter(child: Hairline()),
            if (searching) ...[
              if (found.isEmpty)
                const SliverToBoxAdapter(child: EmptyNote('Nothing matches.'))
              else
                _cards(found),
            ] else ...[
              if (collections.isNotEmpty) ...[
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      PhoneSpace.margin,
                      20,
                      PhoneSpace.margin,
                      10,
                    ),
                    child: Eyebrow('Folders'),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 40,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: PhoneSpace.margin,
                      ),
                      itemCount: collections.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) => _FolderTab(
                        collection: collections[i],
                        onTap: () => pushPhone<void>(
                          context,
                          PhoneFolderPage(
                            state: s,
                            collectionId: collections[i].id,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    PhoneSpace.margin,
                    24,
                    PhoneSpace.margin,
                    12,
                  ),
                  child: Eyebrow('Saved'),
                ),
              ),
              if (recent.isEmpty)
                const SliverToBoxAdapter(
                  child: EmptyNote(
                    'Nothing saved yet.',
                    hint: 'Share a link or a picture to misc., or use the + below.',
                  ),
                )
              else
                _cards(recent),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        );
      },
    );
  }

  /// One folder per saved item, built lazily as they scroll into view.
  Widget _cards(List<LibraryObject> items) => SliverList.builder(
    itemCount: items.length,
    itemBuilder: (context, i) => _itemCard(context, s, items[i]),
  );

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(
      PhoneSpace.margin,
      4,
      PhoneSpace.margin,
      6,
    ),
    child: Row(
      children: [
        Icon(Icons.search_rounded, size: 20, color: AppColors.textFaint),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            key: const ValueKey('phone-archive-search'),
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            cursorColor: AppColors.accent,
            style: PhoneType.row.copyWith(fontWeight: FontWeight.w400),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              hintText: 'Search the Archive',
              hintStyle: PhoneType.row.copyWith(
                fontWeight: FontWeight.w400,
                color: AppColors.textFaint,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        if (_query.isNotEmpty)
          GlyphButton(
            icon: Icons.close_rounded,
            label: 'Clear search',
            size: 18,
            onTap: () {
              _search.clear();
              setState(() => _query = '');
            },
          ),
      ],
    ),
  );
}

/// A saved item as a folder; the same one everywhere in the phone Archive.
Widget _itemCard(BuildContext context, AppState s, LibraryObject o) =>
    ScrollDepth(
      key: ValueKey('archive-item-${o.id}'),
      child: ArchiveFolderCard(
        state: s,
        object: o,
        onTap: () => openPhoneArchiveItem(context, s, o.id),
        onLongPress: () => showSortSheet(context, s, o),
      ),
    );

/// One of your folders, as a tab in the row above the saved items.
class _FolderTab extends StatelessWidget {
  const _FolderTab({required this.collection, required this.onTap});

  final ArchiveCollection collection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color =
        NewFolderColors.byId(collection.space?.colorId)?.color ??
        AppColors.textFaint;
    return Press(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Color.lerp(AppColors.card, color, 0.16),
          border: Border(top: BorderSide(color: color, width: 3)),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadii.sm),
          ),
        ),
        alignment: Alignment.center,
        child: Row(
          children: [
            Text(
              collection.name,
              maxLines: 1,
              style: PhoneType.row.copyWith(fontSize: AppType.sizeBody),
            ),
            const SizedBox(width: 8),
            Text('${collection.total}', style: PhoneType.meta),
          ],
        ),
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.state,
    required this.collection,
    required this.onTap,
  });

  final AppState state;
  final ArchiveCollection collection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color =
        NewFolderColors.byId(collection.space?.colorId)?.color ??
        AppColors.textFaint;
    final latest = collection.items.firstOrNull;
    return Press(
      onTap: onTap,
      child: Column(
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: PhoneSpace.margin),
                Container(
                  width: 3,
                  margin: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(AppRadii.xs),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          collection.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: PhoneType.title.copyWith(fontSize: 21),
                        ),
                        if (latest != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              latest.title.isEmpty ? 'Untitled' : latest.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PhoneType.meta,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(
                    left: 12,
                    right: PhoneSpace.margin,
                  ),
                  child: Center(
                    child: Text(
                      '${collection.total}',
                      style: PhoneType.time.copyWith(fontSize: 15),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Hairline(inset: PhoneSpace.margin + 17),
        ],
      ),
    );
  }
}

/// A folder as a list: sub-folders first, then what is in it.
class PhoneFolderPage extends StatelessWidget {
  const PhoneFolderPage({
    super.key,
    required this.state,
    required this.collectionId,
  });

  final AppState state;
  final String collectionId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state.workspace.changes,
      builder: (context, _) {
        final ws = state.workspace;
        final space = ws.librarySpaces[collectionId];
        final collection = space == null
            ? ArchiveModel.unfiled(state.library, ws)
            : ArchiveModel.collection(state.library, space);
        final subfolders = space == null
            ? const <LibrarySpace>[]
            : ArchiveModel.folders(ws, parentId: space.id);
        final color = NewFolderColors.byId(space?.colorId)?.color;
        return PhonePage(
          eyebrow: collection.total == 1
              ? '1 item'
              : '${collection.total} items',
          title: collection.name,
          child: collection.items.isEmpty && subfolders.isEmpty
              ? const Align(
                  alignment: Alignment.topLeft,
                  child: EmptyNote(
                    'Empty.',
                    hint: 'Save something into it from the + or a share sheet.',
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 32),
                  itemCount:
                      (color != null ? 1 : 0) +
                      subfolders.length +
                      collection.items.length,
                  itemBuilder: (context, i) {
                    if (color != null) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(
                            PhoneSpace.margin,
                            0,
                            PhoneSpace.margin,
                            12,
                          ),
                          child: Container(height: 3, color: color),
                        );
                      }
                      i -= 1;
                    }
                    if (i < subfolders.length) {
                      final f = subfolders[i];
                      return _FolderRow(
                        state: state,
                        collection: ArchiveModel.collection(state.library, f),
                        onTap: () => pushPhone<void>(
                          context,
                          PhoneFolderPage(state: state, collectionId: f.id),
                        ),
                      );
                    }
                    return _itemCard(
                      context,
                      state,
                      collection.items[i - subfolders.length],
                    );
                  },
                ),
        );
      },
    );
  }
}

/// Opens one saved item in the Archive's existing detail view. Same route as
/// the full Archive uses (an invisible page that shows the item and closes
/// with it), with a Material under it, which that page's controls need.
Future<void> openPhoneArchiveItem(
  BuildContext context,
  AppState state,
  String objectId,
) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => Material(
      type: MaterialType.transparency,
      child: Visibility(
        visible: false,
        maintainState: true,
        child: LibraryPage(
          state: state,
          initialObjectId: objectId,
          closeAfterInitialObject: true,
        ),
      ),
    ),
  ),
);

/// What can be done with a saved item: file it, turn it into a note or a
/// task, or put it away. Each one can be undone from the bar that appears.
Future<void> showSortSheet(
  BuildContext context,
  AppState state,
  LibraryObject object,
) async {
  final sorter = CaptureSorter(state.workspace, state.library);
  final current = sorter.stateOf(object.id);
  final choice = await showPhoneSheet<String>(
    context,
    eyebrow:
        '${object.title.isEmpty ? 'Untitled' : object.title} · ${current.label}',
    children: (c) => [
      SheetItem(
        label: 'File in a folder',
        onTap: () => Navigator.pop(c, 'file'),
      ),
      SheetItem(label: 'Make a note', onTap: () => Navigator.pop(c, 'note')),
      SheetItem(label: 'Make a task', onTap: () => Navigator.pop(c, 'task')),
      if (current == CaptureState.archived)
        SheetItem(label: 'Restore', onTap: () => Navigator.pop(c, 'restore'))
      else
        SheetItem(label: 'Archive', onTap: () => Navigator.pop(c, 'archive')),
    ],
  );
  if (choice == null || !context.mounted) return;
  SortResult? result;
  switch (choice) {
    case 'file':
      final folders =
          state.workspace.librarySpaces.all
              .where((s) => s.kind == LibrarySpaceKind.regular)
              .toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
      if (folders.isEmpty) {
        state.showToast('There are no folders yet.');
        return;
      }
      final picked = await showPhoneSheet<String>(
        context,
        eyebrow: 'File in',
        children: (c) => [
          for (final f in folders)
            SheetItem(label: f.name, onTap: () => Navigator.pop(c, f.id)),
        ],
      );
      if (picked != null) result = await sorter.file(object.id, picked);
    case 'note':
      result = await sorter.convertToNote(object.id);
    case 'task':
      result = await sorter.convertToTask(object.id);
    case 'archive':
      result = await sorter.archive(object.id);
    case 'restore':
      result = await sorter.restore(object.id);
  }
  if (result == null) return;
  unawaited(
    result.persisted.catchError(
      (Object e) => state.showToast('Could not save that change: $e'),
    ),
  );
  state.showTransferResult((
    message: result.already ? 'Already done.' : result.undo.message,
    undo: result.already ? null : result.undo.undo,
  ));
}
