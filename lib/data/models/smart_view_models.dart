import 'record.dart';
import 'task_models.dart';
import 'unknown_fields.dart';

// Smart Views: saved filters over the existing task records (never copies
// of tasks). Each saved view is one small record in the "smart_views"
// collection, so it is saved, backed up and synced like everything else.

/// Which tasks a view keeps by completion.
enum ViewCompletion {
  open('Open'),
  done('Completed'),
  any('Any');

  const ViewCompletion(this.label);
  final String label;
}

/// Which tasks a view keeps by deadline.
enum ViewDue {
  any('Any date'),
  overdue('Overdue'),
  today('Due today'),
  next7('Due in the next 7 days'),
  hasDeadline('Has a deadline'),
  noDeadline('No deadline');

  const ViewDue(this.label);
  final String label;
}

/// The conditions of a view. Every condition must hold; an empty set means
/// "any" for that condition.
class ViewFilter {
  const ViewFilter({
    this.completion = ViewCompletion.open,
    this.due = ViewDue.any,
    this.priorities = const {},
    this.projectIds = const {},
    this.projectKinds = const {},
    this.labels = const {},
    this.unknown = const {},
  });

  final ViewCompletion completion;
  final ViewDue due;

  /// Task priorities (0 = none … 3 = high) to keep.
  final Set<int> priorities;
  final Set<String> projectIds;

  /// Category: tasks in projects or in study subjects.
  final Set<ProjectKind> projectKinds;

  /// Tasks with any of these labels.
  final Set<String> labels;

  /// Conditions written by a newer version (kept and written back).
  final Map<String, dynamic> unknown;

  static const _known = {
    'completion',
    'due',
    'priorities',
    'projectIds',
    'projectKinds',
    'labels',
  };

  /// Whether [t] meets every condition on [today]. [kindOf] gives the kind
  /// of a task's project (null without a project).
  bool matches(
    Task t, {
    required DateTime today,
    required ProjectKind? Function(String? projectId) kindOf,
  }) {
    switch (completion) {
      case ViewCompletion.open when t.done:
      case ViewCompletion.done when !t.done:
        return false;
      default:
    }
    final due = t.dueDate;
    final dueOk = switch (this.due) {
      ViewDue.any => true,
      ViewDue.overdue => due != null && daysBetween(due, today) > 0,
      ViewDue.today => due != null && daysBetween(due, today) == 0,
      ViewDue.next7 =>
        due != null &&
            daysBetween(today, due) >= 0 &&
            daysBetween(today, due) < 7,
      ViewDue.hasDeadline => due != null,
      ViewDue.noDeadline => due == null,
    };
    if (!dueOk) return false;
    if (priorities.isNotEmpty && !priorities.contains(t.priority)) {
      return false;
    }
    if (projectIds.isNotEmpty && !projectIds.contains(t.projectId)) {
      return false;
    }
    if (projectKinds.isNotEmpty) {
      final kind = kindOf(t.projectId);
      if (kind == null || !projectKinds.contains(kind)) return false;
    }
    if (labels.isNotEmpty && !t.labels.any(labels.contains)) return false;
    return true;
  }

  ViewFilter copyWith({
    ViewCompletion? completion,
    ViewDue? due,
    Set<int>? priorities,
    Set<String>? projectIds,
    Set<ProjectKind>? projectKinds,
    Set<String>? labels,
  }) => ViewFilter(
    completion: completion ?? this.completion,
    due: due ?? this.due,
    priorities: priorities ?? this.priorities,
    projectIds: projectIds ?? this.projectIds,
    projectKinds: projectKinds ?? this.projectKinds,
    labels: labels ?? this.labels,
    unknown: unknown,
  );

  Map<String, dynamic> toJson() => withUnknownFields({
    'completion': completion.name,
    'due': due.name,
    if (priorities.isNotEmpty) 'priorities': (priorities.toList()..sort()),
    if (projectIds.isNotEmpty) 'projectIds': (projectIds.toList()..sort()),
    if (projectKinds.isNotEmpty)
      'projectKinds': [for (final k in projectKinds) k.name]..sort(),
    if (labels.isNotEmpty) 'labels': (labels.toList()..sort()),
  }, unknown);

  factory ViewFilter.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    Iterable<Object?> list(String key) =>
        j[key] is List ? j[key] as List : const [];
    return ViewFilter(
      completion:
          ViewCompletion.values.asNameMap()[j['completion']] ??
          ViewCompletion.open,
      due: ViewDue.values.asNameMap()[j['due']] ?? ViewDue.any,
      priorities: {
        for (final v in list('priorities'))
          if (v is int && v >= 0 && v <= 3) v,
      },
      projectIds: {...list('projectIds').whereType<String>()},
      projectKinds: {
        for (final v in list('projectKinds'))
          ?ProjectKind.values.asNameMap()[v],
      },
      labels: {...list('labels').whereType<String>()},
      unknown: unknownFields(Map<String, dynamic>.from(j), _known),
    );
  }
}

/// A view the user saved: a name and its conditions.
class SmartView implements Record {
  const SmartView({
    required this.id,
    required this.name,
    required this.filter,
    required this.createdAt,
    required this.updatedAt,
  });

  @override
  final String id;
  final String name;
  final ViewFilter filter;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;

  static const maxNameLength = 60;

  SmartView copyWith({String? name, ViewFilter? filter}) => SmartView(
    id: id,
    name: name ?? this.name,
    filter: filter ?? this.filter,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'filter': filter.toJson(),
    'createdAt': utcIso(createdAt),
    'updatedAt': utcIso(updatedAt),
  };

  factory SmartView.fromJson(Map<String, dynamic> j) => SmartView(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'View',
    filter: ViewFilter.fromJson(j['filter']),
    createdAt: parseDate(j['createdAt']) ?? DateTime.now(),
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}
