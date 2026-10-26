// Calendar workload: how full each day is, worked out from the calendar
// entries, connected-calendar events and tasks that already exist. It only
// READS them: nothing is created, moved or rescheduled, and there is no
// drag-and-drop planning. The reader may set a daily capacity (a time and/or
// a number of tasks); days over it are marked in words and symbols, not just
// colour, so it reads the same on the dark and the light theme.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/record.dart' show dateOnly, dayKey;
import '../../data/models/task_models.dart';
import '../../data/workspace.dart';
import '../../widgets/common.dart' show formatShortDate, promptText;

// ------------------------------------------------------------------ logic --

/// The reader's own capacity and estimate (all optional).
class WorkloadSettings {
  const WorkloadSettings({
    this.capacityMinutes,
    this.capacityTasks,
    this.minutesPerTask = 30,
  });

  /// Time a day can hold (minutes), or null for no limit.
  final int? capacityMinutes;

  /// Tasks a day can hold, or null for no limit.
  final int? capacityTasks;

  /// What one task is counted as in the day's time (tasks have no length
  /// of their own).
  final int minutesPerTask;

  WorkloadSettings copyWith({
    int? Function()? capacityMinutes,
    int? Function()? capacityTasks,
    int? minutesPerTask,
  }) => WorkloadSettings(
    capacityMinutes: capacityMinutes != null
        ? capacityMinutes()
        : this.capacityMinutes,
    capacityTasks: capacityTasks != null ? capacityTasks() : this.capacityTasks,
    minutesPerTask: minutesPerTask ?? this.minutesPerTask,
  );

  Map<String, Object> toJson() => {
    'capacityMinutes': ?capacityMinutes,
    'capacityTasks': ?capacityTasks,
    'minutesPerTask': minutesPerTask,
  };

  factory WorkloadSettings.fromJson(Object? raw) {
    if (raw is! Map) return const WorkloadSettings();
    int? positive(Object? v) => v is int && v > 0 ? v : null;
    return WorkloadSettings(
      capacityMinutes: positive(raw['capacityMinutes']),
      capacityTasks: positive(raw['capacityTasks']),
      minutesPerTask: positive(raw['minutesPerTask']) ?? 30,
    );
  }
}

/// What to count.
class WorkloadFilter {
  const WorkloadFilter({
    this.showOpenTasks = true,
    this.showDoingTasks = true,
    this.showDoneTasks = false,
    this.categories = const {...CalendarCategory.values},
    this.includeConnected = true,
    this.minPriority = 0,
  });

  /// Task status: not started (todo), in progress (doing), finished.
  final bool showOpenTasks;
  final bool showDoingTasks;
  final bool showDoneTasks;

  /// Calendar categories of entries to count.
  final Set<CalendarCategory> categories;

  /// Events from connected Google / Outlook calendars.
  final bool includeConnected;

  /// Only tasks with at least this priority (0 any, 1 low, 2 medium, 3 high).
  final int minPriority;

  bool taskPasses(Task t) {
    if (t.priority < minPriority) return false;
    if (t.done) return showDoneTasks;
    return t.status == TaskStatus.doing ? showDoingTasks : showOpenTasks;
  }

  WorkloadFilter copyWith({
    bool? showOpenTasks,
    bool? showDoingTasks,
    bool? showDoneTasks,
    Set<CalendarCategory>? categories,
    bool? includeConnected,
    int? minPriority,
  }) => WorkloadFilter(
    showOpenTasks: showOpenTasks ?? this.showOpenTasks,
    showDoingTasks: showDoingTasks ?? this.showDoingTasks,
    showDoneTasks: showDoneTasks ?? this.showDoneTasks,
    categories: categories ?? this.categories,
    includeConnected: includeConnected ?? this.includeConnected,
    minPriority: minPriority ?? this.minPriority,
  );

  Map<String, Object> toJson() => {
    'open': showOpenTasks,
    'doing': showDoingTasks,
    'done': showDoneTasks,
    'categories': [for (final c in categories) c.name],
    'connected': includeConnected,
    'minPriority': minPriority,
  };

  factory WorkloadFilter.fromJson(Object? raw) {
    if (raw is! Map) return const WorkloadFilter();
    final cats = <CalendarCategory>{
      for (final n in raw['categories'] as List? ?? const [])
        ?CalendarCategory.values.asNameMap()[n],
    };
    return WorkloadFilter(
      showOpenTasks: raw['open'] != false,
      showDoingTasks: raw['doing'] != false,
      showDoneTasks: raw['done'] == true,
      categories: raw['categories'] is List ? cats : {...CalendarCategory.values},
      includeConnected: raw['connected'] != false,
      minPriority: raw['minPriority'] is int
          ? (raw['minPriority'] as int).clamp(0, 3)
          : 0,
    );
  }
}

