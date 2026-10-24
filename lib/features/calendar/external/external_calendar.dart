// Google Calendar and Microsoft Outlook (Graph) sync. One provider-neutral
// engine ([ExternalCalendarSync]) with two providers that keep their own
// sign-in, API calls, ids and error handling.
//
// What syncs, and why it cannot loop or duplicate:
//   - Provider → THEapp: events of the chosen calendar become read-only
//     [ExternalEvent]s on their days (recurring events arrive as their
//     single occurrences; cancelled/removed ones are deleted). Incremental:
//     Google sync tokens, Graph delta links; a reset does a full pull.
//   - THEapp → provider (optional): Reminder/Event entries' dates become
//     events. Each exported occurrence has a [CalendarLink] with the remote
//     id and a hash of what was sent: unchanged → not sent again; the
//     provider's copy of it is recognised by its id and never imported
//     back. Imported events are never exported. Local entries are never
//     changed by the sync, so local-only details cannot be lost.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../../data/models/calendar_models.dart';
import '../../../data/models/calendar_sync_models.dart';
import '../../../data/models/record.dart';
import '../../../data/repositories/canvas_repository.dart'
    show SettingsRepository;
import '../../../data/workspace.dart';
import '../../../sync/secret_store.dart';
import 'oauth.dart';

class RemoteCalendar {
  const RemoteCalendar(this.id, this.name, {this.primary = false});
  final String id;
  final String name;
  final bool primary;
}

class RemoteEvent {
  const RemoteEvent({
    required this.remoteId,
    this.title = '',
    this.start,
    this.end,
    this.allDay = false,
    this.location = '',
    this.link = '',
    this.removed = false,
  });
  final String remoteId;
  final String title;
  final DateTime? start;
  final DateTime? end;
  final bool allDay;
  final String location;
  final String link;

  /// Cancelled (Google) or removed (Graph @removed).
  final bool removed;
}

class DeltaPage {
  const DeltaPage(this.events, this.cursor, {this.full = false});
  final List<RemoteEvent> events;
  final String? cursor;

  /// A complete list (first sync or after a reset), not only changes.
  final bool full;
}

/// What THEapp sends for one entry occurrence.
class EventDraft {
  const EventDraft({
    required this.title,
    required this.day,
    this.description = '',
    this.startMinutes,
    this.durationMinutes,
  });
  final String title;
  final String description;
  final DateTime day;
  final int? startMinutes;
  final int? durationMinutes;

  bool get allDay => startMinutes == null;
  DateTime get start => DateTime(
    day.year,
    day.month,
    day.day,
    (startMinutes ?? 0) ~/ 60,
    (startMinutes ?? 0) % 60,
  );
  DateTime get end => allDay
      ? DateTime(day.year, day.month, day.day + 1)
      : start.add(Duration(minutes: durationMinutes ?? 60));

  String get hash => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            title,
            description,
            dayKey(day),
            startMinutes,
            durationMinutes,
          ]),
        ),
      )
      .toString();
}

class ProviderException implements Exception {
  const ProviderException(this.message, {this.status = 0, this.retryAfter});
  final String message;
  final int status;
  final Duration? retryAfter;
  @override
  String toString() => message;
}

/// The access token, refreshed when needed (supplied by the engine).
typedef TokenSource = Future<String> Function({bool force});

abstract class CalendarProvider {
  CalendarProvider(this.token);
  final TokenSource token;

  String get name;
  String get label;

  Future<List<RemoteCalendar>> calendars();
  Future<DeltaPage> changes(String calendarId, String? cursor);
  Future<String> create(String calendarId, EventDraft d);
  Future<void> update(String calendarId, String remoteId, EventDraft d);
  Future<void> delete(String calendarId, String remoteId);

