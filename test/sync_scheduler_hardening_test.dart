// The sync scheduler under hostile conditions, with a fake hub that only
// answers the live-wait endpoint: unexpected errors, refusals that waiting
// does not fix, a hub that accepts connections and never answers, and rapid
// start/stop while a cycle is running.
import 'dart:io';

import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> until(
  bool Function() done, {
  required String what,
  Duration limit = const Duration(seconds: 15),
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > limit) fail('$what not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late HttpServer fake;
  setUp(() async {
    fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fake.listen((req) async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"lastSeq":0,"hubId":"fake"}');
      await req.response.close();
    });
  });
  tearDown(() => fake.close(force: true));

  SyncScheduler make(
    Future<void> Function() run, {
    void Function(SyncFailure)? onBlocked,
    Duration blockedBase = const Duration(milliseconds: 300),
    Uri? at,
  }) => SyncScheduler(
    run: run,
    cursor: () async => 0,
    client: SyncClient(
      at ?? Uri.parse('http://127.0.0.1:${fake.port}'),
      token: 't',
    ),
    debounce: const Duration(milliseconds: 20),
    onBlocked: onBlocked,
    blockedRetryBase: blockedBase,
  );

  test('an unexpected error is "blocked" (never live), reported once, and a '
      'later success clears it', () async {
    var fail = true;
    final blocked = <String>[];
    final s = make(() async {
      if (fail) throw StateError('a bug');
    }, onBlocked: (e) => blocked.add(e.code));
    s.start();
    await until(
      () => s.connection == SyncConnection.blocked,
      what: 'blocked after an unexpected error',
    );
    expect(blocked, ['unexpected']);
    expect(s.failuresTotal, greaterThan(0));
    fail = false;
    await s.syncNow();
    expect(s.connection, isNot(SyncConnection.blocked));
    expect(s.lastSuccess, isNotNull);
    await s.close();
  });

  test('while blocked, a burst of requests is throttled into a few cycles; '
      '"Sync now" still runs at once', () async {
    var runs = 0;
    final s = make(() async {
      runs++;
      throw const SyncFailure('protocol_mismatch', 'Update the app.');
    });
    s.start();
    await until(() => runs >= 1, what: 'the first cycle');
    await until(() => s.connection == SyncConnection.blocked, what: 'blocked');
    final before = runs;
    final burst = Stopwatch()..start();
    while (burst.elapsed < const Duration(milliseconds: 1500)) {
      s.request(Duration.zero);
      s.localChange();
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // 1.5 s of constant requests with a 300 ms (doubling) pause: a handful of
    // cycles at most, not hundreds.
    expect(runs - before, lessThanOrEqualTo(5), reason: 'throttled');
    final explicit = runs;
    await s.syncNow();
    expect(runs, explicit + 1, reason: 'an explicit "Sync now" is never held');
    await s.close();
  });

  test('a hub that accepts the connection and never answers is never shown '
      'as live', () async {
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    silent.listen(held.add); // accepted, never answered
    addTearDown(() async {
      for (final c in held) {
        c.destroy();
      }
      await silent.close();
    });
    final s = make(
      () async {},
      at: Uri.parse('http://127.0.0.1:${silent.port}'),
    );
    s.start();
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 13)) {
      expect(s.connection, isNot(SyncConnection.live));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(s.connection, SyncConnection.offline, reason: 'timed out = offline');
    await s.close();
  });

  test('starting and stopping again and again while a cycle runs never runs '
      'two cycles at once and never leaves a loop behind', () async {
    var running = 0;
    var overlap = 0;
    var total = 0;
    final s = make(() async {
      running++;
      total++;
      if (running > 1) overlap++;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      running--;
    });
    for (var i = 0; i < 25; i++) {
      s.start();
      s.localChange();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      s.stop();
    }
    s.start();
    await until(() => s.connection == SyncConnection.live, what: 'live');
    await s.close();
    expect(overlap, 0);
    expect(total, greaterThan(0));
    // Nothing keeps running after close.
    final after = total;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(total, after);
    expect(s.connection, SyncConnection.stopped);
  });

  test('lastSuccess is only set by a cycle that really finished', () async {
    var fail = true;
    final s = make(() async {
      if (fail) throw const SyncFailure('offline', 'down', retryable: true);
    });
    s.start();
    await until(() => s.failuresTotal > 0, what: 'a failed cycle');
    expect(s.lastSuccess, isNull);
    fail = false;
    await s.syncNow();
    expect(s.lastSuccess, isNotNull);
    await s.close();
  });
}
