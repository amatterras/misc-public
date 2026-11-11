// Archive items keep their real content and connect to the workspace:
// the detail dialog shows the stored image, opens the exact saved link,
// and copies/moves content into notes; PDFs import as notes with their
// pages wherever a page renderer exists (PdfRenderer: iPhone/iPad and
// Windows), and still attach cleanly where none does.
import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/material.dart' hide Size;
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/notes/note_page.dart'
    show importPdfAsNote;
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/platform/pdf_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

/// A real 1×1 PNG (it must pass the importer's signature check).
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakeRenderer implements PdfRenderer {
  _FakeRenderer(this.pages);
  final int pages;
  int rendered = 0;

  @override
  Future<List<Size>?> pageSizes(String path) async =>
      List.filled(pages, const Size(612, 792));

  @override
  Future<Uint8List?> renderPage(String path, int page, int width) async {
    rendered++;
    return _png;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_arch_'));
  tearDown(() {
    PdfRenderer.resetForTests();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> appState({String name = 'app'}) async {
    final ws = Workspace(Directory('${dir.path}$sep$name'));
    await ws.load();
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

  File writePdf(String name) =>
      File('${dir.path}$sep$name')..writeAsStringSync('%PDF-1.4\n%synthetic\n');

  group('PDF import into notes', () {
    test('a PDF becomes a note with its pages where pages render', () async {
      PdfRenderer.setForTests(_FakeRenderer(3));
      final s = await appState();
      final pdf = writePdf('Lecture 1.pdf');
      s.capture.pickDocumentFiles = () => [pdf.path];
      final noteId = await importPdfAsNote(s);
      expect(noteId, isNotNull);
      final note = s.workspace.notes[noteId]!;
      expect(note.title, 'Lecture 1');
      expect(note.assetIds, hasLength(1));
      // The attachment is the real PDF, stored as a copy.
      final asset = s.workspace.assets[note.assetIds.single]!;
      final stored = s.workspace.documentFile(asset)!;
      expect(stored.readAsStringSync(), pdf.readAsStringSync());
      // Every page became a notebook page background.
      final doc = await s.canvases.load(notebookIdFor(note.id));
      expect(doc, isNotNull);
      expect(doc!.pageBackgrounds, hasLength(3));
      expect(doc.pageBackgrounds.first.assetId, asset.id);
      s.dispose();
    });

    test('without a renderer the PDF still imports as an attachment', () async {
      PdfRenderer.setForTests(null);
      final s = await appState();
      final pdf = writePdf('Paper.pdf');
      s.capture.pickDocumentFiles = () => [pdf.path];
      final noteId = await importPdfAsNote(s);
      expect(noteId, isNotNull);
      final note = s.workspace.notes[noteId]!;
      expect(note.assetIds, hasLength(1));
      // No pages could be laid out, but the content is kept and readable.
      final asset = s.workspace.assets[note.assetIds.single]!;
      expect(s.workspace.documentFile(asset), isNotNull);
      s.dispose();
    });
  });

  group('Windows PDF renderer channel', () {
    const channel = MethodChannel('theapp/windows');
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('decodes sizes and page bytes', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'pdfInfo') {
              expect(call.arguments, 'C:\\doc.pdf');
              return [
                [612.0, 792.0],
                [792.0, 612.0],
              ];
            }
            if (call.method == 'pdfRenderPage') {
              expect(call.arguments, {
                'path': 'C:\\doc.pdf',
                'page': 1,
                'width': 512,
              });
              return Uint8List.fromList([1, 2, 3]);
            }
            return null;
          });
      final renderer = WindowsPdfRenderer(channel: channel);
      expect(await renderer.pageSizes('C:\\doc.pdf'), const [
        Size(612, 792),
        Size(792, 612),
      ]);
      expect(await renderer.renderPage('C:\\doc.pdf', 1, 512), [1, 2, 3]);
    });

    test('an unreadable PDF is null, never a throw', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'pdf', message: 'unreadable');
          });
      final renderer = WindowsPdfRenderer(channel: channel);
      expect(await renderer.pageSizes('x'), isNull);
      expect(await renderer.renderPage('x', 0, 100), isNull);
      // An old runner without the handler behaves the same.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await renderer.pageSizes('x'), isNull);
    });
  });

  group('Archive item dialog', () {
    // Lets writes started from taps (the transaction log's intent file,
    // debounced saves) finish. The flush is started in the test's own
    // (fake-async) zone and nudged along: real IO events are delivered
    // only inside runAsync, while the fake zone's continuations run only
    // on a pump — so the two alternate until the flush reports done.
    Future<void> closeApp(WidgetTester tester, AppState s) async {
      var done = false;
      unawaited(s.flush().catchError((_) {}).whenComplete(() => done = true));
      for (var i = 0; i < 200 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(done, isTrue, reason: 'the workspace flush never finished');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      s.dispose();
    }

    Future<LibraryObject> savedImage(AppState s) async {
      final asset = await s.workspace.imageAssetFromBytes(_png, 'png');
      await s.capture.saveAssetToArchive(asset);
      return s.library.objects.single;
    }

    testWidgets('an image item shows the actual image and copies to a note', (
      tester,
    ) async {
      final s = (await tester.runAsync(appState))!;
      late LibraryObject object;
      late String targetNoteId;
      await tester.runAsync(() async {
        object = await savedImage(s);
        targetNoteId = s.workspace.createNote(title: 'Target note').id;
      });
      await tester.pumpWidget(TheApp(state: s));
      s.goTo(AppPage.links);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('archive-whole-look')));
      await tester.pump();
      await tester.pump();
      await tester.ensureVisible(
        find.text(object.title.isEmpty ? 'Untitled' : object.title).first,
      );
      await tester.pump();
      await tester.tap(
        find.text(object.title.isEmpty ? 'Untitled' : object.title).first,
      );
      await tester.pumpAndSettle();

      // The dialog shows the real image, not just a name.
      expect(find.byKey(const ValueKey('archive-image-preview')), findsOne);

      // Copy to… → A note → pick the target note.
      await tester.tap(find.byKey(const ValueKey('archive-copy-to')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('archive-dest-note')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('archive-pick-note-$targetNoteId')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      final assetId = object.attachmentIds.single;
      expect(s.workspace.notes[targetNoteId]!.assetIds, contains(assetId));
      // A copy: the Archive item is untouched.
      expect(s.workspace.libraryObjects[object.id]!.deleted, isFalse);
      // The same managed file, not a placeholder.
      expect(
        await tester.runAsync(
          () => s.workspace.attachments.readBytes(
            s.workspace.assets[assetId]!.file!,
          ),
        ),
        _png,
      );
      await closeApp(tester, s);
    });

    testWidgets('Move to a note takes the item out of the Archive', (
      tester,
    ) async {
      final s = (await tester.runAsync(appState))!;
      late LibraryObject object;
      late String targetNoteId;
      await tester.runAsync(() async {
        object = await savedImage(s);
        targetNoteId = s.workspace.createNote(title: 'Moved here').id;
      });
      await tester.pumpWidget(TheApp(state: s));
      s.goTo(AppPage.links);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('archive-whole-look')));
      await tester.pump();
      await tester.pump();
      await tester.ensureVisible(
        find.text(object.title.isEmpty ? 'Untitled' : object.title).first,
      );
      await tester.pump();
      await tester.tap(
        find.text(object.title.isEmpty ? 'Untitled' : object.title).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('archive-move-to')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('archive-dest-note')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('archive-pick-note-$targetNoteId')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      final assetId = object.attachmentIds.single;
      expect(s.workspace.notes[targetNoteId]!.assetIds, contains(assetId));
      // Moved: gone from the Archive, but the file and asset stay.
      expect(s.workspace.libraryObjects[object.id]!.deleted, isTrue);
      expect(s.workspace.assets[assetId], isNotNull);
      expect(
        s.workspace.attachments
            .fileFor(s.workspace.assets[assetId]!.file!)
            .existsSync(),
        isTrue,
      );
      await closeApp(tester, s);
    });

    testWidgets('a saved link goes into a note as the exact address', (
      tester,
    ) async {
      final s = (await tester.runAsync(appState))!;
      const url = 'https://example.com/a/b?q=1&UTM_source=x#frag';
      late LibraryObject object;
      late String targetNoteId;
      await tester.runAsync(() async {
        object = await s.library.save(
          type: LibraryObjectType.website,
          sourceUrl: url,
          title: 'Example',
        );
        targetNoteId = s.workspace.createNote(title: 'Reading list').id;
      });
      await tester.pumpWidget(TheApp(state: s));
      s.goTo(AppPage.links);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('archive-whole-look')));
      await tester.pump();
      await tester.pump();
      await tester.ensureVisible(find.text('Example').first);
      await tester.pump();
      await tester.tap(find.text('Example').first);
      await tester.pumpAndSettle();

      // The dialog shows and opens the saved address itself.
      expect(find.text(url), findsWidgets);
      expect(object.sourceUrl, url);

      await tester.tap(find.byKey(const ValueKey('archive-copy-to')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('archive-dest-note')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('archive-pick-note-$targetNoteId')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      final noteAssets = s.workspace.notes[targetNoteId]!.assetIds;
      expect(noteAssets, hasLength(1));
      // The exact original URL, never canonicalized or truncated.
      expect(s.workspace.assets[noteAssets.single]!.url, url);
      await closeApp(tester, s);
    });

    testWidgets('New note makes a standalone note and keeps the item', (
      tester,
    ) async {
      final s = (await tester.runAsync(appState))!;
      late LibraryObject object;
      await tester.runAsync(() async {
        object = await savedImage(s);
      });
      await tester.pumpWidget(TheApp(state: s));
      s.goTo(AppPage.links);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('archive-whole-look')));
      await tester.pump();
      await tester.pump();
      await tester.ensureVisible(
        find.text(object.title.isEmpty ? 'Untitled' : object.title).first,
      );
      await tester.pump();
      await tester.tap(
        find.text(object.title.isEmpty ? 'Untitled' : object.title).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('archive-make-note')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      final notes = s.workspace.notes.all.toList();
      expect(notes, hasLength(1));
      expect(notes.single.assetIds, object.attachmentIds);
      expect(s.workspace.libraryObjects[object.id]!.deleted, isFalse);
      await closeApp(tester, s);
    });
  });
}
