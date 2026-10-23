// Every page, at common window sizes (and the phone-width layout), must lay
// out without overflow errors. Uses a real temporary data folder.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/settings/settings_dialog.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

void main() {
  const sizes = [
    Size(1600, 1000),
    Size(1280, 720),
    Size(1000, 700),
    Size(800, 600),
    Size(390, 844), // phone width: compact layout
    Size(820, 1180), // iPad Air portrait
    Size(1180, 820), // iPad Air landscape
    Size(844, 390), // iPhone landscape
  ];

  for (final size in sizes) {
    testWidgets(
      'all pages lay out at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final errors = <String>[];
        var where = 'start';
        final previous = FlutterError.onError;
        FlutterError.onError = (d) {
          // Name the widget responsible (file and line), not just the symptom.
          final origin = RegExp(r'lib/[\w/]+\.dart:\d+')
              .firstMatch(d.toString())
              ?.group(0);
          errors.add(
            '$where: ${d.exceptionAsString().split('\n').first} (${origin ?? '?'})',
          );
        };

        final dir = Directory.systemTemp.createTempSync('theapp_layout_');
        addTearDown(() {
          try {
            dir.deleteSync(recursive: true);
          } catch (_) {}
        });
        final ws = Workspace(dir);
        final state = AppState(
          canvases: FileCanvasRepository(ws.store),
          settings: SettingsRepository(ws.store),
          workspace: ws,
          enableSendTo: false,
        );
        await tester.runAsync(state.init);
        await tester.pumpWidget(TheApp(state: state));
        await tester.pump();

        // A task with a long date and a reminder, so the task panel is
        // laid out too (it once overflowed in narrow windows).
        final task = state.workspace.createTask(
          'Revise organic chemistry before the mock exam',
          dueDate: DateTime(2026, 9, 30),
        );
        for (final page in AppPage.values) {
          where = page.name;
          if (page == AppPage.tasks) {
            state.openTask(task.id);
          } else {
            state.goTo(page);
          }
          await tester.pump();
          await tester.pump();
        }
        where = 'settings';
        final context = tester.element(find.byType(Scaffold).first);
        showSettingsDialog(context, state);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        await waitForBothClocks(tester, state.flush, what: 'Saving');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 4));
        state.dispose();
        FlutterError.onError = previous;
        expect(errors, isEmpty, reason: 'at $size');
      },
    );
  }
}
