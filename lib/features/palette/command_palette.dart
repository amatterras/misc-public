// The command palette (Ctrl+Shift+P, or the ⌘ button): find and run any
// app command or open any place by typing. Different from the right-click
// menus, which only offer actions for what was clicked.
import '../canvas/canvas_page.dart' show runCanvasOption;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/page_windows.dart';
import '../../app/top_bar.dart';
import '../../app/theme.dart';
import '../../platform/input_hints.dart';
import '../../widgets/common.dart';
import '../../platform/platform.dart' as native;
import '../calendar/ics.dart';
import '../canvas/time_machine.dart';
import '../notes/notes_page.dart' show showNoteHistory;
import '../capture/quick_capture.dart';
import '../reading/reading_progress.dart';
import '../pdfanchors/pdf_notes_split.dart';
import '../../data/models/library_models.dart' show AssetKind;
import '../export/exports.dart';
import '../sharing/share_dialog.dart';
import '../review/review_center.dart';
import '../templates/templates.dart';
import '../think/experiment_page.dart';

class PaletteCommand {
  const PaletteCommand(this.label, this.icon, this.run, {this.hint = ''});
  final String label;
  final IconData icon;

  /// Runs after the palette has closed, with the page's context.
  final void Function(BuildContext context) run;
  final String hint;
}