/// How full one day is.
class DayLoad {
  const DayLoad({
    required this.day,
    required this.eventCount,
    required this.taskCount,
    required this.eventMinutes,
    required this.taskMinutes,
    required this.over,
    required this.ratio,
  });

  final DateTime day;
  final int eventCount;
  final int taskCount;
  final int eventMinutes;
  final int taskMinutes;

  /// The day holds more than the reader's capacity.
  final bool over;

  /// Share of the capacity used (0 when there is no capacity set).
  final double ratio;

  int get minutes => eventMinutes + taskMinutes;
  bool get isEmpty => eventCount == 0 && taskCount == 0;
}

String formatMinutes(int minutes) {
  if (minutes <= 0) return '0 min';
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// The load of [days] days starting at [from].
List<DayLoad> workloadFor(
  Workspace ws,
  DateTime from,
  int days,
  WorkloadSettings settings,
  WorkloadFilter filter,
) {
  final out = <DayLoad>[];
  for (var i = 0; i < days; i++) {
    final day = DateTime(from.year, from.month, from.day + i);
    var events = 0, tasks = 0, eventMin = 0;
    final items = ws.itemsOn(
      day,
      categories: filter.categories,
      includeTasks: true,
    );
    for (final item in items) {
      switch (item) {
        case EntryOnDay(:final entry):
          events++;
          eventMin += entry.durationMinutes ?? 0;
        case ExternalOnDay(:final event):
          if (!filter.includeConnected) continue;
          events++;
          if (!event.allDay) {
            final m = event.end.difference(event.start).inMinutes;
            if (m > 0 && m < 24 * 60) eventMin += m;
          }
        case TaskOnDay(:final task):
          if (!filter.taskPasses(task)) continue;
          tasks++;
      }
    }
    final taskMin = tasks * settings.minutesPerTask;
    final total = eventMin + taskMin;
    final capMin = settings.capacityMinutes;
    final capTasks = settings.capacityTasks;
    final over =
        (capMin != null && total > capMin) ||
        (capTasks != null && tasks > capTasks);
    final ratio = capMin != null && capMin > 0
        ? total / capMin
        : capTasks != null && capTasks > 0
        ? tasks / capTasks
        : 0.0;
    out.add(
      DayLoad(
        day: day,
        eventCount: events,
        taskCount: tasks,
        eventMinutes: eventMin,
        taskMinutes: taskMin,
        over: over,
        ratio: ratio,
      ),
    );
  }
  return out;
}

/// Unfinished tasks whose date has passed.
List<Task> overdueTasks(Workspace ws, DateTime today, WorkloadFilter f) => [
  for (final t in ws.tasks.all)
    if (!t.done &&
        t.dueDate != null &&
        dateOnly(t.dueDate!).isBefore(dateOnly(today)) &&
        f.taskPasses(t))
      t,
]..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));

/// Unfinished tasks with no date.
List<Task> unscheduledTasks(Workspace ws, WorkloadFilter f) => [
  for (final t in ws.tasks.all)
    if (!t.done && t.dueDate == null && t.parentId == null && f.taskPasses(t))
      t,
]..sort((a, b) => b.priority.compareTo(a.priority));

/// Monday of the week of [d].
DateTime weekStart(DateTime d) =>
    DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));

// --------------------------------------------------------------------- UI --

class CalendarWorkloadView extends StatefulWidget {
  const CalendarWorkloadView({
    super.key,
    required this.state,
    required this.anchor,
    required this.onDay,
  });

  final AppState state;
  final DateTime anchor;
  final void Function(DateTime day) onDay;

  @override
  State<CalendarWorkloadView> createState() => _CalendarWorkloadViewState();
}

class _CalendarWorkloadViewState extends State<CalendarWorkloadView> {
  static const _weeks = 4;
  AppState get s => widget.state;

  WorkloadSettings get _settings =>
      WorkloadSettings.fromJson(s.settings.get<Object>('workloadSettings'));
  WorkloadFilter get _filter =>
      WorkloadFilter.fromJson(s.settings.get<Object>('workloadFilter'));

  Future<void> _saveSettings(WorkloadSettings v) async {
    await s.settings.set('workloadSettings', v.toJson());
    if (mounted) setState(() {});
  }

