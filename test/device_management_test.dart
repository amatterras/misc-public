// Device management: the list, removal enforced by the hub (including held
// connections), roles that cannot be changed, and the workspace key change
// that follows a removal. Real hub on 127.0.0.1, several simulated devices.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/storage_encryption.dart'
    show DecryptionFailure, FileCipher;
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/device_keys.dart';
import 'package:flutter_application_1/sync/e2ee.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_keys.dart';

final sep = Platform.pathSeparator;

class Dev {
  Dev(this.name, this.ws, this.engine, this.token, this.key);
  final String name;
  final Workspace ws;
  final SyncEngine engine;
  final String token;
  final DeviceKeyPair key;
  SyncClient get client => engine.client;
  String get id => ws.device!.id;
  Future<SyncReport> sync() => engine.syncOnce();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late HubServer hub;
  late Uri url;
  final logs = <String>[];

  Future<Dev> dev(
    String name, {
    bool readOnly = false,
    bool keyed = true,
  }) async {
    final ws = Workspace(Directory('${root.path}$sep$name'));
    await ws.load();
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      ws.device!.id,
      name,
      readOnly: readOnly,
    );
    // Each device holds its own copy of the keys (as after pairing).
    final crypto = keyed ? SyncCrypto(Uint8List.fromList(testSyncKey)) : null;
    final canvases = FileCanvasRepository(ws.store);
    final engine = SyncEngine(
      workspace: ws,
      canvases: canvases,
      client: SyncClient(url, token: token, crypto: crypto),
    );
    final key = DeviceKeyPair.generate();
    if (keyed) {
      engine
        ..deviceKey = key
        ..saveKeys = (_) async {};
    }
    return Dev(name, ws, engine, token, key);
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_devices_');
    logs.clear();
    hub = await HubServer.start(
      dir: Directory('${root.path}${sep}hub'),
      port: 0,
      dailyBackups: false,
      log: logs.add,
    );
    url = Uri.parse('http://127.0.0.1:${hub.port}');
  });

  tearDown(() async {
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'the list shows every device, its role and when it was last seen',
    () async {
      final a = await dev('a');
      final mirror = await dev('mirror1', readOnly: true, keyed: false);
      await a.sync();
      await mirror.client.pull(0, limit: 1);
      final info = await a.client.devices();
      expect(info.self, a.id);
      final byName = {for (final d in info.devices) d.name: d};
      expect(byName.keys, containsAll(['a', 'mirror1']));
      expect(byName['a']!.readOnly, isFalse);
      expect(byName['mirror1']!.readOnly, isTrue);
      expect(byName['a']!.lastSeen, isNotNull);
      expect(byName['mirror1']!.lastSeen, isNotNull);
      expect(byName['a']!.revoked, isFalse);
      expect(byName['a']!.publicKey, a.key.publicBase64, reason: 'published');
    },
  );

  test('removal is enforced by the hub on the very next request, on every '
      'endpoint, and ends a connection that is being held', () async {
    final a = await dev('a');
    final victim = await dev('victim');
    await a.sync();
    await victim.sync();
    final seq = (await victim.client.pull(0, limit: 1)).lastSeq;

    // The victim is holding a long-poll when it is removed.
    final held = victim.client.waitForChange(seq, seconds: 20);
    final heldResult = held.then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final watch = Stopwatch()..start();
    expect(await a.client.revokeDevice(victim.id), isTrue);
    final end = await heldResult;
    expect(
      end,
      isA<SyncFailure>().having((e) => e.code, 'code', 'unauthorized'),
    );
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'not held to its timeout',
    );

    for (final call in <Future<Object?> Function()>[
      () => victim.client.pull(0),
      () => victim.client.push(const []),
      () => victim.client.devices(),
      () => victim.client.keysSince(1),
      () => victim.client.e2eeStatus(),
      () => victim.client.hasAttachment('0' * 64),
      () => victim.client.waitForChange(0, seconds: 1),
    ]) {
      await expectLater(
        call(),
        throwsA(
          isA<SyncFailure>().having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
    }
    final listed = (await a.client.devices()).devices.firstWhere(
      (d) => d.id == victim.id,
    );
    expect(listed.revoked, isTrue);
    // Removing it again, or something that is not there, changes nothing.
    expect(await a.client.revokeDevice(victim.id), isTrue);
    expect(await a.client.revokeDevice('nobody'), isFalse);
  });

  test('a read-only device can neither remove devices nor change keys, and '
      'no request can make it writable', () async {
    final a = await dev('a');
    await a.sync();
    final mirror = await dev('mirror2', readOnly: true, keyed: false);
    final m = mirror.client;
    for (final call in <Future<Object?> Function()>[
      () => m.revokeDevice(a.id),
      () => m.rotateKeys(2, const {}),
      () => m.commitEncryption(),
      () => m.offerPairing('0' * 64, 'x'),
    ]) {
      await expectLater(
        call(),
        throwsA(isA<SyncFailure>().having((e) => e.code, 'code', 'read_only')),
      );
    }
    expect(
      (await a.client.devices()).devices
          .firstWhere((d) => d.name == 'mirror2')
          .readOnly,
      isTrue,
    );
    expect(
      hub.auth.devices.firstWhere((d) => d.name == 'mirror2').readOnly,
      isTrue,
    );
    expect(await a.client.revokeDevice(a.id), isTrue);
    expect(
      hub.auth.devices.firstWhere((d) => d.name == 'mirror2').readOnly,
      isTrue,
    );
  });

  group('the workspace key changes when a device is removed', () {
    test('the others get the new key without typing anything; the removed '
        'device and the hub never do', () async {
      final a = await dev('a');
      final b = await dev('b');
      final victim = await dev('victim');
      final mirror = await dev('mirror3', readOnly: true, keyed: false);
      await a.sync();
      await b.sync();
      await victim.sync();
      expect(a.client.crypto!.current, 1);

      expect(await a.client.revokeDevice(victim.id), isTrue);
      final rotated = await a.engine.rotateKey();
      expect(rotated.epoch, 2);
      expect(rotated.notUpdated, isEmpty, reason: 'the mirror holds no key');
      expect(a.client.crypto!.current, 2);

      // New content is sealed under the new key.
      const secret = 'CANARY-AFTER-REMOVAL-77a1';
      a.ws.createNote(title: secret, body: 'new');
      await a.sync();
      final changes = (await hub.store.changesSince(
        0,
        500,
      )).changes.where((c) => c.collection == 'notes').toList();
      final fresh = changes.last;
      expect(SyncCrypto.epochOf(fresh.data!), 2);
      expect(
        utf8.decode(utf8.encode(jsonEncode(fresh.data))),
        isNot(contains(secret)),
      );

      // B takes the key in on its next sync and reads the new note.
      final report = await b.sync();
      expect(report.problems, isEmpty);
      expect(b.client.crypto!.current, 2);
      expect(b.ws.notes.all.map((n) => n.title), contains(secret));

      // The removed device (still holding the old key) cannot open it...
      final old = SyncCrypto(Uint8List.fromList(testSyncKey));
      expect(() => old.openChange(fresh), throwsA(isA<MissingEpochKey>()));
      // ...nor can anyone who guesses the epoch: the key is not derived.
      final guessed = SyncCrypto.epochs({
        1: Uint8List.fromList(testSyncKey),
        2: Uint8List.fromList(testSyncKey),
      }, current: 2);
      expect(
        () => guessed.openChange(fresh),
        throwsA(isA<DecryptionFailure>()),
      );

      // The hub holds only wrapped keys it cannot open.
      final wraps = hub.store.wrapsFor(b.id, 1);
      expect(wraps.single.epoch, 2);
      expect(
        unwrapRotatedKey(
          device: DeviceKeyPair.generate(),
          epoch: 2,
          deviceId: b.id,
          wrapped: wraps.single.wrapped,
          firstWorkspaceKey: Uint8List.fromList(testSyncKey),
        ),
        isNull,
        reason: 'only B\'s own device key opens it',
      );
      expect(hub.store.wrapsFor(victim.id, 1), isEmpty);
      expect(hub.store.wrapsFor(mirror.id, 1), isEmpty);
      final onDisk = await Future.wait([
        for (final f
            in hub.store.dir.listSync(recursive: true).whereType<File>())
          readSafe(f),
      ]);
      final keyB64 = base64Encode(a.client.crypto!.exportKey());
      for (final bytes in onDisk) {
        expect(latin1.decode(bytes), isNot(contains(keyB64)));
      }
    });

    test('a device that has not taken the new key in cannot write under the '
        'old one', () async {
      final a = await dev('a');
      final b = await dev('b');
      final victim = await dev('victim');
      await a.sync();
      await b.sync();
      await victim.sync();
      await a.client.revokeDevice(victim.id);
      await a.engine.rotateKey();
      b.ws.createNote(title: 'written with the old key', body: '');
      // B pushes directly, before it fetched the key: refused, retryable.
      await expectLater(
        SyncEngine(
          workspace: b.ws,
          canvases: FileCanvasRepository(b.ws.store),
          client: b.client,
        ).localVersions().then(
          (v) => b.client.push([
            v.values.firstWhere((c) => c.collection == 'notes'),
          ]),
        ),
        throwsA(
          isA<SyncFailure>()
              .having((e) => e.code, 'code', 'stale_key')
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      // After a normal sync (which fetches the key) it works again.
      final r = await b.sync();
      expect(r.problems, isEmpty);
      expect(b.client.crypto!.current, 2);
      expect(
        (await hub.store.changesSince(0, 500)).changes.any(
          (c) =>
              c.collection == 'notes' && SyncCrypto.epochOf(c.data ?? {}) == 2,
        ),
        isTrue,
      );
    });

    test('a key change that was not made by a holder of the workspace key '
        '(a hub that wraps one of its own) is refused', () async {
      final a = await dev('a');
      final b = await dev('b');
      await a.sync();
      await b.sync();
      // The "hub operator" wraps its own key for B's public key.
      final attackerKey = FileCipher.randomBytes(32);
      await hub.store.rotateKeys(2, {
        b.id: wrapRotatedKey(
          recipientPublic: b.key.publicBytes,
          epoch: 2,
          deviceId: b.id,
          newKey: attackerKey,
          firstWorkspaceKey: FileCipher.randomBytes(
            32,
          ), // it does not have ours
        ),
      });
      final r = await b.sync();
      expect(r.problems.join(), contains('could not be verified'));
      expect(
        b.client.crypto!.current,
        1,
        reason: 'the forged key was not used',
      );
    });

    test('a device whose key the hub cannot vouch for is named, not skipped '
        'silently', () async {
      final a = await dev('a');
      final nokey = await dev('nokey', keyed: false); // never published a key
      await a.sync();
      await nokey.client.pull(0, limit: 1);
      final r = await a.engine.rotateKey();
      expect(r.notUpdated, ['nokey']);
    });
  });

  test('logs name no device, key or token', () async {
    final a = await dev('a');
    final victim = await dev('victim');
    await a.sync();
    await a.client.revokeDevice(victim.id);
    await a.engine.rotateKey();
    final text = logs.join('\n');
    expect(text, isNot(contains(a.token)));
    expect(text, isNot(contains(victim.token)));
    expect(text, isNot(contains(base64Encode(testSyncKey))));
    expect(text, isNot(contains(victim.id)));
    expect(text, contains('Workspace key changed'));
  });
}
