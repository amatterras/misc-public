// End-to-end scenarios across devices, replacing a hand-run checklist. Every
// scenario uses the production AppState / SyncScheduler / SyncEngine and a
// real hub on 127.0.0.1; the network of each device is a FlakyProxy the test
// controls, so connection loss, airplane mode, a refused device and a
// restarted hub are reproduced exactly and repeatably.
//
// Status honesty is asserted throughout: while sync cannot happen, the status
// text never says "Synced" or "live".

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_keys.dart';
import 'support/sync_rig.dart';

/// The status line must not claim a working connection.
void expectNotClaimingSync(AppState s, String when) {
  expect(
    s.syncStatus,
    isNot(anyOf(startsWith('Synced'), contains('· live'))),
    reason: '$when: "${s.syncStatus}"',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncRig rig;

  setUp(() async => rig = await SyncRig.start());
  tearDown(() => rig.close());

  // ---------------------------------------------------------------- pairing
  group('1. pairing', () {
    test('a device pairs, and notes travel both ways within seconds', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      final a = pc.s.workspace.createNote(title: 'From the PC', body: 'one');
      await until(
        () => ipad.s.workspace.notes[a.id]?.body == 'one',
        what: 'PC note on the iPad',
      );
      final b = ipad.s.workspace.createNote(
        title: 'From the iPad',
        body: 'two',
      );
      await until(
        () => pc.s.workspace.notes[b.id]?.body == 'two',
        what: 'iPad note on the PC',
      );
    });

    test('a wrong, a reused and a throttled pairing code are refused with a '
        'message and change nothing', () async {
      final ipad = await rig.device('ipad', ipad: true, pair: false);
      final wrong = await ipad.s.pairWithHub(
        'http://127.0.0.1:${ipad.proxy.port}',
        'WRONG123',
      );
      expect(wrong, isNotNull);
      expect(ipad.s.syncPaired, isFalse);
      expect(ipad.s.syncConnection, SyncConnection.stopped);
      // A code works once.
      final code = rig.hub.auth.createPairingCode();
      final other = await rig.device('other', pair: false);
      expect(
        await other.s.pairWithHub('http://127.0.0.1:${other.proxy.port}', code),
        isNull,
      );
      final again = await ipad.s.pairWithHub(
        'http://127.0.0.1:${ipad.proxy.port}',
        code,
      );
      expect(again, isNotNull, reason: 'single use');
      expect(ipad.s.syncPaired, isFalse);
      // Repeated wrong codes are throttled (and still change nothing).
      String? last;
      for (var i = 0; i < 7; i++) {
        last = await ipad.s.pairWithHub(
          'http://127.0.0.1:${ipad.proxy.port}',
          'BADCODE$i',
        );
      }
      expect(last, isNotNull);
      expect(ipad.s.syncPaired, isFalse);
    });

    test(
      'an expired code is refused with a message and changes nothing; a fresh '
      'one works; the throttle after wrong codes ends with time',
      () async {
        final ipad = await rig.device('ipad', ipad: true, pair: false);
        final url = 'http://127.0.0.1:${ipad.proxy.port}';
        final stale = keyedPairingCode(rig.hub.auth);
        // Eleven minutes later the code (valid for ten) is no good.
        rig.hub.auth.clock = () =>
            DateTime.now().add(const Duration(minutes: 11));
        final expired = await ipad.s.pairWithHub(url, stale);
        expect(expired, isNotNull);
        expect(ipad.s.syncPaired, isFalse);
        expect(ipad.s.syncConnection, SyncConnection.stopped);
        // Wrong codes are throttled ...
        rig.hub.auth.clock = DateTime.now;
        for (var i = 0; i < 6; i++) {
          await ipad.s.pairWithHub(url, 'WRONGCODE$i');
        }
        final throttled = await ipad.s.pairWithHub(
          url,
          keyedPairingCode(rig.hub.auth),
        );
        expect(throttled, isNotNull, reason: 'blocked for a while');
        // ... and the throttle ends: later, a fresh code works.
        rig.hub.auth.clock = () =>
            DateTime.now().add(const Duration(minutes: 11));
        final fresh = keyedPairingCode(rig.hub.auth);
        expect(await ipad.s.pairWithHub(url, fresh), isNull);
        rig.hub.auth.clock = DateTime.now;
        expect(ipad.s.syncPaired, isTrue);
      },
    );

    test(
      'an address that cannot be reached is a message, not a crash',
      () async {
        final ipad = await rig.device('ipad', ipad: true, pair: false);
        await ipad.proxy.down();
        final r = await ipad.s.pairWithHub(
          'http://127.0.0.1:${ipad.proxy.port}',
          rig.hub.auth.createPairingCode(),
        );
        expect(r, isNotNull);
        expect(ipad.s.syncPaired, isFalse);
      },
    );
  });

  // ------------------------------------------------------ offline and back
  group('2. network loss and recovery', () {
    test('airplane mode: edits are kept, the status never claims sync, and '
        'everything arrives when the network returns', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      await ipad.proxy.down(); // airplane mode on
      await until(
        () => ipad.s.syncConnection == SyncConnection.offline,
        what: 'the iPad notices',
      );
      expectNotClaimingSync(ipad.s, 'offline');
      final n1 = ipad.s.workspace.createNote(title: 'Offline 1', body: 'a');
      final n2 = ipad.s.workspace.createNote(title: 'Offline 2', body: 'b');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(ipad.s.syncPendingLocal, isTrue);
      expectNotClaimingSync(ipad.s, 'offline with edits');
      expect(pc.s.workspace.notes[n1.id], isNull);
      await ipad.proxy.up(); // airplane mode off
      await until(
        () =>
            pc.s.workspace.notes[n1.id] != null &&
            pc.s.workspace.notes[n2.id] != null,
        what: 'offline notes on the PC',
        limit: const Duration(seconds: 45),
      );
      await until(
        () => ipad.s.syncConnection == SyncConnection.live,
        what: 'live again',
      );
      await until(() => !ipad.s.syncPendingLocal, what: 'nothing waiting');
    });

    test('a long offline period with many edits on both sides converges '
        'without duplicates', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      await pc.proxy.down();
      await ipad.proxy.down();
      final ids = <String>[];
      for (var i = 0; i < 25; i++) {
        ids.add(pc.s.workspace.createNote(title: 'PC $i', body: 'p$i').id);
        ids.add(ipad.s.workspace.createNote(title: 'iPad $i', body: 'i$i').id);
      }
      await pc.proxy.up();
      await ipad.proxy.up();
      await until(
        () =>
            ids.every((id) => pc.s.workspace.notes[id] != null) &&
            ids.every((id) => ipad.s.workspace.notes[id] != null),
        what: 'all 50 notes on both',
        limit: const Duration(seconds: 60),
      );
      expect(pc.s.workspace.notes.length, 50);
      expect(ipad.s.workspace.notes.length, 50);
      expect(rig.hub.store.stats.records, greaterThanOrEqualTo(50));
    });

    test('repeated connection failures back off (bounded requests) and '
        'recover without a restart', () async {
      final ipad = await rig.device('ipad', ipad: true);
      await ipad.proxy.down();
      await until(
        () => ipad.s.syncConnection == SyncConnection.offline,
        what: 'offline',
      );
      // While the network is down the device keeps retrying, slowly: the
      // pause grows, so a few seconds of outage is a few attempts, not a storm.
      final failures0 = ipad.s.syncFailures;
      await Future<void>.delayed(const Duration(seconds: 6));
      final attempts = ipad.s.syncFailures - failures0;
      expect(
        attempts,
        lessThanOrEqualTo(6),
        reason: 'backed off, not spinning',
      );
      expectNotClaimingSync(ipad.s, 'repeatedly failing');
      await ipad.proxy.up();
      final n = ipad.s.workspace.createNote(title: 'After the outage');
      await until(
        () => rig.hub.store.current('notes', n.id).then((c) => c != null),
        what: 'edit reaches the hub after recovery',
        limit: const Duration(seconds: 45),
      );
    });

    test('the hub is not running when the app starts: it opens, says so, '
        'and syncs once the hub is there', () async {
      final ipad = await rig.device('ipad', ipad: true);
      final n0 = ipad.s.workspace.createNote(title: 'Before closing');
      await ipad.s.syncNow();
      await rig.quiesce(ipad);
      await rig.stopHub();
      await rig.restart(ipad); // the app starts while the hub is down
      final n1 = ipad.s.workspace.createNote(title: 'While the hub is down');
      await until(
        () => ipad.s.syncConnection == SyncConnection.offline,
        what: 'offline at launch',
      );
      expectNotClaimingSync(ipad.s, 'hub down at launch');
      expect(ipad.s.workspace.notes[n0.id], isNotNull);
      await rig.startHub();
      await until(
        () => rig.hub.store.current('notes', n1.id).then((c) => c != null),
        what: 'the note written while the hub was down',
        limit: const Duration(seconds: 45),
      );
    });

    test('the hub stops during a live connection and comes back', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      await rig.stopHub();
      await until(
        () => ipad.s.syncConnection == SyncConnection.offline,
        what: 'iPad offline',
      );
      expectNotClaimingSync(ipad.s, 'hub stopped');
      final n = pc.s.workspace.createNote(title: 'During the outage');
      await rig.startHub();
      await until(
        () => ipad.s.workspace.notes[n.id] != null,
        what: 'note on the iPad after the hub restarted',
        limit: const Duration(seconds: 45),
      );
    });

    test(
      'several devices reconnect at the same moment and all converge',
      () async {
        final devs = [
          await rig.device('a'),
          await rig.device('b', ipad: true),
          await rig.device('c', ipad: true),
          await rig.device('d'),
        ];
        for (final d in devs) {
          await d.proxy.down();
        }
        final ids = <String>[];
        for (final d in devs) {
          for (var i = 0; i < 4; i++) {
            ids.add(d.s.workspace.createNote(title: '${d.name} $i').id);
          }
        }
        for (final d in devs) {
          await d.proxy.up();
        }
        await until(
          () => devs.every(
            (d) => ids.every((id) => d.s.workspace.notes[id] != null),
          ),
          what: 'all 16 notes on all 4 devices',
          limit: const Duration(seconds: 60),
        );
        for (final d in devs) {
          expect(d.s.workspace.notes.length, 16, reason: d.name);
        }
      },
    );
  });

  // ------------------------------------------------------------ lifecycle
  group('3. the app in the background', () {
    test('changes made elsewhere while the iPad is in the background arrive '
        'on return, and the status is honest meanwhile', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      ipad.s.syncPaused();
      expect(ipad.s.syncConnection, SyncConnection.stopped);
      expectNotClaimingSync(ipad.s, 'in the background');
      final n = pc.s.workspace.createNote(title: 'While you were away');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(ipad.s.workspace.notes[n.id], isNull);
      await ipad.s.appResumed();
      await until(
        () => ipad.s.workspace.notes[n.id] != null,
        what: 'note after returning',
      );
      await until(
        () => ipad.s.syncConnection == SyncConnection.live,
        what: 'live after returning',
      );
    });

    test('returning from the background after a long time with the network '
        'gone leaves an honest "offline", then recovers', () async {
      final ipad = await rig.device('ipad', ipad: true);
      ipad.s.syncPaused();
      await ipad.proxy.down();
      await ipad.s.appResumed();
      await until(
        () => ipad.s.syncConnection == SyncConnection.offline,
        what: 'offline after returning',
      );
      expectNotClaimingSync(ipad.s, 'back, no network');
      await ipad.proxy.up();
      final n = ipad.s.workspace.createNote(title: 'Back online');
      await until(
        () => rig.hub.store.current('notes', n.id).then((c) => c != null),
        what: 'note on the hub',
        limit: const Duration(seconds: 45),
      );
    });

    test('going to the background and back many times keeps one connection '
        'and loses nothing', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      for (var i = 0; i < 8; i++) {
        ipad.s.syncPaused();
        pc.s.workspace.createNote(title: 'Round $i');
        await ipad.s.appResumed();
      }
      await until(
        () => ipad.s.workspace.notes.length == 8,
        what: 'all notes on the iPad',
        limit: const Duration(seconds: 30),
      );
      expect(ipad.s.syncConnection, isNot(SyncConnection.stopped));
    });
  });

  // ---------------------------------------------- authentication / revoke
  group('4. a device the hub refuses', () {
    test('revoked: stops, says pairing is needed, keeps its edits; pairing '
        'again delivers them', () async {
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      expect(await rig.hub.auth.revoke(ipad.s.workspace.device!.id), isTrue);
      await until(() => ipad.s.syncNeedsPairing, what: 'pairing required');
      expectNotClaimingSync(ipad.s, 'revoked');
      expect(ipad.s.syncConnection, SyncConnection.stopped);
      final n = ipad.s.workspace.createNote(title: 'Written when refused');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await rig.hub.store.current('notes', n.id), isNull);
      expect(
        pc.s.syncConnection,
        SyncConnection.live,
        reason: 'others unaffected',
      );
      // Pair again (as a device with the key would).
      await ipad.s.disconnectHub();
      expect(
        await ipad.s.pairWithHub(
          'http://127.0.0.1:${ipad.proxy.port}',
          keyedPairingCode(rig.hub.auth),
        ),
        isNull,
      );
      await until(
        () => pc.s.workspace.notes[n.id] != null,
        what: 'the unsent note on the PC',
        limit: const Duration(seconds: 30),
      );
    });

    test(
      'a hub that stops accepting the device mid-session (401 for '
      'everything) is not "live"; accepting again recovers on return',
      () async {
        final ipad = await rig.device('ipad', ipad: true);
        ipad.proxy.refuseAuth = true;
        ipad.s.workspace.createNote(title: 'Edit while refused');
        await until(() => ipad.s.syncNeedsPairing, what: 'pairing required');
        expectNotClaimingSync(ipad.s, 'refused');
        ipad.proxy.refuseAuth = false;
        await ipad.s.appResumed();
        await until(() => !ipad.s.syncNeedsPairing, what: 'accepted again');
        expect(ipad.s.syncStatus, startsWith('Synced'));
      },
    );

    test('a removed device does not spin: no requests pile up while it '
        'waits for pairing', () async {
      final ipad = await rig.device('ipad', ipad: true);
      expect(await rig.hub.auth.revoke(ipad.s.workspace.device!.id), isTrue);
      await until(() => ipad.s.syncNeedsPairing, what: 'pairing required');
      final before = ipad.proxy.requests;
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(ipad.proxy.requests - before, lessThanOrEqualTo(2));
    });
  });

  // -------------------------------------------- a refusal waiting cannot fix
  group('4c. a hub that refuses for a lasting reason', () {
    test('the PC does not ask again every 10 seconds, says why, and recovers '
        'by itself when the cause goes away', () async {
      final pc = await rig.device('pc');
      pc.s.runMaintenance = true; // the Windows 10-second job
      pc.s.maintenanceInterval = const Duration(milliseconds: 100);
      pc.s.startMaintenanceForTests();
      pc.proxy.refuseWith = (status: 426, code: 'protocol_mismatch');
      pc.s.workspace.createNote(title: 'Edit while refused');
      await until(
        () => pc.s.syncConnection == SyncConnection.blocked,
        what: 'blocked',
      );
      expect(pc.s.syncStatus, isNot(startsWith('Synced')));
      expect(pc.s.syncStatus, isNot(contains('live')));
      final before = pc.proxy.requests;
      await Future<void>.delayed(const Duration(seconds: 4));
      // 40 job ticks happened; a refusal is asked again after the scheduler's
      // pause (15 s), not on every tick.
      expect(pc.proxy.requests - before, lessThanOrEqualTo(6));
      // "Sync now" is never held back, and a cure is noticed at once.
      pc.proxy.refuseWith = null;
      await pc.s.syncNow();
      await until(
        () => pc.s.syncStatus.startsWith('Synced'),
        what: 'recovered',
      );
      expect(pc.s.syncConnection, isNot(SyncConnection.blocked));
    });
  });

  // ------------------------------------------------- data that cannot sync
  group('4b. a record that can never sync', () {
    test('is reported (never plain "Synced"), stays on the device, and does '
        'not block the other changes', () async {
      final pc = await rig.device('pc');
      final other = await rig.device('other', ipad: true);
      final huge = pc.s.workspace.createNote(
        title: 'Too large',
        body: 'x' * (1100 * 1024), // over the 1 MB record limit
      );
      final small = pc.s.workspace.createNote(title: 'Small', body: 'ok');
      await until(
        () => other.s.workspace.notes[small.id] != null,
        what: 'the small note on the other device',
      );
      await until(
        () => pc.s.syncStatus.startsWith('Some changes could not sync'),
        what: 'an honest status',
      );
      expect(pc.s.syncStatus, contains('too large'));
      expect(pc.s.syncStatus, isNot(startsWith('Synced')));
      expect(pc.s.workspace.notes[huge.id], isNotNull, reason: 'kept here');
      expect(other.s.workspace.notes[huge.id], isNull);
    });
  });

  // ------------------------------------------------------------ conflicts
  group('5. conflicts across devices', () {
    test(
      'the full sequence: edit offline on two devices, reconnect one then '
      'the other, conflict, resolve, restart mid-way, everything intact',
      () async {
        final pc = await rig.device('pc');
        final ipad = await rig.device('ipad', ipad: true);
        final note = pc.s.workspace.createNote(title: 'Shared', body: 'start');
        await until(
          () => ipad.s.workspace.notes[note.id] != null,
          what: 'note on the iPad',
        );
        // 1. both edit while offline
        await pc.proxy.down();
        await ipad.proxy.down();
        pc.s.workspace.notes.put(
          pc.s.workspace.notes[note.id]!.copyWith(body: 'edited on the PC'),
        );
        ipad.s.workspace.notes.put(
          ipad.s.workspace.notes[note.id]!.copyWith(body: 'edited on the iPad'),
        );
        // 2. the iPad reconnects first, 3. the PC later
        await ipad.proxy.up();
        await until(
          () async =>
              (await rig.hub.store.current('notes', note.id)) != null &&
              openedData(
                    await rig.hub.store.current('notes', note.id),
                  )?['body'] ==
                  'edited on the iPad',
          what: 'the iPad edit on the hub',
          limit: const Duration(seconds: 45),
        );
        await pc.proxy.up();
        // 4. a conflict is created and reaches both devices
        await until(
          () => pc.s.openConflictCount == 1 && ipad.s.openConflictCount == 1,
          what: 'the conflict on both',
          limit: const Duration(seconds: 45),
        );
        final conflict = pc.s.conflictResolver.open().single;
        final loser = conflict.otherData!['body'];
        final winner = pc.s.workspace.notes[note.id]!.body;
        expect({winner, loser}, {'edited on the PC', 'edited on the iPad'});
        // Opening / listing changed nothing.
        expect(pc.s.workspace.notes[note.id]!.body, winner);
        // 5. the user resolves, 6. the app is interrupted during the resolution
        pc.s.conflictResolver.debugInterruptAfterIntent = true;
        await expectLater(
          pc.s.conflictResolver.useOther(conflict),
          throwsA(isA<StateError>()),
        );
        await rig.restart(pc);
        // 7./8. after the restart both versions and a consistent state remain
        // (the unfinished settling was completed while the app started).
        final p = pc.s;
        final settled = p.workspace.conflicts.all.where((c) => c.isResolved);
        expect(settled, hasLength(1));
        expect(settled.single.otherData?['body'], loser);
        expect(settled.single.replacedData?['body'], winner);
        expect(p.workspace.notes[note.id]!.body, loser);
        expect(p.openConflictCount, 0);
      },
    );
  });
}
