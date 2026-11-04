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

import '../data/storage/log_sanitizer.dart';
import '../sync/protocol.dart';
import 'hub_auth.dart';
import 'hub_backup.dart';
import 'hub_store.dart';

const defaultHubPort = 47710;

/// Whether plain HTTP is acceptable on [a]: this PC itself, or a Tailscale
/// address (WireGuard encrypts that network). Any other network, including
/// an ordinary home LAN, needs HTTPS (see [HubServer.start] `tls`).
bool isPlainHttpAddress(InternetAddress a) {
  if (a.isLoopback) return true;
  if (a.type == InternetAddressType.IPv4) {
    final b = a.rawAddress;
    return b[0] == 100 && b[1] >= 64 && b[1] <= 127; // 100.64.0.0/10
  }
  final b = a.rawAddress;
  return b[0] == 0xfd &&
      b[1] == 0x7a &&
      b[2] == 0x11 &&
      b[3] == 0x5c &&
      b[4] == 0xa1 &&
      b[5] == 0xe0; // fd7a:115c:a1e0::/48
}

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
    // (Hosted devices sign in with a password and are all writable; a hosted
    // device without the key cannot write anything readable anyway: the
    // account's hub accepts only sealed records once it is switched over.)
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
    SecurityContext? tls,
    String? tlsCertSha256,
  }) async {
    final extra = privateHost == null
        ? null
        : await _checkPrivateHost(privateHost, tls: tls);
    final store = await HubStore.open(dir);
    final auth = await HubAuth.open(dir);
    final servers = <HttpServer>[];
    try {
      servers.add(await HttpServer.bind(InternetAddress.loopbackIPv4, port));
      if (extra != null) {
        servers.add(await _bindPrivate(extra, servers.first.port, tls));
      }
    } catch (_) {
      for (final s in servers) {
        await s.close(force: true);
      }
      await store.close();
      rethrow;
    }
    final server =
        HubServer._(store, auth, HubBackups(store), servers, log ?? (_) {})
          .._tls = tls
          .._certSha256 = tlsCertSha256;
    auth.keylessDevicesReadOnly = store.e2eeRequired;
    server._paused = await server._pausedFile.exists();
    try {
      await server._purgeExpiredArchives();
      await server._purgePurged();
    } catch (error) {
      server._log('Retention cleanup FAILED: ${error.runtimeType}');
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

  /// Records deleted for good: their old versions leave the journal and every
  /// backup (only the tombstone stays, which is also what refuses a revival).
  Future<void> _purgePurged() async {
    final keys = await store.purgedKeys();
    if (keys.isEmpty) return;
    await store.compact();
    for (final (collection, id) in keys) {
      await backups.purgeRecord(collection, id);
    }
    _log('Records deleted for good were removed from the journal and backups');
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
  static Future<InternetAddress> _checkPrivateHost(
    String privateHost, {
    SecurityContext? tls,
  }) async {
    final extra = InternetAddress.tryParse(privateHost);
    if (extra == null || extra.isLoopback || !isAllowedBindAddress(extra)) {
      throw ArgumentError(
        'Refusing to listen on "$privateHost": only a private or Tailscale '
        'address of this computer is allowed (never 0.0.0.0 or a public IP).',
      );
    }
    if (tls == null && !isPlainHttpAddress(extra)) {
      throw ArgumentError(
        'Refusing to listen on "$privateHost" without HTTPS: plain HTTP is '
        'only allowed on this PC and on Tailscale. Give the hub a TLS '
        'certificate (--tls-cert / --tls-key) to serve a home network.',
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

  /// HTTPS context for the non-loopback listener (null: plain HTTP is only
  /// possible on Tailscale).
  SecurityContext? _tls;
  String? _certSha256;

  /// SHA-256 (hex) of the DER certificate in a PEM file, for pairing codes
  /// (a device pins the certificate the code names).
  static String certSha256OfPem(String pem) => sha256
      .convert(
        base64Decode(
          pem
              .replaceAll(RegExp(r'-----[A-Z ]+-----'), '')
              .replaceAll(RegExp(r'\s'), ''),
        ),
      )
      .toString();

  static Future<HttpServer> _bindPrivate(
    InternetAddress address,
    int port,
    SecurityContext? tls,
  ) => tls != null && !isPlainHttpAddress(address)
      ? HttpServer.bindSecure(address, port, tls)
      : tls != null
      // Tailscale with a certificate (tailscale cert): HTTPS there too.
      ? HttpServer.bindSecure(address, port, tls)
      : HttpServer.bind(address, port);

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
    final address = host == null
        ? null
        : await _checkPrivateHost(host, tls: _tls);
    for (final s in [..._servers]) {
      if (s.address.isLoopback) continue;
      _servers.remove(s);
      await s.close(force: true);
    }
    if (address != null) {
      final http = await _bindPrivate(address, port, _tls);
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
            'certSha256': ?_certSha256,
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
          if (changes.any((c) => c.collection == 'purges' && !c.deleted)) {
            await _purgePurged();
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
          // A device removed while this was waiting gets "unauthorized", not
          // the news (and a removal ends every held wait at once).
          _device(r);
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
          if (!exists) {
            // How much of an interrupted upload the hub already holds.
            r.response.headers.set(
              'x-partial-bytes',
              '${await store.partialBytes(segments[2])}',
            );
          }
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
          final offsetHeader = r.headers.value('x-upload-offset');
          if (offsetHeader == null) {
            await store.putAttachment(segments[2], size, r);
            await _send(r, 200, {'ok': true});
          } else {
            // One piece of a resumable upload (HubStore.putAttachmentPart).
            final offset = int.tryParse(offsetHeader);
            final total = int.tryParse(r.headers.value('x-upload-total') ?? '');
            if (offset == null || total == null || offset < 0) {
              throw const ProtocolException(
                'bad_request',
                'Bad upload offset.',
              );
            }
            try {
              final complete = await store.putAttachmentPart(
                segments[2],
                offset: offset,
                total: total,
                data: r,
              );
              await _send(r, 200, {'ok': true, 'complete': complete});
            } on ProtocolException catch (e) {
              if (e.code == 'offset_mismatch') {
                r.response.headers.set(
                  'x-partial-bytes',
                  '${await store.partialBytes(segments[2])}',
                );
              }
              rethrow;
            }
          }
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
          final length = await file.length();
          // A download can continue where it stopped ("Range: bytes=N-").
          final range = RegExp(r'^bytes=(\d+)-$')
              .firstMatch(r.headers.value(HttpHeaders.rangeHeader) ?? '');
          final from = range == null ? 0 : int.parse(range.group(1)!);
          if (range != null && from >= length) {
            r.response.statusCode = 416;
            r.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */$length',
            );
            await r.response.close();
          } else {
            r.response
              ..statusCode = range == null ? 200 : 206
              ..headers.contentType = ContentType.binary
              ..headers.contentLength = length - from;
            if (range != null) {
              r.response.headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes $from-${length - 1}/$length',
              );
            }
            await r.response.addStream(file.openRead(from));
            await r.response.close();
          }
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
          // With an offer ({registerCode, wrappedKey}) the code is made by
          // the app and the hub never sees it; without, an ordinary code
          // (for read-only devices such as the mirror).
          final offer = r.contentLength > 0 ? await _json(r) : const {};
          if (offer['registerCode'] is String) {
            auth.createPairingOffer(
              registerCode: offer['registerCode'] as String,
              wrappedKey: '${offer['wrappedKey']}',
              readOnly: offer['readOnly'] == true,
            );
            await _send(r, 200, {
              'expiresInMinutes': HubAuth.pairingLifetime.inMinutes,
            });
          } else {
            await _send(r, 200, {
              'code': auth.createPairingCode(),
              'expiresInMinutes': HubAuth.pairingLifetime.inMinutes,
            });
          }
        // A paired, writable device offers another device the workspace key
        // (wrapped under the pairing code): used for hosted accounts and by
        // iPhone/iPad to add devices.
        case ('POST', '/v1/pairing'):
          _checkProtocol(r);
          who = _syncDevice(r, write: true).id;
          final offer = await _json(r);
          auth.createPairingOffer(
            registerCode: '${offer['registerCode']}',
            wrappedKey: '${offer['wrappedKey']}',
            readOnly: offer['readOnly'] == true,
          );
          await _send(r, 200, {
            'expiresInMinutes': HubAuth.pairingLifetime.inMinutes,
          });
        case ('POST', '/v1/pairing/redeem'):
          _checkProtocol(r);
          who = _device(r).id;
          final wrapped = auth.redeemPairingOffer(
            '${(await _json(r))['registerCode']}',
          );
          if (wrapped == null) {
            throw const ProtocolException(
              'pairing_failed',
              'The pairing code is wrong or has expired.',
              status: 401,
            );
          }
          await _send(r, 200, {'wrappedKey': wrapped});
        case ('GET', '/v1/e2ee'):
          _checkProtocol(r);
          who = _device(r).id;
          await _send(r, 200, {
            'required': store.e2eeRequired,
            'plaintextRecords': await store.countPlaintext(),
            'keyEpoch': store.keyEpoch,
          });
        // Devices: who is paired, when last seen, who can write, and each
        // device's public key with its endorsement (for key changes).
        case ('GET', '/v1/devices'):
          _checkProtocol(r);
          final me = _device(r);
          who = me.id;
          await _send(r, 200, {
            'self': me.id,
            'keyEpoch': store.keyEpoch,
            'devices': [
              for (final d in auth.devices)
                {
                  'id': d.id,
                  'name': d.name,
                  'createdAt': d.createdAt.toUtc().toIso8601String(),
                  if (d.lastSeen != null)
                    'lastSeen': d.lastSeen!.toUtc().toIso8601String(),
                  'readOnly': d.readOnly,
                  'revoked': d.revoked,
                  'publicKey': ?d.publicKey,
                  'endorsement': ?d.endorsement,
                },
            ],
          });
        case ('POST', '/v1/device-key'):
          _checkProtocol(r);
          final self = _device(r);
          who = self.id;
          final body = await _json(r);
          final pub = body['publicKey'], endorsement = body['endorsement'];
          if (pub is! String ||
              endorsement is! String ||
              !RegExp(r'^[A-Za-z0-9+/]{80,100}={0,2}$').hasMatch(pub) ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(endorsement)) {
            throw const ProtocolException('bad_request', 'Invalid device key.');
          }
          await auth.setDeviceKey(self.id, pub, endorsement);
          await _send(r, 200, {'ok': true});
        // Removes a device. Takes effect on the next request of that device
        // and ends its held connections; it only ever removes, never changes
        // who may write (a read-only mirror stays read-only).
        // Removes sealed attachment copies of a record deleted for good.
        case ('POST', '/v1/purge-blobs'):
          _checkProtocol(r);
          who = _syncDevice(r, write: true).id;
          final ids = (await _json(r))['ids'];
          final removed = ids is List && ids.length <= 20
              ? await store.deleteAttachments(ids.whereType<String>())
              : 0;
          await _send(r, 200, {'removed': removed});
        case ('POST', '/v1/devices/revoke'):
          _checkProtocol(r);
          who = _syncDevice(r, write: true).id;
          final target = (await _json(r))['deviceId'];
          final done = target is String && await auth.revoke(target);
          if (done) {
            store.wakeWaiters();
            _log('Device removed');
          }
          await _send(r, 200, {'revoked': done});
        case ('GET', '/v1/keys'):
          _checkProtocol(r);
          final self = _device(r);
          who = self.id;
          final since =
              int.tryParse(r.uri.queryParameters['since'] ?? '0') ?? 0;
          await _send(r, 200, {
            'epoch': store.keyEpoch,
            'wraps': [
              for (final w in store.wrapsFor(self.id, since))
                {'epoch': w.epoch, 'wrapped': w.wrapped},
            ],
          });
        case ('POST', '/v1/keys'):
          _checkProtocol(r);
          who = _syncDevice(r, write: true).id;
          final body = await _json(r);
          final epoch = body['epoch'], wraps = body['wraps'];
          if (epoch is! int || wraps is! Map || wraps.length > 100) {
            throw const ProtocolException('bad_request', 'Invalid key change.');
          }
          final live = {
            for (final d in auth.devices)
              if (!d.revoked) d.id,
          };
          final clean = <String, String>{};
          for (final e in wraps.entries) {
            if (e.key is String &&
                e.value is String &&
                live.contains(e.key) &&
                (e.value as String).length < 4096) {
              clean[e.key as String] = e.value as String;
            }
          }
          await store.rotateKeys(epoch, clean);
          _log('Workspace key changed');
          await _send(r, 200, {'epoch': store.keyEpoch});
        // Switches the hub to end-to-end encrypted only, once a device has
        // re-sent everything encrypted and read it back. Refused (and
        // nothing changed) while any plain record is left.
        case ('POST', '/v1/e2ee/commit'):
          _checkProtocol(r);
          who = _syncDevice(r, write: true).id;
          final fresh = store.e2eeRequired
              ? null
              : await store.commitEncryption();
          // (The PC hub: ordinary codes then give read-only devices. A hosted
          // account's devices sign in with a password and stay writable.)
          if (tenantId == null) auth.keylessDevicesReadOnly = true;
          // A new backup (of ciphertext) first, then the old, plain ones go.
          final keepBackup = await backups.create();
          final purged = await backups.removeAllExcept(keepBackup);
          await backups.createLive(); // the frequent-backup set starts again
          await _send(r, 200, {
            'required': true,
            'removedPlainAttachments': fresh ?? 0,
            'removedOldBackups': purged,
          });
        case ('POST', '/v1/admin/revoke'):
          _admin(r);
          who = 'admin';
          final id = (await _json(r))['deviceId'];
          final done = id is String && await auth.revoke(id);
          if (done) store.wakeWaiters();
          await _send(r, 200, {'revoked': done});
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
        final shown = sanitizeLog(
          route.length > 60 ? route.substring(0, 60) : route,
        );
        _log('${r.method} $shown -> $status ${ms}ms by $shortWho');
      }
    }
  }

  /// A read-only share page (see ShareLink): no device token, only the
  /// link's secret. Unknown, revoked and expired links all get the same
  /// "not available" answer.
  ///
  /// The shared text is ciphertext the hub cannot read. It is put in the
  /// page, and a small script in the recipient's browser opens it with the
  /// key from the link's `#fragment` (never sent to this server).
  Future<int> _serveShare(HttpRequest r, String token) async {
    Map<String, dynamic>? data;
    if (_shareToken.hasMatch(token)) {
      final id = sha256.convert(utf8.encode(token)).toString();
      final c = await store.current('shares', id);
      data = c == null || c.deleted ? null : c.data;
    }
    // Sealed share: {e2ee, c, pub: {expiresAt, revoked, ct}}. (A plain share
    // from before encryption was required is not served any more.)
    final pub = data?['pub'];
    final meta = pub is Map<String, dynamic> ? pub : null;
    final expires = DateTime.tryParse('${meta?['expiresAt'] ?? ''}');
    final ct = meta?['ct'];
    final ok =
        meta != null &&
        ct is String &&
        meta['revoked'] != true &&
        (expires == null || DateTime.now().toUtc().isBefore(expires.toUtc()));
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
        ok
            ? "default-src 'none'; style-src 'unsafe-inline'; "
                  "script-src 'sha256-$_shareScriptHash'"
            : "default-src 'none'; style-src 'unsafe-inline'",
      )
      ..write(ok ? _sealedSharePage(ct) : _unavailableSharePage);
    await r.response.close();
    return status;
  }

  static const _pageHead =
      '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<meta name="robots" content="noindex"><meta name="referrer" '
      'content="no-referrer">';
  static const _pageStyle =
      '<style>body{font:16px/1.5 system-ui,sans-serif;max-width:720px;'
      'margin:2em auto;padding:0 16px;color:#222;background:#fafafa}'
      'pre{white-space:pre-wrap;font:inherit}</style>';

  static const _unavailableSharePage =
      '$_pageHead<title>Not available</title>$_pageStyle</head><body>'
      '<h1>Not available</h1><pre>This link does not exist, was revoked or '
      'has expired.</pre><p style="color:#888;font-size:12px">Shared '
      'read-only from misc.</p></body></html>';

  /// Opens the sealed text with WebCrypto (AES-256-GCM): the key is in
  /// `location.hash` (`#k=...`), the ciphertext in the `d` element.
  static const _shareScript = r'''
(async()=>{
const out=document.getElementById('b'),h=document.getElementById('h');
const fail=m=>{h.textContent='Not available';out.textContent=m;};
try{
if(!(window.crypto&&crypto.subtle)){fail('Open this link over HTTPS to read it.');return;}
const u=s=>{s=s.replace(/-/g,'+').replace(/_/g,'/');while(s.length%4)s+='=';
return Uint8Array.from(atob(s),c=>c.charCodeAt(0));};
const m=/^#k=([A-Za-z0-9_-]{43})$/.exec(location.hash);
if(!m){fail('This link is missing its key.');return;}
const data=u(document.getElementById('d').textContent.trim());
const key=await crypto.subtle.importKey('raw',u(m[1]),'AES-GCM',false,['decrypt']);
const plain=await crypto.subtle.decrypt({name:'AES-GCM',iv:data.slice(0,12),
additionalData:new TextEncoder().encode('theapp-share-v1')},key,data.slice(12));
const j=JSON.parse(new TextDecoder().decode(plain));
document.title=j.t;h.textContent=j.t;out.textContent=j.b;
}catch(e){fail('This link could not be opened.');}
})();
''';

  static final String _shareScriptHash = base64Encode(
    sha256.convert(utf8.encode(_shareScript)).bytes,
  );

  static String _sealedSharePage(String ct) =>
      '$_pageHead<title>Shared note</title>$_pageStyle</head><body>'
      '<h1 id="h">Opening…</h1><pre id="b"></pre>'
      '<script id="d" type="application/octet-stream">$ct</script>'
      '<p style="color:#888;font-size:12px">Shared read-only from misc. '
      'End-to-end encrypted: the server cannot read this.</p>'
      '<script>$_shareScript</script></body></html>';

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
      auth.keylessDevicesReadOnly = store.e2eeRequired;
      final result = await auth.registerWithKey(
        code,
        id,
        name,
        readOnly: body['readOnly'] == true,
      );
      _failedPairing.remove(remote);
      await _send(r, 200, {
        'token': result.token,
        'protocol': syncProtocolVersion,
        'lastSeq': store.lastSeq,
        'hubId': store.hubId,
        'e2ee': store.e2eeRequired,
        'wrappedKey': ?result.wrappedKey,
      });
    } on ProtocolException {
      _failedPairing[remote] = recent..add(now);
      rethrow;
    }
  }
}
