// Hybrid logical clock for revision stamps. Pure Dart (used by the hub too).

/// Revision stamps for sync, from a hybrid logical clock.
///
/// A stamp looks like `0001792345678901-0003-dk3j9x2a`: UTC milliseconds,
/// a counter, and the device that made the change. Stamps sort correctly as
/// plain strings, never go backwards on one device (even if its clock is
/// wrong or changes), and two devices can never produce the same stamp.
/// When the same record changed on two devices, the higher stamp wins.
class SyncClock {
  SyncClock({this.deviceId = 'local', int Function()? wallClock})
    : _wall =
          wallClock ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  String deviceId;
  final int Function() _wall;
  int _millis = 0;
  int _counter = 0;

  /// A new stamp, later than every stamp this clock has produced or seen.
  String now() {
    final wall = _wall();
    if (wall > _millis) {
      _millis = wall;
      _counter = 0;
    } else {
      _counter++;
    }
    return format(_millis, _counter, deviceId);
  }

  /// Moves the clock past [stamp] (e.g. one loaded from disk or received
  /// from another device), so later local edits always sort after it.
  void observe(String? stamp) {
    if (stamp == null) return;
    final parsed = parse(stamp);
    if (parsed == null) return;
    if (parsed.$1 > _millis || (parsed.$1 == _millis && parsed.$2 > _counter)) {
      _millis = parsed.$1;
      _counter = parsed.$2;
    }
  }

  /// The stamp an old record gets when it is first given a revision: its
  /// last edit time, counter 0, this device.
  String stampAt(DateTime time) =>
      format(time.toUtc().millisecondsSinceEpoch, 0, deviceId);

  static String format(int millis, int counter, String device) =>
      '${millis.toString().padLeft(16, '0')}-'
      '${counter.toString().padLeft(4, '0')}-$device';

  static (int, int, String)? parse(String stamp) {
    final parts = stamp.split('-');
    // Exactly the stamp form (16-digit time, 4-digit counter). An ISO date
    // such as "2026-08-30T09:00:00Z" also splits on "-" into numbers, and
    // was once taken for a stamp: old tombstones then never got converted
    // and the hub refused them ("Invalid revision"), blocking the push.
    if (parts.length < 3 || parts[0].length != 16 || parts[1].length != 4) {
      return null;
    }
    final millis = int.tryParse(parts[0]);
    final counter = int.tryParse(parts[1]);
    if (millis == null || counter == null) return null;
    return (millis, counter, parts.sublist(2).join('-'));
  }

  /// Older tombstones were plain ISO dates; turn them into stamps.
  String normalize(String value) {
    if (parse(value) != null) return value;
    final date = DateTime.tryParse(value);
    return date == null ? now() : stampAt(date);
  }
}
