// Optional AI help. Off unless the user turns it on, and even then nothing
// leaves THEapp until the user presses Send in the AI window, which shows
// exactly what will be sent. Two kinds of service:
//   - a model running on this PC with Ollama (free, nothing leaves the PC);
//   - an OpenAI-compatible service with the user's own key (may cost money;
//     a ChatGPT subscription does not include this).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../data/repositories/canvas_repository.dart' show SettingsRepository;

enum AiProvider { ollama, openAiCompatible }

extension AiProviderInfo on AiProvider {
  String get label => switch (this) {
    AiProvider.ollama => 'Local model on this PC (Ollama, free)',
    AiProvider.openAiCompatible => 'OpenAI-compatible service (your own key)',
  };

  String get defaultEndpoint => switch (this) {
    AiProvider.ollama => 'http://127.0.0.1:11434',
    AiProvider.openAiCompatible => 'https://api.openai.com',
  };
}

/// Kinds of content the AI may be given (each can be switched off).
enum AiSource { notes, canvases, tasks, archive, calendar }

extension AiSourceInfo on AiSource {
  String get label => switch (this) {
    AiSource.notes => 'Notes',
    AiSource.canvases => 'Mindmaps (also as images)',
    AiSource.tasks => 'Tasks and projects',
    AiSource.archive => 'Archive resources',
    AiSource.calendar => 'Calendar entries',
  };
}

/// The AI settings of this device (never synced).
class AiSettings {
  AiSettings(this._settings);

  final SettingsRepository _settings;

  T _get<T>(String key, T fallback) => _settings.get<T>('ai.$key') ?? fallback;
  Future<void> _set(String key, Object? value) =>
      _settings.set('ai.$key', value);

  /// Master switch: off by default.
  bool get enabled => _get('enabled', false);
  Future<void> setEnabled(bool on) => _set('enabled', on);

  AiProvider get provider =>
      AiProvider.values.asNameMap()[_get<String>('provider', '')] ??
      AiProvider.ollama;
  Future<void> setProvider(AiProvider p) => _set('provider', p.name);

  String get endpoint => _get('endpoint', provider.defaultEndpoint);
  Future<void> setEndpoint(String url) => _set('endpoint', url.trim());

  String get model =>
      _get('model', provider == AiProvider.ollama ? 'llama3.2' : 'gpt-4o-mini');
  Future<void> setModel(String name) => _set('model', name.trim());

  /// Most characters of text sent with one request.
  int get maxContextChars => _get('maxContext', 4000).clamp(500, 50000);
  Future<void> setMaxContextChars(int n) => _set('maxContext', n);

  /// User-authored guidance added to the system instructions for each turn.
  /// This guides the model; it cannot grant access to sources disabled below.
  String get workingRules => _get('workingRules', '');
  Future<void> setWorkingRules(String rules) {
    final value = String.fromCharCodes(rules.trim().runes.take(4000));
    return _set('workingRules', value);
  }

  /// Whether mindmap selections may be sent as pictures.
  bool get allowImages => _get('allowImages', true);
  Future<void> setAllowImages(bool on) => _set('allowImages', on);

  Set<AiSource> get sources {
    final saved = _settings.get<List<dynamic>>('ai.sources');
    if (saved == null) return {...AiSource.values};
    return {for (final v in saved) ?AiSource.values.asNameMap()[v]};
  }

  Future<void> setSources(Set<AiSource> sources) =>
      _set('sources', [for (final s in sources) s.name]);

  bool allows(AiSource source) => enabled && sources.contains(source);

  /// Extra rules for one tool (e.g. "Quiz me: 10 questions, harder"),
  /// added to that tool's requests only.
  String toolRules(AiTool tool) => _get('rules.${tool.name}', '');
  Future<void> setToolRules(AiTool tool, String rules) => _set(
    'rules.${tool.name}',
    String.fromCharCodes(rules.trim().runes.take(2000)),
  );

  /// Whether the AI address is this PC (nothing leaves the device).
  bool get isLocal {
    final host = Uri.tryParse(endpoint)?.host.toLowerCase() ?? '';
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '[::1]';
  }

