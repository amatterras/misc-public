// Sorting what was captured (features/capture/sorting.dart): clear states,
// filing, converting to a note or a task without losing the original or
// making duplicates, archiving, and undo for every action.
import 'dart:io';

import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_application_1/data/repositories/library_repository.dart';
import 'package:flutter_application_1/data/storage/transaction_log.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/sorting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late Workspace ws;
  late LibraryRepository repo;
  late CaptureSorter sorter;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_sort_');
    ws = Workspace(dir);
    await ws.load();
    repo = LibraryRepository(ws);
    sorter = CaptureSorter(ws, repo);
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<LibraryObject> capture(
    String title, {
    String body = 'something to read',
    String? url,
  }) async {
    return repo.save(
      type: url == null ? LibraryObjectType.note : LibraryObjectType.website,
      title: title,
      content: body,
      sourceUrl: url,
    );
  }

  test('a new capture is unfiled', () async {
    final o = await capture('Idea');
    expect(sorter.stateOf(o.id), CaptureState.unfiled);
    expect(sorter.counts()[CaptureState.unfiled], 1);
    expect(sorter.items(CaptureState.unfiled).single.id, o.id);
  });

  test('filing moves it out of unfiled, and undo puts it back', () async {
    final o = await capture('Idea');
    final folder = await repo.createSpace('Read later');
    final r = (await sorter.file(o.id, folder.id))!;
    expect(sorter.stateOf(o.id), CaptureState.filed);
    expect(r.already, isFalse);
    await r.undo.undo();
    expect(sorter.stateOf(o.id), CaptureState.unfiled);
  });

  test('filing twice does not change anything the second time', () async {
    final o = await capture('Idea');
    final folder = await repo.createSpace('Read later');
    await sorter.file(o.id, folder.id);
    final again = (await sorter.file(o.id, folder.id))!;
    expect(again.already, isTrue);
    await again.undo.undo(); // undoing a no-op must not unfile it
    expect(sorter.stateOf(o.id), CaptureState.filed);
  });

  test(
    'a note made from it keeps the text and the source; the original stays',
    () async {
      final o = await capture(
        'Great article',
        body: 'Key point: write things down.',
        url: 'https://example.com/a',
      );
      final r = (await sorter.convertToNote(o.id))!;
      final note = ws.notes[r.id!]!;
      expect(note.title, 'Great article');
      expect(note.body, contains('Key point: write things down.'));
      expect(note.body, contains('Source: https://example.com/a'));
      expect(sorter.stateOf(o.id), CaptureState.converted);
      expect(
        ws.libraryObjects[o.id],
        isNotNull,
        reason: 'the original is kept',
      );
      expect(ws.libraryObjects[o.id]!.content, 'Key point: write things down.');
    },
  );

  test('converting twice gives the same note, not a duplicate', () async {
    final o = await capture('Once');
    final first = (await sorter.convertToNote(o.id))!;
    final second = (await sorter.convertToNote(o.id))!;
    expect(second.id, first.id);
    expect(second.already, isTrue);
    expect(ws.notes.length, 1);
  });

  test(
    'undoing a conversion removes the note and the link, nothing else',
    () async {
      final o = await capture('Undo me');
      final keep = ws.createNote(title: 'Unrelated', body: 'x');
      final r = (await sorter.convertToNote(o.id))!;
      expect(ws.notes.length, 2);
      await r.undo.undo();
      expect(ws.notes.length, 1);
      expect(ws.notes[keep.id], isNotNull);
      expect(sorter.stateOf(o.id), CaptureState.unfiled);
      expect(ws.libraryObjects[o.id], isNotNull);
    },
  );

  test('a task made from it carries its title and notes', () async {
    final o = await capture('Book dentist', body: 'ask about Tuesday');
    final r = (await sorter.convertToTask(o.id))!;
    final task = ws.tasks[r.id!]!;
    expect(task.title, 'Book dentist');
    expect(task.notes, contains('ask about Tuesday'));
    expect(sorter.stateOf(o.id), CaptureState.converted);
    await r.undo.undo();
    expect(ws.tasks[r.id!], isNull);
  });

  test(
    'if the made note is deleted later the item is not stuck as converted',
    () async {
      final o = await capture('Later deleted');
      final r = (await sorter.convertToNote(o.id))!;
      ws.deleteNote(r.id!);
      expect(sorter.stateOf(o.id), CaptureState.unfiled);
      final again = (await sorter.convertToNote(o.id))!;
      expect(again.id, isNot(r.id), reason: 'a new note is made');
      expect(again.already, isFalse);
    },
  );

  test('archiving puts it away and can be restored or undone', () async {
    final o = await capture('Old');
    final folder = await repo.createSpace('Stuff');
    await sorter.file(o.id, folder.id);
    final a = (await sorter.archive(o.id))!;
    expect(sorter.stateOf(o.id), CaptureState.archived);
    await a.undo.undo();
    expect(sorter.stateOf(o.id), CaptureState.filed);
    await sorter.archive(o.id);
    await sorter.restore(o.id);
    expect(
      sorter.stateOf(o.id),
      CaptureState.filed,
      reason: 'its folder is untouched',
    );
  });

  test('a deleted or unknown item cannot be sorted', () async {
    expect(await sorter.convertToNote('nope'), isNull);
    expect(await sorter.archive('nope'), isNull);
    final o = await capture('Gone');
    await repo.delete(o.id);
    expect(await sorter.convertToTask(o.id), isNull);
  });

  test('a conversion leaves no half-finished change behind', () async {
    final o = await capture('Clean');
    await (await sorter.convertToNote(o.id))!.persisted;
    final txn = Directory(
      '${dir.path}${Platform.pathSeparator}${TransactionLog.folder}',
    );
    final left = txn.existsSync()
        ? txn.listSync().where((e) => e.path.endsWith('.json')).length
        : 0;
    expect(left, 0);
  });
}
