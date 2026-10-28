// Deleting for good: the record leaves active storage, "recently deleted",
// the app's backups, the hub's journal and backups and the links that shared
// it; the other devices are told; and an old copy (another device, a backup
// restore) cannot bring it back. Ordinary deletion stays undoable, and the
// backup retention is not disturbed. Real hub on 127.0.0.1.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_application_1/data/models/knowledge_models.dart';
import 'package:flutter_application_1/data/models/sync_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/e2ee.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_keys.dart';

final sep = Platform.pathSeparator;

const canary = 'CANARY-PURGE-TITLE-3c9a';
const canaryBody = 'CANARY-PURGE-BODY-81f2 private';

class Dev {
  Dev(this.ws, this.canvases, this.engine);
  final Workspace ws;
  final FileCanvasRepository canvases;
  final SyncEngine engine;
  Future<SyncReport> sync() => engine.syncOnce();
}

Future<List<String>> filesWith(Directory dir, String needle) async {
  final out = <String>[];
  if (!await dir.exists()) return out;
  await for (final e in dir.list(recursive: true)) {
    if (e is File && latin1.decode(await readSafe(e)).contains(needle)) {
      out.add(e.path.substring(dir.path.length));
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late HubServer hub;
  late Uri url;

  Future<Dev> device(String name, {Directory? dir}) async {
    final ws = Workspace(dir ?? Directory('${root.path}$sep$name'));
    await ws.load();
    final token = await _token(hub, ws.device!.id, name);
    final canvases = FileCanvasRepository(ws.store);
    return Dev(
      ws,
      canvases,
      SyncEngine(
        workspace: ws,
        canvases: canvases,
        client: SyncClient(url, token: token, crypto: testSyncCrypto),
      ),
    );
  }

  /// How many journal lines (versions) a journal file holds for a record.
  int versionsIn(File journal, String collection, String id) {
    var n = 0;
    for (final line in journal.readAsLinesSync()) {
      if (line.contains('"c":"$collection","id":"$id"')) n++;
    }
    return n;
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_purge_');
    hub = await HubServer.start(
      dir: Directory('${root.path}${sep}hub'),
      port: 0,
      dailyBackups: false,
    );
    url = Uri.parse('http://127.0.0.1:${hub.port}');
  });

  tearDown(() async {
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a record deleted for good is removed from every copy THEapp manages '
      'and cannot come back', () async {
    final a = await device('a');
    final b = await device('b');
    final note = a.ws.createNote(title: canary, body: canaryBody);
    const token = 'purge-share-token-AAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final shareId = sha256.convert(utf8.encode(token)).toString();
    final seal = ShareSeal.seal(canary, canaryBody);
    a.ws.shares.put(
      ShareLink(
        id: shareId,
        kind: 'note',
        sourceId: note.id,
        title: canary,
        body: canaryBody,
        createdAt: DateTime(2026),
        updatedAt: DateTime.now(),
        sealed: seal.ciphertext,
      ),
    );
    final other = a.ws.createNote(title: 'keep me', body: 'other');
    await a.sync();
    await b.sync();
    expect(b.ws.notes[note.id], isNotNull);

    // Copies: the app's backups (two kinds), a saved copy, a hub backup, and a
    // copy the user made themselves outside any managed folder.
    final copies = Directory('${root.path}${sep}copies')..createSync();
    a.ws.backups.copiesDir = copies;
    final backup = await a.ws.backups.snapshot(
      'manual',
      includeAttachments: true,
    );
    await a.ws.backups.copyTo(backup, copies);
    await a.ws.backups.snapshot('auto');
    await a.ws.flush();
    final mine = Directory('${root.path}${sep}my-own-copy');
    await a.ws.backups.restoreTo(backup, mine);
    await hub.backups.create();
    await hub.backups.createLive();
    final backupsBefore = (await a.ws.backups.list()).length;
    final hubBackupsBefore = (await hub.backups.list()).length;
    expect(await filesWith(a.ws.backups.backupsDir, canary), isNotEmpty);
    expect(await filesWith(copies, canary), isNotEmpty);

    // Delete it ordinarily first: recoverable, as always.
    a.ws.notes.remove(note.id);
    expect(a.ws.notes.recentlyDeleted, contains(note.id));
    expect(a.ws.notes.restoreDeleted(note.id), isNotNull);

    // Now for good.
    await a.ws.purgeRecord('notes', note.id);
    await a.sync();
    await b.sync();
    await a.sync();

    // This device: gone from active storage, recently deleted and the link.
    expect(a.ws.notes[note.id], isNull);
    expect(a.ws.notes.recentlyDeleted, isNot(contains(note.id)));
    expect(a.ws.notes[other.id], isNotNull, reason: 'nothing else is touched');
    final link = a.ws.shares[shareId]!;
    expect(link.revoked, isTrue);
    expect(link.title, isEmpty);
    expect(link.body, isEmpty);
    expect(link.sealed, isNull);
    await a.ws.flush();
    expect(
      await filesWith(Directory('${a.ws.root.path}${sep}data'), canary),
      isEmpty,
      reason: 'not in active storage',
    );

    // The app's backups and saved copies: no trace, still valid, same count.
    expect(await filesWith(a.ws.backups.backupsDir, canary), isEmpty);
    expect(await filesWith(copies, canary), isEmpty);
    expect(await filesWith(a.ws.backups.backupsDir, canaryBody), isEmpty);
    expect((await a.ws.backups.list()).length, backupsBefore);
    for (final d in await a.ws.backups.list()) {
      final manifest = await a.ws.backups.readManifest(d);
      if (manifest != null) {
        expect(await a.ws.backups.checkManifest(d), isEmpty, reason: d.path);
      }
    }
    // (The user's own copy is theirs: THEapp does not reach into it.)
    expect(await filesWith(mine, canary), isNotEmpty);

    // The hub: only the tombstone is left, in the journal and in every backup.
    final tombstone = await hub.store.current('notes', note.id);
    expect(tombstone!.deleted, isTrue);
    expect(versionsIn(hub.store.journal, 'notes', note.id), 1);
    final hubBackups = [
      ...await hub.backups.list(),
      ...await hub.backups.listLive(),
    ];
    expect(hubBackups, isNotEmpty);
    for (final h in hubBackups) {
      expect(
        versionsIn(File('${h.path}${sep}journal.jsonl'), 'notes', note.id),
        lessThanOrEqualTo(1),
        reason: h.path,
      );
    }
    expect((await hub.backups.list()).length, hubBackupsBefore);
    final http = HttpClient();
    final page = await (await http.getUrl(url.replace(path: '/s/$token')))
        .close();
    expect(page.statusCode, 404, reason: 'the link stopped');
    http.close();

    // The other device was told.
    expect(b.ws.notes[note.id], isNull);
    expect(b.ws.purges.all.map((m) => m.recordId), contains(note.id));

    // A device with an old copy cannot bring it back.
    final cDir = Directory('${root.path}${sep}c');
    await a.ws.backups.restoreTo(mine, cDir); // a copy from before
    File('${cDir.path}${sep}sync${sep}device.json').deleteSync();
    final c = await device('c', dir: cDir);
    expect(c.ws.notes[note.id], isNotNull, reason: 'it has the old copy');
    await c.sync();
    await c.sync();
    expect(c.ws.notes[note.id], isNull);
    expect(versionsIn(hub.store.journal, 'notes', note.id), 1);
    expect((await hub.store.current('notes', note.id))!.deleted, isTrue);

    // Restoring the user's own old copy on this device does not bring it back
    // either, once it syncs.
    a.ws.dispose();
    a.ws.store.readOnly = true;
    await Workspace(a.ws.root).backups.restore(mine);
    final again = await device('a-again', dir: a.ws.root);
    expect(again.ws.notes[note.id], isNotNull, reason: 'restored locally');
    await again.sync();
    await again.sync();
    expect(again.ws.notes[note.id], isNull);
    expect(again.ws.notes.recentlyDeleted, isNot(contains(note.id)));
    expect(versionsIn(hub.store.journal, 'notes', note.id), 1);
  });

  test('an ordinary deletion stays undoable and is not a purge', () async {
    final a = await device('a');
    final note = a.ws.createNote(title: 'delete me', body: 'x');
    await a.sync();
    a.ws.notes.remove(note.id);
    await a.sync();
    expect(a.ws.purges.all, isEmpty);
    expect(a.ws.notes.restoreDeleted(note.id), isNotNull);
    await a.sync();
    expect((await hub.store.current('notes', note.id))!.deleted, isFalse);
  });

  test('the hub refuses to take a purged record back, from any device and '
      'whatever its revision', () async {
    final a = await device('a');
    final note = a.ws.createNote(title: 'x', body: 'y');
    await a.sync();
    await a.ws.purgeRecord('notes', note.id);
    await a.sync();
    final raw = SyncClient(
      url,
      token: await _token(hub, 'raw', 'raw'),
      crypto: testSyncCrypto,
    );
    addTearDown(raw.close);
    final result = await raw.push([
      SyncChange(
        collection: 'notes',
        id: note.id,
        rev: '0009999999999999-0000-raw',
        deleted: false,
        data: {'id': note.id, 'title': 'back again'},
      ),
    ]);
    expect(result.results.single.status, PushStatus.keptServer);
    expect((await hub.store.current('notes', note.id))!.deleted, isTrue);
    // A purge mark cannot be undone either.
    final undo = await raw.push([
      SyncChange(
        collection: 'purges',
        id: 'notes.${note.id}',
        rev: '0009999999999999-0001-raw',
        deleted: true,
      ),
    ]);
    expect(undo.results.single.status, PushStatus.keptServer);
  });

  test('sealed attachment copies of a purged record are removed from the hub, '
      'unless another record still uses them', () async {
    final a = await device('a');
    final b = await device('b');
    final pdf = File('${a.ws.root.path}${sep}doc.pdf')
      ..writeAsBytesSync(utf8.encode('%PDF-1.4 $canaryBody'));
    final one = await a.ws.documentAssetFromFile(pdf);
    final pdf2 = File('${a.ws.root.path}${sep}other.pdf')
      ..writeAsBytesSync(utf8.encode('%PDF-1.4 something else entirely'));
    final two = await a.ws.documentAssetFromFile(pdf2);
    await a.sync();
    await b.sync();
    final blobsBefore = await hub.store.attachmentHashes();
    expect(blobsBefore, hasLength(2));
    final file = one.file!;
    expect(a.ws.attachments.fileFor(file).existsSync(), isTrue);

    await a.ws.purgeRecord('assets', one.id);
    await a.sync();
    await b.sync();
    expect(a.ws.attachments.fileFor(file).existsSync(), isFalse);
    expect(a.ws.attachments.fileFor(two.file!).existsSync(), isTrue);
    expect(await hub.store.attachmentHashes(), hasLength(1));
    expect(b.ws.assets[one.id], isNull);
    expect(b.ws.assets[two.id], isNotNull);
  });

  test('purge marks sync and the record id is all the hub learns', () async {
    final a = await device('a');
    final note = a.ws.createNote(title: canary, body: canaryBody);
    await a.sync();
    await a.ws.purgeRecord('notes', note.id);
    await a.sync();
    final mark = await hub.store.current('purges', 'notes.${note.id}');
    expect(mark, isNotNull);
    expect(isEnvelope(mark!.data), isTrue, reason: 'sealed like any record');
    final all = await Future.wait([
      for (final f in hub.store.dir.listSync(recursive: true).whereType<File>())
        readSafe(f),
    ]);
    for (final bytes in all) {
      expect(latin1.decode(bytes), isNot(contains('CANARY')));
    }
    expect(
      PurgeMark.fromJson(a.ws.purges.all.single.toJson()).recordId,
      note.id,
    );
  });
}

Future<String> _token(HubServer hub, String id, String name) async {
  // A device paired with an end-to-end code (so it may write).
  final secret = PairingSecret.generate();
  hub.auth.createPairingOffer(
    registerCode: secret.registerCode,
    wrappedKey: 'unused',
  );
  return (await hub.auth.registerWithKey(secret.registerCode, id, name)).token;
}
