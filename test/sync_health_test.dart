// Sync Health: the diagnosis picks the right plain-language message and safe
// next step for each situation, copied reports and history never contain
// addresses, keys or note text, and the center opens and renders.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/sync_health/sync_health_center.dart';
import 'package:flutter_application_1/sync/sync_health.dart';
import 'package:flutter_application_1/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

SyncFacts facts({
  bool paired = true,
  bool needsPairing = false,
  bool enabled = true,
  SyncConnection connection = SyncConnection.live,
  bool syncing = false,
  DateTime? lastSynced,
  int pending = 0,
  int conflicts = 0,
  bool failed = false,
}) => SyncFacts(
  paired: paired,
  needsPairing: needsPairing,
  enabled: enabled,
  connection: connection,
  syncing: syncing,
  lastSynced: lastSynced ?? DateTime.now(),
  pendingCount: pending,
  conflictCount: conflicts,
  lastAttemptFailed: failed,
);

void main() {
  test('every situation gets the right level and next step', () {
    var d = diagnoseSync(facts(paired: false));
    expect(d.level, SyncLevel.ok);
    expect(d.title, contains('not connected'));

    d = diagnoseSync(facts());
    expect(d.level, SyncLevel.ok);
    expect(d.title, 'Everything is synced');

    d = diagnoseSync(facts(needsPairing: true, pending: 3));
    expect(d.level, SyncLevel.problem);
    expect(d.steps, [SyncStep.pairAgain]);
    expect(d.detail, contains('3 changes'));

    d = diagnoseSync(facts(enabled: false, pending: 1));
    expect(d.steps, [SyncStep.turnOnSync]);
    expect(d.detail, contains('1 change '));

    d = diagnoseSync(facts(connection: SyncConnection.paused));
    expect(d.level, SyncLevel.attention);
    expect(d.title, contains('paused on the PC'));

    d = diagnoseSync(facts(connection: SyncConnection.offline, pending: 4));
    expect(d.level, SyncLevel.waiting);
    expect(d.steps, [SyncStep.syncNow]);
    expect(d.help, isNotEmpty);
    expect(d.detail, contains('4 changes'));

    d = diagnoseSync(facts(conflicts: 2, pending: 1));
    expect(d.steps.first, SyncStep.reviewConflicts);
    expect(d.title, contains('2 conflicts'));

    d = diagnoseSync(facts(failed: true));
    expect(d.title, contains('did not finish'));

    d = diagnoseSync(facts(pending: 2));
    expect(d.title, '2 changes waiting to sync');
  });

  test('offline outranks conflicts; pairing outranks everything', () {
    expect(
      diagnoseSync(
        facts(connection: SyncConnection.offline, conflicts: 3),
      ).title,
      contains('cannot be reached'),
    );
    expect(
      diagnoseSync(
        facts(needsPairing: true, enabled: false, conflicts: 3),
      ).level,
      SyncLevel.problem,
    );
  });

  test('scrub removes addresses, keys and long tokens', () {
    final t = scrubDiagnostic(
      'Could not reach http://100.64.1.2:47710/sync with '
      'abcdefghijklmnopqrstuvwxyz0123456789 on 192.168.0.5 or pc.tail1.ts.net',
    );
    expect(t, isNot(contains('http')));
    expect(t, isNot(contains('100.64')));
    expect(t, isNot(contains('192.168')));
    expect(t, isNot(contains('abcdefghijklmnop')));
    expect(t, isNot(contains('ts.net')));
    expect(scrubDiagnostic('x' * 400).length, lessThanOrEqualTo(160));
  });

  test('copied report has counts and states but no addresses or text', () {
    final f = facts(connection: SyncConnection.offline, pending: 2);
    final now = DateTime.now();
    final text = syncDiagnosticsText(
      facts: f,
      diagnosis: diagnoseSync(f),
      pendingByKind: const {'notes': 2},
      history: [
        SyncAttempt(now, false, 'Hub http://10.0.0.7:47710 not reachable'),
      ],
      now: now,
    );
    expect(text, contains('Changes waiting: 2'));
    expect(text, contains('waiting notes: 2'));
    expect(text, contains('FAIL'));
    expect(text, isNot(contains('10.0.0.7')));
    expect(text, isNot(contains('http')));
  });

  testWidgets('the center opens for an unpaired device and closes', (t) async {
    final dir = Directory.systemTemp.createTempSync('theapp_synchealth_');
    final ws = Workspace(Directory('${dir.path}/data'));
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await t.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSyncHealthCenter(context, s),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sync-health-center')), findsOneWidget);
    expect(
      find.text('This device is not connected to a sync hub'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('sync-health-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-health-backup')), findsOneWidget);
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sync-health-center')), findsNothing);
  });
}
