// The hub's journal must not grow forever. Every edit adds a version and an
// acknowledgement; only compaction removes the superseded ones. It used to run
// only when someone typed `thehub compact`. Now the hub does it itself when
// the journal is mostly garbage, after a backup, without devices noticing.
import 'dart:io';

import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

SyncChange note(SyncClock clock, String id, String body, {String? base}) =>
    SyncChange(
      collection: 'notes',
      id: id,
      rev: clock.now(),
      deleted: false,
      data: {'title': id, 'body': body},
      baseRev: base,
    );

void main() {
  late Directory root;
  late HubServer hub;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_compact_');
    hub = await HubServer.start(
      dir: Directory('${root.path}${Platform.pathSeparator}hub'),
      port: 0,
      dailyBackups: false,
    );
  });
  tearDown(() async {
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, String>> fill({int records = 12, int edits = 80}) async {
    final clock = SyncClock(deviceId: 'aaaa');
    final latest = <String, String>{};
    final lastRev = <String, String>{};
    for (var e = 0; e < edits; e++) {
      for (var r = 0; r < records; r++) {
        final id = 'n$r';
        final c = note(
          clock,
          id,
          'edit $e of $id ${'x' * 200}',
          base: lastRev[id],
        );
        await hub.store.push('aaaa', [c]);
        lastRev[id] = c.rev;
        latest[id] = c.data!['body'] as String;
      }
    }
    return latest;
  }

  test('a journal that is mostly superseded versions is compacted by the hub '
      'itself, and nothing current is lost', () async {
    final latest = await fill();
    final before = hub.store.stats.journalBytes;
    final lastSeq = hub.store.stats.lastSeq;
    expect(hub.store.shouldCompact(minBytes: 1000), isTrue);
    expect(hub.store.shouldCompact(), isFalse, reason: 'too small to bother');

    expect(await hub.compactIfNeeded(minBytes: 1000), isTrue);

    final after = hub.store.stats.journalBytes;
    expect(after, lessThan(before ~/ 3), reason: 'the garbage is gone');
    expect(hub.store.stats.lastSeq, lastSeq, reason: 'change numbers stay');
    for (final e in latest.entries) {
      final c = await hub.store.current('notes', e.key);
      expect(c?.data?['body'], e.value, reason: e.key);
    }
    // Devices that read up to a change number keep working: what is newer
    // than their cursor is still all there.
    final page = await hub.store.changesSince(0, 500);
    expect(page.changes, hasLength(latest.length));
    // A backup was taken first.
    expect(await hub.backups.list(), isNotEmpty);
    // Nothing more to do right after.
    expect(hub.store.shouldCompact(minBytes: 1000), isFalse);
    expect(await hub.compactIfNeeded(minBytes: 1000), isFalse);
  });

  test('a compacted hub reopens with the same data (restart), and a retried '
      'edit is still recognised', () async {
    final latest = await fill(records: 5, edits: 40);
    final dir = hub.store.dir;
    expect(await hub.compactIfNeeded(minBytes: 1000), isTrue);
    await hub.stop();
    hub = await HubServer.start(dir: dir, port: 0, dailyBackups: false);
    for (final e in latest.entries) {
      expect((await hub.store.current('notes', e.key))?.data?['body'], e.value);
    }
    // A new edit on top of the compacted data is accepted.
    final cur = (await hub.store.current('notes', 'n0'))!;
    final next = note(
      SyncClock(deviceId: 'aaaa')..observe(cur.rev),
      'n0',
      'after',
      base: cur.rev,
    );
    final r = await hub.store.push('aaaa', [next]);
    expect(r.single.status, PushStatus.applied);
  });

  test('a healthy journal is left alone', () async {
    await fill(records: 3, edits: 1);
    expect(
      hub.store.shouldCompact(minBytes: 1),
      isFalse,
      reason: 'one version per record: nothing to remove',
    );
    final before = hub.store.stats.journalBytes;
    expect(await hub.compactIfNeeded(minBytes: 1), isFalse);
    expect(hub.store.stats.journalBytes, before);
  });
}
