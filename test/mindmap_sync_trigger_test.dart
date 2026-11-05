// A saved mindmap edit must ask for a sync by itself. It used to wait for a
// timer (10 s on Windows, 60 s on an iPad), because the mindmap save path did
// not tell the scheduler (note pages and the Archive board did).
//
// These tests use the production AppState, SyncScheduler, SyncEngine and a
// real hub. "iPad" here is the iOS configuration of the app: an AppState with
// an iOS bridge and no 10-second maintenance job, so only the edit
// notification, the live connection and the 60-second safety timer exist.
import 'dart:async';
import 'dart:io';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_application_1/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/flaky_proxy.dart';
import 'support/sync_keys.dart';

final sep = Platform.pathSeparator;

Future<Duration> until(
  FutureOr<bool> Function() done, {
  required String what,
  Duration limit = const Duration(seconds: 12),
}) async {
  final watch = Stopwatch()..start();
  while (!await done()) {
    if (watch.elapsed > limit) fail('$what not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  return watch.elapsed;
}

TextItem textItem(String id, String text) => TextItem(
  id: id,
  position: const Offset(10, 10),
  width: 200,
  minHeight: 40,
  text: text,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late HubServer hub;
  FlakyProxy? proxy;
  final apps = <AppState>[];

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_mmsync_');
    hub = await HubServer.start(
      dir: Directory('${root.path}${sep}hub'),
      port: 0,
      dailyBackups: false,
    );
  });
  tearDown(() async {
    for (final s in apps) {
      s.syncPaused();
    }
    for (final s in apps) {
      final w = Stopwatch()..start();
      while (s.syncing && w.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    for (final s in apps) {
      s.dispose();
    }
    apps.clear();
    await proxy?.close();
    proxy = null;
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> device(String name, {bool ipad = false, int? port}) async {
    final ws = Workspace(Directory('${root.path}$sep$name'));
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
      ios: ipad ? IosBridge() : null,
    );
    s.capture.fetchPreviews = false;
    s.allowLoopbackHubForTests = true;
    await shareSyncKey(s);
    await s.init();
    expect(
      await s.pairWithHub(
        'http://127.0.0.1:${port ?? hub.port}',
        keyedPairingCode(hub.auth),
      ),
      isNull,
    );
    apps.add(s);
    await until(
      () => s.syncConnection == SyncConnection.live,
      what: '$name live',
    );
    return s;
  }

  /// Saves an item on the open mindmap the way an edit does (through the
  /// controller, then its save).
  Future<String> openMindmap(AppState s) async {
    await s.createCanvas(title: 'Board', show: true);
    await s.syncNow();
    return s.canvas!.id;
  }

  Future<void> edit(AppState s, String id, String text) async {
    s.canvas!.restoreItem(textItem(id, text));
    await s.canvas!.flush();
  }

  Future<bool> hubHas(String canvasId, String itemId) async =>
      await hub.store.current('canvas_items', '$canvasId/$itemId') != null;

  test('a saved edit reaches the hub within a second or two, not a timer '
      'period (iPad configuration)', () async {
    final ipad = await device('ipad', ipad: true);
    final canvas = await openMindmap(ipad);
    expect(ipad.runMaintenance, isFalse, reason: 'no 10-second job on iOS');
    final took = await (() async {
      await edit(ipad, 'p1', 'hello');
      return until(() => hubHas(canvas, 'p1'), what: 'item on the hub');
    })();
    // ignore: avoid_print
    print('mindmap edit -> hub: ${took.inMilliseconds} ms');
    expect(took, lessThan(const Duration(seconds: 3)));
    await until(() => !ipad.syncPendingLocal, what: 'no longer waiting');
  });

  test('the same on the Windows configuration', () async {
    final pc = await device('pc');
    final canvas = await openMindmap(pc);
    await edit(pc, 'p1', 'hello');
    final took = await until(() => hubHas(canvas, 'p1'), what: 'item on hub');
    expect(took, lessThan(const Duration(seconds: 3)));
  });

  test('the edit shows as "changes waiting" at once, and not after it was '
      'sent', () async {
    final ipad = await device('ipad', ipad: true);
    final canvas = await openMindmap(ipad);
    await until(() => !ipad.syncPendingLocal, what: 'idle');
    await edit(ipad, 'p1', 'x');
    expect(ipad.syncPendingLocal || await hubHas(canvas, 'p1'), isTrue);
    await until(() => hubHas(canvas, 'p1'), what: 'sent');
    await until(() => !ipad.syncPendingLocal, what: 'idle again');
  });

  test('rapid consecutive edits are batched: many saves, few sync cycles, '
      'everything arrives', () async {
    final ipad = await device('ipad', ipad: true);
    final canvas = await openMindmap(ipad);
    await until(() => !ipad.syncPendingLocal, what: 'idle');
    final before = ipad.syncCycles;
    for (var i = 0; i < 30; i++) {
      await edit(ipad, 'r$i', 'text $i');
    }
    await until(() async {
      for (var i = 0; i < 30; i++) {
        if (!await hubHas(canvas, 'r$i')) return false;
      }
      return true;
    }, what: 'all 30 items on the hub');
    await until(() => !ipad.syncPendingLocal, what: 'idle');
    final cycles = ipad.syncCycles - before;
    expect(cycles, lessThan(12), reason: '30 saves must not mean 30 cycles');
    expect(cycles, greaterThan(0));
  });

  test('an edit made while the hub is unreachable is kept, shown as waiting '
      'and never as synced, and goes out when the network is back', () async {
    proxy = await FlakyProxy.start(hub.port);
    final ipad = await device('ipad', ipad: true, port: proxy!.port);
    final canvas = await openMindmap(ipad);
    await until(() => !ipad.syncPendingLocal, what: 'idle');
    await proxy!.down();
    await edit(ipad, 'off1', 'written offline');
    await until(
      () => ipad.syncConnection == SyncConnection.offline,
      what: 'offline',
    );
    expect(ipad.syncPendingLocal, isTrue);
    expect(ipad.syncStatus, isNot(contains('live')));
    expect(ipad.syncStatus, isNot(startsWith('Synced')));
    expect(await hubHas(canvas, 'off1'), isFalse);
    // A second edit while offline, and the app restarts its connection.
    await edit(ipad, 'off2', 'also offline');
    await proxy!.up();
    await until(
      () async => await hubHas(canvas, 'off1') && await hubHas(canvas, 'off2'),
      what: 'both offline edits on the hub',
      limit: const Duration(seconds: 45),
    );
    await until(
      () => ipad.syncConnection == SyncConnection.live,
      what: 'live again',
    );
    await until(() => !ipad.syncPendingLocal, what: 'idle');
  });

  test('an edit made while the app is in the background goes out when it '
      'returns to the front', () async {
    final ipad = await device('ipad', ipad: true);
    final canvas = await openMindmap(ipad);
    await until(() => !ipad.syncPendingLocal, what: 'idle');
    ipad.syncPaused(); // the app goes to the background
    expect(ipad.syncConnection, SyncConnection.stopped);
    expect(ipad.syncStatus, isNot(contains('live')));
    await edit(ipad, 'bg1', 'edited just before leaving');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(
      await hubHas(canvas, 'bg1'),
      isFalse,
      reason: 'nothing runs in background',
    );
    expect(ipad.syncPendingLocal, isTrue, reason: 'still waiting');
    await ipad.appResumed();
    await until(() => hubHas(canvas, 'bg1'), what: 'item after resume');
  });

  test(
    'a second device receives a mindmap edit promptly (both directions)',
    () async {
      final a = await device('a', ipad: true);
      final b = await device('b');
      final canvas = await openMindmap(a);
      await edit(a, 'x1', 'from the iPad');
      await until(
        () => b.canvasList.any((c) => c.id == canvas),
        what: 'canvas on the PC',
      );
      // The PC edits the same canvas: it must reach the iPad.
      await until(
        () => b.canvasList.any((c) => c.id == canvas),
        what: 'canvas known',
      );
      final c = await b.acquireCanvas(canvas);
      c!.restoreItem(textItem('y1', 'from the PC'));
      await c.flush();
      await b.releaseCanvas(canvas);
      await until(() => hubHas(canvas, 'y1'), what: 'the PC edit on the hub');
    },
  );
}
