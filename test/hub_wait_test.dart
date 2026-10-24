// The hub's long-poll wait: it answers on a change, a wake-up or the
// timeout, answers at once when a change is already there, and leaves no
// listener behind however it ends (a paused hub holds waits for hours).
import 'dart:io';

import 'package:flutter_application_1/hub/hub_store.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_wait_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  var t = 1000;
  final clock = SyncClock(deviceId: 'aaaa', wallClock: () => t += 10);
  SyncChange note(String id) => SyncChange(
    collection: 'notes',
    id: id,
    rev: clock.now(),
    deleted: false,
    data: {'id': id, 'title': id},
  );

  test('change, wake-up and timeout answer; no listeners are left', () async {
    final store = await HubStore.open(dir);
    final start = store.lastSeq;

    // A change arriving during the wait.
    final waiting = store.waitForChange(start, const Duration(seconds: 10));
    expect(store.waiting, 1);
    await store.push('aaaa', [note('a')]);
    expect(await waiting, greaterThan(start));

    // Already newer: at once.
    expect(
      await store.waitForChange(start, const Duration(seconds: 10)),
      store.lastSeq,
    );

    // Woken (pause / resume / stop) and timed out: the current number.
    final held = store.waitForChange(1 << 52, const Duration(seconds: 10));
    store.wakeWaiters();
    expect(await held, store.lastSeq);
    expect(
      await store.waitForChange(
        store.lastSeq,
        const Duration(milliseconds: 50),
      ),
      store.lastSeq,
    );

    // Many held waits that end without a change leave nothing behind.
    for (var i = 0; i < 50; i++) {
      final w = store.waitForChange(1 << 52, const Duration(seconds: 10));
      store.wakeWaiters();
      await w;
    }
    expect(store.waiting, 0);
    expect(store.hasChangeListeners, isFalse);
  });
}
