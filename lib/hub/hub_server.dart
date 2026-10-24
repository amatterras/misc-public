// The hub's HTTP service. Pure Dart (dart:io only).
//
// Endpoints are documented in SYNC_ARCHITECTURE.md §10. Every data endpoint
// requires a device token; admin endpoints require the admin token and only
// answer requests from this PC. Logs never contain record content, URLs,
// tokens or attachment ids.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../sync/protocol.dart';
import 'hub_auth.dart';
import 'hub_backup.dart';
import 'hub_store.dart';

const defaultHubPort = 47710;

/// Addresses the hub may listen on: this PC only, or a private network
/// (home LAN, or the Tailscale range 100.64.0.0/10). Never "all
/// interfaces" and never a public address.
bool isAllowedBindAddress(InternetAddress a) {
  if (a.isLoopback) return true;
  if (a.address == '0.0.0.0' || a.address == '::') return false;
  if (a.type == InternetAddressType.IPv4) {
    final b = a.rawAddress;
    if (b[0] == 10) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true; // Tailscale
    return false;
  }
  // Tailscale IPv6 (fd7a:115c:a1e0::/48) and other unique-local addresses.
  return (a.rawAddress[0] & 0xfe) == 0xfc;
}

class HubServer {
  HubServer._(
    this.store,
    this.auth,
    this.backups,
    this._servers,
    this._log, {
    this.tenantId,
  });

  /// One account's hub inside the hosted service (hosted_hub.dart): it
  /// listens on nothing itself; the hosted front passes it the requests
  /// whose token belongs to that account. Admin, pairing and share
  /// endpoints are off; device tokens are `<tenantId>.<token>`.
  static Future<HubServer> tenant(
    Directory dir,
    String tenantId, {
    void Function(String line)? log,
  }) async {
    final store = await HubStore.open(dir);
    final auth = await HubAuth.open(dir);
    return HubServer._(
      store,
      auth,
      HubBackups(store),
      const [],
      log ?? (_) {},
      tenantId: tenantId,
    );
  }

  /// Set for an account inside the hosted service.
  final String? tenantId;

  /// Handles one request (used by the hosted front).
  Future<void> handle(HttpRequest r) => _handle(r);

  final HubStore store;
  final HubAuth auth;
  final HubBackups backups;

  /// Always this PC (127.0.0.1); optionally also one private address.
  final List<HttpServer> _servers;
  final void Function(String line) _log;
  final _done = Completer<void>();
  final Map<String, List<DateTime>> _failedPairing = {};
  Timer? _backupTimer;

  InternetAddress get address => _servers.first.address;
  int get port => _servers.first.port;

  /// Every address the hub is listening on.
  List<String> get listening => [
    for (final s in _servers) '${s.address.address}:${s.port}',
  ];

  /// Completes when the server has stopped (e.g. via the admin shutdown).
  Future<void> get done => _done.future;

  /// Starts the hub on 127.0.0.1 and, if [privateHost] is given, also on
  /// that private/Tailscale address (which must belong to this computer).
  static Future<HubServer> start({
    required Directory dir,
    int port = defaultHubPort,
    String? privateHost,
    void Function(String line)? log,
    bool dailyBackups = true,
  }) async {
    final extra = privateHost == null
        ? null
        : await _checkPrivateHost(privateHost);
    final store = await HubStore.open(dir);
    final auth = await HubAuth.open(dir);
    final servers = <HttpServer>[];
    try {
      servers.add(await HttpServer.bind(InternetAddress.loopbackIPv4, port));
      if (extra != null) {
        servers.add(await HttpServer.bind(extra, servers.first.port));
      }
    } catch (_) {
      for (final s in servers) {
        await s.close(force: true);
      }
      await store.close();
      rethrow;
    }
    final server = HubServer._(
      store,
      auth,
      HubBackups(store),
      servers,
      log ?? (_) {},
    );
    server._paused = await server._pausedFile.exists();
    try {
      await server._purgeExpiredArchives();
    } catch (error) {
      server._log('Calendar retention cleanup FAILED: ${error.runtimeType}');
    }
    for (final http in servers) {
      server._serve(http);
    }
    if (dailyBackups) {
      unawaited(server._backup());
      server._backupTimer = Timer.periodic(
        const Duration(hours: 24),
        (_) => server._backup(),
      );
    }
    server._log(
      'Hub listening on ${server.listening.join(', ')} (protocol $syncProtocolVersion)',
    );
    return server;
  }

