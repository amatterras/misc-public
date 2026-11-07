// Notes on the phone: an index, newest first, set as plain typography. One
// line of search, folders as text tabs, and each note as a title, two lines
// of what is in it, and when it was touched. A note opens on its own page.
import 'package:flutter/material.dart';

import '../app/design_tokens.dart';
import '../app/app_state.dart';
import '../data/models/library_models.dart';
import '../features/notes/note_page.dart' show openNotePage;
import '../new_ui/new_tokens.dart';
import '../widgets/common.dart' show confirm;
import 'phone_more.dart';
import 'phone_tokens.dart';
import 'phone_widgets.dart';

const _all = '_all';
const _favourites = '_fav';

class PhoneNotes extends StatefulWidget {
  const PhoneNotes({super.key, required this.state});

  final AppState state;

  @override
  State<PhoneNotes> createState() => _PhoneNotesState();
}

class _PhoneNotesState extends State<PhoneNotes> {
  String _filter = _all;
  String _query = '';
  final _search = TextEditingController();

  AppState get s => widget.state;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Note> _visible() {
    final q = _query.trim().toLowerCase();
    final list = [
      for (final n in s.workspace.notes.all)
        if (_filter == _all ||
            (_filter == _favourites ? n.favorite : n.folderId == _filter))
          if (q.isEmpty ||
              n.title.toLowerCase().contains(q) ||
              n.body.toLowerCase().contains(q))
            n,
    ];
    list.sort((a, b) {
      if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  Future<void> _menu(Note note) async {
    final choice = await showPhoneSheet<String>(
      context,
      eyebrow: note.displayTitle,
      children: (c) => [
        SheetItem(
          label: note.favorite ? 'Remove from favourites' : 'Favourite',
          onTap: () => Navigator.pop(c, 'fav'),
        ),
        SheetItem(
          label: 'Move to folder',
          onTap: () => Navigator.pop(c, 'move'),
        ),
        SheetItem(
          label: 'Delete',
          color: NewColors.danger,
          onTap: () => Navigator.pop(c, 'delete'),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'fav':
        s.workspace.notes.put(note.copyWith(favorite: !note.favorite));
      case 'move':
        await _move(note);
      case 'delete':
        final ok = await confirm(
          context,
          title: 'Delete “${note.displayTitle}”?',
          message: 'It is kept in Recently deleted, where it can be restored.',
        );
        if (ok) {
          s.workspace.deleteNote(note.id);
          s.showToast('Deleted “${note.displayTitle}”.');
        }
    }
  }

  Future<void> _move(Note note) async {
    final folders = s.workspace.folders.all.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final picked = await showPhoneSheet<String>(
      context,
      eyebrow: 'Move to',
      children: (c) => [
        SheetItem(label: 'No folder', onTap: () => Navigator.pop(c, '')),
        for (final f in folders)
          SheetItem(label: f.name, onTap: () => Navigator.pop(c, f.id)),
        if (folders.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(
              PhoneSpace.margin,
              4,
              PhoneSpace.margin,
              8,
            ),
            child: Text(
              'There are no folders yet. Make one in Notes, in full.',
            ),
          ),
      ],
    );
    if (picked == null) return;
    s.workspace.notes.put(
      note.copyWith(folderId: () => picked.isEmpty ? null : picked),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s.workspace.changes]),
      builder: (context, _) {
        final notes = _visible();
        final folders = s.workspace.folders.all.toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
        final total = s.workspace.notes.length;
        return CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: PhoneHeader(
                eyebrow: total == 1 ? '1 note' : '$total notes',
                title: 'Notes',
                actions: [PhoneMoreButtons(state: s, tab: PhoneTabKind.notes)],
              ),
            ),
            SliverToBoxAdapter(child: _searchField()),
            SliverToBoxAdapter(child: _tabs(folders)),
            const SliverToBoxAdapter(child: Hairline()),
            if (notes.isEmpty)
              SliverToBoxAdapter(
                child: EmptyNote(
                  _query.isNotEmpty
                      ? 'Nothing matches.'
                      : total == 0
                      ? 'No notes yet.'
                      : 'Nothing here.',
                  hint: total == 0 ? 'Start one with the + below.' : null,
                ),
              )
            else
              SliverList.builder(
                itemCount: notes.length,
                itemBuilder: (context, i) => _NoteRow(
                  key: ValueKey('note-${notes[i].id}'),
                  note: notes[i],
                  folder: folders
                      .where((f) => f.id == notes[i].folderId)
                      .firstOrNull
                      ?.name,
                  onTap: () => openNotePage(context, s, notes[i].id),
                  onMenu: () => _menu(notes[i]),
                ),
              ),
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
            key: const ValueKey('phone-notes-search'),
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            textInputAction: TextInputAction.search,
            cursorColor: NewColors.accent,
            style: PhoneType.row.copyWith(fontWeight: FontWeight.w400),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              hintText: 'Search notes',
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

  Widget _tabs(List<Folder> folders) {
    final entries = <(String, String)>[
      (_all, 'All'),
      (_favourites, 'Favourites'),
      for (final f in folders) (f.id, f.name),
    ];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: PhoneSpace.margin),
        children: [
          for (final (id, label) in entries)
            Press(
              onTap: () => setState(() => _filter = id),
              child: Padding(
                padding: const EdgeInsets.only(right: 22),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                        color: id == _filter
                            ? NewColors.text
                            : NewColors.textFaint,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 2,
                      width: id == _filter ? 16 : 0,
                      color: NewColors.text,
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    super.key,
    required this.note,
    required this.folder,
    required this.onTap,
    required this.onMenu,
  });

  final Note note;
  final String? folder;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final text = excerpt(note.body);
    return Press(
      onTap: onTap,
      onLongPress: onMenu,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PhoneSpace.margin,
              15,
              PhoneSpace.margin,
              15,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    if (note.favorite)
                      Padding(
                        padding: const EdgeInsets.only(right: 7),
                        child: Icon(
                          Icons.star_rounded,
                          size: 14,
                          color: NewColors.accent,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        note.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PhoneType.row.copyWith(
                          color: note.title.trim().isEmpty
                              ? NewColors.textFaint
                              : NewColors.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(relativeDay(note.updatedAt), style: PhoneType.meta),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  text.isEmpty ? 'No text yet' : text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: PhoneType.body.copyWith(
                    fontSize: AppType.sizeBody,
                    color: text.isEmpty
                        ? NewColors.textFaint
                        : NewColors.textMuted,
                  ),
                ),
                if (folder != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      folder!.toUpperCase(),
                      style: PhoneType.eyebrow.copyWith(
                        fontSize: AppType.sizeMicro,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Hairline(inset: PhoneSpace.margin),
        ],
      ),
    );
  }
}