  /// One authorised JSON request; refreshes the token once on 401.
  Future<Map<String, dynamic>?> request(
    String method,
    Uri url, {
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.openUrl(method, url);
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${await token(force: attempt > 0)}',
        );
        headers.forEach(req.headers.set);
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        final res = await req.close().timeout(const Duration(seconds: 30));
        final text = await utf8
            .decodeStream(res)
            .timeout(const Duration(seconds: 60));
        if (res.statusCode == 401 && attempt == 0) continue;
        if (res.statusCode >= 400) {
          final retry = int.tryParse(
            res.headers.value(HttpHeaders.retryAfterHeader) ?? '',
          );
          throw ProviderException(
            switch (res.statusCode) {
              401 || 403 => '$label refused access. Connect the account again.',
              404 || 410 => 'Not found',
              429 || 503 => '$label is busy (rate limit). Try again later.',
              _ => '$label answered with an error (${res.statusCode}).',
            },
            status: res.statusCode,
            retryAfter: retry == null ? null : Duration(seconds: retry),
          );
        }
        if (text.trim().isEmpty) return null;
        final json = jsonDecode(text);
        return json is Map<String, dynamic> ? json : null;
      } on SocketException {
        throw ProviderException('No connection to $label.');
      } on TimeoutException {
        throw ProviderException('$label took too long.');
      } on FormatException {
        throw ProviderException('$label sent an unreadable answer.');
      } finally {
        client.close(force: true);
      }
    }
    throw ProviderException('$label refused access.', status: 401);
  }
}

String _two(int v) => v.toString().padLeft(2, '0');
String _date(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// Local time with its UTC offset, e.g. 2026-10-24T10:00:00+03:00.
String _localWithOffset(DateTime t) {
  final o = t.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final m = o.inMinutes.abs();
  return '${_date(t)}T${_two(t.hour)}:${_two(t.minute)}:00$sign${_two(m ~/ 60)}:${_two(m % 60)}';
}

class GoogleCalendarProvider extends CalendarProvider {
  GoogleCalendarProvider(super.token);

  static const scopes = [
    'https://www.googleapis.com/auth/calendar.calendarlist.readonly',
    'https://www.googleapis.com/auth/calendar.events',
  ];

  static OAuthConfig config({
    required String clientId,
    String? clientSecret,
    String? iosRedirect,
  }) => OAuthConfig(
    authorizeUrl: Uri.parse('https://accounts.google.com/o/oauth2/v2/auth'),
    tokenUrl: Uri.parse('https://oauth2.googleapis.com/token'),
    clientId: clientId,
    clientSecret: clientSecret,
    scopes: scopes,
    extraAuthParams: const {'access_type': 'offline', 'prompt': 'consent'},
    mobileRedirect: iosRedirect,
  );

  static final _base = Uri.parse('https://www.googleapis.com/calendar/v3/');

  @override
  String get name => 'google';
  @override
  String get label => 'Google Calendar';

  @override
  Future<List<RemoteCalendar>> calendars() async {
    final json = await request(
      'GET',
      _base.resolve('users/me/calendarList?minAccessRole=writer'),
    );
    return [
      for (final c in (json?['items'] as List?) ?? const [])
        if (c is Map && c['id'] is String)
          RemoteCalendar(
            c['id'] as String,
            '${c['summaryOverride'] ?? c['summary'] ?? c['id']}',
            primary: c['primary'] == true,
          ),
    ];
  }

  static DateTime? _when(Object? w) {
    if (w is! Map) return null;
    if (w['date'] is String) return DateTime.tryParse(w['date'] as String);
    if (w['dateTime'] is String) {
      return DateTime.tryParse(w['dateTime'] as String)?.toUtc();
    }
    return null;
  }

  @override
  Future<DeltaPage> changes(String calendarId, String? cursor) async {
    final events = <RemoteEvent>[];
    String? page, next;
    final path = 'calendars/${Uri.encodeComponent(calendarId)}/events';
    do {
      final q = <String, String>{
        'singleEvents': 'true',
        'showDeleted': 'true',
        'maxResults': '250',
        if (cursor != null)
          'syncToken': cursor
        else
          'timeMin': DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 60))
              .toIso8601String(),
        'pageToken': ?page,
      };
      final Map<String, dynamic>? json;
      try {
        json = await request(
          'GET',
          _base.resolve(path).replace(queryParameters: q),
        );
      } on ProviderException catch (e) {
        // 410: the sync token expired; start over with a full list.
        if (e.status == 410 && cursor != null) return changes(calendarId, null);
        rethrow;
      }
      for (final e in (json?['items'] as List?) ?? const []) {
        if (e is! Map || e['id'] is! String) continue;
        final start = _when(e['start']);
        events.add(
          RemoteEvent(
            remoteId: e['id'] as String,
            title: '${e['summary'] ?? ''}',
            start: start,
            end: _when(e['end']) ?? start,
            allDay: (e['start'] as Map?)?['date'] != null,
            location: '${e['location'] ?? ''}',
            link: '${e['htmlLink'] ?? ''}',
            removed: e['status'] == 'cancelled',
          ),
        );
      }
      page = json?['nextPageToken'] as String?;
      next = json?['nextSyncToken'] as String? ?? next;
    } while (page != null && events.length < 20000);
    return DeltaPage(events, next ?? cursor, full: cursor == null);
  }

  Map<String, dynamic> _body(EventDraft d) => {
    'summary': d.title,
    if (d.description.isNotEmpty) 'description': d.description,
    'start': d.allDay
        ? {'date': _date(d.start)}
        : {'dateTime': _localWithOffset(d.start)},
    'end': d.allDay
        ? {'date': _date(d.end)}
        : {'dateTime': _localWithOffset(d.end)},
    'extendedProperties': {
      'private': {'theapp': '1'},
    },
  };

  @override
  Future<String> create(String calendarId, EventDraft d) async {
    final json = await request(
      'POST',
      _base.resolve('calendars/${Uri.encodeComponent(calendarId)}/events'),
      body: _body(d),
    );
    final id = json?['id'];
    if (id is! String) throw ProviderException('$label sent no event id.');
    return id;
  }

  @override
  Future<void> update(
    String calendarId,
    String remoteId,
    EventDraft d,
  ) => request(
    'PATCH',
    _base.resolve(
      'calendars/${Uri.encodeComponent(calendarId)}/events/${Uri.encodeComponent(remoteId)}',
    ),
    body: _body(d),
  );

  @override
  Future<void> delete(String calendarId, String remoteId) async {
    try {
      await request(
        'DELETE',
        _base.resolve(
          'calendars/${Uri.encodeComponent(calendarId)}/events/${Uri.encodeComponent(remoteId)}',
        ),
      );
    } on ProviderException catch (e) {
      if (e.status != 404 && e.status != 410) rethrow; // already gone
    }
  }
}

