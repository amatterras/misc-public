// Tests with several simulated devices: every device of a test uses this one
// workspace key, as devices that were paired with an end-to-end pairing code
// do. (Each real device would otherwise make its own random key.)
import 'dart:typed_data';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/hub/hub_auth.dart';
import 'package:flutter_application_1/sync/e2ee.dart';
import 'package:flutter_application_1/sync/protocol.dart';

final testSyncKey = Uint8List.fromList(List.generate(32, (i) => i * 7 + 3));

final testSyncCrypto = SyncCrypto(testSyncKey);

/// Gives [state] the shared test key (call before it syncs).
Future<void> shareSyncKey(AppState state) async {
  await state.syncKeys.save(testSyncKey);
}

/// The plain record of a change as stored on a hub (which holds it sealed).
Map<String, dynamic>? openedData(SyncChange? c) =>
    c == null ? null : testSyncCrypto.openChange(c).data;

/// A pairing code like the one a device that has the key shows: the hub gets
/// an offer carrying the shared test key (wrapped), and the code is returned.
String keyedPairingCode(HubAuth auth) {
  final secret = PairingSecret.generate();
  auth.createPairingOffer(
    registerCode: secret.registerCode,
    wrappedKey: secret.wrap(testSyncKey),
  );
  return secret.display;
}
