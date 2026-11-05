// When to sync. The sync itself (SyncEngine.syncOnce: push, then pull) is
// unchanged; this decides when it runs so changes travel in about a second
// instead of waiting for a minute-long timer:
//   - a local edit asks for a sync after a short pause (edits in quick
//     succession travel together);
//   - a request while a sync is running is remembered and runs right after
//     it (never dropped);
//   - a long-poll to the hub (/v1/wait) returns the moment another device's
//     change is stored there, and a pull follows at once;
//   - if the hub is unreachable the long-poll retries with growing pauses
//     (1 s … 30 s) and catches up as soon as it answers again;
//   - a hub from before /v1/wait (404) is simply polled;
//   - a slow timer still runs as a safety net in every case.
import 'dart:async';
import 'dart:math';

import 'sync_client.dart';

/// How this device is connected to the hub right now.
enum SyncConnection {
  /// Not started (or stopped: not paired, paused in the background).
  stopped,

  /// Long-poll connected: other devices' changes arrive within a second.
  live,

  /// The hub does not support live updates: synced on the timer and after
  /// each local edit.
  polling,

  /// The hub could not be reached; retrying. Local edits are kept.
  offline,

  /// Sync is paused on the PC (its switch is off). Local edits are kept
  /// and go out once it is turned on again.
  paused,

  /// The hub answered but refuses this device's sync for a reason that waiting
  /// does not fix (for example an app version it does not accept). Local
  /// edits are kept; the cause is shown, and a later success clears it.
  blocked,
}

class SyncScheduler {
  SyncScheduler({
    required this.run,
    required this.cursor,
    required this.client,
    this.debounce = const Duration(milliseconds: 300),
    this.fallback = const Duration(minutes: 1),
    this.waitSeconds = 25,
    this.onChange,
    this.onError,
    this.onBlocked,
  });

  /// Told about a failure that waiting cannot fix: `unauthorized` (this
  /// device was removed or the hub was replaced; the scheduler has stopped
  /// itself) or any other non-retryable failure (it keeps trying slowly).
  final void Function(SyncFailure failure)? onBlocked;

  /// Told about a failed cycle (to show and log it).
  final void Function(Object error, StackTrace stack)? onError;

  /// One sync cycle (push + pull). Throws [SyncFailure] when the hub is
  /// unreachable (after reporting it); the scheduler retries.
  final Future<void> Function() run;

  /// The change number this device has read up to (its sync cursor).
  final Future<int> Function() cursor;
  final SyncClient client;
  final Duration debounce;
  final Duration fallback;
  final int waitSeconds;

  /// Told when [connection] or [pendingLocal] changes.
  final void Function()? onChange;

  SyncConnection connection = SyncConnection.stopped;

  /// A local edit happened that has not gone through a successful sync yet.
  bool pendingLocal = false;

  /// When the last cycle finished without error.
  DateTime? lastSuccess;

  bool _stopped = true;
  bool _running = false;
  bool _again = false;
  Timer? _debounce;
  Timer? _fallback;
  Completer<void>? _idle;
  int _generation = 0;
  int _failures = 0;

  /// The code last reported through [onBlocked] (so one cause is reported
  /// once, not once per cycle).
  String? _lastBlockedCode;

  /// Counts local edits, so a cycle clears [pendingLocal] only if no edit
  /// arrived after it began (requests from the hub do not count).
  int _edits = 0;

  /// The hub answered /v1/wait at least once.
  bool _liveSupported = false;

