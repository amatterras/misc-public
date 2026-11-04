// All-or-nothing changes across collections (lib/data/storage/transaction_log.dart):
// a normal transaction, a crash between the intent and the saves (the
// intent is replayed on the next start), steps that are already done, steps
// whose record was edited again afterwards (the later edit wins), and an
// intent from a newer version (kept untouched).
import 'dart:io';

import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/storage/transaction_log.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_txn_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Workspace> open() async {
    final ws = Workspace(dir);
    await ws.load();
    return ws;
  }

  Future<void> close(Workspace ws) async {
    await ws.flush();
    ws.dispose();
  }

  File intentFile(String id) => File(
    '${dir.path}${Platform.pathSeparator}${TransactionLog.folder}'
    '${Platform.pathSeparator}$id.json',
  );

  Directory intentDir() =>
      Directory('${dir.path}${Platform.pathSeparator}${TransactionLog.folder}');

  int intents() => intentDir().existsSync()
      ? intentDir().listSync().where((e) => e.path.endsWith('.json')).length
      : 0;

  test('a transaction changes both collections and leaves no intent', () async {
    var ws = await open();
    final note = ws.createNote(title: 'A', body: 'text');
    await ws.flush();
    ws.deleteNote(note.id);
    // Applied in memory at once.
    expect(ws.notes[note.id], isNull);
    expect(ws.noteVersions.all.where((v) => v.noteId == note.id), hasLength(1));
    await ws.txn.run('noop', (_) {}); // nothing to do: completes at once
    await close(ws);
    ws = await open();
    expect(ws.notes[note.id], isNull);
    expect(ws.deletedNotes().single.noteId, note.id);
    expect(intents(), 0, reason: 'finished transactions leave nothing behind');
    await close(ws);
  });

  test(
    'a crash after the intent is written is finished at the next start',
    () async {
      var ws = await open();
      final note = ws.createNote(title: 'Keep me', body: 'important');
      await ws.flush();
      final version = NoteVersion(
        id: 'v-crash',
        noteId: note.id,
        title: note.title,
        body: note.body,
        savedAt: DateTime.now().toUtc(),
        deleted: true,
      );
      // The intent as `deleteNote` writes it, then the "crash": the collections
      // are never saved.
      await ws.store.write(TransactionLog.folder, 'crash1', {
        'schema': 1,
        'label': 'Delete note',
        'ops': [
          TxOp.put(
            'note_versions',
            version.id,
            null,
            version.toJson(),
          ).toJson(),
          TxOp.remove('notes', note.id, ws.notes.jsonOf(note.id)).toJson(),
        ],
      });
      await close(ws);

      ws = await open();
      expect(ws.lastRecovery.intents, 1);
      expect(ws.lastRecovery.applied, 2);
      expect(ws.notes[note.id], isNull);
      expect(ws.noteVersions['v-crash'], isNotNull);
      expect(intents(), 0);
      await close(ws);

      // The result is on disk, not only in memory.
      ws = await open();
      expect(ws.notes[note.id], isNull);
      expect(ws.noteVersions['v-crash'], isNotNull);
      await close(ws);
    },
  );

  test('half-finished: only the missing step is applied', () async {
    var ws = await open();
    final note = ws.createNote(title: 'Half', body: 'x');
    final version = NoteVersion(
      id: 'v-half',
      noteId: note.id,
      title: 'Half',
      body: 'x',
      savedAt: DateTime.now().toUtc(),
      deleted: true,
    );
    final before = ws.notes.jsonOf(note.id);
    ws.noteVersions.put(version); // the first save made it to disk...
    await ws.flush();
    await ws.store.write(TransactionLog.folder, 'half1', {
      'schema': 1,
      'label': 'Delete note',
      'ops': [
        TxOp.put('note_versions', version.id, null, version.toJson()).toJson(),
        TxOp.remove('notes', note.id, before).toJson(),
      ],
    });
    await close(ws);
    ws = await open();
    expect(ws.lastRecovery.alreadyDone, 1);
    expect(ws.lastRecovery.applied, 1);
    expect(ws.notes[note.id], isNull);
    await close(ws);
  });

  test('a record edited again afterwards is never overwritten', () async {
    var ws = await open();
    final note = ws.createNote(title: 'Old title', body: 'x');
    final before = ws.notes.jsonOf(note.id);
    final after = note.copyWith(title: 'Transaction title').toJson();
    await ws.store.write(TransactionLog.folder, 'late1', {
      'schema': 1,
      'label': 'Rename',
      'ops': [TxOp.put('notes', note.id, before, after).toJson()],
    });
    // A later edit, saved before the crash.
    ws.notes.put(note.copyWith(title: 'Edited later'));
    await close(ws);
    ws = await open();
    expect(ws.lastRecovery.skipped, 1);
    expect(ws.notes[note.id]!.title, 'Edited later');
    expect(intents(), 0);
    await close(ws);
  });

  test('an intent from a newer version is kept untouched', () async {
    var ws = await open();
    await ws.store.write(TransactionLog.folder, 'future1', {
      'schema': 9,
      'label': 'From the future',
      'ops': [
        {
          'c': 'quantum_things',
          'id': 'q1',
          'op': 'put',
          'after': {'id': 'q1'},
        },
      ],
    });
    await close(ws);
    ws = await open();
    expect(ws.lastRecovery.kept, 1);
    expect(intentFile('future1').existsSync(), isTrue);
    await close(ws);
  });

  test('replaying twice changes nothing the second time', () async {
    var ws = await open();
    final note = ws.createNote(title: 'Twice', body: 'x');
    await ws.flush();
    final op = TxOp.remove('notes', note.id, ws.notes.jsonOf(note.id)).toJson();
    await ws.store.write(TransactionLog.folder, 'again1', {
      'schema': 1,
      'label': 'Remove',
      'ops': [op],
    });
    await close(ws);
    ws = await open();
    expect(ws.lastRecovery.applied, 1);
    await close(ws);
    ws = await open();
    expect(ws.lastRecovery.intents, 0);
    await close(ws);
  });
}
