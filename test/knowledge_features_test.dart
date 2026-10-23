// Tests for implementation phases 4/5–6/8: PDF text, Archive folders and
// link repair, calendar files, mindmap branch → tasks, the private vault,
// read-only share links on the hub, templates, review, graph layout and
// thought experiments.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/knowledge_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/ics.dart';
import 'package:flutter_application_1/features/canvas/branch_conversion.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/graph/relationship_graph.dart';
import 'package:flutter_application_1/features/links/archive_library.dart';
import 'package:flutter_application_1/features/review/review_center.dart';
import 'package:flutter_application_1/features/search/pdf_text.dart';
import 'package:flutter_application_1/features/search/text_index.dart';
import 'package:flutter_application_1/features/templates/templates.dart';
import 'package:flutter_application_1/features/vault/vault_crypto.dart';
import 'package:flutter_application_1/features/vault/vault_service.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal one-page PDF whose content stream shows [text].
Uint8List tinyPdf(String content, {bool flate = false}) {
  final data = flate
      ? ZLibEncoder().convert(latin1.encode(content))
      : latin1.encode(content);
  final b = BytesBuilder()
    ..add(latin1.encode('%PDF-1.4\n1 0 obj\n<< /Length ${data.length}'))
    ..add(latin1.encode(flate ? ' /Filter /FlateDecode >>\n' : ' >>\n'))
    ..add(latin1.encode('stream\n'))
    ..add(data)
    ..add(latin1.encode('\nendstream\nendobj\n%%EOF\n'));
  return b.toBytes();
}

Asset link(String id, String url, {DateTime? at}) => Asset(
  id: id,
  kind: AssetKind.link,
  url: url,
  createdAt: at ?? DateTime(2026, 1, 1),
  updatedAt: at ?? DateTime(2026, 1, 1),
);

