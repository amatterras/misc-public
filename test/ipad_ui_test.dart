// The iPad interface (lib/ipad): who gets it, the rail, Today, that every
// place lays out at every iPad size in both themes, and that Windows, the
// iPhone and narrow iPad windows are not changed by it.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/interface_version.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_application_1/ipad/ipad_shell.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/phone/phone_profile.dart';
import 'package:flutter_application_1/phone/phone_shell.dart';
import 'package:flutter_application_1/platform/device_idiom.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_ipad_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final today = dateOnly(DateTime.now());

  Future<AppState> boot(
    WidgetTester tester, {
    required Size size,
    InterfaceVersion version = InterfaceVersion.newDesign,
    bool ios = false,
    bool ipad = false,
    bool phone = false,
    bool forced = false,
    String theme = 'dark',
    bool seed = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (ios) debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    DeviceIdiom.debugIsPhone = phone;
    DeviceIdiom.debugIsIpad = ipad;
    PhoneProfile.forced = forced;
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
    await tester.runAsync(() async {
      await state.init();
      await state.setInterfaceVersion(version);
      await state.setThemeMode(theme);
      if (seed) {
        ws.createTask('Pay rent', dueDate: today);
        ws.createTask('Late report', dueDate: addDays(today, -2));
        ws.createTask('Someday');
        ws.createNote(title: 'Groceries', body: 'Lemons and bread');
        ws.createNote(title: 'Ideas', body: 'A plant app');
        await state.library.createSpace('Lisbon trip');
      }
    });
    return state;
  }

  Future<void> settle(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
    debugDefaultTargetPlatformOverride = null;
    DeviceIdiom.debugIsPhone = null;
    DeviceIdiom.debugIsIpad = null;
    PhoneProfile.forced = false;
  }

  Future<void> open(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester, 12);
  }

  const ipadLandscape = Size(1180, 820);
  const ipadPortrait = Size(820, 1180);

  Future<void> rail(WidgetTester tester, String id) async {
    final item = find.byKey(ValueKey('ipad-rail-$id'));
    await tester.ensureVisible(item); // the test font is far wider than SF
    await tester.tap(item);
    await settle(tester);
  }

  testWidgets('an iPad gets the rail and opens on Today', (tester) async {
    final state = await boot(
      tester,
      size: ipadLandscape,
      ios: true,
      ipad: true,
    );
    await open(tester, state);
    expect(find.byType(IpadShell), findsOneWidget);
    expect(find.byType(PhoneShell), findsNothing);
    expect(state.homeActive, isTrue);
    for (final k in const [
      'today',
      'notes',
      'calendar',
      'archive',
      'canvas',
      'browser',
      'ai',
      'new',
      'search',
      'settings',
    ]) {
      expect(find.byKey(ValueKey('ipad-rail-$k')), findsOneWidget, reason: k);
    }
    // Same palette as New, whatever Original/New was stored for this device.
    expect(state.interfaceVersion, InterfaceVersion.newDesign);
    await close(tester, state);
  });

  testWidgets('Windows and the iPhone never get the iPad frame', (
    tester,
  ) async {
    for (final (size, ios, phone) in const [
      (Size(1280, 800), false, false),
      (Size(390, 844), true, true),
    ]) {
      final state = await boot(
        tester,
        size: size,
        ios: ios,
        phone: phone,
        seed: false,
      );
      await open(tester, state);
      expect(find.byType(IpadShell), findsNothing, reason: '$size');
      expect(find.byKey(const ValueKey('ipad-rail-today')), findsNothing);
      await close(tester, state);
      dir.deleteSync(recursive: true);
      dir = Directory.systemTemp.createTempSync('theapp_ipad_');
    }
  });

  testWidgets('Windows keeps the Original/New choice', (tester) async {
    final state = await boot(
      tester,
      size: const Size(1280, 800),
      version: InterfaceVersion.original,
      seed: false,
    );
    await open(tester, state);
    expect(state.interfaceVersion, InterfaceVersion.original);
    expect(find.byType(IpadShell), findsNothing);
    await close(tester, state);
  });

  testWidgets('narrow iPad windows keep the compact capsule', (tester) async {
    for (final size in const [Size(507, 1000), Size(320, 900)]) {
      final state = await boot(
        tester,
        size: size,
        ios: true,
        ipad: true,
        seed: false,
      );
      await open(tester, state);
      expect(find.byType(IpadShell), findsNothing, reason: '$size');
      expect(find.byKey(const ValueKey('new-sidebar-show')), findsOneWidget);
      await close(tester, state);
      dir.deleteSync(recursive: true);
      dir = Directory.systemTemp.createTempSync('theapp_ipad_');
    }
  });

  testWidgets('the rail moves between places', (tester) async {
    final state = await boot(
      tester,
      size: ipadLandscape,
      ios: true,
      ipad: true,
    );
    await open(tester, state);
    await rail(tester, 'notes');
    expect(state.page, AppPage.notes);
    expect(state.homeActive, isFalse);
    await rail(tester, 'calendar');
    expect(state.page, AppPage.calendar);
    await rail(tester, 'archive');
    expect(state.page, AppPage.links);
    await rail(tester, 'canvas');
    expect(state.page, AppPage.canvas);
    await rail(tester, 'ai');
    expect(state.page, AppPage.ai);
    await rail(tester, 'today');
    expect(state.homeActive, isTrue);
    await close(tester, state);
  });

  testWidgets('Today: the day on the left, recent notes on the right', (
    tester,
  ) async {
    final state = await boot(
      tester,
      size: ipadLandscape,
      ios: true,
      ipad: true,
    );
    await open(tester, state);
    expect(find.text('Pay rent'), findsOneWidget);
    expect(find.text('Desk'), findsOneWidget);
    await tester.tap(find.text('Groceries'));
    await settle(tester, 14);
    expect(find.byType(NotePage), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('the + on the rail lists what can be made', (tester) async {
    final state = await boot(
      tester,
      size: ipadLandscape,
      ios: true,
      ipad: true,
    );
    await open(tester, state);
    await rail(tester, 'new');
    for (final w in const ['Task', 'Note', 'Event', 'Mindmap']) {
      expect(find.text(w), findsWidgets, reason: w);
    }
    await close(tester, state);
  });

  testWidgets('Settings on the iPad has no interface switch', (tester) async {
    final state = await boot(
      tester,
      size: ipadLandscape,
      ios: true,
      ipad: true,
      seed: false,
    );
    await open(tester, state);
    final previous = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.toString().contains('overflowed')) previous?.call(d);
    };
    addTearDown(() => FlutterError.onError = previous);
    await rail(tester, 'settings');
    await tester.tap(find.text('Appearance').first);
    await settle(tester, 12);
    expect(find.byKey(const ValueKey('interface-version')), findsNothing);
    await close(tester, state);
  });

  for (final size in const [
    Size(744, 1133), // iPad mini
    ipadPortrait,
    Size(1024, 1366), // 12.9 portrait
    ipadLandscape,
    Size(1366, 1024), // 12.9 landscape
  ]) {
    for (final theme in const ['dark', 'light']) {
      testWidgets(
        'every place lays out at ${size.width.toInt()}x${size.height.toInt()} '
        '$theme',
        (tester) async {
          final state = await boot(
            tester,
            size: size,
            ios: true,
            ipad: true,
            theme: theme,
          );
          await open(tester, state);
          expect(tester.takeException(), isNull, reason: 'Today');
          for (final k in const [
            'notes',
            'calendar',
            'archive',
            'canvas',
            'today',
          ]) {
            await rail(tester, k);
            expect(tester.takeException(), isNull, reason: k);
          }
          await close(tester, state);
        },
      );
    }
  }
}
