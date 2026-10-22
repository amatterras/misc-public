// Test-data mode for manual testing: started with `--data-dir=<folder>`, the
// app uses that disposable folder instead of %APPDATA%\THEapp. Off unless
// the flag is given; normal use is unchanged.
//
// Safety rules:
// * The folder must already contain the marker file [markerFile] (created
//   by tool/testenv.ps1), so the flag can never be pointed at real data by a
//   typo.
// * A folder inside the real app or hub data folders is refused.
// * In this mode the app never pairs with the real hub's port and never
//   touches Explorer's user-wide "Send to" menu.
import 'dart:io';

class TestEnvironmentError implements Exception {
  const TestEnvironmentError(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract final class TestEnvironment {
  static const flag = '--data-dir=';
  static const markerFile = '.theapp-test-data';

  /// Port of the test hub started by tool/testenv.ps1 (the real hub uses
  /// 47710).
  static const testHubPort = 47799;

  /// The active test data folder; null in normal use.
  static Directory? dataDir;

  static bool get active => dataDir != null;

  /// Reads `--data-dir=` from [args]. Returns null when the flag is absent.
  /// Throws [TestEnvironmentError] when the folder is missing, not prepared
  /// as a test folder, or inside one of [realDirs].
  static Directory? fromArgs(
    List<String> args, {
    required List<Directory> realDirs,
  }) {
    // "--data-dir <folder>" (two arguments) would otherwise open the real
    // data and treat the folder as a file sent to the Inbox.
    if (args.contains(flag.substring(0, flag.length - 1))) {
      throw const TestEnvironmentError(
        'Write the test folder as --data-dir=<folder> (one argument).',
      );
    }
    final values = [
      for (final a in args)
        if (a.startsWith(flag)) a.substring(flag.length).trim(),
    ];
    if (values.isEmpty) return null;
    if (values.length > 1 || values.single.isEmpty) {
      throw const TestEnvironmentError('Give exactly one --data-dir=<folder>.');
    }
    final dir = Directory(values.single).absolute;
    for (final real in realDirs) {
      if (isSameOrInside(dir, real)) {
        throw TestEnvironmentError(
          'Refusing to use ${dir.path} as test data: it is inside the real '
          'data folder ${real.path}.',
        );
      }
    }
    if (!File('${dir.path}${Platform.pathSeparator}$markerFile').existsSync()) {
      throw TestEnvironmentError(
        'Refusing to use ${dir.path} as test data: it has no $markerFile '
        'marker. Create the test environment with tool/testenv.ps1 setup.',
      );
    }
    return dir;
  }

  /// Whether [dir] is [parent] or lies inside it (after resolving `..`).
  static bool isSameOrInside(Directory dir, Directory parent) {
    String norm(Directory d) {
      var p = d.absolute.uri.normalizePath().toFilePath();
      if (!p.endsWith(Platform.pathSeparator)) p += Platform.pathSeparator;
      return Platform.isWindows ? p.toLowerCase() : p;
    }

    return norm(dir).startsWith(norm(parent));
  }
}
