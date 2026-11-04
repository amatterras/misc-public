// Direct device-to-device sync with the PC off, built from the existing
// engine: every device can host a hub of its own (HubServer is plain Dart),
// and a device syncs with several remotes (SyncEngine.remote), each with its
// own cursor and last-confirmed versions. Here: an iPad that hosts a hub and
// an iPhone that syncs with it while the PC hub is down; edits made on both;
// the PC coming back; and a peer that is briefly unreachable.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/sync/e2ee.dart';

import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _Device {
  _Device(this.name, this.ws, this.canvases);
  final String name;
  final Workspace ws;
  final FileCanvasRepository canvases;
  final Map<String, SyncEngine> engines = {};

  Future<SyncReport> sync(String remote) => engines[remote]!.syncOnce();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late HubServer? pc; // the PC's hub (null while the PC is off)
  late HubServer? ipadHub; // the hub the iPad hosts
  var pcPort = 0;
  var ipadPort = 0;

  Directory sub(String n) =>
      Directory('${root.path}${Platform.pathSeparator}$n');

  Future<HubServer> startPc() async {
    final s = await HubServer.start(
      dir: sub('pc-hub'),
      port: pcPort,
      dailyBackups: false,
    );
    pcPort = s.port;
    return s;
  }

  Future<HubServer> startIpadHub() async {
    final s = await HubServer.start(
      dir: sub('ipad-hub'),
      port: ipadPort,
      dailyBackups: false,
    );
    ipadPort = s.port;
    return s;
  }

  Future<_Device> device(String name) async {
    final ws = Workspace(sub(name));
    await ws.load();
    return _Device(name, ws, FileCanvasRepository(ws.store));
  }

  Future<void> connect(
    _Device d,
    String remote,
    HubServer hub,
    int port,
  ) async {
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      d.ws.device!.id,
      d.name,
    );
    d.engines[remote] = SyncEngine(
      workspace: d.ws,
      canvases: d.canvases,
      client: SyncClient(Uri.parse('http://127.0.0.1:$port'), token: token),
      remote: remote,
    );
  }

  Set<String> titles(_Device d) => {for (final n in d.ws.notes.all) n.title};

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_peer_');
    pc = await startPc();
    ipadHub = await startIpadHub();
  });

  tearDown(() async {
    await pc?.stop();
    await ipadHub?.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(_Device, _Device)> twoDevices() async {
    final ipad = await device('ipad');
    final phone = await device('phone');
    await connect(ipad, '', pc!, pcPort); // both know the PC hub
    await connect(phone, '', pc!, pcPort);
    await connect(ipad, 'self', ipadHub!, ipadPort); // the iPad's own hub
    await connect(phone, 'ipad', ipadHub!, ipadPort); // phone -> iPad's hub
    return (ipad, phone);
  }

  /// A full round between the two devices through the iPad's hub.
  Future<void> peerRound(_Device ipad, _Device phone) async {
    await ipad.sync('self'); // iPad's own changes into its hub
    await phone.sync('ipad'); // phone pushes and pulls
    await ipad.sync('self'); // iPad receives what the phone pushed
  }

  test('with the PC off, iPhone and iPad exchange changes directly', () async {
    final (ipad, phone) = await twoDevices();
    await pc!.stop();
    pc = null;

    phone.ws.createNote(title: 'From the phone', body: 'a');
    ipad.ws.createNote(title: 'From the iPad', body: 'b');
    await peerRound(ipad, phone);

    expect(titles(ipad), {'From the phone', 'From the iPad'});
    expect(titles(phone), {'From the phone', 'From the iPad'});
    // Nothing duplicated by the round trip.
    expect(ipad.ws.notes.length, 2);
    expect(phone.ws.notes.length, 2);
  });

  test(
    'both edit the same note: one version wins, the other is kept',
    () async {
      final (ipad, phone) = await twoDevices();
      final note = ipad.ws.createNote(title: 'Shared', body: 'start');
      await peerRound(ipad, phone);
      expect(phone.ws.notes[note.id], isNotNull);

      ipad.ws.notes.put(note.copyWith(body: 'iPad edit'));
      phone.ws.notes.put(phone.ws.notes[note.id]!.copyWith(body: 'phone edit'));
      await peerRound(ipad, phone);
      await peerRound(ipad, phone);

      // Both devices hold the same winning text...
      expect(ipad.ws.notes[note.id]!.body, phone.ws.notes[note.id]!.body);
      // ...and the other edit was kept as a conflict, not lost.
      final bodies = {
        for (final c in [...ipad.ws.conflicts.all, ...phone.ws.conflicts.all])
          c.toJson().toString(),
      };
      expect(
        bodies.any((b) => b.contains('iPad edit') || b.contains('phone edit')),
        isTrue,
        reason: 'the losing edit is preserved',
      );
      expect(ipad.ws.conflicts.length, phone.ws.conflicts.length);
    },
  );

  test(
    'when the PC comes back everything converges without duplicates',
    () async {
      final (ipad, phone) = await twoDevices();
      await pc!.stop();
      pc = null;
      phone.ws.createNote(title: 'Made while PC off', body: 'x');
      ipad.ws.createNote(title: 'Also while PC off', body: 'y');
      await peerRound(ipad, phone);

      pc = await startPc(); // same folder and port: the PC is back
      await ipad.sync('');
      await phone.sync('');
      await ipad.sync('');
      await phone.sync('');

      for (final d in [ipad, phone]) {
        expect(titles(d), {'Made while PC off', 'Also while PC off'});
        expect(d.ws.notes.length, 2, reason: '${d.name}: no duplicates');
      }
      // A third device that only knows the PC gets everything too.
      final laptop = await device('laptop');
      await connect(laptop, '', pc!, pcPort);
      await laptop.sync('');
      expect(titles(laptop), {'Made while PC off', 'Also while PC off'});
    },
  );

  test(
    'a peer that is unreachable keeps the changes queued, then catches up',
    () async {
      final (ipad, phone) = await twoDevices();
      await ipad.sync('self');
      await ipadHub!.stop(); // the iPad is out of reach
      ipadHub = null;

      phone.ws.createNote(title: 'Waiting', body: 'z');
      await expectLater(
        phone.sync('ipad'),
        throwsA(
          isA<SyncFailure>().having((e) => e.retryable, 'retryable', true),
        ),
      );
      expect(phone.ws.notes.length, 1, reason: 'the local change is kept');

      ipadHub = await startIpadHub(); // back on the same port and folder
      await peerRound(ipad, phone);
      expect(titles(ipad), {'Waiting'});
    },
  );

  test('syncing the same remote twice changes nothing', () async {
    final (ipad, phone) = await twoDevices();
    phone.ws.createNote(title: 'Once', body: 'x');
    await peerRound(ipad, phone);
    final before = phone.ws.notes.versions().toList();
    final report = await phone.sync('ipad');
    expect(report.toString(), isNotEmpty);
    expect(
      phone.ws.notes.versions().map((v) => '${v.id}${v.rev}'),
      before.map((v) => '${v.id}${v.rev}'),
    );
    expect(ipad.ws.notes.length, 1);
  });

  test(
    'each remote keeps its own state and the hub state is untouched',
    () async {
      final (ipad, phone) = await twoDevices();
      phone.ws.createNote(title: 'N', body: 'x');
      await peerRound(ipad, phone);
      final syncDir = Directory(
        '${sub('phone').path}${Platform.pathSeparator}sync',
      );
      final names = syncDir
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toSet();
      expect(names.any((n) => n.startsWith('client_state_ipad')), isTrue);
      expect(
        names.contains('client_state.json'),
        isFalse,
        reason: 'the PC hub was never used, so its state does not exist',
      );
    },
  );

  test(
    'an encrypted photo travels peer to peer, then via the PC, intact',
    () async {
      final key = SyncCrypto.generate();
      final ipad = await device('ipad');
      final phone = await device('phone');
      Future<void> secure(
        _Device d,
        String remote,
        HubServer hub,
        int port,
      ) async {
        final token = await hub.auth.register(
          hub.auth.createPairingCode(),
          d.ws.device!.id,
          d.name,
        );
        d.engines[remote] = SyncEngine(
          workspace: d.ws,
          canvases: d.canvases,
          client: SyncClient(
            Uri.parse('http://127.0.0.1:$port'),
            token: token,
            crypto: key,
          ),
          remote: remote,
        );
      }

      await secure(ipad, '', pc!, pcPort);
      await secure(phone, '', pc!, pcPort);
      await secure(ipad, 'self', ipadHub!, ipadPort);
      await secure(phone, 'ipad', ipadHub!, ipadPort);
      await pc!.stop();
      pc = null;

      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawColor(const Color(0xFF35A99A), BlendMode.src);
      final image = await rec.endRecording().toImage(3, 2);
      final Uint8List png = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      final note = phone.ws.createNote(title: 'With photo', body: 'x');
      final photo = await phone.ws.imageAssetFromBytes(png, 'png');
      phone.ws.attachToNote(note.id, photo.id);

      await peerRound(ipad, phone);
      final onIpad = ipad.ws.assets[photo.id];
      expect(onIpad, isNotNull);
      expect(await ipad.ws.attachments.readBytes(onIpad!.file!), png);

      // The PC returns: a device that only knows the PC gets the photo too.
      pc = await startPc();
      await phone.sync('');
      await ipad.sync('');
      final laptop = await device('laptop');
      await secure(laptop, '', pc!, pcPort);
      await laptop.sync('');
      final onLaptop = laptop.ws.assets[photo.id];
      expect(onLaptop, isNotNull);
      expect(await laptop.ws.attachments.readBytes(onLaptop!.file!), png);
    },
  );
}
