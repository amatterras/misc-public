// iPhone/iPad file protection: private files get NSFileProtectionComplete
// (unreadable while the device is locked). Other platforms have no such
// class, so every call here does nothing there.
//
// Writes are never made weaker to keep working while the device is locked:
// a write that cannot happen yet waits until iOS reports protected data is
// available again (see [FileProtection.whenUnlocked]).
//
// STATUS: the Dart side is tested with a simulated backend. The Swift side
// (ios/Runner/AppDelegate.swift) has NOT been compiled or run on a device.
import 'dart:async';
import 'dart:io';

import '../data/storage/app_log.dart';

/// What the native side offers (implemented by `IosBridge`).
abstract class ProtectionBackend {
  /// Sets NSFileProtectionComplete on each path (and, for [tree], on
  /// everything below it). False if any item could not be changed, e.g.
  /// because the device is locked or the path does not exist.
  Future<bool> protect(List<String> paths, {bool tree = false});

  /// Whether protected files can be read and written right now.
  Future<bool> dataAvailable();

  /// Changes of [dataAvailable] (true = unlocked).
  Stream<bool> get availability;
}

abstract final class FileProtection {
  /// Set at start-up on iPhone/iPad; null elsewhere (everything is a no-op).
  static ProtectionBackend? backend;

  static bool _available = true;
  static Completer<void>? _unlocked;
  static StreamSubscription<bool>? _subscription;
  static final Set<String> _owed = {};
  static final Set<String> _owedTrees = {};

  /// Starts following the device lock state. Call once after setting
  /// [backend].
  static Future<void> start() async {
    final b = backend;
    if (b == null) return;
    await _subscription?.cancel();
    _subscription = b.availability.listen(_changed);
    try {
      _changed(await b.dataAvailable());
    } on Exception catch (e) {
      AppLog.warn('Could not ask iOS whether protected data is available: $e');
    }
  }

  /// Forgets the backend and any waiting state (tests).
  static Future<void> reset() async {
    await _subscription?.cancel();
    _subscription = null;
    backend = null;
    _available = true;
    _unlocked = null;
    _owed.clear();
    _owedTrees.clear();
  }

  static void _changed(bool available) {
    _available = available;
    if (!available) {
      _unlocked ??= Completer<void>();
      return;
    }
    final waiting = _unlocked;
    _unlocked = null;
    waiting?.complete();
    if (_owed.isNotEmpty || _owedTrees.isNotEmpty) {
      unawaited(_settleOwed());
    }
  }

  /// Whether protected files are readable now (always true off iOS).
  static bool get available => backend == null || _available;

  /// Runs [action] once protected data is available, and again if the device
  /// locks while it runs and it fails with a file error. [action] must be safe
  /// to run again (the file writes it guards write a temporary file first).
  static Future<T> whenUnlocked<T>(Future<T> Function() action) async {
    final b = backend;
    if (b == null) return action();
    for (;;) {
      while (!_available) {
        await (_unlocked ??= Completer<void>()).future;
      }
      try {
        return await action();
      } on FileSystemException {
        // Only a lock explains it: anything else is a real error.
        if (await b.dataAvailable()) rethrow;
        _changed(false);
      }
    }
  }

  /// Marks [paths] NSFileProtectionComplete. When the device is locked this
  /// is retried as soon as it unlocks. Never throws.
  static Future<void> protect(
    Iterable<String> paths, {
    bool tree = false,
  }) async {
    final b = backend;
    if (b == null) return;
    final list = paths.toList();
    if (list.isEmpty) return;
    (tree ? _owedTrees : _owed).addAll(list);
    if (!_available) return; // done by [_settleOwed] after unlock
    await _settleOwed();
  }

  static bool _settling = false;

  static Future<void> _settleOwed() async {
    final b = backend;
    if (b == null || _settling) return;
    _settling = true;
    try {
      for (final (tree, owed) in [(false, _owed), (true, _owedTrees)]) {
        if (owed.isEmpty) continue;
        final batch = owed.toList();
        bool ok;
        try {
          ok = await b.protect(batch, tree: tree);
        } on Exception catch (e) {
          AppLog.warn('Could not set file protection: $e');
          ok = false;
        }
        if (ok) {
          owed.removeAll(batch);
        } else if (_available) {
          // Not a lock: a missing or unchangeable path. Do not keep
          // retrying it forever.
          AppLog.warn('File protection not applied to: ${batch.join(', ')}');
          owed.removeAll(batch);
        }
      }
    } finally {
      _settling = false;
    }
  }
}
