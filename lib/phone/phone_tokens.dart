// Type, spacing and small helpers of the iPhone interface.
//
// The colours are NOT new: everything comes from AppColors (graphite and
// steel blue in the dark theme, porcelain and iris in the light one, with the
// periwinkle→coral brand gradient). What the phone adds is a stricter way of
// using them: no cards and no filled containers, content set directly on the
// page, divided by hairlines, with one gradient moment per screen.
import 'package:flutter/material.dart';

import '../app/theme.dart';

abstract final class PhoneSpace {
  /// Left and right margin of all content.
  static const margin = 20.0;

  /// Width of the time column in agenda rows.
  static const timeColumn = 52.0;

  static const dockHeight = 58.0;
}

const _tabular = [FontFeature.tabularFigures()];

abstract final class PhoneType {
  /// Screen titles: "3 November", "Notes".
  static TextStyle get display => TextStyle(
    fontSize: 36,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.3,
    height: 1.02,
    color: AppColors.text,
  );

  /// Section titles inside a screen, pushed page titles.
  static TextStyle get title => TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    height: 1.15,
    color: AppColors.text,
  );

  /// The main line of a row.
  static TextStyle get row => TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.25,
    color: AppColors.text,
  );

  static TextStyle get body => TextStyle(
    fontSize: 15,
    height: 1.4,
    letterSpacing: -0.1,
    color: AppColors.textMuted,
  );

  static TextStyle get meta => TextStyle(
    fontSize: AppType.sizeBodySmall,
    height: 1.3,
    letterSpacing: 0,
    color: AppColors.textFaint,
  );

  /// Small capitals above things: "OVERDUE", "TUESDAY".
  static TextStyle get eyebrow => TextStyle(
    fontSize: AppType.sizeMeta,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.5,
    height: 1.2,
    color: AppColors.textFaint,
  );

  /// Clock times and counts: digits keep their width.
  static TextStyle get time => TextStyle(
    fontSize: AppType.sizeBodySmall,
    fontWeight: FontWeight.w500,
    height: 1.25,
    letterSpacing: 0.1,
    color: AppColors.textMuted,
    fontFeatures: _tabular,
  );

  /// The dock labels.
  static TextStyle get dock => const TextStyle(
    fontSize: AppType.sizeBodySmall,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.1,
  );

  static TextStyle get numeral => TextStyle(
    fontSize: AppType.sizeHeading,
    fontWeight: FontWeight.w500,
    height: 1.1,
    color: AppColors.text,
    fontFeatures: _tabular,
  );
}

/// Content of a note or an item cut to one readable excerpt.
String excerpt(String text, {int max = 180}) {
  final flat = text
      .replaceAll(RegExp(r'[#*_>`~]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return flat.length <= max ? flat : '${flat.substring(0, max).trimRight()}…';
}

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String monthName(int month) => _monthNames[month - 1];
String weekdayName(int weekday) => _weekdayNames[weekday - 1];

/// "Today", "Yesterday", "Mon", "12 Oct" or "12 Oct 2025" for a past date.
String relativeDay(DateTime when, {DateTime? now}) {
  final today = DateTime(
    (now ?? DateTime.now()).year,
    (now ?? DateTime.now()).month,
    (now ?? DateTime.now()).day,
  );
  final d = DateTime(when.year, when.month, when.day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return weekdayName(d.weekday).substring(0, 3);
  final short = '${d.day} ${monthName(d.month).substring(0, 3)}';
  return d.year == today.year ? short : '$short ${d.year}';
}
