// Cross-Device Handoff: the place is recorded as ids and numbers only, it
// travels through the normal sync, another device resumes it only on
// request, conflicting / stale / incomplete states are handled predictably,
// and the receiving device keeps its own zoom and its unsaved work.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/handoff/handoff.dart';
import 'package:flutter_application_1/features/handoff/handoff_dialog.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class Dev {
  Dev(this.app, this.engine);
  final AppState app;
  final SyncEngine engine;
  Workspace get ws => app.workspace;
  Future<void> sync() async {
    await app.flush();
    await engine.syncOnce();
  }
}

ResumeState state(
  String id,
  DateTime at, {
  String page = 'notes',
  String? noteId,
  String? canvasId,
  Offset? center,
}) => ResumeState(
  deviceId: id,
  deviceName: id,
  at: at,
  page: page,
  noteId: noteId,
  canvasId: canvasId,
  center: center,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory root;
  late HubServer hub;
  late int port;

  Future<Dev> device(String name) async {
    final dir = Directory('${root.path}${Platform.pathSeparator}$name');
    final ws = Workspace(dir);
    final canvases = FileCanvasRepository(ws.store);
    final app = AppState(
      canvases: canvases,
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    app.capture.fetchPreviews = false;
    await app.init();
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      ws.device!.id,
      name,
    );
    final client = SyncClient(Uri.parse('http://127.0.0.1:$port'), token: token);
    return Dev(app, SyncEngine(workspace: ws, canvases: canvases, client: client));
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_handoff_');
    hub = await HubServer.start(
      dir: Directory('${root.path}${Platform.pathSeparator}hub'),
      port: 0,
      dailyBackups: false,
    );
    port = hub.port;
  });

  tearDown(() async {
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  final t0 = DateTime.utc(2026, 10, 26, 12);

  test('state round-trips; damaged state is ignored; no text is stored', () {
    final r = state('d1', t0, noteId: 'n1', center: const Offset(10.4, 20.6));
    final back = ResumeState.fromRecord(r.toRecord())!;
    expect(back.noteId, 'n1');
    expect(back.center, const Offset(10, 21));
    expect(back.at, t0);
    final rec = r.toRecord();
    expect(rec.revoked, isTrue, reason: 'a handoff record can never be a share');
    expect(rec.title, isEmpty);
    expect(ResumeState.fromJson('d', 'junk'), isNull);
    expect(ResumeState.fromJson('d', {'page': 'notes', 'at': 'x'}), isNull);
    expect(ResumeState.fromJson('d', {'page': '', 'at': t0.toIso8601String()}), isNull);
  });

  test('choosing: latest, conflict, stale, and this device newer', () {
    final now = t0.add(const Duration(minutes: 30));
    // One recent state: suggested.
    var c = chooseResume([state('a', t0)], local: null, now: now);
    expect(c.suggested?.deviceId, 'a');
    expect(c.needsChoice, isFalse);
    // Two within 5 minutes: the user chooses.
    c = chooseResume(
      [state('a', t0), state('b', t0.add(const Duration(minutes: 2)))],
      local: null,
      now: now,
    );
    expect(c.needsChoice, isTrue);
    expect(c.suggested, isNull);
    expect(c.candidates.first.deviceId, 'b');
    // Two far apart: the newer is suggested.
    c = chooseResume(
      [state('a', t0), state('b', t0.add(const Duration(minutes: 20)))],
      local: null,
      now: now,
    );
    expect(c.suggested?.deviceId, 'b');
    // Only an old state: listed, never suggested.
    c = chooseResume(
      [state('a', t0.subtract(const Duration(days: 3)))],
      local: null,
      now: t0,
    );
    expect(c.candidates, hasLength(1));
    expect(c.suggested, isNull);
    // This device was used after the other: no suggestion.
    c = chooseResume(
      [state('a', t0)],
      local: state('me', t0.add(const Duration(minutes: 20))),
      now: now,
    );
    expect(c.localIsNewer, isTrue);
    expect(c.suggested, isNull);
    // This device at almost the same time in a different place: ask.
    c = chooseResume(
      [state('a', t0, noteId: 'x')],
      local: state('me', t0.add(const Duration(minutes: 1)), noteId: 'y'),
      now: now,
    );
    expect(c.needsChoice, isTrue);
  });

  test('a position travels between two devices and is resumed on request', () async {
    final pc = await device('pc');
    final ipad = await device('ipad');
    final note = pc.ws.createNote(title: 'Plan', body: 'private text');
    pc.app.openNote(note.id);
    expect(pc.app.handoff.publishNow(), isTrue);
    expect(pc.app.handoff.publishNow(), isFalse, reason: 'unchanged: no write');

    // Not sent yet: the device can say so.
    final id = handoffRecordId(pc.ws.device!.id);
    expect(await pc.engine.isPending('shares', id), isTrue);
    await pc.sync();
    expect(await pc.engine.isPending('shares', id), isFalse);

    // The iPad has not synced: it sees nothing, resuming is impossible.
    expect(ipad.app.handoff.others(), isEmpty);
    await ipad.sync();
    final seen = ipad.app.handoff.others();
    expect(seen, hasLength(1));
    expect(seen.single.noteId, note.id);
    // Nothing opened by itself.
    expect(ipad.app.selectedNoteId, isNull);

    final outcome = await applyResume(ipad.app, seen.single);
    expect(outcome, ResumeOutcome.opened);
    expect(ipad.app.selectedNoteId, note.id);
    expect(ipad.app.page, AppPage.notes);
    expect(ipad.ws.notes[note.id]!.body, 'private text');
  });

  test('incomplete sync: a note that has not arrived is reported, not opened', () async {
    final pc = await device('pc');
    final ipad = await device('ipad');
    final note = pc.ws.createNote(title: 'New', body: 'x');
    final r = state('pc', DateTime.now().toUtc(), noteId: note.id);
    final before = ipad.app.page;
    expect(await applyResume(ipad.app, r), ResumeOutcome.notOnThisDevice);
    expect(ipad.app.page, before);
    expect(ipad.app.selectedNoteId, isNull);
  });

  test('offline: the position stays local and is sent later', () async {
    final pc = await device('pc');
    await hub.stop(); // hub unreachable
    pc.app.openNote(pc.ws.createNote(title: 'T', body: 'b').id);
    pc.app.handoff.publishNow();
    final id = handoffRecordId(pc.ws.device!.id);
    await expectLater(pc.engine.syncOnce(), throwsA(anything));
    expect(await pc.engine.isPending('shares', id), isTrue);
    expect(pc.app.handoff.own, isNotNull, reason: 'kept on this device');
    hub = await HubServer.start(
      dir: Directory('${root.path}${Platform.pathSeparator}hub'),
      port: port,
      dailyBackups: false,
    );
    await pc.engine.syncOnce();
    expect(await pc.engine.isPending('shares', id), isFalse);
  });

  test('the receiving device keeps its own zoom and its unsaved work', () async {
    final pc = await device('pc');
    await pc.app.createCanvas(title: 'Board');
    final c = pc.app.canvas!;
    c.viewportSize = const Size(800, 600);
    c.centerOn(const Offset(1000, 500), c.viewportSize);
    final captured = pc.app.handoff.capture()!;
    expect(captured.center!.dx, closeTo(1000, 1));
    expect(captured.center!.dy, closeTo(500, 1));

    // Another place and zoom on this device, then resume the captured spot.
    c.centerOn(const Offset(-300, -300), c.viewportSize);
    final scaleBefore = c.scale;
    // An unsaved edit elsewhere must survive the resume.
    final note = pc.ws.createNote(title: 'Draft', body: 'v1');
    pc.ws.notes.put(pc.ws.notes[note.id]!.copyWith(body: 'v2 unsaved'));
    final out = await applyResume(pc.app, captured);
    expect(out, ResumeOutcome.opened);
    expect(pc.app.canvas!.scale, scaleBefore, reason: 'zoom stays per device');
    final centre =
        (c.viewportSize.center(Offset.zero) - c.offset) / c.scale;
    expect(centre.dx, closeTo(1000, 1));
    expect(pc.ws.notes[note.id]!.body, 'v2 unsaved');
  });

  test('turning handoff off stops recording', () async {
    final pc = await device('pc');
    await pc.app.handoff.setEnabled(false);
    pc.app.openNote(pc.ws.createNote(title: 'T', body: 'b').id);
    expect(pc.app.handoff.publishNow(), isFalse);
    expect(pc.app.handoff.own, isNull);
  });

  test('handoff records stay out of the shared links list', () async {
    final pc = await device('pc');
    pc.app.handoff.publishNow();
    final listed = pc.ws.shares.all.where((l) => l.kind != handoffKind);
    expect(listed, isEmpty);
    expect(pc.ws.shares.all.where((l) => l.kind == handoffKind), hasLength(1));
  });

  testWidgets('the dialog lists devices and asks when states conflict', (t) async {
    late Dev pc;
    await t.runAsync(() async {
      pc = await device('pc');
    });
    final now = DateTime.now().toUtc();
    pc.ws.shares.put(state('d1', now.subtract(const Duration(minutes: 3)), page: 'calendar').toRecord());
    pc.ws.shares.put(state('d2', now.subtract(const Duration(minutes: 1)), page: 'tasks').toRecord());
    pc.ws.shares.put(state('d3', now.subtract(const Duration(days: 4)), page: 'links').toRecord());
    await t.binding.setSurfaceSize(const Size(900, 800));
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showContinueDialog(context, pc.app),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('continue-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('handoff-choose')), findsOneWidget);
    expect(find.byKey(const ValueKey('handoff-resume-d1')), findsOneWidget);
    expect(find.byKey(const ValueKey('handoff-resume-d2')), findsOneWidget);
    expect(find.textContaining('· old'), findsOneWidget);
    expect(find.textContaining('not connected to a hub'), findsOneWidget);
    await t.binding.setSurfaceSize(null);
    await t.pump(const Duration(seconds: 20));
  });
}
