// HTTP client for the hub (used by every device). Pure Dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../hub/hub_server.dart' show isAllowedBindAddress;
import '../data/storage/storage_encryption.dart' show DecryptionFailure;
import 'e2ee.dart';
import 'protocol.dart';

/// A sync attempt that did not complete. [retryable] failures (hub
/// offline, timeouts) simply mean "try again later"; nothing was lost.
class SyncFailure implements Exception {
  const SyncFailure(this.code, this.message, {this.retryable = false});

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => '$code: $message';
}

/// The transport rule: plain HTTP only to this PC or Tailscale (whose
/// network is encrypted); HTTPS for everything else (a home network, a hosted
/// service). Sync traffic is never sent over an open network in the clear.
///
/// The address must also be one sync may use at all: this PC, a private
/// network, Tailscale, or a hosted service named by a host name.
bool isAllowedHubUrl(Uri url) {
  if (url.scheme != 'http' && url.scheme != 'https') return false;
  if (url.userInfo.isNotEmpty) return false;
  // A hosted sync service: any named server, but only over HTTPS.
  if (isHostedHubUrl(url)) return true;
  final host = url.host.toLowerCase();
  final knownRoute =
      host == 'localhost' ||
      host.endsWith('.ts.net') ||
      (InternetAddress.tryParse(host) != null &&
          isAllowedBindAddress(InternetAddress.tryParse(host)!));
  if (!knownRoute) return false;
  // Plain HTTP only where the network itself is protected.
  return url.scheme == 'https' || isEncryptedHubRoute(url);
}

/// Whether [url] is refused only because it would send data in the clear
/// (so the message can say so).
bool isInsecureHubUrl(Uri url) =>
    url.scheme == 'http' && !isEncryptedHubRoute(url);

/// Whether [address] is in Tailscale's ranges (100.64.0.0/10, fd7a:115c:a1e0::/48).
bool isTailscaleAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return b[0] == 100 && b[1] >= 64 && b[1] <= 127;
  }
  return b[0] == 0xfd &&
      b[1] == 0x7a &&
      b[2] == 0x11 &&
      b[3] == 0x5c &&
      b[4] == 0xa1 &&
      b[5] == 0xe0;
}

/// Whether [url] points at the device the app runs on (127.0.0.1, ::1,
/// localhost).
bool isLoopbackHubUrl(Uri url) {
  if (url.host.toLowerCase() == 'localhost') return true;
  return InternetAddress.tryParse(url.host)?.isLoopback ?? false;
}

/// Whether traffic to [url] is protected on the network: this PC itself
/// (never leaves the computer) or a Tailscale address (encrypted by
/// WireGuard). Other private addresses, e.g. home Wi-Fi `192.168.x.x`, carry
/// plain HTTP that others on that network could read.
bool isEncryptedHubRoute(Uri url) {
  final host = url.host.toLowerCase();
  if (url.scheme == 'https') return true;
  if (host == 'localhost' || host.endsWith('.ts.net')) return true;
  final ip = InternetAddress.tryParse(host);
  if (ip == null) return false;
  if (ip.isLoopback) return true;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 100 && b[1] >= 64 && b[1] <= 127; // 100.64.0.0/10
  }
  // Tailscale's IPv6 range fd7a:115c:a1e0::/48.
  return b[0] == 0xfd &&
      b[1] == 0x7a &&
      b[2] == 0x11 &&
      b[3] == 0x5c &&
      b[4] == 0xa1 &&
      b[5] == 0xe0;
}

/// Learns the SHA-256 of the certificate an HTTPS hub presents, for pinning,
/// but only if it starts with [prefix] (the fingerprint prefix that came with
/// the pairing code, i.e. over a channel the network cannot change). Nothing
/// is sent: the connection is closed right after the handshake. Null when the
/// certificate does not match, so a stranger's certificate is never pinned.
Future<String?> fetchPinnedCertificate(Uri url, String prefix) async {
  if (url.scheme != 'https') return null;
  X509Certificate? seen;
  try {
    final socket = await SecureSocket.connect(
      url.host,
      url.hasPort ? url.port : 443,
      timeout: const Duration(seconds: 8),
      onBadCertificate: (cert) {
        seen = cert;
        return true; // only to read it: nothing is sent on this connection
      },
    );
    seen ??= socket.peerCertificate;
    socket.destroy();
  } on SocketException {
    return null;
  } on TlsException {
    return null;
  }
  final cert = seen;
  if (cert == null) return null;
  final sha = sha256.convert(cert.der).toString();
  return sha.startsWith(prefix.toLowerCase()) ? sha : null;
}

