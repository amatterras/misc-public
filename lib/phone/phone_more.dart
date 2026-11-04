// The two glyphs at the top right of every screen (search, more) and what
// "more" opens: the other places (Safari, AI), Search, Commands, Settings,
// and, per screen, the complete page of the app for the things the phone
// screens leave out (trash, templates, the Archive's whole look…).
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/shell.dart' show openCommandPalette;
import '../features/calendar/calendar_page.dart';
import '../features/library/library_page.dart';
import '../features/notes/notes_page.dart';
import '../features/search/search_dialog.dart';
import '../features/settings/settings_dialog.dart';
import 'phone_page.dart';
import 'phone_widgets.dart';

enum PhoneTabKind { today, notes, calendar, archive, map }

class PhoneMoreButtons extends StatelessWidget {
  const PhoneMoreButtons({super.key, required this.state, required this.tab});

  final AppState state;
  final PhoneTabKind tab;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      GlyphButton(
        key: const ValueKey('phone-search'),
        icon: Icons.search_rounded,
        label: 'Search',
        onTap: () => showSearchDialog(context, state),
      ),
      GlyphButton(
        key: const ValueKey('phone-more'),
        icon: Icons.more_horiz_rounded,
        label: 'More',
        onTap: () => showPhoneMore(context, state, tab),
      ),
    ],
  );
}

Future<void> showPhoneMore(
  BuildContext context,
  AppState state,
  PhoneTabKind tab,
) async {
  final choice = await showPhoneSheet<String>(
    context,
    eyebrow: 'misc.',
    children: (c) => [
      SheetItem(label: 'Safari', onTap: () => Navigator.pop(c, 'safari')),
      SheetItem(label: 'AI', onTap: () => Navigator.pop(c, 'ai')),
      SheetItem(label: 'Search', onTap: () => Navigator.pop(c, 'search')),
      SheetItem(label: 'Commands', onTap: () => Navigator.pop(c, 'commands')),
      if (tab == PhoneTabKind.notes)
        SheetItem(
          label: 'Notes, in full',
          hint: 'Trash, templates, folders',
          onTap: () => Navigator.pop(c, 'full'),
        ),
      if (tab == PhoneTabKind.calendar)
        SheetItem(
          label: 'Calendar, in full',
          hint: 'Habits, reading, handwriting, filters',
          onTap: () => Navigator.pop(c, 'full'),
        ),
      if (tab == PhoneTabKind.archive)
        SheetItem(
          label: 'Archive, whole look',
          hint: 'Every item, tags, checks',
          onTap: () => Navigator.pop(c, 'full'),
        ),
      SheetItem(label: 'Settings', onTap: () => Navigator.pop(c, 'settings')),
    ],
  );
  if (!context.mounted || choice == null) return;
  switch (choice) {
    case 'safari':
      state.goTo(AppPage.browser);
    case 'ai':
      state.goTo(AppPage.ai);
    case 'search':
      await showSearchDialog(context, state);
    case 'commands':
      await openCommandPalette(context, state);
    case 'settings':
      await showSettingsDialog(context, state);
    case 'full':
      switch (tab) {
        case PhoneTabKind.notes:
          await pushPhone<void>(
            context,
            PhonePage(
              title: 'Notes',
              child: NotesPage(state: state),
            ),
          );
        case PhoneTabKind.calendar:
          await pushPhone<void>(
            context,
            PhonePage(
              title: 'Calendar',
              child: CalendarPage(state: state),
            ),
          );
        case PhoneTabKind.archive:
          await pushPhone<void>(
            context,
            PhonePage(
              title: 'Archive',
              child: LibraryPage(state: state),
            ),
          );
        default:
          break;
      }
  }
}
