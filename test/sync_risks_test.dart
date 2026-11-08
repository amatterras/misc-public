// Regression tests for data-loss risks found in the sync audit
// (docs/SYNC_ARCHITECTURE.md §11). Real hub on 127.0.0.1, real data folders.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_backup.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

/// A client that runs [beforeReply] after the hub answered a push but
/// before the engine sees the answer (like a user typing mid-sync).
class RacingClient extends SyncClient {
  RacingClient(super.base, {super.token});

  void Function()? beforeReply;

  @override
  Future<({List<PushResult> results, int lastSeq, String hubId})> push(
    List<SyncChange> changes,
  ) async {
    final r = await super.push(changes);
    beforeReply?.call();
    beforeReply = null;
    return r;
  }
}

class Device {
  Device(this.ws, this.canvases, this.client, this.engine);
  final Workspace ws;
  final FileCanvasRepository canvases;
  final RacingClient client;
  final SyncEngine engine;
  Future<SyncReport> sync() => engine.syncOnce();
}

Future<Uint8List> makePng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xFFE9A23B), BlendMode.src);
  final image = await recorder.endRecording().toImage(2, 2);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
      .asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late HubServer hub;
  late int port;
  Directory hubDir() => Directory('${root.path}${sep}hub');

  Future<void> startHub() async {
    hub = await HubServer.start(dir: hubDir(), port: port, dailyBackups: false);
    port = hub.port;
  }

  Future<Device> device(String name) async {
    final ws = Workspace(Directory('${root.path}$sep$name'));
    await ws.load();
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      ws.device!.id,
      name,
    );
    final client = RacingClient(
      Uri.parse('http://127.0.0.1:$port'),
      token: token,
    );
    final canvases = FileCanvasRepository(ws.store);
    return Device(
      ws,
      canvases,
      client,
      SyncEngine(workspace: ws, canvases: canvases, client: client),
    );
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_risk_');
    port = 0;
    await startHub();
  });

  tearDown(() async {
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'after a real hub restore, devices holding each other\'s records refill it',
    () async {
      final pc = await device('pc');
      final ipad = await device('ipad');
      final a = pc.ws.createNote(title: 'Made on PC before the backup');
      await pc.sync();
      await ipad.sync(); // the iPad now holds a PC-made record
      final backup = await hub.backups.create();
      final b = ipad.ws.createNote(title: 'Made on iPad after the backup');
      await ipad.sync();
      await pc.sync();

      // Disaster recovery exactly as documented: restore into a NEW folder.
      await hub.stop();
      final old = await hubDir().rename('${root.path}${sep}hub-old');
      final backupNow = Directory(
        backup.path.replaceFirst(hubDir().path, old.path),
      );
      await HubBackups.restoreTo(
        backupNow,
        hubDir(),
        attachmentsFrom: Directory('${old.path}${sep}attachments'),
      );
      await startHub();

      // The iPad syncs first and re-offers a PC-made record: must not stall.
      final r = await ipad.sync();
      expect(r.problems, isEmpty);
      await pc.sync();
      expect((await hub.store.current('notes', a.id))!.data!['title'], a.title);
      expect((await hub.store.current('notes', b.id))!.data!['title'], b.title);
      expect(pc.ws.notes.length, 2);
      expect(ipad.ws.notes.length, 2);
    },
  );

  test('an edit made while a push is in flight is never overwritten', () async {
    final pc = await device('pc');
    final ipad = await device('ipad');
    final note = pc.ws.createNote(title: 'Plan', body: 'start');
    await pc.sync();
    await ipad.sync();

    pc.ws.notes.put(pc.ws.notes[note.id]!.copyWith(body: 'PC edit (older)'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    ipad.ws.notes.put(
      ipad.ws.notes[note.id]!.copyWith(body: 'iPad edit (newer)'),
    );
    await ipad.sync();

    // The hub keeps the iPad's newer version for the PC's push, but the user
    // types again on the PC while that request is in flight.
    pc.client.beforeReply = () => pc.ws.notes.put(
      pc.ws.notes[note.id]!.copyWith(body: 'PC typed during sync'),
    );
    await pc.sync();
    expect(pc.ws.notes[note.id]!.body, 'PC typed during sync');

    await pc.sync(); // the newest edit goes out
    await ipad.sync();
    final current = (await hub.store.current('notes', note.id))!.data!['body'];
    final preserved = {
      for (final c in pc.ws.conflicts.all) c.otherData?['body'],
    };
    expect(current, 'PC typed during sync');
    expect(
      {current, ...preserved},
      containsAll([
        'PC typed during sync',
        'iPad edit (newer)',
        'PC edit (older)',
      ]),
      reason: 'no version was lost',
    );
  });

  test('restoring an app backup is not undone by the next sync', () async {
    final pc = await device('pc');
    final note = pc.ws.createNote(title: 'Precious');
    await pc.sync();
    final backup = await pc.ws.backups.snapshot('manual');
    pc.ws.notes.remove(note.id);
    await pc.sync();
    expect((await hub.store.current('notes', note.id))!.deleted, isTrue);

    await pc.ws.backups.restore(backup);
    final ws = Workspace(pc.ws.root);
    await ws.load();
    expect(ws.notes[note.id], isNotNull);
    final engine = SyncEngine(
      workspace: ws,
      canvases: FileCanvasRepository(ws.store),
      client: pc.client,
    );
    await engine.syncOnce();
    expect(ws.notes[note.id], isNotNull, reason: 'the restored note stays');
    expect((await hub.store.current('notes', note.id))!.deleted, isFalse);
  });

  test(
    'one oversized record is reported but does not block other changes',
    () async {
      final pc = await device('pc');
      final huge = pc.ws.createNote(
        title: 'Huge',
        body: 'x' * (maxRecordBytes + 10),
      );
      final small = pc.ws.createNote(title: 'Small');
      final r = await pc.sync();
      expect(r.problems.join(), contains('too large'));
      expect(await hub.store.current('notes', small.id), isNotNull);
      expect(await hub.store.current('notes', huge.id), isNull);
      expect(pc.ws.notes[huge.id], isNotNull, reason: 'kept on this device');
    },
  );

  test('photos the hub lost are uploaded again in the next session', () async {
    final pc = await device('pc');
    final png = await makePng();
    final asset = await pc.ws.imageAssetFromBytes(png, 'png');
    await pc.sync();
    final sha = pc.ws.assets[asset.id]!.fileSha256!;
    await hub.store.attachmentFile(sha).delete();

    // A new session (app restart) checks the hub's photos once.
    final engine = SyncEngine(
      workspace: pc.ws,
      canvases: pc.canvases,
      client: pc.client,
    );
    final running = engine.syncOnce();
    final idle = engine.whenIdle();
    final r = await running;
    await idle;
    expect(r.uploaded, 1);
    expect(await hub.store.attachmentFile(sha).readAsBytes(), png);
  });
}
