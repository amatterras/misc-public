// Extended stability check of the hub THEapp runs (opt-in, takes
// minutes): heartbeats every 200 ms, a push and a pull every second from
// two devices, a long-poll always waiting, and the 10-second health
// check, for THEAPP_STABILITY_MINUTES minutes on a temporary folder.
// Every request must succeed, the health check must stay green, and every
// record must arrive exactly once.
//   THEAPP_STABILITY_MINUTES=5 flutter test test/hub_stability_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/hub/hub_host.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_application_1/sync/local_hub.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final minutes = int.tryParse(
    Platform.environment['THEAPP_STABILITY_MINUTES'] ?? '',
  );

  test(
    'the hub stays up and correct under steady load',
    () async {
      HttpOverrides.global = null;
      final dir = Directory.systemTemp.createTempSync('theapp_stability_');
      final host = HubHost(dir: dir, port: 0, privateAddress: () async => null);
      await host.start();
      final port = int.parse(host.listening.first.split(':').last);
      final base = Uri.parse('http://127.0.0.1:$port');
      Future<SyncClient> device(String id) async => SyncClient(
        base,
        token: await SyncClient(base)
            .register((await localPairingCode(hubDir: dir)).code, id, id),
      );
      final pc = await device('pc'), ipad = await device('ipad');
      final clock = SyncClock(deviceId: 'pc');
      final end = DateTime.now().add(Duration(minutes: minutes!));
      var heartbeats = 0, pushes = 0, pulls = 0, waits = 0, checks = 0;
      final failures = <String>[];
      var slowest = Duration.zero;
      final http = HttpClient();
      final sent = <String>{};

      Future<void> timed(String what, Future<void> Function() f) async {
        final w = Stopwatch()..start();
        try {
          await f();
        } catch (e) {
          failures.add('${DateTime.now().toIso8601String()} $what: $e');
        }
        if (w.elapsed > slowest && what != 'wait') slowest = w.elapsed;
      }

      final loops = <Future<void>>[
        // Heartbeats.
        () async {
          while (DateTime.now().isBefore(end)) {
            await timed('status', () async {
              final r = await (await http.getUrl(base.resolve('/v1/status')))
                  .close();
              final body = await utf8.decodeStream(r);
              if (r.statusCode != 200) throw 'status ${r.statusCode}';
              if (!body.contains('THEapp hub')) throw 'not the hub';
              heartbeats++;
            });
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }(),
        // Sync traffic.
        () async {
          var i = 0, since = 0;
          while (DateTime.now().isBefore(end)) {
            final id = 'n${i++}';
            await timed('push', () async {
              await pc.push([
                SyncChange(
                  collection: 'notes',
                  id: id,
                  rev: clock.now(),
                  deleted: false,
                  data: {'id': id, 'title': id},
                ),
              ]);
              sent.add(id);
              pushes++;
            });
            await timed('pull', () async {
              final page = await ipad.pull(since);
              since = page.next;
              pulls++;
            });
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }(),
        // A long-poll always waiting (as an iPad does): from the newest
        // change it knows, so it holds until the next push.
        () async {
          var known = 0;
          while (DateTime.now().isBefore(end)) {
            await timed('wait', () async {
              known = (await ipad.waitForChange(known, seconds: 5)).lastSeq;
              waits++;
            });
          }
        }(),
        // The 10-second health check THEapp runs.
        () async {
          while (DateTime.now().isBefore(end)) {
            await Future<void>.delayed(const Duration(seconds: 10));
            final h = await host.check();
            checks++;
            if (!h.ok) failures.add('check: ${h.problem}');
            if (h.recovered != null) failures.add('recovery: ${h.recovered}');
          }
        }(),
      ];
      final started = DateTime.now();
      await Future.wait(loops);
      final ran = DateTime.now().difference(started);

      // Every record exactly once.
      final seen = <String, int>{};
      var since = 0;
      while (true) {
        final page = await ipad.pull(since);
        for (final c in page.changes) {
          seen[c.id] = (seen[c.id] ?? 0) + 1;
        }
        if (!page.hasMore) break;
        since = page.next;
      }
      final rss = ProcessInfo.currentRss ~/ (1024 * 1024);
      // ignore: avoid_print
      print(
        'Ran ${ran.inSeconds} s: $heartbeats heartbeats, $pushes pushes, '
        '$pulls pulls, $waits long-polls, $checks health checks; '
        '${failures.length} failure(s); slowest request '
        '${slowest.inMilliseconds} ms; records ${seen.length}/${sent.length}; '
        'process memory $rss MB',
      );
      for (final f in failures.take(10)) {
        // ignore: avoid_print
        print(f);
      }
      expect(failures, isEmpty);
      expect(seen.keys.toSet().containsAll(sent), isTrue);
      expect(seen.values.every((n) => n == 1), isTrue);
      http.close(force: true);
      pc.close();
      ipad.close();
      await host.stop();
      dir.deleteSync(recursive: true);
    },
    skip: minutes == null
        ? 'Set THEAPP_STABILITY_MINUTES to run (takes that many minutes)'
        : false,
    timeout: Timeout(Duration(minutes: (minutes ?? 1) + 5)),
  );
}
