// THEapp sync hub: command-line control. Pure Dart, no Flutter.
//
//   dart run bin/thehub.dart serve [--port 47710] [--private-host 100.x.y.z] [--data DIR]
//   dart run bin/thehub.dart status | stop | pair | devices | revoke <id>
//   dart run bin/thehub.dart backup | compact | restore-to <backupDir> <emptyDir>
//   dart run bin/thehub.dart startup enable|disable|status
//
// See SYNC_ARCHITECTURE.md §15 for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/hub/hub_auth.dart';
import 'package:flutter_application_1/hub/hub_backup.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/secret_store.dart';

String get _sep => Platform.pathSeparator;

Directory defaultHubDir() {
  final base =
      Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? '.';
  return Directory('$base${_sep}THEapp-hub');
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == 'help' || args.first == '--help') {
    _usage();
    return;
  }
  final options = _Options(args.skip(1).toList());
  final dir = options.value('--data') == null
      ? defaultHubDir()
      : Directory(options.value('--data')!);
  try {
    switch (args.first) {
      case 'serve':
        await _serve(dir, options);
      case 'status':
        await _status(dir);
      case 'stop':
        await _admin(dir, 'POST', '/v1/admin/shutdown');
        stdout.writeln('Hub is stopping.');
      case 'pair':
        final r = await _admin(dir, 'POST', '/v1/admin/pair');
        stdout.writeln(
          'Pairing code: ${r['code']}  (valid ${r['expiresInMinutes']} minutes, single use)',
        );
        stdout.writeln(
          'Enter it in THEapp → Settings → Sync on the device you are adding.',
        );
      case 'devices':
        final r = await _admin(dir, 'GET', '/v1/admin/status');
        for (final d in r['devices'] as List) {
          stdout.writeln(
            '${d['id']}  ${d['name']}${d['revoked'] == true ? '  (revoked)' : ''}',
          );
        }
      case 'revoke':
        if (options.positional.isEmpty) {
          throw const _UsageError('revoke needs a device id');
        }
        final r = await _admin(dir, 'POST', '/v1/admin/revoke', {
          'deviceId': options.positional.first,
        });
        stdout.writeln(r['revoked'] == true ? 'Revoked.' : 'No such device.');
      case 'backup':
        final r = await _admin(dir, 'POST', '/v1/admin/backup');
        stdout.writeln('Backup: ${r['backup']}  verified: ${r['verified']}');
      case 'compact':
        final r = await _admin(dir, 'POST', '/v1/admin/compact');
        stdout.writeln(
          'Compacted: ${r['records']} records, journal ${r['journalBytes']} bytes',
        );
      case 'restore-to':
        if (options.positional.length != 2) {
          throw const _UsageError('restore-to <backupDir> <emptyDir>');
        }
        final missing = await HubBackups.restoreTo(
          Directory(options.positional[0]),
          Directory(options.positional[1]),
          attachmentsFrom: Directory('${dir.path}${_sep}attachments'),
        );
        stdout.writeln('Restored into ${options.positional[1]}.');
        if (missing.isNotEmpty) {
          stdout.writeln(
            '${missing.length} attachment file(s) were not found.',
          );
        }
        stdout.writeln(
          'Live data was not touched. See SYNC_ARCHITECTURE.md §14 to switch to it.',
        );
      case 'startup':
        await _startup(options.positional.firstOrNull ?? 'status');
      default:
        throw _UsageError('unknown command "${args.first}"');
    }
  } on _UsageError catch (e) {
    stderr.writeln('Error: ${e.message}\n');
    _usage();
    exitCode = 64;
  } on SocketException {
    stderr.writeln(
      'The hub is not running (start it with: dart run bin/thehub.dart serve).',
    );
    exitCode = 69;
  } on ArgumentError catch (e) {
    stderr.writeln('Error: ${e.message}');
    exitCode = 64;
  } on _AdminError catch (e) {
    stderr.writeln('Error: ${e.message}');
    exitCode = 1;
  }
}

void _usage() => stdout.writeln('''
THEapp sync hub

  serve [--port N] [--private-host ADDRESS] [--data DIR]
        Run the hub. Listens on 127.0.0.1 (this PC only). --private-host also
        listens on that private/Tailscale address of this PC. Ctrl+C stops it.
  status                 Is it running? Records, devices, memory use.
  stop                   Stop a running hub.
  pair                   Make a one-time pairing code for a new device.
  devices                List paired devices.   revoke <deviceId>   Remove one.
  backup                 Make a verified backup now.
  compact                Shrink the journal (makes a backup first).
  restore-to <backup> <emptyDir>   Restore a backup into a NEW folder.
  startup enable|disable|status    Start the hub at Windows sign-in (optional).
''');

class _UsageError implements Exception {
  const _UsageError(this.message);
  final String message;
}

class _AdminError implements Exception {
  const _AdminError(this.message);
  final String message;
}

class _Options {
  _Options(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      if (args[i].startsWith('--') && i + 1 < args.length) {
        _values[args[i]] = args[++i];
      } else {
        positional.add(args[i]);
      }
    }
  }

  final Map<String, String> _values = {};
  final List<String> positional = [];
  String? value(String name) => _values[name];
}