class SyncClient {
  /// [pinnedCertSha256]: for an HTTPS hub with its own certificate (a home
  /// network), the SHA-256 (hex) of that certificate. A certificate that is
  /// not valid is accepted ONLY if it is exactly this one; any other invalid
  /// certificate is refused and the request is not sent.
  ///
  /// [crypto]: seals every record and attachment before it leaves, opens
  /// them when they arrive (end-to-end encryption, see e2ee.dart).
  SyncClient(
    this.base, {
    this.token,
    this.timeout = const Duration(seconds: 20),
    this.crypto,
    String? pinnedCertSha256,
    this.requireSealed = false,
  }) : _pinned = pinnedCertSha256?.toLowerCase() {
    if (isInsecureHubUrl(base)) {
      // Fail closed: nothing is ever sent, not even a pairing code.
      throw const SyncFailure(
        'insecure_transport',
        'This address would send your data unprotected over the network. '
            'Use https://, or this PC (127.0.0.1) or a Tailscale address.',
      );
    }
    if (!isAllowedHubUrl(base)) {
      throw const SyncFailure(
        'bad_hub_address',
        'The hub address must be this PC, your home network or Tailscale.',
      );
    }
    _http.badCertificateCallback = _acceptPinned;
  }

  final Uri base;
  String? token;
  final Duration timeout;
  final SyncCrypto? crypto;
  final String? _pinned;

  /// True once the hub requires encryption: a record that arrives unsealed
  /// is then refused instead of applied.
  bool requireSealed;

  late final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  /// Called by Dart for a certificate the system does not trust: accepted
  /// only when it is the pinned one for this hub's host and port.
  bool _acceptPinned(X509Certificate cert, String host, int port) {
    final pinned = _pinned;
    if (pinned == null) return false;
    if (host != base.host || port != (base.hasPort ? base.port : 443)) {
      return false;
    }
    return sha256.convert(cert.der).toString() == pinned;
  }

  /// A `*.ts.net` name must really resolve into the tailnet before plain
  /// HTTP is used, so a look-alike name cannot lead the app onto an open
  /// network. Checked once per client.
  bool _routeChecked = false;
  Future<void> _checkRoute() async {
    if (_routeChecked) return;
    if (base.scheme == 'http' && base.host.toLowerCase().endsWith('.ts.net')) {
      final addresses = await InternetAddress.lookup(base.host);
      if (addresses.isEmpty || !addresses.every(isTailscaleAddress)) {
        throw const SyncFailure(
          'insecure_transport',
          'This name does not point into your Tailscale network, so it was '
              'not used.',
        );
      }
    }
    _routeChecked = true;
  }

  void close() {
    _http.close(force: true);
    cancelWait();
  }

  Future<HttpClientRequest> _open(
    String method,
    String path, [
    Map<String, String>? query,
  ]) async {
    final uri = base.replace(path: path, queryParameters: query);
    await _checkRoute();
    try {
      final req = await _http.openUrl(method, uri).timeout(timeout);
      req.headers.set(protocolHeader, '$syncProtocolVersion');
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      return req;
    } on HandshakeException {
      throw const SyncFailure(
        'certificate_rejected',
        'The hub\'s security certificate is not trusted, so nothing was '
            'sent. Pair again with the code from the hub (it identifies the '
            'right certificate).',
      );
    } on TlsException {
      throw const SyncFailure(
        'certificate_rejected',
        'The secure connection to the hub could not be set up, so nothing '
            'was sent.',
      );
    } on SocketException {
      throw const SyncFailure(
        'offline',
        'The hub is not reachable.',
        retryable: true,
      );
    } on TimeoutException {
      throw const SyncFailure(
        'timeout',
        'The hub did not answer in time.',
        retryable: true,
      );
    }
  }