class MicrosoftCalendarProvider extends CalendarProvider {
  MicrosoftCalendarProvider(super.token);

  static const scopes = ['offline_access', 'Calendars.ReadWrite'];

  static OAuthConfig config({required String clientId, String? iosRedirect}) =>
      OAuthConfig(
        authorizeUrl: Uri.parse(
          'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
        ),
        tokenUrl: Uri.parse(
          'https://login.microsoftonline.com/common/oauth2/v2.0/token',
        ),
        clientId: clientId,
        scopes: scopes,
        mobileRedirect: iosRedirect,
        loopbackHost: 'localhost',
      );

  static final _base = Uri.parse('https://graph.microsoft.com/v1.0/');
  static const _prefer = {
    'Prefer': 'outlook.timezone="UTC", odata.maxpagesize=200',
  };

  @override
  String get name => 'microsoft';
  @override
  String get label => 'Outlook Calendar';

  @override
  Future<List<RemoteCalendar>> calendars() async {
    final json = await request(
      'GET',
      _base.resolve('me/calendars?\$select=id,name,isDefaultCalendar,canEdit'),
    );
    return [
      for (final c in (json?['value'] as List?) ?? const [])
        if (c is Map && c['id'] is String && c['canEdit'] != false)
          RemoteCalendar(
            c['id'] as String,
            '${c['name'] ?? c['id']}',
            primary: c['isDefaultCalendar'] == true,
          ),
    ];
  }

  /// Graph sends UTC wall time without an offset (we ask for UTC).
  static DateTime? _when(Object? w, {required bool allDay}) {
    if (w is! Map || w['dateTime'] is! String) return null;
    final raw = (w['dateTime'] as String).split('.').first;
    final t = DateTime.tryParse('${raw}Z');
    if (t == null) return null;
    return allDay ? DateTime(t.year, t.month, t.day) : t;
  }

