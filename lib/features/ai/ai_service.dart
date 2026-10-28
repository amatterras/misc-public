// Optional AI help. Off unless the user turns it on, and even then nothing
// leaves THEapp until the user presses Send in the AI window, which shows
// exactly what will be sent. Three kinds of service:
//   - a model running on this PC with Ollama (free, nothing leaves the PC);
//   - an OpenAI-compatible service with the user's own key (may cost money;
//     a ChatGPT subscription does not include this).
//   - Google Gemini with the user's own API key (Google AI Studio).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../data/repositories/canvas_repository.dart' show SettingsRepository;
import '../../data/storage/app_log.dart';

enum AiProvider { ollama, openAiCompatible, gemini }

extension AiProviderInfo on AiProvider {
  String get label => switch (this) {
    AiProvider.ollama => 'Local model on this PC (Ollama, free)',
    AiProvider.openAiCompatible => 'OpenAI-compatible service (your own key)',
    AiProvider.gemini => 'Google Gemini (your own API key)',
  };

  String get defaultEndpoint => switch (this) {
    AiProvider.ollama => 'http://127.0.0.1:11434',
    AiProvider.openAiCompatible => 'https://api.openai.com',
    AiProvider.gemini => 'https://generativelanguage.googleapis.com',
  };

  // Checked against the providers' model and deprecation pages on
  // 2026-10-24: gpt-4o-mini shuts down on 2027-01-14 (replacement
  // gpt-6-luna). New Gemini projects should use 3.8 Flash; 2.5 Flash remains
  // available to existing users but is capacity-limited for new projects.
  String get defaultModel => switch (this) {
    AiProvider.ollama => 'llama3.2',
    AiProvider.openAiCompatible => 'gpt-6-luna',
    AiProvider.gemini => 'gemini-3.8-flash',
  };

  /// Needs an API key (stored protected, per service).
  bool get needsKey => this != AiProvider.ollama;
}

/// Models the provider has shut down or announced a shutdown for, with the
/// replacement it names (from the official deprecation pages, checked
/// 2026-10-24). Shown as a warning in Settings; nothing is changed by itself.
const retiredAiModels = <String, ({String date, String replacement})>{
  'gpt-4o-mini': (date: '2027-01-14', replacement: 'gpt-6-luna'),
  'gpt-4o-mini-2024-07-18': (date: '2027-01-14', replacement: 'gpt-6-luna'),
  'gemini-2.0-flash': (date: '2026-06-01', replacement: 'gemini-3.6-flash'),
  'gemini-2.0-flash-001': (date: '2026-06-01', replacement: 'gemini-3.6-flash'),
  'gemini-2.0-flash-lite': (
    date: '2026-06-01',
    replacement: 'gemini-3.5-flash-lite',
  ),
  'gemini-2.0-flash-lite-001': (
    date: '2026-06-01',
    replacement: 'gemini-3.5-flash-lite',
  ),
};

/// A plain warning when [model] is retired or will be, else null.
String? retiredModelWarning(String model, {DateTime? today}) {
  final r = retiredAiModels[model.trim()];
  if (r == null) return null;
  final day = (today ?? DateTime.now()).toUtc().toIso8601String().substring(
    0,
    10,
  );
  return day.compareTo(r.date) >= 0
      ? 'The provider shut down "$model" on ${r.date}. Use '
            '"${r.replacement}" or another current model.'
      : 'The provider will shut down "$model" on ${r.date}. Its suggested '
            'replacement is "${r.replacement}".';
}

/// Kinds of content the AI may be given (each can be switched off).
enum AiSource { notes, canvases, tasks, archive, calendar, photos }

