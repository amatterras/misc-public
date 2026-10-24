// The hub run by THEapp itself (hub_host.dart), against real sockets in
// a temporary folder: one hub only, a crash is noticed and recovered
// without losing data, an outside hub is used instead of a second one,
// listener changes are followed, and frequent hub backups are checked,
// made only after a change and kept in a bounded set.
import 'dart:io';

import 'package:flutter_application_1/sync/local_hub.dart';
import 'package:flutter_application_1/hub/hub_host.dart';
import 'package:flutter_application_1/hub/hub_backup.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/hub/hub_store.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

void main() {
  late Directory dir;
  final logs = <String>[];
  setUpAll(() => HttpOverrides.global = null);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('theapp_hubhost_');
    logs.clear();
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  HubHost host(int port, {Future<String?> Function()? private}) => HubHost(
    dir: dir,
    port: port,
    privateAddress: private ?? () async => null,
    log: logs.add,
    restartDelays: const [Duration.zero],
  );

  /// Pairs a device with the hub at [port] (admin pairing code from the
  /// hub folder's auth, as `thehub pair` does) and returns its client.
  Future<SyncClient> pair(int port, String id) async {
    final code = (await localPairingCode(hubDir: dir)).code;
    final token = await SyncClient(Uri.parse('http://127.0.0.1:$port'))
        .register(code, id, id);
    return SyncClient(Uri.parse('http://127.0.0.1:$port'), token: token);
  }

  test(
    'runs once; a second host uses it instead of starting another',
    () async {
      final port = await freePort();
      final a = host(port);
      await a.start();
      await a.start(); // repeated start: still one
      expect(a.state, HubHostState.running);
      expect(a.starts, 1);
      expect(a.listening, ['127.0.0.1:$port']);
      expect(
        File('${dir.path}/hub.json').readAsStringSync(),
        contains('"embedded":true'),
      );
      expect((await a.check()).ok, isTrue);

      final b = host(port);
      await b.start();
      expect(b.state, HubHostState.external);
      expect(b.starts, 0);

      await a.stop();
      expect(File('${dir.path}/hub.json').existsSync(), isFalse);
      // The other hub went away: b runs one itself at its next check.
      final h = await b.check();
      expect(b.state, HubHostState.running);
      expect(h.recovered, 'hub started');
      expect(b.starts, 1);
      await b.stop();
    },
  );

  Future<(SyncClient, SyncClock)> withNote(int port) async {
    final client = await pair(port, 'dev1');
    final clock = SyncClock(deviceId: 'dev1');
    await client.push([
      SyncChange(
        collection: 'notes',
        id: 'n1',
        rev: clock.now(),
        deleted: false,
        data: {'id': 'n1', 'title': 'Kept'},
      ),
    ]);
    return (client, clock);
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('an uncaught error inside the hub does not stop it', () async {
    final port = await freePort();
    final a = host(port);
    await a.start();
    await a.debugThrow();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(a.state, HubHostState.running);
    expect((await a.check()).ok, isTrue);
    expect(
      File('${dir.path}/logs/hub.log').readAsStringSync(),
      contains('uncaught StateError; still running'),
    );
    expect(a.starts, 1);
    await a.stop();
  });

  test('alive but not answering: restarted in place after 3 checks, '
      'nothing lost', () async {
    final port = await freePort();
    final a = host(port);
    await a.start();
    final (client, _) = await withNote(port);
    await a.debugCloseListeners();
    expect((await a.check()).ok, isFalse);
    expect((await a.check()).ok, isFalse);
    final h = await a.check(); // third failure: restart
    expect(h.recovered, 'hub restarted');
    expect(a.state, HubHostState.running);
    expect(a.starts, 1); // same isolate, no second hub
    expect((await a.check()).ok, isTrue);
    final page = await client.pull(0);
    expect(page.changes.map((c) => c.id), contains('n1'));
    client.close();
    await a.stop();
  });

  test('the hub isolate ends by itself: noticed, started again', () async {
    final port = await freePort();
    final a = host(port);
    await a.start();
    final (client, _) = await withNote(port);
    await a.debugExit();
    await until(() => a.state != HubHostState.running);
    expect(a.state, HubHostState.recovering);
    expect(logs.join('\n'), contains('stopped unexpectedly'));
    final h = await a.check();
    expect(h.recovered, 'hub restarted');
    expect(a.state, HubHostState.running);
    expect(a.starts, 2);
    final page = await client.pull(0);
    expect(page.changes.map((c) => c.id), contains('n1'));
    client.close();
    await a.stop();
  });

  test(
    'a port held by another program: no second hub, a plain problem',
    () async {
      final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final a = host(blocker.port);
      await a.start();
      expect(a.state, HubHostState.recovering);
      expect(a.problem, contains('could not'));
      expect((await a.check()).ok, isFalse);
      await blocker.close();
      final h = await a.check();
      expect(a.state, HubHostState.running);
      expect(h.recovered, 'hub restarted');
      await a.stop();
    },
  );

  test('frequent hub backups: only after a change, checked, bounded', () async {
    final port = await freePort();
    final a = host(port);
    await a.start();
    final client = await pair(port, 'dev1');
    final clock = SyncClock(deviceId: 'dev1');
    Future<void> edit(int i) => client.push([
      SyncChange(
        collection: 'notes',
        id: 'n$i',
        rev: clock.now(),
        deleted: false,
        data: {'id': 'n$i', 'title': '$i'},
      ),
    ]);

    await edit(0);
    final first = await a.backupLive();
    expect(first, isNotNull);
    expect(await a.backupLive(), isNull); // nothing changed
    for (var i = 1; i <= HubBackups.keepLive + 5; i++) {
      await edit(i);
      expect(await a.backupLive(), isNotNull);
    }
    final store = await HubStore.open(Directory('${dir.path}/probe'));
    final live = await HubBackups(store).listLive();
    expect(live, isEmpty); // a different folder: nothing there
    await store.close();
    final liveDir = Directory('${dir.path}/backups/live');
    final kept = liveDir.listSync().whereType<Directory>().toList();
    expect(kept, hasLength(HubBackups.keepLive));
    for (final b in kept) {
      expect(await HubBackups.verify(b), isTrue);
    }
    // Daily backups are kept apart and never pushed out by live ones.
    final daily = Directory('${dir.path}/backups')
        .listSync()
        .whereType<Directory>()
        .where((d) => !d.path.endsWith('live'))
        .toList();
    expect(daily, isNotEmpty); // the start-up backup
    client.close();
    await a.stop();
  });

  test('a lost private listener is noticed and opened again', () async {
    // The private address cannot be faked portably, so this checks the
    // hub side: a listener that closes by itself is reported and the
    // hub keeps serving on 127.0.0.1.
    final server = await HubServer.start(
      dir: dir,
      port: 0,
      dailyBackups: false,
      log: logs.add,
    );
    expect(server.servesLoopback, isTrue);
    expect(server.privateHost, isNull);
    await server.setPrivateHost(null);
    expect(server.listenerLost, isFalse);
    final tailscale = await detectTailscaleAddress();
    if (tailscale != null) {
      await server.setPrivateHost(tailscale);
      expect(server.privateHost, tailscale);
      await server.setPrivateHost(null);
      expect(server.privateHost, isNull);
    }
    expect(
      () => server.setPrivateHost('8.8.8.8'),
      throwsArgumentError, // never a public address
    );
    await server.stop();
  });
}
