// Checks a running hosted sync service (`thehub hosted-serve`) from outside
// its process, with synthetic data only. No Windows PC hub is involved.
//
//   dart run bin/thehub.dart hosted-invite --data <folder>
//   dart run bin/thehub.dart hosted-serve  --data <folder> --port 47811
//   dart run tool/hosted_check.dart --url http://127.0.0.1:47811 --invite <code>
//
// The app itself only accepts https:// for a hosted service; plain HTTP to
// 127.0.0.1 is used here because no TLS proxy (Caddy) runs on this PC. What
// it proves: account creation needs the invite, two devices of one account
// exchange a record and an attachment (checked by SHA-256), a retried push
// is recognised, a wrong password and admin/share endpoints are refused,
// and another account sees nothing. What it does NOT prove: TLS, Docker, a
// real domain, or a different network.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_application_1/sync/hlc.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';

var failures = 0;
void result(bool ok, String what) {
  if (!ok) failures++;
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $what');
}

String? arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Future<bool> refused(Future<Object?> Function() call) async {
  try {
    await call();
    return false;
  } on SyncFailure {
    return true;
  }
}

Future<void> main(List<String> args) async {
  final url = Uri.parse(arg(args, '--url') ?? 'http://127.0.0.1:47811');
  final invite = arg(args, '--invite');
  if (invite == null) {
    stderr.writeln('Needs --invite <code> (thehub hosted-invite).');
    exitCode = 64;
    return;
  }
  final rnd = Random.secure();
  final suffix = List.generate(6, (_) => rnd.nextInt(10)).join();
  final email = 'check$suffix@example.com';
  const password = 'synthetic password 1';

  final a = SyncClient(url);
  final b = SyncClient(url);
  final temp = await Directory.systemTemp.createTemp('theapp-hosted-check-');
  try {
    result(
      await refused(() => a.createAccount(email, password, 'WRONGCODE')),
      'account creation refused without a valid invite',
    );
    await a.createAccount(email, password, invite);
    result(true, 'account created with the invite');
    result(
      await refused(() => a.createAccount('x$email', password, invite)),
      'the invite works only once',
    );
    result(
      await refused(() => b.signIn(email, 'wrong password!', 'devb', 'B')),
      'wrong password refused',
    );
    await a.signIn(email, password, 'deva$suffix', 'Device A');
    await b.signIn(email, password, 'devb$suffix', 'Device B');
    result(true, 'two devices signed in to one account');

    // An attachment, by SHA-256, then the record that names it.
    final bytes = Uint8List.fromList(List.generate(4096, (i) => i % 251));
    final source = File('${temp.path}${Platform.pathSeparator}a.bin')
      ..writeAsBytesSync(bytes);
    final sha = await fileSha256(source);
    await a.upload(sha, source);
    final clock = SyncClock(deviceId: 'deva$suffix');
    final change = SyncChange(
      collection: 'notes',
      id: 'note$suffix',
      rev: clock.now(),
      deleted: false,
      data: {'id': 'note$suffix', 'title': 'Synthetic', 'body': 'check'},
    );
    final first = await a.push([change]);
    result(first.results.single.status == PushStatus.applied, 'record stored');
    final again = await a.push([change]);
    result(
      again.results.single.status == PushStatus.duplicate &&
          again.lastSeq == first.lastSeq,
      'a retried push is recognised, not stored twice',
    );
    final pulled = await b.pull(0);
    result(
      pulled.changes.any((c) => c.key == 'notes/note$suffix'),
      'the other device receives the record',
    );
    final target = File('${temp.path}${Platform.pathSeparator}b.bin');
    await b.download(sha, bytes.length, target);
    result(
      await fileSha256(target) == sha,
      'the other device receives the attachment intact (SHA-256)',
    );

    final http = HttpClient();
    for (final path in ['/v1/admin/status', '/s/${'x' * 30}']) {
      final res = await (await http.getUrl(url.resolve(path))).close();
      await res.drain<void>();
      result(res.statusCode == 404, 'admin/share endpoint off: $path');
    }
    http.close(force: true);
  } on SyncFailure catch (e) {
    result(false, 'unexpected failure: ${e.code}');
  } finally {
    a.close();
    b.close();
    await temp.delete(recursive: true);
  }
  stdout.writeln(failures == 0 ? 'ALL PASSED' : '$failures FAILED');
  exitCode = failures == 0 ? 0 : 1;
}
