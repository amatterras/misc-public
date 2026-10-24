// Attacks on sync, through the real code: real hub (HubServer on
// 127.0.0.1), real SyncEngine per device, each device with its own data
// folder. A small proxy between device and hub injects faults (a reply lost
// after the hub stored the push; an upload cut off half way). This is a
// simulation on one PC, not a test with physical devices.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fault injection between a device and the hub.
class FaultProxy {
  FaultProxy._(this._server, this.hubPort);
  final HttpServer _server;
  final int hubPort;
  int get port => _server.port;

  /// The next push is stored by the hub, but its reply never arrives.
  bool loseNextPushReply = false;

  /// The next attachment upload is cut off after half of its bytes.
  bool cutNextUpload = false;
  int lostReplies = 0, cutUploads = 0;

  static Future<FaultProxy> start(int hubPort) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final p = FaultProxy._(s, hubPort);
    s.listen(p._handle);
    return p;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest r) async {
    final body = await r.fold<BytesBuilder>(
      BytesBuilder(),
      (b, d) => b..add(d),
    );
    final bytes = body.takeBytes();
    final client = HttpClient();
    try {
      final out = await client.openUrl(
        r.method,
        Uri.parse('http://127.0.0.1:$hubPort${r.uri}'),
      );
      for (final h in [
        HttpHeaders.authorizationHeader,
        HttpHeaders.contentTypeHeader,
        protocolHeader,
      ]) {
        final v = r.headers.value(h);
        if (v != null) out.headers.set(h, v);
      }
      if (r.method == 'PUT' && cutNextUpload) {
        cutNextUpload = false;
        cutUploads++;
        out.contentLength = bytes.length;
        out.add(bytes.sublist(0, bytes.length ~/ 2));
        await out.flush();
        out.abort(); // the connection drops mid-upload
        (await r.response.detachSocket()).destroy();
        return;
      }
      if (bytes.isNotEmpty) {
        out.contentLength = bytes.length;
        out.add(bytes);
      }
      final res = await out.close();
      final reply = await res.fold<BytesBuilder>(
        BytesBuilder(),
        (b, d) => b..add(d),
      );
      if (r.uri.path == '/v1/push' && loseNextPushReply) {
        loseNextPushReply = false;
        lostReplies++;
        (await r.response.detachSocket()).destroy(); // stored, no answer
        return;
      }
      r.response.statusCode = res.statusCode;
      final ct = res.headers.contentType;
      if (ct != null) r.response.headers.contentType = ct;
      r.response.add(reply.takeBytes());
      await r.response.close();
    } catch (_) {
      try {
        (await r.response.detachSocket()).destroy();
      } catch (_) {}
    } finally {
      client.close(force: true);
    }
  }
}

class Device {
  Device(this.name, this.ws, this.engine);
  final String name;
  final Workspace ws;
  final SyncEngine engine;
  Future<SyncReport> sync() => engine.syncOnce();
}

