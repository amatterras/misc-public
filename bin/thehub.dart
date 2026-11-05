// THEapp sync hub: command-line control. Pure Dart, no Flutter.
//
//   dart run bin/thehub.dart serve [--port 47710] [--private-host 100.x.y.z] [--data DIR]
//                                  [--tls-cert cert.pem --tls-key key.pem]
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
import 'package:flutter_application_1/hub/hub_mirror.dart';
import 'package:flutter_application_1/hub/hub_host.dart'
    show detectTailscaleAddress;
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/hub/hub_startup.dart';
import 'package:flutter_application_1/hub/hosted_hub.dart';
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
        await _serve(dir, options, args);
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
          'Enter it in misc. → Settings → Sync on the device you are adding.',
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
        await _startup(
          options.positional.firstOrNull ?? 'status',
          options,
          customData: options.value('--data') != null ? dir : null,
        );
      case 'mirror-pair':
        await _mirrorPair(options);
      case 'mirror-run':
        await _mirrorRun(
          options,
          reseed: args.contains('--reseed'),
          repair: args.contains('--repair'),
        );
      case 'mirror-status':
        await _mirrorStatus(options);
      case 'mirror-verify':
        await _mirrorVerify(options);
      case 'restore-from-mirror':
        await _restoreFromMirror(options.positional);
      // Hosted sync service (many accounts; see deploy/hosted/README.md).
      case 'hosted-serve':
        final data = options.value('--data');
        if (data == null) {
          throw const _UsageError('hosted-serve needs --data <folder>');
        }
        final hub = await HostedHub.start(
          dir: Directory(data),
          host: options.value('--listen') ?? '127.0.0.1',
          port: int.tryParse(options.value('--port') ?? '') ?? 8080,
          behindProxy: options.value('--behind-proxy') == 'yes',
          log: (line) =>
              stdout.writeln('${DateTime.now().toIso8601String()} $line'),
        );
        ProcessSignal.sigint.watch().first.then((_) => hub.stop());
        await Completer<void>().future;
      case 'hosted-invite':
        final data = options.value('--data');
        if (data == null) {
          throw const _UsageError('hosted-invite needs --data <folder>');
        }
        stdout.writeln(
          'Invite code (single use): ${await HostedHub.createInvite(Directory(data))}',
        );
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
misc. sync hub

  serve [--port N] [--private-host ADDRESS|auto] [--data DIR]
        [--tls-cert FILE --tls-key FILE] [--background yes]
        Run the hub. Listens on 127.0.0.1 (this PC only). --private-host also
        listens on that private/Tailscale address of this PC. Plain http is
        only used on this PC and on Tailscale: a home-network address needs
        HTTPS, so give the hub a certificate (--tls-cert/--tls-key, PEM).
        Ctrl+C stops it. --background yes starts it without a window and
        returns at once (this is what the sign-in start uses).
  status                 Is it running? Records, devices, memory use.
  stop                   Stop a running hub.
  pair                   Make a one-time pairing code for a new device.
  devices                List paired devices.   revoke <deviceId>   Remove one.
  backup                 Make a verified backup now.
  compact                Shrink the journal (makes a backup first).
  restore-to <backup> <emptyDir>   Restore a backup into a NEW folder.
  startup enable|disable|status    Start the hub at Windows sign-in (optional).
        enable builds the hub program first if it is missing or out of date,
        and can be run again at any time (it changes nothing if all is set).
        status shows what is registered and whether a hub is running now.
Read-only mirror (e.g. on a second machine; always its OWN folder):
  mirror-pair --hub <URL> --code <CODE> --data <DIR>   Pair once (code from "pair").
  mirror-run --data <DIR> [--reseed] [--repair]
        Copy new changes and photos from the hub. --repair re-hashes every
        copied photo and downloads damaged ones again (old copies kept in "damaged").
  mirror-status --data <DIR>           Health, position and missing files.
  mirror-verify --data <DIR>           Check the copy loads as a hub; re-hash photos.
  restore-from-mirror <mirrorDir> <emptyDir>   Rebuild a hub folder from the mirror.
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

