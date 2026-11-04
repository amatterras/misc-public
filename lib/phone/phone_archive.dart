// Archive on the phone: a table of contents. The newest saved things run in a
// strip of pictures on top; the folders follow as an index, each with its own
// colour as a thin rule. A folder opens as a list. Same library records as the
// full Archive (reachable under More).
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/models/object_library_models.dart';
import '../new_ui/archive_model.dart';
import '../features/library/library_page.dart' show LibraryPage;
import '../new_ui/new_archive_page.dart'
    show archiveIconOf, archiveImageOf, archiveMetaOf;
import '../new_ui/new_folder_colors.dart' show NewFolderColors;
import '../new_ui/new_tokens.dart';
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
                SliverList.builder(
                  itemCount: found.length,
                  itemBuilder: (context, i) =>
                      ArchiveItemRow(state: s, object: found[i]),
                ),
            ] else ...[
              if (recent.isNotEmpty) ...[
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      PhoneSpace.margin,
                      22,
                      PhoneSpace.margin,
                      10,
                    ),
                    child: Eyebrow('Recently saved'),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 150,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: PhoneSpace.margin,
                      ),
                      itemCount: recent.length > 12 ? 12 : recent.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (context, i) =>
                          _RecentTile(state: s, object: recent[i]),
                    ),
                  ),
                ),
              ],
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    PhoneSpace.margin,
                    28,
                    PhoneSpace.margin,
                    4,
                  ),
                  child: Eyebrow('Folders'),
                ),
              ),
              if (collections.isEmpty)
                const SliverToBoxAdapter(
                  child: EmptyNote(
                    'Nothing saved yet.',
                    hint: 'Share a link or a picture to misc., or use the + below.',
                  ),
                )
              else
                SliverList.builder(
                  itemCount: collections.length,
                  itemBuilder: (context, i) => _FolderRow(
                    state: s,
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
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        );
      },
    );
  }

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(
      PhoneSpace.margin,
      4,
      PhoneSpace.margin,
      6,
    ),
    child: Row(
      children: [
        Icon(Icons.search_rounded, size: 20, color: NewColors.textFaint),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            key: const ValueKey('phone-archive-search'),
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            cursorColor: NewColors.accent,
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
                color: NewColors.textFaint,
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

/// A picture, or the title set on a tint of the folder's colour.
class _RecentTile extends StatelessWidget {
  const _RecentTile({required this.state, required this.object});

  final AppState state;
  final LibraryObject object;

  @override
  Widget build(BuildContext context) {
    final image = archiveImageOf(state, object);
    final paper = Color.lerp(
      NewColors.surfaceSecondary,
      NewColors.accent,
      0.12,
    )!;
    return Press(
      onTap: () => openPhoneArchiveItem(context, state, object.id),
      child: SizedBox(
        width: 112,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: image != null
              ? Image(image: image, fit: BoxFit.cover, width: 112, height: 150)
              : ColoredBox(
                  color: paper,
                  child: Padding(
                    padding: const EdgeInsets.all(11),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          archiveIconOf(object),
                          size: 18,
                          color: NewColors.textFaint,
                        ),
                        const Spacer(),
                        Text(
                          object.title.isEmpty ? 'Untitled' : object.title,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: PhoneType.row.copyWith(
                            fontSize: 14,
                            height: 1.2,
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
        NewColors.textFaint;
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
                    borderRadius: BorderRadius.circular(2),
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
              : ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    if (color != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          PhoneSpace.margin,
                          0,
                          PhoneSpace.margin,
                          0,
                        ),
                        child: Container(height: 3, color: color),
                      ),
                    for (final f in subfolders)
                      _FolderRow(
                        state: state,
                        collection: ArchiveModel.collection(state.library, f),
                        onTap: () => pushPhone<void>(
                          context,
                          PhoneFolderPage(state: state, collectionId: f.id),
                        ),
                      ),
                    for (final o in collection.items)
                      ArchiveItemRow(state: state, object: o),
                  ],
                ),
        );
      },
    );
  }
}

class ArchiveItemRow extends StatelessWidget {
  const ArchiveItemRow({super.key, required this.state, required this.object});

  final AppState state;
  final LibraryObject object;

  @override
  Widget build(BuildContext context) {
    final image = archiveImageOf(state, object);
    final when = object.lastSavedAt ?? object.createdAt;
    return Press(
      onTap: () => openPhoneArchiveItem(context, state, object.id),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PhoneSpace.margin,
              vertical: 13,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 58,
                    height: 58,
                    child: image != null
                        ? Image(image: image, fit: BoxFit.cover)
                        : ColoredBox(
                            color: NewColors.surfaceSecondary,
                            child: Icon(
                              archiveIconOf(object),
                              size: 22,
                              color: NewColors.textFaint,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        object.title.isEmpty ? 'Untitled' : object.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: PhoneType.row.copyWith(fontSize: 16),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${archiveMetaOf(object)} · ${relativeDay(when)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PhoneType.meta,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Hairline(inset: PhoneSpace.margin + 72),
        ],
      ),
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