Future<Uint8List> png(int seed) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(Color(0xFF000000 + seed * 4099), BlendMode.src);
  final image = await recorder.endRecording().toImage(64, 48);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
      .asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late HubServer hub;
  late int port;
  final clients = <SyncClient>[];

  Future<HubServer> startHub() async {
    final s = await HubServer.start(
      dir: Directory('${root.path}${Platform.pathSeparator}hub'),
      port: port,
      dailyBackups: false,
    );
    port = s.port;
    return s;
  }

  Future<Device> device(String name, {int? viaPort, SyncClock? clock}) async {
    final ws = Workspace(
      Directory('${root.path}${Platform.pathSeparator}$name'),
      clock: clock,
    );
    await ws.load();
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      ws.device!.id,
      name,
    );
    final client = SyncClient(
      Uri.parse('http://127.0.0.1:${viaPort ?? port}'),
      token: token,
    );
    clients.add(client);
    return Device(
      name,
      ws,
      SyncEngine(
        workspace: ws,
        canvases: FileCanvasRepository(ws.store),
        client: client,
      ),
    );
  }

  /// Everything a device shows, comparable across devices.
  String snapshot(Workspace ws) => jsonEncode({
    for (final MapEntry(key: name, value: c) in ws.syncCollections.entries)
      name: {
        for (final r in c.all.toList()..sort((a, b) => a.id.compareTo(b.id)))
          r.id: c.jsonOf(r.id),
      },
  });

  /// Syncs every device until nothing moves, then checks they agree.
  Future<void> converge(List<Device> ds) async {
    for (var round = 0; round < 4; round++) {
      for (final d in ds) {
        await d.sync();
      }
    }
    final first = snapshot(ds.first.ws);
    for (final d in ds.skip(1)) {
      expect(snapshot(d.ws), first, reason: '${d.name} differs');
    }
    for (final d in ds) {
      expect((await d.sync()).pushed, 0, reason: '${d.name} still sending');
    }
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_attack_');
    port = 0;
    hub = await startHub();
  });

  tearDown(() async {
    for (final c in clients) {
      c.close();
    }
    clients.clear();
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'simultaneous edits to one note: both devices agree, loser kept',
    () async {
      final a = await device('a'), b = await device('b');
      final n = a.ws.createNote(title: 'Plan', body: 'v0');
      await converge([a, b]);
      a.ws.notes.put(a.ws.notes[n.id]!.copyWith(body: 'A wrote this'));
      b.ws.notes.put(b.ws.notes[n.id]!.copyWith(body: 'B wrote this'));
      await converge([a, b]);
      final winner = a.ws.notes[n.id]!.body;
      final kept = jsonEncode(a.ws.conflicts.all.single.otherData);
      expect(
        {winner, kept.contains('A wrote') ? 'A wrote this' : 'B wrote this'},
        {'A wrote this', 'B wrote this'},
        reason: 'neither edit is silently lost',
      );
    },
  );

  test('edits to different items never conflict', () async {
    final a = await device('a'), b = await device('b');
    final n1 = a.ws.createNote(title: 'One');
    final n2 = a.ws.createNote(title: 'Two');
    await converge([a, b]);
    a.ws.notes.put(a.ws.notes[n1.id]!.copyWith(body: 'by A'));
    b.ws.notes.put(b.ws.notes[n2.id]!.copyWith(body: 'by B'));
    await converge([a, b]);
    expect(b.ws.notes[n1.id]!.body, 'by A');
    expect(a.ws.notes[n2.id]!.body, 'by B');
    expect(a.ws.conflicts.length, 0);
  });

  test('add, update and delete while offline on both sides converge', () async {
    final a = await device('a'), b = await device('b');
    final keep = a.ws.createNote(title: 'Keep', body: 'v0');
    final gone = a.ws.createNote(title: 'Gone');
    await converge([a, b]);
    await hub.stop(); // both offline
    final aNew = a.ws.createNote(title: 'A offline');
    a.ws.notes.put(a.ws.notes[keep.id]!.copyWith(body: 'edited by A'));
    a.ws.deleteNote(gone.id);
    final bNew = b.ws.createNote(title: 'B offline');
    b.ws.deleteNote(keep.id); // B deletes what A edited
    await expectLater(a.sync(), throwsA(isA<SyncFailure>()));
    hub = await startHub();
    await converge([a, b]);
    expect(a.ws.notes[aNew.id], isNotNull);
    expect(a.ws.notes[bNew.id], isNotNull);
    expect(a.ws.notes[gone.id], isNull);
    // A deletion never overwrites an edit: the edit stays, deletion noted.
    expect(b.ws.notes[keep.id]?.body, 'edited by A');
    expect(a.ws.conflicts.all.single.reason, isNotEmpty);
  });

  test(
    'a push stored by the hub whose reply is lost is not duplicated',
    () async {
      final proxy = await FaultProxy.start(port);
      addTearDown(proxy.close);
      final a = await device('a', viaPort: proxy.port), b = await device('b');
      final n = a.ws.createNote(title: 'Sent once', body: 'x');
      proxy.loseNextPushReply = true;
      await expectLater(a.sync(), throwsA(isA<SyncFailure>()));
      expect(proxy.lostReplies, 1);
      expect(
        (await hub.store.current('notes', n.id))?.data?['body'],
        'x',
        reason: 'the hub did store it',
      );
      // Hub restart before the device tries again.
      await hub.stop();
      hub = await startHub();
      await converge([a, b]);
      expect(b.ws.notes.all.where((x) => x.title == 'Sent once'), hasLength(1));
      expect(hub.store.stats.records, a.ws.notes.length + a.ws.folders.length);
    },
  );

  test(
    'an upload cut off half way is never stored; the retry arrives intact',
    () async {
      final proxy = await FaultProxy.start(port);
      addTearDown(proxy.close);
      final a = await device('a', viaPort: proxy.port), b = await device('b');
      final bytes = await png(3);
      final asset = await a.ws.imageAssetFromBytes(bytes, 'png');
      a.ws.createNote(title: 'Photo', assetIds: [asset.id]);
      proxy.cutNextUpload = true;
      await expectLater(a.sync(), throwsA(isA<SyncFailure>()));
      expect(proxy.cutUploads, 1);
      final sha = a.ws.assets[asset.id]!.fileSha256!;
      expect(
        await hub.store.hasAttachment(sha),
        isFalse,
        reason: 'no partial file',
      );
      await converge([a, b]);
      final got = b.ws.attachments.fileFor(b.ws.assets[asset.id]!.file!);
      expect(got.readAsBytesSync(), bytes);
    },
  );

  test('duplicate and out-of-order delivery change nothing twice', () async {
    final a = await device('a'), b = await device('b');
    // The note arrives before the folder it is in (separate pushes).
    final folder = a.ws.createFolder('Later');
    final note = a.ws.createNote(title: 'In folder', folderId: folder.id);
    final client = clients.first;
    final clock = a.ws.clock;
    await client.push([
      SyncChange(
        collection: 'notes',
        id: note.id,
        rev: a.ws.notes.versions().singleWhere((v) => v.id == note.id).rev,
        deleted: false,
        data: a.ws.notes.jsonOf(note.id),
      ),
    ]);
    await b.sync();
    expect(b.ws.notes[note.id]!.folderId, folder.id);
    expect(b.ws.folders[folder.id], isNull, reason: 'not arrived yet');
    clock.now();
    await converge([a, b]);
    expect(b.ws.folders[folder.id]?.name, 'Later');
    // Everything delivered again from the start: no duplicates, no change.
    final before = snapshot(b.ws);
    final state = await b.engine.loadState();
    state.cursor = 0;
    await b.ws.store.write('sync', 'client_state', state.toJson());
    final again = await b.sync();
    expect(again.pushed, 0);
    expect(snapshot(b.ws), before);
  });

  test('an old client coming back never resurrects a deleted note', () async {
    final a = await device('a'),
        b = await device('b'),
        old = await device('old');
    final n = a.ws.createNote(title: 'Deleted later');
    final m = a.ws.createNote(title: 'Edited offline');
    await converge([a, b, old]);
    a.ws.deleteNote(n.id);
    a.ws.deleteNote(m.id);
    await converge([a, b]);
    // "old" was offline the whole time; it edited m (but not n).
    old.ws.notes.put(old.ws.notes[m.id]!.copyWith(body: 'my offline edit'));
    await converge([a, b, old]);
    expect(old.ws.notes[n.id], isNull, reason: 'stale copy not resurrected');
    // A newer edit is never silently lost: it comes back with the deletion
    // kept as a conflict record.
    expect(a.ws.notes[m.id]?.body, 'my offline edit');
    expect(a.ws.conflicts.all.any((c) => c.recordId == m.id), isTrue);
  });

  test(
    'clock skew: a later edit from a device two hours behind still wins',
    () async {
      var behind =
          DateTime.now().toUtc().millisecondsSinceEpoch -
          const Duration(hours: 2).inMilliseconds;
      final a = await device('a');
      final b = await device(
        'b',
        clock: SyncClock(wallClock: () => behind += 5),
      );
      final n = a.ws.createNote(title: 'Skew', body: 'from A');
      await converge([a, b]);
      b.ws.notes.put(b.ws.notes[n.id]!.copyWith(body: 'later, from B'));
      await converge([a, b]);
      expect(a.ws.notes[n.id]!.body, 'later, from B');
      expect(a.ws.conflicts.length, 0, reason: 'sequential, not concurrent');
    },
  );

  test(
    'repeated reconnects with edits in between converge without copies',
    () async {
      final a = await device('a'), b = await device('b');
      var made = 0;
      for (var i = 0; i < 12; i++) {
        if (i.isEven) {
          await hub.stop();
        }
        a.ws.createNote(title: 'A$i');
        b.ws.createNote(title: 'B$i');
        made += 2;
        if (i.isEven) {
          await expectLater(a.sync(), throwsA(isA<SyncFailure>()));
          hub = await startHub();
        }
        await a.sync();
        await b.sync();
      }
      await converge([a, b]);
      expect(a.ws.notes.length, made);
      expect(b.ws.notes.length, made);
      expect(a.ws.notes.all.map((n) => n.title).toSet(), hasLength(made));
    },
  );

  test('a read-only mirror can read but never write', () async {
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      'mirrorabc12345',
      'Mirror',
    );
    final mirror = SyncClient(
      Uri.parse('http://127.0.0.1:$port'),
      token: token,
    );
    clients.add(mirror);
    expect((await mirror.pull(0)).changes, isEmpty);
    await expectLater(
      mirror.push([
        SyncChange(
          collection: 'notes',
          id: 'x',
          rev: SyncClock(deviceId: 'mirrorabc12345').now(),
          deleted: false,
          data: {'id': 'x', 'title': 'evil', 'body': ''},
        ),
      ]),
      throwsA(isA<SyncFailure>().having((e) => e.code, 'code', 'read_only')),
    );
    final f = File('${root.path}${Platform.pathSeparator}x.bin')
      ..writeAsBytesSync([1, 2, 3]);
    await expectLater(
      mirror.upload(await fileSha256(f), f),
      throwsA(isA<SyncFailure>()),
    );
    expect(hub.store.stats.records, 0);
  });

  test(
    'pause: changes stay queued on every device; resume reconciles',
    () async {
      final a = await device('a'), b = await device('b');
      await converge([a, b]);
      await hub.setPaused(true);
      final na = a.ws.createNote(title: 'Paused A');
      final nb = b.ws.createNote(title: 'Paused B');
      await expectLater(
        a.sync(),
        throwsA(
          isA<SyncFailure>().having((e) => e.code, 'code', 'sync_paused'),
        ),
      );
      expect(
        hub.store.stats.records,
        0,
        reason: 'nothing crossed while paused',
      );
      // Paused survives a hub restart.
      await hub.stop();
      hub = await startHub();
      expect(hub.paused, isTrue);
      await hub.setPaused(false);
      await converge([a, b]);
      expect(b.ws.notes[na.id], isNotNull);
      expect(a.ws.notes[nb.id], isNotNull);
    },
  );

  test(
    'the photo record and file reach a third device after retries',
    () async {
      final a = await device('a'), b = await device('b'), c = await device('c');
      final bytes = await png(7);
      final asset = await a.ws.imageAssetFromBytes(bytes, 'png');
      a.ws.notes.put(
        a.ws.createNote(title: 'P').copyWith(assetIds: [asset.id]),
      );
      await converge([a, b, c]);
      for (final d in [b, c]) {
        final x = d.ws.assets[asset.id]!;
        expect(x.kind, AssetKind.image);
        expect(d.ws.attachments.fileFor(x.file!).readAsBytesSync(), bytes);
      }
    },
  );
}
