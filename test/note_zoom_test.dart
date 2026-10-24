import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_test/flutter_test.dart';

class _EmptyCanvasRepository implements CanvasRepository {
  @override
  Future<void> delete(String id) async {}

  @override
  Future<CanvasDocument?> load(String id) async => null;

  @override
  Future<List<CanvasSummary>> listCanvases() async => const [];

  @override
  Future<int> newestSchema() async => CanvasDocument.schemaVersion;

  @override
  Future<int> oldestSchema() async => CanvasDocument.schemaVersion;

  @override
  Future<void> save(CanvasDocument document) async {}
}

void main() {
  testWidgets(
    'note page zoom is visible, bounded, and restored after restart',
    (tester) async {
      tester.view.physicalSize = const Size(1700, 1050);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final root = Directory.systemTemp.createTempSync('theapp_note_zoom_');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });

      Future<AppState> boot() async {
        final ws = Workspace(Directory('${root.path}/data'));
        final state = AppState(
          canvases: _EmptyCanvasRepository(),
          settings: SettingsRepository(ws.store),
          workspace: ws,
          enableSendTo: false,
        );
        state.capture.fetchPreviews = false;
        await tester.runAsync(state.init);
        return state;
      }

      var state = await boot();
      final note = state.workspace.createNote(title: 'Zoom test');
      await tester.runAsync(state.flush);

      Future<void> openPage() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: NotePage(state: state, noteId: note.id),
          ),
        );
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );
        await tester.pumpAndSettle();
      }

      await openPage();
      expect(find.byKey(const ValueKey('note-zoom-value')), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(find.byTooltip('Larger pages'));
      await tester.pump();
      expect(find.text('125%'), findsOneWidget);
      await tester.runAsync(state.flush);
      state.dispose();

      state = await boot();
      addTearDown(() => state.dispose());
      await openPage();
      expect(find.text('125%'), findsOneWidget);

      await tester.tap(find.byTooltip('Fit page width'));
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);
      await tester.runAsync(state.flush);
    },
  );
}
