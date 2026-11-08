// Other views of the same task records: a board (To do / In progress /
// Done), a sortable, filterable table and a Gantt timeline. Each shows the
// tasks it is given; changing a task here changes that one record.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/record.dart';
import '../../data/models/task_models.dart';
import '../../widgets/common.dart';

enum TaskView { list, board, table, gantt }

extension TaskViewInfo on TaskView {
  String get label => switch (this) {
    TaskView.list => 'List',
    TaskView.board => 'Board',
    TaskView.table => 'Table',
    TaskView.gantt => 'Gantt',
  };

  IconData get icon => switch (this) {
    TaskView.list => Icons.view_list_outlined,
    TaskView.board => Icons.view_kanban_outlined,
    TaskView.table => Icons.table_rows_outlined,
    TaskView.gantt => Icons.view_timeline_outlined,
  };
}

/// Board column of a task.
enum BoardColumn { todo, doing, done }

BoardColumn boardColumnOf(Task t) => t.done
    ? BoardColumn.done
    : t.status == TaskStatus.doing
    ? BoardColumn.doing
    : BoardColumn.todo;

/// Puts [task] into [column] (the same record: done/status change).
void moveToColumn(AppState s, Task task, BoardColumn column) {
  final ws = s.workspace;
  switch (column) {
    case BoardColumn.done:
      if (!task.done) s.toggleTask(task.id);
    case BoardColumn.todo || BoardColumn.doing:
      final status = column == BoardColumn.doing
          ? TaskStatus.doing
          : TaskStatus.todo;
      final t = ws.tasks[task.id] ?? task;
      ws.tasks.put(
        t.done
            ? t.copyWith(done: false, completedAt: () => null, status: status)
            : t.copyWith(status: status),
      );
  }
}

class TaskBoardView extends StatelessWidget {
  const TaskBoardView({
    super.key,
    required this.state,
    required this.tasks,
    required this.onOpen,
  });

  final AppState state;
  final List<Task> tasks;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final column in BoardColumn.values)
        Expanded(
          child: DragTarget<String>(
            key: ValueKey('board-${column.name}'),
            onAcceptWithDetails: (d) {
              final t = state.workspace.tasks[d.data];
              if (t != null) moveToColumn(state, t, column);
            },
            builder: (context, hovering, _) => Container(
              margin: const EdgeInsets.all(4),
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                color: hovering.isEmpty ? AppColors.card : AppColors.selected,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(
                      switch (column) {
                        BoardColumn.todo => 'To do',
                        BoardColumn.doing => 'In progress',
                        BoardColumn.done => 'Done',
                      },
                      style: TextStyle(
                        fontSize: AppType.sizeLabel,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final t in tasks)
                          if (boardColumnOf(t) == column)
                            _BoardCard(state: state, task: t, onOpen: onOpen),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

class _BoardCard extends StatelessWidget {
  const _BoardCard({
    required this.state,
    required this.task,
    required this.onOpen,
  });

  final AppState state;
  final Task task;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: 220,
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.all(AppSpace.sm),
      decoration: BoxDecoration(
        color: AppColors.cardRaised,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.sizeBodySmall,
              decoration: task.done ? TextDecoration.lineThrough : null,
              color: task.done ? AppColors.textFaint : AppColors.text,
            ),
          ),
          if (task.dueDate != null || task.labels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                [
                  if (task.dueDate != null) formatShortDate(task.dueDate!),
                  ...task.labels,
                ].join('  ·  '),
                style: TextStyle(
                  fontSize: AppType.sizeMeta,
                  color: AppColors.textFaint,
                ),
              ),
            ),
        ],
      ),
    );
    return Draggable<String>(
      key: ValueKey('board-card-${task.id}'),
      data: task.id,
      feedback: Material(color: Colors.transparent, child: card),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: GestureDetector(onTap: () => onOpen(task.id), child: card),
    );
  }
}

/// Sortable table columns.
enum TaskColumn { title, due, priority, project, labels, status }

class TaskTableView extends StatefulWidget {
  const TaskTableView({
    super.key,
    required this.state,
    required this.tasks,
    required this.onOpen,
  });

  final AppState state;
  final List<Task> tasks;
  final ValueChanged<String> onOpen;

