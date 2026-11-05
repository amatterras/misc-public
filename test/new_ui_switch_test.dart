import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/shell.dart';
import 'package:flutter_application_1/app/top_bar.dart';
import 'package:flutter_application_1/features/motivation/motivation_service.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/new_ui/new_sidebar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String quotes;
  late String greetings;
  setUpAll(() async {
    quotes = await rootBundle.loadString('assets/motivation/quotes.json');
    greetings = await rootBundle.loadString('assets/motivation/greetings.json');
  });
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_newui_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  AppState makeState() {
    final ws = Workspace(dir);
    return AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  }

  testWidgets('the sidebar navigates, expands and hides', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = makeState();
    await tester.runAsync(state.init);
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('new-nav-notes')));
    await settle(tester);
    expect(state.page, AppPage.notes);
    await tester.tap(find.byKey(const ValueKey('new-nav-calendar')));
    await settle(tester);
    expect(state.page, AppPage.calendar);

    // The selected marker stays inside the capsule (not over its border).
    final capsule = tester.getRect(
      find.descendant(
        of: find.byType(NewSidebar),
        matching: find.byType(BackdropFilter),
      ),
    );
    final item = tester.getRect(find.byKey(const ValueKey('new-nav-canvas')));
    expect(item.right, lessThanOrEqualTo(capsule.right - 1));
    expect(item.left, greaterThanOrEqualTo(capsule.left + 1));

    // On the right edge.
    expect(
      tester.getCenter(find.byKey(const ValueKey('new-nav-notes'))).dx,
      greaterThan(1280 - 100),
    );
    // Compact → expanded (names beside the icons) → compact.
    expect(state.newSidebarExpanded, isFalse);
    await tester.tap(find.byKey(const ValueKey('new-nav-expand')));
    await settle(tester);
    expect(state.newSidebarExpanded, isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('new-nav-notes')),
        matching: find.text('notes'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('new-nav-expand')));
    await settle(tester);
    expect(state.newSidebarExpanded, isFalse);

    // Hide completely, then bring it back with the handle.
    await tester.tap(find.byKey(const ValueKey('new-nav-hide')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // fade-out
    await tester.pump(const Duration(milliseconds: 50));
    expect(state.newSidebarHidden, isTrue);
    expect(find.byType(NewSidebar), findsNothing);
    await tester.tap(find.byKey(const ValueKey('new-sidebar-show')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 50));
    expect(state.newSidebarHidden, isFalse);
    expect(find.byType(NewSidebar), findsOneWidget);
    await close(tester, state);
  });

  for (final (name, size, theme) in [
    ('1280x720 dark', const Size(1280, 720), 'dark'),
    ('1000x700 light', const Size(1000, 700), 'light'),
    ('800x600 dark', const Size(800, 600), 'dark'),
    ('820x1180 light', const Size(820, 1180), 'light'),
    ('844x390 dark', const Size(844, 390), 'dark'),
  ]) {
    testWidgets('the layout has no overflow at $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = makeState();
      await tester.runAsync(state.init);
      await tester.runAsync(() => state.setThemeMode(theme));
      await tester.pumpWidget(TheApp(state: state));
      await settle(tester);
      for (final key in ['notes', 'calendar', 'links', 'browser', 'ai']) {
        final page = AppPage.values.firstWhere((p) => p.name == key);
        state.goTo(page);
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'page $key');
      }
      expect(find.byType(NewSidebar), findsOneWidget);
      await close(tester, state);
    });
  }

  for (final (label, width) in [('wide', 1280.0), ('narrow', 390.0)]) {
    testWidgets('the greeting sits below the page bar ($label)', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = makeState();
      await tester.runAsync(state.init);
      final motivation = MotivationService(nextIndex: (_) => 0)
        ..loadFromSources(quotes, greetings);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(state: state, motivation: motivation),
        ),
      );
      await tester.pump();
      await settle(tester);
      final greeting = find.byKey(const ValueKey('greeting-window'));
      expect(greeting, findsOneWidget);
      // Never over the page bar (34 px) at the top-left.
      expect(
        tester.getTopLeft(greeting).dy,
        greaterThanOrEqualTo(TopBar.height),
      );
      motivation.dispose();
      await close(tester, state);
    });
  }
}