extension AiSourceInfo on AiSource {
  String get label => switch (this) {
    AiSource.notes => 'Notes',
    AiSource.canvases => 'Mindmaps (also as images)',
    AiSource.tasks => 'Tasks and projects',
    AiSource.archive => 'Archive resources',
    AiSource.calendar => 'Calendar entries',
    AiSource.photos => 'Photos you add in the AI window',
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

  // Address and model are kept per service, so switching between them never
  // sends one service's model name or address to another. (Settings from
  // before Gemini existed were shared; they still apply to Ollama and the
  // OpenAI-compatible service.)
  String get endpoint => _get(
    'endpoint.${provider.name}',
    provider == AiProvider.gemini
        ? provider.defaultEndpoint
        : _get('endpoint', provider.defaultEndpoint),
  );
  Future<void> setEndpoint(String url) =>
      _set('endpoint.${provider.name}', url.trim());

  String get model => _get(
    'model.${provider.name}',
    provider == AiProvider.gemini
        ? provider.defaultModel
        : _get('model', provider.defaultModel),
  );
  Future<void> setModel(String name) =>
      _set('model.${provider.name}', name.trim());

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
  bool get isLocal => isLocalAiHost(Uri.tryParse(endpoint)?.host ?? '');

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

/// What went wrong with an AI request, so callers can react without
/// reading the message.
enum AiErrorKind {
  /// The settings are incomplete or not valid (nothing was sent).
  settings,

  /// The service could not be reached at all (not running, wrong address).
  unreachable,

  /// The connection broke off after it was made.
  network,

  /// The secure connection was not accepted.
  certificate,
  timeout,

  /// The key was refused.
  auth,

  /// Unknown address or model.
  notFound,

  /// Too many requests, or the usage limit is reached.
  rateLimited,

  /// The service itself failed (5xx).
  server,

  /// The service would not accept this request (4xx).
  rejected,
  region,

  /// The provider's safety rules stopped the answer.
  blocked,

  /// An answer that could not be read.
  badResponse,
  cancelled,
}

class AiFailure implements Exception {
  const AiFailure(
    this.message, {
    this.kind = AiErrorKind.badResponse,
    this.status,
    this.retryAfter,
  });
  final String message;
  final AiErrorKind kind;

  /// The HTTP status, when the service answered with one.
  final int? status;

  /// How long the service asked to wait before trying again.
  final Duration? retryAfter;

  /// Whether the same request may work when tried again a little later.
  bool get retryable => switch (kind) {
    AiErrorKind.rateLimited || AiErrorKind.network => true,
    AiErrorKind.server => status != 501,
    _ => false,
  };

  @override
  String toString() => message;
}

/// How passing problems (a busy service, a broken connection) are tried
/// again: at most [attempts] tries in all, waiting [base] and then three
/// times longer each time (±20 %), or as long as the service asks. A
/// service that asks for a wait longer than [maxWait] is not tried again.
class AiRetry {
  const AiRetry({
    this.attempts = 3,
    this.base = const Duration(milliseconds: 700),
    this.maxWait = const Duration(seconds: 10),
    this.sleep = _sleep,
  });

  /// One try, no retries.
  static const none = AiRetry(attempts: 1);

  final int attempts;
  final Duration base;
  final Duration maxWait;
  final Future<void> Function(Duration) sleep;

  static Future<void> _sleep(Duration d) => Future.delayed(d);

  /// The wait before the try after [attempt] (from 1), or null to give up.
  Duration? waitAfter(int attempt, AiFailure failure) {
    if (!failure.retryable || attempt >= attempts) return null;
    final asked = failure.retryAfter;
    if (asked != null) return asked > maxWait ? null : asked;
    final ms =
        base.inMilliseconds *
        pow(3, attempt - 1) *
        (0.8 + Random().nextDouble() * 0.4);
    final wait = Duration(milliseconds: ms.round());
    return wait > maxWait ? maxWait : wait;
  }
}

/// Sends a conversation and returns the reply, whole ([complete]) or piece
/// by piece as it is written ([stream]); [cancel] stops a request.
abstract class AiClient {
  AiClient({this.retry = const AiRetry()});

  final AiRetry retry;

  Future<String> complete(List<AiMessage> messages);

  /// The reply in pieces. Services that cannot stream give it in one piece.
  Stream<String> stream(List<AiMessage> messages) async* {
    yield await complete(messages);
  }

  /// The models the service offers (to check the setting); empty when it
  /// does not list them.
  Future<List<String>> listModels() async => const [];

  /// Stops the request in progress (its stream ends with [AiCancelled]).
  void cancel() {}
}

/// The user stopped the request.
/// The last gate before a request leaves the app. Whatever built the
/// request (the AI window, a tool, a test), nothing is sent unless AI is on,
/// pictures only when allowed, and never anything that holds text from the
/// open private vault. The interface also hides these choices, but the rule
/// is kept here, where it cannot be skipped by a screen that forgets it.
class GuardedAiClient extends AiClient {
  GuardedAiClient(this._inner, this.settings, {this.vaultCheck})
    : super(retry: _inner.retry);

  final AiClient _inner;
  final AiSettings settings;

  /// True when a text contains private vault content.
  final bool Function(String text)? vaultCheck;

  List<AiMessage> _checked(List<AiMessage> messages) {
    if (!settings.enabled) {
      throw const AiFailure(
        'AI is switched off in Settings. Nothing was sent.',
        kind: AiErrorKind.settings,
      );
    }
    if (!settings.allowImages && messages.any((m) => m.images.isNotEmpty)) {
      throw const AiFailure(
        'Pictures are not allowed in Settings → AI. Nothing was sent.',
        kind: AiErrorKind.settings,
      );
    }
    final check = vaultCheck;
    if (check != null && messages.any((m) => check(m.content))) {
      throw const AiFailure(
        'Private vault content can never be sent to AI. Nothing was sent.',
        kind: AiErrorKind.rejected,
      );
    }
    return messages;
  }

  @override
  Future<String> complete(List<AiMessage> messages) async =>
      _inner.complete(_checked(messages));

  @override
  Stream<String> stream(List<AiMessage> messages) async* {
    yield* _inner.stream(_checked(messages));
  }

  @override
  Future<List<String>> listModels() => _inner.listModels();

  @override
  void cancel() => _inner.cancel();
}

class AiCancelled extends AiFailure {
  const AiCancelled() : super('Stopped.', kind: AiErrorKind.cancelled);
}

/// Picks the client for [settings]. [apiKey] for the services that need
/// one. An address that cannot be read gives a client that explains so.
AiClient aiClientFor(
  AiSettings settings, {
  String? apiKey,
  AiRetry retry = const AiRetry(),
}) {
  final endpoint = Uri.tryParse(settings.endpoint) ?? Uri();
  return switch (settings.provider) {
    AiProvider.ollama => OllamaClient(endpoint, settings.model, retry: retry),
    AiProvider.openAiCompatible => OpenAiCompatibleClient(
      endpoint,
      settings.model,
      apiKey ?? '',
      retry: retry,
    ),
    AiProvider.gemini => GeminiClient(
      endpoint,
      settings.model,
      apiKey ?? '',
      retry: retry,
    ),
  };
}

/// Whether [host] is this device (nothing sent there leaves it).
bool isLocalAiHost(String host) {
  final h = host.toLowerCase();
  return h == '127.0.0.1' || h == 'localhost' || h == '::1' || h == '[::1]';
}

/// Why [endpoint] cannot be used, or null. A key is only ever sent over
/// https, except to this device.
AiFailure? aiAddressProblem(Uri endpoint, {required bool sendsKey}) {
  if (!(endpoint.isScheme('http') || endpoint.isScheme('https')) ||
      endpoint.host.isEmpty) {
    return const AiFailure(
      'The AI address is not valid. It should look like '
      'https://example.com (Settings → AI).',
      kind: AiErrorKind.settings,
    );
  }
  if (sendsKey && endpoint.isScheme('http') && !isLocalAiHost(endpoint.host)) {
    return const AiFailure(
      'The AI address must start with https:// so the key is not sent '
      'unprotected. Nothing was sent.',
      kind: AiErrorKind.settings,
    );
  }
  return null;
}

/// [endpoint]'s path without a trailing slash or any of [suffixes] (people
/// often paste the full address of one call).
String _basePath(Uri endpoint, List<String> suffixes) {
  var path = endpoint.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  for (final s in suffixes) {
    if (path.endsWith(s)) return path.substring(0, path.length - s.length);
  }
  return path;
}

/// [endpoint]'s server with [path] and [query] (and nothing else).
Uri _at(Uri endpoint, String path, [Map<String, String>? query]) => Uri(
  scheme: endpoint.scheme,
  host: endpoint.host,
  port: endpoint.hasPort ? endpoint.port : null,
  path: path,
  queryParameters: query,
);

/// Ollama's address for call [name] (`chat`, `tags`).
Uri ollamaUrl(Uri endpoint, String name) => _at(
  endpoint,
  '${_basePath(endpoint, const ['/api/chat', '/api/tags', '/api'])}/api/$name',
);

/// An OpenAI-compatible service's address for call [name]
/// (`chat/completions`, `models`). The address may carry the service's
/// own path, such as `https://openrouter.ai/api/v1`; without one, `/v1`.
Uri openAiUrl(Uri endpoint, String name) {
  final base = _basePath(endpoint, const ['/chat/completions', '/models']);
  return _at(endpoint, '${base.isEmpty ? '/v1' : base}/$name');
}

/// Gemini's address: `…/models/{model}:{method}`, or the model list when
/// [model] is null. Without a path of its own, the `v1beta` API.
Uri geminiUrl(Uri endpoint, String? model, [String method = '']) {
  final base = _basePath(endpoint, const ['/models']);
  final root = '${base.isEmpty ? '/v1beta' : base}/models';
  return model == null
      ? _at(endpoint, root, {'pageSize': '1000'})
      : _at(
          endpoint,
          '$root/$model:$method',
          method.startsWith('stream') ? {'alt': 'sse'} : null,
        );
}

/// Whether [model] is among [offered] (Ollama lists `llama3.2:latest` for
/// `llama3.2`).
bool aiModelOffered(String model, List<String> offered) =>
    offered.any((o) => o == model || o == '$model:latest');

/// [text] with anything that looks like a key or token replaced, so it can
/// be logged or shown.
String redactSecrets(String text) => text
    .replaceAll(RegExp(r'Bearer\s+\S+', caseSensitive: false), 'Bearer •••')
    .replaceAll(RegExp(r'\bsk-[A-Za-z0-9_\-]{8,}'), 'sk-•••')
    .replaceAll(RegExp(r'\bAIza[0-9A-Za-z_\-]{20,}'), 'AIza•••')
    .replaceAll(
      RegExp(r'([?&](?:key|api_key|token)=)[^&\s]+', caseSensitive: false),
      r'$1•••',
    );

/// Largest reply accepted (characters); anything beyond is cut off.
const maxReplyChars = 200000;

/// The picture type of [bytes] from its first bytes (PNG when unknown):
/// services reject a picture sent under the wrong type.
String aiImageMime(Uint8List bytes) {
  bool starts(List<int> sig, [int at = 0]) =>
      bytes.length >= at + sig.length &&
      [for (var i = 0; i < sig.length; i++) bytes[at + i] == sig[i]]
          .every((ok) => ok);
  if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
      starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return 'image/png';
}

/// A plain explanation for an HTTP status from an AI service.
AiFailure aiFailureFor(
  int status, {
  String body = '',
  Duration? retryAfter,
}) => switch (status) {
  _
      when body.contains('API_KEY_INVALID') ||
          body.contains('API key not valid') =>
    AiFailure(
      'The AI service refused the key. Check it in Settings → AI.',
      kind: AiErrorKind.auth,
      status: status,
    ),
  _ when body.contains('User location is not supported') => AiFailure(
    'This AI service is not available in your region.',
    kind: AiErrorKind.region,
    status: status,
  ),
  _ when body.contains('try pulling it first') => AiFailure(
    'This model is not installed in Ollama. Install it with "ollama pull" '
    'and the model name, or pick an installed model in Settings → AI.',
    kind: AiErrorKind.notFound,
    status: status,
  ),
  400 || 422 => AiFailure(
    'The AI service could not accept this request (check the model name, '
    'or remove pictures if the model cannot read them).',
    kind: AiErrorKind.rejected,
    status: status,
  ),
  401 || 403 => AiFailure(
    'The AI service refused the key (not signed in or not allowed).',
    kind: AiErrorKind.auth,
    status: status,
  ),
  404 => AiFailure(
    'The AI service does not know this address or model. Check Settings → AI.',
    kind: AiErrorKind.notFound,
    status: status,
  ),
  408 || 504 => AiFailure(
    'The AI service took too long. Try again.',
    kind: status == 504 ? AiErrorKind.server : AiErrorKind.timeout,
    status: status,
  ),
  429 => AiFailure(
    'The AI service says too many requests or the usage limit is reached. '
    'Wait a moment, or check your plan with the provider.',
    kind: AiErrorKind.rateLimited,
    status: status,
    retryAfter: retryAfter,
  ),
  >= 500 => AiFailure(
    'The AI service had a problem ($status). Try again later.',
    kind: AiErrorKind.server,
    status: status,
    retryAfter: retryAfter,
  ),
  _ => AiFailure(
    'The AI service answered with an error ($status).',
    kind: AiErrorKind.rejected,
    status: status,
  ),
};

/// A Retry-After header in seconds (dates are not used by these services).
Duration? _retryAfter(String? value) {
  final seconds = int.tryParse(value?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}

/// One HTTP exchange that can be cancelled.
class _Request {
  _Request(
    this.url,
    this.body,
    this.headers,
    this.timeout, {
    this.method = 'POST',
  });
  final Uri url;
  final String method;
  final Map<String, dynamic>? body;
  final Map<String, String> headers;
  final Duration timeout;
  HttpClient? _client;
  bool cancelled = false;
  final _stopped = Completer<void>();

  void cancel() {
    cancelled = true;
    _client?.close(force: true);
    if (!_stopped.isCompleted) _stopped.complete();
  }

  /// Waits [wait] before a retry; a cancel ends the wait at once.
  Future<void> pause(AiRetry retry, Duration wait) async {
    await Future.any([retry.sleep(wait), _stopped.future]);
    if (cancelled) throw const AiCancelled();
  }

  /// The response's text lines.
  Stream<String> lines() async* {
    if (cancelled) throw const AiCancelled();
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = timeout;
    var connected = false;
    try {
      final request = await client.openUrl(method, url).timeout(timeout);
      connected = true;
      headers.forEach(request.headers.set);
      final body = this.body;
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode >= 400) {
        // A little of the error body, only to recognise known causes; it is
        // never shown or logged as is.
        final text = await response
            .transform(utf8.decoder)
            .take(4)
            .join()
            .timeout(const Duration(seconds: 5))
            .catchError((_) => '');
        throw aiFailureFor(
          response.statusCode,
          body: text,
          retryAfter: _retryAfter(response.headers.value('retry-after')),
        );
      }
      // Not `yield*`: its errors would pass by the explanations below.
      await for (final line
          in response
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(timeout)) {
        yield line;
      }
    } on AiFailure catch (f) {
      _log(f);
      rethrow;
    } on TimeoutException {
      if (cancelled) throw const AiCancelled();
      throw _log(
        const AiFailure(
          'The AI service took too long. Try again.',
          kind: AiErrorKind.timeout,
        ),
      );
    } on HandshakeException {
      throw _log(
        AiFailure(
          'The secure connection to ${url.host} failed (its certificate was '
          'not accepted). Nothing was sent.',
          kind: AiErrorKind.certificate,
        ),
      );
    } on SocketException {
      if (cancelled) throw const AiCancelled();
      throw _log(
        connected
            ? const AiFailure(
                'The connection to the AI service broke off.',
                kind: AiErrorKind.network,
              )
            : AiFailure(
                'Could not reach the AI at ${url.host}:${url.port}. Is it '
                'running, and is the address right?',
                kind: AiErrorKind.unreachable,
              ),
      );
    } on HttpException {
      if (cancelled) throw const AiCancelled();
      throw _log(
        const AiFailure(
          'The connection to the AI service broke off.',
          kind: AiErrorKind.network,
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Logs a failure with where it went, never the content or the key.
  AiFailure _log(AiFailure f) {
    if (f is! AiCancelled) {
      AppLog.warn(
        redactSecrets(
          'AI $method ${url.host}${url.path}: ${f.kind.name}'
          '${f.status == null ? '' : ' (${f.status})'}',
        ),
      );
    }
    return f;
  }
}

Map<String, dynamic> _decode(String text) {
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

/// One JSON answer from [open], tried again after a passing problem.
Future<Map<String, dynamic>> _json(
  AiRetry retry,
  _Request Function() open,
) async {
  for (var attempt = 1; ; attempt++) {
    final r = open();
    try {
      final text = await r.lines().join('\n');
      if (r.cancelled) throw const AiCancelled();
      return _decode(text);
    } on AiFailure catch (f) {
      final wait = r.cancelled ? null : retry.waitAfter(attempt, f);
      if (wait == null) rethrow;
      AppLog.info('AI: ${f.kind.name}, trying again in ${wait.inSeconds} s');
      await r.pause(retry, wait);
    }
  }
}

/// Pieces of a streamed reply, one per line of the response; cut off at
/// [maxReplyChars]. A passing problem before anything arrived is tried
/// again; once part of a reply arrived it never is (nothing is repeated).
Stream<String> _pieces(
  AiRetry retry,
  _Request Function() open,
  String? Function(String line) piece,
) async* {
  for (var attempt = 1; ; attempt++) {
    final request = open();
    var received = false;
    try {
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
        received = true;
        yield text;
      }
      if (request.cancelled) throw const AiCancelled();
      return;
    } on AiFailure catch (f) {
      final wait = received || request.cancelled
          ? null
          : retry.waitAfter(attempt, f);
      if (wait == null) rethrow;
      AppLog.info('AI: ${f.kind.name}, trying again in ${wait.inSeconds} s');
      await request.pause(retry, wait);
    }
  }
}

/// An error object sent inside a streamed OpenAI-style reply.
AiFailure _streamError(Object? error) {
  final message = error is Map ? '${error['message'] ?? ''}' : '$error';
  final short = redactSecrets(message.trim());
  return AiFailure(
    short.isEmpty
        ? 'The AI service stopped with an error.'
        : 'The AI service stopped with an error: '
              '${short.length > 200 ? '${short.substring(0, 200)}…' : short}',
    kind: AiErrorKind.server,
  );
}

class OllamaClient extends AiClient {
  OllamaClient(this.endpoint, this.model, {super.retry});
  final Uri endpoint;
  final String model;
  _Request? _active;

  /// A local model may need a while to load before it answers.
  static const timeout = Duration(seconds: 300);

  _Request _open(String name, Map<String, dynamic>? body) => _active = _Request(
    ollamaUrl(endpoint, name),
    body,
    const {},
    timeout,
    method: body == null ? 'GET' : 'POST',
  );

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

  AiFailure? get _invalid {
    if (model.trim().isEmpty) {
      return const AiFailure(
        'No model is set (Settings → AI).',
        kind: AiErrorKind.settings,
      );
    }
    return aiAddressProblem(endpoint, sendsKey: false);
  }

  @override
  Future<String> complete(List<AiMessage> messages) async {
    if (_invalid case final bad?) throw bad;
    final json = await _json(
      retry,
      () => _open('chat', _body(messages, false)),
    );
    final content = (json['message'] as Map?)?['content'];
    if (content is! String) {
      throw const AiFailure('The local model sent no answer.');
    }
    return content.trim();
  }

  @override
  Stream<String> stream(List<AiMessage> messages) {
    if (_invalid case final bad?) return Stream.error(bad);
    // One JSON object per line.
    return _pieces(retry, () => _open('chat', _body(messages, true)), (line) {
      if (line.trim().isEmpty) return null;
      final json = jsonDecode(line);
      if (json is! Map) return null;
      if (json['error'] != null) throw _streamError(json['error']);
      final content = (json['message'] as Map?)?['content'];
      return content is String ? content : null;
    });
  }

  @override
  Future<List<String>> listModels() async {
    if (aiAddressProblem(endpoint, sendsKey: false) case final bad?) {
      throw bad;
    }
    final json = await _json(retry, () => _open('tags', null));
    return [
      for (final m in json['models'] as List? ?? const [])
        if (m is Map && m['name'] is String) m['name'] as String,
    ];
  }

  @override
  void cancel() => _active?.cancel();
}

class OpenAiCompatibleClient extends AiClient {
  OpenAiCompatibleClient(this.endpoint, this.model, this.apiKey, {super.retry});
  final Uri endpoint;
  final String model;
  final String apiKey;
  _Request? _active;

  _Request _open(String name, Map<String, dynamic>? body) => _active = _Request(
    openAiUrl(endpoint, name),
    body,
    _headers,
    const Duration(seconds: 120),
    method: body == null ? 'GET' : 'POST',
  );

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
                        'url':
                            'data:${aiImageMime(i)};base64,${base64Encode(i)}',
                      },
                    },
                ],
        },
    ],
  };

