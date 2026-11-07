// Phase 2: live theme switching and the design-token system.
//
// The app reads most colours from static palette getters (AppColors /
// NewColors). A theme change must reach every visible component in the SAME
// frame, including widgets that never depend on Theme.of (const widgets, open
// dialogs, floating windows), without re-creating any state. These tests open
// several kinds of UI at once, switch theme, pump exactly one frame and check
// the colours and that nothing was rebuilt from scratch.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/background_palette.dart';
import 'package:flutter_application_1/app/floating_windows.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/app/theme_switch.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/new_ui/new_tokens.dart';
import 'package:flutter_application_1/platform/window_chrome.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

/// Reads the palette while building and never depends on Theme: exactly the
/// kind of widget that used to keep its old colours after a switch.
class _ConstProbe extends StatelessWidget {
  const _ConstProbe(this.id);
  final String id;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: ValueKey('probe-$id'),
    color: AppColors.card,
    child: const SizedBox(width: 10, height: 10),
  );
}

/// A stateful widget whose State must survive the switch (no remount).
class _Keeper extends StatefulWidget {
  const _Keeper();
  @override
  State<_Keeper> createState() => _KeeperState();
}

class _KeeperState extends State<_Keeper> {
  final controller = TextEditingController(text: 'half-typed note');

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 220,
    child: TextField(key: const ValueKey('keeper-field'), controller: controller),
  );
}

Color _probe(WidgetTester tester, String id) =>
    tester.widget<ColoredBox>(find.byKey(ValueKey('probe-$id'))).color;

