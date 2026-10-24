// The AI service against a fake AI server on this PC (real HTTP, nothing
// leaves the PC): addresses, typed errors, bounded retries, cancelling,
// streaming, model lists, the connection test and redaction.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/data/repositories/canvas_repository.dart'
    show SettingsRepository;
import 'package:flutter_application_1/data/storage/app_log.dart';
import 'package:flutter_application_1/features/ai/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake AI server: answers each request with the next handler (the last
/// one repeats) and records what it was sent.
class FakeAi {
  FakeAi._(this._server);
  final HttpServer _server;
  final List<FutureOr<void> Function(HttpRequest r)> handlers = [];
  final requests =
      <
        ({String method, String path, Map<String, String> headers, String body})
      >[];

  static Future<FakeAi> start() async {
    final s = FakeAi._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    s._server.listen((r) async {
      final body = await utf8.decoder.bind(r).join();
      final headers = <String, String>{};
      r.headers.forEach((k, v) => headers[k] = v.join(','));
      s.requests.add((
        method: r.method,
        path: r.uri.toString(),
        headers: headers,
        body: body,
      ));
      final i = s.requests.length - 1;
      final h = s.handlers[i < s.handlers.length ? i : s.handlers.length - 1];
      try {
        await h(r);
      } catch (_) {
        // The test closed the connection on purpose.
      }
    });
    return s;
  }

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);
}

FutureOr<void> Function(HttpRequest) status(
  int code, {
  String body = '{}',
  Map<String, String> headers = const {},
}) => (r) async {
  r.response.statusCode = code;
  headers.forEach(r.response.headers.set);
  r.response.write(body);
  await r.response.close();
};

FutureOr<void> Function(HttpRequest) json(Object value) =>
    status(200, body: jsonEncode(value));

FutureOr<void> Function(HttpRequest) sse(List<String> lines) => (r) async {
  r.response.headers.contentType = ContentType('text', 'event-stream');
  for (final l in lines) {
    r.response.write('$l\n\n');
    await r.response.flush();
  }
  await r.response.close();
};

/// Records the waits instead of waiting.
class Sleeps {
  final waits = <Duration>[];
  Future<void> call(Duration d) async => waits.add(d);
}

const _key = 'sk-test-THISKEYMUSTNEVERAPPEAR1234';

