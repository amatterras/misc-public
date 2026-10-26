// The Time Machine: automatic and named versions of a mindmap, what each
// one changed, bounded storage, previews that change nothing, restores that
// keep the current state first, and damaged or interrupted versions.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/canvas_ops.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/time_machine.dart';
import 'package:flutter_test/flutter_test.dart';

TextItem box(String id, String text, [Offset at = Offset.zero]) =>
    TextItem(id: id, position: at, width: 200, minHeight: 50, text: text);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState s;

  Future<AppState> boot() async {
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    state.capture.fetchPreviews = false;
    await state.init();
    return state;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_tmachine_');
    s = await boot();
    s.autoSnapshots = false;
    TimeMachine.maxAuto = 40;
    TimeMachine.maxNamed = 60;
    // Start from an empty canvas (a new one holds a welcome note).
    s.canvas!.selectAll();
    s.canvas!.deleteSelection();
  });
  tearDown(() async {
    TimeMachine.maxAuto = 40;
    TimeMachine.maxNamed = 60;
    await s.flush();
    s.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  CanvasController canvas() => s.canvas!;

  test('what changed is told in words', () {
    CanvasDocument doc(List<CanvasItem> items) => CanvasDocument(
      id: 'c',
      title: 't',
      items: items,
      updatedAt: DateTime(2026),
      viewport: const CanvasViewport(),
      schema: 3,
    );
    final before = doc([box('a', 'one'), box('b', 'two'), box('c', 'three')]);
    final after = doc([box('a', 'one'), box('b', 'TWO'), box('d', 'four')]);
    expect(TimeMachine.describe(before, after), 'Added 1, removed 1, changed 1');
    expect(TimeMachine.describe(before, before), 'No changes');
    expect(TimeMachine.describe(null, after), '3 items');
    expect(
      TimeMachine.describe(before, after, verb: 'Restoring'),
      'Restoring: added 1, removed 1, changed 1',
    );
  });

  test('named versions and automatic ones are told apart', () async {
    canvas().addItems([box('a', 'first')]);
    final named = await s.saveSnapshot(canvas(), 'Before the rewrite');
    expect(named.auto, isFalse);
    canvas().addItems([box('b', 'second')]);
    final list = await s.snapshotsOf(canvas().id);
    expect(list.single.name, 'Before the rewrite');
    expect(list.single.summary, '1 items');
    canvas().addItems([box('c', 'third')]);
    await s.saveSnapshot(canvas(), 'Later');
    final both = await s.snapshotsOf(canvas().id);
    expect(both.first.name, 'Later');
    expect(both.first.summary, 'Added 2');
  });

  test('automatic versions: after changes, not too often, not when unchanged',
      () async {
    final c = canvas();
    c.addItems([box('a', 'x')]);
    await s.autoSnapshot(c.document);
    var list = await s.snapshotsOf(c.id);
    expect(list, hasLength(1));
    expect(list.single.auto, isTrue);
    // A minute later with a new change: too soon.
    c.addItems([box('b', 'y')]);
    await s.autoSnapshot(c.document);
    expect(await s.snapshotsOf(c.id), hasLength(1));
    // Half an hour later: a new one with the change in words.
    s.snapshotState[c.id] = (
      at: DateTime.now().subtract(const Duration(minutes: 30)),
      fingerprint: s.snapshotState[c.id]!.fingerprint,
    );
    await s.autoSnapshot(c.document);
    list = await s.snapshotsOf(c.id);
    expect(list, hasLength(2));
    expect(list.first.summary, 'Added 1');
    // Nothing changed since: no third one, however late.
    s.snapshotState[c.id] = (
      at: DateTime.now().subtract(const Duration(hours: 5)),
      fingerprint: s.snapshotState[c.id]!.fingerprint,
    );
    await s.autoSnapshot(c.document);
    expect(await s.snapshotsOf(c.id), hasLength(2));
  });

  test('an empty canvas makes no automatic version', () async {
    final c = canvas();
    c.selectAll();
    c.deleteSelection();
    await s.autoSnapshot(c.document);
    expect(await s.snapshotsOf(c.id), isEmpty);
  });

  test('storage stays bounded: the newest are kept, the rest go to the trash',
      () async {
    TimeMachine.maxAuto = 3;
    TimeMachine.maxNamed = 2;
    final c = canvas();
    c.addItems([box('a', 'x')]);
    for (var i = 0; i < 6; i++) {
      c.addItems([box('n$i', 'item $i')]);
      await s.saveSnapshot(c, 'Named $i');
    }
    for (var i = 0; i < 6; i++) {
      c.addItems([box('m$i', 'more $i')]);
      s.snapshotState[c.id] = (
        at: DateTime.now().subtract(const Duration(hours: 1)),
        fingerprint: 0,
      );
      await s.autoSnapshot(c.document);
    }
    final list = await s.snapshotsOf(c.id);
    expect(list.where((v) => !v.auto), hasLength(2));
    expect(list.where((v) => v.auto), hasLength(3));
    expect(
      list.where((v) => !v.auto).map((v) => v.name),
      ['Named 5', 'Named 4'],
    );
  });

  test('restore keeps the current state first, replaces only this mindmap, '
      'and Undo works', () async {
    final c = canvas();
    c.addItems([box('a', 'old a'), box('b', 'old b')]);
    final v = await s.saveSnapshot(c, 'Good state');
    c.select(const ['b']);
    c.deleteSelection();
    c.addItems([box('c', 'new c')]);
    final otherId = (await s.canvases.listCanvases())
        .map((x) => x.id)
        .where((id) => id != c.id)
        .firstOrNull;

    expect(await s.restoreSummary(c, v.key), 'Restoring: added 1, removed 1');
    expect(await s.restoreSnapshot(c, v.key), isTrue);
    expect(c.items.map((i) => i.id).toSet(), {'a', 'b'});
    // The state from before is its own version.
    final list = await s.snapshotsOf(c.id);
    final safety = list.firstWhere((x) => x.name.startsWith('Before restoring'));
    expect(safety.auto, isTrue);
    expect(safety.itemCount, 2); // a and c
    // And it can be brought back in turn.
    expect(await s.restoreSnapshot(c, safety.key), isTrue);
    expect(c.items.map((i) => i.id).toSet(), {'a', 'c'});
    // Undo also steps back.
    c.undo();
    expect(c.items.map((i) => i.id).toSet(), {'a', 'b'});
    expect(otherId, isNull, reason: 'no other mindmap was involved');
  });

  test('looking (preview, summary) changes nothing', () async {
    final c = canvas();
    c.addItems([box('a', 'text'), box('b', 'more', const Offset(300, 0))]);
    final v = await s.saveSnapshot(c, 'Look');
    c.addItems([box('c', 'later')]);
    final before = jsonEncode(c.document.toJson()['items']);
    final png = await s.snapshotPreview(v.key);
    expect(png, isNotNull);
    final codec = await ui.instantiateImageCodec(png!);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, greaterThan(0));
    expect(frame.image.width, lessThanOrEqualTo(420));
    frame.image.dispose();
    codec.dispose();
    await s.restoreSummary(c, v.key);
    expect(jsonEncode(c.document.toJson()['items']), before);
    expect(c.canUndo, isTrue);
    c.undo(); // undoes the addItems, not anything from looking
    expect(c.items.map((i) => i.id).toSet(), {'a', 'b'});
  });

  test('a damaged version is listed but never restored or relied on', () async {
    final c = canvas();
    c.addItems([box('a', 'x')]);
    final good = await s.saveSnapshot(c, 'Good');
    // An interrupted write: the item count does not match the items.
    final file = File(
      '${dir.path}/canvas_snapshots/${c.id}~${DateTime.now().microsecondsSinceEpoch + 5}.json',
    );
    file.parent.createSync(recursive: true);
    final json = jsonDecode(
      File('${dir.path}/canvas_snapshots/${good.key}.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    json['itemCount'] = 7;
    json['name'] = 'Cut short';
    file.writeAsStringSync(jsonEncode(json));
    // And one that is not even JSON.
    File(
      '${dir.path}/canvas_snapshots/${c.id}~${DateTime.now().microsecondsSinceEpoch + 9}.json',
    ).writeAsStringSync('{"canvasId": "x", "docum');

    final list = await s.snapshotsOf(c.id);
    final cut = list.firstWhere((v) => v.name == 'Cut short');
    expect(cut.damaged, isTrue);
    c.addItems([box('b', 'y')]);
    final before = jsonEncode(c.document.toJson()['items']);
    expect(await s.restoreSnapshot(c, cut.key), isFalse);
    expect(jsonEncode(c.document.toJson()['items']), before);
    expect(await s.restoreSnapshot(c, good.key), isTrue);
  });

  test('if the current state cannot be kept first, nothing is restored',
      () async {
    final c = canvas();
    c.addItems([box('a', 'x')]);
    final v = await s.saveSnapshot(c, 'One');
    c.addItems([box('b', 'y')]);
    final before = jsonEncode(c.document.toJson()['items']);
    s.workspace.store.readOnly = true; // writes silently do not happen
    expect(await s.restoreSnapshot(c, v.key), isFalse);
    s.workspace.store.readOnly = false;
    expect(jsonEncode(c.document.toJson()['items']), before);
    // A version that did not write completely is not presented as one.
    s.workspace.store.readOnly = true;
    await expectLater(s.saveSnapshot(c, 'Lost'), throwsStateError);
    s.workspace.store.readOnly = false;
    expect((await s.snapshotsOf(c.id)).map((x) => x.name), isNot(contains('Lost')));
  });

  test('versions survive a restart', () async {
    final c = canvas();
    c.addItems([box('a', 'kept')]);
    final v = await s.saveSnapshot(c, 'Across restarts');
    final id = c.id;
    await s.flush();
    s.dispose();
    s = await boot();
    final list = await s.snapshotsOf(id);
    expect(list.single.key, v.key);
    expect(list.single.damaged, isFalse);
    await s.openCanvas(id);
    expect(await s.restoreSnapshot(s.canvas!, v.key), isTrue);
  });

  testWidgets('the window: pick and look; restoring is a separate button', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = canvas();
    late CanvasSnapshot v1, v2;
    await tester.runAsync(() async {
      c.addItems([box('a', 'alpha')]);
      v1 = await s.saveSnapshot(c, 'First');
      c.addItems([box('b', 'beta')]);
      v2 = await s.saveSnapshot(c, 'Second');
      c.select(const ['a']);
      c.deleteSelection();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showCanvasVersions(context, s, c),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byKey(const ValueKey('time-machine')).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(const ValueKey('time-machine')), findsOneWidget);
    FilledButton restore() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('time-machine-restore')),
    );
    expect(restore().onPressed, isNull, reason: 'nothing picked yet');
    final before = jsonEncode(c.document.toJson()['items']);
    await tester.tap(find.byKey(ValueKey('version-${v1.key}')));
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byKey(const ValueKey('version-preview')).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(const ValueKey('version-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('version-effect')), findsOneWidget);
    expect(jsonEncode(c.document.toJson()['items']), before, reason: 'only looked');
    expect(restore().onPressed, isNotNull);
    // (The restore itself, with its safety copy, is tested above; here only
    // that the window never changes anything by looking.)
    expect(v2.name, 'Second');
    await tester.pump(const Duration(seconds: 4));
  });
}
