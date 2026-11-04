// OAuth 2.0 sign-in for installed apps (RFC 8252) with PKCE (RFC 7636):
// the provider's own sign-in page opens in the system browser; the code
// comes back to a one-time loopback address on this PC (Windows) or to the
// app's registered URL scheme (iPhone/iPad). No passwords pass through
// THEapp. Tokens are stored with the secret store (Windows DPAPI / iOS
// Keychain), never in settings, logs or synced records.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A provider's endpoints and the app registration the user supplied.
class OAuthConfig {
  const OAuthConfig({
    required this.authorizeUrl,
    required this.tokenUrl,
    required this.clientId,
    required this.scopes,
    this.clientSecret,
    this.extraAuthParams = const {},
    this.mobileRedirect,
    this.loopbackHost = '127.0.0.1',
  });

  final Uri authorizeUrl;
  final Uri tokenUrl;
  final String clientId;

  /// Google "Desktop app" clients have one (Google documents it as not
  /// confidential for installed apps); Microsoft public clients have none.
  final String? clientSecret;
  final List<String> scopes;
  final Map<String, String> extraAuthParams;

  /// iPhone/iPad redirect (a URL scheme registered for THEapp).
  final String? mobileRedirect;

  /// Google wants `127.0.0.1`, Microsoft `localhost`.
  final String loopbackHost;
}

class OAuthTokens {
  const OAuthTokens({
    required this.accessToken,
    required this.expiresAt,
    this.refreshToken,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  bool get expired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 1)));

  String toJson() => jsonEncode({
    'access': accessToken,
    'refresh': ?refreshToken,
    'expires': expiresAt.toUtc().toIso8601String(),
  });

  static OAuthTokens? fromJson(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return OAuthTokens(
        accessToken: j['access'] as String,
        refreshToken: j['refresh'] as String?,
        expiresAt: DateTime.parse(j['expires'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

class OAuthException implements Exception {
  const OAuthException(this.message, {this.signInAgain = false});
  final String message;

  /// The grant was revoked or expired: the user must connect again.
  final bool signInAgain;
  @override
  String toString() => message;
}

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String _random(int bytes) {
  final r = Random.secure();
  return _b64url([for (var i = 0; i < bytes; i++) r.nextInt(256)]);
}

/// PKCE pair: (verifier, S256 challenge).
(String, String) pkcePair() {
  final verifier = _random(48);
  return (verifier, _b64url(sha256.convert(ascii.encode(verifier)).bytes));
}

/// Pending iPhone/iPad sign-ins waiting for their redirect link.
final Map<String, Completer<Uri>> _mobilePending = {};

/// Called with links opened from outside (theapp://…); true when the link
/// was an OAuth redirect and was handled.
bool completeOAuthRedirect(Uri uri) {
  final state = uri.queryParameters['state'];
  final waiting = state == null ? null : _mobilePending.remove(state);
  if (waiting == null) return false;
  waiting.complete(uri);
  return true;
}

/// Runs the sign-in. [openBrowser] opens a URL in the system browser.
Future<OAuthTokens> signIn(
  OAuthConfig config, {
  required bool Function(String url) openBrowser,
  bool mobile = false,
  Duration timeout = const Duration(minutes: 5),
}) async {
  if (config.clientId.trim().isEmpty) {
    throw const OAuthException(
      'No client ID is set for this account type (see the setup notes).',
    );
  }
  final (verifier, challenge) = pkcePair();
  final state = _random(24);
  HttpServer? server;
  final String redirect;
  final Future<Uri> response;
  if (mobile) {
    final r = config.mobileRedirect;
    if (r == null || r.isEmpty) {
      throw const OAuthException(
        'This account type has no iPhone/iPad redirect set up yet.',
      );
    }
    redirect = r;
    final c = _mobilePending[state] = Completer<Uri>();
    response = c.future;
  } else {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    redirect = 'http://${config.loopbackHost}:${server.port}';
    // The redirect carries `state`; anything else (a favicon request) is ignored.
    response = server
        .firstWhere((r) => r.uri.queryParameters.containsKey('state'))
        .then((req) async {
          final uri = req.uri;
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              '<!doctype html><meta charset="utf-8"><title>misc.</title>'
              '<body style="font:16px system-ui;margin:3em">'
              'You can close this window and go back to misc.</body>',
            );
          await req.response.close();
          return uri;
        });
  }
  final url = config.authorizeUrl.replace(
    queryParameters: {
      'client_id': config.clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': config.scopes.join(' '),
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      ...config.extraAuthParams,
    },
  );
  try {
    if (!openBrowser(url.toString())) {
      throw const OAuthException('Could not open the sign-in page.');
    }
    final back = await response.timeout(timeout);
    final q = back.queryParameters;
    if (q['state'] != state) {
      throw const OAuthException('The sign-in answer did not match (state).');
    }
    if (q['error'] != null) {
      throw OAuthException(
        q['error'] == 'access_denied'
            ? 'Access was not granted.'
            : 'The sign-in failed (${q['error']}).',
      );
    }
    final code = q['code'];
    if (code == null) throw const OAuthException('No sign-in code came back.');
    return await _token(config, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirect,
      'code_verifier': verifier,
    });
  } on TimeoutException {
    throw const OAuthException('The sign-in was not finished in time.');
  } finally {
    _mobilePending.remove(state);
    await server?.close(force: true);
  }
}

/// A fresh access token from [refreshToken] (keeps the refresh token when
/// the provider does not send a new one).
Future<OAuthTokens> refresh(OAuthConfig config, String refreshToken) async {
  final t = await _token(config, {
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
  });
  return t.refreshToken == null
      ? OAuthTokens(
          accessToken: t.accessToken,
          refreshToken: refreshToken,
          expiresAt: t.expiresAt,
        )
      : t;
}

Future<OAuthTokens> _token(OAuthConfig c, Map<String, String> form) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.postUrl(c.tokenUrl);
    req.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    req.write(
      Uri(
        queryParameters: {
          ...form,
          'client_id': c.clientId,
          if (c.clientSecret != null && c.clientSecret!.isNotEmpty)
            'client_secret': c.clientSecret!,
        },
      ).query,
    );
    final res = await req.close().timeout(const Duration(seconds: 30));
    final body = await utf8.decodeStream(res);
    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw const OAuthException(
        'The sign-in service sent an unreadable answer.',
      );
    }
    if (res.statusCode >= 400 || json['access_token'] is! String) {
      final error = json['error'];
      throw OAuthException(
        error == 'invalid_grant'
            ? 'Access was revoked or expired. Connect the account again.'
            : 'The sign-in service refused (${error ?? res.statusCode}).',
        signInAgain: error == 'invalid_grant',
      );
    }
    final seconds = (json['expires_in'] as num?)?.toInt() ?? 3600;
    return OAuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: DateTime.now().add(Duration(seconds: seconds)),
    );
  } on SocketException {
    throw const OAuthException('No connection to the sign-in service.');
  } on TimeoutException {
    throw const OAuthException('The sign-in service took too long.');
  } finally {
    client.close(force: true);
  }
}
