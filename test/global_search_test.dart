// Global search ("Search everything"). Acceptance criteria:
//  1. One index finds typed text in every category: notes, note pages,
//     tasks, subtasks, projects, calendar entries (events, habits,
//     reading), text typed on the Calendar, mindmap text, Archive links
//     (title, url, description, tags, categories), bookmarks, AI chats.
//  2. Handwriting is never searched: strokes add nothing to the index and
//     the search layer has no recognition code.
//  3. Partial words, any case, accents, punctuation and spacing variations
//     all find the item.
//  4. New, edited and deleted content shows up / disappears at once.
//  5. Results are grouped by section, say where the match is, highlight
//     the words, and each opens the exact item (a mindmap result selects
//     the text box).
//  6. Empty query, no result, loading and error states are clear, and the
//     field can be cleared.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_ink.dart';
import 'package:flutter_application_1/features/search/search_dialog.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/search/search_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_gsearch_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a just-closed file; the temp folder is
      // harmless.
    }
  });

  Future<AppState> start() async {
    final ws = Workspace(dir);
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

  Set<String> kinds(AppState s, String q) =>
      searchEverything(s, q).map((r) => r.kind).toSet();

  group('every category', () {
    test('notes, tasks, subtasks, projects, entries, archive, chats', () async {
      final s = await start();
      final ws = s.workspace;
      ws.createNote(
        title: 'Zeppelin history',
        body: 'airship era notes',
      );
      final parent = ws.createTask('Plan voyage');
      ws.createTask('Pack zeppelin tickets', parentId: parent.id);
      ws.projects.put(
        Project(
          id: 'p',
          name: 'Zeppelin museum',
          kind: ProjectKind.project,
          updatedAt: DateTime(2026),
        ),
      );
      for (final (cat, name) in [
        (CalendarCategory.events, 'Zeppelin event'),
        (CalendarCategory.habits, 'Zeppelin habit'),
      ]) {
        ws.saveEntry(
          CalendarEntry(
            id: newId(),
            category: cat,
            name: name,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            startDate: DateTime.now(),
          ),
        );
      }
      ws.saveEntry(
        CalendarEntry(
          id: newId(),
          category: CalendarCategory.reading,
          name: 'Airship book',
          author: 'Zeppelin Author',
          highlights: 'a quote about hydrogen',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          startDate: DateTime.now(),
        ),
      );
      final link = s.capture.link('https://zeppelin.example/page');
      await s.addToLinks(link, tags: ['shopping']);

      final found = kinds(s, 'zeppelin');
      expect(found, containsAll(['Note', 'Task', 'Project', 'Link']));
      expect(
        searchEverything(s, 'zeppelin').map((r) => r.title),
        containsAll(['Pack zeppelin tickets', 'Zeppelin museum']),
      );
      // Reading entries: author, highlights.
      expect(searchEverything(s, 'hydrogen'), isNotEmpty);
      // The subtask says whose it is, and is found by its parent's title.
      final sub = searchEverything(s, 'voyage')
          .where((r) => r.title == 'Pack zeppelin tickets')
          .single;
      expect(sub.location, 'Subtask of Plan voyage');
      // Archive categories are searchable by their name.
      expect(searchEverything(s, 'shopping').map((r) => r.kind), contains('Link'));
      await s.flush();
      s.dispose();
    });

    test('mindmap text, note-page text and calendar text', () async {
      final s = await start();
      final note = s.workspace.createNote(title: 'Biology', body: '');
      await s.saveDocument(
        CanvasDocument(
          id: notebookIdFor(note.id),
          title: 'Biology',
          kind: 'notebook',
          items: [
            const TextItem(
              id: 'n',
              position: Offset.zero,
              width: 200,
              minHeight: 0,
              text: 'mitochondria powerhouse',
            ),
          ],
          updatedAt: DateTime.now(),
        ),
      );
      await s.canvases.save(
        CanvasDocument(
          id: 'mm',
          title: 'Strategy map',
          items: [
            const TextItem(
              id: 'a',
              position: Offset(10, 10),
              width: 200,
              minHeight: 0,
              text: 'first idea',
            ),
            const TextItem(
              id: 'b',
              position: Offset(900, 600),
              width: 200,
              minHeight: 0,
              text: 'launch narwhal initiative',
            ),
          ],
          updatedAt: DateTime.now(),
        ),
      );
      await s.createCanvas(title: 'Other', show: false);
      final day = DateTime(2026, 11, 3);
      await s.saveDocument(
        CanvasDocument(
          id: calendarInkId,
          title: 'Calendar drawings',
          kind: 'calendarInk',
          items: [
            TextItem(
              id: 'c',
              position: inkDayRect(day).topLeft + const Offset(20, 20),
              width: 120,
              minHeight: 0,
              text: 'dentist okapi appointment',
            ),
          ],
          updatedAt: DateTime.now(),
        ),
      );
      expect(kinds(s, 'powerhouse'), {'Note page'});
      final map = searchEverything(s, 'narwhal');
      expect(map.single.kind, 'Mindmap');
      expect(map.single.title, 'Strategy map');
      final cal = searchEverything(s, 'okapi').single;
      expect(cal.kind, 'Calendar note');
      expect(cal.location, contains('Calendar'));
      cal.open();
      expect(s.page, AppPage.calendar);
      expect(dayKey(s.focusDay!), dayKey(day));
      await s.flush();
      s.dispose();
    });

    test('opening a mindmap hit selects the exact text box', () async {
      final s = await start();
      await s.canvases.save(
        CanvasDocument(
          id: 'mm',
          title: 'Strategy map',
          items: [
            const TextItem(
              id: 'a',
              position: Offset(10, 10),
              width: 200,
              minHeight: 0,
              text: 'first idea',
            ),
            const TextItem(
              id: 'b',
              position: Offset(900, 600),
              width: 200,
              minHeight: 0,
              text: 'launch narwhal initiative',
            ),
          ],
          updatedAt: DateTime.now(),
        ),
      );
      await s.createCanvas(title: 'Other', show: false);
      final hit = searchEverything(s, 'narwhal').single;
      hit.open();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(s.page, AppPage.canvas);
      expect(s.canvas!.id, 'mm');
      expect(s.canvas!.selectedItems.map((i) => i.id), ['b']);
      await s.flush();
      s.dispose();
    });
  });

  group('handwriting is never searched', () {
    test('strokes add nothing, even beside typed text', () async {
      final s = await start();
      await s.canvases.save(
        CanvasDocument(
          id: 'ink',
          title: 'Sketches',
          items: [
            StrokeItem(
              id: 's',
              points: const [StrokePoint(0, 0), StrokePoint(50, 50)],
              color: Colors.white,
              strokeWidth: 2,
            ),
          ],
          updatedAt: DateTime.now(),
        ),
      );
      await s.createCanvas(title: 'Typed', show: false);
      expect(searchEverything(s, 'stroke'), isEmpty);
      expect(
        s.search.index.keys.where((k) => k.startsWith('canvas:ink')).length,
        1,
        reason: 'only the title of the sketch mindmap is indexed',
      );
      expect(searchEverything(s, 'sketches').single.kind, 'Mindmap');
      await s.flush();
      s.dispose();
    });

    test('the search layer contains no recognition code', () {
      for (final f in Directory('lib/search').listSync().whereType<File>()) {
        final src = f.readAsStringSync().toLowerCase();
        expect(src.contains('ocr'), isFalse, reason: f.path);
        expect(src.contains('recogni'), isFalse, reason: f.path);
        expect(src.contains('strokeitem'), isFalse, reason: f.path);
      }
    });
  });

  group('matching', () {
    SearchIndex index() => SearchIndex()
      ..upsert(IndexedDoc(kind: DocKind.note, id: '1', title: 'Account to-do list'))
      ..upsert(
        IndexedDoc(
          kind: DocKind.note,
          id: '2',
          title: 'Mindmap ideas',
          fields: const [SearchField('body', 'Café, résumé & e-mail')],
        ),
      );

    test('partial words anywhere in a word', () {
      expect(index().query('ount').map((h) => h.doc.id), ['1']);
      expect(index().query('acc').map((h) => h.doc.id), ['1']);
      expect(index().query('deas').map((h) => h.doc.id), ['2']);
    });

    test('case, accents and punctuation', () {
      expect(index().query('CAFE RESUME').map((h) => h.doc.id), ['2']);
      expect(index().query('…café!').map((h) => h.doc.id), ['2']);
    });

    test('spacing variations', () {
      expect(index().query('todo').map((h) => h.doc.id), ['1']);
      expect(index().query('to do').map((h) => h.doc.id), ['1']);
      expect(index().query('mind map').map((h) => h.doc.id), ['2']);
      expect(index().query('email').map((h) => h.doc.id), ['2']);
      expect(index().query('   account    list  ').map((h) => h.doc.id), ['1']);
    });

    test('nothing matches nothing', () {
      expect(index().query('zzzz'), isEmpty);
      expect(index().query('!!!'), isEmpty);
    });

    test('highlight ranges follow accents and spacing', () {
      expect(matchRanges('Café Münster', 'munster'), [(start: 5, end: 12)]);
      expect(matchRanges('my to-do list', 'todo'), [(start: 3, end: 8)]);
      expect(matchRanges('abc', 'xyz'), isEmpty);
    });
  });

  group('updates and deletions', () {
    test('new, edited and deleted content', () async {
      final s = await start();
      final ws = s.workspace;
      expect(searchEverything(s, 'quasar'), isEmpty);
      var note = ws.createNote(title: 'Draft', body: 'about a quasar');
      expect(searchEverything(s, 'quasar').single.title, 'Draft');
      // Edited: old text gone, new text found.
      ws.notes.put(note.copyWith(body: 'about a pulsar'));
      expect(searchEverything(s, 'quasar'), isEmpty);
      expect(searchEverything(s, 'pulsar').single.title, 'Draft');
      final task = ws.createTask('Observe pulsar');
      expect(searchEverything(s, 'pulsar'), hasLength(2));
      // Deleted.
      ws.deleteNote(note.id);
      ws.deleteTask(task.id);
      expect(searchEverything(s, 'pulsar'), isEmpty);
      // A deleted mindmap leaves the results.
      await s.createCanvas(title: 'Pulsar map', show: false);
      expect(searchEverything(s, 'pulsar').single.kind, 'Mindmap');
      await s.deleteCanvas(
        s.canvasList.singleWhere((c) => c.title == 'Pulsar map').id,
      );
      expect(searchEverything(s, 'pulsar'), isEmpty);
      await s.flush();
      s.dispose();
    });
  });

  group('the dialog', () {
    Future<AppState> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ws = Workspace(dir);
      final state = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      state.capture.fetchPreviews = false;
      await tester.runAsync(state.init);
      state.workspace.createNote(title: 'Walrus facts', body: 'tusks and blubber');
      state.workspace.createTask('Feed the walrus');
      await tester.pumpWidget(TheApp(state: state));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The upper-right entry opens it.
      await tester.tap(find.byKey(const ValueKey('top-bar-search')));
      await tester.pumpAndSettle();
      return state;
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(
        find.byKey(const ValueKey('global-search-field')),
        text,
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(searchPause);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> done(WidgetTester tester, AppState state) async {
      await tester.runAsync(state.flush);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 9));
      state.dispose();
    }

    testWidgets('hint, results grouped by section, highlight, clear', (
      tester,
    ) async {
      final state = await open(tester);
      expect(find.byKey(const ValueKey('search-hint')), findsOneWidget);

      await type(tester, 'walr');
      expect(find.byKey(const ValueKey('search-section-Notes')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('search-section-Tasks and projects')),
        findsOneWidget,
      );
      // The matching part is drawn in its own style.
      bool bold(InlineSpan span) {
        var found = false;
        span.visitChildren((c) {
          if (c is TextSpan &&
              (c.text ?? '').toLowerCase() == 'walr' &&
              c.style?.fontWeight == FontWeight.w700) {
            found = true;
          }
          return true;
        });
        return found;
      }

      final marked = find.byWidgetPredicate(
        (w) => w is RichText && bold(w.text),
      );
      expect(marked, findsWidgets);
      // Where it was found is shown.
      expect(find.textContaining('Notes ›'), findsWidgets);

      // Clear returns to the hint, field empty.
      await tester.tap(find.byKey(const ValueKey('search-clear')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('search-hint')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-clear')), findsNothing);
      await done(tester, state);
    });

    testWidgets('nothing found says so and offers advice', (tester) async {
      final state = await open(tester);
      await type(tester, 'qqqqzz');
      expect(find.byKey(const ValueKey('search-empty')), findsOneWidget);
      expect(find.textContaining('Nothing found'), findsOneWidget);
      await done(tester, state);
    });

    testWidgets('results update as the user types', (tester) async {
      final state = await open(tester);
      await type(tester, 'wal');
      expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
      await type(tester, 'walrus tusks');
      expect(find.text('Walrus facts'), findsWidgets);
      expect(find.text('Feed the walrus'), findsNothing);
      await done(tester, state);
    });

    testWidgets('a result opens the exact item', (tester) async {
      final state = await open(tester);
      await type(tester, 'feed');
      await tester.tap(find.text('Feed the walrus').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('global-search-field')), findsNothing);
      expect(state.page, AppPage.calendar, reason: "tasks live in Calendar");
      await done(tester, state);
    });
  });
}
