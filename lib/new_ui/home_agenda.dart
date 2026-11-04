// What the iPhone Home shows for one day, computed from the existing
// Calendar and Task data (Workspace.itemsOn and the task records). No data
// of its own and no second calendar engine: this only sorts what Calendar
// already knows into Home's sections.
import 'package:flutter/material.dart';

import '../data/models/calendar_models.dart';
import '../data/models/record.dart';
import '../data/workspace.dart';
import '../widgets/common.dart' show calendarCategoryColor;

enum HomeKind { task, event, habit, reading, reminder, external }

extension HomeKindInfo on HomeKind {
  String get label => switch (this) {
    HomeKind.task => 'Task',
    HomeKind.event => 'Event',
    HomeKind.habit => 'Habit',
    HomeKind.reading => 'Reading',
    HomeKind.reminder => 'Reminder',
    HomeKind.external => 'Calendar',
  };

  IconData get icon => switch (this) {
    HomeKind.task => Icons.check_circle_outline,
    HomeKind.event => Icons.event_outlined,
    HomeKind.habit => Icons.repeat,
    HomeKind.reading => Icons.menu_book_outlined,
    HomeKind.reminder => Icons.notifications_none,
    HomeKind.external => Icons.cloud_outlined,
  };

  /// The existing Calendar category colours (tasks use the Events colour,
  /// as they do in Calendar).
  Color get color => switch (this) {
    HomeKind.task => calendarCategoryColor(CalendarCategory.events),
    HomeKind.event => calendarCategoryColor(CalendarCategory.events),
    HomeKind.habit => calendarCategoryColor(CalendarCategory.habits),
    HomeKind.reading => calendarCategoryColor(CalendarCategory.reading),
    HomeKind.reminder => calendarCategoryColor(CalendarCategory.other),
    HomeKind.external => calendarCategoryColor(CalendarCategory.events),
  };
}

/// One thing on Home: an existing Calendar day item seen on [day].
class HomeItem {
  const HomeItem(this.item, this.day);

  final DayItem item;
  final DateTime day;

  String get id => item.id;
  String get title => item.label;

  HomeKind get kind => switch (item) {
    TaskOnDay() => HomeKind.task,
    ExternalOnDay() => HomeKind.external,
    EntryOnDay(:final entry) => switch (entry.category) {
      CalendarCategory.events => HomeKind.event,
      CalendarCategory.habits => HomeKind.habit,
      CalendarCategory.reading => HomeKind.reading,
      CalendarCategory.other => HomeKind.reminder,
    },
  };

  /// Calendar finished-state of this occurrence (tasks, and the per-day
  /// check-offs of every entry kind).
  bool get done => switch (item) {
    TaskOnDay(:final task) => task.done,
    EntryOnDay(:final entry) => entry.checkoffs.contains(dayKey(day)),
    ExternalOnDay() => false,
  };

  /// Everything but a read-only Google/Outlook event can be ticked.
  bool get completable => item is! ExternalOnDay;

  int? get startMinutes => switch (item) {
    TaskOnDay(:final task) => task.dueMinutes,
    EntryOnDay(:final entry) => entry.startMinutes,
    ExternalOnDay(:final event) => event.startMinutes,
  };

  int? get endMinutes {
    final start = startMinutes;
    if (start == null) return null;
    return switch (item) {
      EntryOnDay(:final entry) when entry.durationMinutes != null =>
        start + entry.durationMinutes!,
      ExternalOnDay(:final event) =>
        start + event.end.difference(event.start).inMinutes,
      _ => null,
    };
  }

  /// "09:00" or "09:00–10:00" (24-hour, as Calendar writes it).
  String? get timeLabel {
    final start = startMinutes;
    if (start == null) return null;
    final end = endMinutes;
    if (end == null || end <= start) return formatClock(start);
    return '${formatClock(start)}–${formatClock(end % (24 * 60))}';
  }

  /// A short second line from what the record already holds.
  String get subtitle => switch (item) {
    TaskOnDay(:final task) => task.notes.trim().split('\n').first,
    EntryOnDay(:final entry) =>
      entry.category == CalendarCategory.reading &&
              entry.totalPages != null &&
              entry.totalPages! > 0
          ? 'Page ${entry.currentPage} of ${entry.totalPages}'
          : entry.description.trim().split('\n').first,
    ExternalOnDay(:final event) =>
      event.location.isNotEmpty ? event.location : '',
  };
}

