// Conflict handling under bad conditions: malformed records, duplicates,
// repeated undo/redo, double taps, an app killed half way through a settling,
// retention, and several devices. The standard is the data, not the screen:
// every test checks that BOTH versions are still somewhere after the action.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/sync_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/settings/conflict_review.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_rig.dart';

final sep2 = Platform.pathSeparator;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final apps = <AppState>[];

  setUp(() => root = Directory.systemTemp.createTempSync('theapp_cfrob_'));
  tearDown(() {
    for (final s in apps) {
      s.dispose();
    }
    apps.clear();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppState open(String name) {
    final ws = Workspace(Directory('${root.path}$sep2$name'));
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    apps.add(s);
    return s;
  }

  Future<AppState> booted(String name) async {
    final s = open(name);
    await s.init();
    return s;
  }

  SyncConflict conflictFor(
    AppState s,
    String noteId, {
    String id = 'cf-1',
    String body = 'other text',
    String keptRev = '0001792610475963-0000-aaaa',
  }) {
    final note = s.workspace.notes[noteId]!;
    return SyncConflict({
      'id': id,
      'collection': 'notes',
      'recordId': noteId,
      'reason': 'concurrent_edit',
      'keptRev': keptRev,
      'keptDevice': 'aaaa',
      'otherRev': '0001792610475000-0000-bbbb',
      'otherDevice': 'bbbb',
      'otherData': note.copyWith(body: body).toJson(),
      'at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  group('malformed records', () {
    test('every odd shape is listed and kept, never a crash; nothing is '
        'restorable that cannot be', () async {
      final s = await booted('a');
      final odd = <Map<String, dynamic>>[
        {'id': 'm1'},
        {'id': 'm2', 'collection': 7, 'recordId': null, 'reason': []},
        {
          'id': 'm3',
          'collection': 'notes',
          'recordId': 'x',
          'otherData': 'text',
        },
        {'id': 'm4', 'collection': 'notes', 'recordId': 'x', 'otherData': 5},
        {
          'id': 'm5',
          'collection': 'canvas_items',
          'recordId': 'no-slash',
          'otherData': {'a': 1},
        },
        {
          'id': 'm6',
          'collection': 'tasks',
          'recordId': 't',
          'otherDeleted': 'yes',
        },
        {
          'id': 'm7',
          'collection': 'notes',
          'recordId': 'x',
          'resolved': 'oops',
        },
        {
          'id': 'm8',
          'collection': 'notes',
          'recordId': 'x',
          'keptRev': 4,
          'otherRev': {},
        },
      ];
      for (final j in odd) {
        s.workspace.conflicts.put(SyncConflict(j));
      }
      final all = s.workspace.conflicts.all.toList();
      expect(all, hasLength(odd.length));
      for (final c in all) {
        // Reading any property must not throw.
        c.collection;
        c.recordId;
        c.reason;
        c.otherData;
        c.otherDeleted;
        c.keptRev;
        c.otherRev;
        c.isResolved;
        c.choice;
        c.replacedData;
        await s.conflictResolver.sides(c);
      }
      final resolver = s.conflictResolver;
      expect(
        resolver.canUseOther(all.firstWhere((c) => c.id == 'm1')),
        isFalse,
      );
      expect(
        resolver.canUseOther(all.firstWhere((c) => c.id == 'm3')),
        isFalse,
      );
      expect(
        resolver.canUseOther(all.firstWhere((c) => c.id == 'm5')),
        isFalse,
      );
      expect(
        await resolver.useOther(all.firstWhere((c) => c.id == 'm1')),
        isFalse,
      );
      // Each can still be kept (settled), and keeps its content.
      for (final c in all) {
        resolver.keepCurrent(c);
      }
      expect(s.openConflictCount, 0);
      expect(
        s.workspace.conflicts['m3']!.data['otherData'],
        'text',
        reason: 'what was there stays there',
      );
    });

    testWidgets('the review window shows malformed conflicts without '
        'throwing', (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = open('ui');
      await tester.runAsync(s.init);
      s.workspace.conflicts
        ..put(SyncConflict({'id': 'm1'}))
        ..put(SyncConflict({'id': 'm2', 'collection': 9, 'otherData': 'x'}));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showConflictReview(context, s),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('conflict-m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('conflict-m2')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('opening never changes data', () {
    test('listing, inspecting and checking a conflict write nothing', () async {
      final s = await booted('a');
      final note = s.workspace.createNote(title: 'N', body: 'current');
      s.workspace.conflicts.put(conflictFor(s, note.id));
      await s.flush();
      var changes = 0;
      void count() => changes++;
      s.workspace.changes.addListener(count);
      final before = s.workspace.notes[note.id]!.toJson().toString();
      final c = s.conflictResolver.open().single;
      await s.conflictResolver.sides(c);
      s.conflictResolver.canUseOther(c);
      s.conflictResolver.settled();
      s.openConflictCount;
      expect(changes, 0, reason: 'no record was written');
      expect(s.workspace.notes[note.id]!.toJson().toString(), before);
      expect(s.workspace.conflicts.length, 1);
      s.workspace.changes.removeListener(count);
    });
  });

  group('choices', () {
    test('both choices work, and each keeps both versions', () async {
      final s = await booted('a');
      final note = s.workspace.createNote(title: 'N', body: 'current');
      s.workspace.conflicts
        ..put(conflictFor(s, note.id, id: 'keep', body: 'other A'))
        ..put(conflictFor(s, note.id, id: 'use', body: 'other B'));
      final r = s.conflictResolver;
      r.keepCurrent(s.workspace.conflicts['keep']!);
      expect(s.workspace.notes[note.id]!.body, 'current');
      final kept = s.workspace.conflicts['keep']!;
      expect(kept.choice, 'kept_current');
      expect((kept.otherData)?['body'], 'other A');

      expect(await r.useOther(s.workspace.conflicts['use']!), isTrue);
      expect(s.workspace.notes[note.id]!.body, 'other B');
      final used = s.workspace.conflicts['use']!;
      expect(used.choice, 'used_other');
      expect(used.replacedData?['body'], 'current');
      expect(used.otherData?['body'], 'other B');
      expect(used.isApplying, isFalse);
    });

    test(
      'settling twice (a double tap, two calls at once) does one thing',
      () async {
        final s = await booted('a');
        final note = s.workspace.createNote(title: 'N', body: 'current');
        s.workspace.conflicts.put(conflictFor(s, note.id));
        final c = s.workspace.conflicts['cf-1']!;
        final results = await Future.wait([
          s.conflictResolver.useOther(c),
          s.conflictResolver.useOther(c),
        ]);
        expect(results.where((r) => r).length, lessThanOrEqualTo(2));
        expect(s.workspace.notes[note.id]!.body, 'other text');
        final settled = s.workspace.conflicts['cf-1']!;
        expect(
          settled.replacedData?['body'],
          'current',
          reason: 'the replaced version must not become "other text"',
        );
        // And after it is settled, trying again changes nothing.
        expect(await s.conflictResolver.useOther(settled), isFalse);
        s.conflictResolver.keepCurrent(settled);
        expect(s.workspace.conflicts['cf-1']!.choice, 'used_other');
      },
    );

    test('use / undo repeated many times always returns to the right state '
        'and never loses a version', () async {
      final s = await booted('a');
      final note = s.workspace.createNote(title: 'N', body: 'current');
      s.workspace.conflicts.put(conflictFor(s, note.id));
      final r = s.conflictResolver;
      for (var i = 0; i < 6; i++) {
        final open = s.workspace.conflicts['cf-1']!;
        expect(open.isResolved, isFalse, reason: 'round $i start');
        expect(await r.useOther(open), isTrue);
        expect(s.workspace.notes[note.id]!.body, 'other text');
        final settled = s.workspace.conflicts['cf-1']!;
        expect(settled.otherData?['body'], 'other text');
        expect(settled.replacedData?['body'], 'current');
        expect(await r.reopen(settled), isTrue);
        expect(s.workspace.notes[note.id]!.body, 'current');
        final again = s.workspace.conflicts['cf-1']!;
        expect(again.isResolved, isFalse);
        expect(
          again.otherData?['body'],
          'other text',
          reason: 'the preserved version survives every round',
        );
      }
      expect(s.workspace.conflicts.length, 1);
    });

    test('a deletion conflict: using the other version deletes, undo restores '
        'the record', () async {
      final s = await booted('a');
      final note = s.workspace.createNote(title: 'Doomed', body: 'text');
      s.workspace.conflicts.put(
        SyncConflict({
          'id': 'cf-del',
          'collection': 'notes',
          'recordId': note.id,
          'reason': 'deleted_here_edited_elsewhere',
          'otherDeleted': true,
          'at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      final r = s.conflictResolver;
      expect(await r.useOther(s.workspace.conflicts['cf-del']!), isTrue);
      expect(s.workspace.notes[note.id], isNull);
      final settled = s.workspace.conflicts['cf-del']!;
      expect(settled.replacedData?['body'], 'text');
      expect(await r.reopen(settled), isTrue);
      expect(s.workspace.notes[note.id]?.body, 'text');
    });
  });

  group('duplicate and stale conflicts', () {
    test(
      'two conflicts on one record are separate; settling one leaves the '
      'other open; the older one warns that the record changed since',
      () async {
        final s = await booted('a');
        final note = s.workspace.createNote(title: 'N', body: 'v1');
        final rev = s.workspace.notes.revOf(note.id)!;
        s.workspace.conflicts
          ..put(
            conflictFor(
              s,
              note.id,
              id: 'old',
              body: 'old other',
              keptRev: '0001000000000000-0000-zzzz',
            ),
          )
          ..put(
            conflictFor(s, note.id, id: 'new', body: 'new other', keptRev: rev),
          );
        final r = s.conflictResolver;
        expect(
          (await r.sides(s.workspace.conflicts['new']!)).editedSince,
          isFalse,
        );
        expect(
          (await r.sides(s.workspace.conflicts['old']!)).editedSince,
          isTrue,
        );
        expect(await r.useOther(s.workspace.conflicts['new']!), isTrue);
        expect(s.openConflictCount, 1);
        expect(s.workspace.conflicts['old']!.isResolved, isFalse);
        // The record now differs from what 'old' was about: still detected.
        expect(
          (await r.sides(s.workspace.conflicts['old']!)).editedSince,
          isTrue,
        );
        // Using the stale one replaces newer work, but keeps it.
        expect(await r.useOther(s.workspace.conflicts['old']!), isTrue);
        expect(
          s.workspace.conflicts['old']!.replacedData?['body'],
          'new other',
        );
      },
    );
  });

  group('an app killed half way through', () {
    test('after the intent was saved: on restart the settling is finished '
        'and both versions are intact', () async {
      final s = await booted('a');
      final note = s.workspace.createNote(title: 'N', body: 'current');
      s.workspace.conflicts.put(conflictFor(s, note.id));
      s.conflictResolver.debugInterruptAfterIntent = true;
      await expectLater(
        s.conflictResolver.useOther(s.workspace.conflicts['cf-1']!),
        throwsA(isA<StateError>()),
      );
      // The note was not touched yet; the intent and both versions are saved.
      expect(s.workspace.notes[note.id]!.body, 'current');
      final mid = s.workspace.conflicts['cf-1']!;
      expect(mid.isApplying, isTrue);
      expect(mid.replacedData?['body'], 'current');
      expect(mid.otherData?['body'], 'other text');
      await s.flush();
      s.dispose();
      apps.remove(s);

      final again = await booted('a'); // the restart
      expect(
        again.workspace.notes[note.id]!.body,
        'other text',
        reason: 'the unfinished settling was completed on start-up',
      );
      final done = again.workspace.conflicts['cf-1']!;
      expect(done.isApplying, isFalse);
      expect(done.choice, 'used_other');
      expect(done.replacedData?['body'], 'current');
      expect(done.otherData?['body'], 'other text');
      expect(again.openConflictCount, 0);
      // Finishing again changes nothing.
      expect(await again.conflictResolver.recoverInterrupted(), 0);
    });

    test('an interrupted undo is finished on restart', () async {
      final s = await booted('a');
      final note = s.workspace.createNote(title: 'N', body: 'current');
      s.workspace.conflicts.put(conflictFor(s, note.id));
      expect(
        await s.conflictResolver.useOther(s.workspace.conflicts['cf-1']!),
        isTrue,
      );
      s.conflictResolver.debugInterruptAfterIntent = true;
      await expectLater(
        s.conflictResolver.reopen(s.workspace.conflicts['cf-1']!),
        throwsA(isA<StateError>()),
      );
      expect(s.workspace.conflicts['cf-1']!.isUndoing, isTrue);
      await s.flush();
      s.dispose();
      apps.remove(s);
      final again = await booted('a');
      expect(again.workspace.notes[note.id]!.body, 'current');
      final c = again.workspace.conflicts['cf-1']!;
      expect(c.isResolved, isFalse);
      expect(c.otherData?['body'], 'other text');
    });

    test('a settling that cannot be finished re-opens the conflict (nothing '
        'is lost, the user sees it again)', () async {
      final s = await booted('a');
      // A settled-in-progress conflict whose record kind cannot be restored.
      s.workspace.conflicts.put(
        SyncConflict({
          'id': 'cf-x',
          'collection': 'canvas_items',
          'recordId': 'missing-canvas/item',
          'reason': 'concurrent_edit',
          'otherData': {'type': 'text', 'id': 'item', 'text': 'hello'},
          'resolved': {
            'choice': 'used_other',
            'at': DateTime.now().toUtc().toIso8601String(),
            'replacedDeleted': true,
            'applying': true,
          },
        }),
      );
      expect(await s.conflictResolver.recoverInterrupted(), 1);
      final c = s.workspace.conflicts['cf-x']!;
      expect(c.isResolved, isFalse);
      expect(c.otherData?['text'], 'hello');
    });

    test('a mindmap item settling interrupted and recovered', () async {
      final s = await booted('a');
      await s.createCanvas(title: 'Board', show: false);
      final canvas = s.canvasList.first.id;
      TextItem item(String t) => TextItem(
        id: 'i1',
        position: const Offset(1, 1),
        width: 100,
        minHeight: 20,
        text: t,
      );
      expect(
        await s.restoreCanvasItem(canvas, 'i1', item('current').toJson()),
        isTrue,
      );
      s.workspace.conflicts.put(
        SyncConflict({
          'id': 'cf-item',
          'collection': 'canvas_items',
          'recordId': '$canvas/i1',
          'reason': 'concurrent_edit',
          'otherData': item('other').toJson(),
          'at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      s.conflictResolver.debugInterruptAfterIntent = true;
      await expectLater(
        s.conflictResolver.useOther(s.workspace.conflicts['cf-item']!),
        throwsA(isA<StateError>()),
      );
      expect((await s.canvasItemJson(canvas, 'i1'))!['text'], 'current');
      await s.conflictResolver.recoverInterrupted();
      expect((await s.canvasItemJson(canvas, 'i1'))!['text'], 'other');
      final c = s.workspace.conflicts['cf-item']!;
      expect(c.replacedData?['text'], 'current');
      expect(c.otherData?['text'], 'other');
    });
  });

  group('retention', () {
    SyncConflict make(String id) => SyncConflict({
      'id': id,
      'collection': 'notes',
      'recordId': 'n',
      'otherData': {'title': id},
      'at': DateTime.now().toUtc().toIso8601String(),
    });

    test('open conflicts are never pruned, whatever their age; settled ones '
        'go after 90 days, not before', () async {
      final s = await booted('a');
      final now = DateTime.now();
      s.workspace.conflicts
        ..put(
          SyncConflict({
            ...make('ancient-open').data,
            'at': '2020-01-01T00:00:00Z',
          }),
        )
        ..put(
          make(
            'd89',
          ).settled('kept_current', at: now.subtract(const Duration(days: 89))),
        )
        ..put(
          make(
            'd91',
          ).settled('kept_current', at: now.subtract(const Duration(days: 91))),
        )
        ..put(
          make('stuck').settled(
            'used_other',
            at: now.subtract(const Duration(days: 400)),
            applying: true,
          ),
        );
      expect(s.conflictResolver.pruneSettled(), 1);
      expect(s.workspace.conflicts.all.map((c) => c.id).toSet(), {
        'ancient-open',
        'd89',
        'stuck',
      });
    });
  });

  group('several devices', () {
    test('a conflict settled on one device is settled on the other, and the '
        'other cannot settle it again; both versions stay on both', () async {
      final rig = await SyncRig.start();
      addTearDown(rig.close);
      final pc = await rig.device('pc');
      final ipad = await rig.device('ipad', ipad: true);
      final note = pc.s.workspace.createNote(title: 'Shared', body: 'start');
      await until(
        () => ipad.s.workspace.notes[note.id] != null,
        what: 'note on the iPad',
      );
      pc.s.syncPaused();
      ipad.s.syncPaused();
      pc.s.workspace.notes.put(
        pc.s.workspace.notes[note.id]!.copyWith(body: 'PC'),
      );
      ipad.s.workspace.notes.put(
        ipad.s.workspace.notes[note.id]!.copyWith(body: 'iPad'),
      );
      for (var i = 0; i < 6; i++) {
        await pc.s.syncNow();
        await ipad.s.syncNow();
      }
      await until(
        () => pc.s.openConflictCount == 1 && ipad.s.openConflictCount == 1,
        what: 'the conflict on both',
      );
      final onPc = pc.s.conflictResolver.open().single;
      expect(await pc.s.conflictResolver.useOther(onPc), isTrue);
      for (var i = 0; i < 6; i++) {
        await pc.s.syncNow();
        await ipad.s.syncNow();
      }
      await until(
        () => ipad.s.openConflictCount == 0,
        what: 'settled on the iPad',
      );
      final onIpad = ipad.s.workspace.conflicts[onPc.id]!;
      expect(onIpad.isResolved, isTrue);
      expect(await ipad.s.conflictResolver.useOther(onIpad), isFalse);
      expect(onIpad.otherData, isNotNull);
      expect(onIpad.replacedData, isNotNull);
      expect(
        {onIpad.otherData?['body'], onIpad.replacedData?['body']},
        {'PC', 'iPad'},
        reason: 'both versions are still inside the settled conflict',
      );
      // Both devices agree on the note.
      expect(
        ipad.s.workspace.notes[note.id]!.body,
        pc.s.workspace.notes[note.id]!.body,
      );
    });
  });
}
