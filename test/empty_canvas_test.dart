// The Mindmap's entry screen ("empty canvas"): shown on an empty mindmap,
// its buttons do what they say, and it goes away as soon as anything is on
// the canvas.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_page.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_empty_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
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
    await tester.pump();
    await tester.runAsync(() => state.createCanvas(show: true));
    state.goTo(AppPage.canvas);
    await settle(tester);
    return state;
  }

  Future<void> shutDown(WidgetTester tester, AppState state) async {
    await waitForBothClocks(tester, state.flush, what: 'Saving');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  }

  final screen = find.byKey(const ValueKey('empty-canvas'));

  testWidgets('an empty mindmap shows the entry screen', (tester) async {
    final s = await boot(tester);
    expect(s.canvas!.items, isEmpty);
    expect(screen, findsOneWidget);
    expect(find.text('mpty canvas'), findsOneWidget);
    expect(find.text('sketch · plan · think · create'), findsOneWidget);
    for (final label in ['Add note', 'Add image', 'Add text', 'Quick add']) {
      expect(find.text(label), findsOneWidget);
    }
    await shutDown(tester, s);
  });

  testWidgets('Add text starts a text box and the screen goes away', (
    tester,
  ) async {
    final s = await boot(tester);
    await tester.tap(find.byKey(const ValueKey('empty-canvas-text')));
    await settle(tester);
    final c = s.canvas!;
    expect(c.items.whereType<TextItem>(), hasLength(1));
    expect(c.editingId, c.items.single.id);
    expect(screen, findsNothing);
    c.endEditing();
    await settle(tester);
    await shutDown(tester, s);
  });

  testWidgets('Add note makes a new note and places its card', (tester) async {
    final s = await boot(tester);
    final notesBefore = s.workspace.notes.all.length;
    await tester.tap(find.byKey(const ValueKey('empty-canvas-note')));
    await settle(tester);
    expect(s.workspace.notes.all.length, notesBefore + 1);
    final card = s.canvas!.items.whereType<NoteCardItem>().single;
    expect(s.workspace.notes[card.noteId], isNotNull);
    expect(screen, findsNothing);
    await shutDown(tester, s);
  });

  testWidgets('anything added from elsewhere hides it too', (tester) async {
    final s = await boot(tester);
    expect(screen, findsOneWidget);
    s.canvas!.insertText('hello', Offset.zero);
    await settle(tester);
    expect(screen, findsNothing);
    // Regression: with the screen gone, the mindmap view must keep its
    // full size (a non-positioned empty child once collapsed it to 0×0).
    final view = tester.getSize(find.byType(CanvasView));
    expect(view.width, greaterThan(400));
    expect(view.height, greaterThan(300));
    await shutDown(tester, s);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}
