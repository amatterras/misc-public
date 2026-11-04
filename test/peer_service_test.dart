// Direct sync between two devices with no pairing code: one hosts a hub of
// its own (PeerHost), the other finds it (PeerDiscovery), proves it holds the
// workspace key (PeerTrust) and syncs (PeerSyncService). Real HTTP on
// 127.0.0.1; discovery is announced by hand because Bonjour needs a device.
import 'dart:io';

import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/sync/e2ee.dart';
import 'package:flutter_application_1/sync/peer_discovery.dart';
import 'package:flutter_application_1/sync/peer_sync.dart';
import 'package:flutter_application_1/sync/peer_trust.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Dev {
  _Dev(this.ws, this.canvases);
  final Workspace ws;
  final FileCanvasRepository canvases;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  final key = SyncCrypto.generate();
  late PeerTrust trust;
  final started = <PeerHost>[];

  Future<_Dev> device(String name) async {
    final ws = Workspace(
      Directory('${root.path}${Platform.pathSeparator}$name'),
    );
    await ws.load();
    return _Dev(ws, FileCanvasRepository(ws.store));
  }

  PeerHost host(_Dev d, {PeerTrust? as}) {
    final h = PeerHost(
      workspace: d.ws,
      canvases: d.canvases,
      crypto: key,
      trust: as ?? trust,
    );
    started.add(h);
    return h;
  }

  PeerSyncService service(
    _Dev d,
    ManualPeerDiscovery discovery, {
    PeerTrust? as,
    PeerTokenStore? tokens,
    Duration retryAfter = const Duration(seconds: 30),
  }) => PeerSyncService(
    workspace: d.ws,
    canvases: d.canvases,
    discovery: discovery,
    trust: as ?? trust,
    crypto: key,
    tokens: tokens ?? MemoryPeerTokens(),
    deviceName: 'phone',
    retryAfter: retryAfter,
  );

  PeerAnnouncement announceOf(_Dev d, int port, {String? tag}) =>
      PeerAnnouncement(
        deviceId: d.ws.device!.id,
        name: 'ipad',
        host: '127.0.0.1',
        port: port,
        tag: tag ?? trust.tag,
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('theapp_peers_');
    trust = PeerTrust(key.exportKey());
  });

  tearDown(() async {
    for (final h in started) {
      await h.stop();
    }
    started.clear();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('two devices sync both ways with no pairing code', () async {
    final ipad = await device('ipad');
    final phone = await device('phone');
    final ipadHost = host(ipad);
    final port = await ipadHost.start();
    final discovery = ManualPeerDiscovery();
    final peers = service(phone, discovery);
    await peers.start();
    addTearDown(peers.stop);

    ipad.ws.createNote(title: 'On the iPad', body: 'a');
    phone.ws.createNote(title: 'On the phone', body: 'b');
    await ipadHost.syncSelf();
    discovery.announce(announceOf(ipad, port));
    await Future<void>.delayed(Duration.zero);
    expect(peers.peers, isNotEmpty);

    final outcome = (await peers.syncAll()).single;
    expect(outcome.ok, isTrue, reason: outcome.error);
    await ipadHost.syncSelf();

    Set<String> titles(_Dev d) => {for (final n in d.ws.notes.all) n.title};
    expect(titles(ipad), {'On the iPad', 'On the phone'});
    expect(titles(phone), {'On the iPad', 'On the phone'});
  });

  test('a device from another workspace is never even tried', () async {
    final ipad = await device('ipad');
    final phone = await device('phone');
    final port = await host(ipad).start();
    final discovery = ManualPeerDiscovery();
    final peers = service(phone, discovery);
    await peers.start();
    addTearDown(peers.stop);
    discovery.announce(announceOf(ipad, port, tag: 'ffffffffffffffff'));
    await Future<void>.delayed(Duration.zero);
    discovery.announce(announceOf(phone, port)); // this device itself
    expect(peers.peers, isEmpty);
    await Future<void>.delayed(Duration.zero);
  });

  test('a device that does not hold the key is refused, not retried', () async {
    final ipad = await device('ipad');
    final intruder = await device('intruder');
    final port = await host(ipad).start();
    final wrong = PeerTrust(SyncCrypto.generate().exportKey());
    final discovery = ManualPeerDiscovery();
    // The intruder copies the right tag but does not have the key.
    final peers = service(intruder, discovery, as: wrong);
    await peers.start();
    addTearDown(peers.stop);
    discovery.announce(announceOf(ipad, port, tag: wrong.tag));
    await Future<void>.delayed(Duration.zero);
    final outcome = await peers.syncPeer(ipad.ws.device!.id);
    expect(outcome.ok, isFalse);
    expect(outcome.retryable, isFalse);
    expect(intruder.ws.notes.length, 0);
    expect(ipad.ws.notes.length, 0);
  });

  test('a captured proof cannot be used twice', () async {
    final ipad = await device('ipad');
    final port = await host(ipad).start();
    final proof = trust.proof('someotherdev1', 'phone');
    final first = SyncClient(Uri.parse('http://127.0.0.1:$port'));
    expect(await first.peerJoin(proof), isNotEmpty);
    final second = SyncClient(Uri.parse('http://127.0.0.1:$port'));
    await expectLater(second.peerJoin(proof), throwsA(isA<SyncFailure>()));
  });

  test('an old proof is refused', () async {
    final ipad = await device('ipad');
    final port = await host(ipad).start();
    final old = PeerTrust(
      key.exportKey(),
      clock: () => DateTime.now().subtract(const Duration(minutes: 20)),
    );
    final client = SyncClient(Uri.parse('http://127.0.0.1:$port'));
    await expectLater(
      client.peerJoin(old.proof('someotherdev2', 'phone')),
      throwsA(isA<SyncFailure>()),
    );
  });

  test('a token the peer forgot is replaced by joining again', () async {
    final ipad = await device('ipad');
    final phone = await device('phone');
    final port = await host(ipad).start();
    final tokens = MemoryPeerTokens();
    await tokens.write(ipad.ws.device!.id, 'not-a-real-token');
    final discovery = ManualPeerDiscovery();
    final peers = service(phone, discovery, tokens: tokens);
    await peers.start();
    addTearDown(peers.stop);
    discovery.announce(announceOf(ipad, port));
    await Future<void>.delayed(Duration.zero);
    phone.ws.createNote(title: 'Hello', body: 'x');
    final outcome = await peers.syncPeer(ipad.ws.device!.id);
    expect(outcome.ok, isTrue, reason: outcome.error);
    expect(await tokens.read(ipad.ws.device!.id), isNot('not-a-real-token'));
  });

  test('an unreachable peer is retried later; changes wait locally', () async {
    final ipad = await device('ipad');
    final phone = await device('phone');
    final ipadHost = host(ipad);
    final port = await ipadHost.start();
    final discovery = ManualPeerDiscovery();
    final peers = service(
      phone,
      discovery,
      retryAfter: const Duration(hours: 1),
    );
    await peers.start();
    addTearDown(peers.stop);
    discovery.announce(announceOf(ipad, port));
    await Future<void>.delayed(Duration.zero);
    await peers.syncPeer(ipad.ws.device!.id); // joins and syncs once
    await ipadHost.stop(); // the iPad goes away (app closed)

    phone.ws.createNote(title: 'Written meanwhile', body: 'x');
    final failed = await peers.syncPeer(ipad.ws.device!.id);
    expect(failed.ok, isFalse);
    expect(failed.retryable, isTrue);
    // Left alone until it is announced again (or forced).
    final skipped = await peers.syncPeer(ipad.ws.device!.id);
    expect(skipped.error, 'Waiting to retry.');
    expect(phone.ws.notes.length, 1, reason: 'nothing lost');

    // The iPad comes back (a new port, as after a restart) and is announced.
    final again = host(ipad);
    final newPort = await again.start();
    await again.syncSelf();
    discovery.announce(announceOf(ipad, newPort));
    await Future<void>.delayed(Duration.zero);
    final ok = await peers.syncPeer(ipad.ws.device!.id);
    expect(ok.ok, isTrue, reason: ok.error);
    await again.syncSelf();
    expect({for (final n in ipad.ws.notes.all) n.title}, {'Written meanwhile'});
  });

  test('a peer that goes away is forgotten', () async {
    final ipad = await device('ipad');
    final phone = await device('phone');
    final port = await host(ipad).start();
    final discovery = ManualPeerDiscovery();
    final peers = service(phone, discovery);
    await peers.start();
    addTearDown(peers.stop);
    discovery.announce(announceOf(ipad, port));
    await Future<void>.delayed(Duration.zero);
    expect(peers.peers, hasLength(1));
    discovery.withdraw(ipad.ws.device!.id);
    await Future<void>.delayed(Duration.zero);
    expect(peers.peers, isEmpty);
    expect((await peers.syncPeer(ipad.ws.device!.id)).ok, isFalse);
  });
}
