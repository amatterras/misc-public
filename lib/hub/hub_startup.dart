// Starting the hub when this Windows user signs in (no admin rights).
//
// A shortcut in the user's Startup folder runs `thehub.exe serve ...`. This
// file does the whole job so nobody has to build or register anything by
// hand:
//
//  * [enable] builds `thehub.exe` itself when it is missing or older than its
//    sources (creating the output folder, building to a temporary name and
//    swapping it in), then writes the shortcut. Running it again changes
//    nothing; running it after the exe moved or was rebuilt updates the
//    shortcut; nothing is left half done when a step fails.
//  * [disable] removes the shortcut; a second call is harmless.
//  * [status] says what is registered, whether its target exists, and whether
//    a hub answers right now.
//
// Pure Dart (no Flutter), so the compiled hub can use it too. The Startup
// folder, project folder and the build step are parameters so tests can run
// every path without touching the real Startup folder.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

String get _sep => Platform.pathSeparator;

/// What the shortcut points at, as read back from Windows.
class StartupShortcut {
  const StartupShortcut({
    required this.target,
    required this.arguments,
    required this.workingDirectory,
    required this.windowStyle,
  });

  final String target;
  final String arguments;
  final String workingDirectory;
  final int windowStyle;

  @override
  bool operator ==(Object other) =>
      other is StartupShortcut &&
      _same(other.target, target) &&
      other.arguments == arguments &&
      _same(other.workingDirectory, workingDirectory) &&
      other.windowStyle == windowStyle;

  @override
  int get hashCode => Object.hash(
    target.toLowerCase(),
    arguments,
    workingDirectory.toLowerCase(),
    windowStyle,
  );

  static bool _same(String a, String b) =>
      a.replaceAll('/', '\\').toLowerCase() ==
      b.replaceAll('/', '\\').toLowerCase();
}

class HubStartupException implements Exception {
  const HubStartupException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum StartupChange { created, updated, unchanged }

class StartupResult {
  const StartupResult(this.change, this.shortcut, {this.built = false});
  final StartupChange change;
  final StartupShortcut shortcut;

  /// The exe was (re)built by this call.
  final bool built;
}

class StartupStatus {
  const StartupStatus({
    required this.registered,
    required this.shortcutPath,
    this.shortcut,
    this.targetExists = false,
    this.hubRunning = false,
    this.hubPid,
    this.logFile,
    this.lastLogLine,
  });

  final bool registered;
  final String shortcutPath;
  final StartupShortcut? shortcut;
  final bool targetExists;
  final bool hubRunning;
  final int? hubPid;
  final File? logFile;
  final String? lastLogLine;

  /// A registration that would not start anything at sign-in.
  bool get broken => registered && !targetExists;
}

/// Builds `thehub.exe` from [source] into [output]. Throws on failure.
typedef HubBuilder = Future<void> Function(File source, File output);

class HubStartup {
  HubStartup({
    required this.startupDir,
    required this.projectRoot,
    this.hubDir,
    File? exe,
    this.build,
    this.runPowerShell = _runPowerShell,
    this.extraArguments = const [],
  }) : exe =
           exe ??
           File('${projectRoot.path}${_sep}build${_sep}hub${_sep}thehub.exe');

  /// `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`.
  final Directory startupDir;

  /// The folder holding `bin/thehub.dart` and `lib/`.
  final Directory projectRoot;

  /// The hub's data folder (for status and the log); null = the default.
  final Directory? hubDir;

  /// The exe the shortcut starts.
  final File exe;

  /// Replaceable in tests; defaults to `dart compile exe`.
  final HubBuilder? build;

  /// Runs a PowerShell script and returns its output (replaceable).
  final Future<String> Function(String script) runPowerShell;

  /// Passed to `serve` after the standard arguments (for example `--data X`).
  final List<String> extraArguments;

  static const shortcutName = 'THEapp hub.lnk';
  static const description = 'misc. sync hub';

  File get shortcutFile => File('${startupDir.path}$_sep$shortcutName');

  /// The command line the shortcut runs. `--background yes` makes the exe
  /// start a console-less copy of itself and leave, so no window stays open.
  String get arguments => [
    'serve',
    '--background',
    'yes',
    '--private-host',
    'auto',
    for (final a in extraArguments) _quote(a),
  ].join(' ');

  StartupShortcut get expected => StartupShortcut(
    target: exe.path,
    arguments: arguments,
    workingDirectory: exe.parent.path,
    windowStyle: 7, // minimized: nothing flashes up at sign-in
  );

  static String _quote(String a) =>
      a.contains(' ') || a.contains('"') ? '"${a.replaceAll('"', '\\"')}"' : a;

  // ------------------------------------------------------------------ enable

