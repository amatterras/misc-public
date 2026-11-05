// Sync conflicts: visible outside Settings, and settled only by an explicit
// choice that never discards either version.
//
// Guards (each was a defect found by reading the code):
//  1. Conflicts on mindmap/notebook items could only be dismissed, never
//     restored, from the review window.
//  2. "Dismiss" deleted the preserved version for good, with no way back.
//  3. "Use this version" replaced the current version and kept no copy of it.
//  4. Conflicts were visible only in Settings -> Sync.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/conflict_notice.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/sync_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/settings/conflict_review.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/conflict_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_keys.dart';

final sep = Platform.pathSeparator;

Future<void> until(
  bool Function() done, {
  required String what,
  Duration limit = const Duration(seconds: 20),
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > limit) fail('$what not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the local hub

  late Directory root;
  late HubServer hub;
  final apps = <AppState>[];

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_conflict_');
    hub = await HubServer.start(
      dir: Directory('${root.path}${sep}hub'),
      port: 0,
      dailyBackups: false,
    );
  });
  tearDown(() async {
    // Sync cycles of different engines share one queue (SyncEngine._turn):
    // let any cycle in flight finish before the hub goes away, so one test
    // never delays the next.
    for (final s in apps) {
      s.syncPaused();
    }
    for (final s in apps) {
      final watch = Stopwatch()..start();
      while (s.syncing && watch.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    for (final s in apps) {
      s.dispose();
    }
    apps.clear();
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppState bare(String name) {
    final ws = Workspace(Directory('${root.path}$sep$name'));
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

  Future<AppState> paired(String name) async {
    final s = bare(name);
    await shareSyncKey(s);
    await s.init();
    expect(
      await s.pairWithHub(
        'http://127.0.0.1:${hub.port}',
        hub.auth.createPairingCode(),
      ),
      isNull,
    );
    return s;
  }

  /// Both devices edit the same note while offline, then sync.
  Future<(AppState, AppState, String, String)> noteConflict() async {
    final a = await paired('a');
    final b = await paired('b');
    final note = a.workspace.createNote(title: 'Shared', body: 'start');
    await a.syncNow();
    await b.syncNow();
    await until(() => b.workspace.notes[note.id] != null, what: 'note on B');
    a.syncPaused();
    b.syncPaused();
    a.workspace.notes.put(a.workspace.notes[note.id]!.copyWith(body: 'from A'));
    b.workspace.notes.put(b.workspace.notes[note.id]!.copyWith(body: 'from B'));
    for (final s in [a, b, a, b, a]) {
      await s.syncNow();
    }
    await until(
      () => a.openConflictCount == 1 && b.openConflictCount == 1,
      what: 'the conflict on both devices',
    );
    expect(a.workspace.notes[note.id]!.body, b.workspace.notes[note.id]!.body);
    final winner = a.workspace.notes[note.id]!.body;
    final loser = winner == 'from A' ? 'from B' : 'from A';
    return (a, b, note.id, loser);
  }

  test('a concurrent edit is kept aside, counted, and announced; nothing is '
      'settled by itself', () async {
    final (a, b, id, loser) = await noteConflict();
    final c = a.conflictResolver.open().single;
    expect(c.otherData?['body'], loser, reason: 'the losing text is kept');
    expect(c.isResolved, isFalse);
    // More syncs never settle or remove it.
    for (final s in [a, b, a, b]) {
      await s.syncNow();
    }
    expect(a.openConflictCount, 1);
    expect(b.openConflictCount, 1);
    expect(a.workspace.notes[id], isNotNull);
  });

  test('a device is told once when new conflicts arrive', () async {
    final a = await paired('a');
    final b = await paired('b');
    final note = a.workspace.createNote(title: 'Shared', body: 'start');
    await a.syncNow();
    await b.syncNow();
    await until(() => b.workspace.notes[note.id] != null, what: 'note on B');
    a.syncPaused();
    b.syncPaused();
    // Every message B shows, not just the last one.
    final told = <String>[];
    b.toast.addListener(() {
      final m = b.toast.value;
      if (m != null) told.add(m);
    });
    a.workspace.notes.put(a.workspace.notes[note.id]!.copyWith(body: 'from A'));
    b.workspace.notes.put(b.workspace.notes[note.id]!.copyWith(body: 'from B'));
    // (A cycle already in flight can swallow one syncNow, so repeat.)
    for (var i = 0; i < 8 && b.openConflictCount == 0; i++) {
      await a.syncNow();
      await b.syncNow();
    }
    await until(() => b.openConflictCount == 1, what: 'the conflict on B');
    final about = told.where((m) => m.contains('conflict')).toList();
    expect(about, hasLength(1));
    expect(about.single, contains('both versions are kept'));
    await b.syncNow(); // nothing new: no second message
    await b.syncNow();
    expect(told.where((m) => m.contains('conflict')), hasLength(1));
  });

  test('keeping the current version settles it and keeps both versions; the '
      'settling reaches the other device', () async {
    final (a, b, id, loser) = await noteConflict();
    final before = a.workspace.notes[id]!.body;
    final c = a.conflictResolver.open().single;
    a.conflictResolver.keepCurrent(c);
    expect(a.openConflictCount, 0);
    final settled = a.conflictResolver.settled().single;
    expect(settled.choice, 'kept_current');
    expect(settled.otherData?['body'], loser, reason: 'still preserved');
    expect(a.workspace.notes[id]!.body, before);
    await a.syncNow();
    await b.syncNow();
    await until(() => b.openConflictCount == 0, what: 'settled on B');
    expect(b.conflictResolver.settled().single.otherData?['body'], loser);
  });

  test('using the other version puts it in place, keeps the replaced one, '
      'and can be taken back', () async {
    final (a, b, id, loser) = await noteConflict();
    final winner = a.workspace.notes[id]!.body;
    final c = a.conflictResolver.open().single;
    expect(await a.conflictResolver.useOther(c), isTrue);
    expect(a.workspace.notes[id]!.body, loser);
    final settled = a.conflictResolver.settled().single;
    expect(settled.choice, 'used_other');
    expect(settled.replacedData?['body'], winner, reason: 'nothing lost');
    expect(a.openConflictCount, 0);
    // It is a normal edit: it syncs to the other device.
    await a.syncNow();
    await b.syncNow();
    await until(() => b.workspace.notes[id]!.body == loser, what: 'on B');
    // Taken back: the replaced version returns and the conflict is open.
    expect(await a.conflictResolver.reopen(settled), isTrue);
    expect(a.workspace.notes[id]!.body, winner);
    expect(a.openConflictCount, 1);
    expect(a.conflictResolver.open().single.otherData?['body'], loser);
  });

  test(
    'a conflict on a mindmap item can be restored, and taken back',
    () async {
      final a = await paired('a');
      final b = await paired('b');
      await a.createCanvas(title: 'Board', show: false);
      final canvasId = a.canvasList.first.id;
      TextItem item(String text) => TextItem(
        id: 'item-1',
        position: const Offset(10, 10),
        width: 200,
        minHeight: 40,
        text: text,
      );
      expect(
        await a.restoreCanvasItem(canvasId, 'item-1', item('start').toJson()),
        isTrue,
      );
      await a.syncNow();
      await b.syncNow();
      await until(
        () => b.canvasList.any((c) => c.id == canvasId),
        what: 'canvas on B',
      );
      expect((await b.canvasItemJson(canvasId, 'item-1'))?['text'], 'start');
      a.syncPaused();
      b.syncPaused();
      await a.restoreCanvasItem(canvasId, 'item-1', item('from A').toJson());
      await b.restoreCanvasItem(canvasId, 'item-1', item('from B').toJson());
      for (final s in [a, b, a, b, a]) {
        await s.syncNow();
      }
      await until(() => a.openConflictCount >= 1, what: 'item conflict on A');
      final c = a.conflictResolver.open().firstWhere(
        (c) => c.collection == 'canvas_items',
      );
      expect(
        a.conflictResolver.canUseOther(c),
        isTrue,
        reason: 'defect 1: it used to be dismiss-only',
      );
      final winner = (await a.canvasItemJson(canvasId, 'item-1'))!['text'];
      final loser = c.otherData!['text'];
      expect({winner, loser}, {'from A', 'from B'});

      expect(await a.conflictResolver.useOther(c), isTrue);
      expect((await a.canvasItemJson(canvasId, 'item-1'))!['text'], loser);
      final settled = a.conflictResolver.settled().firstWhere(
        (x) => x.id == c.id,
      );
      expect(settled.replacedData?['text'], winner);
      await a.syncNow();
      await b.syncNow();
      expect((await b.canvasItemJson(canvasId, 'item-1'))!['text'], loser);

      expect(await a.conflictResolver.reopen(settled), isTrue);
      expect((await a.canvasItemJson(canvasId, 'item-1'))!['text'], winner);
      expect(a.conflictResolver.open().any((x) => x.id == c.id), isTrue);
    },
  );

  test('settled conflicts are pruned after 90 days; open ones never', () async {
    final s = bare('solo');
    await s.init();
    SyncConflict make(String id) => SyncConflict({
      'id': id,
      'collection': 'notes',
      'recordId': 'n',
      'reason': 'concurrent_edit',
      'otherData': {'title': 'x'},
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    final old = make('old').settled(
      'kept_current',
      at: DateTime.now().subtract(const Duration(days: 91)),
    );
    final recent = make('recent').settled('kept_current', at: DateTime.now());
    s.workspace.conflicts
      ..put(old)
      ..put(recent)
      ..put(make('open'));
    expect(s.conflictResolver.pruneSettled(), 1);
    final ids = s.workspace.conflicts.all.map((c) => c.id).toSet();
    expect(ids, {'recent', 'open'});
  });

  group('screens', () {
    Future<(AppState, String)> withConflict(WidgetTester tester) async {
      final s = bare('ui');
      await tester.runAsync(s.init);
      final note = s.workspace.createNote(title: 'Plan', body: 'current text');
      s.workspace.conflicts.put(
        SyncConflict({
          'id': 'cf-1',
          'collection': 'notes',
          'recordId': note.id,
          'reason': 'concurrent_edit',
          'keptRev': '0001792610475963-0000-aaaa',
          'keptDevice': 'aaaa',
          'otherRev': '0001792610475000-0000-bbbb',
          'otherDevice': 'bbbb',
          'otherData': note.copyWith(body: 'other text').toJson(),
          'at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      return (s, note.id);
    }

    testWidgets('the notice shows on every page while conflicts wait and '
        'opens the review', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (s, _) = await withConflict(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(children: [ConflictNotice(state: s)]),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('conflict-notice')), findsOneWidget);
      expect(find.text('1 sync conflict to review'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('conflict-notice')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('conflict-review')), findsOneWidget);
      // Opening decides nothing.
      expect(s.openConflictCount, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the review shows both versions and nothing happens until a '
        'choice; a choice keeps both; Undo takes it back', (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (s, noteId) = await withConflict(tester);
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
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('current text'), findsWidgets);
      expect(find.textContaining('other text'), findsWidgets);
      expect(find.text('Current version'), findsOneWidget);
      expect(find.text('Other version'), findsOneWidget);
      expect(s.workspace.notes[noteId]!.body, 'current text');
      expect(s.openConflictCount, 1);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('use-other-cf-1')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(s.workspace.notes[noteId]!.body, 'other text');
      expect(s.openConflictCount, 0);
      final settled = s.workspace.conflicts['cf-1']!;
      expect(settled.replacedData?['body'], 'current text');
      expect(settled.otherData?['body'], 'other text');

      // Undo is under "Settled".
      await tester.tap(find.byKey(const ValueKey('conflicts-settled')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('undo-cf-1')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('undo-cf-1')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(s.workspace.notes[noteId]!.body, 'current text');
      expect(s.openConflictCount, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a kind of conflict that cannot be restored here says so and '
        'still offers only safe choices', (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = bare('ui2');
      await tester.runAsync(s.init);
      s.workspace.conflicts.put(
        SyncConflict({
          'id': 'cf-meta',
          'collection': 'canvases',
          'recordId': 'c1',
          'reason': 'concurrent_edit',
          'otherData': {'title': 'Old title'},
          'at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
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
      await tester.pump(const Duration(milliseconds: 300));
      final useOther = tester.widget<FilledButton>(
        find.byKey(const ValueKey('use-other-cf-meta')),
      );
      expect(useOther.onPressed, isNull);
      // "Keep current" is still available and keeps the other version.
      await tester.tap(find.byKey(const ValueKey('keep-current-cf-meta')));
      await tester.pump();
      final c = s.workspace.conflicts['cf-meta']!;
      expect(c.isResolved, isTrue);
      expect(c.otherData?['title'], 'Old title');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });
  });

  test('the resolver is available on the app state', () {
    final s = bare('x');
    expect(s.conflictResolver, isA<ConflictResolver>());
  });
}
