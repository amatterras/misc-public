// Today on the iPad: two columns. The day (the phone's Today, reused as it
// is) on the left; what you have been working on, on the right: recent
// notes, recent saves and your mindmaps. Nothing here is new data.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../features/motivation/motivation_service.dart';
import '../features/notes/note_page.dart' show openNotePage;
import '../new_ui/new_tokens.dart';
import '../phone/phone_archive.dart' show RecentTile;
import '../phone/phone_notes.dart' show NoteRow;
import '../phone/phone_today.dart';
import '../phone/phone_tokens.dart';
import '../phone/phone_widgets.dart';

class IpadToday extends StatelessWidget {
  const IpadToday({super.key, required this.state, required this.motivation});

  final AppState state;
  final MotivationService motivation;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final left = (width * 0.44).clamp(380.0, 520.0);
    return Row(
      children: [
        SizedBox(
          width: left,
          child: PhoneToday(state: state, motivation: motivation),
        ),
        Container(width: 1, color: NewColors.border.withValues(alpha: 0.7)),
        Expanded(child: _Desk(state: state)),
      ],
    );
  }
}

class _Desk extends StatelessWidget {
  const _Desk({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.workspace.changes]),
      builder: (context, _) {
        final notes = state.workspace.notes.all.toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        final saved = state.library.objects.toList()
          ..sort(
            (a, b) => (b.lastSavedAt ?? b.createdAt).compareTo(
              a.lastSavedAt ?? a.createdAt,
            ),
          );
        final maps = [
          for (final c in state.canvasList)
            if (!c.isNotebook &&
                !c.isLinksBoard &&
                !c.isCalendarInk &&
                !c.isComponents)
              c,
        ];
        return CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(
              child: PhoneHeader(eyebrow: 'Lately', title: 'Desk'),
            ),
            if (notes.isNotEmpty) ...[
              const SliverToBoxAdapter(child: _Label('Notes')),
              SliverList.builder(
                itemCount: notes.length > 5 ? 5 : notes.length,
                itemBuilder: (context, i) => NoteRow(
                  key: ValueKey('desk-note-${notes[i].id}'),
                  note: notes[i],
                  folder: null,
                  onTap: () => openNotePage(context, state, notes[i].id),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(left: PhoneSpace.margin),
                  child: TextLink(
                    'All notes',
                    trailing: Icons.arrow_forward_rounded,
                    onTap: () => state.goTo(AppPage.notes),
                  ),
                ),
              ),
            ],
            if (saved.isNotEmpty) ...[
              const SliverToBoxAdapter(child: _Label('Saved')),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 150,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: PhoneSpace.margin,
                    ),
                    itemCount: saved.length > 12 ? 12 : saved.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, i) =>
                        RecentTile(state: state, object: saved[i]),
                  ),
                ),
              ),
            ],
            if (maps.isNotEmpty) ...[
              const SliverToBoxAdapter(child: _Label('Mindmaps')),
              SliverList.builder(
                itemCount: maps.length > 6 ? 6 : maps.length,
                itemBuilder: (context, i) => Press(
                  onTap: () async {
                    await state.openCanvas(maps[i].id);
                    state.goTo(AppPage.canvas);
                  },
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: PhoneSpace.margin,
                          vertical: 15,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                maps[i].title.isEmpty
                                    ? 'Untitled'
                                    : maps[i].title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: PhoneType.row,
                              ),
                            ),
                            Text(
                              relativeDay(maps[i].updatedAt),
                              style: PhoneType.meta,
                            ),
                          ],
                        ),
                      ),
                      const Hairline(inset: PhoneSpace.margin),
                    ],
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 36)),
          ],
        );
      },
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      PhoneSpace.margin,
      26,
      PhoneSpace.margin,
      8,
    ),
    child: Eyebrow(text),
  );
}