void main() {
  late Directory dir;
  late Workspace ws;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_knowledge_');
    ws = Workspace(dir);
    await ws.load();
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('PDF text', () {
    test('reads Tj and TJ text, plain and Flate-compressed', () {
      const content =
          'BT /F1 12 Tf 72 712 Td (Photosynthesis basics) Tj ET\n'
          'BT 72 690 Td [(Chloro) -20 (phyll) -400 (absorbs)] TJ ET';
      for (final flate in [false, true]) {
        final text = pdfText(tinyPdf(content, flate: flate));
        expect(text, contains('Photosynthesis basics'));
        expect(text, contains('Chlorophyll absorbs'));
      }
    });

    test('not a PDF, or no text, gives nothing (never throws)', () {
      expect(pdfText(Uint8List.fromList([1, 2, 3])), '');
      expect(pdfText(tinyPdf('0 0 m 10 10 l S')), '');
    });

    test('a compressed stream that unpacks to too much is skipped', () {
      final bomb = 'BT (x) Tj ET ${' ' * (40 * 1024 * 1024)}';
      expect(pdfText(tinyPdf(bomb, flate: true)), '');
    });

    test('excerpts show the first match in context', () {
      final e = excerpt('${'a ' * 100}needle here${' b' * 100}', ['needle']);
      expect(e, contains('needle here'));
      expect(e.length, lessThan(160));
      expect(matchesAll(['red', 'fox'], ['the red', 'quick fox']), isTrue);
      expect(matchesAll(['red', 'cat'], ['the red', 'quick fox']), isFalse);
    });
  });

  group('Archive folders and link check', () {
    test('folders nest, cannot go inside themselves, and delete moves up', () {
      final a = ws.createArchiveFolder('Study');
      final b = ws.createArchiveFolder('Biology', parentId: a.id);
      ws.assets.put(link('x', 'https://example.com'));
      ws.moveAssetToFolder('x', b.id);
      expect(ws.archiveFolderLabel(b.id), 'Study / Biology');
      expect(ws.moveArchiveFolder(a.id, b.id), isFalse); // a cycle
      expect(ws.archiveFolders[a.id]!.parentId, isNull);
      ws.deleteArchiveFolder(b.id);
      expect(ws.assets['x']!.folderId, a.id); // moved up, not deleted
      expect(ws.archiveFolders[b.id], isNull);
    });

    test('folderId is written only when set (older versions unaffected)', () {
      expect(
        link('x', 'https://e.com').toJson().containsKey('folderId'),
        false,
      );
      final moved = link('x', 'https://e.com').copyWith(folderId: () => 'f');
      expect(Asset.fromJson(moved.toJson()).folderId, 'f');
    });

    test('duplicates merge into the oldest; broken references are removed;'
        ' both undo', () async {
      ws.assets.put(link('old', 'https://www.Example.com/a/?utm_source=x'));
      ws.assets.put(
        link(
          'new',
          'https://example.com/a',
          at: DateTime(2026, 2, 1),
        ).copyWith(linkTags: ['red']),
      );
      final n = ws.createNote(title: 'N', assetIds: ['new', 'gone']);
      final refs = {
        'new': {ResourceRef('note', n.id, 'N')},
        'gone': {ResourceRef('note', n.id, 'N')},
      };
      final report = checkLinks(ws, refs);
      expect(report.broken.keys, ['gone']);
      expect(report.duplicates.single.map((a) => a.id), ['old', 'new']);

      final (undo, kept) = mergeDuplicates(ws, report.duplicates.single, refs);
      expect(kept, isEmpty);
      expect(ws.assets['new'], isNull);
      expect(ws.assets['old']!.linkTags, ['red']);
      expect(ws.notes[n.id]!.assetIds, ['old', 'gone']);
      undo.apply(ws);
      expect(ws.assets['new'], isNotNull);
      expect(ws.notes[n.id]!.assetIds, ['new', 'gone']);

      final (undo2, canvases) = removeBrokenReferences(ws, report);
      expect(canvases, 0);
      expect(ws.notes[n.id]!.assetIds, ['new']);
      undo2.apply(ws);
      expect(ws.notes[n.id]!.assetIds, ['new', 'gone']);
    });

    test('a duplicate still shown on a mindmap is kept', () {
      ws.assets.put(link('a', 'https://e.com/x'));
      ws.assets.put(link('b', 'https://e.com/x', at: DateTime(2026, 3)));
      final refs = {
        'b': {const ResourceRef('canvas', 'c1', 'Map')},
      };
      final (_, kept) = mergeDuplicates(
        ws,
        checkLinks(ws, refs).duplicates.single,
        refs,
      );
      expect(kept.single.id, 'b');
      expect(ws.assets['b'], isNotNull);
    });
  });

  group('calendar files', () {
    test('export has the entry days and due tasks; import is idempotent', () {
      final now = DateTime(2026, 10, 1);
      ws.entries.put(
        CalendarEntry(
          id: 'e1',
          category: CalendarCategory.events,
          name: 'Dentist, check-up',
          createdAt: now,
          updatedAt: now,
          dates: const {'2026-10-23'},
          startMinutes: 600,
        ),
      );
      ws.createTask('Hand in essay', dueDate: DateTime(2026, 10, 24));
      final ics = calendarIcs(ws, now: now);
      expect(ics, contains('BEGIN:VCALENDAR'));
      expect(ics, contains(r'SUMMARY:Dentist\, check-up'));
      expect(ics, contains('DTSTART:20261023T100000'));
      expect(ics, contains('DTSTART;VALUE=DATE:20261024'));

      final other = Workspace(Directory('${dir.path}/other'));
      expect(importIcs(other, ics), 2);
      expect(importIcs(other, ics), 0); // nothing new the second time
      expect(
        other.dayRecord(DateTime(2026, 10, 23)).text,
        '• 10:00 Dentist, check-up',
      );
      expect(other.entries.all, isEmpty); // never breaks the 5-active rule
    });
  });

  group('mindmap branch → tasks', () {
    CanvasController controller() => CanvasController(
      document: CanvasDocument(
        id: 'c1',
        title: 'Plan',
        updatedAt: DateTime(2026),
        items: const [
          TextItem(
            id: 'r',
            position: Offset.zero,
            width: 100,
            minHeight: 20,
            text: 'Thesis',
          ),
          TextItem(
            id: 'a',
            position: Offset(0, 50),
            width: 100,
            minHeight: 20,
            text: 'Research',
          ),
          TextItem(
            id: 'b',
            position: Offset(0, 100),
            width: 100,
            minHeight: 20,
            text: 'Read papers',
          ),
          ConnectorItem(id: 'k1', fromId: 'r', toId: 'a'),
          ConnectorItem(id: 'k2', fromId: 'a', toId: 'b'),
          ConnectorItem(id: 'k3', fromId: 'b', toId: 'r'), // a loop
        ],
      ),
      onSave: (_) async {},
      saveDelay: const Duration(milliseconds: 10),
    );

    test('makes a project with nested tasks; again updates, never copies', () {
      final c = controller();
      addTearDown(c.dispose);
      final first = convertBranch(c, ws, 'r');
      expect(first.created, 3); // project + 2 tasks
      final project = ws.projects[first.projectId]!;
      expect(project.name, 'Thesis');
      final research = ws.tasks.all.singleWhere((t) => t.title == 'Research');
      final read = ws.tasks.all.singleWhere((t) => t.title == 'Read papers');
      expect(read.parentId, research.id);
      expect(research.projectId, project.id);

      final again = convertBranch(c, ws, 'r');
      expect(again.created, 0);
      expect(ws.tasks.all.length, 2);
      expect(branchProgress(c, ws, 'r'), (0, 2));
      ws.toggleTask(read.id);
      expect(branchProgress(c, ws, 'r'), (1, 2));
      expect(branchAsText(c, 'r'), '- Thesis\n  - Research\n    - Read papers');
    });
  });

  group('private vault', () {
    const fast = KdfParams(memoryKiB: 64, iterations: 1);

    test('create, lock, wrong password, unlock, recover; only ciphertext '
        'is stored', () async {
      final v = VaultService(
        meta: ws.vaultMeta,
        items: ws.vaultItems,
        kdf: fast,
      );
      addTearDown(v.dispose);
      await expectLater(
        v.create('short'),
        throwsA(isA<VaultCryptoException>()),
      );
      final code = await v.create('correct horse battery');
      v.save(title: 'Bank', text: 'TOPSECRET pin 1234');
      final stored = jsonEncode([
        for (final i in ws.vaultItems.all) i.toJson(),
        for (final m in ws.vaultMeta.all) m.toJson(),
      ]);
      expect(stored, isNot(contains('TOPSECRET')));
      expect(stored, isNot(contains('Bank')));

      v.lock();
      expect(v.entries(), isEmpty);
      await expectLater(
        v.unlock('wrong password!!'),
        throwsA(isA<VaultCryptoException>()),
      );
      await v.unlock('correct horse battery');
      expect(v.entries().single.text, 'TOPSECRET pin 1234');

      v.lock();
      await v.recover(code.toLowerCase(), 'a brand new password');
      expect(v.entries().single.title, 'Bank');
      v.lock();
      await v.unlock('a brand new password');
      expect(v.unlocked, isTrue);
    });

    test('a tampered or swapped item cannot be opened', () async {
      final key = randomBytes(32);
      final s = seal(key, Uint8List.fromList([1, 2, 3]), 'item:a');
      expect(open(key, s.nonce, s.data, 'item:a'), [1, 2, 3]);
      expect(
        () => open(key, s.nonce, s.data, 'item:b'),
        throwsA(isA<VaultCryptoException>()),
      );
      final bad = Uint8List.fromList(s.data)..[0] ^= 1;
      expect(
        () => open(key, s.nonce, bad, 'item:a'),
        throwsA(isA<VaultCryptoException>()),
      );
    });

    test('KDF settings from a record are bounded', () {
      expect(
        KdfParams.fromJson({'alg': 'argon2id', 'm': 1 << 30, 't': 2, 'p': 1}),
        isNull,
      );
      expect(KdfParams.fromJson(const KdfParams().toJson())?.memoryKiB, 19456);
    });
  });

  group('share links on the hub', () {
    test(
      'served read-only; revoked, expired and unknown links show nothing',
      () async {
        final hubDir = Directory('${dir.path}/hub')..createSync();
        final server = await HubServer.start(
          dir: hubDir,
          port: 0,
          dailyBackups: false,
        );
        addTearDown(server.stop);
        final token = await server.auth.register(
          server.auth.createPairingCode(),
          'aaaa',
          'PC',
        );
        final client = SyncClient(
          Uri.parse('http://127.0.0.1:${server.port}'),
          token: token,
        );
        addTearDown(client.close);
        final clock = SyncClock(deviceId: 'aaaa');
        final secret = base64Url.encode(List.filled(32, 7)).replaceAll('=', '');
        final id = sha256.convert(utf8.encode(secret)).toString();
        ShareLink share({bool revoked = false, DateTime? expires}) => ShareLink(
          id: id,
          kind: 'note',
          sourceId: 'n1',
          title: 'Notes <b>',
          body: 'Hello <script>alert(1)</script>',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          revoked: revoked,
          expiresAt: expires,
        );
        Future<(int, String, HttpHeaders)> fetch(String t) async {
          final http = HttpClient();
          try {
            final res = await (await http.getUrl(
              Uri.parse('http://127.0.0.1:${server.port}/s/$t'),
            )).close();
            return (res.statusCode, await utf8.decodeStream(res), res.headers);
          } finally {
            http.close();
          }
        }

        Future<void> put(ShareLink l) => client.push([
          SyncChange(
            collection: 'shares',
            id: id,
            rev: clock.now(),
            deleted: false,
            data: l.toJson(),
          ),
        ]);

        await put(share());
        final (status, html, headers) = await fetch(secret);
        expect(status, 200);
        expect(html, contains('Hello &lt;script&gt;'));
        expect(html, isNot(contains('<script>')));
        expect(headers.value('cache-control'), 'no-store');
        expect(
          headers.value('content-security-policy'),
          contains("default-src 'none'"),
        );

        expect((await fetch('${secret}x')).$1, 404);
        await put(share(expires: DateTime(2020)));
        expect((await fetch(secret)).$1, 404);
        await put(share(revoked: true));
        final (gone, body, _) = await fetch(secret);
        expect(gone, 404);
        expect(body, isNot(contains('Hello')));
      },
    );

    test('new record kinds are accepted by the hub and pushed last', () {
      for (final c in newerCollections) {
        expect(syncedCollections, contains(c));
      }
      expect(
        ws.syncCollections.keys,
        containsAll(newerCollections.difference({'clipboard'})),
      );
    });
  });

  group('templates, review, graph, thought experiments', () {
    test('a project template keeps steps and relative due dates', () {
      final p = Project(
        id: 'p',
        name: 'Exam prep',
        kind: ProjectKind.project,
        updatedAt: DateTime(2026),
      );
      ws.projects.put(p);
      final a = ws.createTask(
        'Revise',
        projectId: 'p',
        dueDate: DateTime(2026, 5, 1),
      );
      ws.createTask(
        'Chapter 1',
        projectId: 'p',
        parentId: a.id,
        dueDate: DateTime(2026, 5, 3),
      );
      final t = projectTemplate(ws, 'Exam', 'p');
      ws.templates.put(t);
      final reloaded = ws.templates[t.id]!;
      final newId = useProjectTemplate(
        ws,
        reloaded,
        name: 'Exam 2',
        start: DateTime(2026, 9, 1),
      );
      final made = ws.tasks.all.where((x) => x.projectId == newId).toList();
      final rev = made.singleWhere((x) => x.title == 'Revise');
      final ch = made.singleWhere((x) => x.title == 'Chapter 1');
      expect(rev.dueDate, DateTime(2026, 9, 1));
      expect(ch.dueDate, DateTime(2026, 9, 3));
      expect(ch.parentId, rev.id);

      final note = noteTemplate('Daily', 'Log {date}', 'Mood:');
      final id = useNoteTemplate(ws, note, now: DateTime(2026, 10, 23));
      expect(ws.notes[id]!.title, isNot(contains('{date}')));
    });

    test('review lists overdue and at-risk tasks with plain reasons', () {
      final now = DateTime(2026, 10, 23);
      ws.createTask('Late', dueDate: DateTime(2026, 10, 20));
      final dep = ws.createTask('Get data');
      final t = ws.createTask('Report', dueDate: DateTime(2026, 10, 24));
      ws.tasks.put(t.copyWith(dependsOn: [dep.id]));
      final r = ReviewData(ws, now: now);
      expect(r.overdue.single.title, 'Late');
      final risk = r.atRisk.singleWhere((a) => a.task.title == 'Report');
      expect(risk.reason, contains('Get data'));
    });

    test('graph layout is deterministic and keeps nodes apart', () {
      final a = forceLayout(5, const [(0, 1), (1, 2), (3, 4)], iterations: 50);
      final b = forceLayout(5, const [(0, 1), (1, 2), (3, 4)], iterations: 50);
      expect(a, b);
      for (var i = 0; i < 5; i++) {
        for (var j = i + 1; j < 5; j++) {
          expect((a[i] - a[j]).distance, greaterThan(1));
        }
      }
    });

    test('thought experiments round-trip; unsourced facts are flagged', () {
      final x = ThoughtExperiment(
        id: 'x',
        title: 'What if',
        updatedAt: DateTime(2026),
        claims: const [
          Claim(
            id: 'c1',
            text: 'Water boils at 100 °C',
            origin: ClaimOrigin.verified,
          ),
          Claim(id: 'c2', text: 'Prices rise', sourceIds: ['n1']),
        ],
        scenarios: const [
          Scenario(id: 's1', name: 'High', assumptionIds: ['c2']),
        ],
      );
      final back = ThoughtExperiment.fromJson(
        jsonDecode(jsonEncode(x.toJson())),
      );
      expect(back.claims.length, 2);
      expect(back.scenarios.single.assumptionIds, ['c2']);
      expect(back.unsupportedFacts.single.id, 'c1');
      expect(back.toText(), contains('relies on: Prices rise'));
    });
  });
}
