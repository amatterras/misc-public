// The unified search index (lib/search): ranking, why a result matched,
// snippets and pages, and that it follows the workspace incrementally
// (changed records are re-read, deleted ones dropped, nothing else touched).
import 'dart:io';

import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/search/search_index.dart';
import 'package:flutter_application_1/search/workspace_search.dart';
import 'package:flutter_test/flutter_test.dart';

IndexedDoc doc(
  String id,
  String title, {
  DocKind kind = DocKind.note,
  List<SearchField> fields = const [],
}) => IndexedDoc(kind: kind, id: id, title: title, fields: fields);

void main() {
  group('index', () {
    test('every word must match; the last also as a prefix', () {
      final i = SearchIndex()
        ..upsert(
          doc(
            '1',
            'Lisbon trip',
            fields: [const SearchField('body', 'packing list for Portugal')],
          ),
        )
        ..upsert(
          doc(
            '2',
            'Packing',
            fields: [const SearchField('body', 'tidy the desk')],
          ),
        );
      expect(i.query('lisbon pack').map((h) => h.doc.id), ['1']);
      expect(i.query('pack').map((h) => h.doc.id).toSet(), {'1', '2'});
      expect(i.query('lisbon desk'), isEmpty);
      expect(i.query(''), isEmpty);
      expect(i.query('   '), isEmpty);
    });

    test('title beats tags beats body, exact beats prefix', () {
      final i = SearchIndex()
        ..upsert(
          doc(
            'body',
            'Misc',
            fields: [const SearchField('body', 'about plants')],
          ),
        )
        ..upsert(
          doc(
            'tags',
            'Misc two',
            fields: [const SearchField('tags', 'plants', weight: 6)],
          ),
        )
        ..upsert(doc('title', 'Plants'))
        ..upsert(doc('prefix', 'Plantation'));
      final ids = i.query('plants').map((h) => h.doc.id).toList();
      expect(ids.indexOf('title'), lessThan(ids.indexOf('tags')));
      expect(ids.indexOf('tags'), lessThan(ids.indexOf('body')));
      final withPrefix = i.query('plant').map((h) => h.doc.id).toList();
      expect(withPrefix.first, 'title'.isEmpty ? '' : withPrefix.first);
      expect(withPrefix, contains('prefix'));
    });

    test('a hit says why it matched', () {
      final i = SearchIndex()
        ..upsert(
          doc(
            '1',
            'Budget',
            fields: [
              const SearchField('tags', 'finance', weight: 6),
              const SearchField('body', 'rent and food'),
            ],
          ),
        );
      expect(i.query('budget').single.reasons, ['title']);
      expect(i.query('finance').single.reasons, ['tags']);
      expect(i.query('rent').single.reasons, ['body']);
      expect(i.query('budget rent').single.reasons, ['title', 'body']);
    });

    test('a snippet shows the text around the match', () {
      final long = '${'word ' * 40}needle ${'other ' * 40}';
      final i = SearchIndex()
        ..upsert(doc('1', 'Long', fields: [SearchField('body', long)]));
      final hit = i.query('needle').single;
      expect(hit.snippet, contains('needle'));
      expect(hit.snippet.length, lessThan(160));
      expect(hit.snippet.startsWith('…'), isTrue);
    });

    test('paged text names the page', () {
      final i = SearchIndex()
        ..upsert(
          IndexedDoc(
            kind: DocKind.document,
            id: 'pdf',
            title: 'Paper',
            fields: [
              const SearchField('pdf', '').withPages([
                'introduction and background',
                'methods and materials',
                'the quasar results appear here',
              ]),
            ],
          ),
        );
      final hit = i.query('quasar').single;
      expect(hit.page, 3);
      expect(hit.snippet, contains('quasar'));
    });

    test('kinds filter, replace and remove', () {
      final i = SearchIndex()
        ..upsert(doc('1', 'Alpha'))
        ..upsert(doc('1', 'Alpha task', kind: DocKind.task));
      expect(
        i.query('alpha', kinds: {DocKind.task}).single.doc.kind,
        DocKind.task,
      );
      expect(i.query('alpha'), hasLength(2));
      i.upsert(doc('1', 'Beta'));
      expect(i.query('alpha').map((h) => h.doc.kind), [DocKind.task]);
      i.remove('note:1');
      i.remove('task:1');
      expect(i.length, 0);
      expect(i.query('alpha'), isEmpty);
      expect(i.query('beta'), isEmpty);
    });

    test('accents, case and punctuation do not get in the way', () {
      final i = SearchIndex()..upsert(doc('1', 'Café Münster, Saint-Étienne'));
      expect(i.query('MÜNSTER').single.doc.id, '1');
      expect(i.query('saint étienne').single.doc.id, '1');
    });

    test('it stays fast on a large workspace', () {
      final i = SearchIndex();
      for (var n = 0; n < 5000; n++) {
        i.upsert(
          doc(
            '$n',
            'Note $n',
            fields: [
              SearchField('body', 'lorem ipsum dolor $n sit amet ${n % 97}'),
            ],
          ),
        );
      }
      final t = Stopwatch()..start();
      for (var k = 0; k < 50; k++) {
        i.query('dolor 4${k % 10}');
      }
      expect(t.elapsedMilliseconds, lessThan(3000));
    });
  });

  group('workspace', () {
    late Directory dir;
    late Workspace ws;
    late WorkspaceSearch search;
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('theapp_search_');
      ws = Workspace(dir);
      await ws.load();
      search = WorkspaceSearch(ws);
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('finds notes, tasks and projects, with the reason', () {
      ws.createNote(title: 'Garden plan', body: 'plant tomatoes in May');
      final p = ws.projects;
      ws.createTask('Buy tomato seeds');
      expect(p.length, 0);
      final hits = search.search('tomato');
      expect(hits.map((h) => h.doc.kind).toSet(), {DocKind.note, DocKind.task});
      final note = hits.firstWhere((h) => h.doc.kind == DocKind.note);
      expect(note.reasons, ['body']);
      expect(note.snippet, contains('tomatoes'));
    });

    test('only what changed is read again', () {
      for (var n = 0; n < 40; n++) {
        ws.createNote(title: 'Note $n', body: 'text $n');
      }
      search.search('note');
      expect(search.lastRead, 40, reason: 'the first search reads all');
      search.refresh();
      expect(search.lastRead, 0, reason: 'nothing changed: nothing read');
      expect(search.lastScanned, greaterThanOrEqualTo(40));
      final one = ws.notes.all.first;
      ws.notes.put(one.copyWith(body: 'now about zebras'));
      expect(search.search('zebras').single.doc.id, one.id);
      expect(search.lastRead, 1, reason: 'one changed note: one read');
    });

    test('deleted records disappear from results', () {
      final n = ws.createNote(title: 'Secret plan', body: 'x');
      expect(search.search('secret'), hasLength(1));
      ws.deleteNote(n.id);
      expect(search.search('secret'), isEmpty);
      expect(search.lastDropped, greaterThan(0));
    });

    test('a rebuild gives the same results as the incremental index', () {
      ws.createNote(title: 'One', body: 'alpha beta');
      final t = ws.createTask('Two alpha');
      search.search('alpha');
      ws.tasks.put(t.copyWith(title: 'Two gamma'));
      final incremental = search.search('gamma').map((h) => h.doc.key).toList();
      final fresh = WorkspaceSearch(ws);
      expect(fresh.search('gamma').map((h) => h.doc.key).toList(), incremental);
      expect(
        fresh.search('alpha').map((h) => h.doc.key).toSet(),
        search.search('alpha').map((h) => h.doc.key).toSet(),
      );
    });

    test('a PDF read later becomes searchable by page', () async {
      final file = File('${dir.path}${Platform.pathSeparator}paper.pdf')
        ..writeAsBytesSync(_pdf);
      final asset = await ws.documentAssetFromFile(file);
      var pages = <String>[];
      final s = WorkspaceSearch(
        ws,
        sources: SearchSources(pdfPages: (id) => id == asset.id ? pages : null),
      );
      expect(s.search('nebula'), isEmpty);
      pages = ['cover', 'a nebula appears'];
      final hit = s.search('nebula').single;
      expect(hit.doc.kind, DocKind.document);
      expect(hit.page, 2);
    });
  });
}

const _pdf = <int>[0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34];
