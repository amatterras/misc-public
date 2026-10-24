// Tests for prompts P1–P4: page instances, drag rules and stroke
// connectors, Gemini, calendar sync (with a fake provider and a local OAuth
// server), OCR plumbing, and the hosted (multi-account) hub.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/page_windows.dart';
import 'package:flutter_application_1/data/models/ai_models.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/ai/ai_service.dart';
import 'package:flutter_application_1/features/calendar/external/external_calendar.dart';
import 'package:flutter_application_1/features/calendar/external/oauth.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/links/archive_library.dart';
import 'package:flutter_application_1/features/search/pdf_ocr.dart';
import 'package:flutter_application_1/features/search/text_index.dart';
import 'package:flutter_application_1/features/transfer/transfer.dart';
import 'package:flutter_application_1/hub/hosted_hub.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

StrokeItem stroke(String id, List<Offset> pts) => StrokeItem(
  id: id,
  points: [for (final p in pts) StrokePoint(p.dx, p.dy)],
  color: const Color(0xFFFFFFFF),
  strokeWidth: 3,
);

CanvasController canvas(List<CanvasItem> items) => CanvasController(
  document: CanvasDocument(
    id: 'c',
    title: 'Map',
    items: items,
    updatedAt: DateTime(2026),
  ),
  onSave: (_) async {},
);

/// A provider that keeps events in memory.
class FakeProvider extends CalendarProvider {
  FakeProvider() : super(({bool force = false}) async => 'token');
  final Map<String, RemoteEvent> remote = {};
  final List<String> writes = [];
  var _n = 0;

  @override
  String get name => 'google';
  @override
  String get label => 'Fake';

  @override
  Future<List<RemoteCalendar>> calendars() async => [
    const RemoteCalendar('cal', 'Main', primary: true),
  ];

  @override
  Future<DeltaPage> changes(String calendarId, String? cursor) async =>
      DeltaPage(remote.values.toList(), 'cursor', full: true);

  @override
  Future<String> create(String calendarId, EventDraft d) async {
    final id = 'r${_n++}';
    writes.add('create ${d.title}');
    remote[id] = RemoteEvent(
      remoteId: id,
      title: d.title,
      start: d.start,
      end: d.end,
      allDay: d.allDay,
    );
    return id;
  }

  @override
  Future<void> update(String calendarId, String remoteId, EventDraft d) async {
    writes.add('update ${d.title}');
    remote[remoteId] = RemoteEvent(
      remoteId: remoteId,
      title: d.title,
      start: d.start,
      end: d.end,
    );
  }

