// Near-real-time sync: two devices (own data folders) and a real hub on
// 127.0.0.1, each device driven by SyncScheduler exactly as the app does
// (sync after a local edit; pull when the hub's /v1/wait reports a
// change). Latencies are measured, not assumed.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_application_1/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

class LiveDevice {
  LiveDevice(this.ws, this.engine, this.scheduler, this.errors);
  final Workspace ws;
  final SyncEngine engine;
  final SyncScheduler scheduler;
  final List<Object> errors;

  /// A local edit, told to the scheduler like the app does.
  void edited() => scheduler.localChange();
}

Future<Uint8List> makePng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xFF8FBFA9), BlendMode.src);
  final image = await recorder.endRecording().toImage(4, 3);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
      .asUint8List();
}

/// Waits until [done] is true; returns how long that took.
Future<Duration> until(
  bool Function() done, {
  Duration limit = const Duration(seconds: 15),
  String what = 'condition',
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > limit) fail('$what not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return watch.elapsed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the local hub

  late Directory root;
  late HubServer hub;
  late int port;
  final devices = <LiveDevice>[];

  Future<HubServer> startHub() async {
    final s = await HubServer.start(
      dir: Directory('${root.path}${Platform.pathSeparator}hub'),
      port: port,
      dailyBackups: false,
    );
    port = s.port;
    return s;
  }

  Future<LiveDevice> device(String name) async {
    final dir = Directory('${root.path}${Platform.pathSeparator}$name');
    final ws = Workspace(dir);
    await ws.load();
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      ws.device!.id,
      name,
    );
    final client = SyncClient(
      Uri.parse('http://127.0.0.1:$port'),
      token: token,
    );
    final engine = SyncEngine(
      workspace: ws,
      canvases: FileCanvasRepository(ws.store),
      client: client,
    );
    final errors = <Object>[];
    final d = LiveDevice(
      ws,
      engine,
      SyncScheduler(
        run: () async => engine.syncOnce(),
        cursor: () async => (await engine.loadState()).cursor,
        client: client,
        debounce: const Duration(milliseconds: 100),
        onError: (e, _) => errors.add(e),
      ),
      errors,
    );
    devices.add(d);
    return d;
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_live_');
    port = 0;
    hub = await startHub();
  });

  tearDown(() async {
    for (final d in devices) {
      await d.scheduler.close();
      d.engine.client.close();
    }
    devices.clear();
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(LiveDevice, LiveDevice)> pair() async {
    final pc = await device('pc');
    final ipad = await device('ipad');
    pc.scheduler.start();
    ipad.scheduler.start();
    await until(
      () =>
          pc.scheduler.connection == SyncConnection.live &&
          ipad.scheduler.connection == SyncConnection.live,
      what: 'both devices live',
    );
    return (pc, ipad);
  }

  test(
    'an edit reaches the other device in under 2 seconds (measured)',
    () async {
      final (pc, ipad) = await pair();
      final samples = <int>[];
      for (var i = 0; i < 5; i++) {
        final note = pc.ws.createNote(title: 'Live $i', body: 'body $i');
        pc.edited();
        final took = await until(
          () => ipad.ws.notes[note.id]?.body == 'body $i',
          what: 'note $i on the iPad',
        );
        samples.add(took.inMilliseconds);
      }
      // ignore: avoid_print
      print('Measured PC→iPad latency (ms): $samples');
      expect(samples.every((ms) => ms < 2000), isTrue, reason: '$samples');
      await until(() => !pc.scheduler.pendingLocal, what: "PC shows synced");
      expect(pc.errors, isEmpty);
      expect(ipad.errors, isEmpty);
    },
  );

  test(
    'deletions and attachments propagate live; files arrive intact',
    () async {
      final (pc, ipad) = await pair();
      final png = await makePng();
      final asset = await pc.ws.imageAssetFromBytes(png, 'png');
      final note = pc.ws.createNote(title: 'With photo', assetIds: [asset.id]);
      pc.edited();
      await until(
        () =>
            ipad.ws.assets[asset.id] != null &&
            ipad.ws.attachments
                .fileFor(ipad.ws.assets[asset.id]!.file!)
                .existsSync(),
        what: 'photo on the iPad',
      );
      expect(
        ipad.ws.attachments
            .fileFor(ipad.ws.assets[asset.id]!.file!)
            .readAsBytesSync(),
        png,
      );
      ipad.ws.deleteNote(note.id);
      ipad.edited();
      await until(() => pc.ws.notes[note.id] == null, what: 'delete on the PC');
      // A stale re-sync never brings it back.
      await pc.scheduler.syncNow();
      await ipad.scheduler.syncNow();
      expect(pc.ws.notes[note.id], isNull);
      expect(ipad.ws.notes[note.id], isNull);
    },
  );

  test(
    'offline edits wait; after a hub restart everything catches up',
    () async {
      final (pc, ipad) = await pair();
      await hub.stop();
      final offline = pc.ws.createNote(title: 'Written offline');
      pc.edited();
      await until(
        () => pc.scheduler.connection == SyncConnection.offline,
        what: 'PC notices the hub is gone',
      );
      expect(
        pc.scheduler.pendingLocal,
        isTrue,
        reason: 'never shown as synced',
      );
      hub = await startHub(); // same folder, same port
      final took = await until(
        () => ipad.ws.notes[offline.id] != null,
        limit: const Duration(seconds: 40),
        what: 'catch-up after the restart',
      );
      // ignore: avoid_print
      print('Catch-up after hub restart: ${took.inMilliseconds} ms');
      expect(pc.scheduler.connection, SyncConnection.live);
      expect(pc.scheduler.pendingLocal, isFalse);
    },
  );

  test(
    'duplicate notifications and repeated cycles never duplicate data',
    () async {
      final (pc, ipad) = await pair();
      final note = pc.ws.createNote(title: 'Once');
      pc.edited();
      await until(() => ipad.ws.notes[note.id] != null, what: 'first copy');
      // Many requests at once (a burst of notifications): coalesced.
      for (var i = 0; i < 10; i++) {
        ipad.scheduler.request(Duration.zero);
        pc.scheduler.request(Duration.zero);
      }
      await ipad.scheduler.syncNow();
      await pc.scheduler.syncNow();
      expect(ipad.ws.notes.all.where((n) => n.title == 'Once'), hasLength(1));
      expect(pc.ws.notes.all.where((n) => n.title == 'Once'), hasLength(1));
      final last = await pc.engine.syncOnce();
      expect(last.pushed, 0);
    },
  );

  test(
    'simultaneous edits: one deterministic winner, the other kept',
    () async {
      final (pc, ipad) = await pair();
      final note = pc.ws.createNote(title: 'Shared', body: 'start');
      pc.edited();
      await until(() => ipad.ws.notes[note.id] != null, what: 'shared note');
      // Both edit before either change can travel.
      pc.scheduler.stop();
      ipad.scheduler.stop();
      pc.ws.notes.put(pc.ws.notes[note.id]!.copyWith(body: 'from the PC'));
      ipad.ws.notes.put(
        ipad.ws.notes[note.id]!.copyWith(body: 'from the iPad'),
      );
      pc.scheduler.start();
      ipad.scheduler.start();
      pc.edited();
      ipad.edited();
      await until(
        () =>
            pc.ws.notes[note.id]!.body == ipad.ws.notes[note.id]!.body &&
            pc.ws.conflicts.length == 1 &&
            ipad.ws.conflicts.length == 1,
        what: 'both devices agree, with the conflict kept',
      );
      final winner = pc.ws.notes[note.id]!.body;
      final conflict = pc.ws.conflicts.all.single;
      final kept = jsonEncode(conflict.otherData);
      expect(
        {
          winner,
          kept.contains('from the PC') ? 'from the PC' : 'from the iPad',
        },
        {'from the PC', 'from the iPad'},
        reason: 'the losing text is kept in the conflict record',
      );
    },
  );

  test('a hub without live updates is polled instead', () async {
    final old = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => old.close(force: true));
    old.listen((r) async {
      r.response
        ..statusCode = 404
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({'error': 'not_found', 'message': 'Unknown endpoint.'}),
        );
      await r.response.close();
    });
    final client = SyncClient(
      Uri.parse('http://127.0.0.1:${old.port}'),
      token: 't',
    );
    addTearDown(client.close);
    var runs = 0;
    final s = SyncScheduler(
      run: () async => runs++,
      cursor: () async => 0,
      client: client,
      debounce: const Duration(milliseconds: 50),
    );
    addTearDown(s.stop);
    s.start();
    await until(() => runs >= 1, what: 'first sync');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(s.connection, SyncConnection.polling);
    s.localChange();
    await until(() => runs >= 2, what: 'sync after a local edit');
  });
}
