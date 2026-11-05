// A controllable network between a device and the real hub, for tests of
// connection loss and recovery. Everything is on 127.0.0.1 and deterministic:
// the test decides when the "network" goes away and comes back.
//
//   pass          requests go to the hub unchanged
//   down()        the port stops answering (connections in flight are cut,
//                 new ones are refused), like Wi-Fi dropping or airplane mode
//   up()          the same port answers again
//   refuseAuth    every request gets 401 (a device the hub does not know,
//                 or a hub that was replaced), except the public status page
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class FlakyProxy {
  FlakyProxy._(this.hubPort, HttpServer server)
    : _server = server,
      port = server.port;

  final int hubPort;
  HttpServer? _server;

  /// The address this "network" answers on (stays the same when it comes
  /// back after [down]).
  final int port;

  /// Answer every data request with 401.
  bool refuseAuth = false;

  /// Answer every data request with this status and error code (for example
  /// 426 / protocol_mismatch: a refusal that waiting does not fix).
  ({int status, String code})? refuseWith;

  /// Requests that reached the proxy (all kinds).
  int requests = 0;

  static Future<FlakyProxy> start(int hubPort) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final p = FlakyProxy._(hubPort, server);
    server.listen(p._handle);
    return p;
  }

  bool get isUp => _server != null;

  /// The network goes away: in-flight requests are cut, new connections are
  /// refused.
  Future<void> down() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  /// The network comes back on the same address.
  Future<void> up() async {
    if (_server != null) return;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = s;
    s.listen(_handle);
  }

  Future<void> close() => down();

  Future<void> _handle(HttpRequest r) async {
    requests++;
    final body = await r.fold<BytesBuilder>(
      BytesBuilder(),
      (b, d) => b..add(d),
    );
    final bytes = body.takeBytes();
    if (refuseAuth && r.uri.path != '/v1/status') {
      r.response.statusCode = 401;
      r.response.headers.contentType = ContentType.json;
      r.response.write('{"error":"unauthorized","message":"Not accepted."}');
      await r.response.close();
      return;
    }
    final forced = refuseWith;
    if (forced != null && r.uri.path != '/v1/status') {
      r.response.statusCode = forced.status;
      r.response.headers.contentType = ContentType.json;
      r.response.write(
        '{"error":"${forced.code}","message":"Refused for a test."}',
      );
      await r.response.close();
      return;
    }
    final client = HttpClient();
    try {
      final out = await client.openUrl(
        r.method,
        Uri.parse('http://127.0.0.1:$hubPort${r.uri}'),
      );
      r.headers.forEach((name, values) {
        if (const {
          'host',
          'content-length',
          'transfer-encoding',
          'connection',
        }.contains(name)) {
          return;
        }
        for (final v in values) {
          out.headers.add(name, v);
        }
      });
      if (bytes.isNotEmpty) {
        out.contentLength = bytes.length;
        out.add(bytes);
      }
      final res = await out.close();
      final reply = await res.fold<BytesBuilder>(
        BytesBuilder(),
        (b, d) => b..add(d),
      );
      r.response.statusCode = res.statusCode;
      res.headers.forEach((name, values) {
        if (const {
          'content-length',
          'transfer-encoding',
          'connection',
        }.contains(name)) {
          return;
        }
        for (final v in values) {
          r.response.headers.add(name, v);
        }
      });
      r.response.add(reply.takeBytes());
      await r.response.close();
    } on Object {
      // The hub went away or the "network" was cut mid-request.
      try {
        (await r.response.detachSocket()).destroy();
      } catch (_) {}
    } finally {
      client.close(force: true);
    }
  }
}