  Map<String, String> get _headers => {'Authorization': 'Bearer $apiKey'};

  AiFailure? _problem({bool needsModel = true}) {
    if (apiKey.isEmpty) {
      return const AiFailure(
        'No key is set for the AI service.',
        kind: AiErrorKind.settings,
      );
    }
    if (needsModel && model.trim().isEmpty) {
      return const AiFailure(
        'No model is set (Settings → AI).',
        kind: AiErrorKind.settings,
      );
    }
    return aiAddressProblem(endpoint, sendsKey: true);
  }

  @override
  Future<String> complete(List<AiMessage> messages) async {
    if (_problem() case final bad?) throw bad;
    final json = await _json(
      retry,
      () => _open('chat/completions', _body(messages, false)),
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
    if (_problem() case final bad?) return Stream.error(bad);
    // Server-sent events: "data: {...}" lines, ending with "data: [DONE]".
    return _pieces(
      retry,
      () => _open('chat/completions', _body(messages, true)),
      (line) {
        if (!line.startsWith('data:')) return null;
        final data = line.substring(5).trim();
        if (data == '[DONE]' || data.isEmpty) return null;
        final json = jsonDecode(data);
        if (json is! Map) return null;
        if (json['error'] != null) throw _streamError(json['error']);
        final choices = json['choices'];
        final delta = choices is List && choices.isNotEmpty
            ? (choices.first as Map?)?['delta']?['content']
            : null;
        return delta is String ? delta : null;
      },
    );
  }

  @override
  Future<List<String>> listModels() async {
    if (_problem(needsModel: false) case final bad?) throw bad;
    final json = await _json(retry, () => _open('models', null));
    return [
      for (final m in json['data'] as List? ?? const [])
        if (m is Map && m['id'] is String) m['id'] as String,
    ];
  }

  @override
  void cancel() => _active?.cancel();
}

/// Google Gemini through its public REST API (generativelanguage, v1beta:
/// `models/{model}:generateContent` and `:streamGenerateContent?alt=sse`).
/// The key goes in the `x-goog-api-key` header, never in the address.
class GeminiClient extends AiClient {
  GeminiClient(this.endpoint, this.model, this.apiKey, {super.retry});
  final Uri endpoint;
  final String model;
  final String apiKey;
  _Request? _active;