/// Everything the palette offers right now: commands, then places.
List<PaletteCommand> paletteCommands(
  AppState s, {
  required void Function(BuildContext) quickAdd,
  required void Function(BuildContext) search,
  required void Function(BuildContext) settings,
  required void Function(BuildContext) appSwitcher,
}) {
  final ws = s.workspace;
  final recent = ws.notes.all.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return [
    PaletteCommand(
      'Go to mindmap',
      Icons.hub_outlined,
      (_) => s.goTo(AppPage.canvas),
    ),
    PaletteCommand(
      'Go to notes',
      Icons.description_outlined,
      (_) => s.goTo(AppPage.notes),
    ),
    PaletteCommand(
      'Go to calendar',
      Icons.calendar_today_outlined,
      (_) => s.goTo(AppPage.calendar),
    ),
    PaletteCommand(
      'Go to archive',
      Icons.bookmarks_outlined,
      (_) => s.goTo(AppPage.links),
    ),
    PaletteCommand('Show tasks', Icons.checklist, (_) => s.goTo(AppPage.tasks)),
    PaletteCommand(
      'Time Machine (earlier versions of this note or mindmap)',
      Icons.history,
      (context) {
        final noteId = s.activeNoteId.value;
        if (noteId != null && s.workspace.notes.contains(noteId)) {
          showNoteHistory(context, s.workspace, noteId);
        } else if (s.page == AppPage.canvas && s.canvas != null) {
          showCanvasVersions(context, s, s.canvas!);
        } else {
          s.showToast('Open a note or a mindmap first.');
        }
      },
    ),
    PaletteCommand(
      'PDF and its notes, side by side',
      Icons.vertical_split_outlined,
      (context) async {
        final docs = s.workspace.assets.all
            .where((a) => a.kind == AssetKind.document)
            .toList();
        if (docs.isEmpty) {
          s.showToast('No PDFs in the Archive yet.');
          return;
        }
        final focus = s.pdfFocus.value?.assetId;
        final pick = docs.where((a) => a.id == focus).firstOrNull ?? docs.first;
        openPdfNotes(s, pick.id);
      },
    ),
    PaletteCommand(
      'Reading progress',
      Icons.menu_book_outlined,
      (context) => showReadingOverview(context, s),
    ),
    PaletteCommand(
      'Resume reading',
      Icons.play_arrow,
      (context) async {
        final a = latestReading(s.workspace);
        if (a == null) {
          s.showToast('Nothing is marked as reading yet.');
          return;
        }
        await resumeReading(s, a.id);
      },
    ),
    PaletteCommand(
      'Quick capture',
      Icons.bolt,
      (context) => showQuickCapture(context, s),
      hint: touchFirst ? '' : 'Ctrl+Shift+Space',
    ),
    PaletteCommand(
      'Restore workspace layout',
      Icons.dashboard_customize_outlined,
      (_) => s.floating.restoreLayout(),
      hint: 'floating windows',
    ),
    PaletteCommand(
      'Quick Add',
      Icons.add_circle_outline,
      quickAdd,
      hint: touchFirst ? '' : 'Ctrl+N',
    ),
    PaletteCommand(
      'Search everything',
      Icons.search,
      search,
      hint: touchFirst ? '' : 'Ctrl+K',
    ),
    PaletteCommand('New note', Icons.note_add_outlined, (_) {
      final n = ws.createNote();
      s.openNote(n.id);
    }),
    PaletteCommand('New mindmap', Icons.add_box_outlined, (_) {
      unawaited(s.createCanvas(title: 'mindmap ${s.canvasList.length + 1}'));
    }),
    // There is no canvas picker; its options live here.
    if (s.canvas != null) ...[
      PaletteCommand(
        'Rename this mindmap',
        Icons.drive_file_rename_outline,
        (context) => runCanvasOption(context, s, s.canvas!, 'rename'),
      ),
      PaletteCommand(
        'Move this mindmap to a folder',
        Icons.folder_outlined,
        (context) => runCanvasOption(context, s, s.canvas!, 'folder'),
      ),
      PaletteCommand(
        'Move this mindmap to trash',
        Icons.delete_outline,
        (context) => runCanvasOption(context, s, s.canvas!, 'delete'),
      ),
    ],
    PaletteCommand('New task', Icons.add_task, (context) async {
      final title = await promptText(context, title: 'New task', action: 'Add');
      if (title == null) return;
      final t = ws.createTask(title);
      s.openTask(t.id);
    }),
    PaletteCommand('App switcher (floating)', Icons.apps, appSwitcher),
    PaletteCommand(
      'Add this page to the bar',
      Icons.add_box_outlined,
      (_) => addCurrentPage(s),
    ),
    PaletteCommand('Float this page in a window', Icons.open_in_new, (_) {
      final p = addCurrentPage(s);
      s.windows.float(p.id);
    }),
    // New pages: each a fresh instance (the same as the page bar's menu),
    // in the main area or as a floating window.
    for (final (kind, label) in newPageChoices) ...[
      PaletteCommand(label, pageIcon(kind), (_) => s.newPage(kind)),
      PaletteCommand(
        '$label in a window',
        pageIcon(kind),
        (_) => s.newPage(kind, mode: PageMode.floating),
      ),
    ],
    PaletteCommand(
      'Close this page (keeps its content)',
      Icons.close,
      (_) => s.closeActivePage(),
    ),
    PaletteCommand('Minimize this page', Icons.minimize, (_) {
      final id = s.windows.activeId;
      if (id != null) s.windows.minimize(id);
    }),
    PaletteCommand(
      'Go to safari',
      Icons.explore_outlined,
      (_) => s.goTo(AppPage.browser),
    ),
    PaletteCommand(
      'Go to ai',
      Icons.auto_awesome_outlined,
      (_) => s.goTo(AppPage.ai),
    ),
    PaletteCommand(
      'Export the calendar (.ics file)',
      Icons.event_available_outlined,
      (_) async {
        final dir = exportsFolder(s);
        await dir.create(recursive: true);
        final f = freshFile(dir, 'misc. calendar', 'ics');
        await f.writeAsString(calendarIcs(s.workspace));
        s.showToast('Saved ${f.path}');
        await revealExport(s, f);
      },
    ),
    PaletteCommand('Import a calendar file (.ics)', Icons.event_note_outlined, (
      _,
    ) async {
      if (!Platform.isWindows) {
        s.showToast('Importing calendar files works on Windows for now.');
        return;
      }
      var added = 0;
      for (final path in native.pickCalendarFiles()) {
        final file = File(path);
        if (await file.length() > 20 * 1024 * 1024) {
          s.showToast('That calendar file is too large (over 20 MB).');
          continue;
        }
        added += importIcs(s.workspace, await file.readAsString());
      }
      s.showToast('$added events added to the days’ notes.');
    }),
    PaletteCommand(
      'Review: today and this week',
      Icons.fact_check_outlined,
      (c) => showReviewCenter(c, s),
    ),
    PaletteCommand(
      'New note from a template',
      Icons.note_add_outlined,
      (c) => newNoteFromTemplate(c, s),
    ),
    PaletteCommand(
      'New project from a template',
      Icons.create_new_folder_outlined,
      (c) => newProjectFromTemplate(c, s),
    ),
    PaletteCommand(
      'How things connect (graph)',
      Icons.bubble_chart_outlined,
      (_) => s.openGraph(),
    ),
    PaletteCommand('Private vault', Icons.lock_outline, (_) => s.openVault()),
    PaletteCommand(
      'Thought experiments',
      Icons.psychology_outlined,
      (c) => showExperiments(c, s),
    ),
    PaletteCommand(
      'New thought experiment',
      Icons.psychology_alt_outlined,
      (c) => newExperiment(c, s),
    ),
    PaletteCommand(
      'Shared links (revoke)',
      Icons.ios_share,
      (c) => showSharedLinks(c, s),
    ),
    PaletteCommand(
      'Full screen on or off',
      Icons.fullscreen,
      (_) => s.toggleImmersive(),
    ),
    PaletteCommand('Open AI window', Icons.auto_awesome_outlined, (_) {
      if (!s.ai.enabled) {
        s.showToast('AI is off. Turn it on in Settings → AI.');
      } else {
        s.openAiWindow();
      }
    }),
    PaletteCommand(
      s.timer.running ? 'Pause focus timer' : 'Start focus timer',
      Icons.timer_outlined,
      (_) => s.timer.running ? s.timer.pause() : s.timer.start(),
    ),
    if (s.alwaysOnTopSupported)
      PaletteCommand(
        s.alwaysOnTop ? 'Stop keeping misc. on top' : 'Keep misc. on top',
        Icons.push_pin_outlined,
        (_) => unawaited(s.setAlwaysOnTop(!s.alwaysOnTop)),
      ),
    PaletteCommand('Settings', Icons.settings_outlined, settings),
    for (final c in s.canvasList)
      PaletteCommand(
        'Open mindmap: ${c.title}',
        Icons.hub_outlined,
        (_) => unawaited(s.openCanvas(c.id)),
      ),
    for (final n in recent.take(10))
      PaletteCommand(
        'Open note: ${n.displayTitle}',
        Icons.description_outlined,
        (_) => s.openNote(n.id),
      ),
  ];
}

