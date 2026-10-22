// HTTP client for the hub (used by every device). Pure Dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../hub/hub_server.dart' show isAllowedBindAddress;
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

/// Only this PC, private networks and Tailscale (100.64.0.0/10 or
/// `*.ts.net` names) are accepted: sync traffic is never sent to the
/// public internet.
bool isAllowedHubUrl(Uri url) {
  if (url.scheme != 'http' && url.scheme != 'https') return false;
  if (url.host == 'localhost' || url.host.endsWith('.ts.net')) return true;
  final ip = InternetAddress.tryParse(url.host);
  return ip != null && isAllowedBindAddress(ip);
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

class SyncClient {
  SyncClient(
    this.base, {
    this.token,
    this.timeout = const Duration(seconds: 20),
  }) {
    if (!isAllowedHubUrl(base)) {
      throw const SyncFailure(
        'bad_hub_address',
        'The hub address must be this PC, your home network or Tailscale.',
      );
    }
  }

  final Uri base;
  String? token;
  final Duration timeout;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  void close() => _http.close(force: true);

  Future<HttpClientRequest> _open(
    String method,
    String path, [
    Map<String, String>? query,
  ]) async {
    final uri = base.replace(path: path, queryParameters: query);
    try {
      final req = await _http.openUrl(method, uri).timeout(timeout);
      req.headers.set(protocolHeader, '$syncProtocolVersion');
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      return req;
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

  /// Pairs this device; returns its token (keep it secret).
  Future<String> register(
    String code,
    String deviceId,
    String deviceName,
  ) async {
    final json = await _json(await _open('POST', '/v1/register'), {
      'pairingCode': code,
      'deviceId': deviceId,
      'deviceName': deviceName,
    });
    return token = json['token'] as String;
  }

  Future<({List<PushResult> results, int lastSeq, String hubId})> push(
    List<SyncChange> changes,
  ) async {
    final json = await _json(await _open('POST', '/v1/push'), {
      'changes': [for (final c in changes) c.toJson()],
    });
    return (
      results: [
        for (final r in json['results'] as List)
          PushResult.fromJson(r as Map<String, dynamic>),
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
          SyncChange.fromJson(c as Map<String, dynamic>),
      ],
      next: json['next'] as int,
      hasMore: json['hasMore'] as bool,
      lastSeq: json['lastSeq'] as int,
      hubId: json['hubId'] as String,
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
