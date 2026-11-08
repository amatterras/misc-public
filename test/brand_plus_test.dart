// The "+" on the phone and the Quick Add button on iPad/Windows are one
// widget (BrandPlus), so their gradient, glow and icon cannot drift apart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/shell.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/motivation/motivation_service.dart';
import 'package:flutter_application_1/new_ui/new_components.dart';
import 'package:flutter_application_1/phone/phone_profile.dart';
import 'package:flutter_test/flutter_test.dart';

final _motivations = <AppState, MotivationService>{};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String quotes;
  late String greetings;
  setUpAll(() async {
    quotes = await rootBundle.loadString('assets/motivation/quotes.json');
    greetings = await rootBundle.loadString('assets/motivation/greetings.json');
  });
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_plus_'));
  tearDown(() {
    PhoneProfile.forced = false;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> open(
    WidgetTester tester, {
    required Size size,
    required bool phone,
    String theme = 'dark',
  }) async {
    PhoneProfile.forced = phone;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
    await tester.runAsync(() async {
      await state.init();
      await state.setThemeMode(theme);
    });
    final motivation = MotivationService(
      nextIndex: (_) => 0,
      greetingDismissed: true,
    )..loadFromSources(quotes, greetings);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: theme == 'light' ? Brightness.light : Brightness.dark,
        ),
        home: AppShell(state: state, motivation: motivation),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    _motivations[state] = motivation;
    return state;
  }

  BoxDecoration decorationOf(WidgetTester tester, Finder button) {
    final plus = find.descendant(of: button, matching: find.byType(BrandPlus));
    expect(plus, findsOneWidget);
    final box = tester.widget<AnimatedContainer>(
      find.descendant(of: plus, matching: find.byType(AnimatedContainer)),
    );
    return box.decoration! as BoxDecoration;
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    _motivations.remove(state)?.dispose();
    await tester.runAsync(state.flush);
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  }

  for (final theme in ['dark', 'light']) {
    testWidgets('phone "+" and iPad Quick Add look the same ($theme)', (
      tester,
    ) async {
      final p = await open(
        tester,
        size: const Size(390, 844),
        phone: true,
        theme: theme,
      );
      final phone = decorationOf(
        tester,
        find.byKey(const ValueKey('phone-new')),
      );
      expect(phone.gradient, AppGradients.brand);
      expect(phone.borderRadius, BorderRadius.circular(AppRadii.capsule));
      expect(phone.boxShadow!.single.color.a, closeTo(0.28, 0.01));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('phone-new')),
          matching: find.byIcon(Icons.add),
        ),
        findsOneWidget,
      );
      await close(tester, p);

      final pad = await open(
        tester,
        size: const Size(1280, 900),
        phone: false,
        theme: theme,
      );
      final wide = decorationOf(
        tester,
        find.byKey(const ValueKey('new-quick-add')),
      );
      expect(wide.gradient, phone.gradient);
      expect(wide.borderRadius, phone.borderRadius);
      expect(wide.boxShadow!.single.color, phone.boxShadow!.single.color);
      expect(
        wide.boxShadow!.single.blurRadius,
        phone.boxShadow!.single.blurRadius,
      );
      await close(tester, pad);
    });
  }

  testWidgets('the phone "+" still opens the same New menu', (tester) async {
    final state = await open(tester, size: const Size(390, 844), phone: true);
    await tester.tap(find.byKey(const ValueKey('phone-new')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.byType(BottomSheet), findsOneWidget);
    await close(tester, state);
  });
}
