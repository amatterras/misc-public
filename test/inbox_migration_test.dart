// The Home page and its Inbox were removed: waiting Inbox items are moved
// into the Archive by the `inbox-to-archive-v1` migration, and nothing is
// deleted.
import 'dart:io';

import 'package:flutter_application_1/data/migrations/migration_runner.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/repositories/library_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Workspace ws;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_inboxmig_');
    ws = Workspace(dir);
    await ws.load();
  });
  tearDown(() {
    ws.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final when = DateTime(2026, 10, 1);
  Asset asset(String id, AssetKind kind, {String? url, String? sha}) => Asset(
    id: id,
    kind: kind,
    createdAt: when,
    updatedAt: when,
    url: url,
    title: id,
    fileSha256: sha,
  );
  void inboxItem(String id, {String? text, String? assetId}) => ws.inbox.put(
    InboxItem(id: id, text: text, assetId: assetId, createdAt: when),
  );

  test('waiting Inbox items become Archive objects; the Inbox is kept', () async {
    ws.assets.put(asset('l', AssetKind.link, url: 'https://a.example/x'));
    ws.assets.put(asset('p', AssetKind.image, sha: 'abc'));
    ws.assets.put(asset('d', AssetKind.document, sha: 'def'));
    ws.assets.put(asset('bad', AssetKind.link, url: 'file:///c:/secret.txt'));
    inboxItem('i1', assetId: 'l');
    inboxItem('i2', text: 'remember this');
    inboxItem('i3', assetId: 'p');
    inboxItem('i4', assetId: 'd');
    inboxItem('i5', assetId: 'bad');
    inboxItem('i6', text: '   ');
    await ws.flush();

    final outcome = await MigrationRunner(
      workspace: ws,
      canvases: FileCanvasRepository(ws.store),
    ).run(hasData: true);
    expect(outcome.status, MigrationStatus.applied);
    expect(outcome.applied, contains('inbox-to-archive-v1'));

    final library = LibraryRepository(ws);
    final objects = library.objects;
    expect(objects, hasLength(4));
    expect(
      objects.where((o) => o.type == LibraryObjectType.website).single.sourceUrl,
      'https://a.example/x',
    );
    expect(
      objects.where((o) => o.type == LibraryObjectType.note).single.content,
      'remember this',
    );
    expect(
      objects.where((o) => o.type == LibraryObjectType.image).single.attachmentIds,
      ['p'],
    );
    expect(
      objects.where((o) => o.type == LibraryObjectType.document).single.attachmentIds,
      ['d'],
    );
    expect({for (final o in objects) o.metadata['fromInbox']}, {
      'i1',
      'i2',
      'i3',
      'i4',
    });
    // Nothing is removed from the Inbox, including what could not move.
    expect(ws.inbox.all.map((i) => i.id).toSet(), {
      'i1',
      'i2',
      'i3',
      'i4',
      'i5',
      'i6',
    });
    library.dispose();
  });

  test('running it again, or with the link already saved, adds nothing', () async {
    ws.assets.put(asset('l', AssetKind.link, url: 'https://a.example/x'));
    inboxItem('i1', assetId: 'l');
    inboxItem('i2', text: 'remember this');
    final library = LibraryRepository(ws);
    await library.save(
      type: LibraryObjectType.website,
      sourceUrl: 'https://a.example/x',
      title: 'Saved earlier',
    );
    final ctx = MigrationContext(ws, FileCanvasRepository(ws.store));

    await inboxToArchiveV1.apply(ctx);
    final first = library.objects.length;
    expect(first, 2, reason: 'the note is new; the link was already there');
    expect(await inboxToArchiveV1.verify!(ctx), isEmpty);

    await inboxToArchiveV1.apply(ctx);
    expect(library.objects.length, first);
    expect(await inboxToArchiveV1.verify!(ctx), isEmpty);
    library.dispose();
  });
}
