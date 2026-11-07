// Archive duplicate detection: link normalization, file content hashes,
// text, the name-and-size hint, "save anyway", share-import reuse, and the
// small "Already in Archive" popup.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart'
    show newId;
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/repositories/library_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/send_to.dart';
import 'package:flutter_application_1/features/library/duplicate_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('link keys', () {
    String? k(String url) => ArchiveUrlKey.of(url);

    test('http/https, www, trailing slash and fragments match', () {
      final base = k('https://example.com/articles/42');
      expect(k('http://example.com/articles/42'), base);
      expect(k('https://www.example.com/articles/42'), base);
      expect(k('https://EXAMPLE.com/articles/42/'), base);
      expect(k('https://example.com/articles/42#comments'), base);
      expect(k('https://example.com:443/articles/42'), base);
      expect(k('https://example.com'), k('https://example.com/'));
    });

    test('tracking parameters are ignored, in any order', () {
      final base = k('https://shop.example/item?id=7&color=red');
      expect(
        k(
          'https://shop.example/item?utm_source=mail&color=red'
          '&fbclid=abc&id=7&utm_campaign=x&gclid=1',
        ),
        base,
      );
      expect(k('https://shop.example/item?color=red&id=7'), base);
      expect(
        k('https://youtu.be/dQw4w9WgXcQ?si=Share123'),
        k('https://youtu.be/dQw4w9WgXcQ'),
      );
    });

    test('meaningful differences are kept', () {
      expect(
        k('https://shop.example/item?id=7'),
        isNot(k('https://shop.example/item?id=8')),
      );
      expect(
        k('https://example.com/a'),
        isNot(k('https://example.com/b')),
        reason: 'two pages of one site are different resources',
      );
      expect(
        k('https://example.com/Docs'),
        isNot(k('https://example.com/docs')),
        reason: 'paths are case sensitive',
      );
      expect(
        k('https://www.youtube.com/watch?v=aaa&si=x'),
        isNot(k('https://www.youtube.com/watch?v=bbb')),
      );
      expect(
        k('https://app.example/#/inbox'),
        isNot(k('https://app.example/#/settings')),
        reason: 'single-page-app routes select content',
      );
      expect(
        k('https://github.com/a/b?ref=main'),
        isNot(k('https://github.com/a/b?ref=dev')),
        reason: '"ref" is not treated as tracking',
      );
      expect(
        k('https://example.com:8080/a'),
        isNot(k('https://example.com/a')),
      );
      expect(k('mailto:someone@example.com'), isNull);
    });
  });

  group('repository', () {
    late Directory dir;
    late Workspace ws;
    late LibraryRepository repo;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('theapp_dupes_');
      ws = Workspace(dir);
      await ws.load();
      repo = LibraryRepository(ws);
    });
    tearDown(() {
      repo.dispose();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<Asset> file(
      String name,
      List<int> bytes, {
      bool hashed = true,
    }) async {
      final stored = await ws.attachments.importBytes(
        Uint8List.fromList(bytes),
        'pdf',
      );
      final info = await ws.attachments.contentInfo(stored);
      final now = DateTime.now().toUtc();
      final asset = Asset(
        id: newId(),
        kind: AssetKind.document,
        createdAt: now,
        updatedAt: now,
        file: stored,
        title: name,
        fileSha256: hashed ? info.$1 : null,
        fileSize: info.$2,
      );
      ws.assets.put(asset);
      return asset;
    }

    Future<LibraryObject> saveFile(Asset a, {bool again = false}) =>
        repo.save(
          type: LibraryObjectType.document,
          title: a.label,
          attachmentIds: [a.id],
          allowDuplicate: again,
        );

    test('the same link with tracking parameters is found', () async {
      final saved = await repo.save(
        type: LibraryObjectType.website,
        sourceUrl: 'https://news.example/story/1',
        title: 'Story',
      );
      final dup = repo.findDuplicate(
        sourceUrl: 'http://www.news.example/story/1/?utm_source=x#top',
      );
      expect(dup?.existing.id, saved.id);
      expect(dup?.reason, DuplicateReason.sameLink);
      expect(dup?.certain, isTrue);
      expect(
        repo.findDuplicate(sourceUrl: 'https://news.example/story/2'),
        isNull,
      );
    });

    test('identical files match by content, whatever their names', () async {
      final a = await file('report.pdf', [1, 2, 3, 4]);
      final saved = await saveFile(a);
      final b = await file('copy of report (2).pdf', [1, 2, 3, 4]);
      final dup = repo.findDuplicate(attachmentIds: [b.id]);
      expect(dup?.existing.id, saved.id);
      expect(dup?.reason, DuplicateReason.sameFile);
    });

    test('same name, different content: not a duplicate', () async {
      await saveFile(await file('notes.pdf', [1, 2, 3]));
      final other = await file('notes.pdf', [9, 9, 9]);
      expect(repo.findDuplicate(attachmentIds: [other.id]), isNull);
    });

    test('same name and size without a hash is only a hint', () async {
      final a = await file('scan.pdf', [5, 6, 7], hashed: false);
      final saved = await saveFile(a);
      final b = await file('scan.pdf', [7, 6, 5], hashed: false);
      final dup = repo.findDuplicate(attachmentIds: [b.id]);
      expect(dup?.existing.id, saved.id);
      expect(dup?.reason, DuplicateReason.sameNameAndSize);
      expect(dup?.certain, isFalse);
      // A hint is never acted on automatically: saving creates a new item.
      final second = await saveFile(b);
      expect(second.id, isNot(saved.id));
      expect(repo.objects, hasLength(2));
    });

    test('the same text is found; the same title alone is not', () async {
      final note = await repo.save(
        type: LibraryObjectType.note,
        title: 'Ideas',
        content: 'Visit the harbour',
      );
      expect(
        repo.findDuplicate(content: 'Visit the harbour')?.existing.id,
        note.id,
      );
      expect(repo.findDuplicate(content: 'Visit the station'), isNull);
    });

    test('save anyway creates a copy; the existing item is untouched', () async {
      final first = await repo.save(
        type: LibraryObjectType.website,
        sourceUrl: 'https://a.example/page',
        title: 'Page',
      );
      await repo.setCategory(first.id, 'resource', true);
      final before = ws.libraryObjects[first.id]!.toJson();
      // Default: reused, nothing new.
      final reused = await repo.saveWithResult(
        type: LibraryObjectType.website,
        sourceUrl: 'https://a.example/page?utm_medium=social',
        title: 'Page',
      );
      expect(reused.object.id, first.id);
      expect(reused.reused?.reason, DuplicateReason.sameLink);
      expect(repo.objects, hasLength(1));
      // Save anyway.
      final copy = await repo.save(
        type: LibraryObjectType.website,
        sourceUrl: 'https://a.example/page?utm_medium=social',
        title: 'Page',
        allowDuplicate: true,
      );
      expect(copy.id, isNot(first.id));
      expect(repo.objects, hasLength(2));
      expect(repo.categoriesOf(first.id), {'resource'});
      final after = ws.libraryObjects[first.id]!.toJson();
      for (final key in ['title', 'sourceUrl', 'canonicalUrl', 'deleted']) {
        expect(after[key], before[key], reason: key);
      }
    });

    test('deleted items are not reported', () async {
      final o = await repo.save(
        type: LibraryObjectType.website,
        sourceUrl: 'https://gone.example/',
      );
      await repo.delete(o.id);
      expect(repo.findDuplicate(sourceUrl: 'https://gone.example'), isNull);
    });

    test('two quick saves of the same link create one item', () async {
      final results = await Future.wait([
        for (var i = 0; i < 3; i++)
          repo.save(
            type: LibraryObjectType.website,
            sourceUrl: 'https://quick.example/x',
          ),
      ]);
      expect(results.map((o) => o.id).toSet(), hasLength(1));
      expect(repo.objects, hasLength(1));
    });

    test('checking 2,000 items stays fast', () async {
      final now = DateTime.now().toUtc();
      for (var i = 0; i < 2000; i++) {
        ws.libraryObjects.put(
          LibraryObject(
            id: 'o$i',
            type: LibraryObjectType.website,
            sourceUrl: 'https://site$i.example/page?id=$i',
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      repo.findDuplicate(sourceUrl: 'https://warm.example'); // fills cache
      final watch = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        repo.findDuplicate(sourceUrl: 'https://site$i.example/page?id=$i');
      }
      watch.stop();
      expect(watch.elapsedMilliseconds / 20, lessThan(50));
    });
  });

  group('share imports', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('theapp_dupshare_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<AppState> appState() async {
      final ws = Workspace(dir);
      await ws.load();
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      )..capture.fetchPreviews = false;
      await s.init();
      return s;
    }

    test('a re-shared link is reused and can be saved as a copy', () async {
      final s = await appState();
      final bridge = SendToBridge(dir);
      await bridge.requestsDir.create(recursive: true);
      File('${bridge.requestsDir.path}/r1.json').writeAsStringSync(
        '{"type":"url","value":"https://blog.example/post",'
        '"url":"https://blog.example/post"}',
      );
      await bridge.processRequests(s.capture);
      expect(s.library.objects, hasLength(1));
      expect(bridge.takeReused(), isEmpty);
      // Retrying the same request (after a crash) is not a "duplicate".
      File('${bridge.requestsDir.path}/r1.json').writeAsStringSync(
        '{"type":"url","value":"https://blog.example/post",'
        '"url":"https://blog.example/post"}',
      );
      await bridge.processRequests(s.capture);
      expect(bridge.takeReused(), isEmpty);
      // Sharing it again later (with tracking) is.
      File('${bridge.requestsDir.path}/r2.json').writeAsStringSync(
        '{"type":"url","value":"https://blog.example/post?utm_source=ios",'
        '"url":"https://blog.example/post?utm_source=ios","tagId":"resource"}',
      );
      await bridge.processRequests(s.capture);
      expect(s.library.objects, hasLength(1), reason: 'nothing saved twice');
      final reused = bridge.takeReused();
      expect(reused, hasLength(1));
      expect(reused.single.reason, DuplicateReason.sameLink);
      // "Save anyway" from the popup.
      await reused.single.saveCopy!();
      expect(s.library.objects, hasLength(2));
      final copy = s.library.objects.firstWhere(
        (o) => o.id != reused.single.existing.id,
      );
      expect(s.library.categoriesOf(copy.id), {'resource'});
      // Without the app shell the user still gets a notice.
      await s.offerArchiveDuplicates(reused);
      expect(s.toast.value, startsWith('Already in Archive'));
      await s.flush();
      s.dispose();
    });

    test('the popup answer drives open / save anyway / cancel', () async {
      final s = await appState();
      await s.capture.captureToArchive(url: 'https://x.example/a');
      final reused = <ArchiveDuplicate>[];
      await s.capture.captureToArchive(
        url: 'https://x.example/a/',
        reused: reused,
      );
      expect(reused, hasLength(1));
      String? opened;
      s.openArchiveObject = (id) => opened = id;
      s.askArchiveDuplicate = (_) async => DuplicateChoice.cancel;
      await s.offerArchiveDuplicates(reused);
      expect(s.library.objects, hasLength(1));
      expect(opened, isNull);
      s.askArchiveDuplicate = (_) async => DuplicateChoice.openExisting;
      await s.offerArchiveDuplicates(reused);
      expect(opened, reused.single.existing.id);
      expect(s.library.objects, hasLength(1));
      s.askArchiveDuplicate = (_) async => DuplicateChoice.saveAnyway;
      await s.offerArchiveDuplicates(reused);
      expect(s.library.objects, hasLength(2));
      await s.flush();
      s.dispose();
    });
  });

  testWidgets('the popup shows the existing item and returns the choice', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('theapp_duppop_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final ws = Workspace(dir);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
    await tester.runAsync(s.init);
    late LibraryObject saved;
    await tester.runAsync(() async {
      saved = await s.library.save(
        type: LibraryObjectType.website,
        sourceUrl: 'https://recipes.example/pie',
        title: 'Apple pie',
      );
      await s.library.setCategory(saved.id, 'resource', true);
    });
    final dup = s.library.findDuplicate(
      sourceUrl: 'https://recipes.example/pie?utm_source=feed',
    )!;
    DuplicateChoice? choice;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                choice = await showArchiveDuplicatePrompt(context, s, dup),
            child: const Text('save'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    expect(find.text('Already in Archive'), findsOneWidget);
    expect(find.text('Apple pie'), findsOneWidget);
    expect(find.textContaining('Resource'), findsOneWidget);
    expect(find.text('Open existing'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Save anyway'));
    await tester.pumpAndSettle();
    expect(choice, DuplicateChoice.saveAnyway);
    // Escape (or a tap outside) is Cancel.
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(choice, DuplicateChoice.cancel);
    await tester.runAsync(s.flush);
    s.dispose();
    await tester.pump(const Duration(seconds: 9));
  });
}
