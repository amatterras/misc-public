/// Base for every stored record outside canvases.
///
/// Each record has a stable [id] and an [updatedAt] timestamp. Together with
/// the tombstones kept by `RecordCollection`, this is what a future sync
/// layer needs to merge changes from several devices (newest edit wins per
/// record) without creating duplicates.
abstract class Record {
  String get id;
  DateTime get updatedAt;
  Map<String, dynamic> toJson();
}

/// Date-only key such as `2026-10-21`, used for calendar days.
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime parseDayKey(String key) {
  final parts = key.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime addDays(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days);

/// Whole days from [a] to [b] (calendar days, DST-safe).
int daysBetween(DateTime a, DateTime b) => DateTime.utc(
  b.year,
  b.month,
  b.day,
).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

/// Reads a stored timestamp (UTC or, in older files, local) as local time.
DateTime? parseDate(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

/// Timestamps are stored in UTC (`...Z`) so every device reads the same
/// instant; they are shown in local time.
String utcIso(DateTime d) => d.toUtc().toIso8601String();
