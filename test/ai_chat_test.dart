// The AI chat: Markdown formatting, conversation history limits, Try again
// and Regenerate, and the chat panel itself with a scripted fake AI (no
// network): empty state, streaming, Stop, errors with Settings, Copy,
// photos attached with disclosure, and conversations kept after a restart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/ai_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/ai/ai_chat_page.dart';
import 'package:flutter_application_1/features/ai/ai_markdown.dart';
import 'package:flutter_application_1/features/ai/ai_service.dart';
import 'package:flutter_application_1/features/ai/ai_session.dart';
import 'package:flutter_application_1/features/ai/ai_window.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers from a script: each request takes the next step (pieces to
/// stream, or a failure). [hold] keeps a reply open until released.
class ScriptedAi extends AiClient {
  ScriptedAi(this.script);
  final List<Object> script; // List<String> pieces, or AiFailure
  final requests = <List<AiMessage>>[];
  Completer<void>? hold;
  bool _cancelled = false;

  @override
  Future<String> complete(List<AiMessage> messages) => stream(messages).join();

  @override
  Stream<String> stream(List<AiMessage> messages) async* {
    requests.add(messages);
    _cancelled = false;
    final step = script.removeAt(0);
    if (step is AiFailure) throw step;
    for (final piece in step as List<String>) {
      if (_cancelled) throw const AiCancelled();
      yield piece;
      if (hold != null) await hold!.future;
      if (_cancelled) throw const AiCancelled();
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    hold?.complete();
    hold = null;
  }
}

void main() {
  group('Markdown', () {
    test('blocks: headings, lists, quotes, rules, code (open or closed)', () {
      final blocks = parseMarkdown(
        '# Title\nSome *text*\nmore\n\n- one\n  - two\n1. first\n> said\n'
        '---\n```dart\nvoid main() {}\n```\n```\nstill open',
      );
      expect(blocks.map((b) => b.runtimeType.toString()), [
        'MdHeading',
        'MdParagraph',
        'MdListItem',
        'MdListItem',
        'MdListItem',
        'MdQuote',
        'MdRule',
        'MdCode',
        'MdCode',
      ]);
      expect((blocks[1] as MdParagraph).text, 'Some *text*\nmore');
      expect((blocks[3] as MdListItem).level, 1);
      expect((blocks[4] as MdListItem).marker, '1.');
      expect((blocks[7] as MdCode).language, 'dart');
      expect((blocks[7] as MdCode).code, 'void main() {}');
      expect((blocks[8] as MdCode).code, 'still open');
    });

    test('inline: bold, italic, code, links; snake_case stays plain', () {
      final runs = inlineRuns(
        'a **b** *c* `d` [e](https://x.test) snake_case_name',
      );
      String styled(MdStyle s) =>
          runs.where((r) => r.$2.contains(s)).map((r) => r.$1).join('|');
      expect(styled(MdStyle.bold), 'b');
      expect(styled(MdStyle.italic), 'c');
      expect(styled(MdStyle.code), 'd');
      expect(styled(MdStyle.link), 'e (https://x.test)');
      expect(runs.last.$1, ' snake_case_name');
      expect(runs.last.$2, isEmpty);
    });
  });

  group('history', () {
    AiTurn t(
      String q,
      String a, [
      AiMessageStatus s = AiMessageStatus.complete,
    ]) => AiTurn(q, a, AiTool.ask, const [], status: s);

    test('at most 3 completed turns, failed ones left out', () {
      final h = AiSession.historyFor([
        t('1', 'a'),
        t('2', 'b'),
        t('3', 'c', AiMessageStatus.failed),
        t('4', 'd'),
        t('5', 'e'),
      ]);
      expect(h.map((m) => m.content), ['2', 'b', '4', 'd', '5', 'e']);
    });

    test('long history is cut from the oldest end', () {
      final h = AiSession.historyFor([
        t('old', 'x' * 9000),
        t('new', 'y' * 2000),
      ], maxChars: 10000);
      expect(h.map((m) => m.content.substring(0, 1)), ['n', 'y']);
    });
  });

  group('panel', () {
    late Directory dir;
    late AppState s;
    late ScriptedAi ai;

    setUp(() => dir = Directory.systemTemp.createTempSync('theapp_aichat_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<AppState> boot(
      WidgetTester tester,
      List<Object> script, {
      bool page = false,
    }) async {
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ws = Workspace(dir);
      s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      s.capture.fetchPreviews = false;
      await tester.runAsync(s.init);
      await tester.runAsync(() => s.ai.setEnabled(true));
      ai = ScriptedAi(script);
      s.aiClient = () async => ai;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: page ? AiChatPage(state: s) : AiPanel(state: s),
          ),
        ),
      );
      await tester.pump();
      return s;
    }

    Future<void> shutDown(WidgetTester tester) async {
      await tester.runAsync(s.flush);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4)); // toasts
      s.dispose();
    }

    /// Lets real time pass (disk writes) until [done], or fails.
    Future<void> until(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(done(), isTrue, reason: 'condition not reached in time');
      await tester.pump();
    }

    Future<void> ask(WidgetTester tester, String text) async {
      final before = ai.requests.length;
      await tester.enterText(find.byKey(const ValueKey('ai-question')), text);
      await tester.tap(find.byKey(const ValueKey('ai-send')));
      await until(
        tester,
        () =>
            ai.requests.length > before &&
            (s.aiSession.streaming.isNotEmpty || !s.aiSession.busy),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('empty state, then a formatted answer with Copy', (
      tester,
    ) async {
      await boot(tester, [
        ['## Plan\n', '- step **one**\n', '```\ncode here\n```'],
      ]);
      expect(find.byKey(const ValueKey('ai-empty')), findsOneWidget);
      await ask(tester, 'Make a plan');
      expect(find.byKey(const ValueKey('ai-empty')), findsNothing);
      expect(find.text('Make a plan'), findsOneWidget);
      expect(find.text('Plan'), findsOneWidget); // heading, not "## Plan"
      expect(find.text('code here'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-code-copy')), findsOneWidget);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await tester.tap(find.byKey(const ValueKey('ai-copy-0')));
      await tester.pump();
      expect(copied, startsWith('## Plan'));
      expect(find.byKey(const ValueKey('ai-regenerate')), findsOneWidget);
      await shutDown(tester);
    });

    testWidgets('streaming shows the question and the reply so far; Stop', (
      tester,
    ) async {
      await boot(tester, [
        ['Hello ', 'there', ' never shown'],
      ]);
      ai.hold = Completer<void>();
      await ask(tester, 'Hi?');
      expect(find.byKey(const ValueKey('ai-streaming')), findsOneWidget);
      expect(find.text('Hi?'), findsOneWidget);
      expect(find.textContaining('Hello'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-stop')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-stop')));
      await until(tester, () => !s.aiSession.busy);
      await tester.pump();
      expect(find.text('Stopped by you.'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-send')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-retry')), findsOneWidget);
      await shutDown(tester);
    });

    testWidgets('a failure offers Settings and Try again, which replaces it', (
      tester,
    ) async {
      await boot(tester, [
        const AiFailure(
          'Could not reach the AI at 127.0.0.1:11434. Is it running?',
          kind: AiErrorKind.unreachable,
        ),
        ['Back online.'],
      ]);
      await ask(tester, 'Are you there?');
      expect(find.byKey(const ValueKey('ai-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-error-settings')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-retry')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ai-retry')));
      await until(tester, () => !s.aiSession.busy && ai.requests.length == 2);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('ai-error')), findsNothing);
      expect(find.text('Back online.'), findsOneWidget);
      expect(s.aiSession.turns, hasLength(1));
      expect(ai.requests, hasLength(2));
      expect(ai.requests.last.last.content, contains('Are you there?'));
      // The saved conversation holds one question and one answer.
      final saved = s.workspace.aiConversations[s.aiSession.conversationId!]!;
      expect(saved.messages.map((m) => m.role), ['user', 'assistant']);
      expect(saved.messages.last.text, 'Back online.');
      await shutDown(tester);
    });

    testWidgets('Regenerate replaces the last answer, history excludes it', (
      tester,
    ) async {
      await boot(tester, [
        ['First answer'],
        ['Second answer'],
      ]);
      await ask(tester, 'Question');
      await tester.tap(find.byKey(const ValueKey('ai-regenerate')));
      await until(tester, () => !s.aiSession.busy && ai.requests.length == 2);
      await tester.pump();
      await tester.pump();
      expect(find.text('First answer'), findsNothing);
      expect(find.text('Second answer'), findsOneWidget);
      // The replaced answer is not sent back as history.
      expect(
        ai.requests.last.map((m) => m.content),
        isNot(contains('First answer')),
      );
      await shutDown(tester);
    });

    testWidgets('photos are listed and disclosed before sending', (
      tester,
    ) async {
      await boot(tester, [
        ['A cat.'],
      ]);
      final photo = File('${dir.path}${Platform.pathSeparator}cat.jpg')
        ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      s.capture.pickImageFiles = () => [photo.path];
      await tester.tap(find.byKey(const ValueKey('ai-add-photo')));
      await until(tester, () => s.aiSession.attached.isNotEmpty);
      await tester.pump();
      expect(find.text('cat.jpg'), findsOneWidget);
      expect(find.textContaining('and 1 picture(s)'), findsOneWidget);
      await ask(tester, 'What is this?');
      final sent = ai.requests.single.last;
      expect(sent.images.single, Uint8List.fromList(photo.readAsBytesSync()));
      expect(aiImageMime(sent.images.single), 'image/jpeg');
      expect(photo.existsSync(), isTrue); // the user's file is left alone

      // Photos switched off: the photo is marked and not sent.
      await tester.runAsync(
        () => s.ai.setSources({...AiSource.values}..remove(AiSource.photos)),
      );
      // (Settings changes show on the next rebuild, e.g. picking a tool.)
      await tester.tap(find.byKey(const ValueKey('ai-tool-summarize')));
      await tester.pump();
      expect(find.textContaining('not allowed: not sent'), findsOneWidget);
      expect(s.aiSession.allowedImages, isEmpty);
      await shutDown(tester);
    });

    testWidgets('a conversation is there again after a restart', (
      tester,
    ) async {
      await boot(tester, [
        ['Kept.'],
      ]);
      await ask(tester, 'Remember me');
      final id = s.aiSession.conversationId!;
      await shutDown(tester);

      await boot(tester, const []);
      final c = s.workspace.aiConversations[id];
      expect(c?.messages.map((m) => m.text), ['Remember me', 'Kept.']);
      s.aiSession.openConversation(id);
      await tester.pump();
      expect(find.text('Kept.'), findsOneWidget);
      await shutDown(tester);
    });

    testWidgets('conversations: rename, delete only after confirming', (
      tester,
    ) async {
      await boot(tester, const [], page: true);
      final now = DateTime.now();
      final store = s.workspace.aiConversations;
      store.put(
        AiConversation(
          id: 'c1',
          title: 'Biology',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ai-conversation-c1')));
      await tester.pump();
      expect(s.aiSession.conversationId, 'c1');

      Future<void> menu(String item) async {
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('ai-conversation-c1')),
            matching: find.byIcon(Icons.more_horiz),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(item).last);
        await tester.pumpAndSettle();
      }

      await menu('Rename');
      await tester.enterText(find.byType(TextField).last, 'Cell biology');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(store['c1']?.title, 'Cell biology');

      await menu('Delete');
      expect(find.text('Delete “Cell biology”?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store['c1'], isNotNull);

      await menu('Delete');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(store['c1'], isNull);
      expect(s.aiSession.conversationId, isNull);
      await shutDown(tester);
    });
  });
}
