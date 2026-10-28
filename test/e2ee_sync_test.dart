// End-to-end encrypted sync and secure transport, against a real hub on
// 127.0.0.1. Unique canary strings are put in notes, titles, links,
// attachments and shares; the tests then look for them in everything the hub
// stores, in every byte that crossed the wire (through a recording proxy)
// and in every log line, and fail if a canary or a key is there.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_application_1/data/models/knowledge_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/app_log.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/e2ee.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_keys.dart';

final sep = Platform.pathSeparator;

const noteTitle = 'CANARY-NOTE-TITLE-4d1e';
const noteBody = 'CANARY-NOTE-BODY-9b27 private words';
const linkUrl = 'https://private.example/CANARY-URL-71ac?token=abc';
const fileName = 'CANARY-FILENAME-5f60.pdf';
const fileText = 'CANARY-ATTACHMENT-CONTENT-e913';
const shareTitle = 'CANARY-SHARE-TITLE-2c88';
const shareText = 'CANARY-SHARE-TEXT-b0d4';
const canaries = [
  noteTitle,
  noteBody,
  'CANARY-URL-71ac',
  'CANARY-FILENAME-5f60',
  fileText,
  shareTitle,
  shareText,
];

bool has(List<int> hay, String needle) {
  final n = utf8.encode(needle);
  outer:
  for (var i = 0; i + n.length <= hay.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (hay[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Every file under [dir] holding any of [needles].
Future<List<String>> leaks(Directory dir, Iterable<String> needles) async {
  final out = <String>[];
  if (!await dir.exists()) return out;
  await for (final e in dir.list(recursive: true)) {
    if (e is! File) continue;
    final bytes = await readSafe(e);
    for (final n in needles) {
      if (has(bytes, n)) out.add('${e.path.substring(dir.path.length)}: $n');
    }
  }
  return out;
}

/// A proxy between a device and the hub that keeps every byte that crosses.
class RecordingProxy {
  RecordingProxy._(this._server, this.target);

  final HttpServer _server;
  final Uri target;
  final requests =
      <({String method, String uri, String headers, List<int> body})>[];
  final responses = <List<int>>[];

  static Future<RecordingProxy> start(Uri target) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = RecordingProxy._(server, target);
    final client = HttpClient();
    server.listen((req) async {
      final body = <int>[];
      await for (final chunk in req) {
        body.addAll(chunk);
      }
      final headers = StringBuffer();
      req.headers.forEach((k, v) => headers.writeln('$k: ${v.join(',')}'));
      proxy.requests.add((
        method: req.method,
        uri: req.uri.toString(),
        headers: headers.toString(),
        body: body,
      ));
      final out = await client.openUrl(
        req.method,
        target.replace(path: req.uri.path, query: req.uri.query),
      );
      req.headers.forEach((k, v) {
        if (k != 'host' && k != 'content-length') {
          for (final x in v) {
            out.headers.add(k, x);
          }
        }
      });
      out.headers.contentLength = body.length;
      out.add(body);
      final res = await out.close();
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
      }
      proxy.responses.add(bytes);
      req.response
        ..statusCode = res.statusCode
        ..headers.contentType = res.headers.contentType;
      req.response.add(bytes);
      await req.response.close();
    });
    return proxy;
  }

  int get port => _server.port;
  Uri get url => Uri.parse('http://127.0.0.1:$port');

  /// Everything that crossed, as searchable bytes.
  List<int> get everything => [
    for (final r in requests)
      ...utf8.encode('${r.method} ${r.uri}\n${r.headers}'),
    for (final r in requests) ...r.body,
    for (final r in responses) ...r,
  ];

  Future<void> stop() => _server.close(force: true);
}

class Device {
  Device(this.ws, this.canvases, this.engine);
  final Workspace ws;
  final FileCanvasRepository canvases;
  final SyncEngine engine;
  Future<SyncReport> sync() => engine.syncOnce();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late HubServer hub;
  late Uri hubUrl;
  late RecordingProxy proxy;
  late List<String> hubLog;
  final tokens = <String, String>{};

  Future<Device> device(
    String name, {
    SyncCrypto? crypto,
    bool viaProxy = true,
    bool readOnly = false,
  }) async {
    final ws = Workspace(Directory('${root.path}$sep$name'));
    await ws.load();
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      ws.device!.id,
      name,
      readOnly: readOnly,
    );
    tokens[name] = token;
    final client = SyncClient(
      viaProxy ? proxy.url : hubUrl,
      token: token,
      crypto: crypto,
    );
    final canvases = FileCanvasRepository(ws.store);
    return Device(
      ws,
      canvases,
      SyncEngine(workspace: ws, canvases: canvases, client: client),
    );
  }

  Future<void> putCanaryData(Device d) async {
    d.ws.createNote(title: noteTitle, body: noteBody);
    d.ws.linkAsset(linkUrl, title: noteTitle);
    final pdf = File('${d.ws.root.path}$sep$fileName')
      ..writeAsBytesSync(utf8.encode('%PDF-1.4 $fileText'));
    await d.ws.documentAssetFromFile(pdf);
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_e2ee_');
    hubLog = [];
    AppLog.session.clear();
    hub = await HubServer.start(
      dir: Directory('${root.path}${sep}hub'),
      port: 0,
      dailyBackups: false,
      log: hubLog.add,
    );
    hubUrl = Uri.parse('http://127.0.0.1:${hub.port}');
    proxy = await RecordingProxy.start(hubUrl);
  });

  tearDown(() async {
    await proxy.stop();
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('the hub holds only ciphertext', () {
    test('notes, titles, links and attachments never appear on the hub, on '
        'the wire or in logs, and arrive intact on another device', () async {
      final a = await device('a', crypto: testSyncCrypto);
      final b = await device('b', crypto: testSyncCrypto);
      await putCanaryData(a);
      await a.sync();
      final report = await b.sync();
      expect(report.problems, isEmpty);

      // The other device (same workspace key) has everything, readable.
      expect(b.ws.notes.all.single.title, noteTitle);
      expect(b.ws.notes.all.single.body, noteBody);
      expect(b.ws.assets.all.where((x) => x.url == linkUrl), hasLength(1));
      final doc = b.ws.assets.all.firstWhere((x) => x.file != null);
      expect(
        utf8.decode(await b.ws.attachments.readBytes(doc.file!)),
        '%PDF-1.4 $fileText',
      );

      // What the hub stores: no canary in any file (journal, attachments,
      // devices, backups), and the journal holds sealed records only.
      await hub.backups.create();
      expect(await leaks(hub.store.dir, canaries), isEmpty);
      expect(await hub.store.countPlaintext(), 0);
      expect(hub.store.e2eeRequired, isTrue, reason: 'switched over');

      // What crossed the wire, both ways: no canary, no key.
      final wire = proxy.everything;
      for (final c in canaries) {
        expect(has(wire, c), isFalse, reason: 'wire leaked $c');
      }
      final keyText = [
        base64Encode(testSyncKey),
        base64Url.encode(testSyncKey).replaceAll('=', ''),
        testSyncKey.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
      ];
      for (final k in keyText) {
        expect(has(wire, k), isFalse, reason: 'the key crossed the wire');
        expect(await leaks(hub.store.dir, [k]), isEmpty);
      }

      // Logs (the hub's and the app's), including error paths.
      await a.engine.client
          .push([
            SyncChange(
              collection: 'notes',
              id: 'x',
              rev: '0001792610475963-0000-aaaa',
              deleted: false,
              data: {'title': noteTitle},
            ),
          ])
          .then((_) {}, onError: (_) {});
      final logs = [...hubLog, ...AppLog.session].join('\n');
      for (final c in canaries) {
        expect(logs, isNot(contains(c)), reason: 'log leaked $c');
      }
      for (final t in tokens.values) {
        expect(logs, isNot(contains(t)), reason: 'a device token is in a log');
      }
    });

    test(
      'a hub that requires encryption refuses plain records and files',
      () async {
        final a = await device('a', crypto: testSyncCrypto);
        await putCanaryData(a);
        await a.sync();
        expect(hub.store.e2eeRequired, isTrue);

        final plain = SyncClient(hubUrl, token: tokens['a']);
        addTearDown(plain.close);
        await expectLater(
          plain.push([
            SyncChange(
              collection: 'notes',
              id: 'plainnote',
              rev: '0001792610475963-0000-${a.ws.device!.id}',
              deleted: false,
              data: {'id': 'plainnote', 'title': noteTitle},
            ),
          ]),
          throwsA(
            isA<SyncFailure>().having(
              (e) => e.code,
              'code',
              'plaintext_rejected',
            ),
          ),
        );
        final body = utf8.encode('%PDF plain $fileText');
        final sha = sha256.convert(body).toString();
        final tmp = File('${root.path}${sep}plain.bin')..writeAsBytesSync(body);
        await expectLater(
          plain.upload(sha, tmp),
          throwsA(
            isA<SyncFailure>().having(
              (e) => e.code,
              'code',
              'plaintext_rejected',
            ),
          ),
        );
        expect(await hub.store.hasAttachment(sha), isFalse);
        // A sealed record with an extra plain field is refused too.
        final sealed = testSyncCrypto.seal(
          'notes',
          'n9',
          '0001792610475963-0000-aaaa',
          {'id': 'n9'},
        );
        expect(envelopeShapeOk('notes', {...sealed, 'title': 'leak'}), isFalse);
        expect(envelopeShapeOk('notes', sealed), isTrue);
      },
    );

    test('a ciphertext moved to another record or changed does not open', () {
      final one = testSyncCrypto.seal(
        'notes',
        'n1',
        '0001792610475963-0000-aaaa',
        {'title': noteTitle},
      );
      expect(
        () => testSyncCrypto.open(
          'notes',
          'n2',
          '0001792610475963-0000-aaaa',
          one,
        ),
        throwsA(anything),
        reason: 'another id',
      );
      expect(
        () => testSyncCrypto.open(
          'notes',
          'n1',
          '0001792610475964-0000-aaaa',
          one,
        ),
        throwsA(anything),
        reason: 'another revision',
      );
      expect(
        () => testSyncCrypto.open(
          'tasks',
          'n1',
          '0001792610475963-0000-aaaa',
          one,
        ),
        throwsA(anything),
        reason: 'another collection',
      );
      final other = SyncCrypto(Uint8List(32)..fillRange(0, 32, 9));
      expect(
        () => other.open('notes', 'n1', '0001792610475963-0000-aaaa', one),
        throwsA(anything),
        reason: 'another key',
      );
      final bytes = base64Decode(one['c'] as String)..[40] ^= 1;
      expect(
        () => testSyncCrypto.open('notes', 'n1', '0001792610475963-0000-aaaa', {
          ...one,
          'c': base64Encode(bytes),
        }),
        throwsA(anything),
        reason: 'changed byte',
      );
    });

    test('a device with another key, or a hub that swaps records, stops sync '
        'with an error instead of using the data', () async {
      final a = await device('a', crypto: testSyncCrypto);
      await putCanaryData(a);
      await a.sync();
      final stranger = await device(
        'stranger',
        crypto: SyncCrypto(Uint8List(32)..fillRange(0, 32, 5)),
      );
      await expectLater(
        stranger.sync(),
        throwsA(
          isA<SyncFailure>().having((e) => e.code, 'code', 'e2ee_unreadable'),
        ),
      );
      expect(stranger.ws.notes.all, isEmpty, reason: 'nothing was applied');

      // A hub (operator) that swaps two sealed records is detected.
      final notes = (await hub.store.changesSince(
        0,
        500,
      )).changes.where((c) => c.collection == 'notes').toList();
      final assets = (await hub.store.changesSince(
        0,
        500,
      )).changes.where((c) => c.collection == 'assets').toList();
      expect(notes, isNotEmpty);
      await hub.store.push('hubsw', [
        SyncChange(
          collection: 'notes',
          id: notes.first.id,
          rev: '0001999999999999-0000-hubsw',
          deleted: false,
          data: assets.first.data,
        ),
      ]);
      final b = await device('b', crypto: testSyncCrypto);
      await expectLater(
        b.sync(),
        throwsA(
          isA<SyncFailure>().having((e) => e.code, 'code', 'e2ee_unreadable'),
        ),
      );
    });
  });

  group('migrating a hub that holds plain data', () {
    test('everything is re-sent sealed, read back, and only then is the plain '
        'copy removed (records, files, old backups, links)', () async {
      // An older app (no key) filled the hub in plain text.
      final old = await device('old', viaProxy: false);
      await putCanaryData(old);
      old.ws.shares.put(
        ShareLink(
          id: 'a' * 64,
          kind: 'note',
          sourceId: 'n',
          title: shareTitle,
          body: shareText,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
      await old.sync();
      await hub.backups.create(); // a backup holding the plain records
      expect(await leaks(hub.store.dir, [noteTitle, fileText]), isNotEmpty);
      expect(hub.store.e2eeRequired, isFalse);
      expect(await hub.store.countPlaintext(), greaterThan(0));

      // The same device after updating: it has a key now.
      final updated = Device(
        old.ws,
        old.canvases,
        SyncEngine(
          workspace: old.ws,
          canvases: old.canvases,
          client: SyncClient(
            proxy.url,
            token: tokens['old'],
            crypto: testSyncCrypto,
          ),
        ),
      );
      final report = await updated.sync();
      expect(report.problems, isEmpty);

      expect(hub.store.e2eeRequired, isTrue);
      expect(await hub.store.countPlaintext(), 0);
      final left = await leaks(hub.store.dir, canaries);
      expect(left, isEmpty, reason: left.join('\n'));
      expect(
        await hub.backups.list(),
        hasLength(1),
        reason: 'old backups gone',
      );
      // Nothing was lost locally.
      expect(old.ws.notes.all.single.title, noteTitle);
      expect(old.ws.assets.all.where((a) => a.file != null), isNotEmpty);
      // The old share link (it has no key in its address) was retired.
      expect(old.ws.shares['a' * 64]!.revoked, isTrue);
      // A second device with the same key reads everything.
      final b = await device('b', crypto: testSyncCrypto);
      expect((await b.sync()).problems, isEmpty);
      expect(b.ws.notes.all.single.body, noteBody);
    });

    test(
      'the hub refuses to switch over while a plain record is left',
      () async {
        final old = await device('old', viaProxy: false);
        await putCanaryData(old);
        await old.sync();
        final keyed = SyncClient(
          hubUrl,
          token: tokens['old'],
          crypto: testSyncCrypto,
        );
        addTearDown(keyed.close);
        expect((await keyed.e2eeStatus()).plaintextRecords, greaterThan(0));
        await expectLater(
          keyed.commitEncryption(),
          throwsA(
            isA<SyncFailure>().having(
              (e) => e.code,
              'code',
              'plaintext_remaining',
            ),
          ),
        );
        expect(hub.store.e2eeRequired, isFalse, reason: 'nothing changed');
        expect(
          await leaks(hub.store.dir, [noteTitle]),
          isNotEmpty,
          reason: 'and nothing was claimed or removed',
        );
      },
    );
  });

  group('pairing delivers the key without the hub seeing it', () {
    test('the hub gets a one-way function of the code and a wrapped key '
        'only; a wrong code or a swapped key gives nothing', () async {
      final secret = PairingSecret.generate();
      hub.auth.createPairingOffer(
        registerCode: secret.registerCode,
        wrappedKey: secret.wrap(testSyncKey),
      );
      final client = SyncClient(proxy.url);
      addTearDown(client.close);
      final r = await client.registerWithKey(
        secret.registerCode,
        'newdevice',
        'iPad',
      );
      expect(r.wrappedKey, isNotNull);
      expect(secret.unwrap(r.wrappedKey!), testSyncKey);
      // The wire and the hub never held the code or the key.
      final wire = proxy.everything;
      for (final secretText in [
        secret.secret,
        secret.display,
        base64Encode(testSyncKey),
      ]) {
        expect(has(wire, secretText), isFalse, reason: secretText);
        expect(await leaks(hub.store.dir, [secretText]), isEmpty);
      }
      // Another code cannot open it; neither can a key the hub made up.
      final other = PairingSecret.generate();
      expect(other.unwrap(r.wrappedKey!), isNull);
      expect(secret.unwrap(other.wrap(Uint8List(32))), isNull);
      expect(secret.unwrap('not base64!'), isNull);
      // The code is typed back loosely.
      expect(
        PairingSecret.parse(secret.display.toLowerCase())?.secret,
        secret.secret,
      );
      expect(PairingSecret.parse('SHORT'), isNull);
    });

    test(
      'a signed-in device offers the key; another redeems it once',
      () async {
        final a = await device('a', crypto: testSyncCrypto);
        final b = await device('b', crypto: testSyncCrypto);
        final secret = PairingSecret.generate();
        await a.engine.client.offerPairing(
          secret.registerCode,
          secret.wrap(testSyncKey),
        );
        final wrapped = await b.engine.client.redeemPairing(
          secret.registerCode,
        );
        expect(secret.unwrap(wrapped), testSyncKey);
        await expectLater(
          b.engine.client.redeemPairing(secret.registerCode),
          throwsA(
            isA<SyncFailure>().having((e) => e.code, 'code', 'pairing_failed'),
          ),
          reason: 'one use only',
        );
        await expectLater(
          b.engine.client.redeemPairing(PairingSecret.generate().registerCode),
          throwsA(
            isA<SyncFailure>().having((e) => e.code, 'code', 'pairing_failed'),
          ),
        );
        expect(has(proxy.everything, secret.secret), isFalse);
        expect(has(proxy.everything, base64Encode(testSyncKey)), isFalse);
      },
    );

    test('an ordinary code after the switch-over gives a read-only device '
        '(a mirror never becomes writable)', () async {
      final a = await device('a', crypto: testSyncCrypto);
      await putCanaryData(a);
      await a.sync();
      expect(hub.store.e2eeRequired, isTrue);
      final client = SyncClient(hubUrl);
      addTearDown(client.close);
      final token = await client.register(
        hub.auth.createPairingCode(),
        'mirror1',
        'Raspberry Pi',
      );
      final mirror = SyncClient(hubUrl, token: token);
      addTearDown(mirror.close);
      expect((await mirror.pull(0, limit: 1)).lastSeq, greaterThan(0));
      await expectLater(
        mirror.push([
          SyncChange(
            collection: 'notes',
            id: 'x',
            rev: '0001792610475963-0000-mirror1',
            deleted: false,
            data: testSyncCrypto.seal(
              'notes',
              'x',
              '0001792610475963-0000-mirror1',
              {},
            ),
          ),
        ]),
        throwsA(isA<SyncFailure>().having((e) => e.code, 'code', 'read_only')),
      );
      // A device paired the ordinary way (not a mirror by name) is read-only.
      final phone = await client.register(
        hub.auth.createPairingCode(),
        'phone1',
        'Phone',
      );
      final p = SyncClient(hubUrl, token: phone);
      addTearDown(p.close);
      await expectLater(
        p.push([
          SyncChange(
            collection: 'notes',
            id: 'y',
            rev: '0001792610475963-0000-phone1',
            deleted: false,
            data: testSyncCrypto.seal(
              'notes',
              'y',
              '0001792610475963-0000-phone1',
              {},
            ),
          ),
        ]),
        throwsA(isA<SyncFailure>().having((e) => e.code, 'code', 'read_only')),
      );
    });

    test(
      'unauthorized and revoked devices get nothing, on every endpoint',
      () async {
        final a = await device('a', crypto: testSyncCrypto);
        await putCanaryData(a);
        await a.sync();
        for (final token in ['not-a-token', null]) {
          final c = SyncClient(hubUrl, token: token, crypto: testSyncCrypto);
          addTearDown(c.close);
          for (final call in <Future<Object?> Function()>[
            () => c.pull(0),
            () => c.push(const []),
            () => c.e2eeStatus(),
            () => c.commitEncryption(),
            () => c.redeemPairing('0' * 64),
            () => c.hasAttachment('0' * 64),
          ]) {
            await expectLater(
              call(),
              throwsA(
                isA<SyncFailure>().having(
                  (e) => e.code,
                  'code',
                  'unauthorized',
                ),
              ),
            );
          }
        }
        // Revoked: refused at once, including the long-lived session.
        final revokedClient = a.engine.client;
        await hub.auth.revoke(a.ws.device!.id);
        for (final call in <Future<Object?> Function()>[
          () => revokedClient.pull(0),
          () => revokedClient.e2eeStatus(),
          () => revokedClient.waitForChange(0, seconds: 1),
        ]) {
          await expectLater(
            call(),
            throwsA(
              isA<SyncFailure>().having((e) => e.code, 'code', 'unauthorized'),
            ),
          );
        }
      },
    );
  });

  group('conflicts and offline edits do not need the hub to read anything', () {
    test(
      'concurrent edits: the later one wins, the other is kept as a '
      'conflict that this device can open; the hub sees ciphertext',
      () async {
        final a = await device('a', crypto: testSyncCrypto);
        final b = await device('b', crypto: testSyncCrypto);
        final note = a.ws.createNote(title: 'start', body: 'base');
        await a.sync();
        await b.sync();
        // Both edit offline, then sync.
        a.ws.notes.put(a.ws.notes[note.id]!.copyWith(body: '$noteBody from A'));
        b.ws.notes.put(b.ws.notes[note.id]!.copyWith(body: '$noteBody from B'));
        await a.sync();
        await b.sync();
        await a.sync();
        await b.sync();
        final bodies = {a.ws.notes[note.id]!.body, b.ws.notes[note.id]!.body};
        expect(bodies, hasLength(1), reason: 'both devices agree');
        final kept = {
          for (final c in a.ws.conflicts.all)
            if (c.recordId == note.id) c.otherData?['body'],
          for (final c in b.ws.conflicts.all)
            if (c.recordId == note.id) c.otherData?['body'],
        };
        expect(
          {...bodies, ...kept},
          containsAll(['$noteBody from A', '$noteBody from B']),
          reason: 'neither edit is lost',
        );
        expect(await leaks(hub.store.dir, [noteBody]), isEmpty);
        expect(has(proxy.everything, noteBody), isFalse);
      },
    );

    test('offline edits wait, then go out sealed', () async {
      final a = await device('a', crypto: testSyncCrypto);
      await a.sync();
      a.ws.createNote(title: noteTitle, body: noteBody);
      // (offline: nothing is sent until the next sync)
      expect(await leaks(hub.store.dir, [noteTitle]), isEmpty);
      await a.sync();
      expect(
        (await hub.store.changesSince(
          0,
          500,
        )).changes.where((c) => c.collection == 'notes'),
        isNotEmpty,
      );
      expect(await leaks(hub.store.dir, [noteTitle]), isEmpty);
    });
  });

  group('share links', () {
    test('the hub serves ciphertext; the key is in the fragment only; revoked '
        'and expired links vanish; vault content cannot be shared', () async {
      final a = await device('a', crypto: testSyncCrypto);
      final seal = ShareSeal.seal(shareTitle, shareText);
      final token = base64Url.encode(List.filled(32, 3)).replaceAll('=', '');
      final id = sha256.convert(utf8.encode(token)).toString();
      ShareLink link({bool revoked = false, DateTime? expires}) => ShareLink(
        id: id,
        kind: 'note',
        sourceId: 'n',
        title: shareTitle,
        body: shareText,
        createdAt: DateTime(2026),
        updatedAt: DateTime.now(),
        expiresAt: expires,
        revoked: revoked,
        sealed: revoked ? null : seal.ciphertext,
      );
      a.ws.shares.put(link());
      await a.sync();

      Future<(int, String)> fetch() async {
        final http = HttpClient();
        try {
          // A browser never sends the #fragment: only the path goes.
          final res = await (await http.getUrl(
            proxy.url.replace(path: '/s/$token'),
          )).close();
          return (res.statusCode, await utf8.decodeStream(res));
        } finally {
          http.close();
        }
      }

      final (status, html) = await fetch();
      expect(status, 200);
      expect(html, contains(seal.ciphertext));
      for (final c in [shareTitle, shareText, seal.key]) {
        expect(html, isNot(contains(c)));
      }
      // Hub storage and logs: no title, no text, no key.
      expect(
        await leaks(hub.store.dir, [shareTitle, shareText, seal.key]),
        isEmpty,
      );
      final logs = hubLog.join('\n');
      expect(logs, isNot(contains(seal.key)));
      expect(logs, isNot(contains(token)));
      expect(logs, contains('/s/:token'));
      // Nothing sent to the hub carries the key.
      expect(has(proxy.everything, seal.key), isFalse);

      // Expiry and revocation: the same "not available" as an unknown link.
      a.ws.shares.put(link(expires: DateTime(2020)));
      await a.sync();
      final expired = await fetch();
      a.ws.shares.put(link(revoked: true));
      await a.sync();
      final revoked = await fetch();
      expect(expired.$1, 404);
      expect(revoked.$1, 404);
      expect(revoked.$2, expired.$2);
      expect(revoked.$2, isNot(contains(seal.ciphertext)));
    });
  });

  group('secure transport', () {
    test('plain http over a network is refused before anything is sent', () {
      for (final url in [
        'http://192.168.1.20:47710',
        'http://10.0.0.5:47710',
      ]) {
        expect(
          () => SyncClient(Uri.parse(url), token: 'secret-token'),
          throwsA(
            isA<SyncFailure>().having(
              (e) => e.code,
              'code',
              'insecure_transport',
            ),
          ),
        );
      }
    });

    test(
      'the hub itself refuses to listen on a home network without HTTPS',
      () async {
        final lan = [
          for (final i in await NetworkInterface.list(includeLoopback: false))
            for (final a in i.addresses)
              if (a.type == InternetAddressType.IPv4 &&
                  isAllowedBindAddress(a) &&
                  !isPlainHttpAddress(a))
                a.address,
        ].firstOrNull;
        if (lan == null) {
          markTestSkipped('This computer has no home-network address.');
          return;
        }
        await expectLater(
          HubServer.start(
            dir: Directory('${root.path}${sep}hub2'),
            port: 0,
            dailyBackups: false,
            privateHost: lan,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => '$e',
              'message',
              contains('HTTPS'),
            ),
          ),
        );
      },
    );

    group('certificates', () {
      late HttpServer tls;
      late String pin;
      late Uri url;

      setUp(() async {
        final context = SecurityContext()
          ..useCertificateChain('test/support/tls/hub_cert.pem')
          ..usePrivateKey('test/support/tls/hub_key.pem');
        tls = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          context,
        );
        tls.listen((r) async {
          r.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'service': 'THEapp hub',
                'hubId': 'x',
                'protocol': 1,
              }),
            );
          await r.response.close();
        });
        url = Uri.parse('https://127.0.0.1:${tls.port}');
        final pem = File('test/support/tls/hub_cert.pem').readAsStringSync();
        final der = base64Decode(
          pem
              .replaceAll(RegExp(r'-----[A-Z ]+-----'), '')
              .replaceAll(RegExp(r'\s'), ''),
        );
        pin = sha256.convert(der).toString();
      });
      tearDown(() => tls.close(force: true));

      test(
        'an untrusted certificate is refused, never accepted silently',
        () async {
          final c = SyncClient(url);
          addTearDown(c.close);
          await expectLater(
            c.status(),
            throwsA(
              isA<SyncFailure>()
                  .having((e) => e.code, 'code', 'certificate_rejected')
                  .having((e) => e.retryable, 'retryable', isFalse),
            ),
          );
        },
      );

      test('only the pinned certificate is accepted', () async {
        final good = SyncClient(url, pinnedCertSha256: pin);
        addTearDown(good.close);
        expect((await good.status())['service'], 'THEapp hub');
        final wrong = SyncClient(url, pinnedCertSha256: '0' * 64);
        addTearDown(wrong.close);
        await expectLater(
          wrong.status(),
          throwsA(
            isA<SyncFailure>().having(
              (e) => e.code,
              'code',
              'certificate_rejected',
            ),
          ),
        );
      });

      test(
        'a pin made from the pairing code only takes a matching certificate',
        () async {
          expect(await fetchPinnedCertificate(url, pin.substring(0, 16)), pin);
          expect(await fetchPinnedCertificate(url, 'ffffffffffffffff'), isNull);
          final secret = PairingSecret.generate(certSha256: pin);
          expect(
            PairingSecret.parse(secret.display)?.certPrefix,
            pin.substring(0, 16),
          );
          expect(secret.display, contains('.'));
        },
      );
    });
  });
}
