// The user's date preferences (Calendar settings, kept per device): how
// dates are written and which day starts the week. Separate from the
// local-time rules of greetings and quotes.

/// How short and long dates are written.
enum DateOrder {
  /// "Oct 21", "Wednesday, October 21"
  monthDay,

  /// "21 Oct", "Wednesday, 21 October"
  dayMonth,

  /// "2026-10-21"
  iso,
}

extension DateOrderInfo on DateOrder {
  String get label => switch (this) {
    DateOrder.monthDay => 'Oct 21',
    DateOrder.dayMonth => '21 Oct',
    DateOrder.iso => '2026-10-21',
  };
}

class DatePrefs {
  DatePrefs._();

  static DateOrder order = DateOrder.monthDay;

  /// DateTime.monday … DateTime.sunday.
  static int firstWeekday = DateTime.monday;

  /// The first day (per [firstWeekday]) of the week containing [d].
  static DateTime weekStart(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    final back = (day.weekday - firstWeekday) % 7;
    return DateTime(day.year, day.month, day.day - back);
  }
}
