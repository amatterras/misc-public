// The hub, run by THEapp itself on Windows while the app is open, so the
// iPad and iPhone can sync without a separate console window that someone
// must start (and that stopped for good when its window closed).
//
// - The hub runs in its own isolate: its file and network work never
//   holds up drawing or typing.
// - Exactly one hub: if a hub already answers on the port (e.g. one
//   started with `thehub serve`), THEapp uses that one and starts none;
//   binding the port is the lock between processes.
// - It listens on this PC (127.0.0.1) and on this PC's Tailscale address
//   when there is one. Tailscale coming up later, its address changing, or
//   a listener dropping out (Wi-Fi drop, sleep) is noticed by the health
//   check and the private listener is opened again; 127.0.0.1 and paired
//   devices are not touched.
// - Only if the hub isolate itself ends (a genuine failure) is it started
//   again, with growing pauses; never two at once.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'hub_server.dart';

/// This PC's Tailscale IPv4 address (100.64.0.0/10), or null.
Future<String?> detectTailscaleAddress() async {
  try {
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in i.addresses) {
        final b = a.rawAddress;
        if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return a.address;
      }
    }
  } on SocketException {
    // No interface list right now (e.g. during a network change).
  }
  return null;
}

enum HubHostState {
  /// Not started.
  off,
  starting,

  /// The hub runs inside THEapp.
  running,

  /// Another hub process on this PC serves the port; THEapp uses it.
  external,

  /// The hub stopped or could not start; it is started again shortly.
  recovering,

  /// Cannot start (e.g. the port belongs to another program).
  failed,
}

/// The result of one health check.
class HubHealth {
  const HubHealth({
    required this.state,
    required this.listening,
    this.problem,
    this.recovered,
  });
  final HubHostState state;
  final List<String> listening;

  /// What is wrong now (plain words), if anything.
  final String? problem;

  /// What was repaired by this check, if anything.
  final String? recovered;

  bool get ok =>
      problem == null &&
      (state == HubHostState.running || state == HubHostState.external);
}

class HubHost {
  HubHost({
    required this.dir,
    this.port = defaultHubPort,
    this.privateAddress = detectTailscaleAddress,
    this.log,
    this.restartDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
    this.checkTimeout = const Duration(seconds: 3),
  });

  final Directory dir;
  final int port;

  /// The private (Tailscale) address to listen on as well; null = none.
  final Future<String?> Function() privateAddress;
  final void Function(String line)? log;
  final List<Duration> restartDelays;
  final Duration checkTimeout;

  HubHostState state = HubHostState.off;
  List<String> listening = const [];
  String? problem;

  /// How many hub isolates were started (tests: never two at once).
  int starts = 0;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _events;
  final _replies = <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;
  bool _stopping = false;
  int _failures = 0;
  DateTime? _restartAt;
  int _loopbackFailures = 0;
  Future<void>? _starting;

  int get _boundPort =>
      int.tryParse(listening.firstOrNull?.split(':').last ?? '') ?? port;

  void _log(String line) => log?.call(line);

