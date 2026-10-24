// Calendar pen thickness: the setting is kept on this device and limited,
// each stroke keeps the width it was drawn with (through undo, redo and a
// restart), and the dialog previews the width live.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_ink.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_pen_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> app() async {
    final ws = Workspace(dir);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await s.init();
    return s;
  }

  void draw(CanvasController c, double x) {
    c.setView(Offset.zero, 1);
    c.pointerDown(Offset(x, 20));
    for (var i = 1; i <= 6; i++) {
      c.pointerMove(Offset(x + i * 8, 20 + i * 4));
    }
    c.pointerUp();
  }

  List<double> widths(CanvasController c) => [
    for (final s in c.items.whereType<StrokeItem>()) s.strokeWidth,
  ];

  test('thickness is remembered, limited, and kept per stroke', () async {
    var s = await app();
    var ink = await s.openCalendarInk();
    expect(ink.penWidth, 2.5); // default
    draw(ink, 10);
    await s.setCalendarPenWidth(8);
    expect(ink.penWidth, 8);
    draw(ink, 100);
    expect(widths(ink), [2.5, 8]);

    ink.undo();
    expect(widths(ink), [2.5]); // the old stroke keeps its width
    ink.redo();
    expect(widths(ink), [2.5, 8]);

    await s.setCalendarPenWidth(500);
    expect(s.calendarPenWidth, AppState.calendarPenMax);
    await s.setCalendarPenWidth(0);
    expect(s.calendarPenWidth, AppState.calendarPenMin);
    await s.setCalendarPenWidth(6);
    await s.flush();
    s.dispose();

    s = await app();
    ink = await s.openCalendarInk();
    expect(ink.penWidth, 6);
    expect(widths(ink), [2.5, 8]);
    await s.flush();
    s.dispose();
  });

  test('a whole number saved by another version still reads', () async {
    final s = await app();
    await s.settings.set('calendarPenWidth', 4);
    expect(s.calendarPenWidth, 4.0);
    await s.settings.set('calendarPenWidth', 'thick');
    expect(s.calendarPenWidth, 2.5);
    await s.flush();
    s.dispose();
  });

  testWidgets('the dialog previews the width live and saves it', (
    tester,
  ) async {
    late AppState s;
    late CanvasController ink;
    await tester.runAsync(() async {
      s = await app();
      ink = await s.openCalendarInk();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPenWidthDialog(context, s, ink),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    PenPreviewPainter preview() =>
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byKey(const ValueKey('pen-width-preview')),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as PenPreviewPainter;
    expect(preview().width, 2.5);

    // Drag the slider to its right end.
    final slider = find.byKey(const ValueKey('pen-width-slider'));
    await tester.drag(slider, const Offset(400, 0));
    await tester.pump();
    expect(ink.penWidth, AppState.calendarPenMax);
    expect(preview().width, AppState.calendarPenMax);
    expect(preview().color, ink.penColor);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(s.settings.get<num>('calendarPenWidth'), AppState.calendarPenMax);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.runAsync(s.flush);
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });
}
