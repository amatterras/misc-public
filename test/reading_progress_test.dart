// Reading progress: states, last page, weekly goals, one record per item,
// persistence across a restart, Resume, and the overview window - with no
// calendar entries, tasks or deadlines made along the way.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/reading_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/reading/reading_progress.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pdf(int pages) => Uint8List.fromList(
  '%PDF-1.4\n2 0 obj << /Type /Pages /Kids [] /Count $pages >> endobj\n%%EOF\n'
      .codeUnits,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState s;

  Future<AppState> boot() async {
    final ws = Workspace(Directory('${dir.path}/data'));
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    state.capture.fetchPreviews = false;
    await state.init();
    return state;
  }

  Future<Asset> book(String name) async {
    final f = File('${dir.path}/src/$name.pdf')
      ..createSync(recursive: true)
      ..writeAsBytesSync(pdf(300));
    return s.workspace.documentAssetFromFile(f);
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_reading_');
    s = await boot();
  });
  tearDown(() async {
    await s.flush();
    s.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('the record', () {
    test('saved and read back; damaged parts fall back safely', () {
      final r = ReadingProgress(
        state: ReadState.reading,
        page: 34,
        totalPages: 300,
        log: const {'2026-10-26': 12},
        sessions: const {'2026-10-26': 1},
        goalPages: 50,
        goalSessions: 3,
        updatedAt: DateTime.utc(2026, 10, 26, 10),
      );
      final back = ReadingProgress.fromJson(r.toJson())!;
      expect(back.toJson(), r.toJson());
      expect(back.fraction, closeTo(34 / 300, 1e-9));
      final odd = ReadingProgress.fromJson({
        'state': 'sleeping',
        'page': -4,
        'total': 'many',
        'log': {'x': 'y', 'd': 3, 7: 2},
        'goalPages': 0,
      })!;
      expect(odd.state, ReadState.reading);
      expect(odd.page, 1);
      expect(odd.totalPages, isNull);
      expect(odd.log, {'d': 3});
      expect(odd.goalPages, isNull);
      expect(ReadingProgress.fromJson('nope'), isNull);
      expect(ReadingProgress.fromJson(null), isNull);
    });

    test('older item records have no reading and stay as they are', () {
      final a = Asset.fromJson({
        'id': 'a',
        'kind': 'link',
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': '2026-01-01T00:00:00Z',
        'url': 'https://example.com',
      });
      expect(a.reading, isNull);
      expect(a.toJson().containsKey('reading'), isFalse);
    });

    test('weeks run Monday to Sunday', () {
      final r = ReadingProgress(
        log: const {
          '2026-10-18': 99, // Sunday before
          '2026-10-19': 10, // Monday
          '2026-10-25': 5, // Sunday
          '2026-10-26': 77, // next Monday
        },
        sessions: const {'2026-10-19': 1, '2026-10-21': 2},
      );
      final w = r.week(DateTime(2026, 10, 22)); // a Thursday
      expect(w.pages, 15);
      expect(w.sessions, 3);
      expect(r.week(DateTime(2026, 10, 26)).pages, 77);
    });
  });

  group('keeping track', () {
    test('one record per item however often it is opened', () async {
      final a = await book('Dune');
      final before = s.workspace.assets.all.length;
      startReading(s.workspace, a.id);
      setReadPage(s.workspace, a.id, 40);
      startReading(s.workspace, a.id); // again: nothing changes
      startReading(s.workspace, a.id);
      expect(s.workspace.assets.all.length, before);
      expect(s.workspace.assets[a.id]!.reading!.page, 40);
      expect(readingItems(s.workspace), hasLength(1));
      // Only PDFs and saved links can be tracked.
      final photo = Asset(
        id: 'p',
        kind: AssetKind.image,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      s.workspace.assets.put(photo);
      expect(startReading(s.workspace, 'p'), isNull);
      expect(startReading(s.workspace, 'nope'), isNull);
    });

    test('unread, reading and completed; finishing reaches the last page', () async {
      final a = await book('Long');
      startReading(s.workspace, a.id, state: ReadState.unread);
      expect(s.workspace.assets[a.id]!.reading!.state, ReadState.unread);
      setReadLength(s.workspace, a.id, 300);
      setReadState(s.workspace, a.id, ReadState.reading);
      setReadPage(s.workspace, a.id, 120);
      setReadState(s.workspace, a.id, ReadState.done);
      final r = s.workspace.assets[a.id]!.reading!;
      expect(r.state, ReadState.done);
      expect(r.page, 300);
      expect(r.fraction, 1.0);
      setReadState(s.workspace, a.id, ReadState.unread);
      expect(s.workspace.assets[a.id]!.reading!.page, 300);
      // The page cannot pass the length.
      setReadPage(s.workspace, a.id, 999);
      expect(s.workspace.assets[a.id]!.reading!.page, 300);
      setReadPage(s.workspace, a.id, -5);
      expect(s.workspace.assets[a.id]!.reading!.page, 1);
    });

    test('reading some pages moves on, logs them and a session', () async {
      final a = await book('Log');
      startReading(s.workspace, a.id, state: ReadState.unread);
      logReading(s.workspace, a.id, 12, at: DateTime(2026, 10, 26, 9));
      logReading(s.workspace, a.id, 8, at: DateTime(2026, 10, 26, 21));
      final r = s.workspace.assets[a.id]!.reading!;
      expect(r.state, ReadState.reading, reason: 'reading starts it');
      expect(r.page, 21);
      expect(r.log['2026-10-26'], 20);
      expect(r.sessions['2026-10-26'], 2);
    });

    test('goals are optional targets; nothing is scheduled', () async {
      final a = await book('Goal');
      startReading(s.workspace, a.id);
      final tasks = s.workspace.tasks.all.length;
      final entries = s.workspace.entries.all.length;
      setReadGoals(s.workspace, a.id, pages: 50, sessions: 3);
      logReading(s.workspace, a.id, 30, at: DateTime(2026, 10, 21));
      final data = readingOverview(s.workspace, DateTime(2026, 10, 22));
      final (asset, week) = data.goals.single;
      expect(asset.id, a.id);
      expect(week, (pages: 30, sessions: 1));
      expect(s.workspace.tasks.all.length, tasks);
      expect(s.workspace.entries.all.length, entries);
      setReadGoals(s.workspace, a.id);
      expect(readingOverview(s.workspace, DateTime(2026, 10, 22)).goals, isEmpty);
    });

    test('stopping removes only the reading record', () async {
      final a = await book('Stop');
      startReading(s.workspace, a.id);
      stopReading(s.workspace, a.id);
      expect(s.workspace.assets[a.id], isNotNull);
      expect(s.workspace.assets[a.id]!.reading, isNull);
    });
  });

  group('resume and restart', () {
    test('close the app, reopen it, resume at the right page', () async {
      final a = await book('Novel');
      startReading(s.workspace, a.id);
      setReadLength(s.workspace, a.id, 300);
      setReadPage(s.workspace, a.id, 34);
      await s.flush();
      s.dispose();
      s = await boot();

      final r = s.workspace.assets[a.id]!.reading!;
      expect(r.state, ReadState.reading);
      expect(r.page, 34);
      expect(r.totalPages, 300);
      final opened = <int>[];
      s.pdfOpener = (file, page) async {
        opened.add(page);
        return true;
      };
      expect(await resumeReading(s, a.id), isTrue);
      expect(opened, [34]);
      expect(latestReading(s.workspace)!.id, a.id);
    });

    test('a saved link resumes in the browser; an unread one becomes reading',
        () async {
      final link = s.workspace.linkAsset('https://example.com/article', title: 'Article');
      startReading(s.workspace, link.id, state: ReadState.unread);
      final urls = <String>[];
      s.urlOpener = urls.add;
      expect(await resumeReading(s, link.id), isTrue);
      expect(urls, ['https://example.com/article']);
      expect(s.workspace.assets[link.id]!.reading!.state, ReadState.reading);
    });

    test('a missing PDF file does not resume and nothing changes', () async {
      final a = await book('Gone');
      startReading(s.workspace, a.id);
      setReadPage(s.workspace, a.id, 9);
      s.workspace.documentFile(a)!.deleteSync();
      s.pdfOpener = (f, p) async => true;
      expect(await resumeReading(s, a.id), isFalse);
      expect(s.workspace.assets[a.id]!.reading!.page, 9);
    });

    test('looking at a page in the PDF window follows only while reading',
        () async {
      final a = await book('Follow');
      startReading(s.workspace, a.id, state: ReadState.unread);
      noteReadPage(s.workspace, a.id, 12);
      expect(s.workspace.assets[a.id]!.reading!.page, 1);
      setReadState(s.workspace, a.id, ReadState.reading);
      noteReadPage(s.workspace, a.id, 12);
      expect(s.workspace.assets[a.id]!.reading!.page, 12);
    });

    test('the record travels with the item through sync', () async {
      final a = await book('Sync');
      startReading(s.workspace, a.id);
      setReadPage(s.workspace, a.id, 77);
      final copy = Asset.fromJson(s.workspace.assets[a.id]!.toJson());
      expect(copy.reading!.page, 77);
      expect(copy.reading!.toJson(), s.workspace.assets[a.id]!.reading!.toJson());
    });
  });

  testWidgets('the overview: counts, resume, add, mark completed', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = (await tester.runAsync(() => book('Alpha')))!;
    final b = (await tester.runAsync(() => book('Beta')))!;
    startReading(s.workspace, a.id);
    setReadPage(s.workspace, a.id, 5);
    startReading(s.workspace, b.id, state: ReadState.done);
    final opened = <int>[];
    s.pdfOpener = (f, p) async {
      opened.add(p);
      return true;
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showReadingOverview(context, s),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('reading-counts'))).data,
      '1 reading  ·  0 to read  ·  1 completed',
    );
    expect(find.textContaining('page 5'), findsOneWidget);
    // Mark the second as unread from its menu.
    await tester.tap(find.byKey(ValueKey('reading-menu-${b.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as unread'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('reading-counts'))).data,
      '1 reading  ·  1 to read  ·  0 completed',
    );
    // Resume the one being read.
    await tester.runAsync(() async {});
    await tester.tap(find.byKey(const ValueKey('resume-latest')));
    for (var i = 0; i < 20 && opened.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(opened, [5]);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
  });
}
