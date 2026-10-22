// Checks the TEST hub as seen through a Tailscale address of this PC.
// Test environment only: refuses any folder without the test marker and any
// port other than the test hub's (47799).
//
//   dart run tool/remote_check.dart --data <THEapp-TESTENV\hub> --address 100.x.y.z
//
// What it proves: the test hub really listens on that address, unauthenticated
// and wrong-token requests are refused, admin access is refused from it, the
// real hub's port is not reachable on it, and a disposable device can pair,
// send, receive and be revoked through it. What it does NOT prove: sync
// between different networks — everything here runs on this PC.
// Uses only synthetic data and a disposable device that is revoked at the end.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_application_1/hub/hub_auth.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/secret_store.dart';
import 'package:flutter_application_1/sync/sync_client.dart';

const testPort = 47799;
const realPort = 47710;

var failures = 0;
void result(bool ok, String what) {
  if (!ok) failures++;
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $what');
}

String? arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Future<int> status(
  String method,
  Uri url, {
  String? token,
  bool protocol = true,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.openUrl(method, url);
    if (protocol) req.headers.set(protocolHeader, '$syncProtocolVersion');
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> admin(
  String method,
  String path,
  String token, [
  Object? body,
]) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$testPort$path'),
    );
    req.headers
      ..set(protocolHeader, '$syncProtocolVersion')
      ..set('authorization', 'Bearer $token');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    return jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final data = arg(args, '--data');
  final address = arg(args, '--address');
  final loopbackDryRun = args.contains('--loopback-dry-run');
  if (data == null || address == null) {
    stderr.writeln('Usage: --data <test hub folder> --address <100.x.y.z>');
    exitCode = 64;
    return;
  }
  final dir = Directory(data);
  final appdata = Platform.environment['APPDATA'] ?? '';
  if (!File('${dir.path}${Platform.pathSeparator}.theapp-test-data')
          .existsSync() ||
      dir.absolute.path.toLowerCase().startsWith(
        '$appdata${Platform.pathSeparator}THEapp'.toLowerCase(),
      )) {
    stderr.writeln('Refusing: ${dir.path} is not the THEapp test hub folder.');
    exitCode = 64;
    return;
  }
  final ip = InternetAddress.tryParse(address);
  if (ip == null) {
    stderr.writeln('Not an IP address: $address');
    exitCode = 64;
    return;
  }

  stdout.writeln('Remote check of the TEST hub through $address:$testPort');
  stdout.writeln('(runs on this PC only — not a cross-network test)\n');

  // 1. The address is a Tailscale address of this PC.
  final base = Uri.parse('http://$address:$testPort');
  if (loopbackDryRun) {
    stdout.writeln('INFO  dry run on 127.0.0.1: Tailscale checks skipped');
  } else {
    result(isEncryptedHubRoute(base), '$address is a Tailscale address');
    final mine = [
      for (final i in await NetworkInterface.list())
        for (final a in i.addresses) a.address,
    ];
    result(mine.contains(address), '$address belongs to this PC');
  }

  // 2. The test hub is running and listening on that address.
  final adminToken = await readSecret(HubAuth.adminTokenFile(dir));
  if (adminToken == null) {
    result(false, 'test hub admin token readable (is the test hub running?)');
    exitCode = 1;
    return;
  }
  final s = await admin('GET', '/v1/admin/status', adminToken);
  final listening = (s['listening'] as List? ?? const []).cast<String>();
  stdout.writeln('INFO  test hub listening on: ${listening.join(', ')}');
  result(
    loopbackDryRun || listening.contains('$address:$testPort'),
    'test hub listens on $address:$testPort',
  );
  result(
    !listening.any((l) => l.startsWith('0.0.0.0') || l.startsWith('[::]')),
    'test hub does not listen on all interfaces',
  );

  // 3. Access controls through the address.
  result(
    await status('GET', base.replace(path: '/v1/status')) == 200,
    'status answers (no data, no token needed)',
  );
  final changes = base.replace(
    path: '/v1/changes',
    queryParameters: {'since': '0'},
  );
  result(await status('GET', changes) == 401, 'data refused without a token');
  result(
    await status('GET', changes, token: 'x' * 43) == 401,
    'data refused with a wrong token',
  );
  if (!loopbackDryRun) {
    result(
      await status(
            'GET',
            base.replace(path: '/v1/admin/status'),
            token: adminToken,
          ) ==
          401,
      'admin refused from the Tailscale side, even with the admin token',
    );
    var realOpen = false;
    try {
      final sock = await Socket.connect(
        address,
        realPort,
        timeout: const Duration(seconds: 3),
      );
      realOpen = true;
      sock.destroy();
    } catch (_) {}
    result(!realOpen, 'real hub port $realPort is not reachable on $address');
  }

  // 4. Disposable device round trip through the address, then revoked.
  final rand = Random.secure();
  final deviceId =
      'rc${List.generate(8, (_) => rand.nextInt(36).toRadixString(36)).join()}';
  final pair = await admin('POST', '/v1/admin/pair', adminToken);
  final client = SyncClient(base);
  try {
    final token = await client.register(
      pair['code'] as String,
      deviceId,
      'Remote check (disposable)',
    );
    client.token = token;
    final noteId = 'remotecheck-${DateTime.now().millisecondsSinceEpoch}';
    await client.push([
      SyncChange(
        collection: 'notes',
        id: noteId,
        rev:
            '${DateTime.now().millisecondsSinceEpoch.toString().padLeft(16, '0')}-0000-$deviceId',
        deleted: false,
        data: {'id': noteId, 'title': 'Synthetic remote check', 'body': ''},
      ),
    ]);
    var found = false;
    var cursor = 0;
    while (true) {
      final page = await client.pull(cursor);
      found = found || page.changes.any((c) => c.id == noteId);
      cursor = page.next;
      if (!page.hasMore) break;
    }
    result(found, 'pair, send and receive a synthetic note through $address');
    await admin('POST', '/v1/admin/revoke', adminToken, {'deviceId': deviceId});
    var refused = false;
    try {
      await client.pull(0);
    } on SyncFailure catch (e) {
      refused = e.code == 'unauthorized';
    }
    result(refused, 'the disposable device is refused after revocation');
  } on SyncFailure catch (e) {
    result(false, 'round trip through $address (${e.message})');
  } finally {
    client.close();
  }

  stdout.writeln(
    failures == 0
        ? '\nAll checks passed. This does NOT show sync across networks.'
        : '\n$failures check(s) failed.',
  );
  exitCode = failures == 0 ? 0 : 1;
}
