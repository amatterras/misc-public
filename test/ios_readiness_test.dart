// iPhone/iPad behaviour that can be checked on Windows, with the native side
// SIMULATED: device identity after a restored backup, pairing from an iPad,
// sync when the app returns to the front, share-sheet limits and cleanup of
// picker copies. None of this proves the Swift code works (needs a Mac).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/json_file_store.dart';
import 'package:flutter_application_1/data/sync/sync_clock.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/capture_service.dart';
import 'package:flutter_application_1/features/settings/sync_section.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_application_1/sync/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

class FakeKeychain implements KeychainBackend {
  final values = <String, String>{};
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw PlatformException(code: 'keychain');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the local in-process hub
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(IosBridge.channelName);

  late Directory root;
  late Directory data;

  setUp(() {
    root = Directory.systemTemp.createTempSync('theapp_iosready_');
    data = Directory('${root.path}${sep}app')..createSync();
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'deviceModel' => 'iPad',
        _ => null,
      };
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    secretKeychain = null;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> app({bool ipad = false}) async {
    final ws = Workspace(data);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
      ios: ipad ? IosBridge() : null,
    );
    s.capture.fetchPreviews = false;
    await s.init();
    return s;
  }

  group('device identity with the Keychain', () {
    test('same device keeps its id; a restored copy gets a new one', () async {
      final keychain = FakeKeychain();
      final store = JsonFileStore(data);
      final first = await DeviceIdentity.loadOrCreate(
        store,
        keychain: keychain,
      );
      expect(keychain.values[DeviceIdentity.keychainKey], first.id);
      final again = await DeviceIdentity.loadOrCreate(
        store,
        keychain: keychain,
      );
      expect(again.id, first.id);

      // The same folder restored onto another iPad: its Keychain is empty.
      final other = FakeKeychain();
      final restored = await DeviceIdentity.loadOrCreate(
        store,
        keychain: other,
      );
      expect(restored.id, isNot(first.id));
      expect(other.values[DeviceIdentity.keychainKey], restored.id);
      final saved = await store.read('sync', 'device');
      expect(saved?['replaces'], first.id);
    });

    test('an existing id is bound on the first start with the Keychain, '
        'and nothing changes without one', () async {
      final store = JsonFileStore(data);
      final plain = await DeviceIdentity.loadOrCreate(store);
      expect((await store.read('sync', 'device'))?['keychain'], isNull);
      final keychain = FakeKeychain();
      final bound = await DeviceIdentity.loadOrCreate(
        store,
        keychain: keychain,
      );
      expect(bound.id, plain.id, reason: 'no needless new identity');
      expect((await store.read('sync', 'device'))?['keychain'], isTrue);
    });

    test('a Keychain that refuses writes does not change the id', () async {
      final store = JsonFileStore(data);
      final keychain = FakeKeychain()..failWrites = true;
      final a = await DeviceIdentity.loadOrCreate(store, keychain: keychain);
      final b = await DeviceIdentity.loadOrCreate(store, keychain: keychain);
      expect(b.id, a.id);
    });
  });

  group('pairing from iPhone/iPad', () {
    late HubServer hub;
    late Uri url;
    setUp(() async {
      hub = await HubServer.start(
        dir: Directory('${root.path}${sep}hub'),
        port: 0,
        dailyBackups: false,
      );
      url = Uri.parse('http://127.0.0.1:${hub.port}');
    });
    tearDown(() => hub.stop());

    test('127.0.0.1 is refused on an iPad with a plain explanation', () async {
      secretKeychain = FakeKeychain();
      final s = await app(ipad: true);
      final error = await s.pairWithHub(
        url.toString(),
        hub.auth.createPairingCode(),
      );
      expect(error, contains('Tailscale'));
      expect(s.syncPaired, isFalse);
      expect(hub.auth.devices, isEmpty, reason: 'nothing reached the hub');
      s.dispose();
    });

    test('a key that cannot be stored gives a message, not a stuck '
        'button', () async {
      secretKeychain = FakeKeychain()..failWrites = true;
      final s = await app();
      final error = await s.pairWithHub(
        url.toString(),
        hub.auth.createPairingCode(),
      );
      expect(error, contains('could not store its key'));
      expect(s.syncPaired, isFalse);
      expect(
        File('${data.path}${sep}sync${sep}hub.json').existsSync(),
        isFalse,
      );
      s.dispose();
    });

    test('restored backup without its Keychain key: asks to pair again, '
        'then works', () async {
      final keychain = FakeKeychain();
      secretKeychain = keychain;
      var s = await app();
      expect(
        await s.pairWithHub(url.toString(), hub.auth.createPairingCode()),
        isNull,
      );
      await s.syncNow();
      final oldId = s.workspace.device!.id;
      await s.flush();
      s.dispose();

      // Same files, other iPad: the Keychain does not come along.
      secretKeychain = FakeKeychain();
      s = await app();
      expect(s.workspace.device!.id, isNot(oldId));
      expect(s.syncPaired, isFalse);
      expect(s.syncNeedsPairing, isTrue);
      expect(s.syncStatus, contains('paired again'));
      expect(s.hubUrl, url.toString());

      expect(
        await s.pairWithHub(url.toString(), hub.auth.createPairingCode()),
        isNull,
      );
      expect(s.syncNeedsPairing, isFalse);
      await s.syncNow();
      expect(s.syncStatus, startsWith('Synced'));
      await s.flush();
      s.dispose();
    });

    test('coming back to the front syncs only when the last sync is '
        'not recent', () async {
      final s = await app();
      expect(
        await s.pairWithHub(url.toString(), hub.auth.createPairingCode()),
        isNull,
      );
      await s.syncNow();
      final first = s.lastSynced!;
      await s.appResumed();
      expect(s.lastSynced, first, reason: 'synced moments ago');

      s.lastSynced = first.subtract(AppState.resumeSyncAfter * 2);
      final note = s.workspace.createNote(title: 'Written before sleep');
      await s.appResumed();
      expect(s.lastSynced!.isAfter(first), isTrue);
      expect(
        (await hub.store.current('notes', note.id))?.data?['title'],
        'Written before sleep',
      );
      await s.flush();
      s.dispose();
    });
  });

