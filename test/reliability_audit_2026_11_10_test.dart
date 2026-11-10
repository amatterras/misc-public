// Regression tests for the reliability audit of 2026-11-10 (see
// docs/history/RELIABILITY_AUDIT_2026-11-10.md). Each failed before its fix.
// The iOS side is SIMULATED; nothing here proves iPad behaviour.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/json_file_store.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/capture_dialog.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

/// A Pencil drawing: points carry time and, every other stroke, pen angle.
CanvasDocument pencilDrawing(int samples, {int schema = 0}) {
  final strokes = <CanvasItem>[];
  var left = samples;
  var n = 0;
  while (left > 0) {
    final count = left < 400 ? left : 400;
    final angled = n.isEven;
    strokes.add(
      StrokeItem(
        id: 's${n++}',
        points: [
          for (var i = 0; i < count; i++)
            StrokePoint(
              i * 0.5,
              n * 3.0 + (i % 7),
              0.3 + (i % 5) / 10,
              i * 4,
              angled ? 1.1 + (i % 3) / 10 : null,
              angled ? 0.2 + (i % 4) / 10 : null,
            ),
        ],
        color: const Color(0xFF000000),
        strokeWidth: 3,
        pressureWidth: true,
      ),
    );
    left -= count;
  }
  return CanvasDocument(
    id: 'pencil',
    title: 'Pencil',
    items: strokes,
    updatedAt: DateTime.utc(2026, 11, 10),
    schema: schema == 0 ? CanvasDocument.schemaVersion : schema,
  );
}