  /// Ends a back-off pause early (the hub is reachable again).
  Completer<void>? _backoffWake;
  void _wakeLive() {
    final w = _backoffWake;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _pause(Duration d) async {
    final wake = _backoffWake = Completer<void>();
    await Future.any([Future<void>.delayed(d), wake.future]);
    _backoffWake = null;
  }

  final _random = Random();

  bool get running => _running;

  /// Consecutive failures of the live connection (for the retry pause).
  int get failures => _failures;
  bool get scheduled => !_stopped && (_fallback?.isActive ?? false);

  void _set(SyncConnection c) {
    if (connection == c) return;
    connection = c;
    onChange?.call();
  }

  void start() {
    if (!_stopped) return;
    _stopped = false;
    _generation++;
    // A new start (the app came back to the front, or the device was just
    // paired) is a fresh attempt: failures from before must not stretch the
    // first retry.
    _failures = 0;
    _lastBlockedCode = null;
    _fallback = Timer.periodic(fallback, (_) => request(Duration.zero));
    _set(SyncConnection.polling);
    request(const Duration(seconds: 1)); // catch up after start
    unawaited(_live(_generation));
  }

  /// Stops everything (unpaired, or the app goes to the background).
  /// Local edits stay pending and go out after [start].
  void stop() {
    _stopped = true;
    _generation++;
    _wakeLive();
    _debounce?.cancel();
    _fallback?.cancel();
    client.cancelWait();
    _set(SyncConnection.stopped);
  }

  /// Stops and waits for a cycle in progress to finish.
  Future<void> close() async {
    stop();
    await _idle?.future;
  }

  /// A local edit: sync soon.
  void localChange() {
    _edits++;
    if (!pendingLocal) {
      pendingLocal = true;
      onChange?.call();
    }
    request(debounce);
  }

  /// Asks for a sync after [delay]; coalesces with requests in between.
  void request([Duration? delay]) {
    if (_stopped) return;
    if (_running) {
      _again = true; // runs right after the current one
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(delay ?? debounce, _runNow);
  }

  /// Runs a cycle now (Settings → Sync now) and waits for it.
  Future<void> syncNow() async {
    if (_running) {
      _again = true;
      await _idle?.future;
      return;
    }
    _debounce?.cancel();
    await _runNow();
  }

  Future<void> _runNow() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    _again = false;
    _idle = Completer<void>();
    final editsAtStart = _edits;
    try {
      await run();
      lastSuccess = DateTime.now();
      _lastBlockedCode = null;
      if (connection == SyncConnection.offline ||
          connection == SyncConnection.paused ||
          connection == SyncConnection.blocked) {
        // The hub answered: say so, and end the live loop's back-off.
        _set(_liveSupported ? SyncConnection.live : SyncConnection.polling);
        _wakeLive();
      }
      // Edits made during this cycle stay pending (they run next).
      if (pendingLocal && _edits == editsAtStart) {
        pendingLocal = false;
        onChange?.call();
      }
    } on SyncFailure catch (e, s) {
      // Nothing pending is lost: unsent changes go out on the next cycle.
      if (!_stopped) {
        if (e.code == 'sync_paused') {
          _set(SyncConnection.paused);
        } else if (e.code == 'unauthorized') {
          _unauthorized(e);
        } else if (e.retryable) {
          _set(SyncConnection.offline);
        } else {
          _blocked(e);
        }
      }
      onError?.call(e, s);
    } catch (e, s) {
      onError?.call(e, s);
    } finally {
      _running = false;
      _idle?.complete();
      _idle = null;
      if (_again && !_stopped) {
        _again = false;
        request(debounce);
      }
    }
  }

  /// The hub does not know this device (removed, or another hub answers):
  /// trying again cannot help, so everything stops and the app is told. The
  /// app decides when to look again (coming back to the front, "Sync now").
  void _unauthorized(SyncFailure e) {
    stop();
    if (_lastBlockedCode != e.code) {
      _lastBlockedCode = e.code;
      onBlocked?.call(e);
    }
  }

  /// A refusal that waiting does not fix (not a lost connection): shown as
  /// such instead of "live"; the slow timer keeps trying and a success
  /// clears it.
  void _blocked(SyncFailure e) {
    _set(SyncConnection.blocked);
    if (_lastBlockedCode != e.code) {
      _lastBlockedCode = e.code;
      onBlocked?.call(e);
    }
  }

  Future<void> _waitUntilIdle() async {
    while (!_stopped && (_running || (_debounce?.isActive ?? false))) {
      if (_running) {
        await _idle?.future;
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  Duration _backoff() {
    final seconds = min(30, 1 << min(_failures, 5));
    return Duration(milliseconds: seconds * 1000 + _random.nextInt(500));
  }

  /// The long-poll loop: one request at a time, a pull whenever the hub has
  /// something newer than this device's cursor.
  Future<void> _live(int generation) async {
    while (!_stopped && generation == _generation) {
      try {
        // Never ask again while a sync is about to run or running: the
        // cursor would still be behind and the loop would spin.
        await _waitUntilIdle();
        if (_stopped || generation != _generation) return;
        final since = await cursor();
        // Right after (re)connecting a short probe confirms the hub is
        // there and supports live updates; then the long wait.
        final r = await client.waitForChange(
          since,
          seconds:
              connection == SyncConnection.live ||
                  connection == SyncConnection.paused
              ? waitSeconds
              : 1,
        );
        if (_stopped || generation != _generation) return;
        final reconnected = connection != SyncConnection.live;
        _failures = 0;
        _liveSupported = true;
        // A hub that answers the wait but refuses the sync stays "blocked"
        // until a cycle really succeeds.
        if (connection != SyncConnection.blocked) _set(SyncConnection.live);
        // Newer changes, a restored hub (lower number), or back after an
        // outage: pull now.
        if (r.lastSeq != since || reconnected) request(Duration.zero);
      } on SyncFailure catch (e) {
        if (_stopped || generation != _generation) return;
        if (e.code == 'not_found') {
          // A hub from before live updates: the timer keeps it in sync.
          _set(SyncConnection.polling);
          return;
        }
        if (e.code == 'unauthorized') {
          _unauthorized(e);
          return;
        }
        if (e.code == 'sync_paused') {
          // The hub holds the next wait until sync resumes (or 25 s), so
          // resuming is noticed at once; a short pause only guards against
          // a hub that answers immediately.
          _set(SyncConnection.paused);
          await _pause(const Duration(milliseconds: 250));
          continue;
        }
        _failures++;
        if (e.retryable) {
          _set(SyncConnection.offline);
        } else {
          _blocked(e);
        }
        await _pause(_backoff());
      } catch (_) {
        if (_stopped || generation != _generation) return;
        _failures++;
        _set(SyncConnection.offline);
        await _pause(_backoff());
      }
    }
  }
}
