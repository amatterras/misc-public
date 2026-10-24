// Notes text zoom: only the note's title and body change size (the
// buttons around them do not), within 60–250%; the caret lands where the
// text is drawn at every zoom (a tap on a character puts the caret there);
// typing and replacing in the middle work; long notes scroll; Ctrl+=/−/0
// work; the zoom is remembered per note and survives reopening.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/notes/notes_page.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

void main() {
  late Directory dir;
  late AppState s;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_nzoom_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final long = [
    for (var i = 1; i <= 80; i++) 'Line $i of a long note about cells.',
  ].join('\n');

  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ws = Workspace(dir);
    s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await tester.runAsync(s.init);
  }

  Future<void> open(WidgetTester tester, String id) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: NoteEditor(
              key: ValueKey(id),
              state: s,
              noteId: id,
              onOpenNote: (_) {},
              onDeleted: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    await waitForBothClocks(tester, s.flush, what: 'Saving');
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  }

  EditableTextState bodyState(WidgetTester tester) => tester.state(
    find.descendant(
      of: find.byKey(const ValueKey('note-body')),
      matching: find.byType(EditableText),
    ),
  );
  RenderEditable body(WidgetTester tester) => bodyState(tester).renderEditable;

  String zoomLabel(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('note-text-zoom-value')))
      .data!;

  /// Taps the screen where character [index] of the body is drawn and
  /// returns where the caret went.
  Future<int> tapCharacter(WidgetTester tester, int index) async {
    final editable = body(tester);
    final rect = editable.getLocalRectForCaret(TextPosition(offset: index));
    final global = editable.localToGlobal(rect.centerLeft + const Offset(1, 0));
    await tester.tapAt(global);
    await tester.pump(const Duration(milliseconds: 400)); // not a double tap
    return bodyState(tester).textEditingValue.selection.baseOffset;
  }

  testWidgets('zoom changes only the note text, within its limits', (
    tester,
  ) async {
    await boot(tester);
    final n = s.workspace.createNote(title: 'Cells', body: long);
    await open(tester, n.id);
    expect(zoomLabel(tester), '100%');
    final buttonSize = tester.getSize(
      find.byKey(const ValueKey('note-text-zoom-in')),
    );
    final lineHeight = body(tester).preferredLineHeight;

    await tester.tap(find.byKey(const ValueKey('note-text-zoom-in')));
    await tester.pump();
    expect(zoomLabel(tester), '115%');
    expect(body(tester).preferredLineHeight, closeTo(lineHeight * 1.15, 0.5));
    // The app around the note keeps its size.
    expect(
      tester.getSize(find.byKey(const ValueKey('note-text-zoom-in'))),
      buttonSize,
    );

    for (var i = 0; i < 20; i++) {
      await tester.tap(find.byKey(const ValueKey('note-text-zoom-in')));
      await tester.pump();
    }
    expect(zoomLabel(tester), '250%');
    for (var i = 0; i < 30; i++) {
      final out = find.byKey(const ValueKey('note-text-zoom-out'));
      await tester.tap(out, warnIfMissed: false);
      await tester.pump();
    }
    expect(zoomLabel(tester), '60%');
    await tester.tap(find.byKey(const ValueKey('note-text-zoom-value')));
    await tester.pump();
    expect(zoomLabel(tester), '100%');
    expect(body(tester).preferredLineHeight, closeTo(lineHeight, 0.01));
    await done(tester);
  });

  testWidgets('the caret lands on the tapped character at every zoom; '
      'typing and replacing work', (tester) async {
    await boot(tester);
    final n = s.workspace.createNote(title: 'Cells', body: long);
    await open(tester, n.id);
    for (final z in [0.6, 1.0, 2.5]) {
      final state = tester.state<State>(find.byType(NoteEditor)) as dynamic;
      // ignore: avoid_dynamic_calls
      state.setTextZoomForTest(z);
      await tester.pump();
      for (final index in [0, 5, 20]) {
        expect(
          await tapCharacter(tester, index),
          index,
          reason: 'zoom $z, character $index',
        );
      }
    }

    // Type at the start, middle and end; select and replace.
    final edit = bodyState(tester);
    void type(String text, int at) => edit.userUpdateTextEditingValue(
      TextEditingValue(
        text: edit.textEditingValue.text.replaceRange(at, at, text),
        selection: TextSelection.collapsed(offset: at + text.length),
      ),
      SelectionChangedCause.keyboard,
    );
    type('START ', 0);
    final mid = edit.textEditingValue.text.length ~/ 2;
    type('MIDDLE', mid);
    type(' END', edit.textEditingValue.text.length);
    await tester.pump();
    var saved = s.workspace.notes[n.id]!.body;
    expect(saved, startsWith('START Line 1'));
    expect(saved, contains('MIDDLE'));
    expect(saved, endsWith('cells. END'));
    final from = saved.indexOf('Line 2'), to = from + 'Line 2'.length;
    edit.userUpdateTextEditingValue(
      TextEditingValue(
        text: saved.replaceRange(from, to, 'Second line'),
        selection: TextSelection.collapsed(offset: from + 11),
      ),
      SelectionChangedCause.keyboard,
    );
    await tester.pump();
    saved = s.workspace.notes[n.id]!.body;
    expect(saved, contains('Second line of a long note'));
    await done(tester);
  });

  testWidgets('long notes scroll at the largest zoom; Ctrl shortcuts', (
    tester,
  ) async {
    await boot(tester);
    final n = s.workspace.createNote(title: 'Cells', body: long);
    await open(tester, n.id);
    // Ctrl+= while typing in the note.
    await tester.tapAt(
      tester.getTopLeft(find.byKey(const ValueKey('note-body'))) +
          const Offset(30, 12),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(zoomLabel(tester), '115%');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(zoomLabel(tester), '100%');

    final state = tester.state<State>(find.byType(NoteEditor)) as dynamic;
    // ignore: avoid_dynamic_calls
    state.setTextZoomForTest(2.5);
    await tester.pump();
    final scrollable = find
        .ancestor(
          of: find.byKey(const ValueKey('note-body')),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final before = position.pixels;
    await tester.drag(scrollable, const Offset(0, -600));
    await tester.pump();
    expect(position.pixels, greaterThan(before));
    expect(position.maxScrollExtent, greaterThan(2000)); // all of it reachable
    await done(tester);
  });

  testWidgets('remembered per note, also after reopening', (tester) async {
    await boot(tester);
    final a = s.workspace.createNote(title: 'A', body: 'a');
    final b = s.workspace.createNote(title: 'B', body: 'b');
    await open(tester, a.id);
    await tester.tap(find.byKey(const ValueKey('note-text-zoom-in')));
    await tester.tap(find.byKey(const ValueKey('note-text-zoom-in')));
    await tester.pump();
    expect(zoomLabel(tester), '132%');
    await open(tester, b.id);
    expect(zoomLabel(tester), '100%');
    await open(tester, a.id);
    expect(zoomLabel(tester), '132%');
    await waitForBothClocks(tester, s.flush, what: 'Saving');

    // A restart: a new app on the same data.
    await tester.pumpWidget(const SizedBox());
    s.dispose();
    await boot(tester);
    await open(tester, a.id);
    expect(zoomLabel(tester), '132%');
    expect(s.settings.get<num>('noteTextZoom.${a.id}'), 1.32);
    await done(tester);
  });
}
