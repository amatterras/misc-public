import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/record.dart';
import '../../data/models/task_estimate.dart';
import '../../data/models/task_models.dart';
import '../../data/workspace.dart';
import '../../platform/input_hints.dart';
import '../../widgets/common.dart';
import '../ai/ai_service.dart';
import '../ai/ai_session.dart';
import 'estimate_label.dart';
import 'smart_views.dart';
import 'task_views.dart';
import '../transfer/transfer.dart';
import '../templates/templates.dart';

sealed class TaskList {
  const TaskList();
}

/// Built-in views. Each is a condition over the same task records.
enum SmartList {
  open,
  today,
  upcoming,
  overdue,
  noDate,
  highPriority,
  waiting,
  study,
  exams,
  done,
}

class SmartTaskList extends TaskList {
  const SmartTaskList(this.kind);
  final SmartList kind;
}

class ProjectTaskList extends TaskList {
  const ProjectTaskList(this.projectId);
  final String projectId;
}

class LabelTaskList extends TaskList {
  const LabelTaskList(this.label);
  final String label;
}

/// A Smart View (built-in or saved), picked in the column's view selector.
class SmartViewTaskList extends TaskList {
  const SmartViewTaskList(this.viewId);
  final String viewId;
}

List<Color> get priorityColors => [
  AppColors.textFaint,
  AppColors.accentSecondary,
  AppColors.warm,
  AppColors.danger,
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

  /// Multi-select: picked task ids while [_selecting].
  bool _selecting = false;
  final Set<String> _picked = {};

  AppState get s => widget.state;
  Workspace get ws => s.workspace;

  /// List, board, table or Gantt (remembered on this device).
  TaskView get _view =>
      TaskView.values.asNameMap()[s.settings.get<String>('taskView')] ??
      TaskView.list;

  void _setView(TaskView v) {
    s.settings.set('taskView', v.name);
    setState(() {});
  }

  @override
  void dispose() {
    _newTask.dispose();
    super.dispose();
  }

  /// Which tasks a list shows. Completing a task never removes it from the
  /// list it is in: it stays, ticked and struck through, below the open
  /// ones (sorted in [_tasks]). It is the same record, only marked done.
  bool _inList(Task t) {
    if (t.parentId != null) return false; // subtasks show under their parent
    final today = dateOnly(DateTime.now());
    final due = t.dueDate;
    final completedToday =
        t.completedAt != null && daysBetween(t.completedAt!, today) == 0;
    switch (_list) {
      case SmartTaskList(:final kind):
        return switch (kind) {
          SmartList.open => true,
          // Done ones stay for the day they are due or were ticked off, so
          // old finished tasks do not pile up under "overdue".
          SmartList.today =>
            due != null &&
                (t.done
                    ? daysBetween(due, today) == 0 || completedToday
                    : daysBetween(due, today) >= 0),
          SmartList.upcoming => due != null && daysBetween(today, due) > 0,
          SmartList.overdue =>
            !t.done && due != null && daysBetween(due, today) > 0,
          SmartList.noDate => !t.done && due == null,
          SmartList.highPriority => !t.done && t.priority == 3,
          SmartList.waiting => !t.done && ws.openPrerequisites(t).isNotEmpty,
          // Unfinished study topics: open tasks of study subjects.
          SmartList.study =>
            !t.done && ws.projects[t.projectId]?.kind == ProjectKind.subject,
          SmartList.exams => t.isExam,
          SmartList.done => t.done,
        };
      case ProjectTaskList(:final projectId):
        return t.projectId == projectId;
      case LabelTaskList(:final label):
        return t.labels.contains(label);
      case SmartViewTaskList(:final viewId):
        return smartViewMatcher(ws, viewId, today)(t);
    }
  }

  void _add() {
    final title = _newTask.text.trim();
    if (title.isEmpty) return;
    final list = _list;
    final today = dateOnly(DateTime.now());
    final view = list is SmartViewTaskList
        ? smartViewDefaults(ws, list.viewId)
        : null;
    var task = ws.createTask(
      title,
      projectId: list is ProjectTaskList ? list.projectId : view?.projectId,
      dueDate: list is SmartTaskList && list.kind == SmartList.today
          ? today
          : null,
      isExam: list is SmartTaskList && list.kind == SmartList.exams,
    );
    if (view != null && (view.priority != null || view.labels.isNotEmpty)) {
      task = task.copyWith(priority: view.priority, labels: view.labels);
      ws.tasks.put(task);
    }
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
    // A saved view deleted (here or on another device): back to All tasks.
    final list = _list;
    if (list is SmartViewTaskList && !smartViewExists(ws, list.viewId)) {
      _list = const SmartTaskList(SmartList.open);
    }
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
        (LabelTaskList(label: final a), LabelTaskList(label: final b)) =>
          a == b,
        _ => false,
      };
      return Material(
        color: selected ? AppColors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.sm),
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
                      fontSize: AppType.sizeBodySmall,
                      color: selected ? AppColors.text : AppColors.textMuted,
                    ),
                  ),
                ),
                if (count != null && count > 0)
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: AppType.sizeMeta,
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
              style: TextStyle(
                fontSize: AppType.sizeMeta,
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

    Widget projectItem(Project p) {
      final tile = GestureDetector(
        onSecondaryTapUp: (d) => _projectMenu(p, d.globalPosition),
        // Touch: press and hold (there is no other way to these options).
        onLongPressStart: (d) => _projectMenu(p, d.globalPosition),
        // Drop a task here to move it (with its steps) into the project.
        child: TransferTarget(
          state: s,
          place: TasksPlace(projectId: p.id),
          child: item(
            p.name,
            p.kind == ProjectKind.subject
                ? Icons.school_outlined
                : Icons.folder_special_outlined,
            ProjectTaskList(p.id),
            color: AppColors.accent,
            count: countOf((t) => !t.done && t.projectId == p.id),
          ),
        ),
      );
      // With a mouse or pen the project itself can be dragged (onto a note,
      // a mindmap, a day…); on touch, press-and-hold stays its menu.
      if (touchFirst) return tile;
      return TransferSource(
        transfer: () => ProjectTransfer(p.id, p.name),
        child: tile,
      );
    }

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
          'All tasks',
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
          'Overdue',
          Icons.running_with_errors_outlined,
          const SmartTaskList(SmartList.overdue),
          count: countOf(
            (t) =>
                !t.done &&
                t.dueDate != null &&
                daysBetween(t.dueDate!, today) > 0,
          ),
        ),
        item(
          'No date',
          Icons.event_busy_outlined,
          const SmartTaskList(SmartList.noDate),
        ),
        item(
          'High priority',
          Icons.flag_outlined,
          const SmartTaskList(SmartList.highPriority),
        ),
        item(
          'Waiting on others',
          Icons.link,
          const SmartTaskList(SmartList.waiting),
          count: countOf((t) => !t.done && ws.openPrerequisites(t).isNotEmpty),
        ),
        item(
          'Study topics to do',
          Icons.menu_book_outlined,
          const SmartTaskList(SmartList.study),
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
        if (ws.taskLabels.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(10, 18, 4, 6),
            child: Text(
              'LABELS',
              style: TextStyle(
                fontSize: AppType.sizeMeta,
                letterSpacing: 0.6,
                color: AppColors.textFaint,
              ),
            ),
          ),
          for (final label in ws.taskLabels)
            item(
              label,
              Icons.label_outline,
              LabelTaskList(label),
              count: countOf((t) => !t.done && t.labels.contains(label)),
            ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 24, 10, 0),
          child: Text(
            touchFirst
                ? 'Press and hold a project to rename or archive it.'
                : 'Right-click a project to rename or archive it.',
            style: TextStyle(
              fontSize: AppType.sizeMeta,
              color: AppColors.textFaint,
            ),
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
        // Project color choices remain visible but unavailable until a
        // project palette is approved; do not reuse ink or category colors.
        PopupMenuItem(
          value: 'color',
          height: 36,
          enabled: false,
          child: Text('Change colour'),
        ),
        PopupMenuItem(
          value: 'shift',
          height: 36,
          child: Text('Shift deadlines…'),
        ),
        PopupMenuItem(
          value: 'template',
          height: 36,
          child: Text('Save as a template'),
        ),
        PopupMenuItem(value: 'archive', height: 36, child: Text('Archive')),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'template':
        final name = await promptText(
          context,
          title: 'Template name',
          initial: p.name,
          action: 'Save',
        );
        if (name != null && name.trim().isNotEmpty) {
          final t = projectTemplate(ws, name.trim(), p.id);
          ws.templates.put(t);
          s.showToast('Saved the template with ${t.tasks.length} tasks.');
        }
      case 'shift':
        final days = await askShiftDays(context);
        if (days != null) {
          final n = ws.shiftProject(p.id, days);
          s.showToast('Moved $n task(s) by ${_daysText(days)}.');
        }
      case 'rename':
        final name = await promptText(
          context,
          title: 'Rename',
          initial: p.name,
        );
        if (name != null) ws.projects.put(p.copyWith(name: name));
      case 'archive':
        ws.projects.put(p.copyWith(archived: true));
        setState(() => _list = const SmartTaskList(SmartList.open));
    }
  }

  String get _title => switch (_list) {
    SmartTaskList(:final kind) => switch (kind) {
      SmartList.open => 'All tasks',
      SmartList.today => 'Today & overdue',
      SmartList.upcoming => 'Upcoming',
      SmartList.overdue => 'Overdue',
      SmartList.noDate => 'No date',
      SmartList.highPriority => 'High priority',
      SmartList.waiting => 'Waiting on others',
      SmartList.study => 'Study topics to do',
      SmartList.exams => 'Exams',
      SmartList.done => 'Completed',
    },
    ProjectTaskList(:final projectId) =>
      ws.projects[projectId]?.name ?? 'Project',
    LabelTaskList(:final label) => label,
    SmartViewTaskList(:final viewId) => smartViewName(ws, viewId),
  };

  /// The open Smart View, or null (All tasks or a list of the side column).
  String? get _viewId => switch (_list) {
    SmartViewTaskList(:final viewId) => viewId,
    _ => null,
  };

  bool get _habitsView => BuiltInView.ofId(_viewId) == BuiltInView.todaysHabits;

  Widget _viewSelector() => SmartViewSelector(
    workspace: ws,
    current: _viewId,
    onSelect: (id) => setState(() {
      _list = id == null
          ? const SmartTaskList(SmartList.open)
          : SmartViewTaskList(id);
      _selecting = false;
      _picked.clear();
    }),
  );

  /// What an empty list says (Smart Views explain why they may be empty).
  Widget _empty() {
    final id = _viewId;
    if (id == null) {
      return Center(
        child: Text(
          'Nothing here.',
          style: TextStyle(color: AppColors.textFaint),
        ),
      );
    }
    final builtIn = BuiltInView.ofId(id);
    return SmartViewEmpty(
      title: builtIn?.emptyTitle ?? 'No tasks match this view.',
      hint:
          builtIn?.emptyHint ??
          'Tasks appear here as soon as they meet its conditions. '
              'Edit the view from the selector above.',
    );
  }

  static String _daysText(int days) =>
      '${days > 0 ? '+' : ''}$days day${days.abs() == 1 ? '' : 's'}';

  Widget _viewSwitcher() => SegmentedButton<TaskView>(
    key: const ValueKey('task-view-switcher'),
    showSelectedIcon: false,
    segments: [
      for (final v in TaskView.values)
        ButtonSegment(
          value: v,
          icon: Icon(v.icon, size: 16),
          tooltip: v.label,
          label: MediaQuery.sizeOf(context).width < 1100
              ? null
              : Text(
                  v.label,
                  style: const TextStyle(fontSize: AppType.sizeLabel),
                ),
        ),
    ],
    selected: {_view},
    onSelectionChanged: (v) => _setView(v.first),
  );

  /// Actions on the picked tasks (multi-select).
  Widget _bulkBar() {
    final ids = _picked.where(ws.tasks.contains).toList();
    Future<void> run(String what) async {
      switch (what) {
        case 'complete':
          for (final id in ids) {
            if (!(ws.tasks[id]?.done ?? true)) ws.toggleTask(id);
          }
          s.showToast('Completed ${ids.length} task(s).');
        case 'shift':
          final days = await askShiftDays(context);
          if (days == null) return;
          final n = ws.shiftTasks(ids, days);
          s.showToast('Moved $n task(s) by ${_daysText(days)}.');
        case 'label':
          final label = await promptText(
            context,
            title: 'Add a label',
            action: 'Add',
          );
          if (label == null || label.trim().isEmpty) return;
          for (final id in ids) {
            final t = ws.tasks[id]!;
            if (!t.labels.contains(label.trim())) {
              ws.tasks.put(t.copyWith(labels: [...t.labels, label.trim()]));
            }
          }
        case 'delete':
          if (!mounted) return;
          final ok = await confirm(
            context,
            title: 'Delete ${ids.length} task(s)?',
            message: 'Their subtasks are deleted too.',
          );
          if (!ok) return;
          for (final id in ids) {
            ws.deleteTask(id);
          }
          _picked.clear();
        default:
          if (what.startsWith('priority:')) {
            final p = int.parse(what.substring(9));
            for (final id in ids) {
              ws.tasks.put(ws.tasks[id]!.copyWith(priority: p));
            }
          } else if (what.startsWith('project:')) {
            final pid = what.substring(8);
            for (final id in ids) {
              ws.tasks.put(
                ws.tasks[id]!.copyWith(
                  projectId: () => pid.isEmpty ? null : pid,
                ),
              );
            }
          }
      }
      if (mounted) setState(() {});
    }

    final projects = ws.projects.all.where((p) => !p.archived).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Container(
      key: const ValueKey('task-bulk-bar'),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text(
            '${ids.length} selected',
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              color: AppColors.textMuted,
            ),
          ),
          TextButton(
            onPressed: ids.isEmpty ? null : () => run('complete'),
            child: const Text('Complete'),
          ),
          TextButton(
            key: const ValueKey('bulk-shift'),
            onPressed: ids.isEmpty ? null : () => run('shift'),
            child: const Text('Shift dates…'),
          ),
          TextButton(
            onPressed: ids.isEmpty ? null : () => run('label'),
            child: const Text('Add label…'),
          ),
          PopupMenuButton<String>(
            enabled: ids.isNotEmpty,
            tooltip: 'Priority',
            onSelected: run,
            itemBuilder: (_) => [
              for (var p = 0; p < 4; p++)
                PopupMenuItem(
                  value: 'priority:$p',
                  child: Text(priorityNames[p]),
                ),
            ],
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Priority ▾',
                style: TextStyle(fontSize: AppType.sizeBodySmall),
              ),
            ),
          ),
          PopupMenuButton<String>(
            enabled: ids.isNotEmpty,
            tooltip: 'Project',
            onSelected: run,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'project:', child: Text('No project')),
              for (final p in projects)
                PopupMenuItem(value: 'project:${p.id}', child: Text(p.name)),
            ],
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Project ▾',
                style: TextStyle(fontSize: AppType.sizeBodySmall),
              ),
            ),
          ),
          TextButton(
            onPressed: ids.isEmpty ? null : () => run('delete'),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Widget _tasks() {
    final viewId = _viewId;
    final test = viewId == null
        ? _inList
        : smartViewMatcher(ws, viewId, DateTime.now());
    final habits = _habitsView;
    final tasks = ws.tasks.all.where(test).toList()
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
              // The title names the open view; the small control beside it
              // switches Smart Views.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      _title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _viewSelector(),
                ],
              ),
              FocusTimerCard(state: s),
            ],
          ),
          const SizedBox(height: Space.md),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!habits) _viewSwitcher(),
              if (_view == TaskView.list && !habits)
                TextButton.icon(
                  key: const ValueKey('task-select-toggle'),
                  onPressed: () => setState(() {
                    _selecting = !_selecting;
                    _picked.clear();
                  }),
                  icon: Icon(
                    _selecting ? Icons.close : Icons.checklist,
                    size: 16,
                  ),
                  label: Text(_selecting ? 'Done selecting' : 'Select'),
                ),
            ],
          ),
          if (_selecting && _view == TaskView.list && !habits) ...[
            const SizedBox(height: Space.sm),
            _bulkBar(),
          ],
          const SizedBox(height: Space.md),
          if (!habits) ...[
            TextField(
              controller: _newTask,
              style: const TextStyle(fontSize: AppType.sizeBody),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.add, size: 18),
                hintText: 'Add a task and press Enter',
              ),
              onSubmitted: (_) => _add(),
            ),
            const SizedBox(height: Space.md),
          ],
          if (habits)
            Expanded(
              child: TodaysHabitsList(workspace: ws, today: DateTime.now()),
            )
          else
            Expanded(
              child: TransferTarget(
                state: s,
                place: TasksPlace(
                  projectId: _list is ProjectTaskList
                      ? (_list as ProjectTaskList).projectId
                      : null,
                ),
                child: tasks.isEmpty
                    ? _empty()
                    : switch (_view) {
                        TaskView.list => ListView(
                          children: [
                            for (final t in tasks)
                              Row(
                                children: [
                                  if (_selecting)
                                    Checkbox(
                                      key: ValueKey('pick-${t.id}'),
                                      value: _picked.contains(t.id),
                                      onChanged: (on) => setState(
                                        () => on == true
                                            ? _picked.add(t.id)
                                            : _picked.remove(t.id),
                                      ),
                                    ),
                                  Expanded(
                                    child: TaskRow(
                                      state: s,
                                      task: t,
                                      selected: t.id == _selectedId,
                                      onTap: () => setState(() {
                                        if (_selecting) {
                                          _picked.contains(t.id)
                                              ? _picked.remove(t.id)
                                              : _picked.add(t.id);
                                        } else {
                                          _selectedId = t.id;
                                        }
                                      }),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                        TaskView.board => TaskBoardView(
                          state: s,
                          tasks: tasks,
                          onOpen: (id) => setState(() => _selectedId = id),
                        ),
                        TaskView.table => TaskTableView(
                          state: s,
                          tasks: tasks,
                          onOpen: (id) => setState(() => _selectedId = id),
                        ),
                        TaskView.gantt => TaskGanttView(
                          state: s,
                          tasks: tasks,
                          onOpen: (id) => setState(() => _selectedId = id),
                        ),
                      },
              ),
            ),
        ],
      ),
    );
  }
}

/// Asks how many days to move dates by (negative = earlier).
Future<int?> askShiftDays(BuildContext context) async {
  final text = await promptText(
    context,
    title: 'Move dates by how many days? (e.g. 3 or -2)',
    action: 'Move',
  );
  final days = int.tryParse(text?.trim().replaceFirst('+', '') ?? '');
  return days == null || days == 0 ? null : days;
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
    final waiting = t.done ? const <Task>[] : ws.openPrerequisites(t);
    final row = Material(
      color: selected ? AppColors.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadii.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.sm),
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
                // Done: a clear green tick, whatever the priority colour.
                activeColor: AppColors.success,
                checkColor: AppColors.text,
                side: BorderSide(color: priorityColors[t.priority], width: 1.5),
                onChanged: (_) => state.toggleTask(t.id),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.isExam ? 'Exam: ${t.title}' : t.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.sizeBody,
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
                            t.labels.isNotEmpty ||
                            waiting.isNotEmpty ||
                            t.recurrence != Recurrence.none))
                      Text(
                        [
                          if (project != null) project.name,
                          if (subtasks.isNotEmpty)
                            '${subtasks.where((s) => s.done).length}/${subtasks.length} subtasks',
                          if (t.recurrence != Recurrence.none)
                            'repeats ${t.recurrence.name}',
                          ...t.labels,
                          if (waiting.isNotEmpty)
                            'waits for ${waiting.first.title}${waiting.length > 1 ? ' +${waiting.length - 1}' : ''}',
                        ].join('  ·  '),
                        style: TextStyle(
                          fontSize: AppType.sizeMeta,
                          color: AppColors.textFaint,
                        ),
                      ),
                  ],
                ),
              ),
              if (t.estimateMinutes != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: EstimateLabel(task: t),
                ),
              if (t.dueDate != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    daysBetween(today, t.dueDate!) == 0
                        ? 'Today'
                        : formatShortDate(t.dueDate!),
                    style: TextStyle(
                      fontSize: AppType.sizeLabel,
                      color: overdue ? AppColors.danger : AppColors.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (compact) return row;
    // Drag onto a Calendar day to schedule it there (the same record).
    // Drop another task on it: make that one a step, or wait for this one.
    return TransferTarget(
      state: state,
      place: TaskPlace(t.id),
      child: TransferSource(
        transfer: () => TaskTransfer(t.id, t.title, from: t.dueDate),
        touch: touchFirst,
        child: row,
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

  /// The estimate as typed; read when the field is left or Enter pressed.
  late final _estimate = TextEditingController(
    text: _estimateText(_initial.estimateMinutes),
  );
  final _estimateFocus = FocusNode();
  late int? _estimateShown = _initial.estimateMinutes;
  bool _estimateInvalid = false;

  static String _estimateText(int? minutes) =>
      minutes == null ? '' : formatEstimate(minutes);

  /// Saves what was typed: a duration, or nothing (clears the estimate).
  void _commitEstimate() {
    final text = _estimate.text.trim();
    final minutes = text.isEmpty ? null : parseEstimate(text);
    if (text.isNotEmpty && minutes == null) {
      setState(() => _estimateInvalid = true);
      return;
    }
    _estimateInvalid = false;
    _estimateShown = minutes;
    if (task?.estimateMinutes != minutes) {
      _update((x) => x.copyWith(estimateMinutes: () => minutes));
    }
    _estimate.text = _estimateText(minutes);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _estimateFocus.addListener(() {
      if (!_estimateFocus.hasFocus) _commitEstimate();
    });
  }

  Workspace get ws => widget.state.workspace;
  Task? get task => ws.tasks[widget.taskId];

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _sub.dispose();
    _estimate.dispose();
    _estimateFocus.dispose();
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
    // Changed elsewhere (another device, an undo) while not being typed in.
    if (t.estimateMinutes != _estimateShown && !_estimateFocus.hasFocus) {
      _estimateShown = t.estimateMinutes;
      _estimateInvalid = false;
      syncText(this, _estimate, _estimateText(t.estimateMinutes));
    }
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
              key: const ValueKey('task-duplicate'),
              icon: Icons.copy_outlined,
              tooltip: 'Duplicate task',
              onTap: () {
                final copy = ws.duplicateTask(t.id);
                if (copy != null) widget.state.openTask(copy.id);
              },
            ),
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
          Padding(
            padding: EdgeInsets.only(left: 96, bottom: 4),
            child: Text(
              'Shown on Calendar on this date.',
              style: TextStyle(
                fontSize: AppType.sizeMeta,
                color: AppColors.textFaint,
              ),
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
        if (t.recurrence != Recurrence.none && t.dueDate != null)
          Padding(
            padding: const EdgeInsets.only(left: 96, bottom: 4),
            child: Wrap(
              spacing: 4,
              children: [
                TextButton(
                  key: const ValueKey('skip-occurrence'),
                  onPressed: () => _update((x) => x.skippedOccurrence()),
                  child: const Text('Skip this one'),
                ),
                TextButton(
                  key: const ValueKey('move-occurrence'),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: t.dueDate!,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                      helpText: 'Move only this occurrence',
                    );
                    if (d != null) _update((x) => x.movedOccurrence(d));
                  },
                  child: const Text('Move only this one…'),
                ),
                if (t.seriesDate != null)
                  Text(
                    'Moved from ${formatShortDate(t.seriesDate!)}; '
                    'the series continues from there.',
                    style: TextStyle(
                      fontSize: AppType.sizeMeta,
                      color: AppColors.textFaint,
                    ),
                  ),
              ],
            ),
          ),
        if (t.dueDate != null)
          LabeledField(
            label: 'Starts',
            child: Row(
              children: [
                Flexible(
                  child: TextButton(
                    key: const ValueKey('task-start'),
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: t.startDate ?? t.dueDate!,
                        firstDate: DateTime(2000),
                        lastDate: t.dueDate!,
                      );
                      if (d != null) {
                        _update((x) => x.copyWith(startDate: () => d));
                      }
                    },
                    child: Text(
                      t.startDate == null
                          ? 'Same day (for Gantt)'
                          : formatLongDate(t.startDate!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (t.startDate != null)
                  GhostIconButton(
                    icon: Icons.close,
                    tooltip: 'Remove start date',
                    size: 14,
                    onTap: () =>
                        _update((x) => x.copyWith(startDate: () => null)),
                  ),
              ],
            ),
          ),
        if (!t.done)
          LabeledField(
            label: 'Status',
            child: DropdownButton<TaskStatus>(
              isExpanded: true,
              value: t.status,
              items: const [
                DropdownMenuItem(value: TaskStatus.todo, child: Text('To do')),
                DropdownMenuItem(
                  value: TaskStatus.doing,
                  child: Text('In progress'),
                ),
              ],
              onChanged: (v) => _update((x) => x.copyWith(status: v)),
            ),
          ),
        LabeledField(
          label: 'Estimate',
          child: TextField(
            key: const ValueKey('task-estimate-field'),
            controller: _estimate,
            focusNode: _estimateFocus,
            style: const TextStyle(fontSize: AppType.sizeBodySmall),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'e.g. 45 min or 1h30',
              prefixIcon: const Icon(Icons.schedule, size: 16),
              prefixIconConstraints: const BoxConstraints(minWidth: 32),
              errorText: _estimateInvalid
                  ? 'Try “45 min”, “1 hour” or “1h30”.'
                  : null,
            ),
            onChanged: (_) {
              if (_estimateInvalid) setState(() => _estimateInvalid = false);
            },
            onSubmitted: (_) => _commitEstimate(),
          ),
        ),
        LabeledField(
          label: 'Effort',
          child: DropdownButton<TaskEffort?>(
            key: const ValueKey('task-effort'),
            isExpanded: true,
            value: t.effort,
            items: [
              const DropdownMenuItem(value: null, child: Text('Not set')),
              for (final e in TaskEffort.values)
                DropdownMenuItem(value: e, child: Text(e.label)),
            ],
            onChanged: (v) => _update((x) => x.copyWith(effort: () => v)),
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
                    style: const TextStyle(fontSize: AppType.sizeLabel),
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
        LabeledField(
          label: 'Labels',
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final l in t.labels)
                InputChip(
                  label: Text(
                    l,
                    style: const TextStyle(fontSize: AppType.sizeLabel),
                  ),
                  onDeleted: () => _update(
                    (x) => x.copyWith(labels: [...x.labels]..remove(l)),
                  ),
                ),
              TextButton(
                key: const ValueKey('task-add-label'),
                onPressed: () async {
                  final l = await promptText(
                    context,
                    title: 'Add a label',
                    action: 'Add',
                  );
                  final label = l?.trim() ?? '';
                  if (label.isEmpty) return;
                  _update(
                    (x) => x.labels.contains(label)
                        ? x
                        : x.copyWith(labels: [...x.labels, label]),
                  );
                },
                child: const Text('+ Label'),
              ),
            ],
          ),
        ),
        LabeledField(
          label: 'Waits for',
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final id in t.dependsOn)
                if (ws.tasks[id] case final other?)
                  InputChip(
                    avatar: Icon(
                      other.done ? Icons.check : Icons.hourglass_empty,
                      size: 14,
                      color: other.done ? AppColors.success : AppColors.warm,
                    ),
                    label: Text(
                      other.title,
                      style: const TextStyle(fontSize: AppType.sizeLabel),
                    ),
                    onDeleted: () => _update(
                      (x) =>
                          x.copyWith(dependsOn: [...x.dependsOn]..remove(id)),
                    ),
                  ),
              PopupMenuButton<String>(
                key: const ValueKey('task-add-dependency'),
                tooltip: 'Add a task to finish first',
                onSelected: (id) =>
                    _update((x) => x.copyWith(dependsOn: [...x.dependsOn, id])),
                itemBuilder: (_) => [
                  for (final other
                      in ws.tasks.all.toList()
                        ..sort((a, b) => a.title.compareTo(b.title)))
                    if (!t.dependsOn.contains(other.id) &&
                        ws.canDependOn(t.id, other.id))
                      PopupMenuItem(value: other.id, child: Text(other.title)),
                ],
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    '+ Task',
                    style: TextStyle(fontSize: AppType.sizeBodySmall),
                  ),
                ),
              ),
            ],
          ),
        ),
        LabeledField(
          label: 'Notes',
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final id in t.noteIds)
                if (ws.notes[id] case final note?)
                  InputChip(
                    avatar: const Icon(Icons.description_outlined, size: 14),
                    label: Text(
                      note.displayTitle,
                      style: const TextStyle(fontSize: AppType.sizeLabel),
                    ),
                    onPressed: () => widget.state.openNote(id),
                    onDeleted: () => _update(
                      (x) => x.copyWith(noteIds: [...x.noteIds]..remove(id)),
                    ),
                  ),
              PopupMenuButton<String>(
                key: const ValueKey('task-link-note'),
                tooltip: 'Link a note to this task',
                onSelected: (id) =>
                    _update((x) => x.copyWith(noteIds: [...x.noteIds, id])),
                itemBuilder: (_) => [
                  for (final note
                      in ws.notes.all.toList()
                        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)))
                    if (!t.noteIds.contains(note.id))
                      PopupMenuItem(
                        value: note.id,
                        child: Text(note.displayTitle),
                      ),
                ],
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    '+ Note',
                    style: TextStyle(fontSize: AppType.sizeBodySmall),
                  ),
                ),
              ),
            ],
          ),
        ),
        LabeledField(
          label: 'Properties',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in t.properties.entries)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${e.key}: ${e.value}',
                        style: const TextStyle(fontSize: AppType.sizeBodySmall),
                      ),
                    ),
                    GhostIconButton(
                      icon: Icons.close,
                      tooltip: 'Remove ${e.key}',
                      size: 14,
                      onTap: () => _update(
                        (x) => x.copyWith(
                          properties: {...x.properties}..remove(e.key),
                        ),
                      ),
                    ),
                  ],
                ),
              TextButton(
                key: const ValueKey('task-add-property'),
                onPressed: () async {
                  final name = await promptText(
                    context,
                    title: 'Property name (e.g. Effort)',
                    action: 'Next',
                  );
                  if (name == null || name.trim().isEmpty || !context.mounted) {
                    return;
                  }
                  final value = await promptText(
                    context,
                    title: name.trim(),
                    initial: t.properties[name.trim()] ?? '',
                  );
                  if (value == null) return;
                  _update(
                    (x) => x.copyWith(
                      properties: {...x.properties, name.trim(): value},
                    ),
                  );
                },
                child: const Text('+ Property'),
              ),
            ],
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: t.isExam,
          title: const Text(
            'This is an exam',
            style: TextStyle(fontSize: AppType.sizeBodySmall),
          ),
          subtitle: Text(
            'Add revision tasks as subtasks below.',
            style: TextStyle(
              fontSize: AppType.sizeMeta,
              color: AppColors.textFaint,
            ),
          ),
          onChanged: (v) => _update((x) => x.copyWith(isExam: v)),
        ),
        const SizedBox(height: Space.md),
        Text(
          t.isExam ? 'REVISION TASKS' : 'SUBTASKS',
          style: TextStyle(
            fontSize: AppType.sizeMeta,
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
          style: const TextStyle(fontSize: AppType.sizeBodySmall),
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
          style: const TextStyle(fontSize: AppType.sizeBodySmall),
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
        if (widget.state.ai.enabled)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: OutlinedButton.icon(
              key: const ValueKey('task-ask-ai'),
              onPressed: () => widget.state.sendToAi(
                AiContext(
                  title: 'Task “${t.title}”',
                  source: AiSource.tasks,
                  text: [
                    t.title,
                    if (t.notes.isNotEmpty) t.notes,
                    for (final sub in subtasks) '- ${sub.title}',
                  ].join('\n'),
                ),
              ),
              icon: const Icon(Icons.auto_awesome_outlined, size: 16),
              label: const Text('Ask AI (break down, explain…)'),
            ),
          ),
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
            borderRadius: BorderRadius.circular(AppRadii.md),
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
                      fontSize: AppType.sizeMicro,
                      letterSpacing: 0.6,
                      color: timer.onBreak
                          ? AppColors.success
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
                        style: TextStyle(
                          fontSize: AppType.sizeMeta,
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
