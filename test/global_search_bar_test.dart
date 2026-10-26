// The global search bar stays on every view (also an open note), keeps its
// query while results are opened, fits narrow screens and never covers the
// page below it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_application_1/features/search/global_search_bar.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_gsearch_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<AppState> boot(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
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
    addTearDown(() async {
      await tester.runAsync(state.flush);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 9));
      state.dispose();
    });
    return state;
  }

  final bar = find.byKey(const ValueKey('global-search-bar'));

  testWidgets('the bar is on the shell and on top of an open note', (
    tester,
  ) async {
    final state = await boot(tester, const Size(1440, 900));
    final note = state.workspace.createNote(title: 'Quokka diary');
    await settle(tester);
    expect(bar, findsOneWidget);
    expect(tester.getTopLeft(bar).dy, lessThan(globalSearchBarHeight));

    // Open the note as its own page (a route over the shell).
    final navContext = tester.element(find.byType(Navigator).first);
    openNotePage(navContext, state, note.id);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(NotePage), findsOneWidget);
    expect(bar, findsOneWidget, reason: 'search stays with the note open');

    // The note page starts below the bar: nothing is covered.
    final noteTop = tester.getTopLeft(find.byType(NotePage)).dy;
    expect(noteTop, greaterThanOrEqualTo(globalSearchBarHeight - 0.5));
    expect(
      tester.getRect(bar).bottom,
      lessThanOrEqualTo(globalSearchBarHeight + 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('query stays; a result closes the note page and shows it; '
      'the clear button forgets it', (tester) async {
    final state = await boot(tester, const Size(1440, 900));
    final other = state.workspace.createNote(title: 'Quokka diary');
    final open = state.workspace.createNote(title: 'Something else');
    await settle(tester);
    openNotePage(tester.element(find.byType(Navigator).first), state, open.id);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(NotePage), findsOneWidget);

    await tester.tap(bar);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('global-search-field'));
    expect(field, findsOneWidget);
    await tester.enterText(field, 'quokka');
    await tester.pumpAndSettle();
    expect(state.searchQuery.value, 'quokka');
    await tester.tap(
      find.descendant(of: find.byType(ListTile), matching: find.text('Quokka diary')),
    );
    await tester.pumpAndSettle();

    // The page that was open is gone; the chosen note is the one shown.
    expect(
      find.byWidgetPredicate((w) => w is NotePage && w.noteId == open.id),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate((w) => w is NotePage && w.noteId == other.id),
      findsOneWidget,
    );
    expect(state.page, AppPage.notes);
    // The query is still there, in the bar and when search opens again.
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('global-search-bar-text'))).data,
      'quokka',
    );
    await tester.tap(bar);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field).controller!.text,
      'quokka',
    );
    // Escape closes the search and keeps the query.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    expect(state.searchQuery.value, 'quokka');

    await tester.tap(find.byKey(const ValueKey('global-search-clear')));
    await tester.pump();
    expect(state.searchQuery.value, '');
  });

  testWidgets('Ctrl+K opens search from an open note', (tester) async {
    final state = await boot(tester, const Size(1200, 800));
    final note = state.workspace.createNote(title: 'Plain');
    await settle(tester);
    openNotePage(tester.element(find.byType(Navigator).first), state, note.id);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('global-search-field')), findsOneWidget);
    expect(find.byType(NotePage), findsOneWidget, reason: 'note kept');
  });

  testWidgets('narrow screens get a compact control, not a missing one', (
    tester,
  ) async {
    final state = await boot(tester, const Size(390, 800));
    expect(bar, findsOneWidget);
    expect(tester.getSize(bar).width, lessThan(60));
    expect(tester.getSize(bar).width, greaterThanOrEqualTo(44), reason: 'tap target');
    expect(tester.getSize(bar).height, greaterThanOrEqualTo(44));
    state.searchQuery.value = 'long query that is shown in the bar';
    await tester.pump();
    expect(tester.getSize(bar).width, greaterThan(100));
    expect(tester.getRect(bar).right, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide windows get a roomy bar that grows with the window', (
    tester,
  ) async {
    await boot(tester, const Size(1000, 800));
    final w1 = tester.getSize(bar);
    expect(w1.height, greaterThanOrEqualTo(44));
    expect(w1.width, greaterThanOrEqualTo(380));
    tester.view.physicalSize = const Size(1800, 900);
    await tester.pump();
    expect(tester.getSize(bar).width, greaterThan(w1.width));
    expect(tester.getSize(bar).width, lessThanOrEqualTo(600));
  });

  testWidgets('the search field is roomy, fits a phone and a wide window', (
    tester,
  ) async {
    await boot(tester, const Size(390, 800));
    await tester.tap(bar);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('global-search-field'));
    expect(tester.getSize(field).height, greaterThanOrEqualTo(62));
    expect(tester.getRect(field).right, lessThanOrEqualTo(390));
    expect(tester.getRect(field).left, greaterThanOrEqualTo(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1500, 900);
    await tester.pump();
    await tester.tap(bar);
    await tester.pumpAndSettle();
    expect(tester.getSize(field).width, inInclusiveRange(500, 724));
    final clear = find.byKey(const ValueKey('search-field-clear'));
    expect(clear, findsNothing);
    await tester.enterText(field, 'abc');
    await tester.pump();
    expect(tester.getSize(clear).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(clear).height, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape screens: no strip on the shell, but one over '
      'an open note', (tester) async {
    final state = await boot(tester, const Size(844, 390));
    await settle(tester);
    expect(bar, findsNothing, reason: 'the sidebar has its own search here');
    final note = state.workspace.createNote(title: 'Landscape');
    openNotePage(tester.element(find.byType(Navigator).first), state, note.id);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(NotePage), findsOneWidget);
    expect(bar, findsOneWidget, reason: 'no sidebar over a note page');
    // Back on the shell the strip goes away again.
    Navigator.of(tester.element(find.byType(NotePage))).pop();
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(tester.takeException(), isNull);
  });}
