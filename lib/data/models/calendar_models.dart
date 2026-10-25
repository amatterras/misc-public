import 'record.dart';

DateTime? _dateOnlyOrNull(DateTime? date) =>
    date == null ? null : dateOnly(date);

enum CalendarCategory {
  reading('Reading'),
  habits('Habits'),
  events('Events'),
  other('Other');

  const CalendarCategory(this.label);
  final String label;
}

/// One record shared by its category view and the date grid.
///
/// Which dates it appears on depends on the category:
/// * events: every day from [startDate] to [endDate] (multi-day allowed);
/// * other: each date in [dates];
/// * reading: each day in [readingLog] (pages read that day);
/// * habits: recurring from [startDate] (until [endDate]) on [weekdays]
///   (empty = every day); [checkoffs] are the days marked done.
/// A habit is one record however many days it occurs on.
class CalendarEntry implements Record {
  CalendarEntry({
    required this.id,
    required this.category,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    int? colorIndex,
    this.archived = false,
    this.archivedAt,
    this.notes = '',
    this.assetIds = const [],
    this.startDate,
    this.endDate,
    this.dates = const {},
    this.startMinutes,
    this.durationMinutes,
    this.author = '',
    this.totalPages,
    this.currentPage = 0,
    this.targetPagesPerDay,
    this.goalStartDate,
    this.readingLog = const {},
    this.highlights = '',
    this.weekdays = const {},
    this.checkoffs = const {},
    this.legacyReading,
    this.readingPlanId,
    this.readingPlanDate,
    this.readingPlanDetached = false,
    this.readingPlanStartDate,
    this.readingPlanEndDate,
  }) : colorIndex = colorIndex ?? category.index;

  static const int maxActivePerCategory = 5;

  @override
  final String id;
  final CalendarCategory category;
  final String name;
  final String description;

  /// Compatibility index, normalized to the entry's category palette slot.
  /// Rendering derives the color from [category], never from an ink palette.
  final int colorIndex;
  final bool archived;

  /// UTC instant when this calendar entry entered the archive. Null for
  /// active entries and for legacy archived records before migration.
  final DateTime? archivedAt;
  final String notes;
  final List<String> assetIds;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;

  final DateTime? startDate;
  final DateTime? endDate;
  final Set<String> dates;

  /// Optional time of day (minutes after midnight) and duration.
  final int? startMinutes;
  final int? durationMinutes;

  // Reading
  final String author;
  final int? totalPages;
  final int currentPage;

  /// Optional daily target for a reading goal. Null means no goal is set.
  final int? targetPagesPerDay;

  /// First local calendar date in the goal schedule. Stored as a date-only
  /// value so timezone changes do not shift the selected day.
  final DateTime? goalStartDate;
  final Map<String, int> readingLog;
  final String highlights;

  // Habits: 1 = Monday … 7 = Sunday.
  final Set<int> weekdays;
  final Set<String> checkoffs;

  /// Versioned, read-only copy of Reading fields that later versions no
  /// longer edit (author, highlights, quotes), made by the
  /// `reading-legacy-payload-v1` migration. Never shown in the Reading
  /// editor; kept so the old values stay recoverable (export, backups,
  /// sync). Null when there was nothing to keep. Unrelated to the app-wide
  /// welcome quotes.
  final Map<String, dynamic>? legacyReading;

  /// Reading-plan occurrence identity. The parent keeps its own id; each
  /// date-specific page uses `<parent id>/<yyyy-MM-dd>` as its stable id.
  final String? readingPlanId;
  final DateTime? readingPlanDate;
  final bool readingPlanDetached;
  final DateTime? readingPlanStartDate;
  final DateTime? readingPlanEndDate;

  /// A habit with no time of day yet. Older habits were untimed and stay
  /// untimed: no time is invented for them; the user picks one.
  bool get needsTimeConfiguration =>
      category == CalendarCategory.habits && startMinutes == null;

  bool occursOn(DateTime day) {
    final key = dayKey(day);
    switch (category) {
      case CalendarCategory.events:
        final start = startDate;
        if (start == null) return false;
        final end = endDate ?? start;
        return daysBetween(start, day) >= 0 && daysBetween(day, end) >= 0;
      case CalendarCategory.other:
        return dates.contains(key);
      case CalendarCategory.reading:
        if (readingPlanId != null) {
          return !readingPlanDetached &&
              readingPlanDate != null &&
              dayKey(readingPlanDate!) == key;
        }
        return readingLog.containsKey(key);
      case CalendarCategory.habits:
        final start = startDate ?? createdAt;
        if (daysBetween(start, day) < 0) return false;
        if (endDate != null && daysBetween(day, endDate!) < 0) return false;
        return weekdays.isEmpty || weekdays.contains(day.weekday);
    }
  }

  bool isCheckedOn(DateTime day) => checkoffs.contains(dayKey(day));

