import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/record.dart';
import '../../data/models/smart_view_models.dart';
import '../../data/models/task_models.dart';
import '../../data/workspace.dart';
import '../../widgets/common.dart';

// Smart Views of the Calendar's Tasks column: a small selector that narrows
// the task list to a built-in or saved view. Views are conditions over the
// live task records, worked out again on every change, so a task leaves a
// view as soon as it no longer fits (e.g. when it is completed).

/// The views that come with the app. They are not stored; each works from
/// data the app already has.
enum BuiltInView {
  overdue(
    'Overdue',
    Icons.running_with_errors_outlined,
    'Nothing overdue.',
    'Unfinished tasks whose deadline has passed show here.',
  ),
  university(
    'University',
    Icons.school_outlined,
    'No University tasks.',
    'Tasks in study subjects, or in a project or label named '
        '“University”, show here.',
  ),
  highPriority(
    'High Priority',
    Icons.flag_outlined,
    'No high-priority tasks.',
    'Unfinished tasks marked High show here.',
  ),
  noDeadline(
    'No Deadline',
    Icons.event_busy_outlined,
    'Every open task has a deadline.',
    'Unfinished tasks without a date show here.',
  ),
  blockedProjects(
    'Blocked Projects',
    Icons.block_outlined,
    'No blocked projects.',
    'A project is blocked while one of its tasks waits for an unfinished '
        'task. Its open tasks show here.',
  ),
  todaysHabits(
    'Today’s Habits',
    Icons.repeat,
    'All of today’s habits are done.',
    'Habits planned for today show here until you tick them off.',
  );

  const BuiltInView(this.label, this.icon, this.emptyTitle, this.emptyHint);
  final String label;
  final IconData icon;
  final String emptyTitle;
  final String emptyHint;

  String get id => 'builtin.$name';

  static BuiltInView? ofId(String? id) =>
      id != null && id.startsWith('builtin.')
      ? BuiltInView.values.asNameMap()[id.substring(8)]
      : null;
}

/// Whether [name] (a project or label) means University.
bool _isUniversityName(String name) {
  final n = name.trim().toLowerCase();
  return n == 'uni' || n.contains('university');
}

/// Projects (not archived) with an open task that waits for an unfinished
/// one: the app's existing "waiting on others" state, per project.
Set<String> blockedProjectIds(Workspace ws) => {
  for (final t in ws.tasks.all)
    if (!t.done &&
        t.projectId != null &&
        ws.projects[t.projectId] != null &&
        !ws.projects[t.projectId]!.archived &&
        ws.openPrerequisites(t).isNotEmpty)
      t.projectId!,
};

/// Whether view [id] exists (built-in, or saved and not deleted).
bool smartViewExists(Workspace ws, String id) =>
    BuiltInView.ofId(id) != null || ws.smartViews[id] != null;

String smartViewName(Workspace ws, String id) =>
    BuiltInView.ofId(id)?.label ?? ws.smartViews[id]?.name ?? 'View';

/// A test for which tasks view [id] shows on [today]. Sets it needs are
/// worked out once, so the test is cheap per task. Subtasks show under
/// their parent, as in every other list.
bool Function(Task) smartViewMatcher(Workspace ws, String id, DateTime today) {
  today = dateOnly(today);
  ProjectKind? kindOf(String? projectId) => ws.projects[projectId]?.kind;
  final builtIn = BuiltInView.ofId(id);
  switch (builtIn) {
    case BuiltInView.overdue:
      return (t) =>
          t.parentId == null &&
          !t.done &&
          t.dueDate != null &&
          daysBetween(t.dueDate!, today) > 0;
    case BuiltInView.university:
      return (t) {
        if (t.parentId != null || t.done) return false;
        final p = ws.projects[t.projectId];
        return (p != null &&
                (p.kind == ProjectKind.subject || _isUniversityName(p.name))) ||
            t.labels.any(_isUniversityName);
      };
    case BuiltInView.highPriority:
      return (t) => t.parentId == null && !t.done && t.priority == 3;
    case BuiltInView.noDeadline:
      return (t) => t.parentId == null && !t.done && t.dueDate == null;
    case BuiltInView.blockedProjects:
      final blocked = blockedProjectIds(ws);
      return (t) =>
          t.parentId == null && !t.done && blocked.contains(t.projectId);
    case BuiltInView.todaysHabits:
      return (_) => false; // habits are not tasks: see [habitsDueToday]
    case null:
      final view = ws.smartViews[id];
      if (view == null) return (_) => false;
      return (t) =>
          t.parentId == null &&
          view.filter.matches(t, today: today, kindOf: kindOf);
  }
}

