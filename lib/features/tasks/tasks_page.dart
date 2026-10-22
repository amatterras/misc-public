import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/record.dart';
import '../../data/models/task_models.dart';
import '../../data/workspace.dart';
import '../../platform/input_hints.dart';
import '../../widgets/common.dart';

sealed class TaskList {
  const TaskList();
}

enum SmartList { open, today, upcoming, exams, done }

class SmartTaskList extends TaskList {
  const SmartTaskList(this.kind);
  final SmartList kind;
}

class ProjectTaskList extends TaskList {
  const ProjectTaskList(this.projectId);
  final String projectId;
}

const priorityColors = [
  AppColors.textFaint,
  OrganizerColors.teal,
  OrganizerColors.amber,
  OrganizerColors.coral,
];
const priorityNames = ['No priority', 'Low', 'Medium', 'High'];

/// Reminder choices: minutes before the due time (date-only tasks: 09:00).
const reminderChoices = <(int?, String)>[
  (null, 'No reminder'),
  (0, 'At the due time'),
  (15, '15 minutes before'),
  (60, '1 hour before'),
  (24 * 60, '1 day before'),
];

class TasksPage extends StatefulWidget {
  const TasksPage({super.key, required this.state});

  final AppState state;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  /// Below this width only one of list and details is shown.
  static const narrowWidth = 700.0;

  TaskList _list = const SmartTaskList(SmartList.open);
  String? _selectedId;
  final _newTask = TextEditingController();

  AppState get s => widget.state;
  Workspace get ws => s.workspace;

  @override
  void dispose() {
    _newTask.dispose();
    super.dispose();
  }

  bool _inList(Task t) {
    if (t.parentId != null) return false; // subtasks show under their parent
    final today = dateOnly(DateTime.now());
    switch (_list) {
      case SmartTaskList(:final kind):
        return switch (kind) {
          SmartList.open => !t.done,
          SmartList.today =>
            !t.done && t.dueDate != null && daysBetween(t.dueDate!, today) >= 0,
          SmartList.upcoming =>
            !t.done && t.dueDate != null && daysBetween(today, t.dueDate!) > 0,
          SmartList.exams => t.isExam && !t.done,
          SmartList.done => t.done,
        };
      case ProjectTaskList(:final projectId):
        return t.projectId == projectId && !t.done;
    }
  }

  void _add() {
    final title = _newTask.text.trim();
    if (title.isEmpty) return;
    final list = _list;
    final today = dateOnly(DateTime.now());
    final task = ws.createTask(
      title,
      projectId: list is ProjectTaskList ? list.projectId : null,
      dueDate: list is SmartTaskList && list.kind == SmartList.today
          ? today
          : null,
      isExam: list is SmartTaskList && list.kind == SmartList.exams,
    );
    _newTask.clear();
    setState(() => _selectedId = task.id);
  }

  Future<void> _newProject(ProjectKind kind) async {
    final name = await promptText(
      context,
      title: kind == ProjectKind.subject ? 'New study subject' : 'New project',
      action: 'Create',
    );
    if (name == null) return;
    final p = Project(
      id: newId(),
      name: name,
      kind: kind,
      updatedAt: DateTime.now(),
      colorIndex: kind == ProjectKind.subject ? 6 : 5,
    );
    ws.projects.put(p);
    setState(() => _list = ProjectTaskList(p.id));
  }

