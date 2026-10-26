// PDF page anchors and linked notes: stable links to a page of an Archive
// PDF, notes made for pages, the PDF-and-notes window, and what happens
// when the PDF is renamed, moved, replaced, missing or deleted.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/pdfanchors/pdf_anchors.dart';
import 'package:flutter_application_1/features/pdfanchors/pdf_notes_split.dart';
import 'package:flutter_application_1/features/smartlinks/smart_links.dart';
import 'package:flutter_application_1/features/smartlinks/smart_links_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pdfBytes(int pages, {String extra = ''}) => Uint8List.fromList(
  '%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
          '2 0 obj << /Type /Pages /Kids [] /Count $pages >> endobj\n$extra%%EOF\n'
      .codeUnits,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState s;

  Future<AppState> boot() async {
    final ws = Workspace(Directory('${dir.path}/data'));
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    state.capture.fetchPreviews = false;
    await state.init();
    return state;
  }

  Future<Asset> addPdf(String name, {int pages = 12}) async {
    final f = File('${dir.path}/src/$name.pdf')
      ..createSync(recursive: true)
      ..writeAsBytesSync(pdfBytes(pages));
    return s.workspace.documentAssetFromFile(f);
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_pdfanchor_');
    s = await boot();
  });
  tearDown(() async {
    await s.flush();
    s.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('the anchor', () {
    test('a link to page N: made, found, and read back', () async {
      final a = await addPdf('Lecture');
      final token = pdfAnchorToken(a, 7);
      expect(token, startsWith('[[theapp:pdf/${a.id}#7|'));
      final found = findLinks('see $token now').single;
      expect(found.ref, WorkspaceRef(RefKind.pdf, a.id, '7'));
      expect(found.ref.page, 7);
      // Not a usable page: ignored, not guessed.
      expect(findLinks('[[theapp:pdf/${a.id}#0|x]]'), isEmpty);
      expect(findLinks('[[theapp:pdf/${a.id}#abc|x]]'), isEmpty);
      expect(findLinks('[[theapp:pdf/${a.id}|x]]'), isEmpty);
      expect(plainLinkText(token), contains('p. 7'));
    });

    test('a note for a page: new, or added to a note once', () async {
      final a = await addPdf('Lecture');
      final n = createPdfAnchorNote(s, a.id, 3);
      expect(n.title, 'Lecture.pdf · page 3');
      expect(findLinks(n.body).single.ref, WorkspaceRef(RefKind.pdf, a.id, '3'));
      expect(n.assetIds, [a.id], reason: 'the PDF is attached, not copied');
      // Another page into the same note; asking again changes nothing.
      createPdfAnchorNote(s, a.id, 5, noteId: n.id);
      final before = s.workspace.notes[n.id]!.body;
      createPdfAnchorNote(s, a.id, 5, noteId: n.id);
      expect(s.workspace.notes[n.id]!.body, before);
      expect(findLinks(before).map((t) => t.ref.page), [3, 5]);
      expect(s.workspace.notes[n.id]!.assetIds, [a.id]);
      expect(() => createPdfAnchorNote(s, a.id, 0), throwsArgumentError);
      expect(() => createPdfAnchorNote(s, 'nope', 1), throwsArgumentError);
      final link = s.workspace.linkAsset('https://example.com');
      expect(() => createPdfAnchorNote(s, link.id, 1), throwsArgumentError);
    });

    test('the page count recorded in the PDF is read when it can be', () {
      expect(pdfPageCountGuess(pdfBytes(12)), 12);
      expect(pdfPageCountGuess(Uint8List.fromList('%PDF-1.7\nx'.codeUnits)), isNull);
    });
  });

  group('rename, move, replace, lose', () {
    test('renaming or moving the PDF keeps every link', () async {
      final a = await addPdf('Old name');
      final ref = WorkspaceRef(RefKind.pdf, a.id, '4');
      expect(resolveRef(s, ref).title, 'Old name.pdf · page 4');
      s.workspace.assets.put(a.copyWith(title: 'Better name'));
      expect(resolveRef(s, ref).title, 'Better name · page 4');
      final folder = s.workspace.createFolder('Course');
      s.workspace.assets.put(
        s.workspace.assets[a.id]!.copyWith(folderId: () => folder.id),
      );
      final r = resolveRef(s, ref);
      expect(r.health, LinkHealth.ok);
      expect(r.opens, isTrue);
      expect(pdfAnchorWarning(s, ref), isNull);
    });

    test('missing file, replaced file, page beyond the end, deleted record',
        () async {
      final a = await addPdf('Book', pages: 5);
      final file = s.workspace.documentFile(a)!;
      expect(pdfAnchorWarning(s, WorkspaceRef(RefKind.pdf, a.id, '9')),
          'The PDF has only 5 pages.');
      // Changed outside THEapp: the link is kept and says so.
      file.writeAsBytesSync(pdfBytes(5, extra: '% a different, longer file\n'));
      final ref = WorkspaceRef(RefKind.pdf, a.id, '2');
      expect(resolveRef(s, ref).preview, contains('changed'));
      expect(pdfAnchorWarning(s, ref), contains('changed'));
      // Gone from the device: not openable, and not guessed.
      file.deleteSync();
      final gone = resolveRef(s, ref);
      expect(gone.health, LinkHealth.unavailable);
      expect(gone.opens, isFalse);
      expect(pdfAnchorWarning(s, ref), 'The PDF file is missing.');
      expect(await openPdfAnchor(s, ref), isFalse);
      expect(s.toast.value, contains('not on this device'));
      // The record deleted: marked deleted, never another document.
      s.workspace.assets.remove(a.id);
      final other = await addPdf('Other', pages: 5);
      expect(resolveRef(s, ref).health, LinkHealth.deleted);
      expect(other.id, isNot(a.id));
      expect(await openPdfAnchor(s, ref), isFalse);
    });

    test('a replaced document is a different document, never the old one',
        () async {
      final a = await addPdf('Paper', pages: 5);
      final newer = File('${dir.path}/src/Paper-v2.pdf')
        ..writeAsBytesSync(pdfBytes(8, extra: '% second version\n'));
      final b = await s.workspace.documentAssetFromFile(newer);
      expect(b.id, isNot(a.id));
      final oldRef = WorkspaceRef(RefKind.pdf, a.id, '2');
      expect(resolveRef(s, oldRef).title, startsWith('Paper.pdf'));
      expect(resolveRef(s, oldRef).ref.id, a.id);
    });
  });

  group('opening a page', () {
    test('goes to the viewer at the page; open notes are left alone', () async {
      final a = await addPdf('Slides');
      final opened = <(String, int)>[];
      s.pdfOpener = (file, page) async {
        opened.add((file.path, page));
        return true;
      };
      final writing = s.workspace.createNote(title: 'Draft');
      s.workspace.notes.put(
        writing.copyWith(body: 'half a sentence ${pdfAnchorToken(a, 6)} not fin'),
      );
      final before = s.workspace.notes[writing.id]!.body;
      final ok = await openWorkspaceRef(
        s,
        WorkspaceRef(RefKind.pdf, a.id, '6'),
        from: WorkspaceRef(RefKind.note, writing.id),
      );
      expect(ok, isTrue);
      expect(opened.single.$2, 6);
      expect(opened.single.$1, s.workspace.documentFile(a)!.path);
      expect(s.pdfFocus.value, (assetId: a.id, page: 6));
      expect(s.workspace.notes[writing.id]!.body, before,
          reason: 'the note was not touched');
      expect(s.linkReturn.value.last.label, 'Draft', reason: 'a way back');
    });

    test('a note that shows that page as one of its pages opens there',
        () async {
      final a = await addPdf('Textbook');
      final n = s.workspace.createNote(title: 'Worked problems');
      s.workspace.attachToNote(n.id, a.id);
      await s.canvases.save(
        CanvasDocument(
          id: notebookIdFor(n.id),
          title: 'nb',
          items: const [],
          updatedAt: DateTime(2026),
          kind: 'notebook',
          pageBackgrounds: [
            PageBackground(
              pageIndex: 3,
              assetId: a.id,
              pdfPage: 10, // the PDF's page 11
              width: 600,
              height: 800,
            ),
          ],
        ),
      );
      var viewerCalled = false;
      s.pdfOpener = (f, p) async => viewerCalled = true;
      expect(await openPdfAnchor(s, WorkspaceRef(RefKind.pdf, a.id, '11')), isTrue);
      expect(viewerCalled, isFalse);
      expect(s.notebookJump.value, (noteId: n.id, page: 3));
      expect(s.page, AppPage.notes);
    });

    test('anchors survive a restart', () async {
      final a = await addPdf('Persistent');
      final n = createPdfAnchorNote(s, a.id, 8);
      await s.flush();
      s.dispose();
      s = await boot();
      final hits = pdfAnchorsOf(s, a.id);
      expect(hits.single.page, 8);
      expect(hits.single.source, WorkspaceRef(RefKind.note, n.id));
      expect(resolveRef(s, WorkspaceRef(RefKind.pdf, a.id, '8')).opens, isTrue);
    });
  });

  group('on screen', () {
    Future<void> pumpSplit(WidgetTester tester, String assetId, double width) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: PdfNotesSplit(state: s, assetId: assetId)),
        ),
      );
      await tester.pump();
    }

    testWidgets('the window: notes by page, jump, new note, resizable divider', (
      tester,
    ) async {
      final a = (await tester.runAsync(() => addPdf('Course reader')))!;
      createPdfAnchorNote(s, a.id, 9);
      createPdfAnchorNote(s, a.id, 2);
      await pumpSplit(tester, a.id, 1000);
      // Notes in page order; tapping one makes the PDF side follow.
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect(tiles, hasLength(2));
      expect((tiles.first.leading as Chip).label.toString(), contains('2'));
      await tester.tap(find.byKey(ValueKey('pdf-hit-${s.workspace.notes.all.first.id}-9')));
      await tester.pump();
      expect(find.text('Page 9'), findsOneWidget);
      expect(s.pdfFocus.value?.page, 9);
      // Page controls.
      await tester.tap(find.byKey(const ValueKey('pdf-next')));
      await tester.pump();
      expect(find.text('Page 10'), findsOneWidget);
      // A note for the current page.
      final before = s.workspace.notes.all.length;
      await tester.tap(find.byKey(const ValueKey('pdf-new-note')));
      await tester.pump();
      expect(s.workspace.notes.all.length, before + 1);
      expect(pdfAnchorsOf(s, a.id).map((h) => h.page), contains(10));
      // The divider moves and the choice is kept.
      final pdfSide = tester.getSize(find.byKey(const ValueKey('pdf-page-label'))).width;
      expect(pdfSide, greaterThan(0));
      final handle = find.byKey(const ValueKey('pdf-split-handle'));
      final x0 = tester.getCenter(handle).dx;
      await tester.drag(handle, const Offset(150, 0));
      await tester.pump();
      expect(tester.getCenter(handle).dx, greaterThan(x0 + 100));
      expect(s.settings.get<num>('pdfSplitRatio')!.toDouble(), greaterThan(0.5));
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a narrow window stacks the PDF above its notes', (tester) async {
      final a = (await tester.runAsync(() => addPdf('Narrow')))!;
      createPdfAnchorNote(s, a.id, 1);
      await pumpSplit(tester, a.id, 420);
      expect(find.byKey(const ValueKey('pdf-split-handle')), findsNothing);
      final pdf = tester.getRect(find.byKey(const ValueKey('pdf-page-label')));
      final notes = tester.getRect(find.byType(ListTile));
      expect(pdf.bottom, lessThan(notes.top));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a missing file is said so in the window', (tester) async {
      final a = (await tester.runAsync(() => addPdf('Lost')))!;
      s.workspace.documentFile(a)!.deleteSync();
      await pumpSplit(tester, a.id, 900);
      expect(find.byKey(const ValueKey('pdf-warning')), findsOneWidget);
      expect(find.textContaining('not on this device'), findsWidgets);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the link picker offers a page of a PDF', (tester) async {
      final a = (await tester.runAsync(() => addPdf('Pick me')))!;
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      String? token;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => token = await pickWorkspaceLink(context, s),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('link-pick-pdf')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('pdf-pick-${a.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '14');
      await tester.tap(find.text('Link'));
      await tester.pumpAndSettle();
      expect(findLinks(token!).single.ref, WorkspaceRef(RefKind.pdf, a.id, '14'));
    });
  });
}