File _runFile(Directory dir) => File('${dir.path}${_sep}hub.json');

Future<void> _serve(Directory dir, _Options options) async {
  final existing = await _running(dir);
  if (existing != null) {
    stderr.writeln('The hub is already running (pid ${existing['pid']}).');
    exitCode = 1;
    return;
  }
  final log = _HubLog(dir);
  final port = int.tryParse(options.value('--port') ?? '') ?? defaultHubPort;
  final server = await HubServer.start(
    dir: dir,
    port: port,
    privateHost: options.value('--private-host'),
    log: log.write,
  );
  await _runFile(dir).writeAsString(
    jsonEncode({
      'pid': pid,
      'port': server.port,
      'listening': server.listening,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
    }),
  );
  stdout.writeln(
    'THEapp hub running on ${server.listening.join(', ')}. Press Ctrl+C to stop.',
  );
  final sub = ProcessSignal.sigint.watch().listen((_) => server.stop());
  await server.done;
  await sub.cancel();
  if (await _runFile(dir).exists()) await _runFile(dir).delete();
}

/// The running hub's info, or null.
Future<Map<String, dynamic>?> _running(Directory dir) async {
  try {
    final json =
        jsonDecode(await _runFile(dir).readAsString()) as Map<String, dynamic>;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/v1/status'),
      );
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode == 200 ? json : null;
    } finally {
      client.close(force: true);
    }
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>> _admin(
  Directory dir,
  String method,
  String path, [
  Map<String, dynamic>? body,
]) async {
  final info = await _running(dir);
  if (info == null) throw const SocketException('not running');
  final token = await readSecret(HubAuth.adminTokenFile(dir));
  if (token == null) {
    throw const _AdminError(
      'Could not read the admin token for this Windows user.',
    );
  }
  final client = HttpClient();
  try {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${info['port']}$path'),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw _AdminError('${json['message'] ?? res.statusCode}');
    }
    return json;
  } finally {
    client.close();
  }
}

Future<void> _status(Directory dir) async {
  final info = await _running(dir);
  if (info == null) {
    stdout.writeln('Hub: not running.  Data folder: ${dir.path}');
    return;
  }
  final s = await _admin(dir, 'GET', '/v1/admin/status');
  stdout.writeln(
    'Hub: running (pid ${info['pid']}) on ${(s['listening'] as List).join(', ')}',
  );
  stdout.writeln(
    'Records: ${s['records']}  Last change #${s['lastSeq']}  Journal: ${s['journalBytes']} bytes',
  );
  stdout.writeln(
    'Devices: ${(s['devices'] as List).length}  Backups: ${s['backups']}  Memory: ${(s['rssBytes'] as int) ~/ (1024 * 1024)} MB',
  );
  stdout.writeln('Data folder: ${dir.path}');
}

/// Optional start at Windows sign-in: a shortcut in the user's Startup
/// folder (no admin rights, nothing else changed). `disable` removes it.
Future<void> _startup(String action) async {
  if (!Platform.isWindows) throw const _UsageError('startup is Windows-only');
  final startupDir =
      '${Platform.environment['APPDATA']}\\Microsoft\\Windows\\Start Menu\\Programs\\Startup';
  final lnk = File('$startupDir\\THEapp hub.lnk');
  switch (action) {
    case 'status':
      stdout.writeln(
        lnk.existsSync()
            ? 'Starts at sign-in: yes ($startupDir)'
            : 'Starts at sign-in: no',
      );
    case 'disable':
      if (lnk.existsSync()) lnk.deleteSync();
      stdout.writeln('The hub will no longer start at sign-in.');
    case 'enable':
      final exe = File(
        '${File(Platform.script.toFilePath()).parent.parent.path}\\build\\hub\\thehub.exe',
      );
      if (!exe.existsSync()) {
        throw _UsageError(
          'build the hub first: dart compile exe bin/thehub.dart -o ${exe.path}',
        );
      }
      String q(String s) => s.replaceAll("'", "''");
      final script =
          "\$s = (New-Object -ComObject WScript.Shell).CreateShortcut('${q(lnk.path)}'); "
          "\$s.TargetPath = '${q(exe.path)}'; \$s.Arguments = 'serve'; "
          "\$s.WindowStyle = 7; \$s.Description = 'THEapp sync hub'; \$s.Save()";
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      if (r.exitCode != 0 || !lnk.existsSync()) {
        throw const _AdminError('Could not create the shortcut.');
      }
      stdout.writeln(
        'The hub will start (minimised) when you sign in. Undo with: startup disable',
      );
    default:
      throw _UsageError('startup $action?');
  }
}

/// Privacy-preserving log at `<hub>\logs\hub.log` (rotated at 1 MB).
class _HubLog {
  _HubLog(Directory dir)
    : _file = File('${dir.path}${_sep}logs${_sep}hub.log') {
    _file.parent.createSync(recursive: true);
    if (_file.existsSync() && _file.lengthSync() > 1024 * 1024) {
      _file.renameSync('${_file.path}.1');
    }
  }

  final File _file;

  void write(String line) {
    final text = '${DateTime.now().toIso8601String()} $line';
    stdout.writeln(text);
    try {
      _file.writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}