Future<void> _serve(Directory dir, _Options options, List<String> args) async {
  final existing = await _running(dir);
  if (existing != null) {
    stderr.writeln('The hub is already running (pid ${existing['pid']}).');
    exitCode = 1;
    return;
  }
  // --background yes: start a copy of this program that has no console
  // window, wait until it answers, and leave. The copy does the real work.
  if (options.value('--background') == 'yes' &&
      Platform.environment['THEAPP_HUB_CHILD'] != '1') {
    await _startInBackground(dir, args);
    return;
  }
  final log = _HubLog(dir);
  final port = int.tryParse(options.value('--port') ?? '') ?? defaultHubPort;
  // "auto": this PC's Tailscale address, followed when it appears (e.g.
  // Tailscale starting after sign-in) or changes.
  final auto = options.value('--private-host') == 'auto';
  final requested = auto
      ? await detectTailscaleAddress()
      : options.value('--private-host');
  SecurityContext? tls;
  String? certSha256;
  final certFile = options.value('--tls-cert');
  final keyFile = options.value('--tls-key');
  if ((certFile == null) != (keyFile == null)) {
    stderr.writeln('--tls-cert and --tls-key go together.');
    exitCode = 2;
    return;
  }
  if (certFile != null && keyFile != null) {
    tls = SecurityContext()
      ..useCertificateChain(certFile)
      ..usePrivateKey(keyFile);
    certSha256 = HubServer.certSha256OfPem(await File(certFile).readAsString());
  }
  final server = await HubServer.start(
    dir: dir,
    port: port,
    privateHost: requested,
    log: log.write,
    tls: tls,
    tlsCertSha256: certSha256,
  );
  // Every 10 s: a listener lost to a network change is opened again.
  final watch = Timer.periodic(const Duration(seconds: 10), (_) async {
    final want = auto ? await detectTailscaleAddress() : requested;
    if (want == server.privateHost && !server.listenerLost) return;
    try {
      await server.setPrivateHost(want);
    } catch (e) {
      log.write('Could not listen on $want yet (${e.runtimeType})');
    }
  });
  await _runFile(dir).writeAsString(
    jsonEncode({
      'pid': pid,
      'port': server.port,
      'listening': server.listening,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
    }),
  );
  stdout.writeln(
    'misc. hub running on ${server.listening.join(', ')}. Press Ctrl+C to stop.',
  );
  final sub = ProcessSignal.sigint.watch().listen((_) => server.stop());
  await server.done;
  watch.cancel();
  await sub.cancel();
  if (await _runFile(dir).exists()) await _runFile(dir).delete();
}