  /// Model names are plain ids such as `gemini-2.5-flash`.
  static final _modelPattern = RegExp(r'^[A-Za-z0-9._-]{1,80}$');

  /// Gemini's request: the system text apart, then user/model turns, with
  /// pictures as inline PNG data.
  static Map<String, dynamic> body(List<AiMessage> messages) {
    final system = [
      for (final m in messages)
        if (m.role == 'system') m.content,
    ].join('\n\n');
    return {
      if (system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
      'contents': [
        for (final m in messages)
          if (m.role != 'system')
            {
              'role': m.role == 'assistant' ? 'model' : 'user',
              'parts': [
                if (m.content.isNotEmpty) {'text': m.content},
                for (final i in m.images)
                  {
                    'inlineData': {
                      'mimeType': aiImageMime(i),
                      'data': base64Encode(i),
                    },
                  },
              ],
            },
      ],
    };
  }

  /// The text of one response object; throws for blocked or failed ones.
  static String? textOf(Object? json) {
    if (json is! Map) return null;
    final error = json['error'];
    if (error is Map) {
      throw aiFailureFor(
        (error['code'] as num?)?.toInt() ?? 500,
        body: '${error['status']} ${error['message']}',
      );
    }
    final blocked = (json['promptFeedback'] as Map?)?['blockReason'];
    if (blocked is String) {
      throw const AiFailure(
        'Gemini declined to answer this request (its safety rules).',
        kind: AiErrorKind.blocked,
      );
    }
    final candidates = json['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final first = candidates.first;
    if (first is! Map) return null;
    final parts = (first['content'] as Map?)?['parts'];
    final text = parts is List
        ? [
            for (final p in parts)
              if (p is Map && p['text'] is String) p['text'] as String,
          ].join()
        : '';
    if (text.isEmpty && first['finishReason'] == 'SAFETY') {
      throw const AiFailure(
        'Gemini stopped the answer (its safety rules).',
        kind: AiErrorKind.blocked,
      );
    }
    return text;
  }

  Map<String, String> get _headers => {'x-goog-api-key': apiKey};

  _Request _open(Uri url, Map<String, dynamic>? body) => _active = _Request(
    url,
    body,
    _headers,
    const Duration(seconds: 120),
    method: body == null ? 'GET' : 'POST',
  );

  AiFailure? _problem({bool needsModel = true}) {
    if (apiKey.isEmpty) {
      return const AiFailure(
        'No Gemini API key is set (Settings → AI).',
        kind: AiErrorKind.settings,
      );
    }
    if (needsModel && !_modelPattern.hasMatch(model)) {
      return const AiFailure(
        'The Gemini model name is not valid.',
        kind: AiErrorKind.settings,
      );
    }
    return aiAddressProblem(endpoint, sendsKey: true);
  }

  @override
  Future<String> complete(List<AiMessage> messages) async {
    if (_problem() case final bad?) throw bad;
    final json = await _json(
      retry,
      () =>
          _open(geminiUrl(endpoint, model, 'generateContent'), body(messages)),
    );
    final text = textOf(json);
    if (text == null || text.isEmpty) {
      throw const AiFailure('Gemini sent no answer.');
    }
    return text.trim();
  }

  @override
  Stream<String> stream(List<AiMessage> messages) {
    if (_problem() case final bad?) return Stream.error(bad);
    // Server-sent events: one "data: {...}" line per piece.
    return _pieces(
      retry,
      () => _open(
        geminiUrl(endpoint, model, 'streamGenerateContent'),
        body(messages),
      ),
      (line) {
        if (!line.startsWith('data:')) return null;
        final data = line.substring(5).trim();
        if (data.isEmpty) return null;
        return textOf(jsonDecode(data));
      },
    );
  }

  /// Models that can write answers (`generateContent`), without the
  /// `models/` prefix.
  @override
  Future<List<String>> listModels() async {
    if (_problem(needsModel: false) case final bad?) throw bad;
    final json = await _json(
      retry,
      () => _open(geminiUrl(endpoint, null), null),
    );
    return [
      for (final m in json['models'] as List? ?? const [])
        if (m is Map &&
            m['name'] is String &&
            ((m['supportedGenerationMethods'] as List?)?.contains(
                  'generateContent',
                ) ??
                true))
          (m['name'] as String).replaceFirst('models/', ''),
    ];
  }

  @override
  void cancel() => _active?.cancel();
}

/// The result of [testAiConnection], step by step in plain words.
class AiConnectionReport {
  const AiConnectionReport(this.ok, this.steps, {this.failure});
  final bool ok;
  final List<String> steps;
  final AiFailure? failure;
}

/// A real check of the settings: reaches the service, checks the key and
/// that the model exists (where the service lists its models), then sends
/// one short test sentence.
Future<AiConnectionReport> testAiConnection(
  AiClient client,
  String model,
) async {
  final steps = <String>[];
  try {
    var offered = const <String>[];
    try {
      offered = await client.listModels();
      steps.add(
        offered.isEmpty
            ? 'Reached the service.'
            : 'Reached the service (${offered.length} models offered).',
      );
    } on AiFailure catch (f) {
      if (f.kind != AiErrorKind.notFound) rethrow;
      steps.add('Reached the service (it does not list its models).');
    }
    if (offered.isNotEmpty && !aiModelOffered(model, offered)) {
      final f = AiFailure(
        'The service has no model "$model". It offers: '
        '${offered.take(8).join(', ')}${offered.length > 8 ? ', …' : ''}.',
        kind: AiErrorKind.notFound,
      );
      return AiConnectionReport(false, [...steps, f.message], failure: f);
    }
    final reply = await client.complete(const [
      AiMessage('user', 'Reply with the single word OK.'),
    ]);
    steps.add(
      'The model "$model" answered: '
      '“${reply.length > 80 ? '${reply.substring(0, 80)}…' : reply}”',
    );
    return AiConnectionReport(true, steps);
  } on AiFailure catch (f) {
    return AiConnectionReport(false, [...steps, f.message], failure: f);
  }
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
