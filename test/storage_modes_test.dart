// Storage modes (STORAGE_MODES.md): local only, PC hub, hosted service.
// Real hubs on 127.0.0.1 (HubServer for the PC hub, HostedHub for the
// hosted service) and real app state on temporary folders. These are
// same-PC tests: no Tailscale, no second physical device, no TLS (the
// hosted service runs without its Caddy proxy here).
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/app_log.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hosted_hub.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/storage_modes.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_application_1/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_keys.dart';

import 'support/pre_update_fixture.dart';

final sep = Platform.pathSeparator;

/// Fails the test if anything opens a network connection.
class _NoNetwork extends HttpOverrides {
  final opened = <String>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    opened.add('HttpClient');
    throw StateError('Network used in local-only mode');
  }
}

Future<Map<String, String>> liveHashes(Directory dir) async {
  final out = <String, String>{};
  for (final sub in ['data', 'canvases', 'attachments', 'settings']) {
    final d = Directory('${dir.path}$sep$sub');
    if (!d.existsSync()) continue;
    await for (final e in d.list(recursive: true)) {
      if (e is File) {
        out[e.path.substring(dir.path.length)] = sha256
            .convert(await e.readAsBytes())
            .toString();
      }
    }
  }
  return out;
}

/// Everything a hub holds for one account, latest version per key.
Future<Map<String, SyncChange>> hubContents(SyncClient client) async {
  final out = <String, SyncChange>{};
  var since = 0;
  while (true) {
    final page = await client.pull(since, limit: 500);
    for (final c in page.changes) {
      out[c.key] = c;
    }
    since = page.next;
    if (!page.hasMore) return out;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final states = <AppState>[];

  Future<AppState> appOn(Directory dir) async {
    final ws = Workspace(dir);
    await ws.load();
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await s.settings.load();
    await shareSyncKey(s); // all devices of a test share one workspace key
    // As at every start-up (AppState.init runs them before anything else).
    expect(await s.runMigrations(), isTrue);
    s.capture.fetchPreviews = false;
    states.add(s);
    return s;
  }

  setUp(() {
    HttpOverrides.global = null;
    root = Directory.systemTemp.createTempSync('theapp_modes_');
  });

  tearDown(() async {
    HostedProvider.allowLoopbackForTests = false;
    HttpOverrides.global = null;
    for (final s in states) {
      await s.shutdown();
      s.workspace.dispose();
    }
    states.clear();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('local only: no host needed, nothing leaves the device, data and '
      'attachments survive a restart', () async {
    final f = await buildPreUpdateWorkspace(Directory('${root.path}${sep}app'));
    final noNet = _NoNetwork();
    HttpOverrides.global = noNet;
    final s = await appOn(f.dir);
    await s.init();
    expect(s.dataProblem, isNull);
    expect(s.storageMode, StorageMode.local);
    expect(s.storageProvider.endpoint, isNull);
    final note = s.workspace.createNote(title: 'Offline thought');
    final photo = await s.workspace.imageAssetFromBytes(
      await fixturePng(),
      'png',
    );
    s.workspace.attachToNote(note.id, photo.id);
    await s.shutdown();
    s.workspace.dispose();
    states.remove(s);

    final again = await appOn(f.dir);
    await again.init();
    expect(again.workspace.notes[note.id]!.assetIds, [photo.id]);
    expect(
      again.workspace.attachments
          .fileFor(again.workspace.assets[photo.id]!.file!)
          .existsSync(),
      isTrue,
    );
    expect(again.workspace.notes[f.noteId], isNotNull);
    expect(noNet.opened, isEmpty, reason: 'no network in local-only mode');
  });

  test('hosted mode is off by default and never accepts plain HTTP', () async {
    final s = await appOn(Directory('${root.path}${sep}fresh'));
    expect(s.storageMode, StorageMode.local);
    expect(s.hubHosted, isFalse);
    expect(
      HostedProvider(Uri.parse('http://127.0.0.1:8080')).problem,
      isNotNull,
    );
    expect(
      HostedProvider(Uri.parse('https://sync.example.com')).problem,
      isNull,
    );
    expect(
      PcHubProvider(Uri.parse('https://sync.example.com')).problem,
      isNotNull,
      reason: 'a hosted address is not a PC hub',
    );
    expect(
      PcHubProvider(Uri.parse('http://100.64.12.34:47710')).problem,
      isNull,
    );
    expect(PcHubProvider(Uri.parse('http://8.8.8.8:47710')).problem, isNotNull);
  });

  group('PC hub', () {
    late HubServer hub;
    late int port;
    late PreUpdateFixture f;

    Future<HubServer> startHub() async {
      final h = await HubServer.start(
        dir: Directory('${root.path}${sep}hub'),
        port: port,
        dailyBackups: false,
      );
      port = h.port;
      return h;
    }

    setUp(() async {
      port = 0;
      hub = await startHub();
      f = await buildPreUpdateWorkspace(Directory('${root.path}${sep}app'));
    });
    tearDown(() => hub.stop());

    Uri hubUri() => Uri.parse('http://127.0.0.1:$port');

    SyncClient otherDevice(String id) {
      final c = SyncClient(hubUri());
      addTearDown(c.close);
      c.token = null;
      return c;
    }

    Future<StorageSwitch> connected(AppState s) async {
      final sw = await s.beginStorageSwitch(PcHubProvider(hubUri()));
      await sw.plan();
      await sw.connect(ProviderCredentials.pairing(keyedPairingCode(hub.auth)));
      return sw;
    }

    test('switch copies and verifies before anything changes, then syncs '
        'everything exactly once', () async {
      final s = await appOn(f.dir);
      await fillAttachmentHashes(s.workspace);
      final before = await liveHashes(f.dir);
      final sw = await connected(s);
      final plan = await sw.plan();
      expect(plan.localRecords, greaterThan(20));

      final v = await sw.copyAndVerify();
      expect(v.ok, isTrue, reason: v.problems.join('\n'));
      expect(v.attachmentsChecked, 2);
      expect(await liveHashes(f.dir), before, reason: 'live data untouched');
      expect(s.storageMode, StorageMode.local, reason: 'not switched yet');
      expect(
        File('${f.dir.path}${sep}sync${sep}hub.json').existsSync(),
        isFalse,
      );

      await s.activateStorage(sw);
      expect(s.storageMode, StorageMode.pcHub);
      await s.syncNow();
      expect(s.syncStatus, startsWith('Synced'));

      // Another device receives everything, once.
      final ipad = otherDevice('ipad');
      ipad.token = await hub.auth.register(
        hub.auth.createPairingCode(),
        'ipadx',
        'iPad',
      );
      final contents = await hubContents(ipad);
      final local = await SyncEngine(
        workspace: s.workspace,
        canvases: s.canvases,
        client: ipad,
      ).localVersions();
      expect(contents.keys.toSet(), containsAll(local.keys));
      for (final c in local.values) {
        expect(contents[c.key]!.rev, c.rev, reason: c.key);
      }
      expect(
        contents.values
            .where((c) => c.collection == 'notes' && !c.deleted)
            .length,
        s.workspace.notes.length,
      );
      // Nothing left to send: a second sync pushes nothing new.
      final lastSeq = (await ipad.pull(0, limit: 1)).lastSeq;
      await s.syncNow();
      expect((await ipad.pull(0, limit: 1)).lastSeq, lastSeq);
    });

    test(
      'cancel leaves this device as it was; the hub keeps its copy',
      () async {
        final s = await appOn(f.dir);
        await fillAttachmentHashes(s.workspace);
        final before = await liveHashes(f.dir);
        final sw = await connected(s);
        expect((await sw.copyAndVerify()).ok, isTrue);
        await sw.cancel();
        expect(sw.token, isNull);
        expect(s.storageMode, StorageMode.local);
        expect(
          File('${f.dir.path}${sep}sync${sep}hub.json').existsSync(),
          isFalse,
        );
        expect(
          File('${f.dir.path}${sep}sync${sep}hub.token').existsSync(),
          isFalse,
        );
        expect(await liveHashes(f.dir), before);
        // Cancelling before copying changes nothing either.
        final early = await connected(s);
        await early.cancel();
        expect(() => early.copyAndVerify(), throwsStateError);
      },
    );

    test('a destination with data is merged, never overwritten; conflicting '
        'edits keep both versions', () async {
      // The iPad (its own copy of the same notes) is already on the hub,
      // with its own edit of one note.
      final ipadDir = Directory('${root.path}${sep}ipad');
      final pcSnapshot = await (await appOn(f.dir)).workspace.backups
          .snapshot('seed', includeAttachments: true);
      final pcSeed = states.removeLast();
      pcSeed.workspace.dispose();
      await pcSeed.workspace.backups.restoreTo(pcSnapshot, ipadDir);
      File('${ipadDir.path}${sep}sync${sep}device.json').deleteSync();
      File('${ipadDir.path}${sep}sync${sep}device.json.bak').deleteSync();
      final ipad = await appOn(ipadDir);
      final ipadSwitch = await connected(ipad);
      expect((await ipadSwitch.copyAndVerify()).ok, isTrue);
      await ipad.activateStorage(ipadSwitch);
      ipad.workspace.notes.put(
        ipad.workspace.notes[f.noteId]!.copyWith(body: 'iPad version'),
      );
      ipad.workspace.createNote(title: 'Only on the iPad');
      await ipad.syncNow();

      final pc = await appOn(f.dir);
      pc.workspace.notes.put(
        pc.workspace.notes[f.noteId]!.copyWith(body: 'PC version'),
      );
      final sw = await connected(pc);
      final destination = await sw.connect(
        ProviderCredentials.pairing(keyedPairingCode(hub.auth)),
      );
      expect(destination, greaterThan(0), reason: 'the hub already has data');
      final v = await sw.copyAndVerify();
      expect(v.ok, isTrue, reason: v.problems.join('\n'));
      expect(v.conflicts, greaterThan(0));
      await pc.activateStorage(sw);
      await pc.syncNow();
      await ipad.syncNow();

      for (final s in [pc, ipad]) {
        final ws = s.workspace;
        expect(ws.notes.all.any((n) => n.title == 'Only on the iPad'), isTrue);
        final current = ws.notes[f.noteId]!.body;
        final kept = ws.conflicts.all
            .where((c) => c.recordId == f.noteId)
            .map((c) => c.otherData?['body'])
            .toSet();
        expect({current, ...kept}, containsAll(['PC version', 'iPad version']));
      }
    });

    test('an unreachable hub: edits stay here, never "Synced", sent once '
        'when it is back', () async {
      final s = await appOn(f.dir);
      final sw = await connected(s);
      expect((await sw.copyAndVerify()).ok, isTrue);
      await s.activateStorage(sw);
      await s.syncNow();
      await hub.stop();

      s.workspace.notes.put(
        s.workspace.notes[f.noteId]!.copyWith(title: 'Edited offline'),
      );
      await s.syncNow();
      expect(s.syncConnection, SyncConnection.offline);
      expect(s.syncStatus, isNot(startsWith('Synced')));
      await s.workspace.flush();
      final reopened = Workspace(f.dir);
      await reopened.load();
      expect(reopened.notes[f.noteId]!.title, 'Edited offline');
      reopened.dispose();

      hub = await startHub(); // same folder, same port
      await s.syncNow();
      expect(s.syncStatus, startsWith('Synced'));
      final other = otherDevice('x');
      other.token = await hub.auth.register(
        hub.auth.createPairingCode(),
        'otherx',
        'Other',
      );
      final versions = <String>[];
      var since = 0;
      while (true) {
        final page = await other.pull(since, limit: 500);
        versions.addAll([
          for (final c in page.changes)
            if (c.key == 'notes/${f.noteId}') c.rev,
        ]);
        since = page.next;
        if (!page.hasMore) break;
      }
      expect(versions.length, 1, reason: 'latest version stored once');
      expect(versions.single, s.workspace.notes.revOf(f.noteId));
    });
  });

  test('hosted: two devices sync through the service with no PC hub, '
      'conflicts keep both, retries do not duplicate, leaving keeps the '
      'remote copy', () async {
    AppLog.init(root);
    HostedProvider.allowLoopbackForTests = true;
    final serviceDir = Directory('${root.path}${sep}service');
    final service = await HostedHub.start(
      dir: serviceDir,
      host: '127.0.0.1',
      port: 0,
      dailyBackups: false,
    );
    addTearDown(service.stop);
    final url = Uri.parse('http://127.0.0.1:${service.port}');
    final invite = await HostedHub.createInvite(serviceDir);
    const email = 'me@example.com';
    const password = 'correct horse battery';

    final f = await buildPreUpdateWorkspace(Directory('${root.path}${sep}pc'));
    final pc = await appOn(f.dir);
    final pcSwitch = await pc.beginStorageSwitch(HostedProvider(url));
    await pcSwitch.plan();
    expect(
      await pcSwitch
          .connect(
            const ProviderCredentials.account(email, password, invite: null),
          )
          .then((_) => 'signed in')
          .catchError((Object e) => '$e'),
      contains('unauthorized'),
      reason: 'no account yet without the invite',
    );
    final pcSwitch2 = await pc.beginStorageSwitch(HostedProvider(url));
    expect(
      await pcSwitch2.connect(
        ProviderCredentials.account(email, password, invite: invite),
      ),
      0,
    );
    final v = await pcSwitch2.copyAndVerify();
    expect(v.ok, isTrue, reason: v.problems.join('\n'));
    await pc.activateStorage(pcSwitch2);
    expect(pc.storageMode, StorageMode.hosted);
    await pc.syncNow();
    expect(pc.syncStatus, startsWith('Synced'));

    // The iPad signs in to the same account (no invite) and gets it all.
    final ipad = await appOn(Directory('${root.path}${sep}ipad'));
    final ipadSwitch = await ipad.beginStorageSwitch(HostedProvider(url));
    expect(
      await ipadSwitch.connect(
        const ProviderCredentials.account(email, password),
      ),
      greaterThan(0),
    );
    expect((await ipadSwitch.copyAndVerify()).ok, isTrue);
    await ipad.activateStorage(ipadSwitch);
    await ipad.syncNow();
    final iws = ipad.workspace;
    expect(iws.notes[f.noteId]!.body, contains(secretBodyMarker));
    expect(iws.assets[f.linkAssetId]!.url, archiveUrl);
    expect(iws.customTags[f.tagId]!.color, f.tagColor);
    final photo = iws.assets[f.photoAssetId]!;
    expect(
      sha256
          .convert(iws.attachments.fileFor(photo.file!).readAsBytesSync())
          .toString(),
      photo.fileSha256,
    );
    final doc = (await ipad.canvases.load(f.canvasId))!;
    expect(doc.items.whereType<StrokeItem>().single.color, f.strokeColor);

    // Concurrent edits of one note on both devices: both versions kept.
    pc.workspace.notes.put(
      pc.workspace.notes[f.linkedNoteId]!.copyWith(body: 'PC edit'),
    );
    iws.notes.put(iws.notes[f.linkedNoteId]!.copyWith(body: 'iPad edit'));
    // Sync until both devices hold both versions (a sync the app starts by
    // itself right after an edit can still be running when syncNow is
    // called; that one only queues another).
    Set<Object?> bodiesOf(Workspace ws) => {
      ws.notes[f.linkedNoteId]!.body,
      for (final c in ws.conflicts.all)
        if (c.recordId == f.linkedNoteId) c.otherData?['body'],
    };
    for (var round = 0; round < 15; round++) {
      await pc.syncNow();
      await ipad.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if ([
        pc.workspace,
        iws,
      ].every((w) => bodiesOf(w).containsAll(['PC edit', 'iPad edit']))) {
        break;
      }
    }
    for (final ws in [pc.workspace, iws]) {
      final bodies = {
        ws.notes[f.linkedNoteId]!.body,
        for (final c in ws.conflicts.all)
          if (c.recordId == f.linkedNoteId) c.otherData?['body'],
      };
      expect(bodies, containsAll(['PC edit', 'iPad edit']));
    }

    // A retried push (lost reply) is recognised, not stored twice.
    final client = SyncClient(
      url,
      token: pcSwitch2.token,
      crypto: testSyncCrypto,
    );
    addTearDown(client.close);
    final change = (await SyncEngine(
      workspace: pc.workspace,
      canvases: pc.canvases,
      client: client,
    ).localVersions())['notes/${f.noteId}']!;
    final seq = (await client.pull(0, limit: 1)).lastSeq;
    final again = await client.push([change]);
    expect(again.results.single.status, PushStatus.duplicate);
    expect((await client.pull(0, limit: 1)).lastSeq, seq);

    // Back to this device only: nothing is deleted on the service.
    expect(await pc.switchToLocalOnly(), isNull);
    expect(pc.storageMode, StorageMode.local);
    await ipad.syncNow();
    expect(ipad.syncStatus, startsWith('Synced'));
    expect(iws.notes[f.noteId], isNotNull);
    expect(
      (await hubContents(client)).containsKey('notes/${f.noteId}'),
      isTrue,
    );

    final log = File('${root.path}${sep}logs${sep}app.log');
    final text = log.existsSync() ? log.readAsStringSync() : '';
    expect(text, isNot(contains(password)));
    expect(text, isNot(contains(pcSwitch2.token!)));
    expect(text, isNot(contains(secretBodyMarker)));
  });
}