  Future<void> _backup() async {
    try {
      final b = await backups.create();
      _log('Backup ok: ${b.uri.pathSegments.where((s) => s.isNotEmpty).last}');
    } catch (e) {
      _log('Backup FAILED: ${e.runtimeType}');
    }
  }

  Future<void> _purgeExpiredArchives() async {
    final ids = await store.expiredCalendarEntryIds();
    if (ids.isEmpty) return;
    // The current hub journal is compacted to current versions first; the
    // backup sanitizer then replaces historical copies with the tombstone.
    await store.compact();
    for (final id in ids) {
      await backups.purgeExpiredCalendarEntry(id);
    }
  }

  /// The private/Tailscale address [privateHost] as an address this hub
  /// may listen on; throws [ArgumentError] otherwise.
  static Future<InternetAddress> _checkPrivateHost(String privateHost) async {
    final extra = InternetAddress.tryParse(privateHost);
    if (extra == null || extra.isLoopback || !isAllowedBindAddress(extra)) {
      throw ArgumentError(
        'Refusing to listen on "$privateHost": only a private or Tailscale '
        'address of this computer is allowed (never 0.0.0.0 or a public IP).',
      );
    }
    final mine = [
      for (final i in await NetworkInterface.list(includeLoopback: false))
        for (final a in i.addresses) a.address,
    ];
    if (!mine.contains(extra.address)) {
      throw ArgumentError('"$privateHost" is not an address of this computer.');
    }
    return extra;
  }

  /// Serves requests from [http]. A failing listener (e.g. its network
  /// address went away when Wi-Fi dropped or Tailscale restarted) is
  /// logged and dropped; it never takes the hub down. Before, a listener
  /// error had no handler and ended the whole hub process.
  void _serve(HttpServer http) {
    http.idleTimeout = const Duration(seconds: 30);
    final address = '${http.address.address}:${http.port}';
    http.listen(
      _handle,
      onError: (Object error, StackTrace _) {
        _log('Listener $address error (${error.runtimeType}); recovering');
      },
      onDone: () {
        if (_stopping) return;
        _servers.remove(http);
        listenerLost = true;
        _log('Listener $address closed unexpectedly');
      },
      cancelOnError: false,
    );
  }

  bool _stopping = false;

  /// A listener closed by itself (see [_serve]); the host checks this and
  /// listens again. Cleared by [setPrivateHost].
  bool listenerLost = false;

  /// Whether the hub still listens on this PC (127.0.0.1).
  bool get servesLoopback => _servers.any((s) => s.address.isLoopback);

  /// The private/Tailscale address the hub listens on, if any.
  String? get privateHost => _servers
      .where((s) => !s.address.isLoopback)
      .map((s) => s.address.address)
      .firstOrNull;

  /// Listens on [host] (a private/Tailscale address of this PC) instead of
  /// the current private address, or on none (null). The 127.0.0.1
  /// listener and every device's connection there are not touched; the
  /// same port is kept, so paired devices need nothing new.
  Future<void> setPrivateHost(String? host) async {
    final address = host == null ? null : await _checkPrivateHost(host);
    for (final s in [..._servers]) {
      if (s.address.isLoopback) continue;
      _servers.remove(s);
      await s.close(force: true);
    }
    if (address != null) {
      final http = await HttpServer.bind(address, port);
      _servers.add(http);
      _serve(http);
    }
    listenerLost = false;
    _log('Hub listening on ${listening.join(', ')}');
  }