  Future<void> _saveFilter(WorkloadFilter v) async {
    await s.settings.set('workloadFilter', v.toJson());
    if (mounted) setState(() {});
  }

  Future<void> _editCapacity() async {
    final cur = _settings;
    final hours = await promptText(
      context,
      title: 'Hours a day can hold',
      initial: cur.capacityMinutes == null
          ? ''
          : (cur.capacityMinutes! / 60).toString().replaceAll(RegExp(r'\.0$'), ''),
      hint: 'For example 6 (empty: no limit)',
      action: 'Next',
    );
    if (hours == null || !mounted) return;
    final tasks = await promptText(
      context,
      title: 'Tasks a day can hold',
      initial: cur.capacityTasks?.toString() ?? '',
      hint: 'For example 5 (empty: no limit)',
      action: 'Next',
    );
    if (tasks == null || !mounted) return;
    final each = await promptText(
      context,
      title: 'Minutes one task counts as',
      initial: '${cur.minutesPerTask}',
      hint: 'Tasks have no length of their own',
      action: 'Save',
    );
    if (each == null) return;
    final h = double.tryParse(hours.trim().replaceAll(',', '.'));
    await _saveSettings(
      WorkloadSettings(
        capacityMinutes: h != null && h > 0 ? (h * 60).round() : null,
        capacityTasks: int.tryParse(tasks.trim()) != null &&
                int.parse(tasks.trim()) > 0
            ? int.parse(tasks.trim())
            : null,
        minutesPerTask: (int.tryParse(each.trim()) ?? cur.minutesPerTask)
            .clamp(1, 600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.workspace.changes]),
      builder: (context, _) {
        final settings = _settings, filter = _filter;
        final start = weekStart(widget.anchor);
        final loads = workloadFor(s.workspace, start, _weeks * 7, settings, filter);
        final today = DateTime.now();
        final overdue = overdueTasks(s.workspace, today, filter);
        final loose = unscheduledTasks(s.workspace, filter);
        return Column(
          key: const ValueKey('workload-view'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _controls(settings, filter),
            const SizedBox(height: Space.sm),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final wide = box.maxWidth >= 760;
                  final days = _days(loads, settings, today);
                  final side = _side(overdue, loose);
                  return wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 3, child: days),
                            const SizedBox(width: Space.lg),
                            SizedBox(width: 260, child: side),
                          ],
                        )
                      : ListView(
                          children: [
                            SizedBox(height: 360, child: days),
                            side,
                          ],
                        );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _controls(WorkloadSettings settings, WorkloadFilter filter) {
    Widget chip(String key, String label, bool on, ValueChanged<bool> set) =>
        FilterChip(
          key: ValueKey(key),
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: on,
          onSelected: set,
        );
    final capacity = [
      if (settings.capacityMinutes != null)
        formatMinutes(settings.capacityMinutes!),
      if (settings.capacityTasks != null) '${settings.capacityTasks} tasks',
    ].join(' / ');
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('workload-capacity'),
          onPressed: _editCapacity,
          icon: const Icon(Icons.speed, size: 16),
          label: Text(capacity.isEmpty ? 'Set a daily capacity' : 'A day holds $capacity'),
        ),
        const SizedBox(width: 8),
        chip('wl-open', 'Not started', filter.showOpenTasks, (v) => _saveFilter(filter.copyWith(showOpenTasks: v))),
        chip('wl-doing', 'In progress', filter.showDoingTasks, (v) => _saveFilter(filter.copyWith(showDoingTasks: v))),
        chip('wl-done', 'Done', filter.showDoneTasks, (v) => _saveFilter(filter.copyWith(showDoneTasks: v))),
        const SizedBox(width: 8),
        for (final c in CalendarCategory.values)
          chip(
            'wl-cat-${c.name}',
            c.label,
            filter.categories.contains(c),
            (v) => _saveFilter(
              filter.copyWith(
                categories: {
                  ...filter.categories,
                }..let((set) => v ? set.add(c) : set.remove(c)),
              ),
            ),
          ),
        chip('wl-connected', 'Connected calendars', filter.includeConnected, (v) => _saveFilter(filter.copyWith(includeConnected: v))),
        const SizedBox(width: 8),
        DropdownButton<int>(
          key: const ValueKey('wl-priority'),
          value: filter.minPriority,
          underline: const SizedBox.shrink(),
          isDense: true,
          items: const [
            DropdownMenuItem(value: 0, child: Text('Any priority')),
            DropdownMenuItem(value: 1, child: Text('Low and up')),
            DropdownMenuItem(value: 2, child: Text('Medium and up')),
            DropdownMenuItem(value: 3, child: Text('High only')),
          ],
          onChanged: (v) => _saveFilter(filter.copyWith(minPriority: v ?? 0)),
        ),
      ],
    );
  }

  Widget _days(List<DayLoad> loads, WorkloadSettings settings, DateTime today) {
    final hasCapacity =
        settings.capacityMinutes != null || settings.capacityTasks != null;
    final children = <Widget>[];
    for (var w = 0; w < _weeks; w++) {
      final week = loads.sublist(w * 7, w * 7 + 7);
      final minutes = week.fold<int>(0, (n, d) => n + d.minutes);
      final overDays = week.where((d) => d.over).length;
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Text(
            'WEEK OF ${formatShortDate(week.first.day).toUpperCase()}  ·  '
            '${formatMinutes(minutes)}'
            '${overDays > 0 ? '  ·  $overDays over' : ''}',
            key: ValueKey('workload-week-$w'),
            style: TextStyle(fontSize: 11, letterSpacing: 0.5, color: AppColors.textFaint),
          ),
        ),
      );
      for (final d in week) {
        children.add(_dayRow(d, settings, today, hasCapacity));
      }
    }
    return ListView(children: children);
  }

  Widget _dayRow(DayLoad d, WorkloadSettings settings, DateTime today, bool hasCapacity) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final isToday = dateOnly(d.day) == dateOnly(today);
    final level = !hasCapacity
        ? AppColors.accent
        : d.over
        ? AppColors.danger
        : d.ratio >= 0.8
        ? AppColors.warm
        : AppColors.success;
    return InkWell(
      key: ValueKey('workload-day-${dayKey(d.day)}'),
      onTap: () => widget.onDay(d.day),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
        decoration: BoxDecoration(
          color: isToday ? AppColors.selected : null,
          border: Border(left: BorderSide(color: d.over ? AppColors.danger : Colors.transparent, width: 3)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 84,
              child: Text(
                '${names[d.day.weekday - 1]} ${d.day.day}/${d.day.month}',
                style: TextStyle(
                  fontWeight: isToday ? FontWeight.w600 : FontWeight.w400,
                  fontSize: 13,
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 10,
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: AppColors.cardRaised,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: FractionallySizedBox(
                  widthFactor: hasCapacity
                      ? (d.ratio.clamp(0.0, 1.0)).toDouble()
                      : (d.minutes / 480).clamp(0.0, 1.0).toDouble(),
                  child: Container(
                    decoration: BoxDecoration(
                      color: level,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 200,
              child: Text(
                d.isEmpty
                    ? 'free'
                    : '${d.eventCount} ev · ${d.taskCount} tasks · ${formatMinutes(d.minutes)}',
                key: ValueKey('workload-text-${dayKey(d.day)}'),
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
            SizedBox(
              width: 70,
              child: d.over
                  ? Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 15, color: AppColors.danger),
                        const SizedBox(width: 3),
                        Text(
                          'Over',
                          key: ValueKey('workload-over-${dayKey(d.day)}'),
                          style: TextStyle(fontSize: 12, color: AppColors.danger, fontWeight: FontWeight.w600),
                        ),
                      ],
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _side(List<Task> overdue, List<Task> loose) {
    Widget list(String title, List<Task> tasks, String emptyText, Key key) =>
        Column(
          key: key,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(
                '$title (${tasks.length})',
                style: TextStyle(fontSize: 11, letterSpacing: 0.5, color: AppColors.textFaint),
              ),
            ),
            if (tasks.isEmpty)
              Text(emptyText, style: TextStyle(fontSize: 12, color: AppColors.textFaint)),
            for (final t in tasks.take(30))
              ListTile(
                key: ValueKey('wl-task-${t.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: t.dueDate == null
                    ? null
                    : Text('was due ${formatShortDate(t.dueDate!)}', style: const TextStyle(fontSize: 11.5)),
                onTap: () => s.openTask(t.id),
              ),
          ],
        );
    return ListView(
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      children: [
        list('OVERDUE', overdue, 'Nothing is overdue.', const ValueKey('workload-overdue')),
        list('NO DATE YET', loose, 'Every open task has a date.', const ValueKey('workload-unscheduled')),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            'This view only shows what is already planned. It moves nothing.',
            style: TextStyle(fontSize: 11.5, color: AppColors.textFaint),
          ),
        ),
      ],
    );
  }
}

extension _Let<T> on T {
  void let(void Function(T) f) => f(this);
}
