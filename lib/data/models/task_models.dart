import 'record.dart';

enum ProjectKind { project, subject }

/// A project, or a study subject (for exam planning). Both group tasks.
class Project implements Record {
  const Project({
    required this.id,
    required this.name,
    required this.kind,
    required this.updatedAt,
    this.colorIndex = 5,
    this.archived = false,
  });

  @override
  final String id;
  final String name;
  final ProjectKind kind;
  final int colorIndex;
  final bool archived;
  @override
  final DateTime updatedAt;

  Project copyWith({String? name, int? colorIndex, bool? archived}) => Project(
    id: id,
    name: name ?? this.name,
    kind: kind,
    colorIndex: colorIndex ?? this.colorIndex,
    archived: archived ?? this.archived,
    updatedAt: DateTime.now(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'colorIndex': colorIndex,
    'archived': archived,
    'updatedAt': utcIso(updatedAt),
  };

  factory Project.fromJson(Map<String, dynamic> j) => Project(
    id: j['id'] as String,
    name: j['name'] as String,
    kind: ProjectKind.values.byName(j['kind'] as String? ?? 'project'),
    colorIndex: j['colorIndex'] as int? ?? 5,
    archived: j['archived'] as bool? ?? false,
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}

enum Recurrence { none, daily, weekly, monthly }

/// Board column of an unfinished task (finished = [Task.done]).
enum TaskStatus { todo, doing }

/// Optional rough effort of a task, next to (never instead of) its time
/// estimate.
enum TaskEffort {
  light('Light'),
  medium('Medium'),
  heavy('Heavy');

  const TaskEffort(this.label);
  final String label;
}

class Task implements Record {
  const Task({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.notes = '',
    this.done = false,
    this.completedAt,
    this.dueDate,
    this.dueMinutes,
    this.priority = 0,
    this.projectId,
    this.parentId,
    this.isExam = false,
    this.recurrence = Recurrence.none,
    this.assetIds = const [],
    this.remindBefore,
    this.labels = const [],
    this.properties = const {},
    this.dependsOn = const [],
    this.status = TaskStatus.todo,
    this.startDate,
    this.seriesDate,
    this.noteIds = const [],
    this.estimateMinutes,
    this.effort,
  });

  @override
  final String id;
  final String title;
  final String notes;
  final bool done;
  final DateTime? completedAt;

  /// Date-only deadline/schedule; shown on Calendar as this same record.
  /// For a recurring task: the date of its current occurrence.
  final DateTime? dueDate;
  final int? dueMinutes;

  /// 0 = none, 1 = low, 2 = medium, 3 = high.
  final int priority;
  final String? projectId;

  /// Set for subtasks (e.g. revision tasks under an exam).
  final String? parentId;
  final bool isExam;
  final Recurrence recurrence;
  final List<String> assetIds;

  /// Reminder, in minutes before the due time (0 = at the due time); null
  /// = no reminder. Relative, so a recurring task's reminder moves with it.
  final int? remindBefore;

  /// The user's own labels (free text; no fixed colors).
  final List<String> labels;

  /// The user's own properties (name → value), shown in the table view.
  final Map<String, String> properties;

  /// Tasks that should be finished first (a gentle warning, never a block).
  final List<String> dependsOn;

  /// Board column while unfinished.
  final TaskStatus status;

  /// Optional start (the Gantt bar runs from here to [dueDate]).
  final DateTime? startDate;

  /// Recurring task whose current occurrence was moved on its own: the
  /// date the series rule gave it. The next occurrence is counted from
  /// here, so moving one occurrence never shifts the series.
  final DateTime? seriesDate;

  /// Notes this task is about (each note lists its tasks).
  final List<String> noteIds;

  /// Optional estimated duration in minutes (see task_estimate.dart). Only
  /// shown; nothing is ever scheduled from it.
  final int? estimateMinutes;

  /// Optional effort level (shown only in the task's details).
  final TaskEffort? effort;

  /// Tasks with a date but no time are reminded at this time of day.
  static const defaultReminderMinutes = 9 * 60;

  /// When to remind (local time), or null without a reminder or due date.
  DateTime? get reminderTime {
    final due = dueDate, before = remindBefore;
    if (due == null || before == null) return null;
    final minutes = dueMinutes ?? defaultReminderMinutes;
    return DateTime(
      due.year,
      due.month,
      due.day,
    ).add(Duration(minutes: minutes - before));
  }

  final DateTime createdAt;
  @override
  final DateTime updatedAt;

  Task copyWith({
    String? title,
    String? notes,
    bool? done,
    DateTime? Function()? completedAt,
    DateTime? Function()? dueDate,
    int? Function()? dueMinutes,
    int? priority,
    String? Function()? projectId,
    String? Function()? parentId,
    bool? isExam,
    Recurrence? recurrence,
    List<String>? assetIds,
    int? Function()? remindBefore,
    List<String>? labels,
    Map<String, String>? properties,
    List<String>? dependsOn,
    TaskStatus? status,
    DateTime? Function()? startDate,
    DateTime? Function()? seriesDate,
    List<String>? noteIds,
    int? Function()? estimateMinutes,
    TaskEffort? Function()? effort,
  }) => Task(
    id: id,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    done: done ?? this.done,
    completedAt: completedAt != null ? completedAt() : this.completedAt,
    dueDate: dueDate != null ? dueDate() : this.dueDate,
    dueMinutes: dueMinutes != null ? dueMinutes() : this.dueMinutes,
    priority: priority ?? this.priority,
    projectId: projectId != null ? projectId() : this.projectId,
    parentId: parentId != null ? parentId() : this.parentId,
    isExam: isExam ?? this.isExam,
    recurrence: recurrence ?? this.recurrence,
    assetIds: assetIds ?? this.assetIds,
    remindBefore: remindBefore != null ? remindBefore() : this.remindBefore,
    labels: labels ?? this.labels,
    properties: properties ?? this.properties,
    dependsOn: dependsOn ?? this.dependsOn,
    status: status ?? this.status,
    startDate: startDate != null ? startDate() : this.startDate,
    seriesDate: seriesDate != null ? seriesDate() : this.seriesDate,
    noteIds: noteIds ?? this.noteIds,
    estimateMinutes: estimateMinutes != null
        ? estimateMinutes()
        : this.estimateMinutes,
    effort: effort != null ? effort() : this.effort,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );

  /// The occurrence after [from] by this task's rule.
  DateTime nextOccurrence(DateTime from) => switch (recurrence) {
    Recurrence.daily => addDays(from, 1),
    Recurrence.weekly => addDays(from, 7),
    Recurrence.monthly => DateTime(from.year, from.month + 1, from.day),
    Recurrence.none => from,
  };

  /// Completing a recurring task moves it to its next date instead of
  /// creating a copy, so it stays one record.
  Task completed() {
    if (recurrence == Recurrence.none || dueDate == null) {
      return copyWith(done: true, completedAt: () => DateTime.now());
    }
    return _advanced(completedAt: DateTime.now());
  }

  /// Recurring task: skips its current occurrence (it is not completed)
  /// and moves on to the next one. The series is unchanged.
  Task skippedOccurrence() {
    if (recurrence == Recurrence.none || dueDate == null) return this;
    return _advanced();
  }

  /// Moves only the current occurrence to [day]; for a recurring task the
  /// later occurrences keep following the series.
  Task movedOccurrence(DateTime day) {
    final due = dueDate;
    if (recurrence == Recurrence.none || due == null) {
      return copyWith(dueDate: () => dateOnly(day));
    }
    final series = seriesDate ?? due;
    return copyWith(
      dueDate: () => dateOnly(day),
      seriesDate: () => daysBetween(series, day) == 0 ? null : series,
    );
  }

  Task _advanced({DateTime? completedAt}) {
    final series = seriesDate ?? dueDate!;
    final next = nextOccurrence(series);
    final start = startDate;
    return copyWith(
      dueDate: () => next,
      seriesDate: () => null,
      startDate: start == null
          ? null
          : () => addDays(start, daysBetween(series, next)),
      completedAt: completedAt == null ? null : () => completedAt,
      status: TaskStatus.todo,
    );
  }

  /// The same task with its dates [days] later (or earlier), keeping the
  /// gaps between them.
  Task shifted(int days) {
    if (days == 0) return this;
    DateTime? move(DateTime? d) => d == null ? null : addDays(d, days);
    return copyWith(
      dueDate: () => move(dueDate),
      startDate: () => move(startDate),
      seriesDate: () => move(seriesDate),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'notes': notes,
    'done': done,
    'completedAt': completedAt == null ? null : utcIso(completedAt!),
    'dueDate': dueDate == null ? null : dayKey(dueDate!),
    'dueMinutes': dueMinutes,
    'priority': priority,
    'projectId': projectId,
    'parentId': parentId,
    'isExam': isExam,
    'recurrence': recurrence.name,
    'assetIds': assetIds,
    'remindBefore': remindBefore,
    // Newer fields are written only when used, so files of tasks that do
    // not use them stay exactly as before (older builds keep them as
    // unknown fields).
    if (labels.isNotEmpty) 'labels': labels,
    if (properties.isNotEmpty) 'properties': properties,
    if (dependsOn.isNotEmpty) 'dependsOn': dependsOn,
    if (status != TaskStatus.todo) 'status': status.name,
    if (startDate != null) 'startDate': dayKey(startDate!),
    if (seriesDate != null) 'seriesDate': dayKey(seriesDate!),
    if (noteIds.isNotEmpty) 'noteIds': noteIds,
    if (estimateMinutes != null) 'estimateMinutes': estimateMinutes,
    if (effort != null) 'effort': effort!.name,
    'createdAt': utcIso(createdAt),
    'updatedAt': utcIso(updatedAt),
  };

  static List<String> _strings(Object? raw) => [
    for (final v in raw is List ? raw : const []) ?(v is String ? v : null),
  ];

  static DateTime? _day(Object? raw) {
    if (raw is! String) return null;
    try {
      return parseDayKey(raw);
    } catch (_) {
      return null; // not a date: ignored
    }
  }

  factory Task.fromJson(Map<String, dynamic> j) {
    final props = j['properties'];
    return Task(
      id: j['id'] as String,
      title: j['title'] as String,
      notes: j['notes'] as String? ?? '',
      done: j['done'] as bool? ?? false,
      completedAt: parseDate(j['completedAt']),
      dueDate: j['dueDate'] is String
          ? parseDayKey(j['dueDate'] as String)
          : null,
      dueMinutes: j['dueMinutes'] as int?,
      priority: j['priority'] as int? ?? 0,
      projectId: j['projectId'] as String?,
      parentId: j['parentId'] as String?,
      isExam: j['isExam'] as bool? ?? false,
      recurrence: Recurrence.values.byName(
        j['recurrence'] as String? ?? 'none',
      ),
      assetIds: [...?(j['assetIds'] as List?)?.cast<String>()],
      remindBefore: j['remindBefore'] as int?,
      labels: _strings(j['labels']),
      properties: {
        if (props is Map)
          for (final e in props.entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
      },
      dependsOn: _strings(j['dependsOn']),
      status: TaskStatus.values.asNameMap()[j['status']] ?? TaskStatus.todo,
      startDate: _day(j['startDate']),
      seriesDate: _day(j['seriesDate']),
      noteIds: _strings(j['noteIds']),
      estimateMinutes: switch (j['estimateMinutes']) {
        final int m when m > 0 => m,
        _ => null, // missing or not a usable number: no estimate
      },
      effort: TaskEffort.values.asNameMap()[j['effort']],
      createdAt: parseDate(j['createdAt']) ?? DateTime.now(),
      updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
    );
  }
}
