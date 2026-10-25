// Turning selected note text into a task, subtask, project or note. The
// user sees what will be created first; an existing record with the same
// name is offered instead of making a duplicate; the selected text itself
// is never removed or changed.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/task_models.dart';

enum ConversionTarget { task, subtask, project, note }

extension ConversionTargetInfo on ConversionTarget {
  String get label => switch (this) {
    ConversionTarget.task => 'Task',
    ConversionTarget.subtask => 'Subtask',
    ConversionTarget.project => 'Project',
    ConversionTarget.note => 'Note',
  };

  IconData get icon => switch (this) {
    ConversionTarget.task => Icons.check_box_outlined,
    ConversionTarget.subtask => Icons.subdirectory_arrow_right,
    ConversionTarget.project => Icons.folder_special_outlined,
    ConversionTarget.note => Icons.description_outlined,
  };
}

/// What a conversion will create: a title from the first line, the rest
/// as details.
({String title, String details}) splitSelection(String text) {
  final lines = text.trim().split('\n');
  var title = lines.first.trim().replaceFirst(RegExp(r'^[-*•]\s*'), '');
  if (title.length > 120) title = '${title.substring(0, 117)}…';
  return (title: title, details: lines.skip(1).join('\n').trim());
}

/// Creates (after the user confirms) a [target] from [text] selected in
/// note [sourceNoteId]. Returns the new or reused record's id, or null if
/// cancelled.
Future<String?> convertSelection(
  BuildContext context,
  AppState s,
  String sourceNoteId,
  String text,
  ConversionTarget target,
) async {
  final ws = s.workspace;
  final source = ws.notes[sourceNoteId];
  final (:title, :details) = splitSelection(text);
  if (title.isEmpty || source == null) return null;
  final lower = title.toLowerCase();
  final existingTask = ws.tasks.all
      .where((t) => !t.done && t.title.toLowerCase() == lower)
      .firstOrNull;
  final existingProject = ws.projects.all
      .where((p) => !p.archived && p.name.toLowerCase() == lower)
      .firstOrNull;
  final existingNote = ws.notes.all
      .where(
        (n) => n.id != sourceNoteId && n.displayTitle.toLowerCase() == lower,
      )
      .firstOrNull;
  final duplicate = switch (target) {
    ConversionTarget.task || ConversionTarget.subtask => existingTask != null,
    ConversionTarget.project => existingProject != null,
    ConversionTarget.note => existingNote != null,
  };
  final parents =
      ws.tasks.all.where((t) => !t.done && t.parentId == null).toList()
        ..sort((a, b) => a.title.compareTo(b.title));
  String? parentId = parents.firstOrNull?.id;
  if (target == ConversionTarget.subtask && parents.isEmpty) {
    s.showToast('There is no open task to add a subtask to yet.');
    return null;
  }

  final choice = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(
          'Create a ${target.label.toLowerCase()}',
          style: const TextStyle(fontSize: 16),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            key: const ValueKey('conversion-preview'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  details,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                ),
              ],
              const SizedBox(height: Space.md),
              if (target == ConversionTarget.subtask)
                DropdownButton<String>(
                  isExpanded: true,
                  value: parentId,
                  items: [
                    for (final p in parents)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text('Under: ${p.title}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => parentId = v),
                ),
              Text(switch (target) {
                ConversionTarget.task ||
                ConversionTarget.subtask => 'It will be linked to this note.',
                ConversionTarget.project =>
                  'This note will be added to the project.',
                ConversionTarget.note =>
                  'A new note; this note keeps its text.',
              }, style: TextStyle(fontSize: 12, color: AppColors.textFaint)),
              if (duplicate) ...[
                const SizedBox(height: Space.sm),
                Text(
                  'A ${target == ConversionTarget.subtask ? 'task' : target.label.toLowerCase()} '
                  'with this name already exists.',
                  style: TextStyle(fontSize: 13, color: AppColors.warm),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (duplicate)
            TextButton(
              key: const ValueKey('conversion-use-existing'),
              onPressed: () => Navigator.pop(context, 'existing'),
              child: const Text('Use the existing one'),
            ),
          TextButton(
            key: const ValueKey('conversion-create'),
            onPressed: () => Navigator.pop(context, 'create'),
            child: Text(duplicate ? 'Create anyway' : 'Create'),
          ),
        ],
      ),
    ),
  );
  if (choice == null) return null;
  final useExisting = choice == 'existing';

  switch (target) {
    case ConversionTarget.task || ConversionTarget.subtask:
      if (useExisting) {
        final t = existingTask!;
        if (!t.noteIds.contains(sourceNoteId)) {
          ws.tasks.put(t.copyWith(noteIds: [...t.noteIds, sourceNoteId]));
        }
        s.showToast('Linked the existing task “${t.title}”.');
        return t.id;
      }
      final parent = target == ConversionTarget.subtask
          ? ws.tasks[parentId]
          : null;
      final t = ws.createTask(
        title,
        parentId: parent?.id,
        projectId: parent?.projectId ?? source.projectIds.firstOrNull,
      );
      ws.tasks.put(t.copyWith(notes: details, noteIds: [sourceNoteId]));
      s.showToast('${target.label} “$title” created.');
      return t.id;
    case ConversionTarget.project:
      final project =
          (useExisting ? existingProject : null) ??
          Project(
            id: newId(),
            name: title,
            kind: ProjectKind.project,
            updatedAt: DateTime.now(),
          );
      ws.projects.put(project);
      final note = ws.notes[sourceNoteId]!;
      if (!note.projectIds.contains(project.id)) {
        ws.notes.put(
          note.copyWith(projectIds: [...note.projectIds, project.id]),
        );
      }
      s.showToast('This note is now in project “${project.name}”.');
      return project.id;
    case ConversionTarget.note:
      if (useExisting) {
        s.showToast('“${existingNote!.displayTitle}” already exists.');
        return existingNote.id;
      }
      final n = ws.createNote(
        title: title,
        body: details,
        folderId: source.folderId,
      );
      if (source.projectIds.isNotEmpty) {
        ws.notes.put(n.copyWith(projectIds: source.projectIds));
      }
      s.showToast('Note “$title” created.');
      return n.id;
  }
}

/// The collapsible bar shown under a note's text while some is selected.
class ConversionBar extends StatelessWidget {
  const ConversionBar({
    super.key,
    required this.open,
    required this.onToggle,
    required this.onConvert,
    this.onAskAi,
  });

  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<ConversionTarget> onConvert;

  /// Shown when AI is switched on.
  final VoidCallback? onAskAi;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('conversion-bar'),
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.symmetric(horizontal: 6),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.border),
    ),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          key: const ValueKey('conversion-toggle'),
          onPressed: onToggle,
          icon: Icon(open ? Icons.chevron_left : Icons.chevron_right, size: 16),
          label: const Text('Convert selection'),
        ),
        if (open)
          for (final t in ConversionTarget.values)
            TextButton.icon(
              key: ValueKey('convert-${t.name}'),
              onPressed: () => onConvert(t),
              icon: Icon(t.icon, size: 15),
              label: Text(t.label),
            ),
        if (open && onAskAi != null)
          TextButton.icon(
            key: const ValueKey('convert-ask-ai'),
            onPressed: onAskAi,
            icon: const Icon(Icons.auto_awesome_outlined, size: 15),
            label: const Text('Ask AI'),
          ),
      ],
    ),
  );
}
