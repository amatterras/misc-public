// The Settings window (category rail + pages), the Data & Storage controls,
// and the New sidebar no longer reserving a full-height column. Temporary
// data folders only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/interface_version.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/settings/settings_dialog.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

Future<AppState> _boot(
  WidgetTester tester,
  Directory dir,
  Size size, {
  bool newInterface = false,
}) async {
  tester.view.physicalSize = size;
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
  if (newInterface) {
    await tester.runAsync(
      () => state.setInterfaceVersion(InterfaceVersion.newDesign),
    );
  }
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
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_settings_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('wide window: a rail of categories, one page at a time', (
    tester,
  ) async {
    final s = await _boot(tester, dir, const Size(1280, 900));
    final context = tester.element(find.byType(Scaffold).first);
    showSettingsDialog(context, s);
    await _settle(tester);

    // The rail lists every category; Appearance is open.
    for (final name in [
      'appearance',
      'calendar',
      'archive',
      'sync',
      'data',
      'privacy',
      'ai',
      'about',
    ]) {
      expect(
        find.byKey(ValueKey('settings-category-$name')),
        findsOneWidget,
        reason: name,
      );
    }
    // Apple Pencil settings exist only on an iPhone/iPad.
    expect(find.byKey(const ValueKey('settings-category-pencil')), findsNothing);
    expect(find.byKey(const ValueKey('settings-page-appearance')), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-mode')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-category-data')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-page-data')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-page-appearance')), findsNothing);
    expect(find.text('Export all data'), findsOneWidget);
    expect(find.text('Import a backup file'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-page-data')), findsNothing);
    await _shutDown(tester, s);
  });

  testWidgets('narrow window: a list that opens each page, with a way back', (
    tester,
  ) async {
    final s = await _boot(tester, dir, const Size(390, 844));
    final context = tester.element(find.byType(Scaffold).first);
    showSettingsDialog(context, s);
    await _settle(tester);

    expect(find.byKey(const ValueKey('settings-page-appearance')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-category-calendar')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-page-calendar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-page-calendar')), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-category-calendar')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _shutDown(tester, s);
  });

  testWidgets('Data & Storage: auto-backup switch, frequency, back up now', (
    tester,
  ) async {
    final s = await _boot(tester, dir, const Size(1280, 900));
    final context = tester.element(find.byType(Scaffold).first);
    showSettingsDialog(context, s, open: SettingsCategory.data);
    await _settle(tester);

    expect(s.autoBackupEnabled, isTrue);
    expect(s.autoBackupFrequency, 'daily');
    await tester.tap(find.byKey(const ValueKey('auto-backup')));
    await _settle(tester);
    expect(s.autoBackupEnabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('auto-backup')));
    await _settle(tester);
    expect(s.autoBackupEnabled, isTrue);

    await waitForBothClocks(
      tester,
      () => s.setAutoBackupFrequency('weekly'),
      what: 'Saving the frequency',
    );
    expect(s.autoBackupFrequency, 'weekly');
    expect(s.autoBackupEvery, const Duration(days: 7));

    final before = await tester.runAsync(() => s.workspace.backups.list());
    await tester.ensureVisible(find.byKey(const ValueKey('backup-now')));
    await tester.tap(find.byKey(const ValueKey('backup-now')));
    // The tap starts a save and a backup (disk work plus timers).
    await waitForBothClocks(tester, () async {
      while ((await s.workspace.backups.list()).length == before!.length) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }, what: 'The backup');
    final after = await tester.runAsync(() => s.workspace.backups.list());
    expect(after!.length, before!.length + 1, reason: '${after.map((d) => d.path)}');
    expect(
      after.any((d) => d.path.endsWith('-manual')),
      isTrue,
      reason: 'the new backup is a manual one: ${after.map((d) => d.path)}',
    );
    expect(find.byKey(const ValueKey('storage-usage')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await _settle(tester);
    await _shutDown(tester, s);
  });

  testWidgets('New: pages keep the full window width (no sidebar column)', (
    tester,
  ) async {
    final s = await _boot(
      tester,
      dir,
      const Size(1280, 900),
      newInterface: true,
    );
    await _settle(tester);
    final viewport = tester.getSize(
      find.byKey(const ValueKey('page-content-viewport')),
    );
    expect(viewport.width, 1280, reason: 'the capsule floats over the page');
    // The capsule itself is narrow and sits at the right edge.
    final capsule = tester.getRect(find.byKey(const ValueKey('new-nav-notes')));
    expect(capsule.center.dx, greaterThan(1280 - 100));
    expect(tester.takeException(), isNull);
    await _shutDown(tester, s);
  });
}
