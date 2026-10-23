// Waiting in widget tests for work that needs both clocks.
//
// A widget test runs on a simulated clock. A save that was started there
// (e.g. a debounced canvas save) does real file I/O, but its next steps only
// run when the simulated clock moves. Waiting for it with
// `tester.runAsync(state.flush)` runs on the real clock only, so if the save
// is still in progress at that moment, the test waits forever. That is what
// made `interaction_test` hang now and then, more often on a busy PC.
import 'package:flutter_test/flutter_test.dart';

/// Runs [work] and waits for it, alternating short real waits (for disk I/O)
/// with simulated-time steps (for timers and callbacks started in the test).
/// Fails with a clear message, instead of hanging, after [maxRounds].
Future<T> waitForBothClocks<T>(
  WidgetTester tester,
  Future<T> Function() work, {
  String what = 'The work',
  int maxRounds = 1200, // about a minute of real time
}) async {
  final future = work();
  var done = false;
  late T value;
  Object? error;
  StackTrace? stack;
  future.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e, StackTrace s) {
      error = e;
      stack = s;
      done = true;
    },
  );
  for (var round = 0; !done; round++) {
    if (round >= maxRounds) fail('$what did not finish');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value;
}