  @override
  Widget build(BuildContext context) {
    final requested = s.selectedTaskId;
    if (requested != null) {
      _selectedId = requested;
      s.selectedTaskId = null;
      final t = ws.tasks[requested];
      if (t != null && !_inList(t)) {
        _list = t.done
            ? const SmartTaskList(SmartList.done)
            : const SmartTaskList(SmartList.open);
      }
    }
    return WorkspaceBuilder(
      state: s,
      // Side panels shrink in narrow windows so the task list keeps room.
      // Below [narrowWidth] the selected task's details replace the list
      // (close them to go back) instead of squeezing three columns.
      builder: (context) => LayoutBuilder(
        builder: (context, box) {
          final selected = ws.tasks[_selectedId] != null;
          Widget detail() => TaskDetail(
            key: ValueKey(_selectedId),
            state: s,
            taskId: _selectedId!,
            onClose: () => setState(() => _selectedId = null),
          );
          if (box.maxWidth < narrowWidth && selected) return detail();
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: (box.maxWidth * 0.22).clamp(110, 230),
                child: _lists(),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _tasks()),
              if (selected) ...[
                const VerticalDivider(width: 1),
                SizedBox(
                  width: (box.maxWidth * 0.34).clamp(200, 380),
                  child: detail(),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _lists() {
    Widget item(
      String label,
      IconData icon,
      TaskList list, {
      int? count,
      Color? color,
    }) {
      final selected = switch ((list, _list)) {
        (SmartTaskList(kind: final a), SmartTaskList(kind: final b)) => a == b,
        (
          ProjectTaskList(projectId: final a),
          ProjectTaskList(projectId: final b),
        ) =>
          a == b,
        _ => false,
      };
      return Material(
        color: selected ? AppColors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _list = list),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color:
                      color ??
                      (selected ? AppColors.text : AppColors.textMuted),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected ? AppColors.text : AppColors.textMuted,
                    ),
                  ),
                ),
                if (count != null && count > 0)
                  Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textFaint,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    int countOf(bool Function(Task) test) =>
        ws.tasks.all.where((t) => t.parentId == null && test(t)).length;
    final today = dateOnly(DateTime.now());
    final projects =
        ws.projects.all
            .where((p) => !p.archived && p.kind == ProjectKind.project)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final subjects =
        ws.projects.all
            .where((p) => !p.archived && p.kind == ProjectKind.subject)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

    Widget section(String title, VoidCallback onAdd, String tip) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 18, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 0.6,
                color: AppColors.textFaint,
              ),
            ),
          ),
          GhostIconButton(
            icon: Icons.add,
            tooltip: tip,
            size: 16,
            onTap: onAdd,
          ),
        ],
      ),
    );

    Widget projectItem(Project p) => GestureDetector(
      onSecondaryTapUp: (d) => _projectMenu(p, d.globalPosition),
      // Touch: press and hold (there is no other way to these options).
      onLongPressStart: (d) => _projectMenu(p, d.globalPosition),
      child: item(
        p.name,
        p.kind == ProjectKind.subject
            ? Icons.school_outlined
            : Icons.folder_special_outlined,
        ProjectTaskList(p.id),
        color: organizerColor(p.colorIndex),
        count: countOf((t) => !t.done && t.projectId == p.id),
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(Space.md),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(10, 20, 10, 12),
          child: Text(
            'Tasks',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
        ),
        item(
          'All open',
          Icons.inbox_outlined,
          const SmartTaskList(SmartList.open),
          count: countOf((t) => !t.done),
        ),
        item(
          'Today & overdue',
          Icons.today_outlined,
          const SmartTaskList(SmartList.today),
          count: countOf(
            (t) =>
                !t.done &&
                t.dueDate != null &&
                daysBetween(t.dueDate!, today) >= 0,
          ),
        ),
        item(
          'Upcoming',
          Icons.event_outlined,
          const SmartTaskList(SmartList.upcoming),
        ),
        item(
          'Exams',
          Icons.school_outlined,
          const SmartTaskList(SmartList.exams),
          count: countOf((t) => t.isExam && !t.done),
        ),
        item(
          'Completed',
          Icons.check_circle_outline,
          const SmartTaskList(SmartList.done),
        ),
        section(
          'PROJECTS',
          () => _newProject(ProjectKind.project),
          'New project',
        ),
        for (final p in projects) projectItem(p),
        section(
          'STUDY SUBJECTS',
          () => _newProject(ProjectKind.subject),
          'New subject',
        ),
        for (final p in subjects) projectItem(p),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 24, 10, 0),
          child: Text(
            touchFirst
                ? 'Press and hold a project to rename or archive it.'
                : 'Right-click a project to rename or archive it.',
            style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
          ),
        ),
      ],
    );
  }

  Future<void> _projectMenu(Project p, Offset at) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(value: 'rename', height: 36, child: Text('Rename')),
        PopupMenuItem(value: 'color', height: 36, child: Text('Change colour')),
        PopupMenuItem(value: 'archive', height: 36, child: Text('Archive')),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'rename':
        final name = await promptText(
          context,
          title: 'Rename',
          initial: p.name,
        );
        if (name != null) ws.projects.put(p.copyWith(name: name));
      case 'color':
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Colour', style: TextStyle(fontSize: 16)),
            content: ColorPicker(
              value: p.colorIndex,
              onChanged: (i) {
                ws.projects.put(p.copyWith(colorIndex: i));
                Navigator.pop(context);
              },
            ),
          ),
        );
      case 'archive':
        ws.projects.put(p.copyWith(archived: true));
        setState(() => _list = const SmartTaskList(SmartList.open));
    }
  }

  String get _title => switch (_list) {
    SmartTaskList(:final kind) => switch (kind) {
      SmartList.open => 'All open tasks',
      SmartList.today => 'Today & overdue',
      SmartList.upcoming => 'Upcoming',
      SmartList.exams => 'Exams',
      SmartList.done => 'Completed',
    },
    ProjectTaskList(:final projectId) =>
      ws.projects[projectId]?.name ?? 'Project',
  };

  Widget _tasks() {
    final tasks = ws.tasks.all.where(_inList).toList()
      ..sort((a, b) {
        if (a.done != b.done) return a.done ? 1 : -1;
        final ad = a.dueDate, bd = b.dueDate;
        if (ad != null && bd != null && daysBetween(bd, ad) != 0) {
          return daysBetween(bd, ad);
        }
        if ((ad == null) != (bd == null)) return ad == null ? 1 : -1;
        if (a.priority != b.priority) return b.priority.compareTo(a.priority);
        return a.createdAt.compareTo(b.createdAt);
      });
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xxl, 40, Space.xxl, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: Space.md,
            runSpacing: Space.sm,
            children: [
              Text(
                _title,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                ),
              ),
              FocusTimerCard(state: s),
            ],
          ),
          const SizedBox(height: Space.xl),
          TextField(
            controller: _newTask,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.add, size: 18),
              hintText: 'Add a task and press Enter',
            ),
            onSubmitted: (_) => _add(),
          ),
          const SizedBox(height: Space.md),
          Expanded(
            child: tasks.isEmpty
                ? const Center(
                    child: Text(
                      'Nothing here.',
                      style: TextStyle(color: AppColors.textFaint),
                    ),
                  )
                : ListView(
                    children: [
                      for (final t in tasks)
                        TaskRow(
                          state: s,
                          task: t,
                          selected: t.id == _selectedId,
                          onTap: () => setState(() => _selectedId = t.id),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class TaskRow extends StatelessWidget {
  const TaskRow({
    super.key,
    required this.state,
    required this.task,
    this.selected = false,
    this.onTap,
    this.compact = false,
  });

  final AppState state;
  final Task task;
  final bool selected;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ws = state.workspace;
    final t = task;
    final project = ws.projects[t.projectId];
    final subtasks = ws.tasks.all.where((s) => s.parentId == t.id).toList();
    final today = dateOnly(DateTime.now());
    final overdue =
        !t.done && t.dueDate != null && daysBetween(t.dueDate!, today) > 0;
    return Material(
      color: selected ? AppColors.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 4,
            vertical: compact ? 0 : 2,
          ),
          child: Row(
            children: [
              Checkbox(
                value: t.done,
                activeColor: priorityColors[t.priority],
                side: BorderSide(color: priorityColors[t.priority], width: 1.5),
                onChanged: (_) => ws.toggleTask(t.id),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.isExam ? 'Exam: ${t.title}' : t.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        decoration: t.done ? TextDecoration.lineThrough : null,
                        color: t.done ? AppColors.textFaint : AppColors.text,
                        fontWeight: t.isExam
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    if (!compact &&
                        (project != null ||
                            subtasks.isNotEmpty ||
                            t.recurrence != Recurrence.none))
                      Text(
                        [
                          if (project != null) project.name,
                          if (subtasks.isNotEmpty)
                            '${subtasks.where((s) => s.done).length}/${subtasks.length} subtasks',
                          if (t.recurrence != Recurrence.none)
                            'repeats ${t.recurrence.name}',
                        ].join('  ·  '),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textFaint,
                        ),
                      ),
                  ],
                ),
              ),
              if (t.dueDate != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    daysBetween(today, t.dueDate!) == 0
                        ? 'Today'
                        : formatShortDate(t.dueDate!),
                    style: TextStyle(
                      fontSize: 12,
                      color: overdue ? AppColors.danger : AppColors.textMuted,
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

class TaskDetail extends StatefulWidget {
  const TaskDetail({
    super.key,
    required this.state,
    required this.taskId,
    required this.onClose,
  });

  final AppState state;
  final String taskId;
  final VoidCallback onClose;

  @override
  State<TaskDetail> createState() => _TaskDetailState();
}

class _TaskDetailState extends State<TaskDetail> {
  late final Task _initial = widget.state.workspace.tasks[widget.taskId]!;
  late final _title = TextEditingController(text: _initial.title);
  late final _notes = TextEditingController(text: _initial.notes);
  final _sub = TextEditingController();

  Workspace get ws => widget.state.workspace;
  Task? get task => ws.tasks[widget.taskId];

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _sub.dispose();
    super.dispose();
  }

  void _update(Task Function(Task) change) {
    final t = task;
    if (t != null) ws.tasks.put(change(t));
  }

  @override
  Widget build(BuildContext context) {
    final t = task;
    if (t == null) return const SizedBox.shrink();
    syncText(this, _title, t.title);
    syncText(this, _notes, t.notes);
    final subtasks = ws.tasks.all.where((s) => s.parentId == t.id).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final projects =
        ws.projects.all
            .where((p) => !p.archived || p.id == t.projectId)
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    return ListView(
      padding: const EdgeInsets.all(Space.xl),
      children: [
        Row(
          children: [
            const Spacer(),
            GhostIconButton(
              icon: Icons.delete_outline,
              tooltip: 'Delete task',
              onTap: () async {
                final ok = await confirm(
                  context,
                  title: 'Delete “${t.title}”?',
                  message: 'Its subtasks are deleted too.',
                );
                if (ok) {
                  ws.deleteTask(t.id);
                  widget.onClose();
                }
              },
            ),
            GhostIconButton(
              icon: Icons.close,
              tooltip: 'Close',
              onTap: widget.onClose,
            ),
          ],
        ),
        TextField(
          controller: _title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          maxLines: null,
          decoration: const InputDecoration(
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
          ),
          onChanged: (v) => _update((x) => x.copyWith(title: v)),
        ),
        const SizedBox(height: Space.md),
        LabeledField(
          label: 'Due',
          child: Row(
            children: [
              // The long date may not fit a narrow panel: it shortens.
              Flexible(
                child: TextButton.icon(
                  icon: const Icon(Icons.event, size: 16),
                  label: Text(
                    t.dueDate == null ? 'No date' : formatLongDate(t.dueDate!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: t.dueDate ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) _update((x) => x.copyWith(dueDate: () => d));
                  },
                ),
              ),
              if (t.dueDate != null)
                GhostIconButton(
                  icon: Icons.close,
                  tooltip: 'Remove date',
                  size: 14,
                  onTap: () => _update(
                    (x) =>
                        x.copyWith(dueDate: () => null, dueMinutes: () => null),
                  ),
                ),
            ],
          ),
        ),
        if (t.dueDate != null)
          LabeledField(
            label: 'Time',
            child: Row(
              children: [
                TextButton(
                  onPressed: () async {
                    final m = t.dueMinutes;
                    final time = await showTimePicker(
                      context: context,
                      initialTime: m == null
                          ? const TimeOfDay(hour: 9, minute: 0)
                          : TimeOfDay(hour: m ~/ 60, minute: m % 60),
                    );
                    if (time != null) {
                      _update(
                        (x) => x.copyWith(
                          dueMinutes: () => time.hour * 60 + time.minute,
                        ),
                      );
                    }
                  },
                  child: Text(
                    t.dueMinutes == null
                        ? 'Any time'
                        : '${(t.dueMinutes! ~/ 60).toString().padLeft(2, '0')}:${(t.dueMinutes! % 60).toString().padLeft(2, '0')}',
                  ),
                ),
                if (t.dueMinutes != null)
                  GhostIconButton(
                    icon: Icons.close,
                    tooltip: 'Any time',
                    size: 14,
                    onTap: () =>
                        _update((x) => x.copyWith(dueMinutes: () => null)),
                  ),
              ],
            ),
          ),
        if (t.dueDate != null)
          const Padding(
            padding: EdgeInsets.only(left: 96, bottom: 4),
            child: Text(
              'Shown on Calendar on this date.',
              style: TextStyle(fontSize: 11, color: AppColors.textFaint),
            ),
          ),
        LabeledField(
          label: 'Reminder',
          child: DropdownButton<int?>(
            key: const ValueKey('reminder'),
            isExpanded: true,
            value: t.remindBefore,
            // A reminder needs a date to count from.
            onChanged: t.dueDate == null
                ? null
                : (v) => _update((x) => x.copyWith(remindBefore: () => v)),
            disabledHint: const Text('Set a due date first'),
            items: [
              for (final (minutes, label) in reminderChoices)
                DropdownMenuItem(value: minutes, child: Text(label)),
            ],
          ),
        ),
        LabeledField(
          label: 'Repeat',
          child: DropdownButton<Recurrence>(
            isExpanded: true,
            value: t.recurrence,
            items: [
              for (final r in Recurrence.values)
                DropdownMenuItem(
                  value: r,
                  child: Text(
                    r == Recurrence.none
                        ? 'Does not repeat'
                        : 'Every ${switch (r) {
                            Recurrence.daily => 'day',
                            Recurrence.weekly => 'week',
                            Recurrence.monthly => 'month',
                            Recurrence.none => '',
                          }}',
                  ),
                ),
            ],
            onChanged: (v) => _update((x) => x.copyWith(recurrence: v)),
          ),
        ),
        LabeledField(
          label: 'Priority',
          child: Wrap(
            spacing: 4,
            children: [
              for (var p = 0; p < 4; p++)
                ChoiceChip(
                  label: Text(
                    priorityNames[p],
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: t.priority == p,
                  avatar: Icon(Icons.flag, size: 14, color: priorityColors[p]),
                  onSelected: (_) => _update((x) => x.copyWith(priority: p)),
                ),
            ],
          ),
        ),
        LabeledField(
          label: 'Project',
          child: DropdownButton<String?>(
            isExpanded: true,
            value: ws.projects.contains(t.projectId ?? '') ? t.projectId : null,
            items: [
              const DropdownMenuItem(value: null, child: Text('None')),
              for (final p in projects)
                DropdownMenuItem(
                  value: p.id,
                  child: Text(
                    '${p.kind == ProjectKind.subject ? 'Subject' : 'Project'}: ${p.name}',
                  ),
                ),
            ],
            onChanged: (v) => _update((x) => x.copyWith(projectId: () => v)),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: t.isExam,
          title: const Text('This is an exam', style: TextStyle(fontSize: 13)),
          subtitle: const Text(
            'Add revision tasks as subtasks below.',
            style: TextStyle(fontSize: 11, color: AppColors.textFaint),
          ),
          onChanged: (v) => _update((x) => x.copyWith(isExam: v)),
        ),
        const SizedBox(height: Space.md),
        Text(
          t.isExam ? 'REVISION TASKS' : 'SUBTASKS',
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 0.6,
            color: AppColors.textFaint,
          ),
        ),
        for (final sub in subtasks)
          Row(
            children: [
              Expanded(
                child: TaskRow(state: widget.state, task: sub, compact: true),
              ),
              GhostIconButton(
                icon: Icons.event,
                tooltip: sub.dueDate == null
                    ? 'Schedule'
                    : 'Due ${formatShortDate(sub.dueDate!)}',
                size: 14,
                active: sub.dueDate != null,
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: sub.dueDate ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) ws.tasks.put(sub.copyWith(dueDate: () => d));
                },
              ),
              GhostIconButton(
                icon: Icons.close,
                tooltip: 'Delete',
                size: 14,
                onTap: () => ws.deleteTask(sub.id),
              ),
            ],
          ),
        TextField(
          controller: _sub,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            hintText: '+ Add subtask',
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
          ),
          onSubmitted: (v) {
            if (v.trim().isEmpty) return;
            ws.createTask(v.trim(), parentId: t.id, projectId: t.projectId);
            _sub.clear();
          },
        ),
        const SizedBox(height: Space.md),
        TextField(
          controller: _notes,
          minLines: 3,
          maxLines: 10,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'Notes, preparation materials…',
          ),
          onChanged: (v) => _update((x) => x.copyWith(notes: v)),
        ),
        const SizedBox(height: Space.md),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final a in assetsFor(widget.state, t.assetIds))
              AssetChip(
                workspace: ws,
                asset: a,
                onRemove: () => _update(
                  (x) => x.copyWith(assetIds: [...x.assetIds]..remove(a.id)),
                ),
              ),
            TextButton.icon(
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 15),
              label: const Text('Attach photos'),
              onPressed: () async {
                final assets = await widget.state.capture.pickImages();
                _update(
                  (x) => x.copyWith(
                    assetIds: [...x.assetIds, ...assets.map((a) => a.id)],
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: Space.lg),
        OutlinedButton.icon(
          onPressed: () {
            widget.state.timer
              ..taskId = t.id
              ..reset()
              ..start();
          },
          icon: const Icon(Icons.timer_outlined, size: 16),
          label: const Text('Focus on this task'),
        ),
      ],
    );
  }
}

class FocusTimerCard extends StatelessWidget {
  const FocusTimerCard({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final timer = state.timer;
    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) {
        final task = state.workspace.tasks[timer.taskId];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    timer.onBreak ? 'BREAK' : 'FOCUS',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 0.6,
                      color: timer.onBreak
                          ? OrganizerColors.green
                          : AppColors.textFaint,
                    ),
                  ),
                  Text(
                    timer.label,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (task != null)
                    SizedBox(
                      width: 140,
                      child: Text(
                        task.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: Space.md),
              GhostIconButton(
                icon: timer.running ? Icons.pause : Icons.play_arrow,
                tooltip: timer.running ? 'Pause' : 'Start',
                onTap: timer.running ? timer.pause : timer.start,
              ),
              GhostIconButton(
                icon: Icons.replay,
                tooltip: 'Reset',
                onTap: () => timer.reset(),
              ),
            ],
          ),
        );
      },
    );
  }
}
