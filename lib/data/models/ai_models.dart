// Saved AI conversations. Stored locally like other records (and in
// backups) but never synced: they can contain private material the user
// chose to send. API keys are never part of a conversation.
import 'record.dart';

/// How a message ended.
enum AiMessageStatus {
  complete,

  /// Still being written (only while the app runs).
  streaming,

  /// The user pressed Stop.
  stopped,

  /// The app closed or crashed while it was being written.
  interrupted,

  /// The service reported an error ([AiChatMessage.error]).
  failed,
}

class AiChatMessage {
  const AiChatMessage({
    required this.role,
    required this.text,
    required this.at,
    this.status = AiMessageStatus.complete,
    this.tool,
    this.sources = const [],
    this.error,
  });

  /// "user" or "assistant".
  final String role;
  final String text;
  final DateTime at;
  final AiMessageStatus status;

  /// The tool used (name of an `AiTool`), user messages only.
  final String? tool;

  /// Titles of the material sent with the question, numbered from 1.
  final List<String> sources;
  final String? error;

  AiChatMessage copyWith({
    String? text,
    AiMessageStatus? status,
    String? Function()? error,
  }) => AiChatMessage(
    role: role,
    text: text ?? this.text,
    at: at,
    status: status ?? this.status,
    tool: tool,
    sources: sources,
    error: error != null ? error() : this.error,
  );

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    'at': utcIso(at),
    'status': status.name,
    'tool': ?tool,
    if (sources.isNotEmpty) 'sources': sources,
    'error': ?error,
  };

  static AiChatMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final role = raw['role'], text = raw['text'];
    if (role is! String || text is! String) return null;
    return AiChatMessage(
      role: role == 'assistant' ? 'assistant' : 'user',
      text: text,
      at: parseDate(raw['at']) ?? DateTime.now(),
      status:
          AiMessageStatus.values.asNameMap()[raw['status']] ??
          AiMessageStatus.complete,
      tool: raw['tool'] is String ? raw['tool'] as String : null,
      sources: [
        for (final s in raw['sources'] is List ? raw['sources'] as List : [])
          if (s is String) s,
      ],
      error: raw['error'] is String ? raw['error'] as String : null,
    );
  }
}

class AiConversation implements Record {
  const AiConversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.messages = const [],
    this.group = '',
    this.pinned = false,
  });

  @override
  final String id;
  final String title;

  /// A user-chosen group name for organizing ('' = none).
  final String group;
  final bool pinned;
  final List<AiChatMessage> messages;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;

  AiConversation copyWith({
    String? title,
    String? group,
    bool? pinned,
    List<AiChatMessage>? messages,
  }) => AiConversation(
    id: id,
    title: title ?? this.title,
    group: group ?? this.group,
    pinned: pinned ?? this.pinned,
    messages: messages ?? this.messages,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );

  /// Messages left "being written" by a closed app become interrupted.
  AiConversation? recovered() {
    if (!messages.any((m) => m.status == AiMessageStatus.streaming)) {
      return null;
    }
    return copyWith(
      messages: [
        for (final m in messages)
          m.status == AiMessageStatus.streaming
              ? m.copyWith(status: AiMessageStatus.interrupted)
              : m,
      ],
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (group.isNotEmpty) 'group': group,
    if (pinned) 'pinned': true,
    'messages': [for (final m in messages) m.toJson()],
    'createdAt': utcIso(createdAt),
    'updatedAt': utcIso(updatedAt),
  };

  factory AiConversation.fromJson(Map<String, dynamic> j) => AiConversation(
    id: j['id'] as String,
    title: j['title'] as String? ?? 'Conversation',
    group: j['group'] as String? ?? '',
    pinned: j['pinned'] == true,
    messages: [
      for (final m in j['messages'] is List ? j['messages'] as List : [])
        ?AiChatMessage.fromJson(m),
    ],
    createdAt: parseDate(j['createdAt']) ?? DateTime.now(),
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}