  String? get timeLabel {
    final m = startMinutes;
    if (m == null) return null;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(m ~/ 60)}:${two(m % 60)}';
  }

  /// Moves the occurrence on [from] to [to] (used by drag and drop).
  CalendarEntry movedOccurrence(DateTime from, DateTime to) {
    final shift = daysBetween(from, to);
    switch (category) {
      case CalendarCategory.events:
        return copyWith(
          startDate: () => startDate == null ? to : addDays(startDate!, shift),
          endDate: () => endDate == null ? null : addDays(endDate!, shift),
        );
      case CalendarCategory.other:
        return copyWith(
          dates: {...dates}
            ..remove(dayKey(from))
            ..add(dayKey(to)),
        );
      case CalendarCategory.reading:
        final log = {...readingLog};
        final pages = log.remove(dayKey(from)) ?? 0;
        log[dayKey(to)] = (log[dayKey(to)] ?? 0) + pages;
        return copyWith(readingLog: log);
      case CalendarCategory.habits:
        return this; // Recurring: move by editing its schedule instead.
    }
  }

  CalendarEntry copyWith({
    CalendarCategory? category,
    String? name,
    String? description,
    int? colorIndex,
    bool? archived,
    DateTime? Function()? archivedAt,
    String? notes,
    List<String>? assetIds,
    DateTime? Function()? startDate,
    DateTime? Function()? endDate,
    Set<String>? dates,
    int? Function()? startMinutes,
    int? Function()? durationMinutes,
    String? author,
    int? Function()? totalPages,
    int? currentPage,
    int? Function()? targetPagesPerDay,
    DateTime? Function()? goalStartDate,
    Map<String, int>? readingLog,
    String? highlights,
    Set<int>? weekdays,
    Set<String>? checkoffs,
    Map<String, dynamic>? Function()? legacyReading,
    String? Function()? readingPlanId,
    DateTime? Function()? readingPlanDate,
    bool? readingPlanDetached,
    DateTime? Function()? readingPlanStartDate,
    DateTime? Function()? readingPlanEndDate,
  }) => CalendarEntry(
    id: id,
    category: category ?? this.category,
    name: name ?? this.name,
    description: description ?? this.description,
    colorIndex: colorIndex ?? this.colorIndex,
    archived: archived ?? this.archived,
    archivedAt: archivedAt != null ? archivedAt() : this.archivedAt,
    notes: notes ?? this.notes,
    assetIds: assetIds ?? this.assetIds,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
    startDate: startDate != null ? startDate() : this.startDate,
    endDate: endDate != null ? endDate() : this.endDate,
    dates: dates ?? this.dates,
    startMinutes: startMinutes != null ? startMinutes() : this.startMinutes,
    durationMinutes: durationMinutes != null
        ? durationMinutes()
        : this.durationMinutes,
    author: author ?? this.author,
    totalPages: totalPages != null ? totalPages() : this.totalPages,
    currentPage: currentPage ?? this.currentPage,
    targetPagesPerDay: targetPagesPerDay != null
        ? targetPagesPerDay()
        : this.targetPagesPerDay,
    goalStartDate: goalStartDate != null
        ? _dateOnlyOrNull(goalStartDate())
        : this.goalStartDate,
    readingLog: readingLog ?? this.readingLog,
    highlights: highlights ?? this.highlights,
    weekdays: weekdays ?? this.weekdays,
    checkoffs: checkoffs ?? this.checkoffs,
    legacyReading: legacyReading != null ? legacyReading() : this.legacyReading,
    readingPlanId: readingPlanId != null ? readingPlanId() : this.readingPlanId,
    readingPlanDate: readingPlanDate != null
        ? _dateOnlyOrNull(readingPlanDate())
        : this.readingPlanDate,
    readingPlanDetached: readingPlanDetached ?? this.readingPlanDetached,
    readingPlanStartDate: readingPlanStartDate != null
        ? _dateOnlyOrNull(readingPlanStartDate())
        : this.readingPlanStartDate,
    readingPlanEndDate: readingPlanEndDate != null
        ? _dateOnlyOrNull(readingPlanEndDate())
        : this.readingPlanEndDate,
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'category': category.name,
    'name': name,
    'description': description,
    'colorIndex': colorIndex,
    'archived': archived,
    'archivedAt': archivedAt == null ? null : utcIso(archivedAt!),
    'notes': notes,
    'assetIds': assetIds,
    'createdAt': utcIso(createdAt),
    'updatedAt': utcIso(updatedAt),
    'startDate': startDate == null ? null : dayKey(startDate!),
    'endDate': endDate == null ? null : dayKey(endDate!),
    'dates': dates.toList()..sort(),
    'startMinutes': startMinutes,
    'durationMinutes': durationMinutes,
    'author': author,
    'totalPages': totalPages,
    'currentPage': currentPage,
    'targetPagesPerDay': targetPagesPerDay,
    'goalStartDate': goalStartDate == null ? null : dayKey(goalStartDate!),
    'readingLog': readingLog,
    'highlights': highlights,
    'weekdays': weekdays.toList()..sort(),
    'checkoffs': checkoffs.toList()..sort(),
    // Written only when present, so files without it stay unchanged.
    if (legacyReading != null) 'legacyReading': legacyReading,
    if (readingPlanId != null) 'readingPlanId': readingPlanId,
    if (readingPlanDate != null) 'readingPlanDate': dayKey(readingPlanDate!),
    if (readingPlanDetached) 'readingPlanDetached': true,
    if (readingPlanStartDate != null)
      'readingPlanStartDate': dayKey(readingPlanStartDate!),
    if (readingPlanEndDate != null)
      'readingPlanEndDate': dayKey(readingPlanEndDate!),
  };

  factory CalendarEntry.fromJson(Map<String, dynamic> j) {
    DateTime? day(Object? v) => v is String ? parseDayKey(v) : null;
    final category = CalendarCategory.values.byName(j['category'] as String);
    return CalendarEntry(
      id: j['id'] as String,
      category: category,
      name: j['name'] as String,
      description: j['description'] as String? ?? '',
      colorIndex: j['colorIndex'] as int? ?? category.index,
      archived: j['archived'] as bool? ?? false,
      archivedAt: parseDate(j['archivedAt']),
      notes: j['notes'] as String? ?? '',
      assetIds: [...?(j['assetIds'] as List?)?.cast<String>()],
      createdAt: parseDate(j['createdAt']) ?? DateTime.now(),
      updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
      startDate: day(j['startDate']),
      endDate: day(j['endDate']),
      dates: {...?(j['dates'] as List?)?.cast<String>()},
      startMinutes: j['startMinutes'] as int?,
      durationMinutes: j['durationMinutes'] as int?,
      author: j['author'] as String? ?? '',
      totalPages: j['totalPages'] as int?,
      currentPage: j['currentPage'] as int? ?? 0,
      targetPagesPerDay: j['targetPagesPerDay'] as int?,
      goalStartDate: day(j['goalStartDate']),
      readingLog: {
        ...?(j['readingLog'] as Map?)?.map(
          (k, v) => MapEntry(k as String, (v as num).toInt()),
        ),
      },
      highlights: j['highlights'] as String? ?? '',
      weekdays: {...?(j['weekdays'] as List?)?.cast<int>()},
      checkoffs: {...?(j['checkoffs'] as List?)?.cast<String>()},
      legacyReading: (j['legacyReading'] as Map?)?.cast<String, dynamic>(),
      readingPlanId: j['readingPlanId'] as String?,
      readingPlanDate: day(j['readingPlanDate']),
      readingPlanDetached: j['readingPlanDetached'] as bool? ?? false,
      readingPlanStartDate: day(j['readingPlanStartDate']),
      readingPlanEndDate: day(j['readingPlanEndDate']),
    );
  }
}

