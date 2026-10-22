import 'dart:io';
import 'dart:math' as math;

import '../../sync/secret_store.dart';
import '../storage/json_file_store.dart';

export '../../sync/hlc.dart';

/// This installation's identity, kept in `<data>\sync\device.json`.
///
/// If the data folder is copied to another computer, the host name no
/// longer matches and that copy gets its own new id, so two machines never
/// share one identity.
///
/// On iPhone/iPad the host name is not unique (often "localhost"), so the
/// id is also kept in the Keychain as "this device only". A backup restored
/// onto another iPad brings `device.json` but not that Keychain entry, so
/// the restored copy gets a new id too.
class DeviceIdentity {
  const DeviceIdentity({
    required this.id,
    required this.name,
    required this.host,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String host;
  final DateTime createdAt;

  /// Keychain entry holding this device's id (iPhone/iPad only).
  static const keychainKey = 'THEapp.device';

  static Future<DeviceIdentity> loadOrCreate(
    JsonFileStore store, {
    KeychainBackend? keychain,
  }) async {
    keychain ??= secretKeychain;
    final host = _hostName();
    final json = await store.read('sync', 'device');
    var same = json != null && json['host'] == host && json['id'] is String;
    if (json != null && same && keychain != null) {
      final mark = await _readMark(keychain);
      if (json['keychain'] == true) {
        // Bound earlier: a missing or different entry means this folder
        // came from another device (a restored backup).
        same = mark == json['id'];
      } else if (mark == null || mark == json['id']) {
        // First start with the Keychain: bind the existing id to it.
        if (await _writeMark(keychain, json['id'] as String)) {
          await store.write('sync', 'device', {...json, 'keychain': true});
        }
      } else {
        same = false;
      }
    }
    if (json != null && same) {
      return DeviceIdentity(
        id: json['id'] as String,
        name: json['name'] as String? ?? host,
        host: host,
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );
    }
    final identity = DeviceIdentity(
      id: _randomId(),
      name: host,
      host: host,
      createdAt: DateTime.now(),
    );
    await store.write('sync', 'device', {
      'id': identity.id,
      'name': identity.name,
      'host': identity.host,
      'createdAt': identity.createdAt.toIso8601String(),
      if (json != null) 'replaces': json['id'],
      if (keychain != null && await _writeMark(keychain, identity.id))
        'keychain': true,
    });
    return identity;
  }

  static Future<String?> _readMark(KeychainBackend keychain) async {
    try {
      return await keychain.read(keychainKey);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _writeMark(KeychainBackend keychain, String id) async {
    try {
      await keychain.write(keychainKey, id);
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _hostName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'unknown';
    }
  }

  /// 8 random base-36 characters (no dashes, so stamps stay parseable).
  static String _randomId() {
    final rand = math.Random.secure();
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    return List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
  }
}
