// What the iPhone/iPad home-screen widgets show: today's and tomorrow's
// tasks and calendar entries. The snapshot is DERIVED, display-only data,
// rebuilt from the tasks and calendar each time they change. It is never
// read back by the app and never synced, so it can't change or lose
// anything; deleting it only empties the widget until the next update.
//
// The Swift widget (ios/TheAppWidget) reads the same JSON from the App
// Group folder. Format version 1:
// {"version":1,"generatedAt":"…","days":[{"date":"2026-10-23",
//   "title":"Today","link":"theapp://open?day=2026-10-23","total":7,
//   "items":[{"kind":"task","title":"…","time":"09:30","done":false,
//             "color":4294…,"link":"theapp://open?task=…"}]}]}
import '../../app/theme.dart';
import '../../data/models/record.dart';
import '../../data/workspace.dart';
import '../../widgets/common.dart';

class WidgetSnapshot {
  /// Items kept per day; the widget shows as many as fit and "+N more"
  /// for the rest of [total].
  static const maxItemsPerDay = 12;

  static const version = 1;

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String dateKey(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String? _time(int? minutes) =>
      minutes == null ? null : '${_two(minutes ~/ 60)}:${_two(minutes % 60)}';

  /// Deep link that opens [item] in the app.
  static String linkFor(DayItem item, DateTime day) => switch (item) {
    TaskOnDay(:final task) =>
      'theapp://open?task=${Uri.encodeComponent(task.id)}',
    EntryOnDay() || ExternalOnDay() => 'theapp://open?day=${dateKey(day)}',
  };

  /// The snapshot for [now]'s day and the next one.
  static Map<String, Object?> build(Workspace ws, DateTime now) {
    final today = dateOnly(now);
    return {
      'version': version,
      'generatedAt': now.toUtc().toIso8601String(),
      'days': [
        for (final (i, title) in [(0, 'Today'), (1, 'Tomorrow')])
          _day(ws, addDays(today, i), title),
      ],
    };
  }

  static Map<String, Object?> _day(Workspace ws, DateTime day, String title) {
    final items = ws.itemsOn(day);
    return {
      'date': dateKey(day),
      'title': title,
      'link': 'theapp://open?day=${dateKey(day)}',
      'total': items.length,
      'items': [
        for (final item in items.take(maxItemsPerDay))
          {
            'kind': item is TaskOnDay ? 'task' : 'event',
            'title': item.label.trim().isEmpty ? 'Untitled' : item.label.trim(),
            'time': switch (item) {
              TaskOnDay(:final task) => _time(task.dueMinutes),
              EntryOnDay(:final entry) => _time(entry.startMinutes),
              ExternalOnDay(:final event) => _time(event.startMinutes),
            },
            'done': item is TaskOnDay && item.task.done,
            'color': switch (item) {
              EntryOnDay(:final entry) => calendarCategoryColor(entry.category),
              TaskOnDay() ||
              ExternalOnDay() => CalendarCategoryColors.reminderEvent,
            }.toARGB32(),
            'link': linkFor(item, day),
          },
      ],
    };
  }

  /// What a deep link from a widget asks for, or null if it is not one.
  static ({String? taskId, DateTime? day})? parseLink(Uri uri) {
    if (uri.scheme != 'theapp' || uri.host != 'open') return null;
    final task = uri.queryParameters['task'];
    final dayText = uri.queryParameters['day'];
    final day = dayText == null ? null : DateTime.tryParse(dayText);
    if ((task == null || task.isEmpty) && day == null) return null;
    return (taskId: task, day: day == null ? null : dateOnly(day));
  }
}
