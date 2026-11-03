// Daily and weekly review: what is overdue, due, on the calendar and done,
// and which deadlines look at risk — each with the plain reason (no
// scores or probabilities). Every change is a button the user presses.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/record.dart';
import '../../data/models/task_models.dart';
import '../../data/workspace.dart';
import '../../widgets/common.dart';

/// A task whose deadline looks at risk, and why.
typedef AtRisk = ({Task task, String reason});

class ReviewData {
  ReviewData(Workspace ws, {DateTime? now}) {
    final today = dateOnly(now ?? DateTime.now());
    final weekAgo = today.subtract(const Duration(days: 7));
    for (final t in ws.tasks.all) {
      final due = t.dueDate;
      if (t.done) {
        if (t.completedAt != null && !t.completedAt!.isBefore(weekAgo)) {
          doneThisWeek.add(t);
        }
        continue;
      }
      if (due == null) continue;
      final d = daysBetween(today, due);
      if (d < 0) {
        overdue.add(t);
      } else if (d == 0) {
        dueToday.add(t);
      } else if (d <= 7) {
        dueThisWeek.add(t);
      }
      if (d >= 0 && d <= 3) {
        final blockers = [
          for (final id in t.dependsOn)
            if (ws.tasks[id] case final b? when !b.done) b.title,
        ];
        final open = ws.tasks.all
            .where((s) => s.parentId == t.id && !s.done)
            .length;
        if (blockers.isNotEmpty) {
          atRisk.add((task: t, reason: 'Waits for: ${blockers.join(', ')}'));
        } else if (t.status == TaskStatus.todo && open > d + 1) {
          atRisk.add((
            task: t,
            reason:
                '$open open steps, ${d == 0 ? 'due today' : '$d day(s) left'}',
          ));
        } else if (t.status == TaskStatus.todo && d <= 1) {
          atRisk.add((
            task: t,
            reason: 'Not started, ${d == 0 ? 'due today' : 'due tomorrow'}',
          ));
        }
      }
    }
    int byDue(Task a, Task b) => a.dueDate!.compareTo(b.dueDate!);
    overdue.sort(byDue);
    dueThisWeek.sort(byDue);
    calendarToday = ws.itemsOn(today, includeTasks: false);
    notesThisWeek = ws.notes.all
        .where((n) => !n.updatedAt.isBefore(weekAgo))
        .length;
    archivedThisWeek = ws.assets.all
        .where((a) => !a.createdAt.isBefore(weekAgo))
        .length;
  }

  final overdue = <Task>[];
  final dueToday = <Task>[];
  final dueThisWeek = <Task>[];
  final doneThisWeek = <Task>[];
  final atRisk = <AtRisk>[];
  late final List<DayItem> calendarToday;
  late final int notesThisWeek;
  late final int archivedThisWeek;
}

Future<void> showReviewCenter(BuildContext context, AppState s) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(width: 640, height: 560, child: ReviewCenter(state: s)),
      ),
    );

class ReviewCenter extends StatefulWidget {
  const ReviewCenter({super.key, required this.state});
  final AppState state;

  @override
  State<ReviewCenter> createState() => _ReviewCenterState();
}

class _ReviewCenterState extends State<ReviewCenter> {
  bool _weekly = false;

  AppState get s => widget.state;

  Widget _heading(String text, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      '$text ($count)',
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
    ),
  );

  Widget _task(Task t, {String? reason}) => ListTile(
    key: ValueKey('review-task-${t.id}'),
    dense: true,
    title: Text(t.title),
    subtitle: Text(
      [
        if (t.dueDate != null) 'Due ${formatShortDate(t.dueDate!)}',
        ?reason,
      ].join(' · '),
      style: const TextStyle(fontSize: 11),
    ),
    onTap: () {
      Navigator.pop(context);
      s.openTask(t.id);
    },
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (t.dueDate != null)
          TextButton(
            key: ValueKey('review-later-${t.id}'),
            onPressed: () => s.workspace.tasks.put(
              t.copyWith(
                dueDate: () =>
                    dateOnly(DateTime.now()).add(const Duration(days: 1)),
              ),
            ),
            child: const Text('Tomorrow'),
          ),
        IconButton(
          key: ValueKey('review-done-${t.id}'),
          tooltip: 'Done',
          icon: const Icon(Icons.check, size: 18),
          onPressed: () => s.workspace.toggleTask(t.id),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([s.workspace.tasks, s.workspace.entries]),
    builder: (context, _) {
      final r = ReviewData(s.workspace);
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                const Text(
                  'Review',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: Space.md),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Today')),
                    ButtonSegment(value: true, label: Text('This week')),
                  ],
                  selected: {_weekly},
                  onSelectionChanged: (v) => setState(() => _weekly = v.first),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: _weekly
                  ? [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Text(
                          'Last 7 days: ${r.doneThisWeek.length} tasks done, '
                          '${r.notesThisWeek} notes written or changed, '
                          '${r.archivedThisWeek} things added to the Archive.',
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      ),
                      _heading('Deadlines that look at risk', r.atRisk.length),
                      for (final a in r.atRisk) _task(a.task, reason: a.reason),
                      _heading('Due in the next 7 days', r.dueThisWeek.length),
                      for (final t in r.dueThisWeek) _task(t),
                      _heading('Done this week', r.doneThisWeek.length),
                      for (final t in r.doneThisWeek)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.check, size: 16),
                          title: Text(t.title),
                        ),
                    ]
                  : [
                      _heading('Overdue', r.overdue.length),
                      for (final t in r.overdue) _task(t),
                      _heading('Due today', r.dueToday.length),
                      for (final t in r.dueToday) _task(t),
                      _heading('At risk', r.atRisk.length),
                      for (final a in r.atRisk) _task(a.task, reason: a.reason),
                      _heading('On the calendar today', r.calendarToday.length),
                      for (final i in r.calendarToday)
                        ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.calendar_today_outlined,
                            size: 16,
                          ),
                          title: Text(i.label),
                          onTap: () {
                            Navigator.pop(context);
                            s.openCalendarDay(DateTime.now());
                          },
                        ),
                    ],
            ),
          ),
        ],
      );
    },
  );
}
