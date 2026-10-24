// Hosted sync: the same hub, serving many accounts. Each account has its
// own folder with its own HubStore, HubAuth and HubBackups (a HubServer in
// tenant mode), so the sync protocol, revisions, tombstones, attachments,
// conflict handling and backups are exactly those of the self-hosted hub.
// One account can never reach another's records: the account comes from
// the device token (`<accountId>.<token>`, checked by that account's own
// HubAuth), never from an id in the request.
//
// Enrollment needs an invite code made by the operator (`thehub
// hosted-invite`), so a public server cannot be filled by strangers.
// Passwords are stored as Argon2id hashes (PointyCastle). TLS is done by a
// reverse proxy in front (deploy/hosted/: Caddy with automatic HTTPS); the
// server itself only listens behind it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../sync/protocol.dart';
import 'hub_server.dart';

final _random = Random.secure();
String _hex(int bytes) => [
  for (var i = 0; i < bytes; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

/// Argon2id (19 MiB, t=2) of [password] with [salt], hex.
String _argon2(String password, Uint8List salt) {
  final gen = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        salt,
        desiredKeyLength: 32,
        iterations: 2,
        memory: 19456,
      ),
    );
  return gen
      .process(Uint8List.fromList(utf8.encode(password)))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

Future<String> hashPassword(String password, String saltHex) {
  final salt = Uint8List.fromList([
    for (var i = 0; i < saltHex.length; i += 2)
      int.parse(saltHex.substring(i, i + 2), radix: 16),
  ]);
  return Isolate.run(() => _argon2(password, salt));
}

bool _sameHex(String a, String b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return d == 0;
}

/// Simple sliding-window limiter (per IP, per account).
class _Limiter {
  _Limiter(this.max, this.window);
  final int max;
  final Duration window;
  final Map<String, List<DateTime>> _hits = {};

  bool allow(String key) {
    final now = DateTime.now();
    final list = _hits.putIfAbsent(key, () => [])
      ..removeWhere((t) => now.difference(t) > window);
    if (list.length >= max) return false;
    list.add(now);
    if (_hits.length > 50000) _hits.clear(); // memory bound under attack
    return true;
  }
}

class HostedHub {
  HostedHub._(this.dir, this._http, this._log, this.behindProxy);

  final Directory dir;
  final HttpServer _http;
  final void Function(String) _log;

  /// Trust X-Forwarded-For (only when a proxy is the sole way in).
  final bool behindProxy;

  final Map<String, HubServer> _tenants = {};
  final Map<String, Future<HubServer>> _opening = {};
  final _accountLimiter = _Limiter(10, const Duration(minutes: 1));
  final _loginLimiter = _Limiter(20, const Duration(hours: 1));
  final _requestLimiter = _Limiter(1200, const Duration(minutes: 1));
  Timer? _backupTimer;

  int get port => _http.port;

  String get _sep => Platform.pathSeparator;
  File get _accountsFile => File('${dir.path}${_sep}accounts.json');
  File get _invitesFile => File('${dir.path}${_sep}invites.json');
  Directory _userDir(String id) => Directory('${dir.path}${_sep}users$_sep$id');

  static final _idPattern = RegExp(r'^[0-9a-f]{32}$');
  static final _emailPattern = RegExp(
    r'^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{2,}$',
  );
  static const minPasswordLength = 12;

  static Future<HostedHub> start({
    required Directory dir,
    required String host,
    required int port,
    bool behindProxy = false,
    bool dailyBackups = true,
    void Function(String line)? log,
  }) async {
    await dir.create(recursive: true);
    final http = await HttpServer.bind(host, port);
    http.idleTimeout = const Duration(seconds: 30);
    final hub = HostedHub._(dir, http, log ?? (_) {}, behindProxy);
    http.listen(hub._handle);
    if (dailyBackups) {
      hub._backupTimer = Timer.periodic(
        const Duration(hours: 24),
        (_) => hub._backupAll(),
      );
    }
    hub._log('Hosted hub listening on $host:${http.port}');
    return hub;
  }

  Future<void> stop() async {
    _backupTimer?.cancel();
    await _http.close(force: true);
    for (final t in _tenants.values) {
      await t.stop();
    }
    _tenants.clear();
  }

  // ------------------------------------------------------------ storage --

  Future<Map<String, dynamic>> _read(File f) async {
    if (!await f.exists()) return {};
    return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  }

  /// Writes atomically (temporary file, then rename).
  Future<void> _write(File f, Map<String, dynamic> json) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(f.path);
  }

  /// Makes an invite code in the service folder [dir] (shown once; only
  /// its hash is kept). Works while the service runs or not.
  static Future<String> createInvite(Directory dir) async {
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}invites.json');
    final code = _hex(12);
    final invites = await file.exists()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : <String, dynamic>{};
    final list = [...?(invites['codes'] as List?)?.cast<String>()];
    list.add(sha256.convert(utf8.encode(code)).toString());
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({'codes': list}), flush: true);
    await tmp.rename(file.path);
    return code;
  }

  Future<HubServer> _tenant(String id) {
    final open = _tenants[id];
    if (open != null) return Future.value(open);
    return _opening[id] ??= () async {
      final t = await HubServer.tenant(_userDir(id), id, log: _log);
      _tenants[id] = t;
      _opening.remove(id);
      return t;
    }();
  }

  Future<void> _backupAll() async {
    final users = Directory('${dir.path}${_sep}users');
    if (!await users.exists()) return;
    await for (final d in users.list()) {
      final id = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!_idPattern.hasMatch(id)) continue;
      try {
        await (await _tenant(id)).backups.create();
      } catch (e) {
        _log('Backup failed for an account: ${e.runtimeType}');
      }
    }
  }

  // ------------------------------------------------------------ routing --

  String _ip(HttpRequest r) {
    if (behindProxy) {
      final f = r.headers.value('x-forwarded-for');
      if (f != null && f.isNotEmpty) return f.split(',').first.trim();
    }
    return r.connectionInfo?.remoteAddress.address ?? '?';
  }

  Future<Map<String, dynamic>> _body(HttpRequest r) async {
    if (r.contentLength > 64 * 1024) {
      throw const ProtocolException(
        'too_large',
        'Request too large.',
        status: 413,
      );
    }
    final bytes = await r.fold<List<int>>([], (a, b) {
      if (a.length + b.length > 64 * 1024) {
        throw const ProtocolException(
          'too_large',
          'Request too large.',
          status: 413,
        );
      }
      return a..addAll(b);
    });
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    throw const ProtocolException('bad_request', 'Body must be a JSON object.');
  }

  static Future<void> _send(HttpRequest r, int status, Object body) async {
    r.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.set('cache-control', 'no-store')
      ..headers.set('x-content-type-options', 'nosniff')
      ..write(jsonEncode(body));
    await r.response.close();
  }

  /// The account of the request's device token, or null.
  String? _accountOf(HttpRequest r) {
    final h = r.headers.value(HttpHeaders.authorizationHeader);
    if (h == null || !h.startsWith('Bearer ')) return null;
    final token = h.substring(7).trim();
    final dot = token.indexOf('.');
    if (dot != 32) return null;
    final id = token.substring(0, dot);
    return _idPattern.hasMatch(id) ? id : null;
  }

  Future<void> _handle(HttpRequest r) async {
    final ip = _ip(r);
    try {
      if (!_requestLimiter.allow(ip)) {
        throw const ProtocolException(
          'rate_limited',
          'Too many requests.',
          status: 429,
        );
      }
      final path = r.uri.path;
      if (path == '/v1/status' && r.method == 'GET') {
        await _send(r, 200, {
          'service': 'THEapp hosted hub',
          'hosted': true,
          'protocol': syncProtocolVersion,
        });
        return;
      }
      if (path.startsWith('/v1/account/')) {
        await _account(r, path.substring('/v1/account/'.length), ip);
        return;
      }
      if (!path.startsWith('/v1/') || path.startsWith('/v1/admin')) {
        throw const ProtocolException(
          'not_found',
          'Unknown endpoint.',
          status: 404,
        );
      }
      final id = _accountOf(r);
      if (id == null || !await _userDir(id).exists()) {
        throw const ProtocolException(
          'unauthorized',
          'Missing or invalid device token.',
          status: 401,
        );
      }
      // The account's own hub checks the token against its own devices.
      await (await _tenant(id)).handle(r);
    } on ProtocolException catch (e) {
      try {
        await r.drain<void>();
      } catch (_) {}
      try {
        await _send(r, e.status, e.toJson());
      } catch (_) {}
    } catch (e) {
      _log('Internal error: ${e.runtimeType}');
      try {
        await _send(
          r,
          500,
          const ProtocolException('internal', 'Internal error.').toJson(),
        );
      } catch (_) {}
    }
  }

  Future<void> _account(HttpRequest r, String action, String ip) async {
    if (r.method != 'POST' && action != 'devices') {
      throw const ProtocolException(
        'not_found',
        'Unknown endpoint.',
        status: 404,
      );
    }
    switch (action) {
      case 'register':
        if (!_accountLimiter.allow('reg:$ip')) {
          throw const ProtocolException(
            'rate_limited',
            'Too many attempts.',
            status: 429,
          );
        }
        final b = await _body(r);
        final email = '${b['email'] ?? ''}'.trim().toLowerCase();
        final password = '${b['password'] ?? ''}';
        final invite = '${b['invite'] ?? ''}'.trim();
        if (!_emailPattern.hasMatch(email)) {
          throw const ProtocolException(
            'bad_request',
            'Enter a valid email address.',
          );
        }
        if (password.length < minPasswordLength) {
          throw const ProtocolException(
            'bad_request',
            'Use a password of at least $minPasswordLength characters.',
          );
        }
        final invites = await _read(_invitesFile);
        final codes = [...?(invites['codes'] as List?)?.cast<String>()];
        final inviteHash = sha256.convert(utf8.encode(invite)).toString();
        if (!codes.contains(inviteHash)) {
          throw const ProtocolException(
            'forbidden',
            'This invite code is not valid.',
            status: 403,
          );
        }
        final accounts = await _read(_accountsFile);
        final users = Map<String, dynamic>.from(
          accounts['users'] as Map? ?? {},
        );
        if (users.values.any((u) => (u as Map)['email'] == email)) {
          throw const ProtocolException(
            'conflict',
            'This email already has an account.',
            status: 409,
          );
        }
        final id = _hex(16);
        final salt = _hex(16);
        users[id] = {
          'email': email,
          'salt': salt,
          'hash': await hashPassword(password, salt),
          'created': DateTime.now().toUtc().toIso8601String(),
        };
        await _write(_accountsFile, {'users': users});
        codes.remove(inviteHash); // single use
        await _write(_invitesFile, {'codes': codes});
        await _userDir(id).create(recursive: true);
        await _tenant(id);
        _log('Account created');
        await _send(r, 200, {'ok': true});
      case 'login':
        final b = await _body(r);
        final email = '${b['email'] ?? ''}'.trim().toLowerCase();
        if (!_accountLimiter.allow('login:$ip') ||
            !_loginLimiter.allow('login:$email')) {
          throw const ProtocolException(
            'rate_limited',
            'Too many attempts. Wait a while.',
            status: 429,
          );
        }
        final accounts = await _read(_accountsFile);
        final users = Map<String, dynamic>.from(
          accounts['users'] as Map? ?? {},
        );
        final entry = users.entries
            .where((e) => (e.value as Map)['email'] == email)
            .firstOrNull;
        // The same work and answer whether or not the email exists.
        final salt = entry == null
            ? _hex(16)
            : '${(entry.value as Map)['salt']}';
        final hash = await hashPassword('${b['password'] ?? ''}', salt);
        if (entry == null ||
            !_sameHex(hash, '${(entry.value as Map)['hash']}')) {
          throw const ProtocolException(
            'unauthorized',
            'Wrong email or password.',
            status: 401,
          );
        }
        final tenant = await _tenant(entry.key);
        final token = await tenant.auth.register(
          tenant.auth.createPairingCode(),
          '${b['deviceId'] ?? ''}',
          '${b['deviceName'] ?? 'Device'}'.trim(),
        );
        await _send(r, 200, {
          'token': '${entry.key}.$token',
          'hubId': tenant.store.hubId,
        });
      case 'devices' || 'revoke' || 'delete':
        final id = _accountOf(r);
        if (id == null || !await _userDir(id).exists()) {
          throw const ProtocolException(
            'unauthorized',
            'Not signed in.',
            status: 401,
          );
        }
        final tenant = await _tenant(id);
        final h = r.headers.value(HttpHeaders.authorizationHeader)!;
        final device = tenant.auth.authenticate(
          h.substring(7).trim().substring(33),
        );
        if (device == null) {
          throw const ProtocolException(
            'unauthorized',
            'Not signed in.',
            status: 401,
          );
        }
        if (action == 'devices') {
          await _send(r, 200, {
            'devices': [
              for (final d in tenant.auth.devices)
                {'id': d.id, 'name': d.name, 'revoked': d.revoked},
            ],
          });
        } else if (action == 'revoke') {
          final b = await _body(r);
          await _send(r, 200, {
            'revoked': await tenant.auth.revoke('${b['deviceId'] ?? ''}'),
          });
        } else {
          // Deleting the account removes its data and its backups.
          final b = await _body(r);
          final accounts = await _read(_accountsFile);
          final users = Map<String, dynamic>.from(
            accounts['users'] as Map? ?? {},
          );
          final u = users[id] as Map?;
          final hash = await hashPassword(
            '${b['password'] ?? ''}',
            '${u?['salt']}',
          );
          if (u == null || !_sameHex(hash, '${u['hash']}')) {
            throw const ProtocolException(
              'unauthorized',
              'Wrong password.',
              status: 401,
            );
          }
          await tenant.stop();
          _tenants.remove(id);
          users.remove(id);
          await _write(_accountsFile, {'users': users});
          await _userDir(id).delete(recursive: true);
          _log('Account deleted');
          await _send(r, 200, {'deleted': true});
        }
      default:
        throw const ProtocolException(
          'not_found',
          'Unknown endpoint.',
          status: 404,
        );
    }
  }
}
