import 'dart:io';

import 'package:flutter/foundation.dart';

/// A small local log at `<data>\logs\app.log` (never sent anywhere), so
/// errors and recoveries leave a trace that can be looked at later.
abstract final class AppLog {
  static File? _file;
  static const _maxBytes = 1024 * 1024;

  /// Messages logged this session (shown to the user where relevant).
  static final List<String> session = [];

  static void init(Directory root) {
    final dir = Directory('${root.path}${Platform.pathSeparator}logs');
    try {
      dir.createSync(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}app.log');
      // Keep one previous log when the current one gets large.
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        file.renameSync('${file.path}.1');
      }
      _file = file;
    } catch (e) {
      debugPrint('Log unavailable: $e');
    }
  }

  static void info(String message) => _write('INFO', message);

  static void warn(String message) => _write('WARN', message);

  static void error(String message, [Object? error, StackTrace? stack]) {
    _write(
      'ERROR',
      [
        message,
        ?error?.toString(),
        if (stack != null) stack.toString().split('\n').take(12).join('\n'),
      ].join('\n'),
    );
  }

  static void _write(String level, String message) {
    final line = '${DateTime.now().toIso8601String()} $level $message';
    session.add(line);
    if (session.length > 200) session.removeAt(0);
    debugPrint(line);
    try {
      _file?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging must never break the app.
    }
  }
}