/// Starts `serve` again as a detached process without a console window, and
/// returns once that hub answers (or says why it did not).
Future<void> _startInBackground(Directory dir, List<String> args) async {
  final childArgs = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--background') {
      i++; // its value
      continue;
    }
    childArgs.add(args[i]);
  }
  final running = Platform.resolvedExecutable;
  final viaDart =
      running.toLowerCase().endsWith('dart.exe') ||
      running.toLowerCase().endsWith('${_sep}dart');
  final commandArgs = viaDart
      ? ['run', Platform.script.toFilePath(), ...childArgs]
      : childArgs;
  final log = _HubLog(dir);
  log.write('Starting the hub in the background');
  try {
    await Process.start(
      running,
      commandArgs,
      mode: ProcessStartMode.detached,
      environment: {...Platform.environment, 'THEAPP_HUB_CHILD': '1'},
    );
  } on ProcessException catch (e) {
    stderr.writeln('Could not start the hub: ${e.message}');
    log.write('Could not start the hub: ${e.message}');
    exitCode = 1;
    return;
  }
  for (var i = 0; i < 150; i++) {
    final info = await _running(dir);
    if (info != null) {
      stdout.writeln(
        'Hub started in the background (pid ${info['pid']}, '
        '${(info['listening'] as List).join(', ')}).',
      );
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  stderr.writeln(
    'The hub did not answer within 30 seconds. See ${dir.path}${_sep}logs${_sep}hub.log.',
  );
  log.write('The background hub did not answer within 30 seconds');
  exitCode = 1;
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

/// Start at Windows sign-in (see hub/hub_startup.dart): a shortcut in the
/// user's Startup folder, no admin rights. Everything it needs (the compiled
/// hub program) is built on the way. Safe to repeat.
Future<void> _startup(
  String action,
  _Options options, {
  Directory? customData,
}) async {
  if (!Platform.isWindows) throw const _UsageError('startup is Windows-only');
  final script = Platform.script.toFilePath();
  final compiled = !script.toLowerCase().endsWith('.dart');
  final exe = File(Platform.resolvedExecutable);
  final startup = HubStartup(
    // THEAPP_STARTUP_DIR exists so tests can redirect the Startup folder.
    startupDir: Platform.environment['THEAPP_STARTUP_DIR'] != null
        ? Directory(Platform.environment['THEAPP_STARTUP_DIR']!)
        : HubStartup.defaultStartupDirectory(),
    // bin/thehub.dart lives in the project; a compiled program has no
    // project around it, so it only registers itself.
    projectRoot: compiled ? exe.parent : File(script).parent.parent,
    exe: compiled ? exe : null,
    hubDir: customData,
    extraArguments: customData == null ? const [] : ['--data', customData.path],
  );
  try {
    switch (action) {
      case 'status':
        final s = await startup.status();
        if (!s.registered) {
          stdout.writeln('Not registered: the hub does not start at sign-in.');
          stdout.writeln('Turn it on with: startup enable');
        } else if (s.shortcut == null) {
          stdout.writeln(
            'Registered, but the shortcut could not be read: ${s.shortcutPath}',
          );
          stdout.writeln('Repair it with: startup enable');
        } else {
          stdout.writeln('Registered: starts at sign-in (${s.shortcutPath}).');
          stdout.writeln('Program: ${s.shortcut!.target}');
          stdout.writeln('Command: ${s.shortcut!.arguments}');
          if (s.broken) {
            stdout.writeln(
              'WARNING: that program is missing, so nothing would start. '
              'Repair it with: startup enable',
            );
          }
        }
        if (s.hubRunning) {
          stdout.writeln('The hub is running now (pid ${s.hubPid}).');
        } else {
          stdout.writeln(
            'The hub is not running now. Start it with: serve --background yes',
          );
        }
        if (s.logFile != null && s.logFile!.existsSync()) {
          stdout.writeln('Log: ${s.logFile!.path}');
          if (s.lastLogLine != null) {
            stdout.writeln('Last entry: ${s.lastLogLine}');
          }
        }
      case 'disable':
        stdout.writeln(
          await startup.disable()
              ? 'The hub will no longer start at sign-in.'
              : 'It was not set to start at sign-in; nothing changed.',
        );
      case 'enable':
        final r = await startup.enable(
          rebuild: options.value('--rebuild') == 'yes',
        );
        if (r.built) {
          stdout.writeln('Built the hub program: ${startup.exe.path}');
        }
        stdout.writeln(switch (r.change) {
          StartupChange.created => 'The hub will start (without a window) when you sign in. Undo: startup disable',
          StartupChange.updated =>
            'Updated the sign-in start (it pointed somewhere else).',
          StartupChange.unchanged =>
            'Already set up to start at sign-in; nothing changed.',
        });
        stdout.writeln('Check any time with: startup status');
      default:
        throw _UsageError('startup $action?');
    }
  } on HubStartupException catch (e) {
    throw _AdminError(e.message);
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

/// Mirror commands always need their own folder (never the hub's).
Directory _mirrorDir(_Options options) {
  final data = options.value('--data');
  if (data == null) {
    throw const _UsageError(
      'mirror commands need --data <a separate mirror folder>',
    );
  }
  return Directory(data);
}

Future<void> _mirrorPair(_Options options) async {
  final hub = options.value('--hub');
  final code = options.value('--code');
  if (hub == null || code == null) {
    throw const _UsageError(
      'mirror-pair --hub <URL> --code <CODE> --data <DIR>',
    );
  }
  await MirrorEngine(_mirrorDir(options)).pair(Uri.parse(hub), code);
  stdout.writeln('Mirror paired. Run: mirror-run --data <DIR>');
}

Future<void> _mirrorRun(
  _Options options, {
  required bool reseed,
  required bool repair,
}) async {
  final report = await MirrorEngine(_mirrorDir(options))
      .replicateOnce(reseed: reseed, repair: repair);
  stdout.writeln('Mirror: $report');
  if (report.status != MirrorStatus.inSync) exitCode = 1;
}

Future<void> _mirrorStatus(_Options options) async {
  final state = await MirrorEngine(_mirrorDir(options)).loadState();
  if (state == null) {
    stdout.writeln('Not paired yet.');
    return;
  }
  stdout.writeln('Health: ${state.health()}');
  stdout.writeln(
    'Hub: ${state.primaryUrl}  (hub id ${state.hubId ?? 'not seen yet'})',
  );
  if (state.lastError != null) {
    stdout.writeln(
      'Last attempt ${state.lastAttemptAt ?? '?'}: ${state.lastError}',
    );
  }
  stdout.writeln(
    'Complete up to change #${state.cursor}; last run ${state.replicatedAt ?? 'never'}',
  );
  stdout.writeln(
    'Attachments still missing: ${state.missingAttachments.length}',
  );
}

Future<void> _mirrorVerify(_Options options) async {
  final r = await MirrorEngine(_mirrorDir(options)).verify();
  stdout.writeln('Mirror check: $r');
  if (!r.valid) exitCode = 1;
}

Future<void> _restoreFromMirror(List<String> positional) async {
  if (positional.length != 2) {
    throw const _UsageError('restore-from-mirror <mirrorDir> <emptyDir>');
  }
  await MirrorEngine.restoreToCleanHub(
    mirrorDir: Directory(positional[0]),
    target: Directory(positional[1]),
  );
  stdout.writeln(
    'Restored into ${positional[1]}. It gets a new hub id when it starts;',
  );
  stdout.writeln(
    'pair your devices with it again. The live hub was not touched.',
  );
}
