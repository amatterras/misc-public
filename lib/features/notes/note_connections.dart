// What a note is connected to, in both directions: its projects, the tasks
// that link it, and the mindmaps that show a card of it. Every entry opens
// the original record; nothing is copied.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/canvas_ops.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../tasks/tasks_page.dart' show TaskRow;

class NoteConnections extends StatelessWidget {
  const NoteConnections({
    super.key,
    required this.state,
    required this.note,
    required this.onOpenNote,
  });

  final AppState state;
  final Note note;
  final ValueChanged<String> onOpenNote;

  static const _heading = TextStyle(
    fontSize: 11,
    letterSpacing: 0.6,
    color: AppColors.textFaint,
  );

  @override
  Widget build(BuildContext context) {
    final ws = state.workspace;
    final tasks = ws.tasksForNote(note.id);
    final projects = ws.projects.all.where((p) => !p.archived).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final openTasks = ws.tasks.all.where((t) => !t.done).toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    return Column(
      key: const ValueKey('note-connections'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('CONNECTIONS', style: _heading),
        const SizedBox(height: Space.sm),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final id in note.projectIds)
              if (ws.projects[id] case final p?)
                InputChip(
                  avatar: const Icon(Icons.folder_special_outlined, size: 14),
                  label: Text(p.name, style: const TextStyle(fontSize: 12)),
                  onDeleted: () => ws.notes.put(
                    note.copyWith(projectIds: [...note.projectIds]..remove(id)),
                  ),
                ),
            PopupMenuButton<String>(
              key: const ValueKey('note-add-project'),
              tooltip: 'Add this note to a project or subject',
              onSelected: (id) => ws.notes.put(
                note.copyWith(projectIds: [...note.projectIds, id]),
              ),
              itemBuilder: (_) => [
                for (final p in projects)
                  if (!note.projectIds.contains(p.id))
                    PopupMenuItem(value: p.id, child: Text(p.name)),
              ],
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Text('+ Project', style: TextStyle(fontSize: 12)),
              ),
            ),
            PopupMenuButton<String>(
              key: const ValueKey('note-link-task'),
              tooltip: 'Link a task to this note',
              onSelected: (id) {
                if (id == '+new') {
                  final t = ws.createTask(
                    note.displayTitle,
                    projectId: note.projectIds.firstOrNull,
                  );
                  ws.tasks.put(t.copyWith(noteIds: [note.id]));
                  state.showToast('Task “${t.title}” created for this note.');
                  return;
                }
                final t = ws.tasks[id];
                if (t != null && !t.noteIds.contains(note.id)) {
                  ws.tasks.put(t.copyWith(noteIds: [...t.noteIds, note.id]));
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: '+new',
                  child: Text('New task about this note'),
                ),
                for (final t in openTasks.take(40))
                  if (!t.noteIds.contains(note.id))
                    PopupMenuItem(value: t.id, child: Text(t.title)),
              ],
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Text('+ Task', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        for (final t in tasks)
          Row(
            children: [
              Expanded(
                child: TaskRow(
                  state: state,
                  task: t,
                  compact: true,
                  onTap: () => state.openTask(t.id),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.link_off, size: 14),
                tooltip: 'Unlink this task',
                onPressed: () => ws.tasks.put(
                  t.copyWith(noteIds: [...t.noteIds]..remove(note.id)),
                ),
              ),
            ],
          ),
        _OnMindmaps(state: state, noteId: note.id),
      ],
    );
  }
}

class _OnMindmaps extends StatefulWidget {
  const _OnMindmaps({required this.state, required this.noteId});

  final AppState state;
  final String noteId;

  @override
  State<_OnMindmaps> createState() => _OnMindmapsState();
}

class _OnMindmapsState extends State<_OnMindmaps> {
  List<CanvasSummary> _found = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final found = await widget.state.canvasesShowingNote(widget.noteId);
    if (mounted) setState(() => _found = found);
  }

  @override
  Widget build(BuildContext context) {
    if (_found.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final c in _found)
            ActionChip(
              avatar: const Icon(Icons.hub_outlined, size: 14),
              label: Text(
                'On ${c.title}',
                style: const TextStyle(fontSize: 12),
              ),
              tooltip: 'Open the mindmap',
              onPressed: () {
                Navigator.of(context).popUntil((r) => r.isFirst);
                unawaited(widget.state.openCanvas(c.id));
              },
            ),
        ],
      ),
    );
  }
}
