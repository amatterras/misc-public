// A check against a REAL AI service. Skipped unless asked for, because it
// may cost money and needs a key. Run it with, for example:
//   THEAPP_AI_SMOKE=ollama flutter test test/ai_smoke_test.dart
//   THEAPP_AI_SMOKE=gemini THEAPP_AI_KEY=... flutter test test/ai_smoke_test.dart
// Optional: THEAPP_AI_MODEL, THEAPP_AI_ENDPOINT. The key is read from the
// environment only and never printed.
import 'dart:io';

import 'package:flutter_application_1/features/ai/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final env = Platform.environment;
  final provider = AiProvider.values.asNameMap()[env['THEAPP_AI_SMOKE']];

  test(
    'a real service answers the connection test and streams',
    () async {
      HttpOverrides.global = null;
      final p = provider!;
      final endpoint = Uri.parse(
        env['THEAPP_AI_ENDPOINT'] ?? p.defaultEndpoint,
      );
      final model = env['THEAPP_AI_MODEL'] ?? p.defaultModel;
      final key = env['THEAPP_AI_KEY'] ?? '';
      final client = switch (p) {
        AiProvider.ollama => OllamaClient(endpoint, model),
        AiProvider.openAiCompatible => OpenAiCompatibleClient(
          endpoint,
          model,
          key,
        ),
        AiProvider.gemini => GeminiClient(endpoint, model, key),
      };
      final report = await testAiConnection(client, model);
      // Steps never contain the key (only service answers and model names).
      printOnFailure(redactSecrets(report.steps.join('\n')));
      expect(report.ok, isTrue);
      final pieces = await client.stream(const [
        AiMessage('user', 'Count from 1 to 5, separated by spaces.'),
      ]).toList();
      expect(pieces.join(), contains('3'));
    },
    skip: provider == null
        ? 'Set THEAPP_AI_SMOKE=ollama|openAiCompatible|gemini to run'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
