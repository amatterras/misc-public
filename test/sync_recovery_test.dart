// Disconnection recovery (an iPad that lost its hub, was removed, or comes
// back to the front). Real hub on 127.0.0.1, real SyncClient and
// SyncScheduler; AppState drives them exactly as the app does.
//
// Each test names the defect it guards:
//  1. A device removed while only the live connection was waiting was never
//     told (the scheduler just stopped; the status kept saying "Synced").
//  2. After "pairing required", coming back to the front never looked again,
//     even when the hub was fine.
//  3. A failure that waiting cannot fix showed as "…· live".
//  4. Stopping and starting again (iPad to the background and back) kept the
//     old failure count, so the first retry could wait up to 30 s.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/features/settings/sync_section.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_keys.dart';

final sep = Platform.pathSeparator;

Future<Duration> until(
  bool Function() done, {
  required String what,
  Duration limit = const Duration(seconds: 20),
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > limit) fail('$what not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return watch.elapsed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the local hub

  late Directory root;
  late HubServer hub;
  late Directory hubDir;
  late int port;
  final apps = <AppState>[];

  Future<HubServer> startHub(Directory dir, {int? at}) => HubServer.start(
    dir: dir,
    port: at ?? 0,
    dailyBackups: false,
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_recover_');
    hubDir = Directory('${root.path}${sep}hub');
    hub = await startHub(hubDir);
    port = hub.port;
  });

  tearDown(() async {
    for (final s in apps) {
      s.dispose();
    }
    apps.clear();
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Uri url() => Uri.parse('http://127.0.0.1:$port');

  Future<AppState> pairedApp() async {
    final ws = Workspace(Directory('${root.path}${sep}app'));
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await shareSyncKey(s);
    await s.init();
    apps.add(s);
    expect(
      await s.pairWithHub(url().toString(), hub.auth.createPairingCode()),
      isNull,
    );
    await s.syncNow();
    await until(
      () => s.syncConnection == SyncConnection.live,
      what: 'the app is live',
    );
    return s;
  }

  test('1. a device removed while only the live connection is waiting is told '
      'it must pair again (no sync cycle needed)', () async {
    final s = await pairedApp();
    // Nothing is edited here, so only the live connection can notice.
    expect(await hub.auth.revoke(s.workspace.device!.id), isTrue);

    await until(() => s.syncNeedsPairing, what: 'pairing-required state');
    final note = s.workspace.createNote(title: 'Kept while unauthorized');
    expect(s.syncStatus, contains('pair'));
    expect(s.syncStatus, isNot(contains('live')));
    expect(s.syncConnection, SyncConnection.stopped);
    expect(s.syncScheduled, isFalse, reason: 'no retry every minute');
    expect(s.workspace.notes[note.id], isNotNull, reason: 'nothing lost');
  });

  test('2. coming back to the front looks again: a hub that accepts the '
      'device clears "pairing required" by itself', () async {
    final s = await pairedApp();
    // The wrong hub answers on the same address (an empty one, e.g. started
    // by mistake or from a different folder): this device is unknown to it.
    await hub.stop();
    final wrong = await startHub(
      Directory('${root.path}${sep}wrong-hub'),
      at: port,
    );
    await until(() => s.syncNeedsPairing, what: 'pairing-required state');
    await wrong.stop();
    // The right hub is back; the device comes back to the front.
    hub = await startHub(hubDir, at: port);
    expect(s.syncNeedsPairing, isTrue, reason: 'still the old verdict');
    await s.appResumed();
    await until(() => !s.syncNeedsPairing, what: 'authorized again');
    expect(s.syncStatus, startsWith('Synced'));
    await until(
      () => s.syncConnection == SyncConnection.live,
      what: 'live again',
    );
  });

  test('2b. "Sync now" is also a way back from "pairing required"', () async {
    final s = await pairedApp();
    await hub.stop();
    final wrong = await startHub(
      Directory('${root.path}${sep}wrong-hub'),
      at: port,
    );
    await until(() => s.syncNeedsPairing, what: 'pairing-required state');
    await wrong.stop();
    hub = await startHub(hubDir, at: port);
    await s.syncNow();
    expect(s.syncNeedsPairing, isFalse);
    expect(s.syncStatus, startsWith('Synced'));
  });

  test('2c. a device that is really removed stays "pairing required" after '
      'coming back to the front (no loop, nothing lost)', () async {
    final s = await pairedApp();
    final note = s.workspace.createNote(title: 'Unsent');
    expect(await hub.auth.revoke(s.workspace.device!.id), isTrue);
    await until(() => s.syncNeedsPairing, what: 'pairing-required state');
    await s.appResumed();
    await until(() => !s.syncing, what: 'the re-check finished');
    expect(s.syncNeedsPairing, isTrue);
    expect(s.syncConnection, SyncConnection.stopped);
    expect(s.workspace.notes[note.id], isNotNull);
    expect(await hub.store.current('notes', note.id), isNull);
  });

  testWidgets('2d. Settings says sync is stopped and offers "Check again", '
      'which brings sync back when the hub accepts the device', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = (await tester.runAsync(pairedApp))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncSection(state: s)),
      ),
    );
    expect(find.byKey(const ValueKey('reauthorize-notice')), findsNothing);
    await tester.runAsync(() async {
      await hub.stop();
      final wrong = await startHub(
        Directory('${root.path}${sep}wrong-hub'),
        at: port,
      );
      await until(() => s.syncNeedsPairing, what: 'pairing-required state');
      await wrong.stop();
      hub = await startHub(hubDir, at: port);
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('reauthorize-notice')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('reauthorize-check')));
      await until(() => !s.syncNeedsPairing, what: 'authorized again');
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('reauthorize-notice')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  group('scheduler', () {
    late HttpServer fake;
    var waitStatus = 200;
    Map<String, Object?> waitBody = {'lastSeq': 0, 'hubId': 'fake'};

    setUp(() async {
      waitStatus = 200;
      waitBody = {'lastSeq': 0, 'hubId': 'fake'};
      fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      fake.listen((req) async {
        // Like the real hub, hold the long-poll a little (not a busy loop).
        await Future<void>.delayed(const Duration(milliseconds: 150));
        req.response.statusCode = waitStatus;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(waitBody));
        await req.response.close();
      });
    });
    tearDown(() => fake.close(force: true));

    SyncScheduler make(
      Future<void> Function() run, {
      void Function(SyncFailure)? onBlocked,
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
    );

    test('3. a failure that waiting cannot fix is "blocked", not "live", and '
        'a later success clears it', () async {
      var failing = true;
      final blocked = <String>[];
      final s = make(() async {
        if (failing) {
          throw const SyncFailure(
            'protocol_mismatch',
            'Update the app.',
          );
        }
      }, onBlocked: (e) => blocked.add(e.code));
      s.start();
      await until(
        () => s.connection == SyncConnection.blocked,
        what: 'blocked state',
      );
      expect(blocked, contains('protocol_mismatch'));
      failing = false;
      await s.syncNow();
      expect(s.connection, isNot(SyncConnection.blocked));
      await s.close();
    });

    test('3b. "unauthorized" stops the scheduler and tells the app once, from '
        'the live connection as well as from a cycle', () async {
      waitStatus = 401;
      waitBody = {'error': 'unauthorized', 'message': 'no'};
      final blocked = <String>[];
      final s = make(() async {}, onBlocked: (e) => blocked.add(e.code));
      s.start();
      await until(() => blocked.isNotEmpty, what: 'told the app');
      expect(blocked, ['unauthorized']);
      expect(s.connection, SyncConnection.stopped);
      expect(s.scheduled, isFalse);
      await s.close();
    });

    test('4. stopping and starting again forgets old failures, so the first '
        'retry after returning to the front is immediate', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();
      final s = make(
        () async {},
        at: Uri.parse('http://127.0.0.1:$deadPort'),
      );
      s.start();
      await until(() => s.failures >= 2, what: 'two failures');
      s.stop();
      s.start();
      expect(s.failures, 0);
      await s.close();
    });
  });
}