  /// [tasks] filtered by [query] (title, notes, labels, properties,
  /// project) and sorted by [column].
  static List<Task> arrange(
    AppState s,
    Iterable<Task> tasks, {
    String query = '',
    TaskColumn column = TaskColumn.due,
    bool ascending = true,
  }) {
    final q = query.trim().toLowerCase();
    final ws = s.workspace;
    String project(Task t) => ws.projects[t.projectId]?.name ?? '';
    final list = [
      for (final t in tasks)
        if (q.isEmpty ||
            t.title.toLowerCase().contains(q) ||
            t.notes.toLowerCase().contains(q) ||
            project(t).toLowerCase().contains(q) ||
            t.labels.any((l) => l.toLowerCase().contains(q)) ||
            t.properties.entries.any(
              (e) =>
                  e.key.toLowerCase().contains(q) ||
                  e.value.toLowerCase().contains(q),
            ))
          t,
    ];
    int compare(Task a, Task b) => switch (column) {
      TaskColumn.title => a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      ),
      TaskColumn.due => _compareDates(a.dueDate, b.dueDate),
      TaskColumn.priority => a.priority.compareTo(b.priority),
      TaskColumn.project => project(a).compareTo(project(b)),
      TaskColumn.labels => a.labels.join(',').compareTo(b.labels.join(',')),
      TaskColumn.status => boardColumnOf(
        a,
      ).index.compareTo(boardColumnOf(b).index),
    };
    list.sort((a, b) {
      final c = compare(a, b);
      return ascending ? c : -c;
    });
    return list;
  }

  static int _compareDates(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == null ? (b == null ? 0 : 1) : -1;
    return a.compareTo(b);
  }

  @override
  State<TaskTableView> createState() => _TaskTableViewState();
}

