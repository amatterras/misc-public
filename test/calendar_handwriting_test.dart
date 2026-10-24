import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/features/calendar/calendar_handwriting.dart';
import 'package:flutter_application_1/features/calendar/calendar_ink.dart';
import 'package:flutter_application_1/features/calendar/windows_ink_ocr.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('suggestion extracts title, explicit date and time conservatively', () {
    final selected = DateTime(2026, 10, 24);
    final suggestion = suggestCalendarEvent(
      'Project review 2026-10-31 3:45 PM\nBring notes',
      selected,
    );

    expect(suggestion.title, 'Project review');
    expect(suggestion.day, DateTime(2026, 10, 31));
    expect(suggestion.startMinutes, 15 * 60 + 45);
    expect(suggestion.durationMinutes, isNull);
    expect(suggestion.notes, 'Bring notes');
    expect(suggestion.dateRecognized, isTrue);
  });

  test('extracts a written time range and relative date without guessing', () {
    final suggestion = suggestCalendarEvent(
      'Project review tomorrow 15:45-16:30\nBring notes and agenda',
      DateTime(2026, 10, 24),
    );
    expect(suggestion.title, 'Project review');
    expect(suggestion.day, DateTime(2026, 10, 25));
    expect(suggestion.startMinutes, 15 * 60 + 45);
    expect(suggestion.durationMinutes, 45);
    expect(suggestion.endDayOffset, 0);
    expect(suggestion.notes, 'Bring notes and agenda');
    expect(suggestion.dateRecognized, isTrue);
    expect(suggestion.dateWarning, isNull);
  });

  test('range crossing midnight keeps its next-day end explicit', () {
    final suggestion = suggestCalendarEvent(
      'Night shift 23:30-00:15',
      DateTime(2026, 10, 24),
    );
    expect(suggestion.startMinutes, 23 * 60 + 30);
    expect(suggestion.durationMinutes, 45);
    expect(suggestion.endDayOffset, 1);
  });

  test('ambiguous slash date is not guessed and selected day is disclosed', () {
    final selected = DateTime(2026, 10, 24);
    final suggestion = suggestCalendarEvent(
      'Dentist\n04/05/2027\n09:15',
      selected,
    );

    expect(suggestion.title, 'Dentist');
    expect(suggestion.day, selected);
    expect(suggestion.dateRecognized, isFalse);
    expect(suggestion.dateWarning, contains('ambiguous'));
    expect(suggestion.startMinutes, 9 * 60 + 15);
  });

  test('date/time parsers reject impossible values', () {
    expect(
      suggestCalendarEvent('Plan\n2026-02-30\n25:70', DateTime(2026)),
      isA<CalendarHandwritingSuggestion>()
          .having((s) => s.day, 'selected day', DateTime(2026))
          .having((s) => s.dateRecognized, 'date recognized', isFalse)
          .having((s) => s.startMinutes, 'time', isNull),
    );
    expect(parseCalendarHandwritingTime('12:00 AM'), 0);
    expect(parseCalendarHandwritingTime('12:00 PM'), 720);
    expect(parseCalendarHandwritingTime('25:00'), isNull);
    expect(parseCalendarHandwritingDuration('90 minutes'), 90);
    expect(parseCalendarHandwritingDuration('2 hours'), 120);
    expect(parseCalendarHandwritingDuration('3000 minutes'), isNull);
  });

  test('renders only the selected day and passes the PNG to OCR', () async {
    final day = DateTime(2026, 10, 24);
    final rect = inkDayRect(day);
    final controller = CanvasController(
      document: CanvasDocument(
        id: 'calendar-ink',
        title: 'Calendar drawings',
        items: const [],
        updatedAt: day,
        kind: 'calendarInk',
      ),
      onSave: (_) async {},
    );
    controller.addItems([
      StrokeItem(
        id: 'on-day',
        color: const Color(0xfff2d84a),
        strokeWidth: 4,
        points: [
          StrokePoint(rect.left + 20, 40, 0.5),
          StrokePoint(rect.left + 120, 80, 0.5),
        ],
      ),
      StrokeItem(
        id: 'next-day',
        color: Colors.blue,
        strokeWidth: 4,
        points: [
          StrokePoint(rect.right + 20, 40, 0.5),
          StrokePoint(rect.right + 120, 80, 0.5),
        ],
      ),
    ]);
    addTearDown(controller.dispose);

    final png = await renderCalendarInkForOcr(controller, day);
    expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, (inkDaySize.width * calendarOcrScale).ceil());
    expect(frame.image.height, (inkDaySize.height * calendarOcrScale).ceil());
    frame.image.dispose();
    codec.dispose();

    final recognized = await recognizeCalendarInk(
      controller: controller,
      day: day,
      windowsInkRecognizer: (strokes, dayRect) async {
        expect(dayRect, inkDayRect(day));
        expect(strokes.map((stroke) => stroke.id), ['on-day']);
        final payload = WindowsInkOcr.payload(strokes, dayRect);
        final points =
            ((payload['strokes']! as List).single as Map)['points'] as List;
        expect((points.first as List).first, 20.0);
        expect((points.last as List).first, 120.0);
        return 'Appointment\n2026-10-24\n10:30';
      },
    );
    expect(recognized, 'Appointment\n2026-10-24\n10:30');
  });
}