  /// Starts the hub (once): uses a hub already running on the port, or
  /// runs one in a new isolate.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    _stopping = false;
    state = HubHostState.starting;
    if (port != 0 && await _answers('127.0.0.1', port)) {
      state = HubHostState.external;
      listening = ['127.0.0.1:$port'];
      problem = null;
      _log('Hub: another hub process already serves port $port; using it');
      return;
    }
    await _spawn();
  }

  Future<void> _spawn() async {
    final events = _events = ReceivePort();
    final ready = Completer<Map<String, dynamic>>();
    events.listen((message) {
      // onError sends [error, stack] (strings); onExit sends null.
      if (message is List) {
        _log(
          'Hub: uncaught error in the hub '
          '(${'${message.firstOrNull}'.split(':').first})',
        );
        return;
      }
      if (message == null) {
        if (!ready.isCompleted) {
          ready.complete({'kind': 'startError', 'message': 'hub ended'});
        }
        _onExit();
        return;
      }
      if (message is! Map) return;
      final m = message.cast<String, dynamic>();
      switch (m['kind']) {
        case 'ready' || 'startError':
          if (!ready.isCompleted) ready.complete(m);
        case 'reply':
          _replies.remove(m['id'])?.complete(m);
      }
    });
    starts++;
    final host = await privateAddress();
    try {
      _isolate = await Isolate.spawn(
        _hubMain,
        _HubArgs(dir.path, port, host, events.sendPort),
        onExit: events.sendPort,
        onError: events.sendPort,
        errorsAreFatal: false,
        debugName: 'misc. hub',
      );
      // An exit or uncaught error message arrives as a non-map (handled
      // below by _onExit through the listener); give start a bound.
      final m = await ready.future.timeout(const Duration(seconds: 30));
      if (m['kind'] == 'startError') {
        _discard();
        throw StateError('${m['message']}');
      }
      _commands = m['commands'] as SendPort;
      listening = (m['listening'] as List).cast<String>();
      state = HubHostState.running;
      problem = null;
      _failures = 0;
      _loopbackFailures = 0;
      _log('Hub: running inside misc. on ${listening.join(', ')}');
      await _writeRunFile();
    } catch (e) {
      _discard();
      _failures++;
      final busy =
          e.toString().contains('SocketException') ||
          e.toString().toLowerCase().contains('address');
      problem = busy
          ? 'The hub could not listen on port $port (another program may use it).'
          : 'The hub could not start (${e.runtimeType}).';
      state = HubHostState.recovering;
      _restartAt = DateTime.now().add(_delay());
      _log(
        'Hub: start failed (${e.runtimeType}); next try in ${_delay().inSeconds} s',
      );
    }
  }

  Duration _delay() =>
      restartDelays[(_failures - 1).clamp(0, restartDelays.length - 1)];

  /// The isolate ended (its onExit/onError) without being asked to.
  void _onExit() {
    if (_stopping || _isolate == null) return;
    _discard();
    _failures++;
    state = HubHostState.recovering;
    problem = 'The hub stopped unexpectedly; starting it again.';
    _restartAt = DateTime.now().add(_delay());
    _log('Hub: stopped unexpectedly; restart in ${_delay().inSeconds} s');
  }

  void _discard() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    _events?.close();
    _events = null;
    for (final r in _replies.values) {
      if (!r.isCompleted) r.completeError(StateError('hub gone'));
    }
    _replies.clear();
  }

  Future<Map<String, dynamic>> _ask(
    String cmd, [
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    final port = _commands;
    if (port == null) throw StateError('hub not running');
    final id = _nextId++;
    final reply = _replies[id] = Completer<Map<String, dynamic>>();
    port.send({'id': id, 'cmd': cmd, ...args});
    try {
      final m = await reply.future.timeout(timeout);
      if (m['error'] != null) throw StateError('${m['error']}');
      return m;
    } finally {
      _replies.remove(id);
    }
  }

  /// Whether a THEapp hub answers at [host]:[port].
  Future<bool> _answers(String host, int port) async {
    final client = HttpClient()..connectionTimeout = checkTimeout;
    try {
      final req = await client
          .getUrl(Uri.parse('http://$host:$port/v1/status'))
          .timeout(checkTimeout);
      final res = await req.close().timeout(checkTimeout);
      final body = await utf8.decodeStream(res).timeout(checkTimeout);
      return res.statusCode == 200 && body.contains('THEapp hub');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// One health check (every 10 seconds while THEapp runs): answers on
  /// this PC and on the private address, follows a changed or new
  /// Tailscale address, and starts the hub again only after a real stop.
  Future<HubHealth> check() async {
    if (_stopping || state == HubHostState.off) {
      return HubHealth(state: state, listening: listening, problem: problem);
    }
    await _starting;
    if (state == HubHostState.external) {
      if (await _answers('127.0.0.1', port)) {
        return HubHealth(state: state, listening: listening);
      }
      // The other hub process ended: run one here instead.
      _log('Hub: the other hub process stopped; starting one in misc.');
      await _spawn();
      return HubHealth(
        state: state,
        listening: listening,
        problem: problem,
        recovered: state == HubHostState.running ? 'hub started' : null,
      );
    }
    if (state == HubHostState.recovering) {
      final at = _restartAt;
      if (at != null && DateTime.now().isBefore(at)) {
        return HubHealth(state: state, listening: listening, problem: problem);
      }
      if (port != 0 && await _answers('127.0.0.1', port)) {
        state = HubHostState.external; // someone else started one meanwhile
        listening = ['127.0.0.1:$port'];
        problem = null;
        return HubHealth(
          state: state,
          listening: listening,
          recovered: 'using the other hub',
        );
      }
      await _spawn();
      return HubHealth(
        state: state,
        listening: listening,
        problem: problem,
        recovered: state == HubHostState.running ? 'hub restarted' : null,
      );
    }
    // Running here.
    String? recovered;
    try {
      final status = await _ask(
        'status',
        const {},
        const Duration(seconds: 10),
      );
      final want = await privateAddress();
      final have = status['privateHost'] as String?;
      if (want != have || status['listenerLost'] == true) {
        await _ask('setPrivate', {'host': want});
        recovered = want == null
            ? 'stopped listening on $have (address gone)'
            : 'listening again on $want';
        _log('Hub: $recovered');
      }
      listening = ((await _ask('status'))['listening'] as List).cast<String>();
    } catch (e) {
      _log('Hub: status check failed (${e.runtimeType})');
    }
    // What a device sees: a real request to each address.
    final loopbackOk = await _answers('127.0.0.1', _boundPort);
    if (!loopbackOk) {
      _loopbackFailures++;
      if (_loopbackFailures >= 3) {
        // Alive but not serving for 30 seconds: start it again.
        _log('Hub: not answering on 127.0.0.1 for 3 checks; restarting it');
        await _restartNow();
        return HubHealth(
          state: state,
          listening: listening,
          problem: problem,
          recovered: state == HubHostState.running ? 'hub restarted' : null,
        );
      }
      problem = 'The hub did not answer on this PC.';
      return HubHealth(state: state, listening: listening, problem: problem);
    }
    _loopbackFailures = 0;
    final private = listening
        .where((l) => !l.startsWith('127.'))
        .map((l) => l.substring(0, l.lastIndexOf(':')))
        .firstOrNull;
    if (private != null && !await _answers(private, _boundPort)) {
      problem = 'The hub does not answer on $private (Tailscale) yet.';
      return HubHealth(
        state: state,
        listening: listening,
        problem: problem,
        recovered: recovered,
      );
    }
    problem = null;
    return HubHealth(state: state, listening: listening, recovered: recovered);
  }

  /// The hub stopped answering: the isolate closes its listeners cleanly
  /// and starts the server again (same data, same port). An isolate that
  /// does not even answer that is ended; its port may stay held in this
  /// process (a Dart limitation), and the status then says so plainly.
  Future<void> _restartNow() async {
    _loopbackFailures = 0;
    try {
      final m = await _ask(
        'restartServer',
        const {},
        const Duration(seconds: 15),
      );
      listening = (m['listening'] as List).cast<String>();
      problem = null;
      return;
    } catch (_) {
      // Not answering at all: end it and start a new one below.
    }
    _stopping = true;
    _discard();
    _stopping = false;
    _failures++;
    await _spawn();
    if (state != HubHostState.running) {
      problem =
          'The hub stopped responding and its port is still held. Close and '
          'reopen misc. to start it again (your data is safe).';
      state = HubHostState.failed;
      _log('Hub: unresponsive and port held; misc. needs a restart');
    }
  }

  /// A frequent hub backup if anything changed since the last one; null
  /// when nothing changed (or the hub is not run by THEapp).
  Future<String?> backupLive() async {
    if (state != HubHostState.running) return null;
    final m = await _ask('backupLive', const {}, const Duration(minutes: 2));
    return m['backup'] as String?;
  }

  /// Tests: an uncaught error inside the hub; the hub must keep serving.
  Future<void> debugThrow() => _ask('debugThrow');

  /// Tests: the server stops answering while its isolate lives.
  Future<void> debugCloseListeners() => _ask('debugCloseListeners');

  /// Tests: the hub isolate ends by itself (after closing its sockets).
  Future<void> debugExit() => _ask('debugExit');

  /// Stops the hub this app runs (an outside hub is left alone).
  Future<void> stop() async {
    _stopping = true;
    if (_isolate != null) {
      try {
        await _ask('stop', const {}, const Duration(seconds: 10));
      } catch (_) {
        // Ended below in any case.
      }
      await _deleteRunFile();
    }
    _discard();
    state = HubHostState.off;
    _starting = null;
  }

  File get _runFile => File('${dir.path}${Platform.pathSeparator}hub.json');

  Future<void> _writeRunFile() async {
    try {
      final tmp = File('${_runFile.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'pid': pid,
          'port': _boundPort,
          'listening': listening,
          'embedded': true,
          'startedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      await tmp.rename(_runFile.path);
    } on FileSystemException catch (e) {
      _log('Hub: could not write hub.json (${e.osError?.errorCode})');
    }
  }

  Future<void> _deleteRunFile() async {
    try {
      final json = jsonDecode(await _runFile.readAsString());
      if (json is Map && json['pid'] == pid) await _runFile.delete();
    } catch (_) {
      // Missing or another process's: left alone.
    }
  }
}

class _HubArgs {
  const _HubArgs(this.dir, this.port, this.privateHost, this.events);
  final String dir;
  final int port;
  final String? privateHost;
  final SendPort events;
}

/// The hub isolate: starts the server, then answers commands. Errors are
/// caught by a guarded zone, logged, and the hub keeps serving: an isolate
/// that ends abruptly keeps its listening port in this process, so it must
/// never end that way.
void _hubMain(_HubArgs args) {
  final dir = Directory(args.dir);
  final logFile = File(
    '${dir.path}${Platform.pathSeparator}logs${Platform.pathSeparator}hub.log',
  );
  void log(String line) {
    try {
      logFile.parent.createSync(recursive: true);
      logFile.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // The log must never stop the hub.
    }
  }

  runZonedGuarded(
    () => _serveCommands(args, dir, log),
    (error, stack) => log('Hub: uncaught ${error.runtimeType}; still running'),
  );
}

/// Starts the server; a private address that is not usable right now
/// (Tailscale not up yet) must not keep the hub off this PC: it starts
/// without it and the health check adds it when it appears.
Future<HubServer> _startServer(
  Directory dir,
  int port,
  String? privateHost,
  void Function(String) log,
) async {
  try {
    return await HubServer.start(
      dir: dir,
      port: port,
      privateHost: privateHost,
      log: log,
    );
  } on ArgumentError {
    return HubServer.start(dir: dir, port: port, log: log);
  }
}

Future<void> _serveCommands(
  _HubArgs args,
  Directory dir,
  void Function(String) log,
) async {
  HubServer server;
  try {
    server = await _startServer(dir, args.port, args.privateHost, log);
  } catch (e) {
    args.events.send({'kind': 'startError', 'message': '$e'});
    Isolate.exit();
  }
  // The port actually bound (args.port may be 0 in tests), kept for a
  // restart: a server whose listeners all closed no longer knows it.
  final boundPort = server.port;
  final commands = ReceivePort();
  args.events.send({
    'kind': 'ready',
    'commands': commands.sendPort,
    'listening': server.listening,
  });
  var lastLiveSeq = -1;
  await for (final message in commands) {
    if (message is! Map) continue;
    final id = message['id'];
    Map<String, dynamic> reply;
    try {
      switch (message['cmd']) {
        case 'status':
          reply = {
            'listening': server.listening,
            'privateHost': server.privateHost,
            'listenerLost': server.listenerLost,
            'servesLoopback': server.servesLoopback,
            'lastSeq': server.store.lastSeq,
          };
        case 'setPrivate':
          try {
            await server.setPrivateHost(message['host'] as String?);
          } on ArgumentError {
            await server.setPrivateHost(null);
          }
          reply = {'listening': server.listening};
        case 'restartServer':
          // Alive but not answering: close every listener cleanly (which
          // frees the port) and start the server again on the same data.
          final private = server.privateHost;
          await server.stop();
          server = await _startServer(dir, boundPort, private, log);
          log('Hub: server restarted after it stopped answering');
          reply = {'listening': server.listening};
        case 'backupLive':
          final seq = server.store.lastSeq;
          if (seq == lastLiveSeq) {
            reply = {'backup': null};
          } else {
            final b = await server.backups.createLive();
            lastLiveSeq = seq;
            reply = {'backup': b.path};
          }
        case 'debugThrow':
          // Tests: an error nobody catches (the zone must keep the hub up).
          unawaited(Future<void>.error(StateError('test')));
          reply = {};
        case 'debugCloseListeners':
          // Tests: the server stops answering while the isolate lives.
          await server.closeListenersForTest();
          reply = {};
        case 'stop' || 'debugExit':
          await server.stop();
          args.events.send({'kind': 'reply', 'id': id});
          commands.close();
          if (message['cmd'] == 'debugExit') Isolate.exit();
          return;
        default:
          reply = {'error': 'unknown command'};
      }
    } catch (e) {
      log('Hub command ${message['cmd']} failed: ${e.runtimeType}');
      reply = {'error': '${e.runtimeType}'};
    }
    args.events.send({'kind': 'reply', 'id': id, ...reply});
  }
}
