// The personal activity timeline: what was created, edited, completed or
// opened recently. Worked out from the records themselves (their dates)
// plus a short list of recently opened items kept on this device, so
// nothing extra is synced and no statistics are kept.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/models/record.dart';

enum ActivityKind { created, edited, completed, opened }

class ActivityEvent {
  const ActivityEvent(
    this.at,
    this.kind,
    this.what,
    this.title,
    this.icon,
    this.open,
  );
  final DateTime at;
  final ActivityKind kind;

  /// "note", "task", "mindmap", "calendar entry".
  final String what;
  final String title;
  final IconData icon;
  final VoidCallback open;

  String get verb => switch (kind) {
    ActivityKind.created => 'Created',
    ActivityKind.edited => 'Edited',
    ActivityKind.completed => 'Completed',
    ActivityKind.opened => 'Opened',
  };
}

/// Recent activity, newest first, at most [limit], from the last [days].
List<ActivityEvent> activityTimeline(
  AppState s, {
  int limit = 30,
  int days = 14,
  DateTime? now,
}) {
  final ws = s.workspace;
  final since = (now ?? DateTime.now()).subtract(Duration(days: days));
  final events = <ActivityEvent>[];
  void add(ActivityEvent e) {
    if (e.at.isAfter(since)) events.add(e);
  }

  for (final n in ws.notes.all) {
    add(
      ActivityEvent(
        n.createdAt,
        ActivityKind.created,
        'note',
        n.displayTitle,
        Icons.description_outlined,
        () => s.openNote(n.id),
      ),
    );
    if (n.updatedAt.difference(n.createdAt).inMinutes >= 1) {
      add(
        ActivityEvent(
          n.updatedAt,
          ActivityKind.edited,
          'note',
          n.displayTitle,
          Icons.edit_note,
          () => s.openNote(n.id),
        ),
      );
    }
  }
  for (final t in ws.tasks.all) {
    add(
      ActivityEvent(
        t.createdAt,
        ActivityKind.created,
        'task',
        t.title,
        Icons.add_task,
        () => s.openTask(t.id),
      ),
    );
    final done = t.completedAt;
    if (done != null) {
      add(
        ActivityEvent(
          done,
          ActivityKind.completed,
          'task',
          t.title,
          Icons.check_circle_outline,
          () => s.openTask(t.id),
        ),
      );
    }
  }
  for (final c in s.canvasList) {
    add(
      ActivityEvent(
        c.updatedAt,
        ActivityKind.edited,
        'mindmap',
        c.title,
        Icons.hub_outlined,
        () => s.openCanvas(c.id),
      ),
    );
  }
  for (final e in ws.entries.all) {
    add(
      ActivityEvent(
        e.createdAt,
        ActivityKind.created,
        'calendar entry',
        e.name,
        Icons.event_outlined,
        () => s.goTo(AppPage.calendar),
      ),
    );
  }
  for (final v in s.recentVisits) {
    final title = switch (v.kind) {
      'note' => ws.notes[v.id]?.displayTitle,
      'mindmap' => s.canvasList.where((c) => c.id == v.id).firstOrNull?.title,
      _ => null,
    };
    if (title == null) continue;
    add(
      ActivityEvent(
        v.at,
        ActivityKind.opened,
        v.kind,
        title,
        Icons.visibility_outlined,
        () => v.kind == 'note' ? s.openNote(v.id) : s.openCanvas(v.id),
      ),
    );
  }
  events.sort((a, b) => b.at.compareTo(a.at));
  return events.take(limit).toList();
}

/// "Today", "Yesterday" or the date, for grouping the timeline.
String activityDayLabel(
  DateTime at,
  DateTime now,
  String Function(DateTime) format,
) {
  final d = daysBetween(at, now);
  return d == 0
      ? 'Today'
      : d == 1
      ? 'Yesterday'
      : format(at);
}
