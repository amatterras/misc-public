// Phase 5 audit of the roadmap work: regression tests for what the audit
// found, plus two devices syncing the new data through a real local hub.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/canvas_ops.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/paper.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/import/note_import.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// A hub from before clipboard sharing: refuses clipboard records.
class OldHubClient extends SyncClient {
  OldHubClient(super.url, {super.token});

  @override
  Future<({List<PushResult> results, int lastSeq, String hubId})> push(
    List<SyncChange> changes,
  ) {
    if (changes.any((c) => c.collection == 'clipboard')) {
      throw const SyncFailure('bad_change', 'Unknown or missing collection.');
    }
    return super.push(changes);
  }
}

TextItem text(String id) => TextItem(
  id: id,
  position: Offset.zero,
  width: 200,
  minHeight: 40,
  text: id,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the local test hub
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('theapp_audit_'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> app([String name = 'data']) async {
    final ws = Workspace(
      Directory('${root.path}${Platform.pathSeparator}$name'),
    );
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

  group('canvas marks', () {
    test('a tag set just now is not overwritten by an incoming sync', () {
      final c = CanvasController(
        document: CanvasDocument(
          id: 'c',
          title: 'c',
          items: [text('a')],
          updatedAt: DateTime(2026),
          itemRevs: {'a': '0000000000000001-0000-other'},
        ),
        onSave: (_) async {},
      );
      c.select(['a']);
      c.tagSelection(3);
      // Before the debounced save, another device's version of the item
      // arrives (without a tag).
      final applied = c.applyRemote([
        SyncChange(
          collection: 'canvas_items',
          id: 'c/a',
          rev: '0000000000000009-0000-other',
          deleted: false,
          data: text('a').toJson(),
        ),
      ], (_, _) => false);
      expect(applied, isEmpty);
      expect(c.tagOf('a'), 3);
    });

    test('select all leaves reference overlays alone; locked text keeps its format', () {
      final c = CanvasController(
        document: CanvasDocument(
          id: 'c',
          title: 'c',
          items: [
            text('t'),
            const ImageItem(
              id: 'img',
              position: Offset(500, 0),
              width: 100,
              minHeight: 100,
              assetId: 'x',
            ),
          ],
          updatedAt: DateTime(2026),
        ),
        onSave: (_) async {},
      );
      c.select(['img']);
      c.makeSelectionReference();
      c.selectAll();
      expect(c.selection, {'t'});
      c.deleteSelection();
      expect(c.itemById('img'), isNotNull);

      c.undo();
      c.select(['t']);
      c.toggleLockSelection();
      c.setFontSize(32);
      expect((c.itemById('t') as TextItem).fontSize, 16);
    });

    test(
      'moving locked items to a note leaves them (no silent copy)',
      () async {
        final s = await app();
        final c = s.canvas!;
        c.addItems([text('free'), text('fixed')]);
        c.select(['fixed']);
        c.toggleLockSelection();
        final note = s.workspace.createNote(title: 'N');
        final n = await s.copyToNote(
          c,
          [c.itemById('free')!, c.itemById('fixed')!],
          note.id,
          move: true,
        );
        expect(n, 1);
        expect(c.itemById('free'), isNull);
        expect(c.itemById('fixed'), isNotNull);
        final pages = await s.canvases.load(notebookIdFor(note.id));
        expect(pages!.items, hasLength(1));
        await s.flush();
        s.dispose();
      },
    );
  });

  test('named mindmap versions are in backups', () async {
    final s = await app();
    await s.saveSnapshot(s.canvas!, 'v1');
    final backup = await s.workspace.backups.snapshot('audit');
    expect(await s.workspace.backups.verify(backup), isTrue);
    final copied = Directory(
      '${backup.path}${Platform.pathSeparator}canvas_snapshots',
    );
    final names = copied.listSync().map((e) => e.uri.pathSegments.last);
    expect(
      names.where(
        (n) => n.startsWith('${s.canvas!.id}~') && n.endsWith('.json'),
      ),
      hasLength(1),
    );
    await s.flush();
    s.dispose();
  });

  test(
    'search by meaning never runs against an address outside this PC',
    () async {
      final s = await app();
      await s.ai.setEnabled(true);
      expect(s.canSearchByMeaning, isTrue); // default address is this PC
      await s.ai.setEndpoint('http://192.168.1.20:11434');
      expect(s.ai.isLocal, isFalse);
      expect(s.canSearchByMeaning, isFalse);
      expect(await s.searchByMeaning('anything'), isEmpty);
      await s.flush();
      s.dispose();
    },
  );

  test('an import never pulls files from outside the chosen folder', () async {
    final s = await app();
    final secret = File('${root.path}/secret.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        ),
      );
    expect(secret.existsSync(), isTrue);
    final vault = Directory('${root.path}/vault')..createSync();
    File('${vault.path}/Note.md').writeAsStringSync('![[../secret.png]]');
    final report = await importNotes(
      s.workspace,
      vault,
      source: ImportSource.obsidian,
    );
    expect(report.created, 1);
    expect(report.attachments, 0);
    expect(report.notImported.single, contains('not found'));
    await s.flush();
    s.dispose();
  });

  group('two devices through a real hub', () {
    late HubServer hub;

    setUp(() async {
      hub = await HubServer.start(
        dir: Directory('${root.path}${Platform.pathSeparator}hub'),
        port: 0,
        dailyBackups: false,
      );
    });
    tearDown(() => hub.stop());

    Future<(Workspace, FileCanvasRepository, SyncEngine)> device(
      String name, {
      bool oldHub = false,
    }) async {
      final ws = Workspace(
        Directory('${root.path}${Platform.pathSeparator}$name'),
      );
      await ws.load();
      final token = await hub.auth.register(
        hub.auth.createPairingCode(),
        ws.device!.id,
        name,
      );
      final url = Uri.parse('http://127.0.0.1:${hub.port}');
      final client = oldHub
          ? OldHubClient(url, token: token)
          : SyncClient(url, token: token);
      final canvases = FileCanvasRepository(ws.store);
      return (
        ws,
        canvases,
        SyncEngine(workspace: ws, canvases: canvases, client: client),
      );
    }

    test('new task, note, link and canvas fields arrive intact', () async {
      final (pcWs, pcCanvases, pc) = await device('pc');
      final (padWs, padCanvases, pad) = await device('ipad');
      final t = pcWs.createTask('Lab report');
      pcWs.tasks.put(
        t.copyWith(
          labels: ['lab'],
          properties: {'Room': 'B12'},
          status: TaskStatus.doing,
          dueDate: () => DateTime(2026, 11, 2),
          recurrence: Recurrence.weekly,
        ),
      );
      pcWs.tasks.put(pcWs.tasks[t.id]!.movedOccurrence(DateTime(2026, 11, 4)));
      final note = pcWs.createNote(title: 'Cells');
      pcWs.notes.put(
        pcWs.notes[note.id]!.copyWith(
          paper: NotePaper.of(PaperTemplate.splitGridDots),
          projectIds: ['p1'],
        ),
      );
      final link = pcWs.linkAsset('https://youtu.be/x');
      pcWs.assets.put(link.copyWith(projectIds: ['p1']));
      // A canvas with a tagged, locked item.
      final c = CanvasController(
        document: CanvasDocument(
          id: 'map',
          title: 'Map',
          items: const [],
          updatedAt: DateTime(2026),
        ),
        onSave: pcCanvases.save,
        clock: pcWs.clock,
      );
      c.addItems([text('k')]);
      c.select(['k']);
      c.tagSelection(1);
      c.toggleLockSelection();
      await c.flush();
      c.dispose();
      await pcWs.flush();
      await pc.syncOnce();
      await pad.syncOnce();

      final got = padWs.tasks[t.id]!;
      expect(got.labels, ['lab']);
      expect(got.properties, {'Room': 'B12'});
      expect(got.status, TaskStatus.doing);
      expect(got.dueDate, DateTime(2026, 11, 4));
      expect(got.seriesDate, DateTime(2026, 11, 2));
      expect(
        padWs.notes[note.id]!.paper!.template,
        PaperTemplate.splitGridDots,
      );
      expect(padWs.notes[note.id]!.projectIds, ['p1']);
      expect(padWs.assets[link.id]!.projectIds, ['p1']);
      final map = await padCanvases.load('map');
      expect(map!.itemUnknownFields['k'], {'tag': 1, 'locked': true});
    });

    test(
      'clipboard text travels between devices only while sharing is on',
      () async {
        final (pcWs, _, pc) = await device('pc');
        final (padWs, _, pad) = await device('ipad');
        pcWs.clipboard.put(
          ClipboardClip(
            id: 'c1',
            text: 'hello',
            device: 'pc',
            copiedAt: DateTime.now(),
          ),
        );
        await pcWs.flush();
        await pc.syncOnce(); // off: not sent
        pcWs.shareClipboard = true;
        padWs.shareClipboard = true;
        await pad.syncOnce();
        expect(padWs.clipboard.length, 0);
        await pc.syncOnce(); // on: sent
        await pad.syncOnce();
        expect(padWs.clipboard['c1']?.text, 'hello');
      },
    );

    test(
      'a hub from before clipboard sharing does not stop the other sync',
      () async {
        final (pcWs, _, pc) = await device('pc', oldHub: true);
        final (padWs, _, pad) = await device('ipad');
        pcWs.shareClipboard = true;
        pcWs.clipboard.put(
          ClipboardClip(
            id: 'c1',
            text: 'secret-ish',
            device: 'pc',
            copiedAt: DateTime.now(),
          ),
        );
        pcWs.createNote(title: 'Still syncs');
        await pcWs.flush();
        final report = await pc.syncOnce();
        expect(report.problems.join(), contains('clipboard'));
        await pad.syncOnce();
        expect(padWs.notes.all.any((n) => n.title == 'Still syncs'), isTrue);
      },
    );
  });
}
