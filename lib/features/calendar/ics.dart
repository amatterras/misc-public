// Calendar files (.ics, RFC 5545) for other calendar apps. Export: active
// calendar entries on their days and tasks with a due date. Import: each
// event becomes a line in that day's notes ("10:00 Dentist"), so it never
// breaks the five-active-entries rule; importing the same file twice adds
// nothing new. Live two-way sync with Google or Outlook needs their OAuth
// apps and is not part of THEapp (see docs/history/THEAPP_IMPLEMENTATION_HANDOFF.md).
import 'dart:convert';

import '../../data/models/calendar_models.dart';
import '../../data/models/record.dart';
import '../../data/workspace.dart';

String _esc(String s) => s
    .replaceAll('\\', '\\\\')
    .replaceAll(';', '\\;')
    .replaceAll(',', '\\,')
    .replaceAll(RegExp(r'\r?\n'), '\\n');

/// One pass, so an escaped backslash followed by "n" (`\\n`) stays a
/// backslash and an "n" instead of becoming a line break.
String _unesc(String s) => s.replaceAllMapped(
  RegExp(r'\\([\\;,nN])'),
  (m) => switch (m[1]!) {
    'n' || 'N' => '\n',
    final c => c,
  },
);

String _two(int v) => v.toString().padLeft(2, '0');
String _date(DateTime d) => '${d.year}${_two(d.month)}${_two(d.day)}';
String _stamp(DateTime d) {
  final u = d.toUtc();
  return '${_date(u)}T${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
}

/// Folds lines longer than 75 octets (UTF-8), as RFC 5545 asks, never
/// inside a character (an emoji cut in half would be written as U+FFFD).
/// Continuation lines start with a space, so they hold 74 octets of text.
String _fold(String line) {
  if (utf8.encode(line).length <= 75) return line;
  final b = StringBuffer();
  var octets = 0;
  var limit = 75;
  for (final rune in line.runes) {
    final ch = String.fromCharCode(rune);
    final size = utf8.encode(ch).length;
    if (octets + size > limit) {
      b.write('\r\n ');
      octets = 0;
      limit = 74;
    }
    b.write(ch);
    octets += size;
  }
  return b.toString();
}

String calendarIcs(Workspace ws, {DateTime? now}) {
  final stamp = _stamp(now ?? DateTime.now());
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//THEapp//Calendar export//EN',
    'CALSCALE:GREGORIAN',
  ];
  void event(
    String uid,
    DateTime day,
    String title,
    String desc,
    int? min,
    int? dur,
  ) {
    lines.add('BEGIN:VEVENT');
    lines.add('UID:$uid@theapp');
    lines.add('DTSTAMP:$stamp');
    if (min == null) {
      lines.add('DTSTART;VALUE=DATE:${_date(day)}');
      lines.add(
        'DTEND;VALUE=DATE:${_date(DateTime(day.year, day.month, day.day + 1))}',
      );
    } else {
      final start = DateTime(day.year, day.month, day.day, min ~/ 60, min % 60);
      lines.add(
        'DTSTART:${_date(start)}T${_two(start.hour)}${_two(start.minute)}00',
      );
      final end = start.add(Duration(minutes: dur ?? 60));
      lines.add('DTEND:${_date(end)}T${_two(end.hour)}${_two(end.minute)}00');
    }
    lines.add('SUMMARY:${_esc(title)}');
    if (desc.isNotEmpty) lines.add('DESCRIPTION:${_esc(desc)}');
    lines.add('END:VEVENT');
  }

  for (final e in ws.entries.all.where((e) => !e.archived)) {
    for (final key in _exportDays(e)) {
      event(
        '${e.id}-$key',
        parseDayKey(key),
        e.name,
        [
          e.category.label,
          e.description,
        ].where((s) => s.isNotEmpty).join(' — '),
        e.startMinutes,
        e.durationMinutes,
      );
    }
  }
  for (final t in ws.tasks.all.where((t) => t.dueDate != null && !t.done)) {
    event('task-${t.id}', t.dueDate!, t.title, t.notes, t.dueMinutes, null);
  }
  lines.add('END:VCALENDAR');
  return '${lines.map(_fold).join('\r\n')}\r\n';
}