  /// Tests: every listener closes as if by itself (the hub then answers
  /// nothing until it is restarted).
  Future<void> closeListenersForTest() async {
    for (final s in [..._servers]) {
      await s.close(force: true);
    }
  }

  Future<void> stop() async {
    _stopping = true;
    _backupTimer?.cancel();
    store.wakeWaiters(); // long-polls answer now instead of holding the stop
    for (final s in _servers) {
      await s.close();
    }
    await store.close();
    if (!_done.isCompleted) _done.complete();
    _log('Hub stopped');
  }

  // ------------------------------------------------------------ helpers --

  String? _bearer(HttpRequest r) {
    final h = r.headers.value(HttpHeaders.authorizationHeader);
    if (h == null || !h.startsWith('Bearer ')) return null;
    final token = h.substring(7).trim();
    final t = tenantId;
    if (t == null) return token;
    // Hosted: the account part must be this account's.
    return token.startsWith('$t.') ? token.substring(t.length + 1) : null;
  }

  Future<Map<String, dynamic>> _json(HttpRequest r) async {
    final length = r.contentLength;
    if (length > maxJsonBodyBytes) {
      throw const ProtocolException(
        'too_large',
        'Request body is too large.',
        status: 413,
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in r) {
      builder.add(chunk);
      if (builder.length > maxJsonBodyBytes) {
        throw const ProtocolException(
          'too_large',
          'Request body is too large.',
          status: 413,
        );
      }
    }
    try {
      final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    throw const ProtocolException('bad_request', 'Body must be a JSON object.');
  }

  static Future<void> _send(HttpRequest r, int status, Object body) async {
    r.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.set('cache-control', 'no-store')
      ..write(jsonEncode(body));
    await r.response.close();
  }

  void _checkProtocol(HttpRequest r) {
    if (r.headers.value(protocolHeader) != '$syncProtocolVersion') {
      throw ProtocolException(
        'protocol_mismatch',
        'This hub speaks sync protocol $syncProtocolVersion; update the app.',
        status: 426,
      );
    }
  }

  // ------------------------------------------------------- pause switch --
  //
  // Sync can be paused from the Windows app (Settings → Sync). While paused,
  // devices get `sync_paused` (503, retryable) for every sync request and
  // keep their changes queued; nothing is lost or marked as synced. Read-only
  // mirrors keep reading (backups continue). The state survives a restart.

  bool _paused = false;
  bool get paused => _paused;
  File get _pausedFile =>
      File('${store.dir.path}${Platform.pathSeparator}paused');

  Future<void> setPaused(bool on) async {
    if (on) {
      await _pausedFile.writeAsString('paused');
    } else if (await _pausedFile.exists()) {
      await _pausedFile.delete();
    }
    _paused = on;
    store.wakeWaiters(); // waiting devices hear about it now
    _log(on ? 'Sync paused' : 'Sync resumed');
  }

  /// The device of a sync request: refused while paused (except read-only
  /// mirrors reading), and refused for writes from read-only devices.
  HubDevice _syncDevice(HttpRequest r, {bool write = false}) {
    final d = _device(r);
    if (write && d.readOnly) {
      throw const ProtocolException(
        'read_only',
        'This device may only read from the hub.',
        status: 403,
      );
    }
    if (_paused && (write || !d.readOnly)) {
      throw const ProtocolException(
        'sync_paused',
        'Sync is paused on the PC. Your changes are kept and sync when it is '
            'turned on again.',
        status: 503,
      );
    }
    return d;
  }

  HubDevice _device(HttpRequest r) {
    final token = _bearer(r);
    final device = token == null ? null : auth.authenticate(token);
    if (device == null) {
      throw const ProtocolException(
        'unauthorized',
        'Missing or invalid device token.',
        status: 401,
      );
    }
    return device;
  }

  void _admin(HttpRequest r) {
    if (tenantId != null) {
      throw const ProtocolException(
        'not_found',
        'Unknown endpoint.',
        status: 404,
      );
    }
    final remote = r.connectionInfo?.remoteAddress;
    final token = _bearer(r);
    if (remote == null ||
        !remote.isLoopback ||
        token == null ||
        !auth.isAdmin(token)) {
      throw const ProtocolException(
        'unauthorized',
        'Admin access is only allowed from this PC.',
        status: 401,
      );
    }
  }

  // ------------------------------------------------------------ routing --

  Future<void> _handle(HttpRequest r) async {
    final watch = Stopwatch()..start();
    var route = r.uri.path;
    String who = '-';
    var status = 200;
    try {
      final segments = r.uri.pathSegments;
      if (segments.length == 3 &&
          segments[0] == 'v1' &&
          segments[1] == 'attachments') {
        route = '/v1/attachments/:sha';
      } else if (segments.length == 2 && segments[0] == 's') {
        route = '/s/:token'; // never logged with the token
      }
      switch ((r.method, route)) {
        case ('GET', '/s/:token') when tenantId == null:
          who = 'share';
          status = await _serveShare(r, segments[1]);
        case ('GET', '/v1/status'):
          await _send(r, 200, {
            'service': 'THEapp hub',
            'hubId': store.hubId,
            'protocol': syncProtocolVersion,
            'paused': _paused,
          });
        case ('POST', '/v1/register') when tenantId == null:
          _checkProtocol(r);
          await _register(r);
        case ('POST', '/v1/push'):
          _checkProtocol(r);
          final d = _syncDevice(r, write: true);
          who = d.id;
          final body = await _json(r);
          final raw = body['changes'];
          if (raw is! List) {
            throw const ProtocolException('bad_request', 'Missing changes.');
          }
          final changes = [
            for (final c in raw) SyncChange.fromJson(c as Map<String, dynamic>),
          ];
          final results = await store.push(d.id, changes);
          if (changes.any(
            (change) =>
                change.collection == 'calendar_entry_expirations' &&
                !change.deleted,
          )) {
            await _purgeExpiredArchives();
          }
          await _send(r, 200, {
            'results': [for (final x in results) x.toJson()],
            'lastSeq': store.lastSeq,
            'hubId': store.hubId,
          });
        // Long-poll: answers as soon as the hub has anything newer than
        // `since`, or after `timeout` seconds (≤25) as a heartbeat. Devices
        // then pull as usual; this endpoint carries no record data.
        case ('GET', '/v1/wait'):
          _checkProtocol(r);
          final device = _device(r);
          who = device.id;
          final since = int.tryParse(r.uri.queryParameters['since'] ?? '');
          final seconds =
              int.tryParse(r.uri.queryParameters['timeout'] ?? '') ?? 25;
          if (since == null || since < 0) {
            throw const ProtocolException('bad_request', 'Invalid since.');
          }
          final limit = Duration(seconds: seconds.clamp(1, 25));
          final int lastSeq;
          if (_paused && !device.readOnly) {
            // While paused the request is held, so the device hears the
            // moment sync resumes (setPaused wakes it) and pulls at once;
            // still paused at the end: "paused".
            await store.waitForChange(1 << 52, limit);
            if (_paused) _syncDevice(r); // throws sync_paused
            lastSeq = store.lastSeq;
          } else {
            lastSeq = await store.waitForChange(since, limit);
          }
          await _send(r, 200, {'lastSeq': lastSeq, 'hubId': store.hubId});
        case ('GET', '/v1/changes'):
          _checkProtocol(r);
          who = _syncDevice(r).id;
          final since = int.tryParse(r.uri.queryParameters['since'] ?? '0');
          final limit = int.tryParse(
            r.uri.queryParameters['limit'] ?? '$defaultPullLimit',
          );
          if (since == null || since < 0 || limit == null || limit < 1) {
            throw const ProtocolException(
              'bad_request',
              'Invalid since/limit.',
            );
          }
          final page = await store.changesSince(since, limit);
          await _send(r, 200, {
            'changes': [for (final c in page.changes) c.toJson()],
            'next': page.next,
            'hasMore': page.hasMore,
            'lastSeq': store.lastSeq,
            'hubId': store.hubId,
          });
        case ('HEAD', '/v1/attachments/:sha'):
          _checkProtocol(r);
          who = _syncDevice(r).id;
          final exists = await store.hasAttachment(segments[2]);
          r.response.statusCode = exists ? 200 : 404;
          await r.response.close();
        case ('PUT', '/v1/attachments/:sha'):
          _checkProtocol(r);
          who = _syncDevice(r, write: true).id;
          final size = r.contentLength;
          if (size < 0) {
            throw const ProtocolException(
              'bad_request',
              'Content-Length is required.',
              status: 411,
            );
          }
          await store.putAttachment(segments[2], size, r);
          await _send(r, 200, {'ok': true});
        case ('GET', '/v1/attachments/:sha'):
          _checkProtocol(r);
          who = _syncDevice(r).id;
          final file = store.attachmentFile(segments[2]);
          if (!await file.exists()) {
            throw const ProtocolException(
              'not_found',
              'No such attachment.',
              status: 404,
            );
          }
          r.response
            ..statusCode = 200
            ..headers.contentType = ContentType.binary
            ..headers.contentLength = await file.length();
          await r.response.addStream(file.openRead());
          await r.response.close();
        case ('GET', '/v1/admin/status'):
          _admin(r);
          who = 'admin';
          await _send(r, 200, {
            ...store.stats.toJson(),
            'devices': [
              for (final d in auth.devices)
                {'id': d.id, 'name': d.name, 'revoked': d.revoked},
            ],
            'backups': (await backups.list()).length,
            'listening': listening,
            'rssBytes': ProcessInfo.currentRss,
          });
        case ('POST', '/v1/admin/pair'):
          _admin(r);
          who = 'admin';
          await _send(r, 200, {
            'code': auth.createPairingCode(),
            'expiresInMinutes': HubAuth.pairingLifetime.inMinutes,
          });
        case ('POST', '/v1/admin/revoke'):
          _admin(r);
          who = 'admin';
          final id = (await _json(r))['deviceId'];
          await _send(r, 200, {
            'revoked': id is String && await auth.revoke(id),
          });
        case ('POST', '/v1/admin/pause'):
          _admin(r);
          who = 'admin';
          final on = (await _json(r))['paused'];
          if (on is! bool) {
            throw const ProtocolException(
              'bad_request',
              'paused: true or false.',
            );
          }
          await setPaused(on);
          await _send(r, 200, {'paused': _paused});
        case ('POST', '/v1/admin/backup'):
          _admin(r);
          who = 'admin';
          final b = await backups.create();
          await _send(r, 200, {
            'backup': b.path,
            'verified': await HubBackups.verify(b),
          });
        case ('POST', '/v1/admin/compact'):
          _admin(r);
          who = 'admin';
          await backups.create(); // never compact without a fresh backup
          await store.compact();
          await _send(r, 200, store.stats.toJson());
        case ('POST', '/v1/admin/shutdown'):
          _admin(r);
          who = 'admin';
          await _send(r, 200, {'stopping': true});
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 50), stop),
          );
        default:
          throw const ProtocolException(
            'not_found',
            'Unknown endpoint.',
            status: 404,
          );
      }
    } on ProtocolException catch (e) {
      status = e.status;
      await _drain(r);
      await _trySend(r, e.status, e.toJson());
    } catch (e) {
      status = 500;
      _log('Internal error on $route: ${e.runtimeType}');
      await _trySend(
        r,
        500,
        const ProtocolException(
          'internal',
          'The hub hit an internal error.',
        ).toJson(),
      );
    } finally {
      final ms = watch.elapsedMilliseconds;
      final shortWho = who.length > 4 ? '${who.substring(0, 4)}…' : who;
      // Successful long-polls are routine heartbeats: not logged.
      if (!(route == '/v1/wait' && status == 200)) {
        _log('${r.method} $route -> $status ${ms}ms by $shortWho');
      }
    }
  }

  /// A read-only share page (see ShareLink): no device token, only the
  /// link's secret. Unknown, revoked and expired links all get the same
  /// "not available" answer.
  Future<int> _serveShare(HttpRequest r, String token) async {
    Map<String, dynamic>? data;
    if (_shareToken.hasMatch(token)) {
      final id = sha256.convert(utf8.encode(token)).toString();
      final c = await store.current('shares', id);
      data = c == null || c.deleted ? null : c.data;
    }
    final expires = DateTime.tryParse('${data?['expiresAt'] ?? ''}');
    final ok =
        data != null &&
        data['revoked'] != true &&
        (expires == null || DateTime.now().toUtc().isBefore(expires.toUtc()));
    final title = ok ? '${data['title'] ?? ''}' : 'Not available';
    final body = ok
        ? '${data['body'] ?? ''}'
        : 'This link does not exist, was revoked or has expired.';
    const esc = HtmlEscape();
    final status = ok ? 200 : 404;
    r.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..headers.set('cache-control', 'no-store')
      ..headers.set('x-content-type-options', 'nosniff')
      ..headers.set('referrer-policy', 'no-referrer')
      ..headers.set('x-frame-options', 'DENY')
      ..headers.set(
        'content-security-policy',
        "default-src 'none'; style-src 'unsafe-inline'",
      )
      ..write(
        '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="robots" content="noindex">'
        '<title>${esc.convert(title)}</title><style>body{font:16px/1.5 '
        'system-ui,sans-serif;max-width:720px;margin:2em auto;padding:0 16px;'
        'color:#222;background:#fafafa}pre{white-space:pre-wrap;font:inherit}'
        '</style></head><body><h1>${esc.convert(title)}</h1><pre>'
        '${esc.convert(body)}</pre><p style="color:#888;font-size:12px">'
        'Shared read-only from THEapp.</p></body></html>',
      );
    await r.response.close();
    return status;
  }

  static final _shareToken = RegExp(r'^[A-Za-z0-9_-]{20,100}$');

  static Future<void> _drain(HttpRequest r) async {
    try {
      await r.drain<void>();
    } catch (_) {}
  }

  static Future<void> _trySend(HttpRequest r, int status, Object body) async {
    try {
      await _send(r, status, body);
    } catch (_) {
      // The client went away; nothing to tell it.
    }
  }

  Future<void> _register(HttpRequest r) async {
    final remote = r.connectionInfo?.remoteAddress.address ?? '?';
    final now = DateTime.now();
    final recent = (_failedPairing[remote] ?? [])
      ..removeWhere((t) => now.difference(t) > const Duration(minutes: 10));
    if (recent.length >= 5) {
      throw const ProtocolException(
        'rate_limited',
        'Too many wrong pairing codes; wait 10 minutes.',
        status: 429,
      );
    }
    final body = await _json(r);
    final code = body['pairingCode'],
        id = body['deviceId'],
        name = body['deviceName'];
    if (code is! String || id is! String || name is! String) {
      throw const ProtocolException(
        'bad_request',
        'pairingCode, deviceId and deviceName are required.',
      );
    }
    try {
      final token = await auth.register(
        code,
        id,
        name,
        readOnly: body['readOnly'] == true,
      );
      _failedPairing.remove(remote);
      await _send(r, 200, {
        'token': token,
        'protocol': syncProtocolVersion,
        'lastSeq': store.lastSeq,
        'hubId': store.hubId,
      });
    } on ProtocolException {
      _failedPairing[remote] = recent..add(now);
      rethrow;
    }
  }
}