  /// Registers the hub to start at sign-in, building the exe first if needed.
  Future<StartupResult> enable({bool rebuild = false}) async {
    if (!Platform.isWindows) {
      throw const HubStartupException('Start at sign-in is Windows-only.');
    }
    var built = false;
    if (rebuild || _needsBuild()) {
      await _buildExe();
      built = true;
    }
    if (!exe.existsSync()) {
      throw HubStartupException(
        'The hub program is missing and could not be built: ${exe.path}',
      );
    }
    if (!startupDir.existsSync()) {
      throw HubStartupException(
        'The Windows Startup folder was not found: ${startupDir.path}',
      );
    }
    final existed = shortcutFile.existsSync();
    StartupShortcut? before;
    try {
      before = await _read();
    } on HubStartupException {
      before = null; // damaged: it is rewritten below
    }
    if (before != null && before == expected) {
      return StartupResult(StartupChange.unchanged, before, built: built);
    }
    try {
      await _write(expected);
    } on HubStartupException {
      rethrow;
    }
    final after = await _read();
    if (after == null || after != expected) {
      // Do not leave a registration that does not match what was asked.
      if (!existed) {
        try {
          if (shortcutFile.existsSync()) shortcutFile.deleteSync();
        } catch (_) {}
      }
      throw const HubStartupException(
        'Windows did not keep the startup shortcut as written.',
      );
    }
    return StartupResult(
      existed ? StartupChange.updated : StartupChange.created,
      after,
      built: built,
    );
  }

  // ----------------------------------------------------------------- disable

  /// Removes the registration. Returns false when there was none.
  Future<bool> disable() async {
    final file = shortcutFile;
    if (!file.existsSync()) return false;
    try {
      file.deleteSync();
    } on FileSystemException catch (e) {
      throw HubStartupException(
        'Could not remove the startup shortcut (${e.osError?.message ?? e.message}).',
      );
    }
    return true;
  }

  // ------------------------------------------------------------------ status

  Future<StartupStatus> status() async {
    final registered = shortcutFile.existsSync();
    StartupShortcut? sc;
    if (registered) {
      try {
        sc = await _read();
      } on HubStartupException {
        sc = null;
      }
    }
    final dir = hubDir ?? defaultHubDirectory();
    final info = await runningHub(dir);
    final log = File('${dir.path}${_sep}logs${_sep}hub.log');
    String? last;
    try {
      if (log.existsSync()) {
        final lines = log.readAsLinesSync().where((l) => l.trim().isNotEmpty);
        last = lines.isEmpty ? null : lines.last;
      }
    } catch (_) {}
    return StartupStatus(
      registered: registered,
      shortcutPath: shortcutFile.path,
      shortcut: sc,
      targetExists: sc != null && File(sc.target).existsSync(),
      hubRunning: info != null,
      hubPid: info?['pid'] as int?,
      logFile: log,
      lastLogLine: last,
    );
  }

