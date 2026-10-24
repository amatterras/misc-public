import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/entry_editor.dart';
import 'package:flutter_application_1/features/calendar/reading_goal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reading goal projection', () {
    final today = DateTime(2026, 10, 24);

    test('uses ceiling division and counts today as the first session', () {
      final result = estimateReadingGoal(
        totalPages: 100,
        currentPage: 33,
        pagesPerDay: 20,
        startDate: DateTime(2026, 10, 1),
        today: today,
      );

      expect(result.pagesRemaining, 67);
      expect(result.daysRemaining, 4);
      expect(result.completionDate, DateTime(2026, 10, 27));
    });

    test('a future start date moves the projected finish date', () {
      final result = estimateReadingGoal(
        totalPages: 100,
        currentPage: 33,
        pagesPerDay: 20,
        startDate: DateTime(2026, 10, 27),
        today: today,
      );

      expect(result.daysRemaining, 4);
      expect(result.completionDate, DateTime(2026, 10, 30));
    });

    test('completed goals have no future completion date', () {
      final result = estimateReadingGoal(
        totalPages: 100,
        currentPage: 100,
        pagesPerDay: 20,
        startDate: today,
        today: today,
      );

      expect(result.isComplete, isTrue);
      expect(result.daysRemaining, 0);
      expect(result.completionDate, isNull);
    });

    test('rejects invalid targets and progress', () {
      expect(
        () => estimateReadingGoal(
          totalPages: 100,
          currentPage: 0,
          pagesPerDay: 0,
          startDate: today,
          today: today,
        ),
        throwsArgumentError,
      );
      expect(
        () => estimateReadingGoal(
          totalPages: 100,
          currentPage: 101,
          pagesPerDay: 20,
          startDate: today,
          today: today,
        ),
        throwsArgumentError,
      );
      expect(
        () => estimateReadingGoal(
          totalPages: 0,
          currentPage: 0,
          pagesPerDay: 20,
          startDate: today,
          today: today,
        ),
        throwsArgumentError,
      );
    });
  });

  group('persisted reading goals', () {
    final now = DateTime(2026, 10, 24, 10, 30);

    test('goal fields survive JSON storage and can be explicitly cleared', () {
      final entry = CalendarEntry(
        id: 'book-1',
        category: CalendarCategory.reading,
        name: 'Dune',
        createdAt: now,
        updatedAt: now,
        totalPages: 500,
        currentPage: 125,
        targetPagesPerDay: 25,
        goalStartDate: DateTime(2026, 10, 20, 18),
      );

      final restored = CalendarEntry.fromJson(entry.toJson());
      expect(restored.targetPagesPerDay, 25);
      expect(restored.goalStartDate, DateTime(2026, 10, 20));
      expect(
        restored
            .copyWith(targetPagesPerDay: () => null, goalStartDate: () => null)
            .targetPagesPerDay,
        isNull,
      );
      expect(
        restored.copyWith(goalStartDate: () => null).goalStartDate,
        isNull,
      );
    });

    test('older records without goal fields remain readable', () {
      final old =
          CalendarEntry(
              id: 'old-book',
              category: CalendarCategory.reading,
              name: 'Old book',
              createdAt: now,
              updatedAt: now,
            ).toJson()
            ..remove('targetPagesPerDay')
            ..remove('goalStartDate');

      final restored = CalendarEntry.fromJson(old);
      expect(restored.targetPagesPerDay, isNull);
      expect(restored.goalStartDate, isNull);
    });
  });

  testWidgets('editor recalculates and saves a reading goal', (tester) async {
    tester.view.physicalSize = const Size(1700, 1050);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final temp = Directory.systemTemp.createTempSync('theapp_reading_goal_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    final ws = Workspace(Directory('${temp.path}/data'));
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    state.capture.fetchPreviews = false;
    await tester.runAsync(state.init);
    addTearDown(() {
      state.dispose();
    });

    final today = dateOnly(DateTime.now());
    final book = CalendarEntry(
      id: 'editor-book',
      category: CalendarCategory.reading,
      name: 'Dune',
      createdAt: today,
      updatedAt: today,
      totalPages: 100,
      currentPage: 40,
      targetPagesPerDay: 20,
      goalStartDate: today,
    );
    ws.saveEntry(book);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showEntryEditor(context, state, entry: book),
                child: const Text('Edit book'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit book'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('60 pages left · 3 days · finish'),
      findsOneWidget,
    );

    final currentPage = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == 'Current page',
    );
    await tester.enterText(currentPage, '80');
    await tester.pump();
    expect(
      find.textContaining('20 pages left · 1 day · finish'),
      findsOneWidget,
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(ws.entries[book.id]!.currentPage, 80);
    expect(ws.entries[book.id]!.targetPagesPerDay, 20);
    await tester.runAsync(state.flush);
  });
}
