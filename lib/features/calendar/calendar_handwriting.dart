import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/models/canvas_models.dart';
import '../../data/models/record.dart';
import '../../features/canvas/canvas_controller.dart';
import '../../features/canvas/canvas_painter.dart';
import '../../platform/file_protection.dart';
import '../../platform/ios_bridge.dart';
import 'calendar_ink.dart';
import 'windows_ink_ocr.dart';

/// OCR-only rendering scale. The stored strokes are not changed.
const calendarOcrScale = 3.0;

/// Makes a high-contrast image of the strokes in one calendar cell.
///
/// Ink is recolored only in this temporary OCR rendering so pale ink remains
/// legible to system OCR. No document record, stroke, or saved color changes.
Future<Uint8List> renderCalendarInkForOcr(
  CanvasController source,
  DateTime day, {
  double scale = calendarOcrScale,
}) async {
  if (!scale.isFinite || scale <= 0 || scale > 6) {
    throw ArgumentError.value(scale, 'scale', 'Must be in (0, 6].');
  }
  final rect = inkDayRect(day);
  final strokes = [
    for (final item in source.items)
      if (item is StrokeItem && item.bounds.overlaps(rect))
        item.recolored(Colors.black),
  ];
  final scratch = CanvasController(
    document: CanvasDocument(
      id: 'calendar-ocr',
      title: 'Calendar OCR',
      items: strokes,
      updatedAt: DateTime.now(),
      kind: 'calendarInk',
    ),
    onSave: (_) async {},
  );
  final size = Size(rect.width * scale, rect.height * scale);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  CanvasPainter(scratch, page: rect, pageScale: scale).paint(canvas, size);
  scratch.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.ceil(), size.height.ceil());
  picture.dispose();
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Could not encode calendar ink image.');
    return Uint8List.fromList(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}

/// Runs the platform's on-device OCR engine against the selected calendar
/// cell. Production Windows uses Windows Ink handwriting recognition; iOS
/// uses the on-device Vision framework. [imageRecognizer] is injectable for
/// raster-bridge tests and alternate native recognizers.
Future<String?> recognizeCalendarInk({
  required CanvasController controller,
  required DateTime day,
  IosBridge? ios,
  Future<String> Function(String path)? imageRecognizer,
  Future<String> Function(Iterable<StrokeItem> strokes, Rect dayRect)?
  windowsInkRecognizer,
}) async {
  final rect = inkDayRect(day);
  final strokes = [
    for (final item in controller.items)
      if (item is StrokeItem && item.bounds.overlaps(rect)) item,
  ];
  if (strokes.isEmpty) {
    return '';
  }
  if (ios == null &&
      imageRecognizer == null &&
      windowsInkRecognizer == null &&
      !WindowsInkOcr.available) {
    return null;
  }
  if (ios == null && imageRecognizer == null) {
    final recognize = windowsInkRecognizer ?? WindowsInkOcr.recognize;
    return recognize(strokes, rect);
  }

  final bytes = await renderCalendarInkForOcr(controller, day);
  final dir = await Directory.systemTemp.createTemp('theapp-calendar-ocr-');
  try {
    final image = File('${dir.path}${Platform.pathSeparator}ink.png');
    await image.writeAsBytes(bytes, flush: true);
    await FileProtection.protect([image.path]);
    if (ios != null) return await ios.ocrImage(image.path);
    return await imageRecognizer!(image.path);
  } finally {
    await dir.delete(recursive: true).catchError((_) => dir);
  }
}

/// Conservative, editable defaults extracted from native OCR text.
class CalendarHandwritingSuggestion {
  const CalendarHandwritingSuggestion({
    required this.title,
    required this.day,
    required this.startMinutes,
    required this.durationMinutes,
    required this.endDayOffset,
    required this.notes,
    required this.dateRecognized,
    required this.dateWarning,
  });

  final String title;
  final DateTime day;
  final int? startMinutes;
  final int? durationMinutes;
  final int endDayOffset;
  final String notes;
  final bool dateRecognized;
  final String? dateWarning;
}

