import 'dart:io';
import 'dart:math' as math;

import '../storage/json_file_store.dart';

export '../../sync/hlc.dart';

/// This installation's identity, kept in `<data>\sync\device.json`.
///
/// If the data folder is copied to another computer, the host name no
/// longer matches and that copy gets its own new id, so two machines never
/// share one identity.
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

  static Future<DeviceIdentity> loadOrCreate(JsonFileStore store) async {
    final host = _hostName();
    final json = await store.read('sync', 'device');
    if (json != null && json['host'] == host && json['id'] is String) {
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
    });
    return identity;
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