  @override
  Future<DeltaPage> changes(String calendarId, String? cursor) async {
    final events = <RemoteEvent>[];
    var url = cursor != null
        ? Uri.parse(cursor)
        : _base
              .resolve(
                'me/calendars/${Uri.encodeComponent(calendarId)}/calendarView/delta',
              )
              .replace(
                queryParameters: {
                  'startDateTime': DateTime.now()
                      .toUtc()
                      .subtract(const Duration(days: 60))
                      .toIso8601String(),
                  'endDateTime': DateTime.now()
                      .toUtc()
                      .add(const Duration(days: 400))
                      .toIso8601String(),
                },
              );
    // Only follow Graph's own links.
    if (url.host != 'graph.microsoft.com') return changes(calendarId, null);
    String? delta;
    while (events.length < 20000) {
      final Map<String, dynamic>? json;
      try {
        json = await request('GET', url, headers: _prefer);
      } on ProviderException catch (e) {
        if ((e.status == 410 || e.status == 404) && cursor != null) {
          return changes(calendarId, null); // delta expired: full list
        }
        rethrow;
      }
      for (final e in (json?['value'] as List?) ?? const []) {
        if (e is! Map || e['id'] is! String) continue;
        final allDay = e['isAllDay'] == true;
        final start = _when(e['start'], allDay: allDay);
        events.add(
          RemoteEvent(
            remoteId: e['id'] as String,
            title: '${e['subject'] ?? ''}',
            start: start,
            end: _when(e['end'], allDay: allDay) ?? start,
            allDay: allDay,
            location: '${(e['location'] as Map?)?['displayName'] ?? ''}',
            link: '${e['webLink'] ?? ''}',
            removed: e.containsKey('@removed') || e['isCancelled'] == true,
          ),
        );
      }
      final nextLink = json?['@odata.nextLink'] as String?;
      delta = json?['@odata.deltaLink'] as String? ?? delta;
      if (nextLink == null) break;
      url = Uri.parse(nextLink);
      if (url.host != 'graph.microsoft.com') break;
    }
    return DeltaPage(events, delta ?? cursor, full: cursor == null);
  }

  static String _utc(DateTime t) {
    final u = t.toUtc();
    return '${_date(u)}T${_two(u.hour)}:${_two(u.minute)}:00';
  }

  Map<String, dynamic> _body(EventDraft d) => {
    'subject': d.title,
    if (d.description.isNotEmpty)
      'body': {'contentType': 'text', 'content': d.description},
    'isAllDay': d.allDay,
    // All-day events: midnight to midnight of the date itself.
    'start': {
      'dateTime': d.allDay ? '${_date(d.start)}T00:00:00' : _utc(d.start),
      'timeZone': 'UTC',
    },
    'end': {
      'dateTime': d.allDay ? '${_date(d.end)}T00:00:00' : _utc(d.end),
      'timeZone': 'UTC',
    },
  };

  @override
  Future<String> create(String calendarId, EventDraft d) async {
    final json = await request(
      'POST',
      _base.resolve('me/calendars/${Uri.encodeComponent(calendarId)}/events'),
      body: _body(d),
    );
    final id = json?['id'];
    if (id is! String) throw ProviderException('$label sent no event id.');
    return id;
  }

  @override
  Future<void> update(String calendarId, String remoteId, EventDraft d) =>
      request(
        'PATCH',
        _base.resolve('me/events/${Uri.encodeComponent(remoteId)}'),
        body: _body(d),
      );

  @override
  Future<void> delete(String calendarId, String remoteId) async {
    try {
      await request(
        'DELETE',
        _base.resolve('me/events/${Uri.encodeComponent(remoteId)}'),
      );
    } on ProviderException catch (e) {
      if (e.status != 404 && e.status != 410) rethrow;
    }
  }
}

