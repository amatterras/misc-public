// Work THEapp repeats while it runs on the PC: every 10 seconds it checks
// the hub, syncs, and backs up what changed. One scheduler for the whole
// app (started once, however often pages are rebuilt).
//
// Each job runs at most once at a time. A tick that arrives while a job is
// still running is remembered and that job runs again right after (once,
// however many ticks were missed): nothing overlaps, nothing is lost.
// Each job's outcome is its own: a backup's success says nothing about
// sync, and the other way round.
import 'dart:async';

import 'package:flutter/foundation.dart';

/// One repeated job and its truthful outcome.
class MaintenanceJob {
  MaintenanceJob(this.name, this.run, {this.label});

  /// Short id ('sync', 'backup', …).
  final String name;

  /// Shown while it runs ('Syncing', 'Backing up', …).
  final String? label;

  /// Does the work; throws if it failed. Returns false when there was
  /// nothing to do (e.g. no change to back up): that is not a success
  /// time, but not an error either.
  final Future<bool> Function() run;

  bool running = false;
  bool _pending = false;

  /// When it last completed its work (null: not yet).
  DateTime? lastSuccess;

  /// When it last ran, with or without anything to do.
  DateTime? lastRun;

  /// The last failure, kept until the next success.
  String? lastError;
  DateTime? lastErrorAt;

  /// Failures in a row (0 after a success).
  int failures = 0;

  /// Runs so far (tests).
  int runs = 0;
}

class MaintenanceScheduler extends ChangeNotifier {
  MaintenanceScheduler(
    this.jobs, {
    this.interval = const Duration(seconds: 10),
    this.onError,
  });

  final List<MaintenanceJob> jobs;
  final Duration interval;

  /// Told about each failure (to log it).
  final void Function(MaintenanceJob job, Object error, StackTrace stack)?
  onError;

  Timer? _timer;
  bool _stopped = false;
  final _inFlight = <Future<void>>{};

  /// How often [start] actually started the timer (tests: once).
  int timersStarted = 0;

  bool get started => _timer != null;

  /// The job running now, if any (for the status line).
  MaintenanceJob? get current => jobs.where((j) => j.running).firstOrNull;

  MaintenanceJob job(String name) => jobs.firstWhere((j) => j.name == name);

  /// Starts the repeating timer; does nothing if it already runs. The
  /// first round runs at once.
  void start() {
    if (_timer != null || _stopped) return;
    timersStarted++;
    _timer = Timer.periodic(interval, (_) => tick());
    tick();
  }

  /// One round: every job is asked to run.
  void tick() {
    if (_stopped) return;
    for (final j in jobs) {
      trigger(j);
    }
  }

  /// Runs [j] now, or right after its current run.
  void trigger(MaintenanceJob j) {
    if (_stopped) return;
    if (j.running) {
      j._pending = true;
      return;
    }
    final f = _run(j);
    _inFlight.add(f);
    f.whenComplete(() => _inFlight.remove(f));
  }

  Future<void> _run(MaintenanceJob j) async {
    j.running = true;
    j.runs++;
    notifyListeners();
    try {
      final did = await j.run();
      j.lastRun = DateTime.now();
      if (did) j.lastSuccess = j.lastRun;
      j.lastError = null;
      j.lastErrorAt = null;
      j.failures = 0;
    } catch (e, s) {
      j.lastRun = DateTime.now();
      j.lastError = _plain(e);
      j.lastErrorAt = j.lastRun;
      j.failures++;
      onError?.call(j, e, s);
    } finally {
      j.running = false;
      if (!_stopped) notifyListeners();
    }
    if (j._pending && !_stopped) {
      j._pending = false;
      await _run(j); // the missed tick, once
    }
  }

  static String _plain(Object e) {
    final text = '$e';
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  /// Stops the timer and waits (up to [wait]) for jobs still running, so
  /// the app closes without cutting a backup or a sync in half.
  Future<void> stop({Duration wait = const Duration(seconds: 20)}) async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    if (_inFlight.isEmpty) return;
    await Future.wait([..._inFlight]).timeout(wait, onTimeout: () => []);
  }
}

/// Runs actions one after another (never two at once), in call order.
class SerialLock {
  Future<void> _last = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _last.then((_) => action());
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// A job's failure in plain words (shown as is in Settings → Sync).
class JobProblem implements Exception {
  const JobProblem(this.message);
  final String message;
  @override
  String toString() => message;
}
