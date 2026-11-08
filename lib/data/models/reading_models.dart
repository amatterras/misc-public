// Reading progress of an Archive item (a PDF or a saved link): where the
// reader is, how far, and optional personal weekly goals. Stored inside the
// item's own record (field `reading`), so there is one reading record per
// item however often it is opened, nothing is copied, and it is saved and
// synced with the item. Goals are only the reader's own targets; nothing
// here creates a deadline or a calendar entry.
import 'record.dart';

enum ReadState { unread, reading, done }

class ReadingProgress {
  const ReadingProgress({
    this.state = ReadState.reading,
    this.page = 1,
    this.totalPages,
    this.log = const {},
    this.sessions = const {},
    this.goalPages,
    this.goalSessions,
    this.updatedAt,
  });

  final ReadState state;

  /// The page the reader is on (from 1).
  final int page;

  /// How many pages it has, if the reader entered it.
  final int? totalPages;

  /// Pages read per day (day key `yyyy-mm-dd` -> pages) and reading
  /// sessions per day.
  final Map<String, int> log;
  final Map<String, int> sessions;

  /// Personal targets per week (optional).
  final int? goalPages;
  final int? goalSessions;

  final DateTime? updatedAt;

  /// 0..1 when the length is known, else null.
  double? get fraction => totalPages == null || totalPages! <= 0
      ? null
      : (state == ReadState.done ? 1.0 : (page / totalPages!).clamp(0.0, 1.0));

  ReadingProgress copyWith({
    ReadState? state,
    int? page,
    int? Function()? totalPages,
    Map<String, int>? log,
    Map<String, int>? sessions,
    int? Function()? goalPages,
    int? Function()? goalSessions,
    DateTime? updatedAt,
  }) => ReadingProgress(
    state: state ?? this.state,
    page: page ?? this.page,
    totalPages: totalPages != null ? totalPages() : this.totalPages,
    log: log ?? this.log,
    sessions: sessions ?? this.sessions,
    goalPages: goalPages != null ? goalPages() : this.goalPages,
    goalSessions: goalSessions != null ? goalSessions() : this.goalSessions,
    updatedAt: updatedAt ?? DateTime.now(),
  );

  /// Pages and sessions in the week (Monday to Sunday) of [day].
  ({int pages, int sessions}) week(DateTime day) {
    final monday = DateTime(day.year, day.month, day.day)
        .subtract(Duration(days: day.weekday - 1));
    var pages = 0, sess = 0;
    for (var i = 0; i < 7; i++) {
      final d = DateTime(monday.year, monday.month, monday.day + i);
      final key = dayKey(d);
      pages += log[key] ?? 0;
      sess += sessions[key] ?? 0;
    }
    return (pages: pages, sessions: sess);
  }

  Map<String, dynamic> toJson() => {
    'state': state.name,
    'page': page,
    'total': ?totalPages,
    if (log.isNotEmpty) 'log': log,
    if (sessions.isNotEmpty) 'sessions': sessions,
    'goalPages': ?goalPages,
    'goalSessions': ?goalSessions,
    if (updatedAt != null) 'at': utcIso(updatedAt!),
  };

  /// Null when [raw] is not a reading record; anything damaged inside it
  /// falls back to a safe value.
  static ReadingProgress? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int? positive(Object? v) => v is int && v > 0 ? v : null;
    Map<String, int> counts(Object? v) => {
      if (v is Map)
        for (final e in v.entries)
          if (e.key is String && e.value is int && (e.value as int) > 0)
            e.key as String: e.value as int,
    };
    return ReadingProgress(
      state: ReadState.values.asNameMap()[raw['state']] ?? ReadState.reading,
      page: positive(raw['page']) ?? 1,
      totalPages: positive(raw['total']),
      log: counts(raw['log']),
      sessions: counts(raw['sessions']),
      goalPages: positive(raw['goalPages']),
      goalSessions: positive(raw['goalSessions']),
      updatedAt: parseDate(raw['at']),
    );
  }
}
