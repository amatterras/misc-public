// Dragging selected text and photos between THEapp's windows (notes,
// mindmaps, days): copy keeps the original, move removes it only after the
// content arrived (and only the exact text selected), attachments travel by
// the same asset id and never twice, Undo takes a drop back, cancelling
// the menu changes nothing, and an open note shows the change.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/notes/notes_page.dart';
import 'package:flutter_application_1/features/transfer/transfer.dart';
import 'package:flutter_test/flutter_test.dart';

// The smallest valid PNG (1×1).
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_wdrag_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> app() async {
    final ws = Workspace(dir);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await s.init();
    return s;
  }

  TextTransfer selection(String body, String noteId, String text) {
    final start = body.indexOf(text);
    return TextTransfer(
      text,
      sourceNoteId: noteId,
      start: start,
      end: start + text.length,
    );
  }

  group('selected text', () {
    test(
      'move removes exactly the selected text; Undo puts both back',
      () async {
        final s = await app();
        final ws = s.workspace;
        // "beta" appears twice: only the selected (second) one moves.
        const body = 'alpha beta gamma beta';
        final from = ws.createNote(title: 'From', body: body);
        final to = ws.createNote(title: 'To', body: 'start');
        final second = body.lastIndexOf('beta');
        final t = TextTransfer(
          'beta',
          sourceNoteId: from.id,
          start: second,
          end: second + 4,
        );
        expect(s.transferChoices(t, NotePlace(to.id)).map((c) => c.op), [
          TransferOp.copy,
          TransferOp.move,
        ]);
        final r = await s.performTransfer(t, NotePlace(to.id), TransferOp.move);
        expect(r.message, startsWith('Moved'));
        expect(ws.notes[from.id]!.body, 'alpha beta gamma ');
        expect(ws.notes[to.id]!.body, 'start\n\nbeta');

        await r.undo!();
        expect(ws.notes[from.id]!.body, body);
        expect(ws.notes[to.id]!.body, 'start');
        await s.flush();
        s.dispose();
      },
    );

    test(
      'if the note changed there, the move only copies and says so',
      () async {
        final s = await app();
        final ws = s.workspace;
        final from = ws.createNote(title: 'From', body: 'keep this text');
        final to = ws.createNote(title: 'To');
        final t = selection(from.body, from.id, 'this');
        ws.notes.put(ws.notes[from.id]!.copyWith(body: 'keep THAT text'));
        final r = await s.performTransfer(t, NotePlace(to.id), TransferOp.move);
        expect(r.message, contains('left in the note too'));
        expect(ws.notes[from.id]!.body, 'keep THAT text'); // untouched
        expect(ws.notes[to.id]!.body.trim(), 'this');
        await s.flush();
        s.dispose();
      },
    );

    test('move to a mindmap: a text box; Undo removes it again', () async {
      final s = await app();
      final ws = s.workspace;
      final c = s.canvas!;
      final from = ws.createNote(title: 'From', body: 'one two three');
      final t = selection(from.body, from.id, 'two');
      final r = await s.performTransfer(
        t,
        CanvasPlace(c.id, at: const Offset(10, 10)),
        TransferOp.move,
      );
      final boxes = c.items.whereType<TextItem>().where((i) => i.text == 'two');
      expect(boxes, hasLength(1));
      expect(ws.notes[from.id]!.body, 'one  three');
      await r.undo!();
      expect(
        c.items.whereType<TextItem>().where((i) => i.text == 'two'),
        isEmpty,
      );
      expect(ws.notes[from.id]!.body, 'one two three');
      await s.flush();
      s.dispose();
    });

    test('text from outside a note can only be copied', () async {
      final s = await app();
      final to = s.workspace.createNote(title: 'To');
      expect(
        s
            .transferChoices(const TextTransfer('x'), NotePlace(to.id))
            .map((c) => c.op),
        [TransferOp.copy],
      );
      await s.flush();
      s.dispose();
    });
  });

  group('photos', () {
    test('move to another note keeps the same asset; never attached twice; '
        'Undo restores', () async {
      final s = await app();
      final ws = s.workspace;
      final photo = await s.capture.imageFromBytes(_png, 'png');
      final from = ws.createNote(title: 'From', assetIds: [photo.id]);
      final to = ws.createNote(title: 'To');
      final drag = AssetsTransfer([photo.id], sourceNoteId: from.id);
      expect(s.transferChoices(drag, NotePlace(from.id)), isEmpty);
      expect(s.transferChoices(drag, NotePlace(to.id)).map((c) => c.op), [
        TransferOp.link,
        TransferOp.move,
      ]);

      final r = await s.performTransfer(
        drag,
        NotePlace(to.id),
        TransferOp.move,
      );
      expect(ws.notes[to.id]!.assetIds, [photo.id]);
      expect(ws.notes[from.id]!.assetIds, isEmpty);
      expect(ws.assets.all, hasLength(1)); // the same asset, no copy
      await r.undo!();
      expect(ws.notes[from.id]!.assetIds, [photo.id]);
      expect(ws.notes[to.id]!.assetIds, isEmpty);

      // Attach (copy semantics): on both notes; a second drop adds nothing.
      await s.performTransfer(drag, NotePlace(to.id), TransferOp.link);
      final again = await s.performTransfer(
        drag,
        NotePlace(to.id),
        TransferOp.link,
      );
      expect(again.message, 'Already attached to the note.');
      expect(ws.notes[to.id]!.assetIds, [photo.id]);
      expect(ws.notes[from.id]!.assetIds, [photo.id]);
      await s.flush();
      s.dispose();
    });

    test(
      'move onto a mindmap places the same photo; Undo takes it off',
      () async {
        final s = await app();
        final ws = s.workspace;
        final c = s.canvas!;
        final photo = await s.capture.imageFromBytes(_png, 'png');
        final from = ws.createNote(title: 'From', assetIds: [photo.id]);
        final r = await s.performTransfer(
          AssetsTransfer([photo.id], sourceNoteId: from.id),
          CanvasPlace(c.id, at: Offset.zero),
          TransferOp.move,
        );
        expect(c.items.whereType<ImageItem>().single.assetId, photo.id);
        expect(ws.notes[from.id]!.assetIds, isEmpty);
        await r.undo!();
        expect(c.items.whereType<ImageItem>(), isEmpty);
        expect(ws.notes[from.id]!.assetIds, [photo.id]);
        await s.flush();
        s.dispose();
      },
    );
  });

  group('on screen', () {
    Future<AppState> boot(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late AppState s;
      await tester.runAsync(() async => s = await app());
      return s;
    }

    Future<void> done(WidgetTester tester, AppState s) async {
      await tester.runAsync(s.flush);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 9)); // result banner timer
      s.dispose();
    }

    testWidgets('drag text from one window to another: cancel, then move', (
      tester,
    ) async {
      final s = await boot(tester);
      final ws = s.workspace;
      final from = ws.createNote(title: 'From', body: 'take me please');
      final to = ws.createNote(title: 'To', body: '');
      final t = selection(from.body, from.id, 'me');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 300,
                  child: TransferSource(
                    key: const ValueKey('src'),
                    transfer: () => t,
                    child: const SizedBox(
                      width: 100,
                      height: 60,
                      child: Text('grip'),
                    ),
                  ),
                ),
                Expanded(
                  child: TransferTarget(
                    key: const ValueKey('dst'),
                    state: s,
                    place: NotePlace(to.id),
                    child: const SizedBox.expand(child: Text('other window')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      Future<void> dragOver() async {
        final g = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('src'))),
        );
        await g.moveBy(const Offset(40, 0));
        await tester.pump();
        await g.moveTo(tester.getCenter(find.byKey(const ValueKey('dst'))));
        await tester.pump();
        await g.up();
        await tester.pumpAndSettle();
      }

      await dragOver();
      expect(find.byKey(const ValueKey('transfer-move')), findsOneWidget);
      // Closing the menu cancels: nothing changes.
      await tester.tapAt(const Offset(5, 880));
      await tester.pumpAndSettle();
      expect(ws.notes[from.id]!.body, 'take me please');
      expect(ws.notes[to.id]!.body, '');

      await dragOver();
      await tester.tap(find.byKey(const ValueKey('transfer-move')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(ws.notes[from.id]!.body, 'take  please');
      expect(ws.notes[to.id]!.body.trim(), 'me');
      expect(s.lastTransfer.value?.message, startsWith('Moved'));
      await done(tester, s);
    });

    testWidgets('an open note shows text moved out of it at once', (
      tester,
    ) async {
      final s = await boot(tester);
      final ws = s.workspace;
      final from = ws.createNote(title: 'From', body: 'one two three');
      final to = ws.createNote(title: 'To');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: NoteEditor(
                state: s,
                noteId: from.id,
                onOpenNote: (_) {},
                onDeleted: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => s.performTransfer(
          selection(from.body, from.id, 'two'),
          NotePlace(to.id),
          TransferOp.move,
        ),
      );
      await tester.pump();
      final fields = tester.widgetList<EditableText>(find.byType(EditableText));
      expect(fields.any((f) => f.controller.text == 'one  three'), isTrue);
      expect(fields.any((f) => f.controller.text == 'one two three'), isFalse);
      // Typing afterwards keeps the move (the old text does not come back).
      final body = find.byWidgetPredicate(
        (w) => w is EditableText && w.controller.text == 'one  three',
      );
      await tester.enterText(body, 'one  three!');
      await tester.pump();
      expect(ws.notes[from.id]!.body, 'one  three!');
      await done(tester, s);
    });
  });
}
