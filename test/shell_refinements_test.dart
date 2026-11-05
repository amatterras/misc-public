import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/floating_windows.dart';
import 'package:flutter_application_1/app/page_windows.dart';
import 'package:flutter_application_1/app/sidebar.dart' show appDestinations;
import 'package:flutter_application_1/new_ui/new_sidebar.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_shell_'));
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

  test('content windows use shared responsive viewport geometry', () {
    final desktop = ContentWindowGeometry.initial(const Size(1000, 800));
    expect(desktop.left, 600);
    expect(desktop.width, 400);
    expect(desktop.top, 60);
    expect(desktop.bottom, 740);

    final tablet = ContentWindowGeometry.initial(const Size(800, 600));
    expect(tablet.width, 320);
    expect(tablet.left, 480);
    expect(tablet.top, 45);
    expect(tablet.bottom, 555);

    final phone = ContentWindowGeometry.initial(const Size(390, 700));
    expect(phone.left, 12);
    expect(phone.right, 378);
    expect(phone.top, 52.5);
    expect(phone.bottom, 647.5);

    final spec = FloatingWindowSpec(
      id: 'content',
      title: 'Content',
      builder: (_) => const SizedBox(),
      initialRectFor: ContentWindowGeometry.initial,
    );
    final geometryDir = Directory.systemTemp.createTempSync('geometry_');
    final ws = Workspace(geometryDir);
    final windows = FloatingWindows(SettingsRepository(ws.store));
    expect(windows.rectOf(spec, viewport: const Size(500, 500)).width, 476);
    expect(windows.rectOf(spec, viewport: const Size(1000, 500)).width, 400);
    windows.dispose();
    geometryDir.deleteSync(recursive: true);
  });

  testWidgets('the sidebar has no lists, commands or app switcher', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    state.capture.fetchPreviews = false;
    await tester.runAsync(state.init);
    await tester.runAsync(() async {
      await state.createCanvas(title: 'First board', show: false);
    });
    final note = ws.createNote(title: 'First note');
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester);
    Finder inSidebar(String text) => find.descendant(
      of: find.byType(NewSidebar),
      matching: find.text(text),
    );

    // Compact (icons only): the six destinations and Quick Add are there.
    for (final (page, _, _) in appDestinations) {
      expect(
        find.byKey(ValueKey('new-nav-${page.name}')),
        findsOneWidget,
        reason: page.name,
      );
    }
    expect(find.byKey(const ValueKey('new-quick-add')), findsOneWidget);
    expect(inSidebar('mindmap'), findsNothing, reason: 'icons only');

    // Expanded: their names, and still no Commands, no App switcher, no
    // canvas / recent-note / favorite lists (and no way to open them).
    await tester.tap(find.byKey(const ValueKey('new-nav-expand')));
    await settle(tester);
    for (final label in const [
      'mindmap',
      'notes',
      'calendar',
      'archive',
      'safari',
      'ai',
      'Quick Add',
    ]) {
      expect(inSidebar(label), findsOneWidget, reason: label);
    }
    expect(inSidebar('Commands'), findsNothing);
    expect(find.byTooltip('App switcher'), findsNothing);
    expect(inSidebar('First board'), findsNothing);
    expect(inSidebar('First note'), findsNothing);
    expect(inSidebar('FAVORITES'), findsNothing);
    expect(
      find.byKey(const ValueKey('sidebar-group-mindmap-toggle')),
      findsNothing,
    );
    // Nothing was deleted: the data is still there, and the note is still
    // reachable from Notes.
    expect(state.workspace.notes[note.id], isNotNull);
    expect(state.canvasList.map((c) => c.title), contains('First board'));

    // Compact again: only icons, still no switcher.
    await tester.tap(find.byKey(const ValueKey('new-nav-expand')));
    await settle(tester);
    expect(find.byTooltip('App switcher'), findsNothing);
    expect(inSidebar('mindmap'), findsNothing);

    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  });

  testWidgets('page windows follow the resized page-content viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    state.capture.fetchPreviews = false;
    await tester.runAsync(state.init);
    final note = ws.createNote(title: 'Window source');
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester);
    final page = state.windows.open(
      AppPage.notes,
      refId: note.id,
      title: note.title,
      mode: PageMode.floating,
    );
    await settle(tester);

    void expectCanonicalGeometry() {
      final viewport = tester.getRect(
        find.byKey(const ValueKey('page-content-viewport')),
      );
      final window = tester.getRect(
        find.byKey(ValueKey('floating-${page.id}')),
      );
      expect(window.right, closeTo(viewport.right, 1));
      expect(window.width, closeTo(viewport.width * .4, 1));
      expect(window.top - viewport.top, closeTo(viewport.height * .075, 1));
      expect(
        window.bottom,
        closeTo(viewport.bottom - viewport.height * .075, 1),
      );
    }

    expectCanonicalGeometry();
    tester.view.physicalSize = const Size(1440, 1000);
    await settle(tester);
    expectCanonicalGeometry();
    expect(tester.takeException(), isNull);

    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  });

  testWidgets('global search shortcut opens a larger responsive field', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    await settle(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('global-search-field'));
    expect(field, findsOneWidget);
    final phoneFieldSize = tester.getSize(field);
    expect(phoneFieldSize.height, greaterThanOrEqualTo(56));
    expect(phoneFieldSize.width, greaterThan(250));
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1440, 1000);
    await tester.pumpAndSettle();
    expect(tester.getSize(field).width, greaterThan(phoneFieldSize.width));
    expect(tester.getSize(field).width, lessThanOrEqualTo(588));

    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  });
}