Future<AppState> _boot(WidgetTester tester, Directory dir) async {
  tester.view.physicalSize = const Size(1400, 900);
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
  return state;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shutDown(WidgetTester tester, AppState state) async {
  await waitForBothClocks(tester, state.flush, what: 'Saving');
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 4));
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('theapp_theme_');
    ThemeSwitch.reset();
    WindowChrome.reset();
  });
  tearDown(() {
    AppColors.mode = ThemeMode.dark;
    ThemeSwitch.reset();
    WindowChrome.reset();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('switching theme updates a floating window, an open dialog and '
      'const widgets in one frame, keeping their state', (tester) async {
    final s = await _boot(tester, dir);
    await tester.runAsync(() => s.setThemeMode('dark'));
    await tester.pump();
    expect(AppColors.light, isFalse);
    final darkCard = AppColors.card;
    final darkRaised = AppColors.cardRaised;

    // 1. A floating window with a const probe and a stateful field.
    s.floating.show(
      FloatingWindowSpec(
        id: 'theme-probe',
        title: 'Probe',
        initialRect: const Rect.fromLTWH(60, 60, 320, 240),
        builder: (_) => const Column(
          children: [_ConstProbe('floating'), _Keeper()],
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('Probe'), findsOneWidget);

    // 2. A dialog on top, also with a const probe.
    final context = tester.element(find.byType(Scaffold).first);
    showAppDialog<void>(
      context: context,
      builder: (_) => const Dialog(child: _ConstProbe('dialog')),
    );
    await _settle(tester);
    expect(find.byType(Dialog), findsOneWidget);

    expect(_probe(tester, 'floating'), darkCard);
    expect(_probe(tester, 'dialog'), darkCard);
    final keeper = tester.state<_KeeperState>(find.byType(_Keeper));

    // Switch to light and pump exactly ONE frame.
    await tester.runAsync(() => s.setThemeMode('light'));
    await tester.pump();

    expect(AppColors.light, isTrue);
    final lightCard = AppColors.card;
    expect(lightCard, isNot(darkCard));
    expect(_probe(tester, 'floating'), lightCard, reason: 'floating window');
    expect(_probe(tester, 'dialog'), lightCard, reason: 'open dialog');

    // The floating window's own surface follows too.
    final panel = tester.widget<Material>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('floating-theme-probe-title')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(panel.color, isNot(darkRaised));
    expect(panel.color, AppColors.card);

    // The Material theme matches the palette in the same frame (no
    // cross-fade where Theme colours lag behind palette colours).
    final theme = Theme.of(tester.element(find.byType(Dialog)));
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, NewColors.background);

    // Nothing was re-created: same State, same text, dialog still open.
    expect(tester.state<_KeeperState>(find.byType(_Keeper)), same(keeper));
    expect(keeper.controller.text, 'half-typed note');
    expect(find.byType(Dialog), findsOneWidget);
    expect(s.floating.isOpen('theme-probe'), isTrue);

    // The native title bar was asked to follow the app theme.
    expect(WindowChrome.lastRequest?['dark'], false);

    // And back to dark, again in one frame.
    await tester.runAsync(() => s.setThemeMode('dark'));
    await tester.pump();
    expect(_probe(tester, 'floating'), darkCard);
    expect(_probe(tester, 'dialog'), darkCard);
    expect(WindowChrome.lastRequest?['dark'], true);
    expect(tester.state<_KeeperState>(find.byType(_Keeper)), same(keeper));

    Navigator.of(tester.element(find.byType(Dialog))).pop();
    await _settle(tester);
    s.floating.close('theme-probe');
    await _shutDown(tester, s);
  });

  testWidgets('"System" follows a live operating-system light/dark change', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final s = await _boot(tester, dir);
    s.floating.show(
      FloatingWindowSpec(
        id: 'sys-probe',
        title: 'Sys',
        builder: (_) => const _ConstProbe('sys'),
      ),
    );
    await tester.runAsync(() => s.setThemeMode('system'));
    await _settle(tester);
    expect(AppColors.light, isFalse);
    final dark = _probe(tester, 'sys');

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    expect(AppColors.light, isTrue);
    expect(_probe(tester, 'sys'), isNot(dark));
    expect(_probe(tester, 'sys'), AppColors.card);

    s.floating.close('sys-probe');
    await _shutDown(tester, s);
  });

  group('canvas backgrounds follow the theme, user settings do not', () {
    test('Mindmap dots: white on dark, black on light', () {
      AppColors.mode = ThemeMode.dark;
      expect(BackgroundPalette.dot(), const Color(0xFFFFFFFF));
      AppColors.mode = ThemeMode.light;
      expect(BackgroundPalette.dot(), const Color(0xFF000000));
    });
  });

  group('design tokens', () {
    test('old names are aliases of the one token set', () {
      expect(Space.md, AppSpace.md);
      expect(Space.xl, AppSpace.xl);
      expect(NewSpace.sm, AppSpace.sm);
      expect(NewRadii.capsule, AppRadii.capsule);
      expect(NewRadii.card, AppRadii.card);
      expect(NewMotion.quick, AppMotion.quick);
      expect(NewMotion.curve, AppMotion.standard);
      expect(NewText.label, AppType.label);
      expect(NewText.heading, AppType.title);
    });

    test('motion presets sit inside the Phase 2 target ranges', () {
      bool within(Duration d, int lo, int hi) =>
          d.inMilliseconds >= lo && d.inMilliseconds <= hi;
      expect(within(AppMotion.hover, 100, 140), isTrue);
      expect(within(AppMotion.press, 80, 120), isTrue);
      expect(within(AppMotion.dropdown, 140, 180), isTrue);
      expect(within(AppMotion.popup, 160, 220), isTrue);
      expect(within(AppMotion.sidebar, 180, 250), isTrue);
      expect(within(AppMotion.page, 180, 280), isTrue);
      expect(within(AppMotion.panel, 150, 220), isTrue);
    });

    testWidgets('reduced motion turns animations off', (tester) async {
      late Duration seen;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              seen = AppMotion.of(context, AppMotion.popup);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, Duration.zero);
    });

    for (final b in Brightness.values) {
      test('${b.name} Material theme is built from the tokens', () {
        AppColors.mode = ThemeMode.dark;
        final t = buildAppTheme(brightness: b);
        // Building a theme never leaves the app in the other mode.
        expect(AppColors.mode, ThemeMode.dark);
        AppColors.mode = b == Brightness.light
            ? ThemeMode.light
            : ThemeMode.dark;
        expect(t.scaffoldBackgroundColor, NewColors.background);
        expect(t.colorScheme.primary, NewColors.accent);
        expect(t.colorScheme.onPrimary, NewColors.onAccent);
        final dialog = t.dialogTheme.shape! as RoundedRectangleBorder;
        expect(dialog.borderRadius, AppRadii.all(AppRadii.dialog));
        final menu = t.popupMenuTheme.shape! as RoundedRectangleBorder;
        expect(menu.borderRadius, AppRadii.all(AppRadii.popup));
        final button =
            t.filledButtonTheme.style!.shape!.resolve({})!
                as RoundedRectangleBorder;
        expect(button.borderRadius, AppRadii.all(AppRadii.sm));
        expect(
          t.filledButtonTheme.style!.minimumSize!.resolve({})!.height,
          AppSizes.control,
        );
      });
    }

    test('both themes keep the steel-blue identity and readable accents', () {
      double ratio(Color a, Color c) {
        final la = a.computeLuminance(), lb = c.computeLuminance();
        return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
      }

      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        AppColors.mode = mode;
        final hsv = HSVColor.fromColor(NewColors.accent);
        expect(hsv.hue, inInclusiveRange(195, 215), reason: mode.name);
        expect(
          ratio(NewColors.onAccent, NewColors.accent),
          greaterThanOrEqualTo(4.5),
          reason: '${mode.name}: text on filled buttons',
        );
      }
    });
  });
}