  test('hub device name: the model replaces a generic host name', () {
    expect(AppState.hubDeviceName('localhost', 'iPad'), 'iPad');
    expect(AppState.hubDeviceName('My-iPad', 'iPad'), 'iPad (My-iPad)');
    expect(AppState.hubDeviceName('DESKTOP-1', null), 'DESKTOP-1');
  });

  test('pairing form address: empty on iPad, previous hub when re-pairing', () {
    expect(defaultHubAddress(onPhoneOrTablet: false), 'http://127.0.0.1:47710');
    expect(defaultHubAddress(onPhoneOrTablet: true), '');
    expect(
      defaultHubAddress(
        onPhoneOrTablet: true,
        previous: 'http://100.101.102.103:47710',
      ),
      'http://100.101.102.103:47710',
    );
  });

  testWidgets('re-pair notice and iPad help text are shown', (tester) async {
    late AppState s;
    await tester.runAsync(() async {
      // A paired device whose key is gone (as after a restore).
      final sync = Directory('${data.path}${sep}sync')
        ..createSync(recursive: true);
      File(
        '${sync.path}${sep}hub.json',
      ).writeAsStringSync(jsonEncode({'url': 'http://100.101.102.103:47710'}));
      File('${sync.path}${sep}hub.token')
          .writeAsStringSync(jsonEncode({'keychain': 'THEapp.hub.token'}));
      secretKeychain = FakeKeychain();
      s = await app(ipad: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncSection(state: s)),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('repair-notice')), findsOneWidget);
    expect(find.textContaining('Tailscale address'), findsOneWidget);
    expect(find.text('http://100.101.102.103:47710'), findsOneWidget);
    await tester.runAsync(() async {
      await s.flush();
      s.dispose();
    });
  });

  test('shared text is capped like links from outside', () async {
    final shared = Directory('${root.path}${sep}group');
    final requests = Directory('${shared.path}${sep}inbox_requests')
      ..createSync(recursive: true);
    File('${requests.path}${sep}big.json')
        .writeAsStringSync(jsonEncode({'type': 'text', 'value': 'x' * 50000}));
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'sharedContainer' ? shared.path : null,
    );
    final s = await app(ipad: true);
    final texts = s.workspace.inbox.all.map((i) => i.text ?? '');
    expect(texts.single.length, CaptureService.maxInboundText);
    s.dispose();
  });

  test('picker copies are removed after import, other files never', () async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    final tmp = Directory('${root.path}${sep}tmp')..createSync();
    final copy = File('${tmp.path}${sep}picked.jpg')..writeAsBytesSync(png);
    final pdfCopy = File('${tmp.path}${sep}Report.pdf')
      ..writeAsStringSync('%PDF-1.4\n% synthetic\n');
    final original = File('${root.path}${sep}mine.png')..writeAsBytesSync(png);
    final ws = Workspace(data);
    await ws.load();
    final capture = CaptureService(ws, fetchPreviews: false)
      ..pickerCopies = tmp
      ..pickImageFiles = (() => [copy.path, original.path])
      ..pickDocumentFiles = (() => [pdfCopy.path]);
    expect(await capture.pickImages(), hasLength(2));
    expect(await capture.pickDocuments(), hasLength(1));
    expect(copy.existsSync(), isFalse);
    expect(pdfCopy.existsSync(), isFalse);
    expect(original.existsSync(), isTrue, reason: 'outside the copy folder');
    expect(ws.attachments.dir.listSync(), isNotEmpty, reason: 'kept copies');
    ws.dispose();
  });
}