void main() {
  late FakeAi ai;
  late Sleeps sleeps;
  late AiRetry retry;

  setUpAll(() => HttpOverrides.global = null);
  setUp(() async {
    ai = await FakeAi.start();
    sleeps = Sleeps();
    retry = AiRetry(sleep: sleeps.call);
  });
  tearDown(() => ai.close());

  group('addresses', () {
    test('OpenAI-compatible keeps the service path, else uses /v1', () {
      String u(String e, String n) => openAiUrl(Uri.parse(e), n).toString();
      expect(
        u('https://api.openai.com', 'chat/completions'),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(
        u('https://api.openai.com/v1/', 'models'),
        'https://api.openai.com/v1/models',
      );
      expect(
        u('https://openrouter.ai/api/v1', 'chat/completions'),
        'https://openrouter.ai/api/v1/chat/completions',
      );
      expect(
        u('https://api.groq.com/openai/v1/chat/completions', 'models'),
        'https://api.groq.com/openai/v1/models',
      );
      expect(
        u('https://generativelanguage.googleapis.com/v1beta/openai', 'models'),
        'https://generativelanguage.googleapis.com/v1beta/openai/models',
      );
    });

    test('Ollama and Gemini addresses', () {
      expect(
        ollamaUrl(Uri.parse('http://127.0.0.1:11434/'), 'chat').toString(),
        'http://127.0.0.1:11434/api/chat',
      );
      expect(
        ollamaUrl(Uri.parse('http://pc:11434/api'), 'tags').toString(),
        'http://pc:11434/api/tags',
      );
      final g = Uri.parse('https://generativelanguage.googleapis.com');
      expect(
        geminiUrl(g, 'gemini-2.5-flash', 'streamGenerateContent').toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-flash:streamGenerateContent?alt=sse',
      );
      expect(
        geminiUrl(g, null).toString(),
        'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000',
      );
    });

    test('a key is never sent over plain http to another computer', () async {
      final client = OpenAiCompatibleClient(
        Uri.parse('http://example.com'),
        'm',
        _key,
      );
      await expectLater(
        client.complete(const [AiMessage('user', 'x')]),
        throwsA(
          isA<AiFailure>().having((f) => f.kind, 'kind', AiErrorKind.settings),
        ),
      );
      expect(
        aiAddressProblem(Uri.parse('http://localhost:1234'), sendsKey: true),
        isNull,
      );
      expect(
        aiAddressProblem(
          Uri.parse('http://192.168.1.5:11434'),
          sendsKey: false,
        ),
        isNull,
      );
    });

    test('an unreadable address explains itself instead of crashing', () async {
      final settings = _settings({
        'ai.provider': 'openAiCompatible',
        'ai.endpoint.openAiCompatible': 'not an address',
      });
      final client = aiClientFor(settings, apiKey: _key);
      await expectLater(
        client.stream(const [AiMessage('user', 'x')]).toList(),
        throwsA(
          isA<AiFailure>().having((f) => f.kind, 'kind', AiErrorKind.settings),
        ),
      );
    });
  });

  group('retries', () {
    test('a busy service is tried again, then answers', () async {
      ai.handlers.addAll([
        status(503),
        status(502),
        json({
          'message': {'content': ' OK '},
        }),
      ]);
      final reply = await OllamaClient(
        ai.url,
        'llama3.2',
        retry: retry,
      ).complete(const [AiMessage('user', 'x')]);
      expect(reply, 'OK');
      expect(ai.requests, hasLength(3));
      expect(sleeps.waits, hasLength(2));
      expect(sleeps.waits[1] > sleeps.waits[0], isTrue);
    });

    test('at most three tries in all', () async {
      ai.handlers.add(status(500));
      await expectLater(
        OllamaClient(
          ai.url,
          'm',
          retry: retry,
        ).complete(const [AiMessage('user', 'x')]),
        throwsA(
          isA<AiFailure>()
              .having((f) => f.kind, 'kind', AiErrorKind.server)
              .having((f) => f.status, 'status', 500),
        ),
      );
      expect(ai.requests, hasLength(3));
    });

    test('Retry-After is followed, but not a long one', () async {
      ai.handlers.addAll([
        status(429, headers: {'retry-after': '2'}),
        json({
          'choices': [
            {
              'message': {'content': 'hi'},
            },
          ],
        }),
      ]);
      final client = OpenAiCompatibleClient(ai.url, 'm', _key, retry: retry);
      expect(await client.complete(const [AiMessage('user', 'x')]), 'hi');
      expect(sleeps.waits, [const Duration(seconds: 2)]);

      ai.requests.clear();
      ai.handlers
        ..clear()
        ..add(status(429, headers: {'retry-after': '3600'}));
      await expectLater(
        client.complete(const [AiMessage('user', 'x')]),
        throwsA(
          isA<AiFailure>().having(
            (f) => f.kind,
            'kind',
            AiErrorKind.rateLimited,
          ),
        ),
      );
      expect(ai.requests, hasLength(1));
    });

    test('a refused key or unknown model is not tried again', () async {
      for (final (code, kind) in [
        (401, AiErrorKind.auth),
        (404, AiErrorKind.notFound),
        (400, AiErrorKind.rejected),
      ]) {
        ai.requests.clear();
        ai.handlers
          ..clear()
          ..add(status(code));
        await expectLater(
          OpenAiCompatibleClient(
            ai.url,
            'm',
            _key,
            retry: retry,
          ).complete(const [AiMessage('user', 'x')]),
          throwsA(isA<AiFailure>().having((f) => f.kind, 'kind', kind)),
        );
        expect(ai.requests, hasLength(1), reason: '$code');
      }
      expect(sleeps.waits, isEmpty);
    });

    test('a service that is not running is reported, not retried', () async {
      final port = ai.url.port;
      await ai.close();
      await expectLater(
        OllamaClient(
          Uri.parse('http://127.0.0.1:$port'),
          'm',
          retry: retry,
        ).complete(const [AiMessage('user', 'x')]),
        throwsA(
          isA<AiFailure>()
              .having((f) => f.kind, 'kind', AiErrorKind.unreachable)
              .having((f) => f.message, 'message', contains('$port')),
        ),
      );
      expect(sleeps.waits, isEmpty);
    });

    test('a 404 from Ollama for a missing model says to install it', () async {
      ai.handlers.add(
        status(
          404,
          body: '{"error":"model \\"x\\" not found, try pulling it first"}',
        ),
      );
      await expectLater(
        OllamaClient(ai.url, 'x').complete(const [AiMessage('user', 'x')]),
        throwsA(
          isA<AiFailure>().having(
            (f) => f.message,
            'message',
            contains('ollama pull'),
          ),
        ),
      );
    });
  });

  group('streaming', () {
    test('OpenAI-style pieces arrive in order with the key in the header '
        'and the service path kept', () async {
      ai.handlers.add(
        sse([
          'data: {"choices":[{"delta":{"content":"Hel"}}]}',
          'data: {"choices":[{"delta":{"content":"lo"}}]}',
          'data: [DONE]',
        ]),
      );
      final pieces = await OpenAiCompatibleClient(
        ai.url.replace(path: '/api/v1'),
        'gpt-6-luna',
        _key,
      ).stream(const [AiMessage('user', 'x')]).toList();
      expect(pieces, ['Hel', 'lo']);
      final sent = ai.requests.single;
      expect(sent.path, '/api/v1/chat/completions');
      expect(sent.headers['authorization'], 'Bearer $_key');
      expect(jsonDecode(sent.body)['stream'], isTrue);
    });

    test(
      'a failure before the first piece is retried; after it, never',
      () async {
        ai.handlers.addAll([
          status(503),
          sse(['data: {"choices":[{"delta":{"content":"ok"}}]}']),
        ]);
        final client = OpenAiCompatibleClient(ai.url, 'm', _key, retry: retry);
        expect(await client.stream(const [AiMessage('user', 'x')]).toList(), [
          'ok',
        ]);
        expect(ai.requests, hasLength(2));

        // Half a reply, then the connection is cut: no second request.
        final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        var connections = 0;
        raw.listen((socket) async {
          connections++;
          await socket.first; // the request
          socket.write(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: text/event-stream\r\n'
            'Content-Length: 5000\r\n\r\n'
            'data: {"choices":[{"delta":{"content":"half"}}]}\n\n',
          );
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          socket.destroy();
        });
        final cut = OpenAiCompatibleClient(
          Uri.parse('http://127.0.0.1:${raw.port}'),
          'm',
          _key,
          retry: retry,
        );
        final got = <String>[];
        Object? error;
        try {
          await for (final p in cut.stream(const [AiMessage('user', 'x')])) {
            got.add(p);
          }
        } catch (e) {
          error = e;
        }
        await raw.close();
        expect(got, ['half']);
        expect(
          error,
          isA<AiFailure>().having((f) => f.kind, 'kind', AiErrorKind.network),
        );
        expect(connections, 1);
      },
    );

    test('an error inside the stream is shown, keys redacted', () async {
      ai.handlers.add(sse(['data: {"error":{"message":"bad key $_key"}}']));
      final client = OpenAiCompatibleClient(
        ai.url,
        'm',
        _key,
        retry: AiRetry.none,
      );
      await expectLater(
        client.stream(const [AiMessage('user', 'x')]).toList(),
        throwsA(
          isA<AiFailure>().having(
            (f) => f.message,
            'message',
            allOf(contains('bad key'), isNot(contains(_key))),
          ),
        ),
      );
    });

    test('Gemini streams with the key in a header, not the address', () async {
      ai.handlers.add(
        sse([
          'data: {"candidates":[{"content":{"parts":[{"text":"A"}]}}]}',
          'data: {"candidates":[{"content":{"parts":[{"text":"B"}]}}]}',
        ]),
      );
      final pieces = await GeminiClient(
        ai.url,
        'gemini-2.5-flash',
        'AIzaTESTKEY-0123456789abcdefghij',
      ).stream(const [AiMessage('user', 'x')]).toList();
      expect(pieces, ['A', 'B']);
      final sent = ai.requests.single;
      expect(
        sent.path,
        '/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse',
      );
      expect(sent.path, isNot(contains('AIza')));
      expect(sent.headers['x-goog-api-key'], startsWith('AIza'));
    });
  });

  group('cancelling', () {
    test('Stop ends a whole (not streamed) request at once', () async {
      ai.handlers.add((r) async {
        await Future<void>.delayed(const Duration(seconds: 20));
      });
      final client = OllamaClient(ai.url, 'm');
      final watch = Stopwatch()..start();
      final done = client.complete(const [AiMessage('user', 'x')]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      client.cancel();
      await expectLater(done, throwsA(isA<AiCancelled>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('Stop also ends the wait before a retry', () async {
      ai.handlers.add(status(503));
      final client = OllamaClient(
        ai.url,
        'm',
        retry: const AiRetry(
          base: Duration(seconds: 30),
          maxWait: Duration(seconds: 30),
        ),
      );
      final watch = Stopwatch()..start();
      final done = client.stream(const [AiMessage('user', 'x')]).toList();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      client.cancel();
      await expectLater(done, throwsA(isA<AiCancelled>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(ai.requests, hasLength(1));
    });
  });

  group('connection test', () {
    test('Ollama: lists models, finds the model, gets an answer', () async {
      ai.handlers.addAll([
        json({
          'models': [
            {'name': 'llama3.2:latest'},
          ],
        }),
        json({
          'message': {'content': 'OK'},
        }),
      ]);
      final report = await testAiConnection(
        OllamaClient(ai.url, 'llama3.2'),
        'llama3.2',
      );
      expect(report.ok, isTrue, reason: report.steps.join('\n'));
      expect(ai.requests.map((r) => '${r.method} ${r.path}'), [
        'GET /api/tags',
        'POST /api/chat',
      ]);
      expect(report.steps.last, contains('OK'));
    });

    test('a model the service does not have is named, nothing sent', () async {
      ai.handlers.add(
        json({
          'data': [
            {'id': 'gpt-6-luna'},
            {'id': 'gpt-5.6-terra'},
          ],
        }),
      );
      final report = await testAiConnection(
        OpenAiCompatibleClient(ai.url, 'gpt-typo', _key),
        'gpt-typo',
      );
      expect(report.ok, isFalse);
      expect(report.failure?.kind, AiErrorKind.notFound);
      expect(report.steps.last, contains('gpt-6-luna'));
      expect(ai.requests, hasLength(1));
    });

    test('a refused key stops the test before any text is sent', () async {
      ai.handlers.add(status(401));
      final report = await testAiConnection(
        OpenAiCompatibleClient(ai.url, 'gpt-6-luna', _key, retry: retry),
        'gpt-6-luna',
      );
      expect(report.ok, isFalse);
      expect(report.failure?.kind, AiErrorKind.auth);
      expect(ai.requests.single.path, '/v1/models');
    });

    test('services without a model list are still tested', () async {
      ai.handlers.addAll([
        status(404),
        json({
          'choices': [
            {
              'message': {'content': 'OK'},
            },
          ],
        }),
      ]);
      final report = await testAiConnection(
        OpenAiCompatibleClient(ai.url, 'm', _key),
        'm',
      );
      expect(report.ok, isTrue, reason: report.steps.join('\n'));
    });

    test('Gemini lists only models that can write answers', () async {
      ai.handlers.add(
        json({
          'models': [
            {
              'name': 'models/gemini-2.5-flash',
              'supportedGenerationMethods': ['generateContent'],
            },
            {
              'name': 'models/gemini-embedding-2',
              'supportedGenerationMethods': ['embedContent'],
            },
          ],
        }),
      );
      final models = await GeminiClient(
        ai.url,
        'gemini-2.5-flash',
        'AIzaTESTKEY-0123456789abcdefghij',
      ).listModels();
      expect(models, ['gemini-2.5-flash']);
      expect(ai.requests.single.path, '/v1beta/models?pageSize=1000');
    });
  });

  group('privacy and settings', () {
    test('keys never reach the log', () async {
      AppLog.session.clear();
      ai.handlers.add(status(401));
      await OpenAiCompatibleClient(
        ai.url.replace(path: '/v1', query: 'key=$_key'),
        'm',
        _key,
      ).complete(const [AiMessage('user', 'x')]).catchError((_) => '');
      expect(AppLog.session.join('\n'), contains('auth (401)'));
      expect(AppLog.session.join('\n'), isNot(contains(_key)));
    });

    test('redactSecrets hides keys and tokens', () {
      final text = redactSecrets(
        'Bearer abc.def sk-proj-1234567890abc AIza0123456789abcdefghijKLMN '
        'https://x.test/?key=secret&x=1',
      );
      expect(text, isNot(contains('abc.def')));
      expect(text, isNot(contains('1234567890abc')));
      expect(text, isNot(contains('0123456789abcdefghij')));
      expect(text, isNot(contains('secret')));
      expect(text, contains('x=1'));
    });

    test('retired models are warned about, with the official replacement', () {
      expect(
        retiredModelWarning('gpt-4o-mini', today: DateTime.utc(2026, 10, 24)),
        allOf(
          contains('will shut down'),
          contains('2027-01-14'),
          contains('gpt-6-luna'),
        ),
      );
      expect(
        retiredModelWarning(
          'gemini-2.0-flash',
          today: DateTime.utc(2026, 10, 24),
        ),
        contains('shut down "gemini-2.0-flash" on 2026-06-01'),
      );
      expect(retiredModelWarning('gemini-2.5-flash'), isNull);
      expect(AiProvider.openAiCompatible.defaultModel, 'gpt-6-luna');
    });

    test('older shared settings still apply after the update', () {
      final s = _settings({
        'ai.provider': 'openAiCompatible',
        'ai.endpoint': 'https://openrouter.ai/api/v1',
        'ai.model': 'some/model',
      });
      expect(s.endpoint, 'https://openrouter.ai/api/v1');
      expect(s.model, 'some/model');
      expect(
        openAiUrl(Uri.parse(s.endpoint), 'chat/completions').path,
        '/api/v1/chat/completions',
      );
    });

    test(
      'new Gemini settings use a current model and preserve saved choice',
      () {
        final defaults = AiSettings(_MemorySettings({'ai.provider': 'gemini'}));
        expect(defaults.model, 'gemini-3.8-flash');

        final saved = AiSettings(
          _MemorySettings({
            'ai.provider': 'gemini',
            'ai.model.gemini': 'gemini-2.5-flash',
          }),
        );
        expect(saved.model, 'gemini-2.5-flash');
      },
    );
  });
}

AiSettings _settings(Map<String, Object?> values) =>
    AiSettings(_MemorySettings(values));

class _MemorySettings extends Fake implements SettingsRepository {
  _MemorySettings(this.values);
  final Map<String, Object?> values;

  @override
  T? get<T>(String key) => values[key] is T ? values[key] as T : null;

  @override
  Future<void> set(String key, Object? value) async => values[key] = value;
}
