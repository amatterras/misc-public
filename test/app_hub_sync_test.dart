// THEapp on Windows end to end, on temporary folders and a real local
// hub: the app runs the hub itself, its 10-second work (here every 300 ms)
// syncs and backs up, a hub that stops answering is noticed (sync is
// reported as failed, never as done), restarted, and the app catches up
// without duplicates; navigating never adds a second scheduler; closing
// the app mid-work leaves no half-written backup and stops the hub.
import 'dart:io';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_host.dart';
import 'package:flutter_application_1/sync/local_hub.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

Future<Duration> until(
  bool Function() done, {
  required String what,
  Duration limit = const Duration(seconds: 20),
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > limit) fail('$what not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return watch.elapsed;
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('theapp_apphub_'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('runs the hub, syncs and backs up every tick, recovers from a hub '
      'that stops answering, and closes cleanly', () async {
    final hubDir = Directory('${root.path}/hub')..createSync();
    final port = await freePort();
    final ws = Workspace(Directory('${root.path}/app'));
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    s.runMaintenance = true;
    s.maintenanceInterval = const Duration(milliseconds: 300);
    s.makeHubHost = () => HubHost(
      dir: hubDir,
      port: port,
      privateAddress: () async => null,
      restartDelays: const [Duration.zero],
    );
    await s.init();
    final host = s.hubHost!;
    expect(host.state, HubHostState.running);
    final m = s.maintenance!;

    // Navigating and reopening pages never adds a scheduler.
    for (var i = 0; i < 10; i++) {
      for (final p in AppPage.values) {
        s.goTo(p);
      }
    }
    expect(identical(s.maintenance, m), isTrue);
    expect(m.timersStarted, 1);

    // Pair the app with its own hub (as Settings → Sync does).
    final code = (await localPairingCode(hubDir: hubDir)).code;
    expect(await s.pairWithHub('http://127.0.0.1:$port', code), isNull);

    // Another device, to see what reached the hub.
    final other = SyncClient(
      Uri.parse('http://127.0.0.1:$port'),
      token: await SyncClient(
        Uri.parse('http://127.0.0.1:$port'),
      ).register((await localPairingCode(hubDir: hubDir)).code, 'ipad', 'iPad'),
    );
    Future<List<String>> hubNotes() async {
      final ids = <String>[];
      var since = 0;
      while (true) {
        final page = await other.pull(since);
        ids.addAll([
          for (final c in page.changes)
            if (c.collection == 'notes' && !c.deleted) c.id,
        ]);
        if (!page.hasMore) break;
        since = page.next;
      }
      return ids;
    }

    final n1 = ws.createNote(title: 'Before');
    await until(
      () =>
          m.job('backup').lastSuccess != null &&
          m.job('hubBackup').lastSuccess != null,
      what: 'first backups',
    );
    await until(() => m.job('sync').lastSuccess != null, what: 'first sync');
    var notes = await hubNotes();
    expect(notes, contains(n1.id));
    expect(
      Directory('${root.path}/app/backups')
          .listSync()
          .any((d) => d.path.endsWith('-live')),
      isTrue,
    );
    expect(Directory('${hubDir.path}/backups/live').listSync(), isNotEmpty);

    // The hub stops answering (its listeners close; the isolate lives).
    final syncedBefore = m.job('sync').lastSuccess;
    await host.debugCloseListeners();
    final n2 = ws.createNote(title: 'Written during the outage');
    await until(
      () => m.job('sync').lastError != null,
      what: 'sync reported as failed',
    );
    // A failure is never shown as a sync.
    expect(m.job('sync').lastSuccess, syncedBefore);
    // Noticed by the health check, restarted, and the edit catches up.
    final took = await until(
      () =>
          m.job('sync').lastSuccess != syncedBefore &&
          m.job('sync').lastError == null,
      what: 'recovery and catch-up',
    );
    // ignore: avoid_print
    print('Recovered and caught up in ${took.inMilliseconds} ms');
    expect(host.state, HubHostState.running);
    expect(host.starts, 1); // restarted in place: never a second hub
    notes = await hubNotes();
    expect(notes.where((id) => id == n2.id), hasLength(1)); // no duplicate
    expect(notes.where((id) => id == n1.id), hasLength(1));

    // Close while the loop runs: nothing half-written, the hub stops.
    ws.createNote(title: 'Last');
    m.tick();
    await s.shutdown();
    expect(
      Directory('${root.path}/app/backups')
          .listSync()
          .where((d) => d.path.contains('.partial-')),
      isEmpty,
    );
    expect(File('${hubDir.path}/hub.json').existsSync(), isFalse);
    expect(host.state, HubHostState.off);
    other.close();
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
