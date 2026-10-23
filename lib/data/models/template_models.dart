// A user-made template (see features/templates/templates.dart).
import 'record.dart';

/// One task of a project template.
typedef TemplateTask = ({String title, int? parent, int? dueOffset});

class ContentTemplate implements Record {
  const ContentTemplate({
    required this.id,
    required this.name,
    required this.kind,
    required this.updatedAt,
    this.title = '',
    this.body = '',
    this.tasks = const [],
  });

  @override
  final String id;
  final String name;

  /// 'note' or 'project'.
  final String kind;
  final String title;
  final String body;
  final List<TemplateTask> tasks;
  @override
  final DateTime updatedAt;

  static const maxTasks = 500;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'title': title,
    'body': body,
    'tasks': [
      for (final t in tasks)
        {'title': t.title, 'parent': t.parent, 'dueOffset': t.dueOffset},
    ],
    'updatedAt': utcIso(updatedAt),
  };

  factory ContentTemplate.fromJson(Map<String, dynamic> j) => ContentTemplate(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    kind: j['kind'] as String? ?? 'note',
    title: j['title'] as String? ?? '',
    body: j['body'] as String? ?? '',
    tasks: [
      for (final t in (j['tasks'] as List?) ?? const [])
        if (t is Map && t['title'] is String)
          (
            title: t['title'] as String,
            parent: t['parent'] is int ? t['parent'] as int : null,
            dueOffset: t['dueOffset'] is int ? t['dueOffset'] as int : null,
          ),
    ],
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}