  /// The hub that answers on this folder's recorded port, or null.
  static Future<Map<String, dynamic>?> runningHub(Directory dir) async {
    try {
      final json = jsonDecode(
        File('${dir.path}${_sep}hub.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      try {
        final req = await client
            .getUrl(Uri.parse('http://127.0.0.1:${json['port']}/v1/status'))
            .timeout(const Duration(seconds: 3));
        final res = await req.close().timeout(const Duration(seconds: 3));
        await res.drain<void>();
        return res.statusCode == 200 ? json : null;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return null;
    }
  }

  static Directory defaultHubDirectory() {
    final base =
        Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? '.';
    return Directory('$base${_sep}THEapp-hub');
  }

  static Directory defaultStartupDirectory() => Directory(
    '${Platform.environment['APPDATA']}\\Microsoft\\Windows\\Start Menu\\Programs\\Startup',
  );

  // ------------------------------------------------------------------- build

  File get _source => File('${projectRoot.path}${_sep}bin${_sep}thehub.dart');

  /// The exe is missing, or older than the hub's own sources (an upgrade).
  bool _needsBuild() {
    if (!exe.existsSync()) return true;
    final built = exe.lastModifiedSync();
    for (final dir in ['bin', 'lib${_sep}hub', 'lib${_sep}sync']) {
      final d = Directory('${projectRoot.path}$_sep$dir');
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (f.path.endsWith('.dart') && f.lastModifiedSync().isAfter(built)) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _buildExe() async {
    if (!_source.existsSync()) {
      throw HubStartupException(
        'Cannot build the hub: ${_source.path} was not found. Run this from '
        'the THEapp project, or from a thehub.exe that was already built.',
      );
    }
    exe.parent.createSync(recursive: true);
    // Build beside the target and swap it in, so a failed or interrupted
    // build never replaces a working exe, and a running one is not half
    // overwritten.
    final staged = File('${exe.path}.new');
    if (staged.existsSync()) staged.deleteSync();
    try {
      await (build ?? _dartCompile)(_source, staged);
    } on HubStartupException {
      rethrow;
    } catch (e) {
      throw HubStartupException('Building the hub failed: $e');
    }
    if (!staged.existsSync() || staged.lengthSync() == 0) {
      throw const HubStartupException('Building the hub produced no program.');
    }
    try {
      if (exe.existsSync()) exe.deleteSync();
      staged.renameSync(exe.path);
    } on FileSystemException {
      throw HubStartupException(
        'The hub program is in use (a hub is running from ${exe.path}). Stop '
        'it with "thehub stop", then run this again. The new build is saved '
        'as ${staged.path}.',
      );
    }
  }

  static Future<void> _dartCompile(File source, File output) async {
    final dart = _findDart();
    final r = await Process.run(dart, [
      'compile',
      'exe',
      source.path,
      '-o',
      output.path,
    ], workingDirectory: source.parent.parent.path);
    if (r.exitCode != 0) {
      final tail = '${r.stderr}${r.stdout}'
          .trim()
          .split('\n')
          .take(6)
          .join('\n');
      throw HubStartupException('dart compile exe failed:\n$tail');
    }
  }

  static String _findDart() {
    final running = Platform.resolvedExecutable;
    if (running.toLowerCase().endsWith('dart.exe')) return running;
    final flutter = Platform.environment['FLUTTER_ROOT'];
    final candidates = [
      if (flutter != null) '$flutter${_sep}bin${_sep}dart.bat',
      if (flutter != null) '$flutter${_sep}bin${_sep}dart',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    for (final dir in (Platform.environment['PATH'] ?? '').split(';')) {
      for (final name in ['dart.bat', 'dart.exe']) {
        final f = File('$dir$_sep$name');
        if (dir.isNotEmpty && f.existsSync()) return f.path;
      }
    }
    throw const HubStartupException(
      'Dart was not found, so the hub program cannot be built. Install the '
      'Flutter SDK or build it once with: dart compile exe bin/thehub.dart '
      '-o build/hub/thehub.exe',
    );
  }

  // ---------------------------------------------------------------- shortcut

  static String _q(String s) => s.replaceAll("'", "''");

  Future<void> _write(StartupShortcut s) async {
    final script =
        "\$ErrorActionPreference = 'Stop'; "
        "\$l = (New-Object -ComObject WScript.Shell).CreateShortcut('${_q(shortcutFile.path)}'); "
        "\$l.TargetPath = '${_q(s.target)}'; "
        "\$l.Arguments = '${_q(s.arguments)}'; "
        "\$l.WorkingDirectory = '${_q(s.workingDirectory)}'; "
        "\$l.WindowStyle = ${s.windowStyle}; "
        "\$l.Description = '$description'; "
        '\$l.Save()';
    try {
      await runPowerShell(script);
    } on HubStartupException {
      rethrow;
    }
  }

  Future<StartupShortcut?> _read() async {
    if (!shortcutFile.existsSync()) return null;
    final script =
        "\$ErrorActionPreference = 'Stop'; "
        "\$l = (New-Object -ComObject WScript.Shell).CreateShortcut('${_q(shortcutFile.path)}'); "
        '[pscustomobject]@{ t = \$l.TargetPath; a = \$l.Arguments; '
        'w = \$l.WorkingDirectory; s = [int]\$l.WindowStyle } | ConvertTo-Json -Compress';
    final out = await runPowerShell(script);
    try {
      final j = jsonDecode(out.trim()) as Map<String, dynamic>;
      // A file that is not a real shortcut reads back with no target.
      if ((j['t'] as String? ?? '').isEmpty) {
        throw const FormatException('empty shortcut');
      }
      return StartupShortcut(
        target: j['t'] as String? ?? '',
        arguments: j['a'] as String? ?? '',
        workingDirectory: j['w'] as String? ?? '',
        windowStyle: j['s'] as int? ?? 1,
      );
    } catch (_) {
      throw const HubStartupException(
        'The startup shortcut exists but could not be read.',
      );
    }
  }
}

Future<String> _runPowerShell(String script) async {
  // -EncodedCommand takes UTF-16LE base64, so paths with spaces, quotes or
  // non-ASCII letters reach PowerShell exactly as written.
  final units = script.codeUnits;
  final bytes = <int>[
    for (final u in units) ...[u & 0xff, u >> 8],
  ];
  final r = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-EncodedCommand',
    base64Encode(bytes),
  ]);
  if (r.exitCode != 0) {
    final msg = '${r.stderr}'.trim().split('\n').first;
    throw HubStartupException(
      'Windows refused the shortcut change${msg.isEmpty ? '' : ' ($msg)'}.',
    );
  }
  return '${r.stdout}';
}
