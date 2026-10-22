// The read-only mirror against a real hub on 127.0.0.1. Each test covers a
// defect found in the audit of the first mirror version.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_application_1/hub/hub_mirror.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/hub/hub_store.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

void main() {
  late Directory root;
  late HubServer hub;
  late SyncClient device;
  late SyncClock clock;
  late Uri url;

  Directory sub(String name) => Directory('${root.path}$sep$name');

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_mirror_');
    hub = await HubServer.start(dir: sub('hub'), port: 0, dailyBackups: false);
    url = Uri.parse('http://127.0.0.1:${hub.port}');
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      'pcpc',
      'PC',
    );
    device = SyncClient(url, token: token);
    var t = 1000;
    clock = SyncClock(deviceId: 'pcpc', wallClock: () => t += 10);
  });

  tearDown(() async {
    device.close();
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  SyncChange note(String id, String body, {String? base}) => SyncChange(
    collection: 'notes',
    id: id,
    rev: clock.now(),
    deleted: false,
    data: {'id': id, 'title': 'T', 'body': body},
    baseRev: base,
  );

  Future<MirrorEngine> pairedMirror() async {
    final m = MirrorEngine(sub('mirror'));
    await m.pair(url, hub.auth.createPairingCode());
    return m;
  }

  test('a mirror can never use a hub folder', () async {
    final m = MirrorEngine(sub('hub'));
    await expectLater(
      m.pair(url, hub.auth.createPairingCode()),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(m.replicateOnce(), throwsA(isA<ArgumentError>()));
    expect(File('${sub('hub').path}${sep}mirror.json').existsSync(), isFalse);
  });

  test(
    'repeated runs, edits and photos; restore gives a working hub',
    () async {
      // A photo and a note that references it.
      final bytes = utf8.encode('photo-bytes');
      final sha = sha256.convert(bytes).toString();
      final photo = File('${root.path}${sep}p.png')..writeAsBytesSync(bytes);
      await device.upload(sha, photo);
      final v1 = note('n1', 'first');
      await device.push([
        v1,
        SyncChange(
          collection: 'assets',
          id: 'a1',
          rev: clock.now(),
          deleted: false,
          data: {
            'id': 'a1',
            'kind': 'image',
            'file': 'a1.png',
            'fileSha256': sha,
            'fileSize': bytes.length,
          },
        ),
      ]);

      final mirror = await pairedMirror();
      var r = await mirror.replicateOnce();
      expect(r.status, MirrorStatus.inSync, reason: '$r');
      expect(r.changes, 2);
      expect(r.attachmentsDownloaded, 1);

      // Edit the same note twice: the hub's change numbers now have gaps.
      final v2 = note('n1', 'second', base: v1.rev);
      await device.push([v2]);
      await device.push([note('n1', 'third', base: v2.rev), note('n2', 'new')]);
      r = await mirror.replicateOnce();
      expect(r.status, MirrorStatus.inSync, reason: 'second run must work: $r');
      expect(r.cursor, hub.store.lastSeq);
      r = await mirror.replicateOnce();
      expect(r.changes, 0);

      final check = await mirror.verify();
      expect(check.valid, isTrue, reason: '$check');
      expect(check.records, 3);

      // Restore into a clean folder and open it as a real hub.
      final target = sub('restored');
      await MirrorEngine.restoreToCleanHub(
        mirrorDir: mirror.dir,
        target: target,
      );
      final restored = await HubStore.open(target);
      expect(restored.stats.records, 3);
      expect((await restored.current('notes', 'n1'))!.data!['body'], 'third');
      expect((await restored.current('notes', 'n2'))!.data!['body'], 'new');
      expect(await restored.attachmentFile(sha).readAsBytes(), bytes);
      expect(restored.hubId, isNot(hub.store.hubId));
      await restored.close();
      await expectLater(
        MirrorEngine.restoreToCleanHub(mirrorDir: mirror.dir, target: target),
        throwsA(isA<FileSystemException>()),
        reason: 'never into a folder with data',
      );
    },
  );

  test(
    'a replaced hub stops the mirror; --reseed keeps the old copy',
    () async {
      await device.push([note('n1', 'one')]);
      final mirror = await pairedMirror();
      await mirror.replicateOnce();
      final before = mirror.journal.readAsBytesSync();

      // Replace the hub with an empty one (new id), same address.
      final port = hub.port;
      final token = await hub.auth.register(
        hub.auth.createPairingCode(),
        'zzzz',
        'x',
      );
      await hub.stop();
      final devices = File('${sub('hub').path}${sep}devices.json')
          .readAsStringSync();
      sub('hub').renameSync(sub('hub-old').path);
      sub('hub').createSync();
      File('${sub('hub').path}${sep}devices.json').writeAsStringSync(devices);
      hub = await HubServer.start(
        dir: sub('hub'),
        port: port,
        dailyBackups: false,
      );
      expect(token, isNotEmpty);

      var r = await mirror.replicateOnce();
      expect(r.status, MirrorStatus.primaryHubChanged);
      expect(
        mirror.journal.readAsBytesSync(),
        before,
        reason: 'nothing changed',
      );

      r = await mirror.replicateOnce(reseed: true);
      expect(r.status, MirrorStatus.inSync);
      final aside = mirror.dir.listSync().whereType<Directory>().where(
        (d) => d.path.contains('previous-'),
      );
      expect(aside, hasLength(1));
      expect(
        File('${aside.single.path}${sep}journal.jsonl').readAsBytesSync(),
        before,
      );
    },
  );

  test(
    'an unfinished batch makes the copy invalid and blocks restore',
    () async {
      await device.push([note('n1', 'one')]);
      final mirror = await pairedMirror();
      await mirror.replicateOnce();
      mirror.journal.writeAsStringSync(
        '{"t":"v","seq":9',
        mode: FileMode.append,
      );
      final check = await mirror.verify();
      expect(check.valid, isFalse);
      await expectLater(
        MirrorEngine.restoreToCleanHub(mirrorDir: mirror.dir, target: sub('r')),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'a batch cut off by a crash is removed before new data is appended',
    () async {
      await device.push([note('n1', 'one')]);
      final mirror = await pairedMirror();
      await mirror.replicateOnce();
      // Simulated power cut in the middle of writing a batch.
      mirror.journal.writeAsStringSync(
        '{"t":"v","seq":9,"c":"notes","id":"x"',
        mode: FileMode.append,
      );
      await device.push([note('n2', 'two')]);

      final r = await mirror.replicateOnce();
      expect(r.status, MirrorStatus.inSync, reason: '$r');
      expect(r.bytesTrimmed, greaterThan(0));
      expect(r.changes, 1);
      final check = await mirror.verify();
      expect(check.valid, isTrue, reason: '$check');
      expect(check.records, 2);
      final kept = mirror.dir.listSync().where(
        (f) => f.path.contains('journal.jsonl.tail-'),
      );
      expect(kept, hasLength(1), reason: 'the cut-off bytes are kept');
    },
  );

  test('a damaged photo copy is found, set aside and fetched again', () async {
    final bytes = utf8.encode('original photo');
    final sha = sha256.convert(bytes).toString();
    await device.upload(
      sha,
      File('${root.path}${sep}p.png')..writeAsBytesSync(bytes),
    );
    await device.push([
      SyncChange(
        collection: 'assets',
        id: 'a1',
        rev: clock.now(),
        deleted: false,
        data: {'id': 'a1', 'kind': 'image', 'fileSha256': sha},
      ),
    ]);
    final mirror = await pairedMirror();
    await mirror.replicateOnce();
    final copy = File('${mirror.attachmentsDir.path}$sep$sha');
    copy.writeAsStringSync('bit rot');

    expect((await mirror.verify()).valid, isFalse);
    var r = await mirror.replicateOnce();
    expect(copy.readAsStringSync(), 'bit rot', reason: 'not repaired unasked');
    r = await mirror.replicateOnce(repair: true);
    expect(r.attachmentsRepaired, 1);
    expect(r.attachmentsDownloaded, 1);
    expect(copy.readAsBytesSync(), bytes);
    expect((await mirror.verify()).valid, isTrue);
    final aside = Directory('${mirror.dir.path}${sep}damaged').listSync();
    expect(aside, hasLength(1), reason: 'the damaged copy is kept');
  });

  test('hub offline, then back: health shows failing, then ok', () async {
    await device.push([note('n1', 'one')]);
    final mirror = await pairedMirror();
    expect((await mirror.loadState())!.health(), 'never run');
    await mirror.replicateOnce();
    expect((await mirror.loadState())!.health(), 'ok');

    final port = hub.port;
    await hub.stop();
    var r = await mirror.replicateOnce();
    expect(r.status, MirrorStatus.networkError);
    var state = (await mirror.loadState())!;
    expect(state.health(), startsWith('failing'));
    expect(state.cursor, greaterThan(0), reason: 'position kept');

    hub = await HubServer.start(
      dir: sub('hub'),
      port: port,
      dailyBackups: false,
    );
    r = await mirror.replicateOnce();
    expect(r.status, MirrorStatus.inSync, reason: '$r');
    state = (await mirror.loadState())!;
    expect(state.health(), 'ok');
    expect(
      state.health(now: DateTime.now().add(const Duration(days: 3))),
      startsWith('stale'),
    );
  });

  test('unwritable mirror storage is reported and loses nothing', () async {
    await device.push([note('n1', 'one')]);
    final mirror = await pairedMirror();
    // Something that cannot be opened as a file where the journal goes
    // (stands in for a full or failing disk).
    Directory(mirror.journal.path).createSync(recursive: true);
    var r = await mirror.replicateOnce();
    expect(r.status, MirrorStatus.storageError, reason: '$r');
    expect((await mirror.loadState())!.cursor, 0, reason: 'nothing skipped');

    Directory(mirror.journal.path).deleteSync();
    r = await mirror.replicateOnce();
    expect(r.status, MirrorStatus.inSync);
    expect(r.changes, 1);
    expect((await mirror.verify()).valid, isTrue);
  });

  test('the mirror token is stored encrypted, not passed around', () async {
    final mirror = await pairedMirror();
    final text = File('${mirror.dir.path}${sep}mirror.token')
        .readAsStringSync();
    if (Platform.isWindows) expect(text, contains('dpapi'));
    expect(
      File('${mirror.dir.path}${sep}mirror.json').readAsStringSync(),
      isNot(contains('token')),
    );
  });
}
