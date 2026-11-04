// The "+" of the dock: one list of things to make, the one that belongs to the
// current screen first. Every entry opens an editor that already exists
// (Quick Add, the entry editor, a new note, a new mindmap).
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/models/calendar_models.dart';
import '../features/calendar/entry_editor.dart';
import '../features/capture/capture_dialog.dart';
import '../features/capture/capture_service.dart';
import '../features/notes/note_page.dart' show openNotePage;
import 'phone_more.dart' show PhoneTabKind;
import 'phone_widgets.dart';

/// The day Today or Calendar is showing, so a new item starts on that day.
abstract final class PhoneDay {
  static DateTime? selected;
}

Future<void> showPhoneNew(
  BuildContext context,
  AppState state,
  PhoneTabKind tab, {
  DateTime? day,
}) async {
  if (day == null &&
      (tab == PhoneTabKind.today || tab == PhoneTabKind.calendar)) {
    day = PhoneDay.selected;
  }
  final primary = <(String, String, String?)>[
    ('note', 'Note', null),
    ('task', 'Task', null),
    ('event', 'Event', null),
    ('link', 'Link or photo', 'From the clipboard, or choose'),
  ];
  final first = switch (tab) {
    PhoneTabKind.notes => 'note',
    PhoneTabKind.archive => 'link',
    PhoneTabKind.calendar || PhoneTabKind.today => 'task',
    PhoneTabKind.map => 'note',
  };
  primary.sort((a, b) {
    if (a.$1 == first) return -1;
    if (b.$1 == first) return 1;
    return 0;
  });

  final choice = await showPhoneSheet<String>(
    context,
    eyebrow: 'New',
    children: (c) => [
      for (final (id, label, hint) in primary)
        SheetItem(label: label, hint: hint, onTap: () => Navigator.pop(c, id)),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Hairline(inset: 20, endInset: 20),
      ),
      SheetItem(label: 'Habit', onTap: () => Navigator.pop(c, 'habit')),
      SheetItem(label: 'Reading', onTap: () => Navigator.pop(c, 'reading')),
      SheetItem(label: 'Reminder', onTap: () => Navigator.pop(c, 'reminder')),
      SheetItem(label: 'Mindmap', onTap: () => Navigator.pop(c, 'map')),
    ],
  );
  if (!context.mounted || choice == null) return;
  switch (choice) {
    case 'note':
      final note = state.workspace.createNote();
      await openNotePage(context, state, note.id);
    case 'task':
      await showCaptureDialog(
        context,
        state,
        destination: CaptureDestination.task,
        day: day,
      );
    case 'event':
      await showEntryEditor(
        context,
        state,
        category: CalendarCategory.events,
        day: day,
      );
    case 'habit':
      await showEntryEditor(
        context,
        state,
        category: CalendarCategory.habits,
        day: day,
      );
    case 'reading':
      await showEntryEditor(
        context,
        state,
        category: CalendarCategory.reading,
        day: day,
      );
    case 'reminder':
      await showEntryEditor(
        context,
        state,
        category: CalendarCategory.other,
        day: day,
      );
    case 'link':
      final clip = await state.capture.readClipboard();
      if (!context.mounted) return;
      final use =
          clip.url != null ||
          clip.imageBytes != null ||
          clip.imageFiles.isNotEmpty;
      await showCaptureDialog(
        context,
        state,
        destination: CaptureDestination.links,
        initial: use
            ? ClipboardContent(
                text: clip.url,
                imageBytes: clip.imageBytes,
                imageExtension: clip.imageExtension,
                files: clip.files,
              )
            : null,
      );
    case 'map':
      await state.createCanvas();
  }
}
