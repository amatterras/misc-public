// Large attachments: uploads and downloads that continue after an
// interruption, are checked before they count, and never show a half file.
// Real hub on 127.0.0.1 plus small stub servers for cut connections and an
// older hub without resumable uploads.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/transfer_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late HubServer hub;
  late SyncClient client;

  const chunk = 64 * 1024;
  Uint8List bytes(int n, [int seed = 1]) {
    final r = Random(seed);
    return Uint8List.fromList([for (var i = 0; i < n; i++) r.nextInt(256)]);
  }

  String shaOf(List<int> b) => sha256.convert(b).toString();

  File write(String name, List<int> b) {
    final f = File('${root.path}${Platform.pathSeparator}$name');
    f.writeAsBytesSync(b);
    return f;
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_resume_');
    hub = await HubServer.start(
      dir: Directory('${root.path}${Platform.pathSeparator}hub'),
      port: 0,
      dailyBackups: false,
    );
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      'devresume1',
      'test',
    );
    client = SyncClient(Uri.parse('http://127.0.0.1:${hub.port}'), token: token)
      ..uploadChunkBytes = chunk;
  });

  tearDown(() async {
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('upload', () {
    test('a large file goes up in pieces and arrives complete', () async {
      final data = bytes(chunk * 5 + 123);
      final sha = shaOf(data);
      final progress = <int>[];
      await client.upload(
        sha,
        write('big.bin', data),
        onProgress: (sent, total) {
          expect(total, data.length);
          progress.add(sent);
        },
      );
      expect(await client.hasAttachment(sha), isTrue);
      expect(hub.store.attachmentFile(sha).readAsBytesSync(), data);
      expect(progress.length, greaterThan(3), reason: 'several pieces');
      expect(progress, orderedEquals([...progress]..sort()));
      expect(progress.last, data.length);
      expect(await hub.store.partialBytes(sha), 0, reason: 'no part left');
    });

    test('a cut upload continues from what the hub holds', () async {
      final data = bytes(chunk * 4 + 7, 2);
      final sha = shaOf(data);
      // Two pieces arrive, then the connection is lost (simulated by sending
      // them by hand and stopping).
      for (final offset in [0, chunk]) {
        final req = await HttpClient().openUrl(
          'PUT',
          Uri.parse('http://127.0.0.1:${hub.port}/v1/attachments/$sha'),
        );
        req.headers
          ..set(protocolHeader, '$syncProtocolVersion')
          ..set(HttpHeaders.authorizationHeader, 'Bearer ${client.token}')
          ..set('x-upload-offset', '$offset')
          ..set('x-upload-total', '${data.length}')
          ..contentLength = chunk;
        req.add(data.sublist(offset, offset + chunk));
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, 200);
      }
      expect(await hub.store.partialBytes(sha), chunk * 2);
      expect(await client.hasAttachment(sha), isFalse, reason: 'not complete');
      expect(await client.partialBytes(sha), chunk * 2);

      final first = <int>[];
      await client.upload(
        sha,
        write('big2.bin', data),
        onProgress: (sent, _) => first.add(sent),
      );
      // It did not start again: the first report is already past the two
      // pieces the hub had.
      expect(first.first, chunk * 3);
      expect(hub.store.attachmentFile(sha).readAsBytesSync(), data);
    });

    test('a wrong offset is refused and tells where to continue', () async {
      final data = bytes(chunk * 3, 3);
      final sha = shaOf(data);
      final req = await HttpClient().openUrl(
        'PUT',
        Uri.parse('http://127.0.0.1:${hub.port}/v1/attachments/$sha'),
      );
      req.headers
        ..set(protocolHeader, '$syncProtocolVersion')
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${client.token}')
        ..set('x-upload-offset', '$chunk')
        ..set('x-upload-total', '${data.length}')
        ..contentLength = chunk;
      req.add(data.sublist(chunk, chunk * 2));
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 409);
      expect(res.headers.value('x-partial-bytes'), '0');
    });

    test('content that does not match its id never becomes visible', () async {
      final data = bytes(chunk * 3, 4);
      final wrongSha = shaOf(bytes(10, 99));
      await expectLater(
        client.upload(wrongSha, write('bad.bin', data)),
        throwsA(isA<SyncFailure>()),
      );
      expect(await client.hasAttachment(wrongSha), isFalse);
      expect(await hub.store.partialBytes(wrongSha), 0, reason: 'part removed');
      expect(hub.store.attachmentFile(wrongSha).existsSync(), isFalse);
    });

    test('over the size limit is refused up front', () async {
      final req = await HttpClient().openUrl(
        'PUT',
        Uri.parse('http://127.0.0.1:${hub.port}/v1/attachments/${shaOf([1])}'),
      );
      req.headers
        ..set(protocolHeader, '$syncProtocolVersion')
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${client.token}')
        ..set('x-upload-offset', '0')
        ..set('x-upload-total', '${200 * 1024 * 1024}')
        ..contentLength = 1;
      req.add([1]);
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 413);
    });

    test('uploading a file the hub has is a no-op', () async {
      final data = bytes(chunk * 2 + 1, 5);
      final sha = shaOf(data);
      final f = write('same.bin', data);
      await client.upload(sha, f);
      var calls = 0;
      await client.upload(sha, f, onProgress: (_, _) => calls++);
      expect(calls, 1, reason: 'reported complete at once, sent nothing');
    });
  });

  group('download', () {
    Future<(String, Uint8List)> stored(int n, [int seed = 6]) async {
      final data = bytes(n, seed);
      final sha = shaOf(data);
      await client.upload(sha, write('src-$seed.bin', data));
      return (sha, data);
    }

    test('a partial file is continued, not downloaded again', () async {
      final (sha, data) = await stored(chunk * 4);
      final target = File('${root.path}${Platform.pathSeparator}out.bin');
      File('${target.path}.download').writeAsBytesSync(data.sublist(0, 100000));
      final seen = <int>[];
      await client.download(
        sha,
        data.length,
        target,
        onProgress: (n, _) => seen.add(n),
      );
      expect(target.readAsBytesSync(), data);
      expect(seen.first, greaterThan(100000), reason: 'continued');
      expect(File('${target.path}.download').existsSync(), isFalse);
    });

    test('a damaged partial fails the check and is not kept', () async {
      final (sha, data) = await stored(chunk * 3, 7);
      final target = File('${root.path}${Platform.pathSeparator}out2.bin');
      File('${target.path}.download').writeAsBytesSync(bytes(70000, 55));
      await expectLater(
        client.download(sha, data.length, target),
        throwsA(
          isA<SyncFailure>().having((e) => e.code, 'code', 'integrity_failed'),
        ),
      );
      expect(target.existsSync(), isFalse, reason: 'nothing half-done shown');
      expect(File('${target.path}.download').existsSync(), isFalse);
      // The next try starts clean and works.
      await client.download(sha, data.length, target);
      expect(target.readAsBytesSync(), data);
    });

    test('a partial longer than the file starts again', () async {
      final (sha, data) = await stored(chunk, 8);
      final target = File('${root.path}${Platform.pathSeparator}out3.bin');
      File('${target.path}.download').writeAsBytesSync(bytes(chunk * 2, 9));
      await client.download(sha, data.length, target);
      expect(target.readAsBytesSync(), data);
    });

    test('a missing file is reported, not retried forever', () async {
      final target = File('${root.path}${Platform.pathSeparator}none.bin');
      await expectLater(
        client.download(shaOf([9, 9, 9]), null, target),
        throwsA(
          isA<SyncFailure>().having((e) => e.retryable, 'retryable', false),
        ),
      );
    });
  });

  group('interruption and older hubs (stub servers)', () {
    test('a connection cut mid-download keeps the partial; the next call finishes', () async {
      final data = bytes(300000, 11);
      final sha = shaOf(data);
      var cut = true;
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        final range = RegExp(r'^bytes=(\d+)-$')
            .firstMatch(r.headers.value(HttpHeaders.rangeHeader) ?? '');
        final from = range == null ? 0 : int.parse(range.group(1)!);
        if (cut) {
          // The headers promise the rest, then the connection dies.
          final socket = await r.response.detachSocket(writeHeaders: false);
          final status = range == null ? '200 OK' : '206 Partial Content';
          final rangeLine = range == null
              ? ''
              : 'content-range: bytes $from-${data.length - 1}/${data.length}\r\n';
          socket.add(
            ascii.encode(
              'HTTP/1.1 $status\r\n'
              'content-length: ${data.length - from}\r\n'
              '$rangeLine\r\n',
            ),
          );
          socket.add(data.sublist(from, from + 100000));
          await socket.flush();
          socket.destroy();
          return;
        }
        r.response
          ..statusCode = range == null ? 200 : 206
          ..headers.contentLength = data.length - from;
        if (range != null) {
          r.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $from-${data.length - 1}/${data.length}',
          );
        }
        r.response.add(data.sublist(from));
        await r.response.close();
      });
      final c = SyncClient(Uri.parse('http://127.0.0.1:${server.port}'));
      final target = File('${root.path}${Platform.pathSeparator}cut.bin');
      await expectLater(
        c.download(sha, data.length, target),
        throwsA(
          isA<SyncFailure>().having((e) => e.retryable, 'retryable', true),
        ),
      );
      final partial = File('${target.path}.download');
      expect(partial.existsSync(), isTrue, reason: 'kept for the next try');
      expect(partial.lengthSync(), greaterThan(0));
      expect(target.existsSync(), isFalse, reason: 'never a half file');
      cut = false;
      await c.download(sha, data.length, target);
      expect(target.readAsBytesSync(), data);
    });

    test(
      'an older hub without resumable uploads still gets the file',
      () async {
        final data = bytes(chunk * 3, 12);
        final sha = shaOf(data);
        Uint8List? received;
        final server = await HttpServer.bind('127.0.0.1', 0);
        addTearDown(() => server.close(force: true));
        server.listen((r) async {
          if (r.method == 'HEAD') {
            r.response.statusCode = 404; // no x-partial-bytes: an older hub
            await r.response.close();
            return;
          }
          // An older hub: reads the body as the whole file and checks it.
          final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
          final ok = shaOf(body) == sha;
          if (ok) received = Uint8List.fromList(body);
          r.response
            ..statusCode = ok ? 200 : 422
            ..write(
              jsonEncode(ok ? {'ok': true} : {'error': 'integrity_failed'}),
            );
          await r.response.close();
        });
        final c = SyncClient(Uri.parse('http://127.0.0.1:${server.port}'))
          ..uploadChunkBytes = chunk;
        await c.upload(sha, write('old.bin', data));
        expect(received, data);
      },
    );
  });

  group('tracker', () {
    test('done only when told, finished entries are trimmed', () {
      final t = TransferTracker();
      t.update(
        'a',
        upload: true,
        stage: TransferStage.active,
        bytes: 5,
        total: 10,
      );
      expect(t['a']!.fraction, 0.5);
      expect(t.unfinished, hasLength(1));
      t.update('a', upload: true, stage: TransferStage.retrying, error: 'cut');
      expect(t['a']!.bytes, 5, reason: 'progress kept while retrying');
      t.update('a', upload: true, stage: TransferStage.done, total: 10);
      expect(t['a']!.fraction, 1);
      expect(t.unfinished, isEmpty);
      for (var i = 0; i < 30; i++) {
        t.update('x$i', upload: false, stage: TransferStage.done, total: 1);
      }
      expect(t.all.length, lessThanOrEqualTo(TransferTracker.keepFinished));
    });
  });
}
