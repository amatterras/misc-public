import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/page_windows.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/browser/browser_page.dart';
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
  testWidgets('compact browser chrome is floating-window only and restorable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final root = Directory.systemTemp.createTempSync('theapp_browser_compact_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    final ws = Workspace(Directory('${root.path}/data'));
    final state = AppState(
      canvases: _EmptyCanvasRepository(),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    state.capture.fetchPreviews = false;
    await tester.runAsync(state.init);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(state.flush);
      state.dispose();
    });

    final page = state.windows.open(
      AppPage.browser,
      title: 'Safari',
      mode: PageMode.floating,
    );
    final browser = state.browserFor(page);
    Widget view({bool floating = false}) => MaterialApp(
      home: Scaffold(
        body: BrowserPage(
          state: state,
          browser: browser,
          instanceId: floating ? page.id : null,
        ),
      ),
    );

    await tester.pumpWidget(view(floating: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browser-new-tab')), findsOneWidget);
    expect(find.byTooltip('Hide browser controls'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide browser controls'));
    await tester.pump();
    expect(find.byKey(const ValueKey('browser-new-tab')), findsNothing);
    expect(
      find.byKey(const ValueKey('browser-restore-chrome')),
      findsOneWidget,
    );
    await tester.runAsync(state.flush);

    // The ordinary Safari destination keeps its normal bars even though the
    // floating window's compact preference is saved as on.
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browser-new-tab')), findsOneWidget);
    expect(find.byTooltip('Hide browser controls'), findsNothing);

    // Reopening that floating page restores compact state and offers a clear
    // control to bring the bars back.
    await tester.pumpWidget(view(floating: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browser-new-tab')), findsNothing);
    await tester.tap(find.byTooltip('Show browser controls'));
    await tester.pump();
    expect(find.byKey(const ValueKey('browser-new-tab')), findsOneWidget);
    await tester.runAsync(state.flush);
  });
}
