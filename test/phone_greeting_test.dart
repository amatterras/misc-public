// The welcome greeting on the iPhone interface.
//
// Root cause found in the audit: AppShell drew the floating welcome window only
// `if (!phone)`; on the phone a single text line inside the Today tab (shown
// only while the selected day was today) replaced it. So the popup the user
// knows from Windows and iPad never existed on the phone. These tests pin the
// fixed behaviour: the same window, the same single source, on the phone too.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/shell.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/motivation/motivation_service.dart';
import 'package:flutter_application_1/phone/phone_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String quotes;
  late String greetings;
  setUpAll(() async {
    quotes = await rootBundle.loadString('assets/motivation/quotes.json');
    greetings = await rootBundle.loadString('assets/motivation/greetings.json');
  });
  setUp(() {
    dir = Directory.systemTemp.createTempSync('theapp_phone_greeting_');
    PhoneProfile.forced = true;
  });
  tearDown(() {
    PhoneProfile.forced = false;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppState makeState() {
    final ws = Workspace(dir);
    return AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Boots the real shell on a phone-sized window with the same wiring as the
  /// app: dismissal is written to the same setting Windows and iPad use.
  Future<(AppState, MotivationService)> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    int Function(int)? nextIndex,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = makeState();
    await tester.runAsync(state.init);
    final motivation = MotivationService(
      nextIndex: nextIndex ?? (n) => 3 % n,
      greetingDismissed:
          state.settings.get<bool>('welcomeGreetingDismissed') ?? false,
      onGreetingDismissed: () =>
          state.settings.set('welcomeGreetingDismissed', true),
    )..loadFromSources(quotes, greetings);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: AppShell(state: state, motivation: motivation),
      ),
    );
    await settle(tester);
    return (state, motivation);
  }

  Future<void> close(
    WidgetTester tester,
    AppState state,
    MotivationService m,
  ) async {
    await tester.pumpWidget(const SizedBox());
    m.dispose();
    await tester.runAsync(state.flush);
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  }

  final window = find.byKey(const ValueKey('greeting-window'));

  testWidgets('the welcome window appears on the phone, once', (tester) async {
    final (state, m) = await open(tester);
    expect(window, findsOneWidget);
    // the old Today line is gone: one greeting, not two
    expect(find.byKey(const ValueKey('phone-greeting')), findsNothing);
    expect(find.text(m.greeting!), findsOneWidget);
    await close(tester, state, m);
  });

  testWidgets('it sits below the status bar and fits every iPhone width', (
    tester,
  ) async {
    for (final size in const [
      Size(320, 568), // iPhone SE (1st gen) width
      Size(375, 667),
      Size(390, 844),
      Size(430, 932),
    ]) {
      final (state, m) = await open(tester, size: size);
      final rect = tester.getRect(window);
      expect(rect.left, greaterThanOrEqualTo(16), reason: '$size');
      expect(rect.right, lessThanOrEqualTo(size.width - 16), reason: '$size');
      expect(rect.top, greaterThanOrEqualTo(10), reason: '$size');
      expect(tester.takeException(), isNull, reason: 'no overflow at $size');
      await close(tester, state, m);
    }
  });

  testWidgets('the greeting does not change when the UI rebuilds', (
    tester,
  ) async {
    final (state, m) = await open(
      tester,
      // a random source that would give a different line every time it is asked
      nextIndex: (n) => DateTime.now().microsecondsSinceEpoch % n,
    );
    final first = m.greeting;
    final shown = tester.widget<Text>(
      find.descendant(of: window, matching: find.byType(Text)),
    );
    expect(shown.data, first);
    // rebuilds: tab changes, a foreground event, a changed window size
    state.notifyListeners();
    m.didChangeAppLifecycleState(AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(375, 667);
    await settle(tester);
    expect(m.greeting, first);
    expect(
      tester
          .widget<Text>(
            find.descendant(of: window, matching: find.byType(Text)),
          )
          .data,
      first,
    );
    await close(tester, state, m);
  });

  testWidgets('it comes from the one shared collection', (tester) async {
    final (state, m) = await open(tester);
    final all = [
      for (final slot in MotivationService.parseGreetingSlots(greetings))
        ...slot.greetings,
    ];
    expect(all, hasLength(600));
    expect(all, contains(m.greeting));
    await close(tester, state, m);
    // the phone layer keeps no copy of its own
    for (final f in Directory('lib/phone').listSync().whereType<File>()) {
      expect(
        f.readAsStringSync(),
        isNot(contains('greetings.json')),
        reason: f.path,
      );
    }
  });

  testWidgets('it does not block the phone: tabs still work under it', (
    tester,
  ) async {
    final (state, m) = await open(tester);
    expect(window, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('phone-tab-notes')));
    await settle(tester);
    expect(state.page, AppPage.notes);
    expect(window, findsOneWidget, reason: 'still shown, not re-created');
    await close(tester, state, m);
  });

  testWidgets('it goes after 60 seconds', (tester) async {
    final (state, m) = await open(tester);
    await tester.pump(const Duration(seconds: 59));
    expect(window, findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(window, findsNothing);
    await close(tester, state, m);
  });

  testWidgets('swiping it away persists and it stays away after a restart', (
    tester,
  ) async {
    var (state, m) = await open(tester);
    await tester.drag(window, const Offset(110, 8));
    await tester.pump(const Duration(milliseconds: 400));
    expect(window, findsNothing);
    await tester.runAsync(state.flush);
    expect(state.settings.get<bool>('welcomeGreetingDismissed'), isTrue);

    // restart: a brand-new settings reader over the same folder sees the
    // dismissal on disk, and a new service built from it shows nothing
    // (Windows can briefly hold the settings file; the store retries on the
    // fake clock, so alternate fake and real time until it is on disk)
    final file = File('${dir.path}/settings/app.json');
    for (var i = 0; i < 40; i++) {
      if (file.readAsStringSync().contains('welcomeGreetingDismissed')) break;
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    final reread = SettingsRepository(Workspace(dir).store);
    await tester.runAsync(reread.load);
    expect(reread.get<bool>('welcomeGreetingDismissed'), isTrue);
    await tester.pumpWidget(const SizedBox());
    m.dispose();
    final restarted = MotivationService(
      nextIndex: (n) => 3 % n,
      greetingDismissed: reread.get<bool>('welcomeGreetingDismissed') ?? false,
    )..loadFromSources(quotes, greetings);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: AppShell(state: state, motivation: restarted),
      ),
    );
    await settle(tester);
    expect(restarted.greetingVisible, isFalse);
    expect(window, findsNothing);
    await close(tester, state, restarted);
  });
}