  Future<Map<String, dynamic>> _json(
    HttpClientRequest req, [
    Object? body,
  ]) async {
    try {
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(timeout);
      final text = await utf8.decodeStream(res).timeout(timeout);
      Map<String, dynamic> json;
      try {
        json = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {
        throw SyncFailure(
          'bad_response',
          'Unexpected answer from the hub (${res.statusCode}).',
        );
      }
      if (res.statusCode != 200) {
        throw SyncFailure(
          json['error'] as String? ?? 'error',
          json['message'] as String? ?? 'Hub error ${res.statusCode}.',
          retryable: res.statusCode >= 500 || res.statusCode == 429,
        );
      }
      return json;
    } on SocketException {
      throw const SyncFailure(
        'offline',
        'The connection to the hub was lost.',
        retryable: true,
      );
    } on TimeoutException {
      throw const SyncFailure(
        'timeout',
        'The hub did not answer in time.',
        retryable: true,
      );
    } on HttpException {
      throw const SyncFailure(
        'offline',
        'The connection to the hub was interrupted.',
        retryable: true,
      );
    }
  }

  Future<Map<String, dynamic>> status() async =>
      _json(await _open('GET', '/v1/status'));

  /// Separate connection for the long-poll, so it never holds up a push.
  HttpClient? _waitHttp;

  /// Waits (up to [seconds]) until the hub has a change after [since];
  /// returns the hub's newest change number and id. A hub from before this
  /// endpoint answers `not_found` (the caller then keeps polling).
  Future<({int lastSeq, String hubId})> waitForChange(
    int since, {
    int seconds = 25,
  }) async {
    final http = _waitHttp ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = _acceptPinned;
    final limit = Duration(seconds: seconds + 10);
    await _checkRoute();
    try {
      final req = await http
          .getUrl(
            base.replace(
              path: '/v1/wait',
              queryParameters: {'since': '$since', 'timeout': '$seconds'},
            ),
          )
          .timeout(limit);
      req.headers.set(protocolHeader, '$syncProtocolVersion');
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final res = await req.close().timeout(limit);
      final text = await utf8.decodeStream(res).timeout(limit);
      Map<String, dynamic>? json;
      try {
        json = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}
      if (res.statusCode != 200 || json == null) {
        throw SyncFailure(
          json?['error'] as String? ?? 'error',
          json?['message'] as String? ?? 'Hub error ${res.statusCode}.',
          retryable: res.statusCode >= 500 || res.statusCode == 429,
        );
      }
      return (lastSeq: json['lastSeq'] as int, hubId: json['hubId'] as String);
    } on SocketException {
      throw const SyncFailure(
        'offline',
        'The hub is not reachable.',
        retryable: true,
      );
    } on TimeoutException {
      throw const SyncFailure(
        'timeout',
        'The hub did not answer in time.',
        retryable: true,
      );
    } on HttpException {
      throw const SyncFailure(
        'offline',
        'The connection to the hub was interrupted.',
        retryable: true,
      );
    }
  }

  /// Ends a long-poll in progress (e.g. the app went to the background).
  void cancelWait() {
    _waitHttp?.close(force: true);
    _waitHttp = null;
  }

  /// Pairs this device; returns its token (keep it secret).
  Future<String> register(
    String code,
    String deviceId,
    String deviceName, {
    bool readOnly = false,
  }) async => (await registerWithKey(
    code,
    deviceId,
    deviceName,
    readOnly: readOnly,
  )).token;

  /// [register], also returning the wrapped workspace key when the code was
  /// an end-to-end pairing offer (null for an ordinary code).
  Future<({String token, String? wrappedKey, bool e2ee})> registerWithKey(
    String code,
    String deviceId,
    String deviceName, {
    bool readOnly = false,
  }) async {
    final json = await _json(await _open('POST', '/v1/register'), {
      'pairingCode': code,
      'deviceId': deviceId,
      'deviceName': deviceName,
      if (readOnly) 'readOnly': true,
    });
    token = json['token'] as String;
    return (
      token: token!,
      wrappedKey: json['wrappedKey'] as String?,
      e2ee: json['e2ee'] == true,
    );
  }

  /// Offers the workspace key to a device that will enter [registerCode]
  /// (a signed-in, writable device does this; the key is wrapped under the
  /// pairing code, which the hub never sees).
  Future<void> offerPairing(
    String registerCode,
    String wrappedKey, {
    bool readOnly = false,
  }) async {
    await _json(await _open('POST', '/v1/pairing'), {
      'registerCode': registerCode,
      'wrappedKey': wrappedKey,
      if (readOnly) 'readOnly': true,
    });
  }

  /// A signed-in device takes the wrapped key of an offer made for
  /// [registerCode] (hosted accounts).
  Future<String> redeemPairing(String registerCode) async {
    final json = await _json(await _open('POST', '/v1/pairing/redeem'), {
      'registerCode': registerCode,
    });
    return json['wrappedKey'] as String;
  }

  /// Whether the hub accepts only encrypted records, and how many plain
  /// records it still holds.
  Future<({bool required, int plaintextRecords})> e2eeStatus() async {
    final json = await _json(await _open('GET', '/v1/e2ee'));
    return (
      required: json['required'] == true,
      plaintextRecords: (json['plaintextRecords'] as num?)?.toInt() ?? 0,
    );
  }

  /// Switches the hub to encrypted-only. Refused (`plaintext_remaining`)
  /// while it still holds a plain record.
  Future<Map<String, dynamic>> commitEncryption() async =>
      _json(await _open('POST', '/v1/e2ee/commit'), const <String, dynamic>{});

  /// Hosted service: makes an account (needs an invite code from the
  /// service's operator).
  Future<void> createAccount(
    String email,
    String password,
    String invite,
  ) async {
    await _json(await _open('POST', '/v1/account/register'), {
      'email': email,
      'password': password,
      'invite': invite,
    });
  }

  /// Hosted service: signs this device in; returns (and keeps) its token.
  Future<String> signIn(
    String email,
    String password,
    String deviceId,
    String deviceName,
  ) async {
    final json = await _json(await _open('POST', '/v1/account/login'), {
      'email': email,
      'password': password,
      'deviceId': deviceId,
      'deviceName': deviceName,
    });
    return token = json['token'] as String;
  }

  /// The plain version of a change that came from the hub. A hub that
  /// requires encryption must send only sealed records; before that
  /// (during the upgrade) older plain ones are still read.
  SyncChange _open1(SyncChange c) {
    final crypto = this.crypto;
    if (crypto == null) return c;
    if (!requireSealed && c.data != null && !isEnvelope(c.data)) {
      if (c.collection == 'conflicts' && deviceOfRev(c.rev) == 'hub') {
        return crypto.openChange(c);
      }
      return c; // an older plain record, not yet upgraded by a device
    }
    try {
      return crypto.openChange(c);
    } on DecryptionFailure {
      throw SyncFailure(
        'e2ee_unreadable',
        'A record from the hub could not be decrypted (it was changed, or '
            'made with another key).',
      );
    } on PlaintextRecordException {
      throw const SyncFailure(
        'e2ee_plaintext',
        'The hub sent a record that is not end-to-end encrypted, so it was '
            'not used.',
      );
    }
  }

  Future<({List<PushResult> results, int lastSeq, String hubId})> push(
    List<SyncChange> changes,
  ) async {
    final crypto = this.crypto;
    final json = await _json(await _open('POST', '/v1/push'), {
      'changes': [
        for (final c in changes)
          (crypto == null ? c : crypto.sealChange(c)).toJson(),
      ],
    });
    return (
      results: [
        for (final r in json['results'] as List)
          _openResult(PushResult.fromJson(r as Map<String, dynamic>)),
      ],
      lastSeq: json['lastSeq'] as int,
      hubId: json['hubId'] as String,
    );
  }

  Future<
    ({
      List<SyncChange> changes,
      int next,
      bool hasMore,
      int lastSeq,
      String hubId,
    })
  >
  pull(int since, {int limit = defaultPullLimit}) async {
    final json = await _json(
      await _open('GET', '/v1/changes', {'since': '$since', 'limit': '$limit'}),
    );
    return (
      changes: [
        for (final c in json['changes'] as List)
          _open1(SyncChange.fromJson(c as Map<String, dynamic>)),
      ],
      next: json['next'] as int,
      hasMore: json['hasMore'] as bool,
      lastSeq: json['lastSeq'] as int,
      hubId: json['hubId'] as String,
    );
  }

  PushResult _openResult(PushResult r) {
    final current = r.current;
    if (current == null || crypto == null) return r;
    return PushResult(
      collection: r.collection,
      id: r.id,
      rev: r.rev,
      status: r.status,
      current: _open1(current),
      conflictId: r.conflictId,
    );
  }

  Future<bool> hasAttachment(String sha) async {
    final req = await _open('HEAD', '/v1/attachments/$sha');
    try {
      final res = await req.close().timeout(timeout);
      await res.drain<void>();
      if (res.statusCode == 401) {
        throw const SyncFailure(
          'unauthorized',
          'This device is no longer paired.',
        );
      }
      return res.statusCode == 200;
    } on SocketException {
      throw const SyncFailure(
        'offline',
        'The hub is not reachable.',
        retryable: true,
      );
    }
  }

  Future<void> upload(String sha, File file) async {
    final req = await _open('PUT', '/v1/attachments/$sha');
    req.headers.contentLength = await file.length();
    req.headers.contentType = ContentType.binary;
    try {
      await req.addStream(file.openRead());
    } on SocketException {
      throw const SyncFailure(
        'offline',
        'The upload was interrupted.',
        retryable: true,
      );
    }
    await _json(req);
  }

  /// Downloads an attachment to a temporary file, checks its size and
  /// SHA-256, then moves it to [target]. A bad or interrupted download never
  /// leaves a file at [target].
  Future<void> download(String sha, int? size, File target) async {
    final req = await _open('GET', '/v1/attachments/$sha');
    final tmp = File('${target.path}.download');
    IOSink? sink;
    try {
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw SyncFailure(
          res.statusCode == 404 ? 'not_found' : 'error',
          'Attachment download failed (${res.statusCode}).',
          retryable: res.statusCode != 404,
        );
      }
      await target.parent.create(recursive: true);
      sink = tmp.openWrite();
      final out = _Digest();
      final hasher = sha256.startChunkedConversion(out);
      var received = 0;
      await for (final chunk in res.timeout(timeout)) {
        received += chunk.length;
        if (received > maxAttachmentBytes) {
          throw const SyncFailure(
            'integrity_failed',
            'Attachment is too large.',
          );
        }
        hasher.add(chunk);
        sink.add(chunk);
      }
      await sink.close();
      hasher.close();
      if (out.value.toString() != sha || (size != null && size != received)) {
        throw const SyncFailure(
          'integrity_failed',
          'Downloaded attachment is damaged.',
          retryable: true,
        );
      }
      await tmp.rename(target.path);
    } on SocketException {
      throw const SyncFailure(
        'offline',
        'The download was interrupted.',
        retryable: true,
      );
    } on TimeoutException {
      throw const SyncFailure(
        'timeout',
        'The download timed out.',
        retryable: true,
      );
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      if (await tmp.exists()) await tmp.delete();
    }
  }
}

class _Digest implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// SHA-256 of a file, streamed (never loads it all into memory).
Future<String> fileSha256(File f) async =>
    (await sha256.bind(f.openRead()).first).toString();

/// A hosted sync service address: HTTPS to a named server (not an IP, no
/// user name or password in the address).
bool isHostedHubUrl(Uri url) =>
    url.scheme == 'https' &&
    url.host.contains('.') &&
    url.userInfo.isEmpty &&
    InternetAddress.tryParse(url.host) == null;
