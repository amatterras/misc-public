// The Related panel and the relationship graph with explicit links.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/graph/relationship_graph.dart';
import 'package:flutter_application_1/features/relations/related_panel.dart';
import 'package:flutter_application_1/features/relations/relations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_panel_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> open() async {
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await state.init();
    return state;
  }

  testWidgets('shows what a note links to and what links to it, and unlinks', (
    tester,
  ) async {
    final state = (await tester.runAsync(open))!;
    final ws = state.workspace;
    final a = ws.createNote(title: 'Alpha', body: '');
    final b = ws.createNote(title: 'Beta', body: '');
    final t = ws.createTask('Plan trip');
    final rel = RelationService(ws);
    rel.link(Ref(RefKind.note, a.id), Ref(RefKind.note, b.id));
    rel.link(Ref(RefKind.task, t.id), Ref(RefKind.note, a.id));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RelatedPanel(state: state, item: Ref(RefKind.note, a.id)),
          ),
        ),
      ),
    );
    expect(find.text('LINKS TO'), findsOneWidget);
    expect(find.text('LINKED FROM'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Plan trip'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove this link').first);
    await tester.pump();
    expect(rel.relatedTo(Ref(RefKind.note, a.id)), hasLength(1));
    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  });

  testWidgets('a deleted target is struck out and not tappable', (
    tester,
  ) async {
    final state = (await tester.runAsync(open))!;
    final ws = state.workspace;
    final a = ws.createNote(title: 'Alpha', body: '');
    final b = ws.createNote(title: 'Beta', body: '');
    RelationService(ws).link(Ref(RefKind.note, a.id), Ref(RefKind.note, b.id));
    // Deleting writes to disk for real: start it outside the fake clock.
    await tester.runAsync(() async => ws.deleteNote(b.id));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RelatedPanel(state: state, item: Ref(RefKind.note, a.id)),
        ),
      ),
    );
    expect(find.text('(deleted note)'), findsOneWidget);
    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  });

  test(
    'the graph draws explicit links, and only between things that exist',
    () async {
      final ws = Workspace(dir);
      await ws.load();
      final a = ws.createNote(title: 'Alpha', body: '');
      final b = ws.createNote(title: 'Beta', body: '');
      final c = ws.createNote(title: 'Gone', body: '');
      final rel = RelationService(ws);
      rel.link(Ref(RefKind.note, a.id), Ref(RefKind.note, b.id));
      rel.link(Ref(RefKind.note, a.id), Ref(RefKind.note, c.id));
      ws.deleteNote(c.id);
      final graph = await buildGraph(ws, FileCanvasRepository(ws.store));
      final labels = graph.nodes.map((n) => n.label).toSet();
      expect(labels, {'Alpha', 'Beta'});
      expect(graph.edges, hasLength(1));
    },
  );
}
