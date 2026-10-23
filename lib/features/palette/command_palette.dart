// The command palette (Ctrl+Shift+P, or the ⌘ button): find and run any
// app command or open any place by typing. Different from the right-click
// menus, which only offer actions for what was clicked.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/input_hints.dart';
import '../../widgets/common.dart';

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
    PaletteCommand(
      'Go to start page',
      Icons.wb_sunny_outlined,
      (_) => s.goTo(AppPage.home),
    ),
    PaletteCommand('Show tasks', Icons.checklist, (_) => s.goTo(AppPage.tasks)),
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
    PaletteCommand('New task', Icons.add_task, (context) async {
      final title = await promptText(context, title: 'New task', action: 'Add');
      if (title == null) return;
      final t = ws.createTask(title);
      s.openTask(t.id);
    }),
    PaletteCommand('App switcher (floating)', Icons.apps, appSwitcher),
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
    PaletteCommand(
      s.sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar',
      Icons.view_sidebar_outlined,
      (_) => s.toggleSidebar(),
    ),
    if (s.alwaysOnTopSupported)
      PaletteCommand(
        s.alwaysOnTop ? 'Stop keeping THEapp on top' : 'Keep THEapp on top',
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
  final chosen = await showDialog<PaletteCommand>(
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
                padding: const EdgeInsets.all(Space.md),
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
                    ? const Center(
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
                                  style: const TextStyle(
                                    fontSize: 11,
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