Future<AppState> boot(WidgetTester tester, Directory dir) async {
  tester.view.physicalSize = const Size(1700, 1050);
  tester.view.devicePixelRatio = 1;
  final ws = Workspace(dir);
  final state = AppState(
    canvases: FileCanvasRepository(ws.store),
    settings: SettingsRepository(ws.store),
    workspace: ws,
    enableSendTo: false,
  );
  state.capture.fetchPreviews = false;
  await tester.runAsync(state.init);
  await tester.pumpWidget(TheApp(state: state));
  await tester.pump();
  return state;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> shutDown(WidgetTester tester, AppState state) async {
  await waitForBothClocks(tester, state.flush, what: 'Saving');
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 4));
  state.dispose();
  state.workspace.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  syncFailureTests();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_audit1110_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Pencil drawings in the background save', () {
    test('points with time and pen angle go as flat number lists', () {
      // Before the fix only 3-number points were packed: every Pencil
      // stroke was copied point by point on the UI thread instead.
      expect(
        FileCanvasRepository.packsCompletely(pencilDrawing(2000).toJson()),
        isTrue,
      );
    });

    test('packing gives back exactly the same text and number types', () {
      final json = pencilDrawing(2000).toJson();
      final plain = const JsonEncoder.withIndent(' ').convert(json);
      expect(
        FileCanvasRepository.encodeLikeBackgroundSave(
          pencilDrawing(2000).toJson(),
        ),
        plain,
      );
    });

    test('a big Pencil drawing saves and loads unchanged', () async {
      final repo = FileCanvasRepository(JsonFileStore(dir));
      final doc = pencilDrawing(FileCanvasRepository.bigDrawing + 500);
      await repo.save(doc);
      final text = File(
        '${dir.path}${Platform.pathSeparator}canvases'
        '${Platform.pathSeparator}pencil.json',
      ).readAsStringSync();
      expect(text, const JsonEncoder.withIndent(' ').convert(doc.toJson()));
      final back = (await repo.load('pencil'))!;
      final p = (back.items.first as StrokeItem).points[5];
      expect(p.time, 20);
      expect(p.altitude, isNotNull);
    });
  });

  test('start-up schema check reads each drawing once for both ends', () async {
    final store = JsonFileStore(dir);
    final repo = FileCanvasRepository(store);
    await repo.save(pencilDrawing(10, schema: CanvasDocument.schemaVersion));
    final old = pencilDrawing(10).toJson()
      ..['id'] = 'old'
      ..['schema'] = 1;
    await store.write('canvases', 'old', old);
    final (oldest, newest) = await repo.schemaRange();
    expect(oldest, await repo.oldestSchema());
    expect(newest, await repo.newestSchema());
    expect(oldest, 1);
    expect(newest, CanvasDocument.schemaVersion);
  });

  group('saving when the app leaves the screen (iPhone/iPad)', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(IosBridge.channelName);
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('background time is asked for, the edits are written, and the '
        'time is given back', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add('${call.method}:${call.arguments}');
        return call.method == 'beginBackgroundSave' ? 42 : null;
      });
      final ws = Workspace(dir);
      final state = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
        ios: IosBridge(),
      );
      ws.createNote(title: 'Written on the train', body: 'keep me');
      await state.flushOnLeave();
      expect(calls.first, startsWith('beginBackgroundSave'));
      expect(calls.last, 'endBackgroundSave:42');
      final reread = Workspace(dir);
      await reread.load();
      expect(
        reread.notes.all.map((n) => n.title),
        contains('Written on the train'),
      );
      state.dispose();
    });

    test('a save that fails still gives the time back', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'beginBackgroundSave' ? 7 : null;
      });
      final ws = Workspace(dir);
      final state = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
        ios: IosBridge(),
      );
      ws.store.readOnly = true; // nothing is written; no throw either
      await state.flushOnLeave();
      expect(calls, ['beginBackgroundSave', 'endBackgroundSave']);
      state.dispose();
    });
  });

  testWidgets('Quick Add into a note deleted meanwhile saves a new note '
      'instead of failing', (tester) async {
    addTearDown(tester.view.reset);
    final s = await boot(tester, dir);
    final target = s.workspace.createNote(title: 'Shopping', body: 'eggs');
    showCaptureDialog(
      tester.element(find.byType(Scaffold).first),
      s,
      destination: CaptureDestination.notes,
    );
    await settle(tester);
    await tester.enterText(
      find
          .descendant(
            of: find.byType(CaptureDialog),
            matching: find.byType(TextField),
          )
          .first,
      'milk and bread',
    );
    await tester.tap(find.text('Add to existing note'));
    await tester.pump();
    await tester.tap(find.text('Choose a note'));
    await settle(tester);
    await tester.tap(find.text('Shopping').last);
    await settle(tester);
    // Deleted elsewhere (another window, or sync) while the dialog is open.
    s.workspace.deleteNote(target.id);
    await tester.tap(
      find.descendant(
        of: find.byType(CaptureDialog),
        matching: find.textContaining('Save'),
      ),
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(CaptureDialog), findsNothing, reason: 'saved, closed');
    expect(
      s.workspace.notes.all.any(
        (n) => '${n.title}\n${n.body}'.contains('milk'),
      ),
      isTrue,
      reason: 'the text was kept as a new note',
    );
    await shutDown(tester, s);
  });
}

/// Sync while Tailscale is off or the hub is restarting (run from main()).
void syncFailureTests() {
  group('sync failures are classed as temporary', () {
    final defaultLookup = SyncClient.lookup;
    HttpOverrides? overrides;
    setUp(() {
      overrides = HttpOverrides.current;
      HttpOverrides.global = null; // real HTTP to the local test server
    });
    tearDown(() {
      SyncClient.lookup = defaultLookup;
      HttpOverrides.global = overrides;
    });

    test('a Tailscale name that does not resolve is "offline", retried', () async {
      // Before the fix the lookup error escaped as a raw SocketException,
      // which the scheduler reports as "Sync hit an unexpected error".
      SyncClient.lookup = (host) async =>
          throw const SocketException('Failed host lookup');
      final client = SyncClient(Uri.parse('http://hub.example.ts.net:47710'));
      final error = await client.status().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      client.close();
      expect(error, isA<SyncFailure>());
      expect((error as SyncFailure).code, 'offline');
      expect(error.retryable, isTrue);
    });

    test('a 502 error page instead of JSON is retried', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response
          ..statusCode = 502
          ..headers.contentType = ContentType.html
          ..write('<html>Bad gateway</html>')
          ..close();
      });
      final client = SyncClient(
        Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final error = await client.status().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      client.close();
      await server.close(force: true);
      expect(error, isA<SyncFailure>());
      expect((error as SyncFailure).code, 'bad_response');
      expect(error.retryable, isTrue);
    });
  });
}