String formatClock(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

class HomeAgenda {
  const HomeAgenda({
    required this.day,
    required this.overdue,
    required this.allDay,
    required this.timed,
    required this.unscheduled,
    required this.completed,
    required this.remaining,
    required this.upcomingEvents,
  });

  final DateTime day;

  /// Open tasks dated before today (only filled for today).
  final List<HomeItem> overdue;

  /// Entries and calendar events of the day without a time of day.
  final List<HomeItem> allDay;

  /// Items with a time, by hour (0–23), each hour sorted by time. Hours
  /// without items are not present at all.
  final Map<int, List<HomeItem>> timed;

  /// Tasks without a time (the day's own, and, for today, open tasks that
  /// have no date).
  final List<HomeItem> unscheduled;

  final int completed;
  final int remaining;
  final int upcomingEvents;

  int get total =>
      overdue.length +
      allDay.length +
      timed.values.fold<int>(0, (n, l) => n + l.length) +
      unscheduled.length;

  double get progress {
    final all = completed + remaining;
    return all == 0 ? 0 : completed / all;
  }

  /// The hours that are shown: those with items, ascending.
  List<int> get hours => timed.keys.toList()..sort();

  static HomeAgenda build(Workspace ws, DateTime day, {DateTime? now}) {
    now ??= DateTime.now();
    final today = dateOnly(now);
    final d = dateOnly(day);
    final isToday = daysBetween(d, today) == 0;
    final items = [for (final i in ws.itemsOn(d)) HomeItem(i, d)];

    final allDay = <HomeItem>[];
    final unscheduled = <HomeItem>[];
    final timed = <int, List<HomeItem>>{};
    for (final item in items) {
      final minutes = item.startMinutes;
      if (minutes != null) {
        (timed[minutes ~/ 60] ??= []).add(item);
      } else if (item.kind == HomeKind.task) {
        unscheduled.add(item);
      } else {
        allDay.add(item);
      }
    }
    for (final list in timed.values) {
      list.sort((a, b) => a.startMinutes!.compareTo(b.startMinutes!));
    }

    final overdue = <HomeItem>[];
    if (isToday) {
      final late = [
        for (final t in ws.tasks.all)
          if (!t.done && t.dueDate != null && daysBetween(t.dueDate!, d) > 0) t,
      ]..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
      for (final t in late) {
        overdue.add(HomeItem(TaskOnDay(t, CalendarCategory.events.index), d));
      }
      // Open tasks that have no date at all are not "overdue"; they wait in
      // Unscheduled.
      for (final t in ws.tasks.all) {
        if (!t.done && t.dueDate == null && t.parentId == null) {
          unscheduled.add(
            HomeItem(TaskOnDay(t, CalendarCategory.events.index), d),
          );
        }
      }
    }

    var completed = 0;
    var remaining = overdue.length;
    for (final item in [
      ...allDay,
      ...unscheduled,
      for (final l in timed.values) ...l,
    ]) {
      if (!item.completable) continue;
      // Undated tasks are a backlog, not part of "today".
      final undated =
          item.item is TaskOnDay &&
          (item.item as TaskOnDay).task.dueDate == null;
      if (undated) continue;
      item.done ? completed++ : remaining++;
    }

    var upcoming = 0;
    if (daysBetween(today, d) > 0) {
      upcoming = items.where((i) => i.kind == HomeKind.event).length;
    } else if (isToday) {
      final nowMinutes = now.hour * 60 + now.minute;
      for (final i in items) {
        if (i.kind != HomeKind.event && i.kind != HomeKind.external) continue;
        final start = i.startMinutes;
        if (start == null || start >= nowMinutes) upcoming++;
      }
    }

    return HomeAgenda(
      day: d,
      overdue: overdue,
      allDay: allDay,
      timed: timed,
      unscheduled: unscheduled,
      completed: completed,
      remaining: remaining,
      upcomingEvents: upcoming,
    );
  }

  /// The small coloured marks under a date in the date strip: one per kind
  /// present (at most [max]), in the existing Calendar colours.
  static List<Color> markers(Workspace ws, DateTime day, {int max = 4}) {
    final seen = <HomeKind>{};
    for (final item in ws.itemsOn(dateOnly(day))) {
      seen.add(HomeItem(item, day).kind);
    }
    final colors = <Color>[];
    for (final kind in HomeKind.values) {
      if (!seen.contains(kind)) continue;
      final color = kind.color;
      if (!colors.contains(color)) colors.add(color);
      if (colors.length == max) break;
    }
    return colors;
  }
}
