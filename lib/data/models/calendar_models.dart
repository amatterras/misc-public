import 'record.dart';

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
  const CalendarEntry({
    required this.id,
    required this.category,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    this.colorIndex = 5,
    this.archived = false,
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
    this.readingLog = const {},
    this.highlights = '',
    this.weekdays = const {},
    this.checkoffs = const {},
  });

  static const int maxActivePerCategory = 5;

  @override
  final String id;
  final CalendarCategory category;
  final String name;
  final String description;

  /// Index into the ten organiser colours.
  final int colorIndex;
  final bool archived;
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
  final Map<String, int> readingLog;
  final String highlights;

  // Habits: 1 = Monday … 7 = Sunday.
  final Set<int> weekdays;
  final Set<String> checkoffs;

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
    Map<String, int>? readingLog,
    String? highlights,
    Set<int>? weekdays,
    Set<String>? checkoffs,
  }) => CalendarEntry(
    id: id,
    category: category ?? this.category,
    name: name ?? this.name,
    description: description ?? this.description,
    colorIndex: colorIndex ?? this.colorIndex,
    archived: archived ?? this.archived,
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
    readingLog: readingLog ?? this.readingLog,
    highlights: highlights ?? this.highlights,
    weekdays: weekdays ?? this.weekdays,
    checkoffs: checkoffs ?? this.checkoffs,
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'category': category.name,
    'name': name,
    'description': description,
    'colorIndex': colorIndex,
    'archived': archived,
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
    'readingLog': readingLog,
    'highlights': highlights,
    'weekdays': weekdays.toList()..sort(),
    'checkoffs': checkoffs.toList()..sort(),
  };

  factory CalendarEntry.fromJson(Map<String, dynamic> j) {
    DateTime? day(Object? v) => v is String ? parseDayKey(v) : null;
    return CalendarEntry(
      id: j['id'] as String,
      category: CalendarCategory.values.byName(j['category'] as String),
      name: j['name'] as String,
      description: j['description'] as String? ?? '',
      colorIndex: j['colorIndex'] as int? ?? 5,
      archived: j['archived'] as bool? ?? false,
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
      readingLog: {
        ...?(j['readingLog'] as Map?)?.map(
          (k, v) => MapEntry(k as String, (v as num).toInt()),
        ),
      },
      highlights: j['highlights'] as String? ?? '',
      weekdays: {...?(j['weekdays'] as List?)?.cast<int>()},
      checkoffs: {...?(j['checkoffs'] as List?)?.cast<String>()},
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
