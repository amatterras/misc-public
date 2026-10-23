// Roadmap Phase 4 (advanced): AI (off by default, explicit, previewed,
// approval before changes) against a fake local server, similar notes and
// search by meaning, imports, exports, dropped files and clipboard sharing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/ai/ai_service.dart';
import 'package:flutter_application_1/features/ai/ai_session.dart';
import 'package:flutter_application_1/features/ai/similarity.dart';
import 'package:flutter_application_1/features/capture/file_drop.dart';
import 'package:flutter_application_1/features/export/exports.dart';
import 'package:flutter_application_1/features/import/note_import.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for Ollama on 127.0.0.1: records requests, answers [reply].
class FakeModel {
  late HttpServer server;
  final requests = <Map<String, dynamic>>[];
  String reply = 'OK';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final body =
          jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, dynamic>;
      requests.add(body);
      r.response.headers.contentType = ContentType.json;
      if (r.uri.path == '/api/embed') {
        final input = body['input'] as List;
        r.response.write(
          jsonEncode({
            'embeddings': [
              for (final t in input)
                [
                  (t as String).toLowerCase().contains('plant') ? 1.0 : 0.0,
                  t.toLowerCase().contains('car') ? 1.0 : 0.0,
                  0.1,
                ],
            ],
          }),
        );
      } else {
        r.response.write(
          jsonEncode({
            'message': {'role': 'assistant', 'content': reply},
          }),
        );
      }
      await r.response.close();
    });
  }

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test framework fakes all HTTP (every answer is 400); these tests
  // talk to a real fake model on 127.0.0.1.
  HttpOverrides.global = null;
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_r4_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> app() async {
    final ws = Workspace(Directory('${dir.path}${Platform.pathSeparator}data'));
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await s.init();
    return s;
  }

  group('AI', () {
    test('off by default: nothing can be sent', () async {
      final s = await app();
      expect(s.ai.enabled, isFalse);
      final ok = s.sendToAi(
        const AiContext(title: 'x', source: AiSource.notes, text: 'secret'),
      );
      expect(ok, isFalse);
      expect(s.aiSession.attached, isEmpty);
      await s.aiSession.send(AiTool.ask, 'hi');
      expect(s.aiSession.error, contains('off'));
      await s.flush();
      s.dispose();
    });

    test('only attached, allowed material is sent, cut to the limit', () async {
      final model = FakeModel();
      await model.start();
      final s = await app();
      await s.ai.setEnabled(true);
      await s.ai.setEndpoint(model.url.toString());
      await s.ai.setMaxContextChars(500);
      s.aiWindow = null; // no window in this test
      expect(
        s.sendToAi(
          AiContext(
            title: 'Biology',
            source: AiSource.notes,
            text: 'cells ' * 200,
            noteId: 'n1',
          ),
        ),
        isTrue,
      );
      await s.ai.setSources({AiSource.notes});
      expect(
        s.sendToAi(
          const AiContext(title: 'T', source: AiSource.tasks, text: 'task'),
        ),
        isFalse, // tasks not allowed
      );
      final preview = s.aiSession.preview(AiTool.explain, 'What is a cell?');
      expect(preview, contains('[1] Biology'));
      expect(preview.length, lessThan(800));

      await s.aiSession.send(AiTool.explain, 'What is a cell?');
      expect(s.aiSession.error, isNull);
      expect(model.requests, hasLength(1));
      final sent =
          (model.requests.single['messages'] as List).last['content'] as String;
      expect(sent, preview); // exactly what was shown
      expect(sent, isNot(contains('task')));
      expect(s.aiSession.turns.single.answer, 'OK');
      expect(s.aiSession.turns.single.sources, ['Biology']);
      await model.server.close(force: true);
      await s.flush();
      s.dispose();
    });

    test('proposed tasks and mindmaps need approval', () async {
      final model = FakeModel()
        ..reply = '- Read chapter 1\n- Make notes\n- Quiz';
      await model.start();
      final s = await app();
      await s.ai.setEnabled(true);
      await s.ai.setEndpoint(model.url.toString());
      final note = s.workspace.createNote(title: 'Exam');
      s.aiSession.attach(
        AiContext(
          title: 'Exam',
          source: AiSource.notes,
          text: 'x',
          noteId: note.id,
        ),
      );
      final before = s.workspace.tasks.length;
      await s.aiSession.send(AiTool.tasks, '');
      expect(s.aiSession.proposals.map((p) => p.label), [
        'Read chapter 1',
        'Make notes',
        'Quiz',
      ]);
      expect(s.workspace.tasks.length, before); // nothing yet
      s.aiSession.proposals[2].selected = false;
      expect(s.aiSession.applyTasks(s.workspace, noteId: note.id), 2);
      expect(s.workspace.tasks.length, before + 2);
      expect(s.workspace.tasksForNote(note.id), hasLength(2));

      model.reply = 'Cells\n- Parts\n  - Nucleus\n- Energy';
      await s.aiSession.send(AiTool.mindmap, '');
      expect(s.aiSession.mindmapCenter, 'Cells');
      final c = s.canvas!;
      final count = c.items.length;
      s.aiSession.discardProposals();
      expect(c.items.length, count);
      await s.aiSession.send(AiTool.mindmap, '');
      expect(s.aiSession.applyMindmap(c, Offset.zero), 3);
      expect(c.items.whereType<TextItem>().length, greaterThanOrEqualTo(4));
      expect(c.items.whereType<ConnectorItem>(), hasLength(3));
      await model.server.close(force: true);
      await s.flush();
      s.dispose();
    });

    test('a refused or unreachable service is reported, not crashed', () async {
      final s = await app();
      await s.ai.setEnabled(true);
      await s.ai.setEndpoint('http://127.0.0.1:1');
      s.aiSession.attach(
        const AiContext(title: 'x', source: AiSource.notes, text: 'y'),
      );
      await s.aiSession.send(AiTool.ask, 'hello');
      expect(s.aiSession.error, contains('Could not reach'));
      await s.ai.setProvider(AiProvider.openAiCompatible);
      await s.aiSession.send(AiTool.ask, 'hello');
      expect(s.aiSession.error, contains('No key'));
      await s.flush();
      s.dispose();
    });

    test('bullet parsing', () {
      expect(bulletLines('Intro\n- a\n  - b\n* c'), [
        (0, 'a'),
        (1, 'b'),
        (0, 'c'),
      ]);
      expect(mindmapRoot('# Topic\n- a'), 'Topic');
    });
  });

  group('similar notes and search by meaning', () {
    test('near-identical notes are found; different ones are not', () {
      Note n(String id, String body) => Note(
        id: id,
        title: id,
        body: body,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      final pairs = similarNotes([
        n('a', 'photosynthesis turns light water and carbon into sugar'),
        n(
          'b',
          'photosynthesis turns light water and carbon into sugar quickly',
        ),
        n('c', 'the french revolution started in seventeen eighty nine'),
      ]);
      expect(pairs, hasLength(1));
      expect({pairs.single.$1.id, pairs.single.$2.id}, {'a', 'b'});
      expect(textSimilarity('', 'x'), 0);
    });

    test('search by meaning runs only with the local model', () async {
      final model = FakeModel();
      await model.start();
      final s = await app();
      s.workspace.createNote(title: 'Garden', body: 'plant care');
      s.workspace.createNote(title: 'Engine', body: 'car repair');
      expect(s.canSearchByMeaning, isFalse);
      expect(await s.searchByMeaning('plant'), isEmpty);
      await s.ai.setEnabled(true);
      await s.ai.setEndpoint(model.url.toString());
      expect(s.canSearchByMeaning, isTrue);
      final found = await s.searchByMeaning('a plant');
      expect(found.first.$1.title, 'Garden');
      await s.ai.setProvider(AiProvider.openAiCompatible);
      expect(s.canSearchByMeaning, isFalse); // never sends all notes away
      await model.server.close(force: true);
      await s.flush();
      s.dispose();
    });
  });

  group('imports', () {
    Future<Directory> vault() async {
      final v = Directory('${dir.path}/My Vault');
      await Directory('${v.path}/School/Biology').create(recursive: true);
      await Directory('${v.path}/.obsidian').create();
      await File('${v.path}/.obsidian/app.json').writeAsString('{}');
      await File('${v.path}/School/Biology/Cells.md').writeAsString(
        '---\ntags: [biology, exam]\n---\n# Cells\nSee [[Mitochondria]] and #revision\n![[cell.png]]\n',
      );
      await File('${v.path}/School/Biology/Mitochondria.md')
          .writeAsString('Power of the cell.');
      await File('${v.path}/Ideas.txt').writeAsString('A plain text note');
      await File('${v.path}/table.csv').writeAsString('a,b');
      // A 1x1 PNG.
      await File('${v.path}/School/cell.png').writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        ),
      );
      return v;
    }

    test(
      'an Obsidian vault keeps folders, tags, links and images; twice = once',
      () async {
        final s = await app();
        final ws = s.workspace;
        final v = await vault();
        final report = await importNotes(ws, v, source: ImportSource.obsidian);
        expect(report.created, 3);
        expect(report.attachments, 1);
        expect(report.notImported.single, contains('table.csv'));
        final cells = ws.notes.all.firstWhere((n) => n.title == 'Cells');
        expect(cells.body, startsWith('See [[Mitochondria]]'));
        expect(cells.tags, containsAll(['biology', 'exam', 'revision']));
        expect(cells.assetIds, hasLength(1));
        final bio = ws.folders[cells.folderId]!;
        expect(bio.name, 'Biology');
        expect(ws.folders[bio.parentId]!.name, 'School');
        expect(
          ws.folders[ws.folders[bio.parentId]!.parentId]!.name,
          'My Vault',
        );
        expect(ws.notes.all.any((n) => n.title == 'app'), isFalse); // .obsidian

        final again = await importNotes(ws, v, source: ImportSource.obsidian);
        expect(again.created, 0);
        expect(again.skipped, 3);
        expect(ws.notes.all.where((n) => n.title == 'Cells'), hasLength(1));
        expect(
          await File('${v.path}/School/Biology/Cells.md').readAsString(),
          contains('tags: [biology'),
        );
        await s.flush();
        s.dispose();
      },
    );

    test('Notion names and links, Apple Notes HTML', () async {
      expect(
        cleanNotionName('Project plan 0123456789abcdef0123456789abcdef'),
        'Project plan',
      );
      expect(
        notionLinksToWiki(
          'See [Budget](Budget%200123456789abcdef0123456789abcdef.md)',
        ),
        'See [[Budget]]',
      );
      expect(
        htmlToText(
          '<div>Shopping</div><ul><li>Milk &amp; eggs</li></ul><br>Done',
        ),
        'Shopping\n- Milk & eggs\n\nDone',
      );
      final s = await app();
      final export = Directory('${dir.path}/Apple Notes');
      await export.create();
      await File('${export.path}/Groceries.html')
          .writeAsString('<h1>Groceries</h1><p>Milk</p>');
      final r = await importNotes(
        s.workspace,
        export,
        source: ImportSource.appleNotes,
      );
      expect(r.created, 1);
      expect(
        s.workspace.notes.all.firstWhere((n) => n.title == 'Groceries').body,
        contains('Milk'),
      );
      await s.flush();
      s.dispose();
    });
  });

  group('exports and dropped files', () {
    test('mindmap picture and web page, note Markdown and web page', () async {
      final s = await app();
      final out = Directory('${dir.path}/out');
      final c = s.canvas!;
      final png = await exportCanvasPicture(s, c, to: out);
      expect(png, isNotNull);
      expect((await png!.readAsBytes()).take(4), [0x89, 0x50, 0x4E, 0x47]);
      final html = await exportCanvasWebPage(s, c, to: out);
      final page = await html!.readAsString();
      expect(page, contains('data:image/png;base64,'));
      expect(page, contains('read-only'));

      final note = s.workspace.createNote(
        title: 'Trip <plan>',
        body: 'Pack & go',
      );
      final md = await exportNoteMarkdown(s, note, to: out);
      expect(await md.readAsString(), '# Trip <plan>\n\nPack & go');
      expect(md.path, isNot(contains('<')));
      final web = await (await exportNoteWebPage(
        s,
        note,
        to: out,
      )).readAsString();
      expect(web, contains('Pack &amp; go')); // escaped
      final second = await exportNoteMarkdown(s, note, to: out);
      expect(second.path, isNot(md.path)); // never overwrites
      expect(s.workspace.notes[note.id]!.body, 'Pack & go'); // unchanged
      await s.flush();
      s.dispose();
    });

    test('dropped files go to the Inbox; text files become notes', () async {
      final s = await app();
      final drop = Directory('${dir.path}/drop')..createSync();
      final txt = File('${drop.path}/Todo.md')
        ..writeAsStringSync('#home buy milk');
      final other = File('${drop.path}/x.exe')..writeAsStringSync('x');
      s.goTo(AppPage.notes);
      final summary = await s.handleDroppedFiles([txt.path, other.path]);
      expect(summary, contains('1 note(s)'));
      expect(summary, contains('x.exe'));
      expect(s.workspace.notes.all.firstWhere((n) => n.title == 'Todo').tags, [
        'home',
      ]);
      await s.handleDroppedFiles([txt.path]);
      expect(
        s.workspace.notes.all.where((n) => n.title == 'Todo'),
        hasLength(1),
      );
      await s.flush();
      s.dispose();
    });
  });

  group('clipboard between devices', () {
    test(
      'off by default; when on, new text is shared and remote text applied',
      () async {
        final s = await app();
        var system = 'first';
        final written = <String>[];
        s.readClipboardText = () async => system;
        s.writeClipboardText = (t) async => written.add(t);

        expect(s.shareClipboard, isFalse);
        expect(await s.checkClipboard(), isNull);
        expect(s.workspace.syncCollections.containsKey('clipboard'), isFalse);

        await s.setShareClipboard(true);
        expect(s.workspace.syncCollections.containsKey('clipboard'), isTrue);
        expect((await s.checkClipboard())?.text, 'first');
        expect(await s.checkClipboard(), isNull); // unchanged
        system = 'second';
        await s.checkClipboard();
        expect(s.workspace.clipboard.length, 2);

        // A clip arriving from another device lands on this clipboard.
        s.workspace.clipboard.put(
          ClipboardClip(
            id: 'remote',
            text: 'from the iPad',
            device: 'iPad',
            copiedAt: DateTime.now().add(const Duration(minutes: 1)),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(written, ['from the iPad']);
        system = 'from the iPad';
        expect(await s.checkClipboard(), isNull); // not sent back
        await s.setShareClipboard(false);
        await s.flush();
        s.dispose();
      },
    );
  });
}
