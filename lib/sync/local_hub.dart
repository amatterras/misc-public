// Talking to the hub running on this PC as its owner: the same admin
// request as `thehub pair`, so pairing this PC (or showing a code for an
// iPad) needs no terminal. Only works for the Windows user who started the
// hub (the admin token is protected for that user) and only on 127.0.0.1.
import 'dart:convert';
import 'dart:io';

import '../app/test_environment.dart';
import '../hub/hub_auth.dart';
import 'secret_store.dart';

Directory defaultLocalHubDir() {
  final base =
      Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? '.';
  return Directory('$base${Platform.pathSeparator}THEapp-hub');
}

class LocalHubException implements Exception {
  const LocalHubException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The port of the hub running on this PC, or null.
Future<int?> localHubPort(Directory dir) async {
  try {
    final json = jsonDecode(
      await File('${dir.path}${Platform.pathSeparator}hub.json').readAsString(),
    ) as Map<String, dynamic>;
    final port = json['port'];
    return port is int ? port : null;
  } catch (_) {
    return null;
  }
}

/// A fresh pairing code from this PC's hub (valid for a few minutes).
Future<({String code, int minutes, int port})> localPairingCode({
  Directory? hubDir,
}) async {
  if (hubDir == null &&
      (TestEnvironment.active ||
          Platform.environment.containsKey('FLUTTER_TEST'))) {
    throw const LocalHubException('Not available in test mode.');
  }
  final dir = hubDir ?? defaultLocalHubDir();
  final port = await localHubPort(dir);
  if (port == null) {
    throw const LocalHubException(
      'The hub is not running on this PC. Start it first ("thehub serve", '
      'or make it start with Windows with "thehub startup enable").',
    );
  }
  final token = await readSecret(HubAuth.adminTokenFile(dir));
  if (token == null) {
    throw const LocalHubException(
      'This Windows user cannot manage the hub (it was started by another '
      'user).',
    );
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/v1/admin/pair'),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final res = await req.close();
    final body = jsonDecode(await utf8.decodeStream(res));
    if (res.statusCode != 200 || body is! Map || body['code'] is! String) {
      throw LocalHubException(
        'The hub refused: ${body is Map ? body['message'] : res.statusCode}',
      );
    }
    return (
      code: body['code'] as String,
      minutes: (body['expiresInMinutes'] as num?)?.toInt() ?? 10,
      port: port,
    );
  } on SocketException {
    throw const LocalHubException('The hub on this PC did not answer.');
  } finally {
    client.close(force: true);
  }
}

/// Gives this PC's hub an end-to-end pairing offer: [registerCode] (a
/// one-way function of the code shown to the user) and the workspace key
/// wrapped under the code. The hub never sees the code or the key.
Future<({int minutes, int port})> localPairingOffer({
  required String registerCode,
  required String wrappedKey,
  bool readOnly = false,
  Directory? hubDir,
}) async {
  if (hubDir == null &&
      (TestEnvironment.active ||
          Platform.environment.containsKey('FLUTTER_TEST'))) {
    throw const LocalHubException('Not available in test mode.');
  }
  final dir = hubDir ?? defaultLocalHubDir();
  final port = await localHubPort(dir);
  if (port == null) {
    throw const LocalHubException(
      'The hub is not running on this PC. Start it first ("thehub serve", '
      'or make it start with Windows with "thehub startup enable").',
    );
  }
  final token = await readSecret(HubAuth.adminTokenFile(dir));
  if (token == null) {
    throw const LocalHubException(
      'This Windows user cannot manage the hub (it was started by another '
      'user).',
    );
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/v1/admin/pair'),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'registerCode': registerCode,
        'wrappedKey': wrappedKey,
        if (readOnly) 'readOnly': true,
      }),
    );
    final res = await req.close();
    final body = jsonDecode(await utf8.decodeStream(res));
    if (res.statusCode != 200 || body is! Map) {
      throw LocalHubException(
        'The hub refused: ${body is Map ? body['message'] : res.statusCode}',
      );
    }
    return (
      minutes: (body['expiresInMinutes'] as num?)?.toInt() ?? 10,
      port: port,
    );
  } on SocketException {
    throw const LocalHubException('The hub on this PC did not answer.');
  } finally {
    client.close(force: true);
  }
}

/// Pauses or resumes sync on the hub running on this PC (Settings → Sync
/// switch). Returns false when no hub runs here (the app then only pauses
/// its own sync).
Future<bool> setLocalHubPaused(bool paused, {Directory? hubDir}) async {
  if (hubDir == null &&
      (TestEnvironment.active ||
          Platform.environment.containsKey('FLUTTER_TEST'))) {
    throw const LocalHubException('Not available in test mode.');
  }
  final dir = hubDir ?? defaultLocalHubDir();
  final port = await localHubPort(dir);
  if (port == null) return false;
  final token = await readSecret(HubAuth.adminTokenFile(dir));
  if (token == null) return false;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/v1/admin/pause'),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'paused': paused}));
    final res = await req.close();
    final body = jsonDecode(await utf8.decodeStream(res));
    if (res.statusCode != 200 || body is! Map || body['paused'] != paused) {
      throw LocalHubException(
        'The hub refused: ${body is Map ? body['message'] : res.statusCode}',
      );
    }
    return true;
  } on SocketException {
    return false; // stale hub.json: no hub is actually running
  } finally {
    client.close(force: true);
  }
}