/// Notes, links and images attached to a calendar date. Its id is the
/// date key, so each date has at most one record.
class DayRecord implements Record {
  const DayRecord({
    required this.id,
    required this.updatedAt,
    this.text = '',
    this.assetIds = const [],
  });

  @override
  final String id;
  final String text;
  final List<String> assetIds;
  @override
  final DateTime updatedAt;

  bool get isEmpty => text.trim().isEmpty && assetIds.isEmpty;

  DayRecord copyWith({String? text, List<String>? assetIds}) => DayRecord(
    id: id,
    text: text ?? this.text,
    assetIds: assetIds ?? this.assetIds,
    updatedAt: DateTime.now(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'assetIds': assetIds,
    'updatedAt': utcIso(updatedAt),
  };

  factory DayRecord.fromJson(Map<String, dynamic> j) => DayRecord(
    id: j['id'] as String,
    text: j['text'] as String? ?? '',
    assetIds: [...?(j['assetIds'] as List?)?.cast<String>()],
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}

/// Irreversible retention tombstone for a calendar entry that expired after
/// seven days in the archive. It is synced so older devices cannot restore
/// the record by re-offering a stale local copy.
class CalendarEntryExpiration implements Record {
  const CalendarEntryExpiration({
    required this.id,
    required this.expiredAt,
    required this.updatedAt,
  });

  @override
  final String id;
  final DateTime expiredAt;
  @override
  final DateTime updatedAt;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'expiredAt': utcIso(expiredAt),
    'updatedAt': utcIso(updatedAt),
  };

  factory CalendarEntryExpiration.fromJson(Map<String, dynamic> json) =>
      CalendarEntryExpiration(
        id: json['id'] as String,
        expiredAt: parseDate(json['expiredAt']) ?? DateTime.now().toUtc(),
        updatedAt: parseDate(json['updatedAt']) ?? DateTime.now().toUtc(),
      );
}
