// iPad / iPhone without a mouse or keyboard: every option must be reachable
// by touch, finger targets must be big enough, and reminders are handed to
// iOS as notifications. Simulated touch and a SIMULATED native channel; this
// does not prove anything about a real iPad or the Swift code.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/settings/settings_dialog.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

/// Records canvas deletions instead of doing them (see the trash test).
class _RecordingState extends AppState {
  _RecordingState({
    required super.canvases,
    required super.settings,
    required super.workspace,
  }) : super(enableSendTo: false);

  final deleted = <String>[];

  @override
  Future<void> deleteCanvas(String id) async => deleted.add(id);
}

Future<AppState> bootIpad(
  WidgetTester tester,
  Directory dir, {
  bool recording = false,
}) async {
  // iPad Air, landscape (sidebar layout).
  tester.view.physicalSize = const Size(1180, 820);
  tester.view.devicePixelRatio = 1;
  final ws = Workspace(dir);
  final canvases = FileCanvasRepository(ws.store);
  final settings = SettingsRepository(ws.store);
  final state = recording
      ? _RecordingState(canvases: canvases, settings: settings, workspace: ws)
      : AppState(
          canvases: canvases,
          settings: settings,
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
}

CanvasController controller(List<CanvasItem> items) => CanvasController(
  document: CanvasDocument(
    id: 'c1',
    title: 'Test',
    items: items,
    updatedAt: DateTime(2026),
  ),
  onSave: (_) async {},
  saveDelay: const Duration(milliseconds: 10),
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_ipad_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('canvas with a finger', () {
    final box = TextItem(
      id: 'a',
      position: Offset.zero,
      width: 200,
      minHeight: 100,
      text: 'Resize me',
    );

    test('the resize handle is a finger-sized target', () {
      // Handle at (200, 100); a finger lands 15 px away.
      const near = Offset(215, 112);
      final c = controller([box])..select(['a']);
      expect(c.resizeHandleAt(near), isNull, reason: 'mouse stays precise');
      expect(c.resizeHandleAt(near, kind: PointerDeviceKind.touch), isNotNull);

      c.pointerDown(near, kind: PointerDeviceKind.touch);
      c.pointerMove(const Offset(315, 162));
      c.pointerUp();
      expect(c.itemBounds(c.items.single).width, greaterThan(250));
    });

    test('a double tap may land a little apart, a double click may not', () {
      final link = LinkItem(
        id: 'l',
        position: Offset.zero,
        width: 300,
        minHeight: 80,
        assetId: 'x',
      );
      final opened = <String>[];
      CanvasController make() => CanvasController(
        document: CanvasDocument(
          id: 'c1',
          title: 'Test',
          items: [link],
          updatedAt: DateTime(2026),
        ),
        onSave: (_) async {},
        onActivate: (item) => opened.add(item.id),
      );
      void tapTwice(CanvasController c, PointerDeviceKind kind) {
        c.pointerDown(
          const Offset(100, 40),
          kind: kind,
          timeStamp: const Duration(seconds: 1),
        );
        c.pointerUp();
        c.pointerDown(
          const Offset(112, 48), // 14 px from the first tap
          kind: kind,
          timeStamp: const Duration(seconds: 1, milliseconds: 200),
        );
        c.pointerUp();
      }

      tapTwice(make(), PointerDeviceKind.mouse);
      expect(opened, isEmpty);
      tapTwice(make(), PointerDeviceKind.touch);
      expect(opened, ['l']);
    });
  });

  group('menus without right-click', () {
    testWidgets('press and hold a canvas in the sidebar opens its menu', (
      tester,
    ) async {
      final s = await bootIpad(tester, dir);
      s.goTo(AppPage.canvas);
      await settle(tester);
      final title = s.canvasList.first.title;
      // Two texts carry the title: the title chip and the sidebar entry
      // (the sidebar is on the right in this layout).
      final entries = find.text(title).evaluate().toList()
        ..sort(
          (a, b) => tester
              .getCenter(find.byWidget(a.widget))
              .dx
              .compareTo(tester.getCenter(find.byWidget(b.widget)).dx),
        );
      await tester.longPress(find.byWidget(entries.last.widget));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Move to trash'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5)); // close the menu
      await tester.pump(const Duration(milliseconds: 300));
      await shutDown(tester, s);
    });

    testWidgets('a canvas can be moved to trash from its title menu', (
      tester,
    ) async {
      final s = await bootIpad(tester, dir, recording: true);
      await tester.runAsync(() => s.createCanvas(show: true));
      s.goTo(AppPage.canvas);
      await settle(tester);
      final id = s.canvas!.id;

      await tester.tap(find.byTooltip('Canvas options'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // menu fully open
      await tester.tap(find.text('Move to trash'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('to trash?'), findsOneWidget);
      await tester.tap(find.text('Move to trash').last);
      await settle(tester);
      // File I/O started by a tap inside the widget test's fake clock does
      // not finish, so the deletion itself is checked below without the UI.
      expect((s as _RecordingState).deleted, [id]);
      await shutDown(tester, s);
    });

    test('moving the open canvas to trash keeps the others', () async {
      final ws = Workspace(dir);
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      await s.init();
      await s.createCanvas(show: true);
      final id = s.canvas!.id;
      final before = s.canvasList.length;
      await s.deleteCanvas(id);
      expect(s.canvasList.length, before - 1);
      expect(s.canvasList.any((c) => c.id == id), isFalse);
      expect(s.canvas, isNotNull, reason: 'another canvas is opened');
      await s.flush();
      s.dispose();
    });

    testWidgets('press and hold a project opens rename / colour / archive', (
      tester,
    ) async {
      final s = await bootIpad(tester, dir);
      s.workspace.projects.put(
        Project(
          id: 'p1',
          name: 'Thesis',
          kind: ProjectKind.project,
          updatedAt: DateTime.now(),
        ),
      );
      s.goTo(AppPage.tasks);
      await settle(tester);
      await tester.longPress(find.text('Thesis').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Change colour'), findsOneWidget);
      expect(find.text('Archive'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 300));
      await shutDown(tester, s);
    });
  });

  testWidgets('on iPhone/iPad hints speak of taps, not clicks or Ctrl keys', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final s = await bootIpad(tester, dir);
      await tester.runAsync(() => s.createCanvas(show: true)); // empty canvas
      s.goTo(AppPage.canvas);
      await settle(tester);
      expect(find.textContaining('Double-tap anywhere'), findsOneWidget);
      expect(find.textContaining('Double-click'), findsNothing);
      expect(find.text('Ctrl K'), findsNothing);

      s.goTo(AppPage.home);
      await settle(tester);
      expect(find.text('Quick Add'), findsWidgets);
      expect(find.textContaining('Ctrl+N'), findsNothing);

      final context = tester.element(find.byType(Scaffold).first);
      unawaited(showSettingsDialog(context, s));
      await settle(tester);
      expect(find.textContaining('stored only on this device'), findsOneWidget);
      expect(find.text('Send to THEapp'), findsNothing, reason: 'Windows only');
      Navigator.of(context).pop();
      await settle(tester);
      await shutDown(tester, s);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop wording is unchanged', (tester) async {
    final s = await bootIpad(tester, dir);
    s.goTo(AppPage.canvas);
    await settle(tester);
    expect(find.text('Ctrl K'), findsOneWidget);
    expect(find.text('Saved on this PC'), findsOneWidget);
    await shutDown(tester, s);
  });

  group('reminders as iOS notifications (simulated channel)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(IosBridge.channelName);
    late List<List<Map<Object?, Object?>>> sent;

    setUp(() {
      sent = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'scheduleReminders') {
          sent.add((call.arguments as List).cast<Map<Object?, Object?>>());
          return true;
        }
        return null;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Task task(String id, {required int day, bool done = false}) => Task(
      id: id,
      title: 'Task $id',
      createdAt: DateTime(2026, 11, 1),
      updatedAt: DateTime(2026, 11, 1),
      dueDate: DateTime(2026, 11, day),
      dueMinutes: 600,
      remindBefore: 0,
      done: done,
    );

    test(
      'upcoming reminders are scheduled, sent again only on change',
      () async {
        final ws = Workspace(dir);
        final s = AppState(
          canvases: FileCanvasRepository(ws.store),
          settings: SettingsRepository(ws.store),
          workspace: ws,
          enableSendTo: false,
          ios: IosBridge(),
        )..clock = () => DateTime(2026, 11, 2, 12);
        s.attention = () {};
        await s.init();
        ws.tasks
          ..put(task('past', day: 1)) // already due: in-app notice only
          ..put(task('later', day: 5))
          ..put(task('soon', day: 3))
          ..put(task('finished', day: 4, done: true));
        s.checkReminders();
        await Future<void>.delayed(Duration.zero);
        final last = sent.last;
        expect(last.map((r) => r['id']), ['soon', 'later']);
        expect(
          last.first['at'],
          DateTime(2026, 11, 3, 10).millisecondsSinceEpoch,
        );
        expect(last.first['title'], 'Task soon');

        final count = sent.length;
        s.checkReminders(); // nothing changed
        await Future<void>.delayed(Duration.zero);
        expect(sent.length, count);

        ws.tasks.put(task('soon', day: 3, done: true));
        s.checkReminders();
        await Future<void>.delayed(Duration.zero);
        expect(sent.last.map((r) => r['id']), ['later']);
        await s.flush();
        s.dispose();
      },
    );

    test('at most 60 are handed over (iOS keeps 64 per app)', () async {
      final ws = Workspace(dir);
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      )..clock = () => DateTime(2026, 1, 1);
      await s.init();
      for (var i = 0; i < 80; i++) {
        ws.tasks.put(
          Task(
            id: 't$i',
            title: 'T$i',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
            dueDate: DateTime(2026, 2, 1).add(Duration(days: i)),
            remindBefore: 0,
          ),
        );
      }
      final upcoming = s.upcomingReminders();
      expect(upcoming, hasLength(60));
      expect(upcoming.first.id, 't0');
      await s.flush();
      s.dispose();
    });

    test('no native side: scheduling fails softly', () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(
        await IosBridge().scheduleReminders([
          ScheduledReminder('x', 'X', DateTime(2030)),
        ]),
        isFalse,
      );
    });
  });

  test('channel contract: every Dart call has a Swift case and back', () {
    final dart = File('lib/platform/ios_bridge.dart').readAsStringSync();
    final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final dartCalls = {
      for (final m in RegExp(
        r"""(?:_invoke|invokeListMethod|invokeMethod)<[^(]*>\(\s*'(\w+)'""",
      ).allMatches(dart))
        m.group(1)!,
    };
    final swiftCases = {
      for (final m in RegExp(r'case "(\w+)"').allMatches(swift)) m.group(1)!,
    };
    expect(dartCalls, isNotEmpty);
    expect(swiftCases, dartCalls, reason: 'Dart and Swift must match');
    // Swift → Dart: links opened from outside, and Pencil squeezes.
    expect(swift, contains('invokeMethod("openedUrl"'));
    expect(dart, contains("case 'openedUrl'"));
    expect(swift, contains('invokeMethod("pencilSqueeze"'));
    expect(dart, contains("case 'pencilSqueeze'"));
  });
}
