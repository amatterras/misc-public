// Note version history (kept on this device).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

void main() {
  late Directory dir;
  late Workspace ws;
  late DateTime clock;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_versions_');
    ws = Workspace(dir);
    await ws.load();
    clock = DateTime(2026, 11, 2, 9);
    ws.now = () => clock;
  });
  tearDown(() {
    ws.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  void edit(String id, String body) =>
      ws.notes.put(ws.notes[id]!.copyWith(body: body));

  test('one version per editing session, a new one after 10 minutes', () {
    final n = ws.createNote(title: 'Essay', body: 'Draft 1');
    for (final text in ['Draft 1 a', 'Draft 1 ab', 'Draft 1 abc']) {
      edit(n.id, text); // typing
    }
    expect(ws.versionsOf(n.id).map((v) => v.body), ['Draft 1']);
    clock = clock.add(const Duration(minutes: 11));
    edit(n.id, 'Draft 2');
    expect(ws.versionsOf(n.id).map((v) => v.body), ['Draft 1 abc', 'Draft 1']);
  });

  test('restoring puts old text back and can itself be undone', () {
    final n = ws.createNote(title: 'Essay', body: 'Original');
    edit(n.id, 'Rewritten');
    final original = ws.versionsOf(n.id).single;
    ws.restoreNoteVersion(original.id);
    expect(ws.notes[n.id]!.body, 'Original');
    // "Rewritten" was kept, even within the same 10 minutes.
    final back = ws.versionsOf(n.id).firstWhere((v) => v.body == 'Rewritten');
    ws.restoreNoteVersion(back.id);
    expect(ws.notes[n.id]!.body, 'Rewritten');
  });

  test('a change from another device keeps the replaced text', () {
    final n = ws.createNote(title: 'Shared', body: 'Written here');
    final remote = n.copyWith(body: 'Written on the iPad').toJson();
    ws.notes.applyRemote(n.id, SyncClock(deviceId: 'ipad').now(), remote);
    expect(ws.notes[n.id]!.body, 'Written on the iPad');
    expect(ws.versionsOf(n.id).single.body, 'Written here');
  });

  test('a deleted note can be brought back from its history', () {
    final n = ws.createNote(title: 'Ideas', body: 'v1');
    edit(n.id, 'v2');
    ws.notes.remove(n.id);
    expect(ws.notes[n.id], isNull);
    final v = ws.versionsOf(n.id).single;
    ws.restoreNoteVersion(v.id);
    expect(ws.notes[n.id]!.body, 'v1');
    expect(ws.notes[n.id]!.title, 'Ideas');
  });

  test('at most 30 versions per note; empty new notes make none', () {
    final n = ws.createNote();
    edit(n.id, 'first words');
    expect(ws.versionsOf(n.id), isEmpty, reason: 'nothing to keep yet');
    for (var i = 0; i < 40; i++) {
      clock = clock.add(const Duration(minutes: 11));
      edit(n.id, 'text $i');
    }
    expect(ws.versionsOf(n.id), hasLength(Workspace.versionsPerNote));
    expect(ws.versionsOf(n.id).first.body, 'text 38', reason: 'newest kept');
  });

  test('kept across restarts; not synced to other devices', () async {
    final n = ws.createNote(title: 'T', body: 'old');
    edit(n.id, 'new');
    await ws.flush();
    final again = Workspace(dir);
    await again.load();
    expect(again.versionsOf(n.id).single.body, 'old');
    expect(again.syncCollections.keys, isNot(contains('note_versions')));
    again.dispose();
  });

  testWidgets('the History dialog restores a version', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await tester.runAsync(s.init);
    final n = ws.createNote(title: 'Plan', body: 'Before');
    edit(n.id, 'After');
    s.openNote(n.id);
    await tester.pumpWidget(TheApp(state: s));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // page slides in
    // Version history lives in the note's "More" menu.
    await tester.tap(find.byTooltip('More note actions'));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Version history'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Before'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ws.notes[n.id]!.body, 'Before');
    await waitForBothClocks(tester, s.flush, what: 'Saving');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    s.dispose();
  });
}