  // AI activity log (governance): what kind of material went where and
  // when, never the material itself. Kept on this device, newest last.
  static const maxActivity = 200;

  List<Map<String, dynamic>> get activity => [
    for (final e in _get<List>('activity', const []))
      if (e is Map) e.cast<String, dynamic>(),
  ];

  Future<void> logSend({
    required String tool,
    required List<String> sourceKinds,
    required int chars,
    required int images,
  }) {
    final next = [
      ...activity,
      {
        'at': DateTime.now().toUtc().toIso8601String(),
        'provider': provider.name,
        'host': Uri.tryParse(endpoint)?.host ?? '',
        'local': isLocal,
        'model': model,
        'tool': tool,
        'sources': sourceKinds,
        'chars': chars,
        'images': images,
      },
    ];
    return _set(
      'activity',
      next.length > maxActivity
          ? next.sublist(next.length - maxActivity)
          : next,
    );
  }

  Future<void> clearActivity() => _set('activity', const []);
}

class AiMessage {
  const AiMessage(this.role, this.content, {this.images = const []});
  final String role; // system, user, assistant
  final String content;
  final List<Uint8List> images;
}

class AiFailure implements Exception {
  const AiFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sends a conversation and returns the reply, whole ([complete]) or piece
/// by piece as it is written ([stream]); [cancel] stops a request.
abstract class AiClient {
  Future<String> complete(List<AiMessage> messages);

  /// The reply in pieces. Services that cannot stream give it in one piece.
  Stream<String> stream(List<AiMessage> messages) async* {
    yield await complete(messages);
  }

  /// Stops the request in progress (its stream ends with [AiCancelled]).
  void cancel() {}
}

/// The user stopped the request.
class AiCancelled extends AiFailure {
  const AiCancelled() : super('Stopped.');
}

/// Picks the client for [settings]. [apiKey] only for the OpenAI-compatible
/// service.
AiClient aiClientFor(AiSettings settings, {String? apiKey}) =>
    switch (settings.provider) {
      AiProvider.ollama => OllamaClient(
        Uri.parse(settings.endpoint),
        settings.model,
      ),
      AiProvider.openAiCompatible => OpenAiCompatibleClient(
        Uri.parse(settings.endpoint),
        settings.model,
        apiKey ?? '',
      ),
    };

/// Largest reply accepted (characters); anything beyond is cut off.
const maxReplyChars = 200000;

/// A plain explanation for an HTTP status from an AI service.
AiFailure aiFailureFor(int status) => switch (status) {
  401 || 403 => const AiFailure(
    'The AI service refused the key (not signed in or not allowed).',
  ),
  404 => const AiFailure(
    'The AI service does not know this address or model. Check Settings → AI.',
  ),
  408 || 504 => const AiFailure('The AI service took too long. Try again.'),
  429 => const AiFailure(
    'The AI service says too many requests or the usage limit is reached. '
    'Wait a moment, or check your plan with the provider.',
  ),
  >= 500 => AiFailure(
    'The AI service had a problem ($status). Try again later.',
  ),
  _ => AiFailure('The AI service answered with an error ($status).'),
};

/// One HTTP exchange that can be cancelled.
class _Request {
  _Request(this.url, this.body, this.headers, this.timeout);
  final Uri url;
  final Map<String, dynamic> body;
  final Map<String, String> headers;
  final Duration timeout;
  HttpClient? _client;
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    _client?.close(force: true);
  }

  /// The response's text lines.
  Stream<String> lines() async* {
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = timeout;
    try {
      final request = await client.postUrl(url).timeout(timeout);
      request.headers.contentType = ContentType.json;
      headers.forEach(request.headers.set);
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(timeout);
      if (response.statusCode >= 400) {
        await response.drain<void>().catchError((_) {});
        throw aiFailureFor(response.statusCode);
      }
      yield* response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(timeout);
    } on AiFailure {
      rethrow;
    } on TimeoutException {
      if (cancelled) throw const AiCancelled();
      throw const AiFailure('The AI service took too long. Try again.');
    } on HandshakeException {
      throw AiFailure(
        'The secure connection to ${url.host} failed (its certificate was '
        'not accepted). Nothing was sent.',
      );
    } on SocketException {
      if (cancelled) throw const AiCancelled();
      throw AiFailure(
        'Could not reach the AI at ${url.host}:${url.port}. Is it running?',
      );
    } on HttpException {
      if (cancelled) throw const AiCancelled();
      throw const AiFailure('The connection to the AI service broke off.');
    } finally {
      client.close(force: true);
    }
  }
}

