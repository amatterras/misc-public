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
  });

  @override
  final String id;
  final String title;
  final String notes;
  final bool done;
  final DateTime? completedAt;

  /// Date-only deadline/schedule; shown on Calendar as this same record.
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
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );

  /// Completing a recurring task moves it to its next date instead of
  /// creating a copy, so it stays one record.
  Task completed() {
    final due = dueDate;
    if (recurrence == Recurrence.none || due == null) {
      return copyWith(done: true, completedAt: () => DateTime.now());
    }
    final next = switch (recurrence) {
      Recurrence.daily => addDays(due, 1),
      Recurrence.weekly => addDays(due, 7),
      Recurrence.monthly => DateTime(due.year, due.month + 1, due.day),
      Recurrence.none => due,
    };
    return copyWith(dueDate: () => next, completedAt: () => DateTime.now());
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
    'createdAt': utcIso(createdAt),
    'updatedAt': utcIso(updatedAt),
  };

  factory Task.fromJson(Map<String, dynamic> j) => Task(
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
    recurrence: Recurrence.values.byName(j['recurrence'] as String? ?? 'none'),
    assetIds: [...?(j['assetIds'] as List?)?.cast<String>()],
    remindBefore: j['remindBefore'] as int?,
    createdAt: parseDate(j['createdAt']) ?? DateTime.now(),
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}
