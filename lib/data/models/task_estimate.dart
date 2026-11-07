// Task time estimates: reading what a person types ("45 min", "1h30",
// "1 hour 30 minutes") and showing a stored estimate ("1 hr 30 min").
// Pure Dart, so it is easy to test.

/// Longest estimate accepted: one week.
const maxEstimateMinutes = 7 * 24 * 60;

final _unit = RegExp(
  r'^(\d+(?:\.\d+)?)\s*(hours|hour|hrs|hr|h|minutes|minute|mins|min|m)?',
);

/// Minutes in [input], or null when it is not a duration.
///
/// Accepts e.g. "15 min", "45 minutes", "1 hour", "1 hour 30 minutes",
/// "1h30", "1h 30m", "2 hours", "1.5 h", "1:30", "90" (a bare number is
/// minutes), "an hour" and "half an hour". Zero, negative and longer than
/// [maxEstimateMinutes] are rejected.
int? parseEstimate(String input) {
  var s = input.trim().toLowerCase().replaceAll(',', '.');
  if (s.isEmpty) return null;
  s = s
      .replaceAll(RegExp(r'\band\b'), ' ')
      .replaceAll(RegExp(r'\bhalf an? hour\b|\bhalf hour\b'), '30 min')
      .replaceAll(RegExp(r'\ban? hour\b'), '1 hour')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  int? valid(num minutes) {
    final m = minutes.round();
    return m >= 1 && m <= maxEstimateMinutes ? m : null;
  }

  final clock = RegExp(r'^(\d{1,3}):([0-5]\d)$').firstMatch(s);
  if (clock != null) {
    return valid(int.parse(clock[1]!) * 60 + int.parse(clock[2]!));
  }
  var total = 0.0;
  var sawHours = false, sawMinutes = false, parts = 0;
  while (s.isNotEmpty) {
    final m = _unit.firstMatch(s);
    if (m == null) return null;
    final value = double.parse(m[1]!);
    final unit = m[2];
    final isHours = unit != null && unit.startsWith('h');
    // A number without a unit is minutes ("90", or the "30" of "1h30").
    if (isHours) {
      if (sawHours || sawMinutes) return null;
      sawHours = true;
      total += value * 60;
    } else {
      if (sawMinutes) return null;
      if (unit == null && parts > 0 && !sawHours) return null;
      sawMinutes = true;
      total += value;
    }
    parts++;
    s = s.substring(m.end).trim();
  }
  return valid(total);
}

/// A stored estimate in short words: "45 min", "1 hr", "1 hr 30 min".
String formatEstimate(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h hr' : '$h hr $m min';
}