class _TaskTableViewState extends State<TaskTableView> {
  TaskColumn _column = TaskColumn.due;
  bool _ascending = true;
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final rows = TaskTableView.arrange(
      s,
      widget.tasks,
      query: _filter.text,
      column: _column,
      ascending: _ascending,
    );
    final properties = {
      for (final t in widget.tasks) ...t.properties.keys,
    }.toList()..sort();
    DataColumn col(String label, TaskColumn c) => DataColumn(
      label: Text(label),
      onSort: (_, ascending) => setState(() {
        _column = c;
        _ascending = ascending;
      }),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('task-table-filter'),
          controller: _filter,
          style: const TextStyle(fontSize: AppType.sizeBodySmall),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.filter_list, size: 16),
            hintText: 'Filter by title, label, project or property',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpace.sm),
        Expanded(
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                key: const ValueKey('task-table'),
                sortColumnIndex: _column.index,
                sortAscending: _ascending,
                headingTextStyle: TextStyle(
                  fontSize: AppType.sizeLabel,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                ),
                dataTextStyle: const TextStyle(fontSize: AppType.sizeBodySmall),
                columns: [
                  col('Task', TaskColumn.title),
                  col('Due', TaskColumn.due),
                  col('Priority', TaskColumn.priority),
                  col('Project', TaskColumn.project),
                  col('Labels', TaskColumn.labels),
                  col('Status', TaskColumn.status),
                  for (final p in properties) DataColumn(label: Text(p)),
                ],
                rows: [
                  for (final t in rows)
                    DataRow(
                      onSelectChanged: (_) => widget.onOpen(t.id),
                      cells: [
                        DataCell(
                          Text(
                            t.title,
                            style: TextStyle(
                              decoration: t.done
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: t.done
                                  ? AppColors.textFaint
                                  : AppColors.text,
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            t.dueDate == null
                                ? ''
                                : formatShortDate(t.dueDate!),
                          ),
                        ),
                        DataCell(Text(t.priority == 0 ? '' : '${t.priority}')),
                        DataCell(
                          Text(s.workspace.projects[t.projectId]?.name ?? ''),
                        ),
                        DataCell(Text(t.labels.join(', '))),
                        DataCell(
                          Text(switch (boardColumnOf(t)) {
                            BoardColumn.todo => 'To do',
                            BoardColumn.doing => 'In progress',
                            BoardColumn.done => 'Done',
                          }),
                        ),
                        for (final p in properties)
                          DataCell(Text(t.properties[p] ?? '')),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A Gantt bar: from [Task.startDate] (or the due date) to the due date.
({DateTime start, DateTime end})? ganttSpan(Task t) {
  final due = t.dueDate;
  if (due == null) return null;
  final start = t.startDate;
  if (start == null || start.isAfter(due)) return (start: due, end: due);
  return (start: start, end: due);
}

/// Task dates on a day scale, with prerequisites marked and each
/// project's progress. Only dates: no hours, no time blocks.
class TaskGanttView extends StatelessWidget {
  const TaskGanttView({
    super.key,
    required this.state,
    required this.tasks,
    required this.onOpen,
  });

  final AppState state;
  final List<Task> tasks;
  final ValueChanged<String> onOpen;

  static const dayWidth = 28.0;
  static const rowHeight = 30.0;
  static const labelWidth = 200.0;

  @override
  Widget build(BuildContext context) {
    final ws = state.workspace;
    final dated = [
      for (final t in tasks)
        if (ganttSpan(t) != null) t,
    ]..sort((a, b) => ganttSpan(a)!.start.compareTo(ganttSpan(b)!.start));
    if (dated.isEmpty) {
      return Center(
        child: Text(
          'No tasks with dates here. Give tasks a due date (and a start '
          'date) to see them on the timeline.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textFaint),
        ),
      );
    }
    final today = dateOnly(DateTime.now());
    var first = ganttSpan(dated.first)!.start;
    var last = first;
    for (final t in dated) {
      final span = ganttSpan(t)!;
      if (span.start.isBefore(first)) first = span.start;
      if (span.end.isAfter(last)) last = span.end;
    }
    first = addDays(first, -2);
    last = addDays(last, 3);
    final days = daysBetween(first, last) + 1;
    final projectIds = {for (final t in dated) t.projectId}..remove(null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (projectIds.isNotEmpty)
          Wrap(
            spacing: AppSpace.md,
            children: [
              for (final id in projectIds)
                if (ws.projects[id] case final p?)
                  Builder(
                    builder: (context) {
                      final all = ws.tasks.all
                          .where((t) => t.projectId == id)
                          .toList();
                      final done = all.where((t) => t.done).length;
                      return Text(
                        '${p.name}: $done/${all.length} done',
                        style: TextStyle(
                          fontSize: AppType.sizeLabel,
                          color: AppColors.textMuted,
                        ),
                      );
                    },
                  ),
            ],
          ),
        const SizedBox(height: AppSpace.sm),
        Expanded(
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                key: const ValueKey('task-gantt'),
                width: labelWidth + days * dayWidth,
                height: (dated.length + 1) * rowHeight,
                child: Stack(
                  children: [
                    // Day scale.
                    for (var i = 0; i < days; i++)
                      Positioned(
                        left: labelWidth + i * dayWidth,
                        top: 0,
                        width: dayWidth,
                        height: (dated.length + 1) * rowHeight,
                        child: Container(
                          decoration: BoxDecoration(
                            color: daysBetween(addDays(first, i), today) == 0
                                ? AppColors.accent.withValues(alpha: 0.12)
                                : null,
                            border: Border(
                              left: BorderSide(color: AppColors.border),
                            ),
                          ),
                          alignment: Alignment.topCenter,
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '${addDays(first, i).day}',
                            style: TextStyle(
                              fontSize: AppType.sizeMicro,
                              color: AppColors.textFaint,
                            ),
                          ),
                        ),
                      ),
                    for (var r = 0; r < dated.length; r++)
                      ..._row(context, dated[r], r, first),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _row(BuildContext context, Task t, int r, DateTime first) {
    final span = ganttSpan(t)!;
    final top = (r + 1) * rowHeight;
    final waiting = state.workspace.openPrerequisites(t);
    final left = labelWidth + daysBetween(first, span.start) * dayWidth;
    final width = math.max(
      dayWidth,
      (daysBetween(span.start, span.end) + 1) * dayWidth,
    );
    return [
      Positioned(
        left: 0,
        top: top,
        width: labelWidth - 8,
        height: rowHeight,
        child: Row(
          children: [
            if (waiting.isNotEmpty)
              Tooltip(
                message: 'Waits for: ${waiting.map((w) => w.title).join(', ')}',
                child: Icon(Icons.link, size: 14, color: AppColors.warm),
              ),
            Expanded(
              child: Text(
                t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.sizeLabel,
                  decoration: t.done ? TextDecoration.lineThrough : null,
                  color: t.done ? AppColors.textFaint : AppColors.text,
                ),
              ),
            ),
          ],
        ),
      ),
      Positioned(
        left: left,
        top: top + 6,
        width: width,
        height: rowHeight - 12,
        child: GestureDetector(
          key: ValueKey('gantt-bar-${t.id}'),
          onTap: () => onOpen(t.id),
          child: Container(
            decoration: BoxDecoration(
              color: t.done
                  ? AppColors.success.withValues(alpha: 0.5)
                  : AppColors.accent.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(AppRadii.xs),
            ),
          ),
        ),
      ),
    ];
  }
}