/// The tasks view [id] shows on [today], in no particular order.
List<Task> smartViewTasks(Workspace ws, String id, DateTime today) =>
    ws.tasks.all.where(smartViewMatcher(ws, id, today)).toList();

/// Active habits planned for [today] and not ticked off yet, by time.
List<CalendarEntry> habitsDueToday(Workspace ws, DateTime today) {
  final list = [
    for (final e in ws.entries.all)
      if (e.category == CalendarCategory.habits &&
          !e.archived &&
          e.occursOn(today) &&
          !e.isCheckedOn(today))
        e,
  ];
  list.sort((a, b) {
    final am = a.startMinutes, bm = b.startMinutes;
    if (am != null && bm != null && am != bm) return am.compareTo(bm);
    if ((am == null) != (bm == null)) return am == null ? 1 : -1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return list;
}

/// Details a task typed into view [id] starts with, so it shows in the view
/// it was added from where that is simple to do.
({String? projectId, int? priority, List<String> labels}) smartViewDefaults(
  Workspace ws,
  String id,
) {
  if (BuiltInView.ofId(id) == BuiltInView.highPriority) {
    return (projectId: null, priority: 3, labels: const []);
  }
  final f = ws.smartViews[id]?.filter;
  if (f == null) return (projectId: null, priority: null, labels: const []);
  return (
    projectId: f.projectIds.length == 1 ? f.projectIds.single : null,
    priority: f.priorities.length == 1 ? f.priorities.single : null,
    labels: f.labels.length == 1 ? [f.labels.single] : const [],
  );
}

/// Saved views, by name.
List<SmartView> savedViewsByName(Workspace ws) =>
    ws.smartViews.all.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

SmartView createSmartView(Workspace ws, String name, ViewFilter filter) {
  final now = DateTime.now();
  final view = SmartView(
    id: newId(),
    name: _cleanName(name),
    filter: filter,
    createdAt: now,
    updatedAt: now,
  );
  ws.smartViews.put(view);
  return view;
}

String _cleanName(String name) {
  final n = name.trim().replaceAll(RegExp(r'\s+'), ' ');
  final short = n.length > SmartView.maxNameLength
      ? n.substring(0, SmartView.maxNameLength)
      : n;
  return short.isEmpty ? 'View' : short;
}

void renameSmartView(Workspace ws, String id, String name) {
  final v = ws.smartViews[id];
  if (v != null) ws.smartViews.put(v.copyWith(name: _cleanName(name)));
}

// ------------------------------------------------------------------ UI --

/// The view selector: one quiet text button showing the current view, with
/// a menu of All tasks, the built-in and saved views, and "New view…".
/// For a saved view the same menu edits, renames or deletes it.
class SmartViewSelector extends StatelessWidget {
  const SmartViewSelector({
    super.key,
    required this.workspace,
    required this.current,
    required this.onSelect,
  });

  final Workspace workspace;

  /// The open view, or null for All tasks.
  final String? current;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final ws = workspace;
    final id = current;
    final saved = savedViewsByName(ws);
    final custom = id == null ? null : ws.smartViews[id];
    PopupMenuItem<String> entry(String value, String label, {IconData? icon}) {
      final on = value == (id ?? 'all');
      return PopupMenuItem(
        value: value,
        height: 36,
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: icon == null
                  ? null
                  : Icon(
                      icon,
                      size: 15,
                      color: on ? AppColors.text : AppColors.textFaint,
                    ),
            ),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.sizeBodySmall,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return PopupMenuButton<String>(
      key: const ValueKey('smart-view-selector'),
      // The column's title names the open view; this stays a quiet icon.
      tooltip: 'Smart views',
      position: PopupMenuPosition.under,
      onSelected: (v) => _choose(context, v),
      itemBuilder: (_) => [
        entry('all', 'All tasks', icon: Icons.inbox_outlined),
        const PopupMenuDivider(),
        for (final b in BuiltInView.values) entry(b.id, b.label, icon: b.icon),
        if (saved.isNotEmpty) const PopupMenuDivider(),
        for (final v in saved) entry(v.id, v.name, icon: Icons.tune),
        const PopupMenuDivider(),
        if (custom != null) ...[
          entry('edit', 'Edit “${custom.name}”…'),
          entry('rename', 'Rename…'),
          entry('delete', 'Delete view'),
          const PopupMenuDivider(),
        ],
        entry('new', 'Create a new view…', icon: Icons.add),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.tune,
              size: 15,
              color: id == null ? AppColors.textFaint : AppColors.textMuted,
            ),
            Icon(Icons.expand_more, size: 16, color: AppColors.textFaint),
          ],
        ),
      ),
    );
  }

  Future<void> _choose(BuildContext context, String value) async {
    final ws = workspace;
    switch (value) {
      case 'all':
        onSelect(null);
      case 'new':
        final made = await showSmartViewEditor(context, ws);
        if (made != null) onSelect(made.id);
      case 'edit':
        final v = ws.smartViews[current];
        if (v != null) await showSmartViewEditor(context, ws, existing: v);
      case 'rename':
        final v = ws.smartViews[current];
        if (v == null) return;
        final name = await promptText(
          context,
          title: 'Rename view',
          initial: v.name,
        );
        if (name != null) renameSmartView(ws, v.id, name);
      case 'delete':
        final v = ws.smartViews[current];
        if (v == null) return;
        final ok = await confirm(
          context,
          title: 'Delete “${v.name}”?',
          message: 'Only the view is deleted. Its tasks stay as they are.',
        );
        if (!ok) return;
        ws.smartViews.remove(v.id);
        onSelect(null);
      default:
        onSelect(value);
    }
  }
}

