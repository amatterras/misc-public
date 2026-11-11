import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_application_1/hub/hub_auth.dart';
import 'package:flutter_application_1/hub/hub_backup.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/hub/hub_store.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_application_1/sync/e2ee.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/secret_store.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

SyncClock clockFor(String device, [int start = 1000]) {
  var t = start;
  return SyncClock(deviceId: device, wallClock: () => t += 10);
}

SyncChange note(SyncClock clock, String id, String body, {String? base}) =>
    SyncChange(
      collection: 'notes',
      id: id,
      rev: clock.now(),
      deleted: false,
      data: {'id': id, 'title': 'T', 'body': body},
      baseRev: base,
    );

SyncChange deletion(SyncClock clock, String id, {String? base}) => SyncChange(
  collection: 'notes',
  id: id,
  rev: clock.now(),
  deleted: true,
  baseRev: base,
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_hub_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('store', () {
    test('apply, retry, cursor and paging', () async {
      final store = await HubStore.open(dir);
      final a = clockFor('aaaa');
      final changes = [for (var i = 0; i < 5; i++) note(a, 'n$i', 'body $i')];
      final r1 = await store.push('aaaa', changes);
      expect(r1.map((r) => r.status), everyElement(PushStatus.applied));
      expect(store.lastSeq, 5);

      // Sending the same batch again changes nothing.
      final r2 = await store.push('aaaa', changes);
      expect(r2.map((r) => r.status), everyElement(PushStatus.duplicate));
      expect(store.lastSeq, 5);

      final p1 = await store.changesSince(0, 2);
      expect(p1.changes.map((c) => c.id), ['n0', 'n1']);
      expect(p1.hasMore, isTrue);
      final p2 = await store.changesSince(p1.next, 10);
      expect(p2.changes.map((c) => c.id), ['n2', 'n3', 'n4']);
      expect(p2.hasMore, isFalse);
      expect((await store.changesSince(p2.next, 10)).changes, isEmpty);
      await store.close();
    });

    test('a device may not send edits as another device; re-offers follow the rules', () async {
      final store = await HubStore.open(dir);
      final a = clockFor('aaaa', 1000);
      final first = note(a, 'x', 'v1');
      await store.push('aaaa', [first]);
      // An *edit* (with a base) claiming another device's revision: refused.
      expect(
        () => store.push('bbbb', [
          note(clockFor('aaaa', 9000), 'x', 'forged', base: first.rev),
        ]),
        throwsA(isA<ProtocolException>()),
      );
      // Re-offering (no base) a version the hub already has: a duplicate.
      expect(
        (await store.push('bbbb', [first])).single.status,
        PushStatus.duplicate,
      );
      // Re-offering a record the hub lost: it is filled back in.
      final lost = note(clockFor('cccc', 2000), 'y', 'only on devices');
      expect(
        (await store.push('bbbb', [lost])).single.status,
        PushStatus.applied,
      );
      // Re-offering an OLDER version never overwrites the newer one.
      final newer = note(a, 'x', 'v2', base: first.rev);
      await store.push('aaaa', [newer]);
      final stale = (await store.push('bbbb', [first])).single;
      expect(stale.status, PushStatus.keptServer);
      expect((await store.current('notes', 'x'))!.data!['body'], 'v2');
      await store.close();
    });

    test(
      'a lost reply followed by a new edit replaces it without a conflict copy',
      () async {
        final store = await HubStore.open(dir);
        final a = clockFor('aaaa');
        final v1 = note(a, 'n', 'v1');
        await store.push('aaaa', [v1]);
        final v2 = note(a, 'n', 'v2', base: v1.rev);
        await store.push('aaaa', [v2]); // the device never got this reply
        final v3 = note(a, 'n', 'v3', base: v1.rev); // still based on v1
        final r = (await store.push('aaaa', [v3])).single;
        expect(r.status, PushStatus.applied);
        expect(r.conflictId, isNull);
        expect((await store.current('notes', 'n'))!.data!['body'], 'v3');
        await store.close();
      },
    );

    test(
      'a damaged line in the middle stops the hub instead of cutting data',
      () async {
        var store = await HubStore.open(dir);
        final a = clockFor('aaaa');
        await store.push('aaaa', [note(a, 'one', '1')]);
        await store.push('aaaa', [note(a, 'two', '2')]);
        await store.close();
        final text = await store.journal.readAsString();
        final damaged = text.replaceFirst(
          '"one"',
          '"one',
        ); // break the first line
        await store.journal.writeAsString(damaged);
        final before = await store.journal.length();
        await expectLater(HubStore.open(dir), throwsA(isA<StateError>()));
        expect(await store.journal.length(), before, reason: 'nothing was cut');
        // A torn last line, by contrast, is set aside and cut off.
        await store.journal.writeAsString(text);
        await store.journal.writeAsString(
          '{"t":"v","seq":9',
          mode: FileMode.append,
        );
        store = await HubStore.open(dir);
        expect(store.lastSeq, 2);
        expect(
          dir.listSync().where((e) => e.path.contains('.tail-')),
          hasLength(1),
        );
        await store.close();
      },
    );

    test(
      'concurrent edits: newest wins, the other is preserved as a conflict',
      () async {
        final store = await HubStore.open(dir);
        final a = clockFor('aaaa', 1000), b = clockFor('bbbb', 5000);
        final first = note(a, 'n', 'original');
        await store.push('aaaa', [first]);
        // Both devices edit from the same base.
        final aEdit = note(a, 'n', 'A version', base: first.rev);
        final bEdit = note(b, 'n', 'B version', base: first.rev); // newer clock
        await store.push('aaaa', [aEdit]);
        final res = (await store.push('bbbb', [bEdit])).single;
        expect(res.status, PushStatus.applied);
        expect(res.conflictId, isNotNull);
        expect((await store.current('notes', 'n'))!.data!['body'], 'B version');
        final conflict = await store.current('conflicts', res.conflictId!);
        expect(conflict!.data!['otherData']['body'], 'A version');
        expect(conflict.data!['reason'], 'concurrent_edit');

        // An older concurrent edit loses, but is preserved too.
        final late = note(
          clockFor('cccc', 2000),
          'n',
          'C version',
          base: first.rev,
        );
        final rc = (await store.push('cccc', [late])).single;
        expect(rc.status, PushStatus.keptServer);
        expect(rc.current!.data!['body'], 'B version');
        expect(
          (await store.current(
            'conflicts',
            rc.conflictId!,
          ))!.data!['otherData']['body'],
          'C version',
        );
        await store.close();
      },
    );

    test('a deletion never overwrites a newer edit; an edit after deletion is kept', () async {
      final store = await HubStore.open(dir);
      final a = clockFor('aaaa', 1000), b = clockFor('bbbb', 5000);
      final first = note(a, 'n', 'v1');
      await store.push('aaaa', [first]);
      await store.push('bbbb', [note(b, 'n', 'edited on B', base: first.rev)]);
      final del = (await store.push('aaaa', [
        deletion(a, 'n', base: first.rev),
      ])).single;
      expect(del.status, PushStatus.keptServer);
      expect((await store.current('notes', 'n'))!.deleted, isFalse);
      expect(
        (await store.current('conflicts', del.conflictId!))!.data!['reason'],
        'deleted_here_edited_elsewhere',
      );

      // The other way round: deleted on A first, then edited on C.
      final second = note(a, 'm', 'v1');
      await store.push('aaaa', [second]);
      await store.push('aaaa', [deletion(a, 'm', base: second.rev)]);
      final edit = (await store.push('cccc', [
        note(clockFor('cccc', 9000), 'm', 'kept', base: second.rev),
      ])).single;
      expect(edit.status, PushStatus.applied);
      expect((await store.current('notes', 'm'))!.data!['body'], 'kept');
      expect(
        (await store.current('conflicts', edit.conflictId!))!.data!['reason'],
        'edited_after_delete',
      );
      await store.close();
    });

    test('an interrupted write is discarded; committed data survives restarts', () async {
      var store = await HubStore.open(dir);
      final a = clockFor('aaaa');
      await store.push('aaaa', [note(a, 'kept', 'safe')]);
      await store.close();
      // Simulate a crash in the middle of the next batch (no commit line).
      final torn =
          '${jsonEncode({'t': 'v', 'seq': 2, 'c': 'notes', 'id': 'half', 'rev': a.now(), 'del': false, 'data': {}, 'dev': 'aaaa'})}\n{"t":"v","seq":3,"c":"no';
      await store.journal.writeAsString(torn, mode: FileMode.append);

      store = await HubStore.open(dir);
      expect(store.lastSeq, 1);
      expect(await store.current('notes', 'half'), isNull);
      expect((await store.current('notes', 'kept'))!.data!['body'], 'safe');
      // New writes continue cleanly after the cut.
      await store.push('aaaa', [note(a, 'next', 'ok')]);
      await store.close();
      store = await HubStore.open(dir);
      expect(store.lastSeq, 2);
      expect((await store.current('notes', 'next'))!.data!['body'], 'ok');
      await store.close();
    });

    test(
      'compaction keeps the latest data and still recognises retries',
      () async {
        final store = await HubStore.open(dir);
        final a = clockFor('aaaa');
        final v1 = note(a, 'n', 'one');
        await store.push('aaaa', [v1]);
        final v2 = note(a, 'n', 'two', base: v1.rev);
        await store.push('aaaa', [v2]);
        final before = await store.journal.length();
        await store.compact();
        expect(await store.journal.length(), lessThan(before));
        expect((await store.current('notes', 'n'))!.data!['body'], 'two');
        expect(
          (await store.push('aaaa', [v2])).single.status,
          PushStatus.duplicate,
        );
        await store.close();
      },
    );

    test('attachments: integrity checked, bad ids rejected, interrupted uploads leave nothing', () async {
      final store = await HubStore.open(dir);
      final bytes = utf8.encode('photo bytes');
      final sha = sha256.convert(bytes).toString();
      await store.putAttachment(sha, bytes.length, Stream.value(bytes));
      expect(await store.attachmentFile(sha).readAsBytes(), bytes);
      // Same file again: fine.
      await store.putAttachment(sha, bytes.length, Stream.value(bytes));

      final other = sha256.convert([1, 2, 3]).toString();
      await expectLater(
        store.putAttachment(other, 11, Stream.value(bytes)),
        throwsA(isA<ProtocolException>()),
      );
      expect(await store.hasAttachment(other), isFalse);

      final controller = StreamController<List<int>>();
      final upload = store.putAttachment(other, 3, controller.stream);
      controller.add([1]);
      controller.addError(const SocketException('connection lost'));
      await expectLater(upload, throwsA(isA<SocketException>()));
      expect(await store.hasAttachment(other), isFalse);
      final incoming = Directory(
        '${store.attachmentsDir.path}${Platform.pathSeparator}.incoming',
      );
      expect(incoming.listSync(), isEmpty);

      for (final bad in ['../journal.jsonl', '..\\x', 'ABC', '${sha}0', '']) {
        expect(
          () => store.attachmentFile(bad),
          throwsA(isA<ProtocolException>()),
        );
      }
      expect(
        () => store.putAttachment(
          sha,
          maxAttachmentBytes + 1,
          const Stream.empty(),
        ),
        throwsA(isA<ProtocolException>()),
      );
      await store.close();
    });

    test('backups verify and restore into a separate folder', () async {
      final store = await HubStore.open(dir);
      final a = clockFor('aaaa');
      await store.push('aaaa', [note(a, 'n1', 'one'), note(a, 'n2', 'two')]);
      final bytes = utf8.encode('img');
      final sha = sha256.convert(bytes).toString();
      await store.putAttachment(sha, bytes.length, Stream.value(bytes));
      final backups = HubBackups(store);
      final b = await backups.create();
      expect(await HubBackups.verify(b), isTrue);

      final target = Directory('${dir.path}-restored');
      addTearDown(
        () => target.existsSync() ? target.deleteSync(recursive: true) : null,
      );
      final missing = await HubBackups.restoreTo(
        b,
        target,
        attachmentsFrom: store.attachmentsDir,
      );
      expect(missing, isEmpty);
      final restored = await HubStore.open(target);
      expect(restored.lastSeq, store.lastSeq);
      expect((await restored.current('notes', 'n2'))!.data!['body'], 'two');
      expect(await restored.hasAttachment(sha), isTrue);
      await restored.close();

      // Never into a folder that has data in it.
      await expectLater(
        HubBackups.restoreTo(b, dir),
        throwsA(isA<FileSystemException>()),
      );
      // A damaged backup is detected.
      File('${b.path}${Platform.pathSeparator}journal.jsonl')
          .writeAsStringSync('x', mode: FileMode.append);
      expect(await HubBackups.verify(b), isFalse);
      await store.close();
    });
  });

  group('server', () {
    test('refuses to listen on all interfaces or a public address', () async {
      for (final host in ['0.0.0.0', '::', '8.8.8.8', 'example.com']) {
        await expectLater(
          HubServer.start(
            dir: dir,
            port: 0,
            privateHost: host,
            dailyBackups: false,
          ),
          throwsA(isA<ArgumentError>()),
          reason: host,
        );
      }
    });

    test(
      'authentication, protocol checks, pairing, push/pull, privacy of logs',
      () async {
        final logs = <String>[];
        final server = await HubServer.start(
          dir: dir,
          port: 0,
          log: logs.add,
          dailyBackups: false,
        );
        addTearDown(server.stop);
        expect(server.address.isLoopback, isTrue);
        final base = Uri.parse('http://127.0.0.1:${server.port}');
        final http = HttpClient();
        addTearDown(http.close);

        Future<(int, Map<String, dynamic>)> call(
          String method,
          String path, {
          String? token,
          Object? body,
          bool protocol = true,
        }) async {
          final req = await http.openUrl(method, base.resolve(path));
          if (protocol) req.headers.set(protocolHeader, '$syncProtocolVersion');
          if (token != null) req.headers.set('authorization', 'Bearer $token');
          if (body != null) req.write(jsonEncode(body));
          final res = await req.close();
          final text = await utf8.decodeStream(res);
          return (
            res.statusCode,
            text.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(text) as Map<String, dynamic>,
          );
        }

        expect((await call('GET', '/v1/status', protocol: false)).$1, 200);
        expect((await call('GET', '/v1/changes?since=0')).$1, 401);
        expect((await call('POST', '/v1/push', body: {'changes': []})).$1, 401);
        expect(
          (await call('GET', '/v1/changes?since=0', token: 'nonsense')).$1,
          401,
        );
        expect(
          (await call('GET', '/v1/admin/status', token: 'nonsense')).$1,
          401,
        );

        // Pairing: wrong codes are rate limited; a good code works once.
        final code = server.auth.createPairingCode();
        for (var i = 0; i < 5; i++) {
          expect(
            (await call(
              'POST',
              '/v1/register',
              body: {
                'pairingCode': 'WRONG',
                'deviceId': 'aaaa',
                'deviceName': 'PC',
              },
            )).$1,
            401,
          );
        }
        expect(
          (await call(
            'POST',
            '/v1/register',
            body: {'pairingCode': code, 'deviceId': 'aaaa', 'deviceName': 'PC'},
          )).$1,
          429,
        );
        server.auth.createPairingCode(); // (new code; the limiter is per address and still active)

        final client = SyncClient(base);
        addTearDown(client.close);
        // Bypass the limiter by registering through the API object directly.
        final token = await server.auth.register(
          server.auth.createPairingCode(),
          'aaaa',
          'PC',
        );
        client.token = token;
        expect(
          await server.auth
              .register(code, 'bbbb', 'X')
              .then((_) => true, onError: (_) => false),
          isTrue,
          reason: 'the first code is still valid once',
        );
        await expectLater(
          server.auth.register(code, 'cccc', 'Y'),
          throwsA(isA<ProtocolException>()),
          reason: 'single use',
        );

        // Wrong protocol version.
        expect(
          (await call(
            'GET',
            '/v1/changes?since=0',
            token: token,
            protocol: false,
          )).$1,
          426,
        );

        final a = clockFor('aaaa');
        final push = await client.push([note(a, 'n1', 'TOPSECRET note text')]);
        expect(push.results.single.status, PushStatus.applied);
        final pull = await client.pull(0);
        expect(pull.changes.single.data!['body'], 'TOPSECRET note text');
        expect(pull.hubId, server.store.hubId);

        // Invalid input is rejected with a clear code, not a crash.
        final bad = await call(
          'POST',
          '/v1/push',
          token: token,
          body: {
            'changes': [
              {
                'collection': 'secrets',
                'id': 'x',
                'rev': a.now(),
                'deleted': true,
              },
            ],
          },
        );
        expect(bad.$1, 400);
        expect(bad.$2['error'], 'bad_change');

        // Path tricks never reach files outside the attachments folder.
        for (final p in [
          '/v1/attachments/..%2Fjournal.jsonl',
          '/v1/attachments/..%5Cdevices.json',
          '/v1/attachments/../journal.jsonl',
        ]) {
          final r = await call('GET', p, token: token);
          expect(r.$1, anyOf(400, 404), reason: p);
          expect(jsonEncode(r.$2), isNot(contains('TOPSECRET')));
        }

        // Attachments over HTTP, with integrity checks.
        final file = File('${dir.path}${Platform.pathSeparator}up.bin')
          ..writeAsBytesSync(List.generate(5000, (i) => i % 256));
        final sha = await fileSha256(file);
        expect(await client.hasAttachment(sha), isFalse);
        await client.upload(sha, file);
        expect(await client.hasAttachment(sha), isTrue);
        final down = File('${dir.path}${Platform.pathSeparator}down.bin');
        await client.download(sha, 5000, down);
        expect(down.readAsBytesSync(), file.readAsBytesSync());
        final wrongSha = sha256.convert([9]).toString();
        await expectLater(
          client.upload(wrongSha, file),
          throwsA(isA<SyncFailure>()),
        );
        expect(await client.hasAttachment(wrongSha), isFalse);

        // Logs: useful, but no content, tokens or attachment ids.
        final all = logs.join('\n');
        expect(all, contains('POST /v1/push -> 200'));
        expect(all, isNot(contains('TOPSECRET')));
        expect(all, isNot(contains(token)));
        expect(all, isNot(contains(sha)));
      },
    );

    test('data and device tokens survive a hub restart', () async {
      var server = await HubServer.start(
        dir: dir,
        port: 0,
        dailyBackups: false,
      );
      final token = await server.auth.register(
        server.auth.createPairingCode(),
        'aaaa',
        'PC',
      );
      var client = SyncClient(
        Uri.parse('http://127.0.0.1:${server.port}'),
        token: token,
      );
      await client.push([note(clockFor('aaaa'), 'n', 'persisted')]);
      client.close();
      await server.stop();

      server = await HubServer.start(dir: dir, port: 0, dailyBackups: false);
      client = SyncClient(
        Uri.parse('http://127.0.0.1:${server.port}'),
        token: token,
      );
      final pull = await client.pull(0);
      expect(pull.changes.single.data!['body'], 'persisted');
      client.close();
      await server.stop();
    });

    test(
      'admin endpoints work only with the admin token from this PC',
      () async {
        final server = await HubServer.start(
          dir: dir,
          port: 0,
          dailyBackups: false,
        );
        addTearDown(server.stop);
        final http = HttpClient();
        addTearDown(http.close);
        final adminToken = (await File(
          '${dir.path}${Platform.pathSeparator}admin.token',
        ).readAsString());
        // The admin token file is encrypted (DPAPI) on Windows, not plain text.
        if (Platform.isWindows) expect(adminToken, contains('dpapi'));
        final req = await http.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/v1/admin/pair'),
        );
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, 401);
      },
    );

    // Regression (2026-11-11): the hub read the offer only when the request
    // had Content-Length, but dart:io's HttpClient sends a written body
    // chunked. Every code the PC app showed was dropped, and the iPad got
    // "The pairing code is wrong or has expired".
    test('a pairing offer sent chunked is kept and the code pairs', () async {
      final server = await HubServer.start(
        dir: dir,
        port: 0,
        dailyBackups: false,
      );
      addTearDown(server.stop);
      final adminToken = await readSecret(HubAuth.adminTokenFile(dir));
      expect(adminToken, isNotNull);
      final secret = PairingSecret.generate();
      final http = HttpClient();
      addTearDown(http.close);
      final req = await http.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/admin/pair'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $adminToken');
      req.headers.contentType = ContentType.json;
      // No contentLength: sent chunked, exactly like the old app code.
      req.write(
        jsonEncode({
          'registerCode': secret.registerCode,
          'wrappedKey': 'wrapped-key',
        }),
      );
      final res = await req.close();
      final body = jsonDecode(await utf8.decodeStream(res)) as Map;
      expect(res.statusCode, 200);
      expect(body.containsKey('code'), isFalse, reason: 'offer was ignored');

      final paired = await server.auth.registerWithKey(
        secret.registerCode,
        'ipad0001',
        'iPad',
      );
      expect(paired.wrappedKey, 'wrapped-key');
    });

    test('an empty admin pair request still makes a short code', () async {
      final server = await HubServer.start(
        dir: dir,
        port: 0,
        dailyBackups: false,
      );
      addTearDown(server.stop);
      final adminToken = await readSecret(HubAuth.adminTokenFile(dir));
      final http = HttpClient();
      addTearDown(http.close);
      final req = await http.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/admin/pair'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $adminToken');
      final res = await req.close();
      final body = jsonDecode(await utf8.decodeStream(res)) as Map;
      expect(res.statusCode, 200);
      expect(body['code'], isA<String>());
    });
  });
}
