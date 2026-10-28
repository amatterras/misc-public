import 'dart:io';

import 'package:flutter/foundation.dart';

import 'log_sanitizer.dart';

/// A small local log at `<data>\logs\app.log` (never sent anywhere), so
/// errors and recoveries leave a trace that can be looked at later.
abstract final class AppLog {
  static File? _file;
  static File? _copy;
  static const _maxBytes = 1024 * 1024;

  /// Messages logged this session (shown to the user where relevant).
  static final List<String> session = [];

  /// [copy]: a second file with the same lines, e.g. on iPhone/iPad one the
  /// Files app can show (the data folder itself is not visible there).
  static void init(Directory root, {File? copy}) {
    _file = _open(
      File(
        '${root.path}${Platform.pathSeparator}logs'
        '${Platform.pathSeparator}app.log',
      ),
    );
    _copy = copy == null ? null : _open(copy);
  }

  static File? _open(File file) {
    try {
      file.parent.createSync(recursive: true);
      // Keep one previous log when the current one gets large.
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        file.renameSync('${file.path}.1');
      }
      return file;
    } catch (e) {
      debugPrint('Log unavailable: $e');
      return null;
    }
  }

  static void info(String message) => _write('INFO', message);

  static void warn(String message) => _write('WARN', message);

  static void error(String message, [Object? error, StackTrace? stack]) {
    _write(
      'ERROR',
      [
        message,
        // The type (and a safe detail), never the exception's own message:
        // it can quote the text of the file or request that failed.
        if (error != null) describeError(error),
        if (stack != null) stack.toString().split('\n').take(12).join('\n'),
      ].join('\n'),
    );
  }

  static void _write(String level, String message) {
    final line =
        '${DateTime.now().toIso8601String()} $level ${sanitizeLog(message)}';
    session.add(line);
    if (session.length > 200) session.removeAt(0);
    debugPrint(line);
    for (final file in [_file, _copy]) {
      try {
        file?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
      } catch (_) {
        // Logging must never break the app.
      }
    }
  }
}
