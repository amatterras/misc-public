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
import '../tasks/estimate_label.dart';

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
    required this.onToggleEntry,
    this.overlay,
    this.dropOn,
    this.zoom,
    this.panEnabled = true,
    this.scaleEnabled = true,
  });

  /// When given, the whole grid can be zoomed in (pinch, or the zoom
  /// buttons that drive this controller) and moved while zoomed. At 100%
  /// it fills its area as before.
  final TransformationController? zoom;
  final bool panEnabled, scaleEnabled;

  /// Wraps each day so things can be dropped on it.
  final Widget Function(DateTime day, Widget cell)? dropOn;

  /// Drawn over each day (the Calendar drawings).
  final Widget Function(DateTime day)? overlay;

  final CalendarView view;
  final DateTime anchor;
  final ItemsOn itemsOn;
  final ValueChanged<DateTime> onDay;
  final void Function(DayItem item, DateTime day) onItem;
  final void Function(CalendarEntry entry, DateTime day) onToggleEntry;

  Widget _wrap(DateTime day, Widget cell) => dropOn?.call(day, cell) ?? cell;

  @override
  Widget build(BuildContext context) {
    final days = view.daysAround(anchor);
    final rows = (days.length / 7).ceil();
    final today = dateOnly(DateTime.now());
    final grid = Column(
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
                    style: TextStyle(
                      fontSize: AppType.sizeMeta,
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
                          child: _wrap(
                            days[r * 7 + c],
                            Stack(
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
                                  onToggleEntry: (entry) =>
                                      onToggleEntry(entry, days[r * 7 + c]),
                                ),
                                if (overlay != null) overlay!(days[r * 7 + c]),
                              ],
                            ),
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
    final viewer = zoom;
    if (viewer == null) return grid;
    return InteractiveViewer(
      key: const ValueKey('calendar-grid-zoom'),
      transformationController: viewer,
      minScale: 1,
      maxScale: 4,
      panEnabled: panEnabled,
      scaleEnabled: scaleEnabled,
      child: grid,
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
    required this.onToggleEntry,
  });

  final DateTime day;
  final List<DayItem> items;
  final bool isToday;
  final bool dimmed;
  final VoidCallback onTap;
  final ValueChanged<DayItem> onItem;
  final ValueChanged<CalendarEntry> onToggleEntry;

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
            final overflow = items.skip(shown.length).toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: AppType.sizeBody,
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
                  _ItemLabel(
                    item: item,
                    day: day,
                    onTap: () => onItem(item),
                    onToggleEntry: onToggleEntry,
                  ),
                if (overflow.isNotEmpty)
                  InkWell(
                    onTap: () => showAppDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text(formatLongDate(day)),
                        content: SizedBox(
                          width: 360,
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final item in overflow)
                                if (item case EntryOnDay(:final entry))
                                  CheckboxListTile(
                                    key: ValueKey(
                                      'overflow-entry-check-${entry.id}-${dayKey(day)}',
                                    ),
                                    value: entry.isCheckedOn(day),
                                    title: Text(entry.name),
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    onChanged: (_) {
                                      onToggleEntry(entry);
                                      Navigator.of(dialogContext).pop();
                                    },
                                  )
                                else
                                  ListTile(
                                    title: Text(item.label),
                                    onTap: () {
                                      Navigator.of(dialogContext).pop();
                                      onItem(item);
                                    },
                                  ),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    ),
                    child: SizedBox(
                      height: labelHeight,
                      child: Text(
                        '+${overflow.length} more',
                        style: TextStyle(
                          fontSize: AppType.sizeMicro,
                          color: AppColors.textFaint,
                        ),
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
  const _ItemLabel({
    required this.item,
    required this.day,
    required this.onTap,
    required this.onToggleEntry,
  });

  final DayItem item;
  final DateTime day;
  final VoidCallback onTap;
  final ValueChanged<CalendarEntry> onToggleEntry;

  @override
  Widget build(BuildContext context) {
    final entry = switch (item) {
      EntryOnDay(:final entry) => entry,
      _ => null,
    };
    final done = switch (item) {
      EntryOnDay(:final entry) => entry.isCheckedOn(day),
      TaskOnDay(:final task) => task.done,
      ExternalOnDay() => false,
    };
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        height: _CompactDayCell.labelHeight,
        child: Row(
          children: [
            if (entry != null)
              Semantics(
                key: ValueKey('entry-check-${entry.id}-${dayKey(day)}'),
                label: 'Mark ${entry.name} complete on ${formatLongDate(day)}',
                button: true,
                toggled: done,
                child: InkResponse(
                  radius: 14,
                  onTap: () => onToggleEntry(entry),
                  child: Icon(
                    done ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 15,
                    color: dayItemColor(item),
                  ),
                ),
              )
            else
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
                  fontSize: AppType.sizeMeta,
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
  TaskOnDay() ||
  ExternalOnDay() => calendarCategoryColor(CalendarCategory.events),
};

/// Days with something on them, in order, each with its items.
class CalendarAgendaView extends StatelessWidget {
  const CalendarAgendaView({
    super.key,
    required this.anchor,
    required this.itemsOn,
    required this.onDay,
    required this.onItem,
    required this.onToggleEntry,
  });

  final DateTime anchor;
  final ItemsOn itemsOn;
  final ValueChanged<DateTime> onDay;
  final void Function(DayItem item, DateTime day) onItem;
  final void Function(CalendarEntry entry, DateTime day) onToggleEntry;

  @override
  Widget build(BuildContext context) {
    final days = [
      for (final d in CalendarView.agenda.daysAround(anchor))
        if (itemsOn(d).isNotEmpty) d,
    ];
    if (days.isEmpty) {
      return Center(
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
                style: TextStyle(
                  fontSize: AppType.sizeBodySmall,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ),
          for (final item in itemsOn(d))
            ListTile(
              dense: true,
              leading: SizedBox(
                width: 42,
                child: item is EntryOnDay
                    ? Semantics(
                        key: ValueKey(
                          'entry-check-${item.entry.id}-${dayKey(d)}',
                        ),
                        label:
                            'Mark ${item.entry.name} complete on ${formatLongDate(d)}',
                        button: true,
                        toggled: item.entry.isCheckedOn(d),
                        child: Checkbox(
                          value: item.entry.isCheckedOn(d),
                          visualDensity: VisualDensity.compact,
                          onChanged: (_) => onToggleEntry(item.entry, d),
                        ),
                      )
                    : Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: dayItemColor(item),
                          shape: BoxShape.circle,
                        ),
                      ),
              ),
              title: Text(
                item.label,
                style: TextStyle(
                  decoration:
                      item is EntryOnDay && item.entry.isCheckedOn(d) ||
                          item is TaskOnDay && item.task.done
                      ? TextDecoration.lineThrough
                      : null,
                  color:
                      item is EntryOnDay && item.entry.isCheckedOn(d) ||
                          item is TaskOnDay && item.task.done
                      ? AppColors.textFaint
                      : null,
                ),
              ),
              subtitle: switch (item) {
                EntryOnDay(:final entry) => Text(
                  [entry.category.label, ?entry.timeLabel].join('  ·  '),
                  style: const TextStyle(fontSize: AppType.sizeMeta),
                ),
                TaskOnDay(:final task) => Row(
                  children: [
                    const Text(
                      'Task',
                      style: TextStyle(fontSize: AppType.sizeMeta),
                    ),
                    if (task.estimateMinutes != null) ...[
                      const SizedBox(width: 8),
                      EstimateLabel(task: task),
                    ],
                  ],
                ),
                ExternalOnDay(:final event) => Text(
                  event.provider == 'google' ? 'Google Calendar' : 'Outlook',
                  style: const TextStyle(fontSize: AppType.sizeMeta),
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
    required this.onToggleEntry,
  });

  final DateTime anchor;
  final ItemsOn itemsOn;
  final void Function(DayItem item, DateTime day) onItem;
  final void Function(CalendarEntry entry, DateTime day) onToggleEntry;

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
                      border: Border(left: BorderSide(color: AppColors.border)),
                    ),
                    alignment: Alignment.topCenter,
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${days[i].day}',
                      style: TextStyle(
                        fontSize: AppType.sizeMicro,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ),
                ),
              if (rows.isEmpty)
                Positioned(
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
                      style: const TextStyle(fontSize: AppType.sizeLabel),
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
                          borderRadius: BorderRadius.circular(AppRadii.xs),
                        ),
                      ),
                    ),
                  ),
                if (rows[r].$1 case EntryOnDay(:final entry))
                  for (final (from, to) in rows[r].$2)
                    for (var i = from; i <= to; i++)
                      Positioned(
                        left: labelWidth + i * dayWidth + 3,
                        top: (r + 1) * rowHeight + 2,
                        width: dayWidth - 6,
                        height: rowHeight - 4,
                        child: Semantics(
                          key: ValueKey(
                            'entry-check-${entry.id}-${dayKey(days[i])}',
                          ),
                          label:
                              'Mark ${entry.name} complete on ${formatLongDate(days[i])}',
                          button: true,
                          toggled: entry.isCheckedOn(days[i]),
                          child: Tooltip(
                            message: formatLongDate(days[i]),
                            child: InkResponse(
                              radius: 14,
                              onTap: () => onToggleEntry(entry, days[i]),
                              child: Icon(
                                entry.isCheckedOn(days[i])
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank,
                                size: 15,
                                color: dayItemColor(rows[r].$1),
                              ),
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
