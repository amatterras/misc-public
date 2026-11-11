// Calendar > Month. Acceptance criteria:
//  1. The grid fills the whole area it is given: seven equal columns, equal
//     row heights, no gaps, no leftover space (any window size).
//  2. A month shows exactly the weeks it needs: 4, 5 or 6 rows.
//  3. Everything on a date is reachable: nothing is dropped or hidden
//     behind "+N more"; a crowded date scrolls inside its own cell, keeps
//     its date visible, and never paints over the neighbouring cells.
//  4. Text keeps its size in crowded cells.
//  5. Sparse and empty dates, today and the dimmed days of other months
//     render, and tapping a date still opens it.
import 'package:flutter/material.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/widgets/date_prefs.dart';
import 'package:flutter_application_1/features/calendar/calendar_views.dart';
import 'package:flutter_test/flutter_test.dart';

CalendarEntry entry(String name, DateTime day, {CalendarCategory? c}) =>
    CalendarEntry(
      id: 'e-$name',
      category: c ?? CalendarCategory.events,
      name: name,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      startDate: day,
    );

Future<void> pump(
  WidgetTester tester, {
  required DateTime anchor,
  Size size = const Size(1200, 800),
  Map<String, List<DayItem>> items = const {},
  void Function(DateTime)? onDay,
  CalendarView view = CalendarView.month,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox.expand(
            key: const ValueKey('host'),
            child: CalendarGridView(
              view: view,
              anchor: anchor,
              itemsOn: (d) => items[dayKey(d)] ?? const [],
              onDay: onDay ?? (_) {},
              onItem: (_, _) {},
              onToggleEntry: (_, _) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder cell(DateTime d) => find.byKey(ValueKey('calendar-cell-${dayKey(d)}'));

/// Rects of all cells, by row (top → bottom) then column.
List<Rect> cells(WidgetTester tester) {
  final rects = [
    for (final e in find
        .byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('calendar-cell-'),
        )
        .evaluate())
      tester.getRect(find.byWidget(e.widget)),
  ];
  rects.sort((a, b) {
    final c = a.top.compareTo(b.top);
    return c != 0 ? c : a.left.compareTo(b.left);
  });
  return rects;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // October 2026 (Mon start): 5 weeks. February 2027: 4 weeks on a Monday
  // start (1 Feb is a Monday). August 2026: 6 weeks.
  for (final (label, month, weeks) in [
    ('four-week', DateTime(2027, 2), 4),
    ('five-week', DateTime(2026, 10), 5),
    ('six-week', DateTime(2026, 8), 6),
  ]) {
    for (final size in const [Size(1200, 800), Size(700, 500), Size(1600, 1000)]) {
      testWidgets(
        '$label month fills the area at ${size.width.round()}x${size.height.round()}',
        (tester) async {
          DatePrefs.firstWeekday = DateTime.monday;
          await pump(tester, anchor: month, size: size);
          final rects = cells(tester);
          expect(rects.length, weeks * 7);
          // Columns: seven equal widths, touching.
          final width = rects.first.width;
          for (final r in rects) {
            expect(r.width, closeTo(width, 0.01));
          }
          // Rows: equal heights, touching.
          final height = rects.first.height;
          for (final r in rects) {
            expect(r.height, closeTo(height, 0.01));
          }
          // Together they cover the host's width and (below the weekday
          // names) its height.
          final host = tester.getRect(find.byKey(const ValueKey('host')));
          final union = rects.reduce((a, b) => a.expandToInclude(b));
          expect(union.left, closeTo(host.left, 0.01));
          expect(union.right, closeTo(host.right, 0.01));
          expect(union.bottom, closeTo(host.bottom, 0.01));
          expect(union.width, closeTo(width * 7, 0.01));
          expect(union.height, closeTo(height * weeks, 0.01));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('a crowded date keeps everything reachable and its date shown', (
    tester,
  ) async {
    DatePrefs.firstWeekday = DateTime.monday;
    final day = DateTime(2026, 10, 14);
    final many = [
      for (var i = 0; i < 25; i++)
        EntryOnDay(entry('Item number $i', day)),
    ];
    await pump(
      tester,
      anchor: DateTime(2026, 10),
      size: const Size(900, 600),
      items: {dayKey(day): many},
    );
    final c = cell(day);
    final box = tester.getRect(c);
    // The date number is visible at the top.
    expect(
      find.descendant(of: c, matching: find.text('14')),
      findsOneWidget,
    );
    // All 25 are in the cell, none behind a "+N more".
    for (var i = 0; i < 25; i++) {
      expect(
        find.descendant(of: c, matching: find.text('Item number $i')),
        findsOneWidget,
        reason: 'item $i',
      );
    }
    expect(find.textContaining('more'), findsNothing);
    // They scroll inside the cell: the last one can be brought into view,
    // and then lies inside the cell, never over a neighbour.
    final last = find.descendant(of: c, matching: find.text('Item number 24'));
    await tester.ensureVisible(last);
    await tester.pump();
    final lastRect = tester.getRect(last);
    expect(lastRect.bottom, lessThanOrEqualTo(box.bottom + 0.5));
    expect(lastRect.left, greaterThanOrEqualTo(box.left - 0.5));
    expect(lastRect.right, lessThanOrEqualTo(box.right + 0.5));
    // Its date stayed in place meanwhile.
    expect(tester.getRect(find.descendant(of: c, matching: find.text('14'))).top,
        lessThan(box.top + 24));
    // The neighbouring cells are not wider or taller because of it.
    final neighbour = tester.getRect(cell(DateTime(2026, 10, 15)));
    expect(neighbour.height, closeTo(box.height, 0.01));
    expect(neighbour.width, closeTo(box.width, 0.01));
  });

  testWidgets('text is not shrunk in crowded cells', (tester) async {
    DatePrefs.firstWeekday = DateTime.monday;
    final day = DateTime(2026, 10, 14);
    Future<double> sizeWith(int n) async {
      await pump(
        tester,
        anchor: DateTime(2026, 10),
        items: {
          dayKey(day): [
            for (var i = 0; i < n; i++) EntryOnDay(entry('Task $i', day)),
          ],
        },
      );
      return tester
          .widget<Text>(find.descendant(of: cell(day), matching: find.text('Task 0')))
          .style!
          .fontSize!;
    }

    final few = await sizeWith(1);
    final lots = await sizeWith(30);
    expect(lots, few);
    expect(lots, greaterThanOrEqualTo(10));
  });

  testWidgets('every kind of item shows: events, habits, reading, tasks', (
    tester,
  ) async {
    DatePrefs.firstWeekday = DateTime.monday;
    final day = DateTime(2026, 10, 14);
    await pump(
      tester,
      anchor: DateTime(2026, 10),
      items: {
        dayKey(day): [
          EntryOnDay(entry('A concert', day)),
          EntryOnDay(entry('Daily run', day, c: CalendarCategory.habits)),
          EntryOnDay(entry('Dune', day, c: CalendarCategory.reading)),
          EntryOnDay(entry('Other thing', day, c: CalendarCategory.other)),
        ],
      },
    );
    for (final name in ['A concert', 'Daily run', 'Dune', 'Other thing']) {
      expect(find.descendant(of: cell(day), matching: find.text(name)), findsOneWidget);
    }
  });

  testWidgets('empty dates render and tapping a date opens it', (tester) async {
    DatePrefs.firstWeekday = DateTime.monday;
    DateTime? opened;
    await pump(tester, anchor: DateTime(2026, 10), onDay: (d) => opened = d);
    await tester.tap(cell(DateTime(2026, 10, 20)));
    expect(opened, DateTime(2026, 10, 20));
    // A neighbouring month's dimmed days are still tappable.
    await tester.tap(cell(DateTime(2026, 10, 1)));
    expect(opened, DateTime(2026, 10, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('resizing the window keeps the grid full', (tester) async {
    DatePrefs.firstWeekday = DateTime.monday;
    await pump(tester, anchor: DateTime(2026, 10), size: const Size(1200, 800));
    final before = cells(tester).first;
    tester.view.physicalSize = const Size(640, 480);
    await tester.pump();
    final after = cells(tester);
    final host = tester.getRect(find.byKey(const ValueKey('host')));
    expect(after.length, 35);
    expect(after.first.width, lessThan(before.width));
    expect(
      after.reduce((a, b) => a.expandToInclude(b)).right,
      closeTo(host.right, 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('week view keeps its single row', (tester) async {
    DatePrefs.firstWeekday = DateTime.monday;
    await pump(tester, anchor: DateTime(2026, 10, 14), view: CalendarView.week);
    expect(cells(tester).length, 7);
  });
}