/// One connected account: its tokens (secret store), settings and sync.
class ExternalCalendarSync {
  ExternalCalendarSync({
    required this.ws,
    required this.settings,
    required this.provider,
    required this.oauth,
    this.apiOverride,
  }) : tokenFile = File(
         '${ws.root.path}${Platform.pathSeparator}calendar'
         '${Platform.pathSeparator}$provider.token',
       );

  final Workspace ws;
  final SettingsRepository settings;
  final String provider; // 'google' / 'microsoft'
  final OAuthConfig Function() oauth;
  final File tokenFile;

  /// Most exported changes sent per run (rate limits).
  static const maxWritesPerRun = 200;

  bool _running = false;
  bool get running => _running;

  String _key(String k) => 'calendar.$provider.$k';
  String? get calendarId => settings.get<String>(_key('calendar'));
  String get calendarName => settings.get<String>(_key('calendarName')) ?? '';
  bool get exportEntries => settings.get<bool>(_key('export')) ?? false;
  String get status => settings.get<String>(_key('status')) ?? '';
  DateTime? get lastSuccess =>
      DateTime.tryParse(settings.get<String>(_key('lastSuccess')) ?? '');

  Future<bool> get connected async => await readSecret(tokenFile) != null;

  Future<void> _setStatus(String s) => settings.set(_key('status'), s);

  /// Replaces the real provider in tests.
  final CalendarProvider? apiOverride;

  late final CalendarProvider api =
      apiOverride ??
      (provider == 'google'
          ? GoogleCalendarProvider(_token)
          : MicrosoftCalendarProvider(_token));

  Future<String> _token({bool force = false}) async {
    final t = OAuthTokens.fromJson(await readSecret(tokenFile));
    if (t == null) {
      throw const OAuthException('Not connected.', signInAgain: true);
    }
    if (!force && !t.expired) return t.accessToken;
    if (t.refreshToken == null) {
      throw const OAuthException(
        'The sign-in expired. Connect the account again.',
        signInAgain: true,
      );
    }
    final fresh = await refresh(oauth(), t.refreshToken!);
    await writeSecret(tokenFile, fresh.toJson());
    return fresh.accessToken;
  }

  Future<void> connect({
    required bool Function(String) openBrowser,
    bool mobile = false,
  }) async {
    final t = await signIn(oauth(), openBrowser: openBrowser, mobile: mobile);
    await tokenFile.parent.create(recursive: true);
    await writeSecret(tokenFile, t.toJson());
    await _setStatus('Connected. Choose a calendar.');
  }

  /// Forgets the tokens and this account's imported events (exported
  /// events stay in the provider's calendar; their links are kept so a
  /// later reconnect does not create them twice).
  Future<void> disconnect() async {
    await deleteSecret(tokenFile);
    for (final e
        in ws.externalEvents.all
            .where((e) => e.provider == provider)
            .toList()) {
      ws.externalEvents.remove(e.id);
    }
    await settings.set(_key('cursor'), null);
    await _setStatus('Disconnected.');
  }

  Future<void> chooseCalendar(RemoteCalendar c) async {
    if (c.id == calendarId) return;
    await settings.set(_key('calendar'), c.id);
    await settings.set(_key('calendarName'), c.name);
    await settings.set(_key('cursor'), null);
    for (final e
        in ws.externalEvents.all
            .where((e) => e.provider == provider)
            .toList()) {
      ws.externalEvents.remove(e.id);
    }
  }

  Future<void> setExport(bool on) => settings.set(_key('export'), on);

  /// The local occurrences that should exist in the provider calendar.
  Map<String, EventDraft> _wanted() {
    final today = DateTime.now();
    final from = DateTime(today.year, today.month, today.day - 30);
    final to = DateTime(today.year, today.month, today.day + 365);
    final out = <String, EventDraft>{};
    for (final e in ws.entries.all) {
      if (e.archived || e.category != CalendarCategory.events) continue;
      for (final key in e.dates) {
        final day = parseDayKey(key);
        if (day.isBefore(from) || day.isAfter(to)) continue;
        out[CalendarLink.idFor(provider, e.id, key)] = EventDraft(
          title: e.name,
          description: e.description,
          day: day,
          startMinutes: e.startMinutes,
          durationMinutes: e.durationMinutes,
        );
      }
    }
    return out;
  }

