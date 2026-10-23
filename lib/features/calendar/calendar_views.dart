// Month, week, day, agenda and timeline views of the Calendar, next to the
// custom range of up to 38 days. Every view shows the same entries and
// tasks (Workspace.itemsOn), with the same category and color filters;
// nothing is copied.
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/record.dart';
import '../../data/workspace.dart';
import '../../widgets/common.dart';

enum CalendarView { range, month, week, day, agenda, timeline }

extension CalendarViewInfo on CalendarView {
  String get label => switch (this) {
    CalendarView.range => 'Range',
    CalendarView.month => 'Month',
    CalendarView.week => 'Week',
    CalendarView.day => 'Day',
    CalendarView.agenda => 'Agenda',
    CalendarView.timeline => 'Timeline',
  };

  /// Days the agenda and timeline show from their start.
  static const listDays = 30;

  /// The days a view shows around [anchor].
  List<DateTime> daysAround(DateTime anchor) {
    final a = dateOnly(anchor);
    switch (this) {
      case CalendarView.month:
        final first = DatePrefs.weekStart(DateTime(a.year, a.month));
        return [for (var i = 0; i < 42; i++) addDays(first, i)];
      case CalendarView.week:
        final first = DatePrefs.weekStart(a);
        return [for (var i = 0; i < 7; i++) addDays(first, i)];
      case CalendarView.day:
        return [a];
      case CalendarView.agenda || CalendarView.timeline:
        return [for (var i = 0; i < listDays; i++) addDays(a, i)];
      case CalendarView.range:
        return const [];
    }
  }

  /// The anchor one step later ([forward]) or earlier.
  DateTime step(DateTime anchor, {required bool forward}) {
    final k = forward ? 1 : -1;
    return switch (this) {
      CalendarView.month => DateTime(anchor.year, anchor.month + k),
      CalendarView.week => addDays(anchor, 7 * k),
      CalendarView.day => addDays(anchor, k),
      CalendarView.agenda ||
      CalendarView.timeline => addDays(anchor, listDays * k),
      CalendarView.range => anchor,
    };
  }

  String title(DateTime anchor) {
    final days = daysAround(anchor);
    return switch (this) {
      CalendarView.month => formatMonth(anchor),
      CalendarView.day => formatLongDate(anchor),
      CalendarView.range => '',
      _ => '${formatShortDate(days.first)} – ${formatShortDate(days.last)}',
    };
  }
}

/// Which items the views show (the page's filters).
typedef ItemsOn = List<DayItem> Function(DateTime day);

/// Month (6 weeks) or week grid of compact day cells.
class CalendarGridView extends StatelessWidget {
  const CalendarGridView({
    super.key,
    required this.view,
    required this.anchor,
    required this.itemsOn,
    required this.onDay,
    required this.onItem,
    this.overlay,
  });

  /// Drawn over each day (the Calendar drawings).
  final Widget Function(DateTime day)? overlay;

  final CalendarView view;
  final DateTime anchor;
  final ItemsOn itemsOn;
  final ValueChanged<DateTime> onDay;
  final void Function(DayItem item, DateTime day) onItem;