  @override
  Future<void> delete(String calendarId, String remoteId) async {
    writes.add('delete $remoteId');
    remote.remove(remoteId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to local test servers

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_p_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> app() async {
    final ws = Workspace(dir);
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

  group('P1 page instances', () {
    test('new pages are new things, each with its own instance', () async {
      final s = await app();
      final a = await s.newPage(AppPage.notes);
      final b = await s.newPage(AppPage.notes);
      expect(a.id, isNot(b.id));
      expect(a.refId, isNot(b.refId));
      expect(s.workspace.notes[a.refId], isNotNull);
      final m = await s.newPage(AppPage.canvas, mode: PageMode.floating);
      expect(s.canvasList.any((c) => c.id == m.refId), isTrue);
      expect(s.floating.isOpen(m.id), isTrue);
      final c1 = await s.newPage(AppPage.calendar);
      final c2 = await s.newPage(AppPage.calendar);
      expect(c1.refId, isNot(c2.refId));
      expect(c1.refId, startsWith('view-'));
      final safari1 = await s.newPage(AppPage.browser);
      final safari2 = await s.newPage(AppPage.browser);
      expect(s.browserFor(safari1), isNot(same(s.browserFor(safari2))));
      await s.flush();
      s.dispose();
    });

    test('a new AI chat window is rebound to its conversation', () async {
      final s = await app();
      final p = await s.newPage(AppPage.ai);
      expect(p.refId, startsWith('new-'));
      final session = s.aiSessionFor(p);
      s.workspace.aiConversations.put(
        AiConversation(
          id: 'conv1',
          title: 'Chat',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
      session.openConversation('conv1');
      expect(s.windows.byId(p.id)!.refId, 'conv1');
      await s.flush();
      s.dispose();
    });

    test(
      'close asks a guard and never deletes the content; names persist',
      () async {
        final s = await app();
        final p = await s.newPage(AppPage.notes);
        final noteId = p.refId!;
        s.windows.setCloseGuard(p.id, () async => false);
        await s.windows.close(p.id);
        expect(s.windows.byId(p.id), isNotNull, reason: 'guard refused');
        s.windows.setCloseGuard(p.id, null);
        s.windows.rename(p.id, 'My page');
        expect(s.windows.byId(p.id)!.named, isTrue);
        await s.windows.close(p.id);
        expect(s.windows.byId(p.id), isNull);
        expect(s.workspace.notes[noteId], isNotNull, reason: 'content kept');
        await s.flush();
        s.dispose();
      },
    );
  });

  group('P2 drag rules', () {
    test(
      'URL to an Archive folder, task steps (no loops), project moves',
      () async {
        final s = await app();
        final ws = s.workspace;
        final folder = ws.createArchiveFolder('Reading');
        final choices = s.transferChoices(
          const UrlTransfer('https://example.com/a', title: 'A'),
          ArchivePlace(folder.id),
        );
        expect(choices.single.op, TransferOp.copy);
        final r = await s.performTransfer(
          const UrlTransfer('https://example.com/a', title: 'A'),
          ArchivePlace(folder.id),
          TransferOp.copy,
        );
        final asset = ws.assets.all.single;
        expect(asset.folderId, folder.id);
        await r.undo!();
        expect(ws.assets.all, isEmpty);

        final parent = ws.createTask('Parent');
        final child = ws.createTask('Child');
        await s.performTransfer(
          TaskTransfer(child.id, child.title),
          TaskPlace(parent.id),
          TransferOp.move,
        );
        expect(ws.tasks[child.id]!.parentId, parent.id);
        // The parent cannot become a step of its own step.
        expect(
          s.transferChoices(
            TaskTransfer(parent.id, parent.title),
            TaskPlace(child.id),
          ),
          isEmpty,
        );
        final project = Project(
          id: 'p1',
          name: 'Thesis',
          kind: ProjectKind.project,
          updatedAt: DateTime(2026),
        );
        ws.projects.put(project);
        final moved = await s.performTransfer(
          TaskTransfer(parent.id, parent.title),
          const TasksPlace(projectId: 'p1'),
          TransferOp.move,
        );
        expect(ws.tasks[parent.id]!.projectId, 'p1');
        expect(ws.tasks[child.id]!.projectId, 'p1', reason: 'steps go along');
        await moved.undo!();
        expect(ws.tasks[child.id]!.projectId, isNull);
        await s.flush();
        s.dispose();
      },
    );

    test(
      'a note moves between folders and back with undo; projects shift',
      () async {
        final s = await app();
        final ws = s.workspace;
        final f = ws.createFolder('School');
        final n = ws.createNote(title: 'N');
        final r = await s.performTransfer(
          NoteTransfer(n.id, 'N'),
          NoteFolderPlace(f.id),
          TransferOp.move,
        );
        expect(ws.notes[n.id]!.folderId, f.id);
        await r.undo!();
        expect(ws.notes[n.id]!.folderId, isNull);
        ws.projects.put(
          Project(
            id: 'p',
            name: 'P',
            kind: ProjectKind.project,
            updatedAt: DateTime(2026),
          ),
        );
        ws.createTask('a', projectId: 'p', dueDate: DateTime(2026, 5, 1));
        ws.createTask('b', projectId: 'p', dueDate: DateTime(2026, 5, 4));
        await s.performTransfer(
          const ProjectTransfer('p', 'P'),
          DayPlace(DateTime(2026, 6, 1)),
          TransferOp.move,
        );
        final dues = ws.tasks.all.map((t) => t.dueDate).toSet();
        expect(dues, {DateTime(2026, 6, 1), DateTime(2026, 6, 4)});
        await s.flush();
        s.dispose();
      },
    );
  });

  group('P2 connectors on drawn lines', () {
    test(
      'connect drag from a line end to another line snaps and saves anchors',
      () {
        final c = canvas([
          stroke('s1', const [Offset(0, 0), Offset(100, 0), Offset(200, 0)]),
          stroke('s2', const [
            Offset(300, 200),
            Offset(350, 250),
            Offset(400, 300),
          ]),
        ]);
        c.tool = CanvasTool.connect;
        c.pointerDown(const Offset(198, 2)); // near s1's last point
        c.pointerMove(const Offset(320, 210));
        c.pointerMove(const Offset(302, 203)); // near s2's first point
        c.pointerUp();
        final line = c.items.whereType<ConnectorItem>().single;
        expect(line.fromT, 1.0);
        expect(line.toT, 0.0);
        expect(c.connectorEnds(line), (
          const Offset(200, 0),
          const Offset(300, 200),
        ));
        // Saved and read back with its anchors.
        final back = ConnectorItem.fromJson(line.toJson());
        expect((back.fromT, back.toT), (1.0, 0.0));
        // Erasing a line removes its connection in the same step.
        c.tool = CanvasTool.eraser;
        c.pointerDown(const Offset(350, 250));
        c.pointerMove(const Offset(352, 252));
        c.pointerUp();
        expect(c.itemById('s2'), isNull);
        expect(c.items.whereType<ConnectorItem>(), isEmpty);
        c.undo();
        expect(c.items.whereType<ConnectorItem>(), hasLength(1));
        c.dispose();
      },
    );

    test('an anchor follows the ink when the line moves', () {
      const line = ConnectorItem(
        id: 'k',
        fromId: 's1',
        toId: 's2',
        fromT: 0.5,
        toT: 1,
      );
      final moved = canvas([
        stroke('s1', const [Offset(10, 10), Offset(60, 10), Offset(110, 10)]),
        stroke('s2', const [Offset(500, 500), Offset(600, 600)]),
        line,
      ]);
      expect(moved.connectorEnds(line), (
        const Offset(60, 10),
        const Offset(600, 600),
      ));
      // Old connectors (no anchors) still use the box edges.
      expect(
        jsonEncode(
          const ConnectorItem(id: 'x', fromId: 'a', toId: 'b').toJson(),
        ),
        isNot(contains('fromT')),
      );
      moved.dispose();
    });
  });

  group('P3 Gemini', () {
    test('request body and response parsing', () {
      final body = GeminiClient.body([
        const AiMessage('system', 'Be brief.'),
        const AiMessage('user', 'Hi'),
        AiMessage(
          'assistant',
          'Hello',
          images: [
            Uint8List.fromList([1]),
          ],
        ),
      ]);
      expect(body['systemInstruction'], {
        'parts': [
          {'text': 'Be brief.'},
        ],
      });
      final contents = body['contents'] as List;
      expect(contents.map((c) => (c as Map)['role']), ['user', 'model']);
      expect(jsonEncode(contents.last), contains('inlineData'));
      expect(
        GeminiClient.textOf({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Hel'},
                  {'text': 'lo'},
                ],
              },
            },
          ],
        }),
        'Hello',
      );
      expect(
        () => GeminiClient.textOf({
          'promptFeedback': {'blockReason': 'SAFETY'},
        }),
        throwsA(isA<AiFailure>()),
      );
      expect(
        aiFailureFor(400, body: 'API_KEY_INVALID').message,
        contains('refused the key'),
      );
    });

    test('each service keeps its own address and model', () async {
      final s = await app();
      await s.ai.setProvider(AiProvider.openAiCompatible);
      await s.ai.setModel('gpt-test');
      await s.ai.setProvider(AiProvider.gemini);
      expect(s.ai.model, 'gemini-2.5-flash');
      expect(s.ai.endpoint, 'https://generativelanguage.googleapis.com');
      await s.ai.setProvider(AiProvider.openAiCompatible);
      expect(s.ai.model, 'gpt-test');
      expect(
        await GeminiClient(
              Uri.parse(AiProvider.gemini.defaultEndpoint),
              'gemini-2.5-flash',
              '',
            )
            .complete(const [AiMessage('user', 'x')])
            .then((_) => 'sent', onError: (Object e) => '$e'),
        contains('No Gemini API key'),
      );
      await s.flush();
      s.dispose();
    });
  });

  group('P3 calendar sync', () {
    test('pull, export without loops or copies, update and delete', () async {
      final ws = Workspace(dir);
      await ws.load();
      final settings = SettingsRepository(ws.store);
      final fake = FakeProvider();
      final sync = ExternalCalendarSync(
        ws: ws,
        settings: settings,
        provider: 'google',
        oauth: () => GoogleCalendarProvider.config(clientId: 'x'),
        apiOverride: fake,
      );
      await sync.chooseCalendar(const RemoteCalendar('cal', 'Main'));
      fake.remote['g1'] = RemoteEvent(
        remoteId: 'g1',
        title: 'Dentist',
        start: DateTime.utc(2026, 10, 24, 8),
        end: DateTime.utc(2026, 10, 24, 9),
      );
      await sync.syncOnce();
      expect(ws.externalEvents.all.single.title, 'Dentist');
      expect(
        ws
            .itemsOn(DateTime.utc(2026, 10, 24, 8).toLocal())
            .whereType<ExternalOnDay>(),
        hasLength(1),
      );

      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day + 2);
      ws.entries.put(
        CalendarEntry(
          id: 'e1',
          category: CalendarCategory.events,
          name: 'Exam',
          createdAt: now,
          updatedAt: now,
          dates: {
            '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
          },
        ),
      );
      await sync.setExport(true);
      await sync.syncOnce();
      expect(fake.writes, ['create Exam']);
      expect(ws.calendarLinks.all, hasLength(1));
      // Its own export comes back from the provider: not imported again.
      await sync.syncOnce();
      expect(fake.writes, ['create Exam'], reason: 'unchanged: not resent');
      expect(ws.externalEvents.all.map((e) => e.title), ['Dentist']);

      ws.entries.put(ws.entries['e1']!.copyWith(name: 'Exam (moved)'));
      await sync.syncOnce();
      expect(fake.writes.last, 'update Exam (moved)');
      ws.entries.remove('e1');
      fake.remote.remove('g1'); // cancelled over there
      await sync.syncOnce();
      expect(fake.writes.last, startsWith('delete'));
      expect(ws.calendarLinks.all, isEmpty);
      expect(ws.externalEvents.all, isEmpty);
    });

    test('OAuth with PKCE through a loopback address', () async {
      final tokenServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => tokenServer.close(force: true));
      Map<String, String>? form;
      tokenServer.listen((r) async {
        form = Uri.splitQueryString(await utf8.decodeStream(r));
        r.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'access_token': 'A',
              'refresh_token': 'R',
              'expires_in': 3600,
            }),
          );
        await r.response.close();
      });
      String? challenge;
      final tokens = await signIn(
        OAuthConfig(
          authorizeUrl: Uri.parse('https://example.com/auth'),
          tokenUrl: Uri.parse('http://127.0.0.1:${tokenServer.port}/token'),
          clientId: 'client',
          scopes: const ['s'],
        ),
        openBrowser: (url) {
          final q = Uri.parse(url).queryParameters;
          challenge = q['code_challenge'];
          final back = Uri.parse(q['redirect_uri']!)
              .replace(queryParameters: {'code': 'C', 'state': q['state']!});
          HttpClient().getUrl(back).then((req) => req.close());
          return true;
        },
      );
      expect(tokens.accessToken, 'A');
      expect(tokens.refreshToken, 'R');
      expect(form!['code'], 'C');
      expect(form!['code_verifier'], isNotEmpty);
      expect(challenge, isNotEmpty);
      expect(OAuthTokens.fromJson(tokens.toJson())!.accessToken, 'A');
    });
  });

  group('P3 OCR plumbing', () {
    Uint8List pdfWithImage(String filter, List<int> data, int w, int h) {
      final b = BytesBuilder();
      void s(String x) => b.add(latin1.encode(x));
      s('%PDF-1.4\n');
      s('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
      s('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
      s(
        '3 0 obj\n<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im1 4 0 R >> >> >>\nendobj\n',
      );
      s(
        '4 0 obj\n<< /Type /XObject /Subtype /Image /Width $w /Height $h '
        '/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /$filter '
        '/Length ${data.length} >>\nstream\n',
      );
      b.add(data);
      s('\nendstream\nendobj\n%%EOF\n');
      return b.toBytes();
    }

    test('page images: Flate gray becomes a BMP, JPEG passes through', () {
      final pixels = List.filled(64 * 40, 200);
      final flate = pdfWithImage(
        'FlateDecode',
        ZLibEncoder().convert(pixels),
        64,
        40,
      );
      final img = pdfPageImages(flate).single;
      expect(img.page, 1);
      expect(img.extension, 'bmp');
      expect(img.bytes.sublist(0, 2), [0x42, 0x4D]);
      final jpeg = [0xFF, 0xD8, ...List.filled(100, 7), 0xFF, 0xD9];
      final dct = pdfWithImage('DCTDecode', jpeg, 64, 40);
      expect(pdfPageImages(dct).single.extension, 'jpg');
      expect(pdfPageImages(Uint8List.fromList([1, 2, 3])), isEmpty);
    });

    test(
      'scanned PDFs are read by the OCR callback, cached and paged',
      () async {
        final ws = Workspace(dir);
        await ws.load();
        final pdf = File('${dir.path}${Platform.pathSeparator}scan.pdf')
          ..writeAsBytesSync(latin1.encode('%PDF-1.4\n%%EOF\n'));
        final asset = await ws.documentAssetFromFile(pdf);
        var runs = 0;
        final cache = PdfTextCache(
          ws,
          ocr: (_) async {
            runs++;
            return ['first page', 'Mitochondria page'];
          },
        );
        await cache.indexAll();
        expect(cache[asset.id], contains('Mitochondria'));
        expect(cache.pageMatch(asset.id, ['mitochondria'])!.$1, 2);
        final again = PdfTextCache(
          ws,
          ocr: (_) async {
            runs++;
            return const [];
          },
        );
        await again.indexAll();
        expect(runs, 1, reason: 'the cached result is reused');
        expect(again[asset.id], contains('Mitochondria'));
      },
    );
  });

  group('P4 hosted hub', () {
    test(
      'accounts are isolated; invites are single use; admin/share off',
      () async {
        final hubDir = Directory('${dir.path}${Platform.pathSeparator}hosted');
        final hub = await HostedHub.start(
          dir: hubDir,
          host: '127.0.0.1',
          port: 0,
          dailyBackups: false,
        );
        addTearDown(hub.stop);
        final base = Uri.parse('http://127.0.0.1:${hub.port}');
        final invite1 = await HostedHub.createInvite(hubDir);
        final invite2 = await HostedHub.createInvite(hubDir);

        final a = SyncClient(base);
        addTearDown(a.close);
        await a.createAccount('a@example.com', 'correct horse 1', invite1);
        await expectLater(
          a.createAccount('x@example.com', 'correct horse 1', invite1),
          throwsA(isA<SyncFailure>()),
        );
        final tokenA = await a.signIn(
          'a@example.com',
          'correct horse 1',
          'dev1',
          'PC',
        );
        await expectLater(
          a.signIn('a@example.com', 'wrong password!', 'dev2', 'PC'),
          throwsA(isA<SyncFailure>()),
        );
        final clock = SyncClock(deviceId: 'dev1');
        await a.push([
          SyncChange(
            collection: 'notes',
            id: 'n1',
            rev: clock.now(),
            deleted: false,
            data: {'id': 'n1', 'title': 'Private A', 'body': 'only A'},
          ),
        ]);
        expect((await a.pull(0)).changes.single.data!['title'], 'Private A');

        final b = SyncClient(base);
        addTearDown(b.close);
        await b.createAccount('b@example.com', 'correct horse 2', invite2);
        await b.signIn('b@example.com', 'correct horse 2', 'dev9', 'iPad');
        expect(
          (await b.pull(0)).changes,
          isEmpty,
          reason: 'B sees nothing of A',
        );

        // A's device token with B's account id is refused.
        final forged = SyncClient(
          base,
          token: '${'0' * 32}.${tokenA.split('.').last}',
        );
        addTearDown(forged.close);
        await expectLater(forged.pull(0), throwsA(isA<SyncFailure>()));

        final http = HttpClient();
        addTearDown(http.close);
        for (final path in ['/v1/admin/status', '/s/${'x' * 30}']) {
          final res = await (await http.getUrl(base.resolve(path))).close();
          await res.drain<void>();
          expect(res.statusCode, 404, reason: path);
        }
      },
    );
  });
}
