// Device registry of the hub: concurrent pairing must never lose or garble
// devices.json (a damaged registry would lock every device out).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/hub/hub_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_auth_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('devices paired at the same moment are all saved', () async {
    final auth = await HubAuth.open(dir);
    final codes = [for (var i = 0; i < 12; i++) auth.createPairingCode()];
    final tokens = await Future.wait([
      for (var i = 0; i < codes.length; i++)
        auth.register(codes[i], 'dev$i', 'Device $i'),
    ]);
    expect(tokens.toSet(), hasLength(12));

    // The file on disk is complete and readable...
    final file = File('${dir.path}${Platform.pathSeparator}devices.json');
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect((saved['devices'] as List), hasLength(12));
    // ...and after a hub restart every token still works.
    final again = await HubAuth.open(dir);
    for (var i = 0; i < tokens.length; i++) {
      expect(again.authenticate(tokens[i])?.id, 'dev$i');
    }
  });

  test('pairing and revoking at the same time keep both changes', () async {
    final auth = await HubAuth.open(dir);
    final t0 = await auth.register(auth.createPairingCode(), 'old0', 'Old');
    final code = auth.createPairingCode();
    await Future.wait([
      auth.revoke('old0'),
      auth.register(code, 'new1', 'New'),
    ]);
    final again = await HubAuth.open(dir);
    expect(again.authenticate(t0), isNull, reason: 'revocation kept');
    expect(again.devices.map((d) => d.id), containsAll(['old0', 'new1']));
  });
}