  @override
  Widget build(BuildContext context) {
    final days = view.daysAround(anchor);
    final rows = (days.length / 7).ceil();
    final today = dateOnly(DateTime.now());
    return Column(
      key: ValueKey('calendar-${view.name}'),
      children: [
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  child: Text(
                    weekdayShort(days[i]).toUpperCase(),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textFaint,
                    ),
                  ),
                ),
              ),
          ],
        ),
        Expanded(
          child: Column(
            children: [
              for (var r = 0; r < rows; r++)
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var c = 0; c < 7; c++)
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _CompactDayCell(
                                day: days[r * 7 + c],
                                items: itemsOn(days[r * 7 + c]),
                                isToday:
                                    daysBetween(today, days[r * 7 + c]) == 0,
                                dimmed:
                                    view == CalendarView.month &&
                                    days[r * 7 + c].month != anchor.month,
                                onTap: () => onDay(days[r * 7 + c]),
                                onItem: (i) => onItem(i, days[r * 7 + c]),
                              ),
                              if (overlay != null) overlay!(days[r * 7 + c]),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactDayCell extends StatelessWidget {
  const _CompactDayCell({
    required this.day,
    required this.items,
    required this.isToday,
    required this.dimmed,
    required this.onTap,
    required this.onItem,
  });

  final DateTime day;
  final List<DayItem> items;
  final bool isToday;
  final bool dimmed;
  final VoidCallback onTap;
  final ValueChanged<DayItem> onItem;

  static const labelHeight = 18.0;

  @override
  Widget build(BuildContext context) => Material(
    color: dimmed ? AppColors.background : AppColors.card,
    child: InkWell(
      key: ValueKey('calendar-cell-${dayKey(day)}'),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.background),
        ),
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: LayoutBuilder(
          builder: (context, box) {
            // Date top-left, labels bottom-left, as many as fit.
            final room = ((box.maxHeight - 22) / labelHeight).floor();
            final fit = room < 0 ? 0 : room;
            final shown = items.length > fit && fit > 0
                ? items.take(fit - 1).toList()
                : items.take(fit).toList();
            final more = items.length - shown.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isToday
                        ? AppColors.accent
                        : dimmed
                        ? AppColors.textFaint
                        : AppColors.text,
                  ),
                ),
                const Spacer(),
                for (final item in shown)
                  _ItemLabel(item: item, onTap: () => onItem(item)),
                if (more > 0)
                  SizedBox(
                    height: labelHeight,
                    child: Text(
                      '+$more more',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _ItemLabel extends StatelessWidget {
  const _ItemLabel({required this.item, required this.onTap});

  final DayItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final done = item is TaskOnDay && (item as TaskOnDay).task.done;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        height: _CompactDayCell.labelHeight,
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: dayItemColor(item),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  decoration: done ? TextDecoration.lineThrough : null,
                  color: done ? AppColors.textFaint : AppColors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The color of a calendar item (its category color; tasks use the
/// Reminder/Event color).
Color dayItemColor(DayItem item) => switch (item) {
  EntryOnDay(:final entry) => calendarCategoryColor(entry.category),
  TaskOnDay() => calendarCategoryColor(CalendarCategory.events),
};

/// Days with something on them, in order, each with its items.
class CalendarAgendaView extends StatelessWidget {
  const CalendarAgendaView({
    super.key,
    required this.anchor,
    required this.itemsOn,
    required this.onDay,
    required this.onItem,
  });

  final DateTime anchor;
  final ItemsOn itemsOn;
  final ValueChanged<DateTime> onDay;
  final void Function(DayItem item, DateTime day) onItem;

  @override
  Widget build(BuildContext context) {
    final days = [
      for (final d in CalendarView.agenda.daysAround(anchor))
        if (itemsOn(d).isNotEmpty) d,
    ];
    if (days.isEmpty) {
      return const Center(
        key: ValueKey('calendar-agenda'),
        child: Text(
          'Nothing planned in these 30 days.',
          style: TextStyle(color: AppColors.textFaint),
        ),
      );
    }
    return ListView(
      key: const ValueKey('calendar-agenda'),
      children: [
        for (final d in days) ...[
          InkWell(
            onTap: () => onDay(d),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
              child: Text(
                formatLongDate(d),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ),
          for (final item in itemsOn(d))
            ListTile(
              dense: true,
              leading: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: dayItemColor(item),
                  shape: BoxShape.circle,
                ),
              ),
              title: Text(
                item.label,
                style: TextStyle(
                  decoration: item is TaskOnDay && item.task.done
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
              subtitle: switch (item) {
                EntryOnDay(:final entry) => Text(
                  [entry.category.label, ?entry.timeLabel].join('  ·  '),
                  style: const TextStyle(fontSize: 11),
                ),
                TaskOnDay() => const Text(
                  'Task',
                  style: TextStyle(fontSize: 11),
                ),
              },
              onTap: () => onItem(item, d),
            ),
        ],
      ],
    );
  }
}

/// Entries and tasks as bars across 30 days (multi-day events span their
/// days). Dates only: this is not a time-blocking view.
class CalendarTimelineView extends StatelessWidget {
  const CalendarTimelineView({
    super.key,
    required this.anchor,
    required this.itemsOn,
    required this.onItem,
  });

  final DateTime anchor;
  final ItemsOn itemsOn;
  final void Function(DayItem item, DateTime day) onItem;

  static const dayWidth = 34.0;
  static const rowHeight = 28.0;
  static const labelWidth = 180.0;

  /// Each item with the runs of consecutive day indexes it occurs on.
  static List<(DayItem, List<(int, int)>)> lanes(
    List<DateTime> days,
    ItemsOn itemsOn,
  ) {
    final order = <String>[];
    final items = <String, DayItem>{};
    final on = <String, List<int>>{};
    for (var i = 0; i < days.length; i++) {
      for (final item in itemsOn(days[i])) {
        if (!items.containsKey(item.id)) {
          order.add(item.id);
          items[item.id] = item;
        }
        on.putIfAbsent(item.id, () => []).add(i);
      }
    }
    return [for (final id in order) (items[id]!, _runs(on[id]!))];
  }

  static List<(int, int)> _runs(List<int> indexes) {
    final runs = <(int, int)>[];
    for (final i in indexes) {
      if (runs.isNotEmpty && runs.last.$2 == i - 1) {
        runs.last = (runs.last.$1, i);
      } else {
        runs.add((i, i));
      }
    }
    return runs;
  }

  @override
  Widget build(BuildContext context) {
    final days = CalendarView.timeline.daysAround(anchor);
    final rows = lanes(days, itemsOn);
    final today = dateOnly(DateTime.now());
    final height = (rows.length + 1) * rowHeight;
    return SingleChildScrollView(
      key: const ValueKey('calendar-timeline'),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: labelWidth + days.length * dayWidth,
          height: height < 200 ? 200 : height,
          child: Stack(
            children: [
              for (var i = 0; i < days.length; i++)
                Positioned(
                  left: labelWidth + i * dayWidth,
                  top: 0,
                  bottom: 0,
                  width: dayWidth,
                  child: Container(
                    decoration: BoxDecoration(
                      color: daysBetween(days[i], today) == 0
                          ? AppColors.accent.withValues(alpha: 0.12)
                          : null,
                      border: const Border(
                        left: BorderSide(color: AppColors.border),
                      ),
                    ),
                    alignment: Alignment.topCenter,
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${days[i].day}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ),
                ),
              if (rows.isEmpty)
                const Positioned(
                  left: 0,
                  top: 60,
                  child: Text(
                    'Nothing planned in these 30 days.',
                    style: TextStyle(color: AppColors.textFaint),
                  ),
                ),
              for (var r = 0; r < rows.length; r++) ...[
                Positioned(
                  left: 0,
                  top: (r + 1) * rowHeight,
                  width: labelWidth - 8,
                  height: rowHeight,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      rows[r].$1.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                for (final (from, to) in rows[r].$2)
                  Positioned(
                    left: labelWidth + from * dayWidth + 2,
                    top: (r + 1) * rowHeight + 5,
                    width: (to - from + 1) * dayWidth - 4,
                    height: rowHeight - 10,
                    child: GestureDetector(
                      onTap: () => onItem(rows[r].$1, days[from]),
                      child: Container(
                        decoration: BoxDecoration(
                          color: dayItemColor(rows[r].$1)
                              .withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