/// Creates a view, or edits [existing]. Returns the saved view, or null
/// when cancelled.
Future<SmartView?> showSmartViewEditor(
  BuildContext context,
  Workspace ws, {
  SmartView? existing,
}) => showAppDialog<SmartView>(
  context: context,
  builder: (_) => _SmartViewEditor(workspace: ws, existing: existing),
);

class _SmartViewEditor extends StatefulWidget {
  const _SmartViewEditor({required this.workspace, this.existing});

  final Workspace workspace;
  final SmartView? existing;

  @override
  State<_SmartViewEditor> createState() => _SmartViewEditorState();
}

class _SmartViewEditorState extends State<_SmartViewEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late ViewFilter _filter = widget.existing?.filter ?? const ViewFilter();

  Workspace get ws => widget.workspace;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final old = widget.existing;
    final SmartView saved;
    if (old == null) {
      saved = createSmartView(ws, name, _filter);
    } else {
      saved = old.copyWith(name: _cleanName(name), filter: _filter);
      ws.smartViews.put(saved);
    }
    Navigator.pop(context, saved);
  }

  Set<T> _toggled<T>(Set<T> set, T value, bool on) =>
      on ? {...set, value} : ({...set}..remove(value));

  Widget _chip(String label, bool selected, ValueChanged<bool> onChanged) =>
      FilterChip(
        label: Text(label, style: const TextStyle(fontSize: AppType.sizeLabel)),
        selected: selected,
        showCheckmark: false,
        onSelected: onChanged,
      );

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: AppSpace.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: AppType.sizeMeta,
            letterSpacing: 0.6,
            color: AppColors.textFaint,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final f = _filter;
    final projects = ws.projects.all.where((p) => !p.archived).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final labels = ws.taskLabels;
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'New view' : 'Edit view',
        style: const TextStyle(fontSize: AppType.sizeHeading),
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('smart-view-name'),
                controller: _name,
                autofocus: widget.existing == null,
                maxLength: SmartView.maxNameLength,
                decoration: const InputDecoration(
                  hintText: 'Name, e.g. “This week’s essays”',
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
              ),
              _section(
                'STATUS',
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in ViewCompletion.values)
                      _chip(
                        c.label,
                        f.completion == c,
                        (_) =>
                            setState(() => _filter = f.copyWith(completion: c)),
                      ),
                  ],
                ),
              ),
              _section(
                'DEADLINE',
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final d in ViewDue.values)
                      _chip(
                        d.label,
                        f.due == d,
                        (_) => setState(() => _filter = f.copyWith(due: d)),
                      ),
                  ],
                ),
              ),
              _section(
                'PRIORITY',
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (p, name) in const [
                      (3, 'High'),
                      (2, 'Medium'),
                      (1, 'Low'),
                      (0, 'None'),
                    ])
                      _chip(
                        name,
                        f.priorities.contains(p),
                        (on) => setState(
                          () => _filter = f.copyWith(
                            priorities: _toggled(f.priorities, p, on),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _section(
                'CATEGORY',
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (k, name) in const [
                      (ProjectKind.project, 'Projects'),
                      (ProjectKind.subject, 'Study subjects'),
                    ])
                      _chip(
                        name,
                        f.projectKinds.contains(k),
                        (on) => setState(
                          () => _filter = f.copyWith(
                            projectKinds: _toggled(f.projectKinds, k, on),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (projects.isNotEmpty)
                _section(
                  'PROJECT',
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final p in projects)
                        _chip(
                          p.name,
                          f.projectIds.contains(p.id),
                          (on) => setState(
                            () => _filter = f.copyWith(
                              projectIds: _toggled(f.projectIds, p.id, on),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (labels.isNotEmpty)
                _section(
                  'LABEL',
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final l in labels)
                        _chip(
                          l,
                          f.labels.contains(l),
                          (on) => setState(
                            () => _filter = f.copyWith(
                              labels: _toggled(f.labels, l, on),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.md),
                child: Text(
                  'A task shows when it meets every condition. Nothing is '
                  'copied: the view follows your tasks as they change.',
                  style: TextStyle(
                    fontSize: AppType.sizeMeta,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: AppColors.textMuted)),
        ),
        TextButton(
          key: const ValueKey('smart-view-save'),
          onPressed: _name.text.trim().isEmpty ? null : _save,
          child: const Text('Save view'),
        ),
      ],
    );
  }
}

/// What an empty view says: one quiet line and why it may be empty.
class SmartViewEmpty extends StatelessWidget {
  const SmartViewEmpty({super.key, required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        key: const ValueKey('smart-view-empty'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppType.sizeBody,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppType.sizeMeta,
              color: AppColors.textFaint,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Today's habits that are not done yet; ticking one off removes it.
class TodaysHabitsList extends StatelessWidget {
  const TodaysHabitsList({
    super.key,
    required this.workspace,
    required this.today,
  });

  final Workspace workspace;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final habits = habitsDueToday(workspace, today);
    if (habits.isEmpty) {
      return SmartViewEmpty(
        title: BuiltInView.todaysHabits.emptyTitle,
        hint: BuiltInView.todaysHabits.emptyHint,
      );
    }
    return ListView(
      children: [
        for (final h in habits)
          ListTile(
            key: ValueKey('habit-${h.id}'),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Checkbox(
              value: false,
              activeColor: AppColors.success,
              side: BorderSide(
                color: calendarCategoryColor(CalendarCategory.habits),
                width: 1.5,
              ),
              onChanged: (_) =>
                  workspace.toggleEntryCompletion(h.id, dateOnly(today)),
            ),
            title: Text(
              h.name,
              style: const TextStyle(fontSize: AppType.sizeBody),
            ),
            subtitle: h.timeLabel == null
                ? null
                : Text(
                    h.timeLabel!,
                    style: TextStyle(
                      fontSize: AppType.sizeMeta,
                      color: AppColors.textFaint,
                    ),
                  ),
          ),
      ],
    );
  }
}