Future<Map<String, dynamic>> _postJson(
  Uri url,
  Map<String, dynamic> body, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 120),
}) async {
  final text = await _Request(url, body, headers, timeout).lines().join('\n');
  try {
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic>) {
      throw const AiFailure('The AI service sent an unexpected answer.');
    }
    return json;
  } on FormatException {
    throw const AiFailure('The AI service sent an unreadable answer.');
  }
}

/// Pieces of a streamed reply, one per line of the response; cut off at
/// [maxReplyChars].
Stream<String> _pieces(
  _Request request,
  String? Function(String line) piece,
) async* {
  var total = 0;
  await for (final line in request.lines()) {
    if (request.cancelled) throw const AiCancelled();
    final String? text;
    try {
      text = piece(line);
    } on FormatException {
      continue; // a broken line is skipped, not fatal
    }
    if (text == null || text.isEmpty) continue;
    total += text.length;
    if (total > maxReplyChars) return;
    yield text;
  }
  if (request.cancelled) throw const AiCancelled();
}

class OllamaClient extends AiClient {
  OllamaClient(this.endpoint, this.model);
  final Uri endpoint;
  final String model;
  _Request? _active;

  Map<String, dynamic> _body(List<AiMessage> messages, bool stream) => {
    'model': model,
    'stream': stream,
    'messages': [
      for (final m in messages)
        {
          'role': m.role,
          'content': m.content,
          if (m.images.isNotEmpty)
            'images': [for (final i in m.images) base64Encode(i)],
        },
    ],
  };

  @override
  Future<String> complete(List<AiMessage> messages) async {
    final json = await _postJson(
      endpoint.resolve('/api/chat'),
      _body(messages, false),
    );
    final content = (json['message'] as Map?)?['content'];
    if (content is! String) {
      throw const AiFailure('The local model sent no answer.');
    }
    return content.trim();
  }

  @override
  Stream<String> stream(List<AiMessage> messages) {
    final r = _active = _Request(
      endpoint.resolve('/api/chat'),
      _body(messages, true),
      const {},
      const Duration(seconds: 120),
    );
    // One JSON object per line.
    return _pieces(r, (line) {
      if (line.trim().isEmpty) return null;
      final json = jsonDecode(line);
      if (json is! Map) return null;
      if (json['error'] is String) throw AiFailure('${json['error']}');
      final content = (json['message'] as Map?)?['content'];
      return content is String ? content : null;
    });
  }

  @override
  void cancel() => _active?.cancel();
}

class OpenAiCompatibleClient extends AiClient {
  OpenAiCompatibleClient(this.endpoint, this.model, this.apiKey);
  final Uri endpoint;
  final String model;
  final String apiKey;
  _Request? _active;

  Map<String, dynamic> _body(List<AiMessage> messages, bool stream) => {
    'model': model,
    if (stream) 'stream': true,
    'messages': [
      for (final m in messages)
        {
          'role': m.role,
          'content': m.images.isEmpty
              ? m.content
              : [
                  {'type': 'text', 'text': m.content},
                  for (final i in m.images)
                    {
                      'type': 'image_url',
                      'image_url': {
                        'url': 'data:image/png;base64,${base64Encode(i)}',
                      },
                    },
                ],
        },
    ],
  };

  Map<String, String> get _headers => {'Authorization': 'Bearer $apiKey'};