/// [commands] whose label contains every word of [query].
List<PaletteCommand> filterCommands(
  List<PaletteCommand> commands,
  String query,
) {
  final words = query.toLowerCase().split(' ').where((w) => w.isNotEmpty);
  return [
    for (final c in commands)
      if (words.every(c.label.toLowerCase().contains)) c,
  ];
}

Future<void> showCommandPalette(
  BuildContext context,
  List<PaletteCommand> commands,
) async {
  final chosen = await showAppDialog<PaletteCommand>(
    context: context,
    builder: (_) => _Palette(commands: commands),
  );
  if (chosen != null && context.mounted) chosen.run(context);
}

class _Palette extends StatefulWidget {
  const _Palette({required this.commands});

  final List<PaletteCommand> commands;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  String _query = '';
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final shown = filterCommands(widget.commands, _query);
    final index = shown.isEmpty ? 0 : _index.clamp(0, shown.length - 1);
    return Dialog(
      alignment: const Alignment(0, -0.6),
      child: SizedBox(
        width: 560,
        height: 420,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                setState(() => _index = index + 1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                setState(() => _index = index > 0 ? index - 1 : 0),
          },
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: TextField(
                  key: const ValueKey('palette-input'),
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.keyboard_command_key, size: 18),
                    hintText: 'Type a command or a place…',
                  ),
                  onChanged: (v) => setState(() {
                    _query = v;
                    _index = 0;
                  }),
                  onSubmitted: (_) {
                    if (shown.isNotEmpty) Navigator.pop(context, shown[index]);
                  },
                ),
              ),
              Expanded(
                child: shown.isEmpty
                    ? Center(
                        child: Text(
                          'No matching command.',
                          style: TextStyle(color: AppColors.textFaint),
                        ),
                      )
                    : ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (context, i) => ListTile(
                          dense: true,
                          selected: i == index,
                          selectedTileColor: AppColors.selected,
                          leading: Icon(shown[i].icon, size: 18),
                          title: Text(shown[i].label),
                          trailing: shown[i].hint.isEmpty
                              ? null
                              : Text(
                                  shown[i].hint,
                                  style: TextStyle(
                                    fontSize: AppType.sizeMeta,
                                    color: AppColors.textFaint,
                                  ),
                                ),
                          onTap: () => Navigator.pop(context, shown[i]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
