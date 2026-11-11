// Archive items in a folder: one tap opens the content itself (the exact
// link, the photo popup, the scrollable PDF popup with "Make a note" that
// keeps the item), a still long press opens the info dialog, a full swipe
// left deletes. Previews are smart cropped to the busiest part.
import 'dart:async' show unawaited;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/new_ui/archive_item_actions.dart';
import 'package:flutter_application_1/platform/pdf_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real 1×1 PNG.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakeRenderer implements PdfRenderer {
  @override
  Future<List<Size>?> pageSizes(String path) async =>
      List.filled(3, const Size(612, 792));

  @override
  Future<Uint8List?> renderPage(String path, int page, int width) async => _png;
}

/// A [w]×[h] grey picture with a sharp, colourful checkerboard patch.
Uint8List _picture(int w, int h, Rect patch) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final inPatch = patch.contains(Offset(x + .5, y + .5));
      final on = (x + y).isEven;
      out[i] = inPatch ? (on ? 255 : 0) : 128;
      out[i + 1] = inPatch ? (on ? 40 : 200) : 128;
      out[i + 2] = inPatch ? (on ? 0 : 255) : 128;
      out[i + 3] = 255;
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('smart crop', () {
    test('the focus follows the detailed part of the picture', () {
      final topLeft = smartFocus(
        _picture(48, 32, const Rect.fromLTWH(2, 2, 10, 8)),
        48,
        32,
      );
      expect(topLeft.dx, lessThan(.3));
      expect(topLeft.dy, lessThan(.35));
      final right = smartFocus(
        _picture(48, 32, const Rect.fromLTWH(38, 12, 8, 8)),
        48,
        32,
      );
      expect(right.dx, greaterThan(.7));
      // A flat picture: the middle.
      expect(
        smartFocus(_picture(20, 20, Rect.zero), 20, 20),
        const Offset(.5, .5),
      );
    });

    test('the cover alignment puts the focus in view', () {
      // A wide picture in a square: only the horizontal axis can move.
      expect(coverAlignment(const Offset(0, .5), 2, 1), const Alignment(-1, 0));
      expect(coverAlignment(const Offset(1, .5), 2, 1), const Alignment(1, 0));
      expect(coverAlignment(const Offset(.5, .5), 2, 1), Alignment.center);
      // A tall picture: the vertical axis.
      expect(coverAlignment(const Offset(.5, .4), .5, 1).y, closeTo(-.4, 1e-9));
      // Same shape: nothing to move.
      expect(coverAlignment(const Offset(0, 0), 1, 1), Alignment.center);
    });
  });

  group('one tap in a folder', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('theapp_tap_');
      PdfRenderer.setForTests(_FakeRenderer());
    });
    tearDown(() {
      PdfRenderer.resetForTests();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    // See archive_content_actions_test.dart: the flush is nudged along in
    // the fake zone so taps that start transactions do not hang teardown.
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
      await tester.pump(const Duration(seconds: 9));
      s.dispose();
    }

    testWidgets('link, photo, PDF, long press and full swipe', (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ws = Workspace(dir);
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      )..capture.fetchPreviews = false;
      await tester.runAsync(s.init);
      String? opened;
      s.openUrl = (url) {
        opened = url;
        return true;
      };
      const url = 'https://example.com/Path/To?q=Ä%20b&x=1#Frag';
      late LibrarySpace folder;
      late LibraryObject link, photo, pdf, note;
      await tester.runAsync(() async {
        folder = await s.library.createSpace('Mixed');
        link = await s.library.save(
          type: LibraryObjectType.website,
          title: 'A link',
          sourceUrl: url,
          spaceId: folder.id,
        );
        final image = await ws.imageAssetFromBytes(_png, 'png');
        await s.capture.saveAssetToArchive(image, spaceId: folder.id);
        final pdfFile = File('${dir.path}${Platform.pathSeparator}doc.pdf')
          ..writeAsBytesSync('%PDF-1.4\n%%EOF\n'.codeUnits);
        final doc = await ws.documentAssetFromFile(pdfFile);
        await s.capture.saveAssetToArchive(doc, spaceId: folder.id);
        note = await s.library.save(
          type: LibraryObjectType.note,
          title: 'Plain text',
          content: 'Only words',
          spaceId: folder.id,
        );
      });
      final all = s.library.objects.toList();
      photo = all.firstWhere((o) => o.type == LibraryObjectType.image);
      pdf = all.firstWhere((o) => o.type == LibraryObjectType.document);
      expect(archiveTapOf(ws, link), ArchiveTap.openLink);
      expect(archiveTapOf(ws, photo), ArchiveTap.showImage);
      expect(archiveTapOf(ws, pdf), ArchiveTap.showPdf);
      expect(archiveTapOf(ws, note), ArchiveTap.info);

      await tester.pumpWidget(TheApp(state: s));
      await settle(tester);
      s.goTo(AppPage.links);
      await settle(tester);
      await tester.tap(find.byKey(ValueKey('archive-collection-${folder.id}')));
      await settle(tester);

      // Cells are twice as big as before (a 112 px preview).
      expect(
        tester.getSize(find.byKey(ValueKey('archive-preview-${photo.id}'))),
        const Size(112, 112),
      );

      // Link: straight to the exact saved address.
      await tester.tap(find.byKey(ValueKey('archive-item-${link.id}')));
      await settle(tester);
      expect(opened, url);
      expect(find.byType(AlertDialog), findsNothing);

      // Photo: the picture in a popup with Save.
      await tester.tap(find.byKey(ValueKey('archive-item-${photo.id}')));
      await settle(tester);
      expect(find.byKey(const ValueKey('archive-image-popup')), findsOneWidget);
      expect(find.byKey(const ValueKey('archive-popup-save')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('archive-popup-close')));
      await settle(tester);

      // PDF: its pages in a scrolling popup; "Make a note" keeps the item.
      await tester.tap(find.byKey(ValueKey('archive-item-${pdf.id}')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('archive-pdf-popup')), findsOneWidget);
      expect(find.byKey(const ValueKey('archive-pdf-pages')), findsOneWidget);
      expect(find.byKey(const ValueKey('archive-pdf-page-0')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('archive-popup-note')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('archive-pdf-popup')), findsNothing);
      final made = ws.notes.all.where((n) => n.title == pdf.title).single;
      expect(made.assetIds, pdf.attachmentIds);
      expect(ws.libraryObjects[pdf.id]!.deleted, isFalse);

      // Long press held still: the info dialog.
      await tester.longPress(find.byKey(ValueKey('archive-item-${note.id}')));
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Only words'), findsWidgets);
      await tester.tapAt(const Offset(5, 5)); // outside: closes
      await settle(tester);
      await tester.pageBack().catchError((_) {});
      await settle(tester);

      // A full swipe left deletes (Undo is offered).
      await tester.drag(
        find.byKey(ValueKey('archive-swipe-${note.id}')),
        const Offset(-800, 0),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await settle(tester);
      expect(ws.libraryObjects[note.id]?.deleted ?? true, isTrue);
      expect(find.text('Undo'), findsOneWidget);

      await closeApp(tester, s);
    });
  });
}
