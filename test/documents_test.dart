// PDF documents: stored like photos, opened in the default viewer, never
// outside THEapp's attachments folder.
import 'dart:io';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/send_to.dart';
import 'package:flutter_application_1/features/search/search_dialog.dart';
import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File pdf;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('theapp_docs_');
    // A tiny file with a PDF header (content is never parsed by THEapp).
    pdf = File('${dir.path}${sep}Lecture notes.pdf')
      ..writeAsStringSync('%PDF-1.4\n%synthetic\n');
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> start(List<String> opened) async {
    final ws = Workspace(Directory('${dir.path}${sep}data'));
    final s =
        AppState(
            canvases: FileCanvasRepository(ws.store),
            settings: SettingsRepository(ws.store),
            workspace: ws,
            enableSendTo: false,
          )
          ..openDocument = ((path) {
            opened.add(path);
            return true;
          });
    s.capture.fetchPreviews = false;
    await s.init();
    return s;
  }

  test('a PDF becomes a document record with its file name', () async {
    final s = await start([]);
    final a = await s.workspace.documentAssetFromFile(pdf);
    expect(a.kind, AssetKind.document);
    expect(a.label, 'Lecture notes.pdf');
    final stored = s.workspace.documentFile(a)!;
    expect(stored.readAsStringSync(), pdf.readAsStringSync());
    expect(stored.path, isNot(pdf.path), reason: 'a copy is kept');
    final png = File('${dir.path}${sep}x.png')..writeAsBytesSync([1]);
    await expectLater(
      s.workspace.documentAssetFromFile(png),
      throwsArgumentError,
    );
    s.dispose();
  });

  test('only files inside the attachments folder can be opened', () async {
    final s = await start([]);
    final ws = s.workspace;
    final a = await ws.documentAssetFromFile(pdf);
    final now = DateTime.now();
    Asset doc(String file) => Asset(
      id: 'x',
      kind: AssetKind.document,
      file: file,
      createdAt: now,
      updatedAt: now,
    );
    for (final bad in [
      '..$sep..${sep}Windows${sep}evil.pdf',
      r'C:\Windows\evil.pdf',
      'sub/evil.pdf',
      'notes.exe',
    ]) {
      expect(ws.documentFile(doc(bad)), isNull, reason: bad);
    }
    expect(ws.documentFile(doc('missing.pdf')), isNull);
    final asImage = Asset(
      id: 'y',
      kind: AssetKind.image,
      file: a.file,
      createdAt: now,
      updatedAt: now,
    );
    expect(ws.documentFile(asImage), isNull, reason: 'wrong kind');
    s.dispose();
  });

  test(
    'picker and Send to accept supported documents and skip missing files',
    () async {
      final s = await start([]);
      final txt = File('${dir.path}${sep}readme.txt')..writeAsStringSync('x');
      s.capture.pickDocumentFiles = () => [
        pdf.path,
        txt.path,
        '${dir.path}${sep}gone.pdf',
      ];
      final picked = await s.capture.pickDocuments();
      expect(picked.map((a) => a.label), ['Lecture notes.pdf', 'readme.txt']);

      final bridge = SendToBridge(Directory('${dir.path}${sep}sendto'));
      await bridge.forward([pdf.path]);
      expect(await bridge.processRequests(s.capture), 1);
      final saved = s.library.objects.single;
      expect(saved.type, LibraryObjectType.document);
      expect(
        s.workspace.assets[saved.attachmentIds.single]?.kind,
        AssetKind.document,
      );
      s.dispose();
    },
  );

  test('double-clicking a PDF card opens the stored copy', () async {
    final opened = <String>[];
    final s = await start(opened);
    final a = await s.workspace.documentAssetFromFile(pdf);
    final card = s.canvas!.insertLink(a, const Offset(0, 0));
    s.activateCanvasItem(card);
    expect(opened, [s.workspace.documentFile(a)!.path]);

    // Not on this device yet (e.g. still syncing): a message, nothing opened.
    s.workspace.documentFile(a)!.deleteSync();
    s.activateCanvasItem(card);
    expect(opened, hasLength(1));
    expect(s.toast.value, contains('not on this device'));
    s.dispose();
  });

  test('search finds documents by file name', () async {
    final s = await start([]);
    await s.workspace.documentAssetFromFile(pdf);
    final hits = searchEverything(s, 'lecture');
    expect(hits.map((r) => r.kind), contains('PDF'));
    s.dispose();
  });

  test('canvas link cards keep pointing at the document record', () async {
    final s = await start([]);
    final a = await s.workspace.documentAssetFromFile(pdf);
    final card = s.canvas!.insertLink(a, Offset.zero);
    final saved = s.canvas!.document.toJson();
    final reloaded = CanvasDocument.fromJson(saved);
    final again = reloaded.items.whereType<LinkItem>().single;
    expect(again.id, card.id);
    expect(again.assetId, a.id);
    s.dispose();
  });
}
