// What THEapp says when a task is ticked off: understated (default),
// funny, or nothing at all. Shown as a short toast; it never changes the
// task, its reminders or its sync.
import 'dart:math';

enum CompletionStyle { understated, funny, silent }

extension CompletionStyleInfo on CompletionStyle {
  String get label => switch (this) {
    CompletionStyle.understated => 'Understated',
    CompletionStyle.funny => 'Funny',
    CompletionStyle.silent => 'Silent',
  };
}

const _understated = [
  'Done.',
  'Ticked off.',
  'One less thing.',
  'Noted. Finished.',
  'That’s handled.',
];

const _funny = [
  'Look at you, finishing things.',
  'Task defeated. It never stood a chance.',
  'Another one bites the dust.',
  'Productivity: briefly achieved.',
  'Your to-do list felt that.',
];

/// The message for [style], or null when silent.
String? completionMessage(CompletionStyle style, {Random? random}) {
  final pool = switch (style) {
    CompletionStyle.understated => _understated,
    CompletionStyle.funny => _funny,
    CompletionStyle.silent => const <String>[],
  };
  if (pool.isEmpty) return null;
  return pool[(random ?? Random()).nextInt(pool.length)];
}