CalendarHandwritingSuggestion suggestCalendarEvent(
  String text,
  DateTime selectedDay,
) {
  final lines = text
      .split(RegExp(r'[\r\n]+'))
      .map(
        (line) => line
            .trim()
            .replaceFirst(RegExp(r'^[*\-\s]+'), '')
            .replaceFirst('\u2022', '')
            .trim(),
      )
      .where((line) => line.isNotEmpty)
      .toList();
  var day = dateOnly(selectedDay);
  var dateRecognized = false;
  String? dateWarning;
  int? minutes;
  int? duration;
  var endDayOffset = 0;
  final remaining = <String>[];

  for (final line in lines) {
    final parsed = _readDate(line, selectedDay);
    var remainingLine = line;
    if (parsed != null || _dateTokenPattern.hasMatch(line)) {
      if (parsed != null) {
        day = parsed;
        dateRecognized = true;
      } else {
        dateWarning = 'The written date is ambiguous or invalid. Confirm it.';
      }
      remainingLine = line.replaceFirst(_dateTokenPattern, '').trim();
    }

    final range = _timeRangePattern.firstMatch(remainingLine);
    if (range != null && minutes == null) {
      final start = _readTime(range.group(1)!);
      final end = _readTime(range.group(2)!);
      if (start != null && end != null && start != end) {
        minutes = start;
        if (end > start) {
          duration = end - start;
        } else {
          duration = 24 * 60 - start + end;
          endDayOffset = 1;
        }
      }
      remainingLine = remainingLine.replaceRange(range.start, range.end, ' ');
    } else {
      final time = _readTime(remainingLine);
      if (time != null) {
        minutes ??= time;
        remainingLine = remainingLine.replaceFirst(_timePattern, ' ');
      }
    }

    final durationMatch = _durationPattern.firstMatch(remainingLine);
    if (durationMatch != null) {
      final value = int.tryParse(durationMatch.group(1)!);
      final unit = durationMatch.group(2)!.toLowerCase();
      final parsedDuration = value == null
          ? null
          : (unit.startsWith('h') || unit == 'saat' ? value * 60 : value);
      if (duration == null &&
          parsedDuration != null &&
          parsedDuration > 0 &&
          parsedDuration <= 24 * 60) {
        duration = parsedDuration;
      }
      remainingLine = remainingLine.replaceRange(
        durationMatch.start,
        durationMatch.end,
        ' ',
      );
    }
    remainingLine = remainingLine
        .replaceAll(
          RegExp(r'\b(?:at|on|from|to|until)\b', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s,;:.-]+|[\s,;:.-]+$'), '')
        .trim();
    if (remainingLine.isNotEmpty) remaining.add(remainingLine);
  }
  return CalendarHandwritingSuggestion(
    title: remaining.isEmpty ? '' : remaining.first,
    day: day,
    startMinutes: minutes,
    durationMinutes: duration,
    endDayOffset: endDayOffset,
    notes: remaining.length < 2 ? '' : remaining.skip(1).join('\n'),
    dateRecognized: dateRecognized,
    dateWarning: dateWarning,
  );
}

const _timeToken = r'(\d{1,2}:\d{2}\s*(?:am|pm)?)';
final _timeRangePattern = RegExp(
  '$_timeToken\\s*(?:-|–|to|until)\\s*$_timeToken',
  caseSensitive: false,
);
final _timePattern = RegExp(
  r'\b(\d{1,2}):(\d{2})\s*(am|pm)?\b',
  caseSensitive: false,
);
final _durationPattern = RegExp(
  r'\b(\d{1,4})\s*(minutes?|mins?|m|hours?|hrs?|h|dakika|dk|saat)\b',
  caseSensitive: false,
);

int? _readTime(String text) {
  final match = _timePattern.firstMatch(text);
  if (match == null) return null;
  var hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  final period = match.group(3)?.toLowerCase();
  if (minute > 59) return null;
  if (period != null) {
    if (hour < 1 || hour > 12) return null;
    hour = (hour % 12) + (period == 'pm' ? 12 : 0);
  } else if (hour > 23) {
    return null;
  }
  return hour * 60 + minute;
}

/// Parses an explicit 24-hour time or an OCR-detected AM/PM time.
int? parseCalendarHandwritingTime(String text) => _readTime(text.trim());

/// Converts a written duration to minutes only when it is explicit and sane.
int? parseCalendarHandwritingDuration(String text) {
  final match = _durationPattern.firstMatch(text.trim());
  if (match == null) return null;
  final value = int.tryParse(match.group(1)!);
  if (value == null || value < 1) return null;
  final unit = match.group(2)!.toLowerCase();
  final minutes = unit.startsWith('h') || unit == 'saat' ? value * 60 : value;
  return minutes <= 24 * 60 ? minutes : null;
}

DateTime? _readDate(String text, DateTime contextDay) {
  final relative = _relativeDatePattern.firstMatch(text);
  if (relative != null) {
    final phrase = relative
        .group(0)!
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    final base = dateOnly(contextDay);
    if (phrase == 'today' || phrase == 'tonight' || phrase == 'bugün') {
      return base;
    }
    if (phrase == 'tomorrow' || phrase == 'yarın') {
      return _addCalendarDays(base, 1);
    }
    if (phrase == 'day after tomorrow' ||
        phrase == 'öbür gün' ||
        phrase == 'öbürgün') {
      return _addCalendarDays(base, 2);
    }
    final weekdayNames = <String, int>{
      'monday': DateTime.monday,
      'tuesday': DateTime.tuesday,
      'wednesday': DateTime.wednesday,
      'thursday': DateTime.thursday,
      'friday': DateTime.friday,
      'saturday': DateTime.saturday,
      'sunday': DateTime.sunday,
      'pazartesi': DateTime.monday,
      'salı': DateTime.tuesday,
      'çarşamba': DateTime.wednesday,
      'perşembe': DateTime.thursday,
      'cuma': DateTime.friday,
      'cumartesi': DateTime.saturday,
      'pazar': DateTime.sunday,
    };
    final weekday =
        weekdayNames[phrase.replaceFirst(RegExp(r'^(next|gelecek) '), '')];
    if (weekday != null) {
      var offset = (weekday - base.weekday + 7) % 7;
      if (offset == 0 ||
          phrase.startsWith('next ') ||
          phrase.startsWith('gelecek ')) {
        offset = offset == 0 ? 7 : offset;
      }
      return _addCalendarDays(base, offset);
    }
    return null;
  }

  final iso = RegExp(r'\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b')
      .firstMatch(text);
  if (iso != null) {
    return _validDate(iso.group(1)!, iso.group(2)!, iso.group(3)!);
  }

  final dotted = RegExp(r'\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b').firstMatch(text);
  if (dotted != null) {
    return _validDate(dotted.group(3)!, dotted.group(2)!, dotted.group(1)!);
  }

  final numeric = RegExp(r'\b(\d{1,2})/(\d{1,2})/(\d{4})\b').firstMatch(text);
  if (numeric != null) {
    final a = int.parse(numeric.group(1)!);
    final b = int.parse(numeric.group(2)!);
    if (a <= 12 && b <= 12) return null; // ambiguous locale ordering
    final month = a > 12 ? b : a;
    final date = a > 12 ? a : b;
    return _validDate(numeric.group(3)!, '$month', '$date');
  }

  final monthNames = <String, int>{
    for (final (index, name) in const [
      'january',
      'february',
      'march',
      'april',
      'may',
      'june',
      'july',
      'august',
      'september',
      'october',
      'november',
      'december',
    ].indexed)
      name: index + 1,
  };
  final named = RegExp(
    r'\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2}),?\s+(\d{4})\b',
    caseSensitive: false,
  ).firstMatch(text);
  if (named == null) return null;
  return _validDate(
    named.group(3)!,
    '${monthNames[named.group(1)!.toLowerCase()]}',
    named.group(2)!,
  );
}

DateTime _addCalendarDays(DateTime day, int count) =>
    DateTime(day.year, day.month, day.day + count);

final _relativeDatePattern = RegExp(
  r'\b(?:day after tomorrow|tomorrow|today|tonight|next (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|öbür gün|öbürgün|yarın|bugün|gelecek (?:pazartesi|salı|çarşamba|perşembe|cuma|cumartesi|pazar))\b',
  caseSensitive: false,
);

final _dateTokenPattern = RegExp(
  r'\b(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[./]\d{1,2}[./]\d{4}|\d{1,2}/\d{1,2}/\d{4}|(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2},?\s+\d{4}|day after tomorrow|tomorrow|today|tonight|next (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|öbür gün|öbürgün|yarın|bugün|gelecek (?:pazartesi|salı|çarşamba|perşembe|cuma|cumartesi|pazar))\b',
  caseSensitive: false,
);

DateTime? _validDate(String y, String m, String d) {
  final year = int.tryParse(y), month = int.tryParse(m), day = int.tryParse(d);
  if (year == null || month == null || day == null) return null;
  final value = DateTime(year, month, day);
  if (value.year != year || value.month != month || value.day != day) {
    return null;
  }
  return value;
}
