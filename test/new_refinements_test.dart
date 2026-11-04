// The refinement batch: the Archive-style header in Calendar and Notes, the
// sidebar in all three modes (and the hover-then-click error), the quote in
// the bottom-right corner, the removed sidebar items (both interfaces), the
// Notes zoom-out limit, the Mindmap dot size/opacity controls and the
// removed canvas picker.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/interface_version.dart';
import 'package:flutter_application_1/app/shell.dart';
import 'package:flutter_application_1/app/sidebar.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_toolbar.dart';
import 'package:flutter_application_1/features/motivation/motivation_service.dart';
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_application_1/features/palette/command_palette.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/new_ui/new_components.dart';
import 'package:flutter_application_1/new_ui/new_sidebar.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoCanvases implements CanvasRepository {
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
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String quotes;
  late String greetings;
  setUpAll(() async {
    quotes = await rootBundle.loadString('assets/motivation/quotes.json');
    greetings = await rootBundle.loadString('assets/motivation/greetings.json');
  });
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_refine_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> boot(
    WidgetTester tester, {
    required Size size,
    InterfaceVersion version = InterfaceVersion.newDesign,
    bool noCanvases = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ws = Workspace(dir);
    final state = AppState(
      canvases: noCanvases ? _NoCanvases() : FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
    await tester.runAsync(state.init);
    await tester.runAsync(() => state.setInterfaceVersion(version));
    return state;
  }

  Future<void> settle(WidgetTester tester, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  }

  // ── 1. the Archive's top section in Calendar and Notes ──────────────────
  testWidgets('Archive, Calendar and Notes share the New header', (
    tester,
  ) async {
    final s = await boot(tester, size: const Size(1280, 900));
    await tester.pumpWidget(TheApp(state: s));
    await settle(tester);
    for (final (page, title) in [
      (AppPage.links, 'Archive'),
      (AppPage.calendar, 'Calendar'),
      (AppPage.notes, 'Notes'),
    ]) {
      s.goTo(page);
      await settle(tester);
      expect(find.byType(NewPageHeader), findsOneWidget, reason: '$page');
      expect(
        find.descendant(
          of: find.byType(NewPageHeader),
          matching: find.text(title),
        ),
        findsOneWidget,
        reason: '$page',
      );
    }
    // Calendar keeps its own controls, restyled.
    s.goTo(AppPage.calendar);
    await settle(tester);
    expect(find.byKey(const ValueKey('calendar-tasks-toggle')), findsOneWidget);
    expect(find.text('Quick Add'), findsWidgets);
    // Notes keeps its search and its New button.
    s.goTo(AppPage.notes);
    await settle(tester);
    expect(find.text('Search notes'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, s);
  });

  testWidgets('Original keeps its own Calendar and Notes headers', (
    tester,
  ) async {
    final s = await boot(
      tester,
      size: const Size(1280, 900),
      version: InterfaceVersion.original,
    );
    await tester.pumpWidget(TheApp(state: s));
    await settle(tester);
    for (final page in [AppPage.calendar, AppPage.notes, AppPage.links]) {
      s.goTo(page);
      await settle(tester);
      expect(find.byType(NewPageHeader), findsNothing, reason: '$page');
    }
    await close(tester, s);
  });

  // ── 2. the sidebar in all three modes ───────────────────────────────────
  for (final size in const [Size(1280, 800), Size(900, 500), Size(700, 400)]) {
    testWidgets('sidebar: compact, expanded, hidden and back at $size', (
      tester,
    ) async {
      final s = await boot(tester, size: size);
      await tester.pumpWidget(TheApp(state: s));
      await settle(tester);
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exceptionAsString());

      Future<void> frames() => settle(tester, 10);
      Future<void> hoverThenClick(Finder f) async {
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(f));
        await settle(tester, 3); // its label shows
        await mouse.down(tester.getCenter(f));
        await mouse.up();
        await frames();
        await mouse.removePointer();
      }

      // Compact (the start) → expanded, clicking the very button whose
      // label is showing (this used to throw).
      expect(s.newSidebarExpanded, isFalse);
      await hoverThenClick(find.byKey(const ValueKey('new-nav-expand')));
      expect(s.newSidebarExpanded, isTrue);
      expect(find.text('notes'), findsWidgets); // names beside the icons
      // Expanded → compact.
      await hoverThenClick(find.byKey(const ValueKey('new-nav-expand')));
      expect(s.newSidebarExpanded, isFalse);
      // Compact → hidden → shown.
      await hoverThenClick(find.byKey(const ValueKey('new-nav-hide')));
      expect(s.newSidebarHidden, isTrue);
      expect(find.byType(NewSidebar), findsNothing);
      await tester.tap(find.byKey(const ValueKey('new-sidebar-show')));
      await frames();
      expect(s.newSidebarHidden, isFalse);
      expect(find.byType(NewSidebar), findsOneWidget);
      // Expanded again, then hidden straight from expanded.
      await hoverThenClick(find.byKey(const ValueKey('new-nav-expand')));
      await hoverThenClick(find.byKey(const ValueKey('new-nav-hide')));
      expect(find.byType(NewSidebar), findsNothing);
      await tester.tap(find.byKey(const ValueKey('new-sidebar-show')));
      await frames();

      // Navigation still works, and the capsule has a real size.
      final box = tester.getSize(find.byType(NewSidebar).first);
      expect(box.width, greaterThan(100));
      await tester.tap(find.byKey(const ValueKey('new-nav-notes')));
      await frames();
      expect(s.page, AppPage.notes);

      FlutterError.onError = previous;
      expect(errors, isEmpty, reason: errors.join('\n---\n'));
      await close(tester, s);
    });
  }

  // ── 3. the quote, bottom-right, in both interfaces ──────────────────────
  for (final (label, version, width) in [
    ('Original', InterfaceVersion.original, 1280.0),
    ('New', InterfaceVersion.newDesign, 1280.0),
    ('Original compact', InterfaceVersion.original, 390.0),
    ('New narrow', InterfaceVersion.newDesign, 390.0),
  ]) {
    testWidgets('the quote sits quietly bottom-right ($label)', (tester) async {
      final s = await boot(tester, size: Size(width, 844), version: version);
      final motivation = MotivationService(nextIndex: (_) => 0)
        ..loadFromSources(quotes, greetings);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(state: s, motivation: motivation),
        ),
      );
      await tester.pump();
      await settle(tester);
      final quote = find.byKey(const ValueKey('motivational-quote'));
      expect(quote, findsOneWidget);
      final r = tester.getRect(quote);
      expect(r.right, greaterThan(width * 0.45), reason: 'right side');
      expect(r.right, lessThanOrEqualTo(width - 8));
      expect(r.bottom, greaterThan(844 - 120), reason: 'bottom');
      expect(r.height, lessThan(40), reason: 'one or two small lines');
      // It never takes touches, so it cannot block a control.
      expect(
        find.ancestor(of: quote, matching: find.byType(IgnorePointer)),
        findsWidgets,
      );
      // Not in the sidebar any more.
      expect(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.byKey(const ValueKey('motivational-quote')),
        ),
        findsNothing,
      );
      motivation.dispose();
      await close(tester, s);
    });
  }

  // ── 4. removed sidebar items, New (Original is in shell_refinements) ────
  testWidgets('the New capsule has no commands, switcher or lists', (
    tester,
  ) async {
    final s = await boot(tester, size: const Size(1280, 800));
    await tester.pumpWidget(TheApp(state: s));
    await settle(tester);
    for (final k in const [
      'new-nav-commands',
      'new-nav-switcher',
      'new-nav-library',
      'new-library-panel',
    ]) {
      expect(find.byKey(ValueKey(k)), findsNothing, reason: k);
    }
    for (final k in const [
      'new-quick-add',
      'new-nav-canvas',
      'new-nav-notes',
      'new-nav-calendar',
      'new-nav-links',
      'new-nav-browser',
      'new-nav-ai',
      'new-nav-settings',
      'new-nav-expand',
      'new-nav-hide',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    // The command palette itself (and its keyboard shortcut) still exist.
    final commands = paletteCommands(
      s,
      quickAdd: (_) {},
      search: (_) {},
      settings: (_) {},
      appSwitcher: (_) {},
    );
    expect(commands.map((c) => c.label), contains('App switcher (floating)'));
    await close(tester, s);
  });

  // ── 5. Notes zoom-out limit ─────────────────────────────────────────────
  Future<int> zoomOutAll(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.tap(find.byTooltip('Smaller pages'));
      await tester.pump();
    }
    final text = tester
        .widget<Text>(find.byKey(const ValueKey('note-zoom-value')))
        .data!;
    return int.parse(text.replaceAll('%', ''));
  }

  Future<AppState> openNotePage(
    WidgetTester tester,
    Size size,
    InterfaceVersion version,
  ) async {
    final s = await boot(
      tester,
      size: size,
      version: version,
      noCanvases: true,
    );
    final note = s.workspace.createNote(title: 'Zoom');
    await tester.runAsync(s.flush);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: NotePage(state: s, noteId: note.id),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();
    return s;
  }

  testWidgets('Notes zoom-out stops at a useful overview (New)', (
    tester,
  ) async {
    // A short window: the whole page needs a smaller zoom than Original's 40%.
    final s = await openNotePage(
      tester,
      const Size(1000, 560),
      InterfaceVersion.newDesign,
    );
    final small = await zoomOutAll(tester);
    expect(small, lessThan(40), reason: 'whole page fits in a short window');
    expect(small, greaterThan(10), reason: 'but not unlimited');
    // More taps change nothing: this is the limit.
    expect(await zoomOutAll(tester), small);
    // Zoom-in and "fit width" still work from the limit.
    await tester.tap(find.byTooltip('Larger pages'));
    await tester.pump();
    final bigger = int.parse(
      tester
          .widget<Text>(find.byKey(const ValueKey('note-zoom-value')))
          .data!
          .replaceAll('%', ''),
    );
    expect(bigger, greaterThan(small));
    await tester.tap(find.byTooltip('Fit page width'));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    await close(tester, s);
  });

  testWidgets('Notes zoom-out keeps a big-screen page from shrinking (New)', (
    tester,
  ) async {
    // A large, tall window: the page is not allowed to shrink to a speck.
    final s = await openNotePage(
      tester,
      const Size(1600, 1500),
      InterfaceVersion.newDesign,
    );
    final large = await zoomOutAll(tester);
    expect(large, greaterThan(40), reason: 'no tiny page on a big screen');
    expect(large, lessThan(100));
    await close(tester, s);
  });

  testWidgets('Notes zoom-out in Original is unchanged (40%)', (tester) async {
    final s = await openNotePage(
      tester,
      const Size(1000, 560),
      InterfaceVersion.original,
    );
    expect(await zoomOutAll(tester), 40);
    await close(tester, s);
  });

  // ── 6. Mindmap dot controls ─────────────────────────────────────────────
  testWidgets('dot size and opacity: live, bounded, saved (New)', (
    tester,
  ) async {
    final s = await boot(tester, size: const Size(1000, 800));
    await tester.runAsync(() => s.createCanvas(title: 'Board', show: false));
    await tester.runAsync(() => s.openCanvas(s.canvasList.first.id));
    final c = s.canvas!;
    expect(c.dotSize, CanvasController.defaultDotSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDotOpacityDialog(
              context,
              c,
              s.setDotOpacity,
              saveSize: s.setDotSize,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dot-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('dot-opacity-slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('dot-size-slider')), findsOneWidget);

    // The canvas changes while the slider moves.
    await tester.drag(
      find.byKey(const ValueKey('dot-size-slider')),
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    expect(c.dotSize, greaterThan(CanvasController.defaultDotSize));
    expect(c.dotSize, lessThanOrEqualTo(CanvasController.dotSizeMax));
    final before = c.dotOpacity;
    await tester.drag(
      find.byKey(const ValueKey('dot-opacity-slider')),
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    expect(c.dotOpacity, greaterThan(before));
    expect(c.dotOpacity, lessThanOrEqualTo(CanvasController.dotOpacityMax));
    // The two are independent: size stayed where it was put.
    expect(c.dotSize, greaterThan(CanvasController.defaultDotSize));

    // Saved for this device, and picked up by the next canvas controller.
    final saved = s.settings.get<num>('dotSize.mindmap')!.toDouble();
    expect(saved, c.dotSize);
    expect(s.dotSizeFor(DotSurface.mindmap), saved);

    // Out-of-range values are made safe; Default restores the look.
    c.setDotSize(99);
    expect(c.dotSize, CanvasController.dotSizeMax);
    c.setDotSize(0);
    expect(c.dotSize, CanvasController.dotSizeMin);
    await tester.tap(find.byKey(const ValueKey('dot-opacity-reset')));
    await tester.pumpAndSettle();
    expect(c.dotSize, CanvasController.defaultDotSize);
    expect(c.dotOpacity, CanvasController.defaultDotOpacity);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    await tester.runAsync(s.flush);
    s.dispose();
  });

  testWidgets('the dots dialog has no size slider in Original', (tester) async {
    final s = await boot(
      tester,
      size: const Size(1000, 800),
      version: InterfaceVersion.original,
    );
    await tester.runAsync(() => s.createCanvas(title: 'Board', show: false));
    await tester.runAsync(() => s.openCanvas(s.canvasList.first.id));
    final c = s.canvas!;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDotOpacityDialog(context, c, s.setDotOpacity),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dot-opacity-slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('dot-size-slider')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    await tester.runAsync(s.flush);
    s.dispose();
  });

  // ── 7. the canvas picker ────────────────────────────────────────────────
  for (final (label, version, shown) in [
    ('New', InterfaceVersion.newDesign, false),
    ('Original', InterfaceVersion.original, true),
  ]) {
    testWidgets('the top-left canvas picker is gone in New ($label)', (
      tester,
    ) async {
      final s = await boot(
        tester,
        size: const Size(1280, 800),
        version: version,
      );
      await tester.runAsync(() => s.createCanvas(title: 'Board', show: true));
      await tester.pumpWidget(TheApp(state: s));
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
      s.goTo(AppPage.canvas);
      await settle(tester);
      expect(
        find.byTooltip('Canvas options'),
        shown ? findsOneWidget : findsNothing,
      );
      // The canvases and their data are untouched either way.
      expect(s.canvasList.map((c) => c.title), contains('Board'));
      if (!shown) {
        // What the picker offered is in the command palette instead.
        final labels = paletteCommands(
          s,
          quickAdd: (_) {},
          search: (_) {},
          settings: (_) {},
          appSwitcher: (_) {},
        ).map((c) => c.label);
        expect(
          labels,
          containsAll([
            'Rename this mindmap',
            'Move this mindmap to a folder',
            'Move this mindmap to trash',
          ]),
        );
      }
      await close(tester, s);
    });
  }
}
