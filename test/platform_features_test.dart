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
import 'package:flutter_application_1/data/models/calendar_sync_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
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
  final Map<String, String> _createdForKey = {};
  var failAfterCreateOnce = false;
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
  String? createId(EventDraft draft) => draft.idempotencyKey == null
      ? null
      : googleCalendarEventId(draft.idempotencyKey!);

  @override
  Future<DeltaPage> changes(String calendarId, String? cursor) async =>
      DeltaPage(remote.values.toList(), 'cursor', full: true);

  @override
  Future<String> create(String calendarId, EventDraft d) async {
    final id = d.idempotencyKey == null
        ? 'r${_n++}'
        : _createdForKey.putIfAbsent(
            d.idempotencyKey!,
            () => createId(d) ?? 'r${_n++}',
          );
    writes.add('create ${d.title}');
    remote[id] = RemoteEvent(
      remoteId: id,
      title: d.title,
      description: d.description,
      start: d.start,
      end: d.end,
      allDay: d.allDay,
      updatedAt: DateTime.now(),
    );
    if (failAfterCreateOnce) {
      failAfterCreateOnce = false;
      throw const ProviderException('response lost after remote create');
    }
    return id;
  }

  @override
  Future<void> update(String calendarId, String remoteId, EventDraft d) async {
    writes.add('update ${d.title}');
    remote[remoteId] = RemoteEvent(
      remoteId: remoteId,
      title: d.title,
      description: d.description,
      start: d.start,
      end: d.end,
      allDay: d.allDay,
      updatedAt: DateTime.now(),
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
      expect(s.ai.model, 'gemini-3.8-flash');
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
    test(
      'Google initial and incremental sync use compatible parameters',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final queries = <Map<String, String>>[];
        server.listen((request) async {
          queries.add(request.uri.queryParameters);
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'items': [],
              'nextSyncToken': queries.length == 1 ? 'cursor-1' : 'cursor-2',
            }),
          );
          await request.response.close();
        });
        final provider = GoogleCalendarProvider(
          ({bool force = false}) async => 'token',
          baseUri: Uri.parse('http://127.0.0.1:${server.port}/calendar/v3/'),
        );

        final full = await provider.changes('cal', null);
        final incremental = await provider.changes('cal', full.cursor);

        expect(full.full, isTrue);
        expect(incremental.full, isFalse);
        expect(queries, hasLength(2));
        for (final query in queries) {
          expect(query['singleEvents'], 'true');
          expect(query['showDeleted'], 'true');
          expect(query['maxResults'], '250');
          expect(query, isNot(contains('timeMin')));
        }
        expect(queries.first, isNot(contains('syncToken')));
        expect(queries.last['syncToken'], 'cursor-1');
      },
    );

    test(
      'provider delta records are durable before cursor checkpoint',
      () async {
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
        fake.remote['provider-event'] = RemoteEvent(
          remoteId: 'provider-event',
          title: 'Durable import',
          start: DateTime.utc(2026, 10, 24, 8),
          end: DateTime.utc(2026, 10, 24, 9),
        );

        await sync.syncOnce();

        final importedFile = File(
          '${dir.path}${Platform.pathSeparator}data'
          '${Platform.pathSeparator}external_events.json',
        );
        final settingsFile = File(
          '${dir.path}${Platform.pathSeparator}settings'
          '${Platform.pathSeparator}app.json',
        );
        final imported = jsonDecode(await importedFile.readAsString());
        final savedSettings = jsonDecode(await settingsFile.readAsString());
        expect((imported['records'] as List).single['title'], 'Durable import');
        expect(savedSettings['calendar.google.cursor'], 'cursor');
        await ws.flush();
        ws.dispose();
      },
    );

    test(
      'Google create recovers a lost response using its stable event id',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final key = 'opaque-stable-calendar-key';
        final id = googleCalendarEventId(key);
        var postCount = 0;
        server.listen((request) async {
          final bodyText = await utf8.decoder.bind(request).join();
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer token',
          );
          if (request.method == 'POST') {
            final body = jsonDecode(bodyText) as Map<String, dynamic>;
            expect(body['id'], id);
            expect(
              ((body['extendedProperties'] as Map)['private']
                  as Map)['theappKey'],
              key,
            );
            postCount++;
            request.response.statusCode = postCount == 1 ? 503 : 409;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'error': {'code': request.response.statusCode},
              }),
            );
          } else {
            expect(request.method, 'GET');
            expect(request.uri.path, endsWith('/events/$id'));
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'id': id,
                'extendedProperties': {
                  'private': {'theappKey': key},
                },
              }),
            );
          }
          await request.response.close();
        });

        final provider = GoogleCalendarProvider(
          ({bool force = false}) async => 'token',
          baseUri: Uri.parse('http://127.0.0.1:${server.port}/calendar/v3/'),
        );
        final draft = EventDraft(
          title: 'Recovered event',
          day: DateTime(2026, 10, 24),
          idempotencyKey: key,
        );
        await expectLater(
          provider.create('cal', draft),
          throwsA(isA<ProviderException>()),
        );
        expect(await provider.create('cal', draft), id);
        expect(postCount, 2);
      },
    );

    test('Outlook create sends a stable Graph transactionId', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final bodies = <Map<String, dynamic>>[];
      server.listen((request) async {
        expect(request.method, 'POST');
        bodies.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'id': 'graph-event-id'}));
        await request.response.close();
      });
      final provider = MicrosoftCalendarProvider(
        ({bool force = false}) async => 'token',
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/v1.0/'),
      );
      final draft = EventDraft(
        title: 'Retry-safe Outlook event',
        day: DateTime(2026, 10, 24),
        idempotencyKey: 'stable-operation-key',
      );

      expect(provider.createId(draft), startsWith('pending-'));
      expect(await provider.create('calendar', draft), 'graph-event-id');
      expect(await provider.create('calendar', draft), 'graph-event-id');
      expect(bodies, hasLength(2));
      expect(bodies[0]['transactionId'], 'stable-operation-key');
      expect(bodies[1]['transactionId'], bodies[0]['transactionId']);
      expect(bodies[0]['subject'], 'Retry-safe Outlook event');
    });

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
          startDate: day,
          endDate: day,
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

    test('exports event date ranges as one complete provider event', () async {
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
      await sync.setExport(true);

      final firstDay = DateTime.now().add(const Duration(days: 4));
      final start = DateTime(firstDay.year, firstDay.month, firstDay.day);
      final last = start.add(const Duration(days: 2));
      ws.entries.put(
        CalendarEntry(
          id: 'multi-day',
          category: CalendarCategory.events,
          name: 'Conference',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          startDate: start,
          endDate: last,
        ),
      );

      await sync.syncOnce();

      expect(fake.remote, hasLength(1));
      final exported = fake.remote.values.single;
      expect(exported.title, 'Conference');
      expect(exported.start, start);
      expect(exported.end, last.add(const Duration(days: 1)));
      expect(ws.calendarLinks.all, hasLength(1));
      await ws.flush();
      ws.dispose();
    });

    test('provider edits update the linked local event without a loop', () async {
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
      await sync.setExport(true);
      final start = DateTime.now().add(const Duration(days: 4));
      final day = DateTime(start.year, start.month, start.day);
      ws.entries.put(
        CalendarEntry(
          id: 'linked-event',
          category: CalendarCategory.events,
          name: 'Original title',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          startDate: day,
          endDate: day,
          startMinutes: 9 * 60,
          durationMinutes: 30,
        ),
      );
      await sync.syncOnce();
      final remoteId = ws.calendarLinks.all.single.remoteId;
      final writesAfterCreate = fake.writes.length;

      fake.remote[remoteId] = RemoteEvent(
        remoteId: remoteId,
        title: 'Changed in Google',
        description: 'provider description',
        start: day.add(const Duration(days: 1, hours: 14)),
        end: day.add(const Duration(days: 1, hours: 15)),
        updatedAt: DateTime.now().add(const Duration(days: 1)),
      );
      final report = await sync.syncOnce();

      expect(ws.entries['linked-event']!.name, 'Changed in Google');
      expect(ws.entries['linked-event']!.description, 'provider description');
      expect(
        ws.entries['linked-event']!.startDate,
        day.add(const Duration(days: 1)),
      );
      expect(ws.entries['linked-event']!.startMinutes, 14 * 60);
      expect(ws.entries['linked-event']!.durationMinutes, 60);
      expect(ws.calendarLinks.all.single.remoteId, remoteId);
      expect(fake.writes, hasLength(writesAfterCreate));
      expect(report, contains('provider change(s) applied'));

      // Moving the linked local record reuses its provider ID and stable link.
      ws.entries.put(
        ws.entries['linked-event']!.copyWith(
          name: 'Changed in THEapp',
          startDate: () => day.add(const Duration(days: 2)),
          endDate: () => day.add(const Duration(days: 2)),
        ),
      );
      await sync.syncOnce();
      expect(fake.remote, hasLength(1));
      expect(fake.remote[remoteId]!.title, 'Changed in THEapp');
      expect(ws.calendarLinks.all.single.remoteId, remoteId);
      expect(
        ws.calendarLinks.all.single.id,
        CalendarLink.idFor(
          'google',
          'linked-event',
          dayKey(day.add(const Duration(days: 2))),
        ),
      );
      await ws.flush();
      ws.dispose();
    });

    test(
      'local wins a simultaneous edit when provider timestamp is older',
      () async {
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
        await sync.setExport(true);
        final day = DateTime.now().add(const Duration(days: 3));
        final entry = CalendarEntry(
          id: 'conflict-event',
          category: CalendarCategory.events,
          name: 'Baseline',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          startDate: day,
          endDate: day,
        );
        ws.entries.put(entry);
        await sync.syncOnce();
        final link = ws.calendarLinks.all.single;
        ws.entries.put(entry.copyWith(name: 'Local newer'));
        fake.remote[link.remoteId] = RemoteEvent(
          remoteId: link.remoteId,
          title: 'Remote older',
          start: day,
          end: day.add(const Duration(days: 1)),
          allDay: true,
          updatedAt: DateTime.now().subtract(const Duration(days: 1)),
        );

        final report = await sync.syncOnce();
        expect(ws.entries['conflict-event']!.name, 'Local newer');
        expect(fake.remote[link.remoteId]!.title, 'Local newer');
        expect(report, contains('simultaneous edit(s) kept locally'));
        await ws.flush();
        ws.dispose();
      },
    );

    test(
      'provider deletion archives the linked entry without losing content',
      () async {
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
        await sync.setExport(true);
        final day = DateTime.now().add(const Duration(days: 4));
        ws.entries.put(
          CalendarEntry(
            id: 'deleted-remotely',
            category: CalendarCategory.events,
            name: 'Keep my notes',
            description: 'Preserve this description',
            notes: 'Preserve this note',
            assetIds: const ['photo-id'],
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            startDate: day,
            endDate: day,
          ),
        );
        await sync.syncOnce();
        final link = ws.calendarLinks.all.single;
        fake.remote[link.remoteId] = RemoteEvent(
          remoteId: link.remoteId,
          removed: true,
        );

        await sync.syncOnce();

        final archived = ws.entries['deleted-remotely']!;
        expect(archived.archived, isTrue);
        expect(archived.description, 'Preserve this description');
        expect(archived.notes, 'Preserve this note');
        expect(archived.assetIds, ['photo-id']);
        expect(ws.calendarLinks.all, isEmpty);
        await ws.flush();
        ws.dispose();
      },
    );

    test(
      'a lost create response retries with the same id and no echo copy',
      () async {
        final ws = Workspace(dir);
        await ws.load();
        final settings = SettingsRepository(ws.store);
        final fake = FakeProvider()..failAfterCreateOnce = true;
        final sync = ExternalCalendarSync(
          ws: ws,
          settings: settings,
          provider: 'google',
          oauth: () => GoogleCalendarProvider.config(clientId: 'x'),
          apiOverride: fake,
        );
        await sync.chooseCalendar(const RemoteCalendar('cal', 'Main'));
        await sync.setExport(true);
        final day = DateTime.now().add(const Duration(days: 3));
        ws.entries.put(
          CalendarEntry(
            id: 'retry-event',
            category: CalendarCategory.events,
            name: 'Retry event',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            startDate: day,
            endDate: day,
          ),
        );
        await sync.syncOnce(); // remote create succeeded; response was lost
        expect(ws.calendarLinks.all, hasLength(1));
        expect(ws.calendarLinks.all.single.pendingCreate, isTrue);
        await ws.flush();
        ws.dispose();

        // A fresh workspace instance simulates the process restarting before
        // the provider acknowledged the create.
        final reopened = Workspace(dir);
        await reopened.load();
        final reopenedSettings = SettingsRepository(reopened.store);
        await reopenedSettings.load();
        final retrySync = ExternalCalendarSync(
          ws: reopened,
          settings: reopenedSettings,
          provider: 'google',
          oauth: () => GoogleCalendarProvider.config(clientId: 'x'),
          apiOverride: fake,
        );
        final retryReport = await retrySync.syncOnce();
        expect(fake.remote, hasLength(1));
        expect(reopened.calendarLinks.all, hasLength(1));
        expect(
          reopened.calendarLinks.all.single.pendingCreate,
          isFalse,
          reason: retryReport,
        );
        expect(reopened.externalEvents.all, isEmpty);
        await reopened.flush();
        reopened.dispose();
      },
    );

    test(
      'does not invent a timed event duration before provider export',
      () async {
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
        await sync.setExport(true);
        final day = DateTime.now().add(const Duration(days: 2));
        ws.entries.put(
          CalendarEntry(
            id: 'timed-no-duration',
            category: CalendarCategory.events,
            name: 'Appointment',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            startDate: day,
            endDate: day,
            startMinutes: 10 * 60,
          ),
        );

        final pending = await sync.syncOnce();
        expect(fake.remote, isEmpty);
        expect(pending, contains('need a duration'));

        ws.entries.put(
          ws.entries['timed-no-duration']!.copyWith(durationMinutes: () => 45),
        );
        await sync.syncOnce();
        expect(fake.remote, hasLength(1));
        expect(
          fake.remote.values.single.start,
          DateTime(day.year, day.month, day.day, 10),
        );
        expect(
          fake.remote.values.single.end,
          DateTime(day.year, day.month, day.day, 10, 45),
        );
        await ws.flush();
        ws.dispose();
      },
    );

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