  /// One sync run. Returns a short report (also kept as [status]).
  Future<String> syncOnce() async {
    if (_running) return status;
    final cal = calendarId;
    if (cal == null) return 'Choose a calendar first.';
    _running = true;
    try {
      // 1. Pull.
      final page = await api.changes(cal, settings.get<String>(_key('cursor')));
      final ours = {
        for (final l in ws.calendarLinks.all)
          if (l.provider == provider) l.remoteId,
      };
      final seen = <String>{};
      var added = 0, removed = 0;
      for (final r in page.events) {
        if (ours.contains(r.remoteId)) continue; // our own export echoed back
        final id = ExternalEvent.idFor(provider, cal, r.remoteId);
        seen.add(id);
        if (r.removed || r.start == null) {
          if (ws.externalEvents[id] != null) {
            ws.externalEvents.remove(id);
            removed++;
          }
          continue;
        }
        final next = ExternalEvent(
          id: id,
          provider: provider,
          calendarId: cal,
          remoteId: r.remoteId,
          title: r.title,
          start: r.start!,
          end: r.end ?? r.start!,
          allDay: r.allDay,
          location: r.location,
          link: r.link,
          updatedAt: DateTime.now(),
        );
        final old = ws.externalEvents[id];
        if (old == null ||
            jsonEncode({...old.toJson(), 'updatedAt': 0}) !=
                jsonEncode({...next.toJson(), 'updatedAt': 0})) {
          ws.externalEvents.put(next);
          if (old == null) added++;
        }
      }
      if (page.full) {
        // A full list: what is not in it any more is gone.
        for (final e
            in ws.externalEvents.all
                .where(
                  (e) =>
                      e.provider == provider &&
                      e.calendarId == cal &&
                      !seen.contains(e.id),
                )
                .toList()) {
          ws.externalEvents.remove(e.id);
          removed++;
        }
      }
      await settings.set(_key('cursor'), page.cursor);

      // 2. Push (only when the user turned it on).
      var sent = 0, deleted = 0;
      if (exportEntries) {
        final wanted = _wanted();
        var writes = 0;
        for (final MapEntry(key: id, value: d) in wanted.entries) {
          if (writes >= maxWritesPerRun) break;
          final link = ws.calendarLinks[id];
          if (link != null && link.calendarId == cal && link.hash == d.hash) {
            continue;
          }
          String remoteId;
          if (link != null && link.calendarId == cal) {
            try {
              await api.update(cal, link.remoteId, d);
              remoteId = link.remoteId;
            } on ProviderException catch (e) {
              if (e.status != 404 && e.status != 410) rethrow;
              remoteId = await api.create(cal, d); // deleted over there
            }
          } else {
            remoteId = await api.create(cal, d);
          }
          // Saved right after each write, so a failure later in the run
          // never leads to a second copy next time.
          ws.calendarLinks.put(
            CalendarLink(
              id: id,
              provider: provider,
              calendarId: cal,
              remoteId: remoteId,
              hash: d.hash,
              updatedAt: DateTime.now(),
            ),
          );
          writes++;
          sent++;
        }
        for (final link
            in ws.calendarLinks.all
                .where(
                  (l) => l.provider == provider && !wanted.containsKey(l.id),
                )
                .toList()) {
          if (writes >= maxWritesPerRun) break;
          await api.delete(link.calendarId, link.remoteId);
          ws.calendarLinks.remove(link.id);
          writes++;
          deleted++;
        }
      }
      final report =
          'Synced: $added new, $removed removed'
          '${exportEntries ? ', $sent sent, $deleted deleted there' : ''}.';
      await settings.set(_key('lastSuccess'), DateTime.now().toIso8601String());
      await _setStatus(report);
      return report;
    } on OAuthException catch (e) {
      await _setStatus(e.message);
      return e.message;
    } on ProviderException catch (e) {
      final m = e.retryAfter == null
          ? e.message
          : '${e.message} (in ${e.retryAfter!.inSeconds} s)';
      await _setStatus(m);
      return m;
    } finally {
      _running = false;
    }
  }
}