/// Longest event span written out day by day (a mistyped end date years
/// later must not produce a giant file).
const _maxEventDays = 366;

/// The days (day keys, sorted) an entry is exported on: each date of an
/// "other" entry, and every day an event spans (events keep their days in
/// startDate..endDate, not in `dates`). Habits recur without end and reading
/// days are a log, so neither is exported.
List<String> _exportDays(CalendarEntry e) {
  final days = <String>{...e.dates};
  final start = e.startDate;
  if (e.category == CalendarCategory.events && start != null) {
    final end = e.endDate ?? start;
    final span = daysBetween(start, end).clamp(0, _maxEventDays - 1);
    for (var i = 0; i <= span; i++) {
      days.add(dayKey(addDays(start, i)));
    }
  }
  return days.toList()..sort();
}

/// An event read from a calendar file.
typedef IcsEvent = ({DateTime day, int? minutes, String title});

List<IcsEvent> parseIcs(String text) {
  // Unfold continuation lines first.
  final unfolded = text.replaceAll(RegExp(r'\r?\n[ \t]'), '');
  final events = <IcsEvent>[];
  Map<String, String>? cur;
  for (final raw in unfolded.split(RegExp(r'\r?\n'))) {
    final line = raw.trimRight();
    if (line == 'BEGIN:VEVENT') {
      cur = {};
    } else if (line == 'END:VEVENT') {
      final c = cur;
      cur = null;
      if (c == null) continue;
      final start = c['DTSTART'];
      final m = start == null
          ? null
          : RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2}))?')
                .firstMatch(start);
      if (m == null) continue;
      var day = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
      int? minutes;
      if (m[4] != null) {
        var t = DateTime(
          day.year,
          day.month,
          day.day,
          int.parse(m[4]!),
          int.parse(m[5]!),
        );
        if (start!.endsWith('Z')) {
          t = DateTime.utc(
            day.year,
            day.month,
            day.day,
            int.parse(m[4]!),
            int.parse(m[5]!),
          ).toLocal();
        }
        day = DateTime(t.year, t.month, t.day);
        minutes = t.hour * 60 + t.minute;
      }
      // One line: a day note line is how an import is recognised again, so
      // a summary with line breaks would be added on every import.
      final title = _unesc(
        c['SUMMARY'] ?? '',
      ).replaceAll(RegExp(r'\s+'), ' ').trim();
      events.add((
        day: day,
        minutes: minutes,
        title: title.isEmpty ? '(no title)' : title,
      ));
      if (events.length >= 5000) break;
    } else if (cur != null) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final name = line.substring(0, colon).split(';').first.toUpperCase();
      cur.putIfAbsent(name, () => line.substring(colon + 1));
    }
  }
  return events;
}

/// The text of a calendar file. RFC 5545 files are UTF-8, but some apps
/// write another encoding: such bytes become U+FFFD instead of failing the
/// whole import. A UTF-8 byte order mark is dropped.
String decodeCalendarFile(List<int> bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  return text.startsWith('﻿') ? text.substring(1) : text;
}

/// Adds the events to their days' notes; returns how many were new.
int importIcs(Workspace ws, String text) {
  var added = 0;
  for (final e in parseIcs(text)) {
    final line = e.minutes == null
        ? '• ${e.title}'
        : '• ${_two(e.minutes! ~/ 60)}:${_two(e.minutes! % 60)} ${e.title}';
    final record = ws.dayRecord(e.day);
    if (record.text.split('\n').contains(line)) continue;
    ws.saveDay(
      record.copyWith(
        text: record.text.trim().isEmpty ? line : '${record.text}\n$line',
      ),
    );
    added++;
  }
  return added;
}
