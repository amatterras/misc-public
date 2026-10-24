// Records for Google / Outlook calendar sync (see
// features/calendar/external/). Both sync between the user's devices so
// every device knows the same events and links, and none adds duplicates.
import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'record.dart';

/// An event from a connected Google or Outlook calendar, shown on its days.
/// A read-only mirror: it is changed in that calendar, and THEapp follows.
/// The id is derived from provider, calendar and event id, so the same
/// event is the same record on every device.
class ExternalEvent implements Record {
  const ExternalEvent({
    required this.id,
    required this.provider,
    required this.calendarId,
    required this.remoteId,
    required this.title,
    required this.start,
    required this.end,
    required this.updatedAt,
    this.allDay = false,
    this.location = '',
    this.link = '',
    this.description = '',
  });

  static String idFor(String provider, String calendarId, String remoteId) =>
      'ext-${sha256.convert(utf8.encode('$provider|$calendarId|$remoteId')).toString().substring(0, 32)}';

  @override
  final String id;

  /// 'google' or 'microsoft'.
  final String provider;
  final String calendarId;
  final String remoteId;
  final String title;

  /// Local time for all-day events (midnight), UTC instants otherwise.
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String location;

  /// The event's page in Google / Outlook (to edit it there).
  final String link;
  final String description;
  @override
  final DateTime updatedAt;

  /// Whether it shows on [day] (local date).
  bool occursOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final s = start.toLocal(), e = end.toLocal();
    final first = DateTime(s.year, s.month, s.day);
    // An all-day event's end is exclusive (the next midnight).
    var last = DateTime(e.year, e.month, e.day);
    if (allDay || (e.hour == 0 && e.minute == 0 && e.isAfter(s))) {
      last = last.subtract(const Duration(days: 1));
    }
    if (last.isBefore(first)) last = first;
    return !d.isBefore(first) && !d.isAfter(last);
  }

  /// Minutes after midnight it starts, or null for all-day.
  int? get startMinutes {
    if (allDay) return null;
    final s = start.toLocal();
    return s.hour * 60 + s.minute;
  }

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': provider,
    'calendarId': calendarId,
    'remoteId': remoteId,
    'title': title,
    'start': utcIso(start),
    'end': utcIso(end),
    if (allDay) 'allDay': true,
    if (location.isNotEmpty) 'location': location,
    if (link.isNotEmpty) 'link': link,
    if (description.isNotEmpty) 'description': description,
    'updatedAt': utcIso(updatedAt),
  };

  factory ExternalEvent.fromJson(Map<String, dynamic> j) => ExternalEvent(
    id: j['id'] as String,
    provider: j['provider'] as String? ?? '',
    calendarId: j['calendarId'] as String? ?? '',
    remoteId: j['remoteId'] as String? ?? '',
    title: j['title'] as String? ?? '',
    start: parseDate(j['start']) ?? DateTime.now(),
    end: parseDate(j['end']) ?? DateTime.now(),
    allDay: j['allDay'] == true,
    location: j['location'] as String? ?? '',
    link: j['link'] as String? ?? '',
    description: j['description'] as String? ?? '',
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}

/// One THEapp calendar entry occurrence exported to a provider calendar:
/// id `provider|entryId|day`. Holds the remote event id and a hash of what
/// was sent, so an unchanged entry is not sent again and the provider's
/// echo of it is not imported back as a second event (no loops).
class CalendarLink implements Record {
  const CalendarLink({
    required this.id,
    required this.provider,
    required this.calendarId,
    required this.remoteId,
    required this.hash,
    required this.updatedAt,
    this.entryId,
    this.remoteHash,
    this.remoteUpdatedAt,
    this.pendingCreate = false,
  });

  static String idFor(String provider, String entryId, String day) =>
      '$provider|$entryId|$day'.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  @override
  final String id;
  final String provider;
  final String calendarId;
  final String remoteId;

  /// Local CalendarEntry id. Missing only on links written by older builds.
  final String? entryId;

  /// Last normalized provider state, used for three-way conflict detection.
  final String? remoteHash;
  final DateTime? remoteUpdatedAt;

  /// Durable retry marker written before the provider's create request.
  final bool pendingCreate;
  final String hash;
  @override
  final DateTime updatedAt;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': provider,
    'calendarId': calendarId,
    'remoteId': remoteId,
    if (entryId != null) 'entryId': entryId,
    if (remoteHash != null) 'remoteHash': remoteHash,
    if (remoteUpdatedAt != null) 'remoteUpdatedAt': utcIso(remoteUpdatedAt!),
    if (pendingCreate) 'pendingCreate': true,
    'hash': hash,
    'updatedAt': utcIso(updatedAt),
  };

  factory CalendarLink.fromJson(Map<String, dynamic> j) => CalendarLink(
    id: j['id'] as String,
    provider: j['provider'] as String? ?? '',
    calendarId: j['calendarId'] as String? ?? '',
    remoteId: j['remoteId'] as String? ?? '',
    entryId: j['entryId'] as String?,
    remoteHash: j['remoteHash'] as String?,
    remoteUpdatedAt: parseDate(j['remoteUpdatedAt']),
    pendingCreate: j['pendingCreate'] == true,
    hash: j['hash'] as String? ?? '',
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}
