// Relationships by stable id (features/relations/relations.dart): both
// directions, no duplicates, surviving a rename, deleted targets that do not
// corrupt anything, the older implicit links, and PDF page references.
import 'dart:io';

import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/relations/relations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late Workspace ws;
  late RelationService rel;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_rel_');
    ws = Workspace(dir);
    await ws.load();
    rel = RelationService(ws);
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Ref note(String id) => Ref(RefKind.note, id);

  test('a relation is seen from both ends', () {
    final a = ws.createNote(title: 'A', body: '');
    final t = ws.createTask('Do it');
    rel.link(note(a.id), Ref(RefKind.task, t.id), rel: 'related');
    final fromNote = rel.relatedTo(note(a.id)).single;
    expect(fromNote.outgoing, isTrue);
    expect(fromNote.title, 'Do it');
    final fromTask = rel.relatedTo(Ref(RefKind.task, t.id)).single;
    expect(fromTask.outgoing, isFalse, reason: 'a backlink');
    expect(fromTask.title, 'A');
    expect(fromTask.explicit, isTrue);
  });

  test('adding the same relation twice makes one', () {
    final a = ws.createNote(title: 'A', body: '');
    final b = ws.createNote(title: 'B', body: '');
    final first = rel.link(note(a.id), note(b.id));
    final second = rel.link(note(a.id), note(b.id));
    expect(second, first);
    expect(rel.relatedTo(note(a.id)), hasLength(1));
    expect(ws.libraryRelations.all.where((r) => r.kind == 'ref'), hasLength(1));
  });

  test('a note cannot be related to itself', () {
    final a = ws.createNote(title: 'A', body: '');
    rel.link(note(a.id), note(a.id));
    expect(rel.relatedTo(note(a.id)), isEmpty);
  });

  test(
    'renaming keeps an explicit relation; a title mention breaks until pinned',
    () {
      final a = ws.createNote(title: 'Alpha', body: 'see [[Beta]] for more');
      final b = ws.createNote(title: 'Beta', body: '');
      // The mention is found by title...
      expect(rel.relatedTo(note(a.id)).map((r) => r.title), ['Beta']);
      expect(rel.pinMentions(a), 1);
      expect(rel.pinMentions(a), 0, reason: 'pinning twice adds nothing');
      // ...then Beta is renamed: the plain title link no longer finds it, but
      // the pinned relation (by id) does, under the new name.
      ws.notes.put(b.copyWith(title: 'Beta renamed'));
      final titles = rel.relatedTo(note(a.id)).map((r) => r.title).toList();
      expect(titles, ['Beta renamed']);
      expect(rel.relatedTo(note(b.id)).single.title, 'Alpha');
    },
  );

  test('older links are shown too: task to note, task to project, files', () {
    final p = ws.projects;
    expect(p.length, 0);
    final n = ws.createNote(title: 'N', body: '');
    final t = ws.createTask('T');
    ws.tasks.put(t.copyWith(noteIds: [n.id]));
    final fromNote = rel.relatedTo(note(n.id));
    expect(fromNote.single.rel, 'task');
    expect(fromNote.single.outgoing, isFalse);
    final fromTask = rel.relatedTo(Ref(RefKind.task, t.id));
    expect(fromTask.single.other, note(n.id));
  });

  test('an explicit and an older link to the same thing show once', () {
    final n = ws.createNote(title: 'N', body: '');
    final t = ws.createTask('T');
    ws.tasks.put(t.copyWith(noteIds: [n.id]));
    rel.link(Ref(RefKind.task, t.id), note(n.id), rel: 'note');
    expect(rel.relatedTo(Ref(RefKind.task, t.id)), hasLength(1));
    expect(rel.relatedTo(Ref(RefKind.task, t.id)).single.explicit, isTrue);
  });

  test('a deleted target is shown as unavailable, and comes back with it', () {
    final a = ws.createNote(title: 'A', body: '');
    final b = ws.createNote(title: 'B', body: '');
    rel.link(note(a.id), note(b.id));
    ws.deleteNote(b.id);
    final gone = rel.relatedTo(note(a.id)).single;
    expect(gone.exists, isFalse);
    expect(gone.title, '(deleted note)');
    // Nothing else was damaged.
    expect(ws.notes[a.id], isNotNull);
    expect(ws.libraryRelations.length, 1);
    ws.notes.restoreDeleted(b.id);
    final back = rel.relatedTo(note(a.id)).single;
    expect(back.exists, isTrue);
    expect(back.title, 'B');
  });

  test('unlinking removes it and can be taken back', () {
    final a = ws.createNote(title: 'A', body: '');
    final b = ws.createNote(title: 'B', body: '');
    final id = rel.link(note(a.id), note(b.id));
    expect(rel.unlink(id), isTrue);
    expect(rel.relatedTo(note(a.id)), isEmpty);
    expect(rel.relink(id), isTrue);
    expect(rel.relatedTo(note(a.id)), hasLength(1));
    expect(rel.unlink('nope'), isFalse);
  });

  test('a PDF page reference is found by the PDF and by the note', () {
    final n = ws.createNote(title: 'Reading notes', body: '');
    final pdf = Ref(RefKind.asset, 'pdf1');
    rel.link(note(n.id), pdf, rel: 'cites', page: 12);
    rel.link(note(n.id), pdf, rel: 'cites', page: 3);
    rel.link(note(n.id), pdf, rel: 'cites', page: 12); // same again
    final pages = rel.pageReferences('pdf1');
    expect([for (final p in pages) p.page], [3, 12]);
    expect(pages.first.from, note(n.id));
    final fromNote = rel.relatedTo(note(n.id)).map((r) => r.page).toSet();
    expect(fromNote, {3, 12});
    final fromPdf = rel.relatedTo(pdf);
    expect(fromPdf, hasLength(2));
    expect(fromPdf.every((r) => !r.outgoing), isTrue);
  });

  test('relations sync like any other record', () {
    expect(ws.syncCollections.containsKey('library_relations'), isTrue);
  });

  test('a relation with a broken id is ignored, not a crash', () {
    final a = ws.createNote(title: 'A', body: '');
    ws.libraryRelations.putJson({
      'id': 'ref.broken',
      'objectId': 'garbage',
      'kind': 'ref',
      'targetId': 'also garbage',
      'value': <String, dynamic>{},
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    expect(rel.relatedTo(note(a.id)), isEmpty);
  });
}
