// The user's own templates: a note (title and text) or a project (its
// tasks, steps and due dates relative to the start). Templates are only
// ever made by the user from their own notes and projects — THEapp ships
// none, and notebook paper stays the three approved kinds. `{date}` in a
// note template becomes the day it is used.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/record.dart';
import '../../data/models/template_models.dart';
import '../../data/models/task_models.dart';
import '../../data/workspace.dart';
import '../../widgets/common.dart';

ContentTemplate noteTemplate(String name, String title, String body) =>
    ContentTemplate(
      id: newId(),
      name: name,
      kind: 'note',
      title: title,
      body: body,
      updatedAt: DateTime.now(),
    );

/// The project's tasks, parents first, with due dates relative to the
/// earliest one.
ContentTemplate projectTemplate(Workspace ws, String name, String projectId) {
  final all = ws.tasks.all.where((t) => t.projectId == projectId).toList();
  final ordered = <Task>[];
  void addLevel(String? parent) {
    for (final t in all.where((t) => t.parentId == parent)) {
      if (ordered.length >= ContentTemplate.maxTasks) return;
      ordered.add(t);
      addLevel(t.id);
    }
  }

  addLevel(null);
  final dues = [for (final t in ordered) ?t.dueDate];
  final start = dues.isEmpty
      ? null
      : dues.reduce((a, b) => a.isBefore(b) ? a : b);
  final index = {for (final (i, t) in ordered.indexed) t.id: i};
  return ContentTemplate(
    id: newId(),
    name: name,
    kind: 'project',
    title: ws.projects[projectId]?.name ?? name,
    tasks: [
      for (final t in ordered)
        (
          title: t.title,
          parent: index[t.parentId],
          dueOffset: t.dueDate == null || start == null
              ? null
              : daysBetween(start, t.dueDate!),
        ),
    ],
    updatedAt: DateTime.now(),
  );
}

String _fillDate(String s, DateTime day) =>
    s.replaceAll('{date}', formatShortDate(day));

/// A new note from [t]; returns its id.
String useNoteTemplate(Workspace ws, ContentTemplate t, {DateTime? now}) {
  final day = now ?? DateTime.now();
  return ws
      .createNote(title: _fillDate(t.title, day), body: _fillDate(t.body, day))
      .id;
}

/// A new project from [t], first due date on [start]; returns its id.
String useProjectTemplate(
  Workspace ws,
  ContentTemplate t, {
  required String name,
  required DateTime start,
}) {
  final p = Project(
    id: newId(),
    name: name,
    kind: ProjectKind.project,
    updatedAt: DateTime.now(),
  );
  ws.projects.put(p);
  final made = <String>[];
  for (final task in t.tasks) {
    final parent = task.parent != null && task.parent! < made.length
        ? made[task.parent!]
        : null;
    made.add(
      ws
          .createTask(
            task.title,
            projectId: p.id,
            parentId: parent,
            dueDate: task.dueOffset == null
                ? null
                : dateOnly(start).add(Duration(days: task.dueOffset!)),
          )
          .id,
    );
  }
  return p.id;
}

/// Picks one of the user's templates of [kind].
Future<ContentTemplate?> pickTemplate(
  BuildContext context,
  AppState s,
  String kind,
) {
  final list = s.workspace.templates.all.where((t) => t.kind == kind).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return showDialog<ContentTemplate>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(kind == 'note' ? 'Note templates' : 'Project templates'),
      children: [
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              kind == 'note'
                  ? 'None yet. Open a note and choose "Save as a template".'
                  : 'None yet. Right-click a project in Tasks and choose '
                        '"Save as a template".',
              style: TextStyle(color: AppColors.textFaint),
            ),
          ),
        for (final t in list)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, t),
            child: Row(
              children: [
                Expanded(child: Text(t.name)),
                IconButton(
                  tooltip: 'Delete template',
                  icon: const Icon(Icons.delete_outline, size: 16),
                  onPressed: () {
                    s.workspace.templates.remove(t.id);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

Future<void> newNoteFromTemplate(BuildContext context, AppState s) async {
  final t = await pickTemplate(context, s, 'note');
  if (t == null) return;
  s.openNote(useNoteTemplate(s.workspace, t));
}

Future<void> newProjectFromTemplate(BuildContext context, AppState s) async {
  final t = await pickTemplate(context, s, 'project');
  if (t == null || !context.mounted) return;
  final name = await promptText(
    context,
    title: 'Name of the new project',
    initial: t.title,
    action: 'Create',
  );
  if (name == null || name.trim().isEmpty) return;
  useProjectTemplate(s.workspace, t, name: name.trim(), start: DateTime.now());
  s.showToast('Project “${name.trim()}” made with ${t.tasks.length} tasks.');
  s.goTo(AppPage.tasks);
}
