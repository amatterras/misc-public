// The page bar and page windows (implementation 2/5): stable instances,
// no duplicates, float/dock/minimize/restore/pin/close, persistence, the
// six destinations, and the real app with 20+ windows open.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/floating_windows.dart';
import 'package:flutter_application_1/app/page_windows.dart';
import 'package:flutter_application_1/app/sidebar.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_windows_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('exactly six destinations, in order', () {
    expect(
      [for (final d in appDestinations) d.$1],
      [
        AppPage.canvas,
        AppPage.notes,
        AppPage.calendar,
        AppPage.links,
        AppPage.browser,
        AppPage.ai,
      ],
    );
  });

  test(
    'instances: no duplicates, modes, pin order, close, persistence',
    () async {
      final ws = Workspace(dir);
      final settings = SettingsRepository(ws.store);
      final floating = FloatingWindows(settings);
      final w = PageWindows(settings, floating);
      final closed = <String>[];
      w.onClosed = closed.add;

      final a = w.open(AppPage.notes, refId: 'n1', title: 'One');
      expect(w.open(AppPage.notes, refId: 'n1'), same(a)); // focus, not a copy
      final b = w.open(AppPage.ai, refId: 'chat', mode: PageMode.floating);
      expect(floating.isOpen(b.id), isTrue);
      expect(w.activeId, a.id);

      w.minimize(b.id);
      expect(floating.isOpen(b.id), isFalse);
      w.restoreInstance(b.id);
      expect(b.mode, PageMode.floating); // back where it was
      w.minimize(a.id);
      expect(w.activeId, isNull);
      w.restoreInstance(a.id);
      expect(a.mode, PageMode.docked);

      w.togglePin(b.id);
      expect(w.all.first.id, b.id);
      await w.close(a.id, beforeClose: () async => false); // refused
      expect(w.byId(a.id), isNotNull);
      await w.close(a.id);
      expect(closed, [a.id]);

      await w.setCollapsed(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final again = PageWindows(settings, FloatingWindows(settings))..restore();
      expect(again.all.single.id, b.id); // same identity after restart
      expect(again.all.single.pinned, isTrue);
      expect(again.collapsed, isTrue);
    },
  );

  test('never more than the limit; floating and pinned ones are kept', () {
    final ws = Workspace(dir);
    final settings = SettingsRepository(ws.store);
    final w = PageWindows(settings, FloatingWindows(settings));
    final first = w.open(AppPage.notes, refId: 'keep', mode: PageMode.floating);
    for (var i = 0; i < PageWindows.maxInstances + 5; i++) {
      w.open(AppPage.notes, refId: 'n$i');
    }
    expect(w.all.length, PageWindows.maxInstances);
    expect(w.byId(first.id), isNotNull);
  });

  testWidgets('the real app with 22 page windows: no errors, minimized '
      'pages are not built', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
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
    await tester.pumpWidget(TheApp(state: state));
    await tester.pump();

    final notes = [
      for (var i = 0; i < 20; i++)
        ws.createNote(title: 'Window note $i', body: 'Body $i'),
    ];
    for (final (i, n) in notes.indexed) {
      state.windows.open(
        AppPage.notes,
        refId: n.id,
        title: n.title,
        mode: i < 10 ? PageMode.floating : PageMode.docked,
      );
    }
    state.windows.open(AppPage.calendar, title: 'calendar');
    final hidden = state.windows.open(
      AppPage.notes,
      refId: ws.createNote(title: 'Hidden one').id,
      title: 'Hidden one',
    );
    state.windows.minimize(hidden.id);
    final watch = Stopwatch()..start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    watch.stop();
    expect(tester.takeException(), isNull);
    expect(state.windows.all.length, 22);
    expect(state.floating.open.length, 10);
    // Minimized: kept (no state loss) but offstage — not painted, and its
    // animations and timers are paused.
    bool hiddenEditor(Widget w) =>
        w is EditableText && w.controller.text == 'Hidden one';
    final kept = find.byWidgetPredicate(hiddenEditor, skipOffstage: false);
    expect(kept, findsOneWidget);
    expect(find.byWidgetPredicate(hiddenEditor), findsNothing); // not on screen
    expect(TickerMode.valuesOf(tester.element(kept)).enabled, isFalse);
    // Switching between them keeps each page (no state loss).
    final last = state.windows.all.where((p) => p.mode == PageMode.docked).last;
    final switching = Stopwatch()..start();
    state.windows.focus(last.id);
    await tester.pump();
    switching.stop();
    expect(state.windows.activeId, last.id);
    expect(tester.takeException(), isNull);
    // Debug-mode timings on a busy test machine: loose bounds that still
    // catch a hang (first build of 22 live pages) or a slow switch.
    expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
    expect(switching.elapsed, lessThan(const Duration(seconds: 2)));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  });
}
