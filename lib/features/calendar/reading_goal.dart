import '../../data/models/record.dart';

/// A transparent projection for a reading target.
///
/// The schedule assumes one reading session on every calendar day, including
/// weekends. The first projected session is the later of the goal start date
/// and today. Users can change the goal start date, and the UI states this
/// assumption alongside the estimate.
class ReadingGoalEstimate {
  const ReadingGoalEstimate({
    required this.pagesRemaining,
    required this.daysRemaining,
    required this.completionDate,
  });

  final int pagesRemaining;
  final int daysRemaining;
  final DateTime? completionDate;

  bool get isComplete => pagesRemaining == 0;
  String get daysLabel => '$daysRemaining day${daysRemaining == 1 ? '' : 's'}';
}

/// Projects completion using the current progress and a seven-day schedule.
///
/// Throws [ArgumentError] for invalid persisted or user-entered values rather
/// than silently making an impossible goal appear valid.
ReadingGoalEstimate estimateReadingGoal({
  required int totalPages,
  required int currentPage,
  required int pagesPerDay,
  required DateTime startDate,
  required DateTime today,
}) {
  if (totalPages <= 0) {
    throw ArgumentError.value(totalPages, 'totalPages', 'Must be positive.');
  }
  if (currentPage < 0 || currentPage > totalPages) {
    throw ArgumentError.value(
      currentPage,
      'currentPage',
      'Must be between zero and totalPages.',
    );
  }
  if (pagesPerDay <= 0) {
    throw ArgumentError.value(pagesPerDay, 'pagesPerDay', 'Must be positive.');
  }

  final remaining = totalPages - currentPage;
  if (remaining == 0) {
    return const ReadingGoalEstimate(
      pagesRemaining: 0,
      daysRemaining: 0,
      completionDate: null,
    );
  }

  final days = (remaining + pagesPerDay - 1) ~/ pagesPerDay;
  final firstSession = dateOnly(
    daysBetween(startDate, today) > 0 ? today : startDate,
  );
  return ReadingGoalEstimate(
    pagesRemaining: remaining,
    daysRemaining: days,
    completionDate: addDays(firstSession, days - 1),
  );
}