  @override
  Future<String> complete(List<AiMessage> messages) async {
    if (apiKey.isEmpty) {
      throw const AiFailure('No key is set for the AI service.');
    }
    final json = await _postJson(
      endpoint.resolve('/v1/chat/completions'),
      _body(messages, false),
      headers: _headers,
    );
    final choices = json['choices'];
    final content = choices is List && choices.isNotEmpty
        ? (choices.first as Map?)?['message']?['content']
        : null;
    if (content is! String) {
      throw const AiFailure('The AI service sent no answer.');
    }
    return content.trim();
  }

  @override
  Stream<String> stream(List<AiMessage> messages) {
    if (apiKey.isEmpty) {
      return Stream.error(const AiFailure('No key is set for the AI service.'));
    }
    final r = _active = _Request(
      endpoint.resolve('/v1/chat/completions'),
      _body(messages, true),
      _headers,
      const Duration(seconds: 120),
    );
    // Server-sent events: "data: {...}" lines, ending with "data: [DONE]".
    return _pieces(r, (line) {
      if (!line.startsWith('data:')) return null;
      final data = line.substring(5).trim();
      if (data == '[DONE]' || data.isEmpty) return null;
      final json = jsonDecode(data);
      if (json is! Map) return null;
      final choices = json['choices'];
      final delta = choices is List && choices.isNotEmpty
          ? (choices.first as Map?)?['delta']?['content']
          : null;
      return delta is String ? delta : null;
    });
  }

  @override
  void cancel() => _active?.cancel();
}

/// Study and thinking helpers: each is a fixed instruction sent with the
/// content the user attached.
enum AiTool {
  ask,
  explain,
  summarize,
  outline,
  quiz,
  flashcards,
  brainstorm,
  tasks,
  mindmap,
  links,
}

extension AiToolInfo on AiTool {
  String get label => switch (this) {
    AiTool.ask => 'Ask',
    AiTool.explain => 'Explain',
    AiTool.summarize => 'Summarize',
    AiTool.outline => 'Outline',
    AiTool.quiz => 'Quiz me',
    AiTool.flashcards => 'Flashcards',
    AiTool.brainstorm => 'Brainstorm',
    AiTool.tasks => 'Break into tasks',
    AiTool.mindmap => 'Make a mindmap',
    AiTool.links => 'Suggest links',
  };

  /// Whether the answer proposes changes (shown for approval, never applied
  /// by themselves).
  bool get proposesChanges =>
      this == AiTool.tasks || this == AiTool.mindmap || this == AiTool.links;

  String get instruction => switch (this) {
    AiTool.ask => '',
    AiTool.explain =>
      'Explain the material simply, step by step, for a student.',
    AiTool.summarize => 'Write a short structured summary with key points.',
    AiTool.outline => 'Write a clear outline with headings and sub-points.',
    AiTool.quiz =>
      'Write 5 practice questions about the material, then the answers.',
    AiTool.flashcards =>
      'Write flashcards, one per line, as "Question :: Answer".',
    AiTool.brainstorm => 'Brainstorm ideas that build on the material.',
    AiTool.tasks =>
      'Break the material into concrete tasks. Answer only with one task '
          'per line, each starting with "- ".',
    AiTool.mindmap =>
      'Make a mindmap of the material. Answer only with an indented list: '
          'the central topic first, then "- " branches, indented by two '
          'spaces per level.',
    AiTool.links =>
      'From the note titles given, list which are related to the material. '
          'Answer only with one exact title per line, each starting with '
          '"- ".',
  };
}

/// "- item" lines of an answer, with their indentation level.
List<(int level, String text)> bulletLines(String answer) => [
  for (final line in answer.split('\n'))
    if (RegExp(r'^(\s*)[-*•]\s+(.+)$').firstMatch(line) case final m?)
      ((m.group(1)!.replaceAll('\t', '  ').length ~/ 2), m.group(2)!.trim()),
];

/// The central topic of a mindmap answer: its first non-bullet line.
String? mindmapRoot(String answer) {
  for (final line in answer.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (RegExp(r'^[-*•]\s').hasMatch(t)) return null;
    return t.replaceAll(RegExp(r'^#+\s*'), '');
  }
  return null;
}
