// Where this device keeps the workspace keys used for end-to-end encrypted
// sync (see e2ee.dart) and its own device key pair (device_keys.dart): in
// OS-protected storage only (Windows DPAPI, the iOS Keychain), never beside
// the data in the clear and never in a backup (the `.key` names keep them out
// of backups, exports and restores).
//
// Without protected storage (any other platform) there are no keys and sync
// is not started: it is never run unencrypted or with a key left in a plain
// file.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'device_keys.dart';
import 'e2ee.dart';
import 'secret_store.dart';

class SyncKeyStore {
  SyncKeyStore(Directory root)
    : _file = File(
        '${root.path}${Platform.pathSeparator}keys'
        '${Platform.pathSeparator}sync.key',
      ),
      _deviceFile = File(
        '${root.path}${Platform.pathSeparator}keys'
        '${Platform.pathSeparator}device.key',
      );

  final File _file;
  final File _deviceFile;

  /// Whether this platform can protect the keys.
  bool get isSecure => Platform.isWindows || secretKeychain != null;

  /// The stored keys, or null if there are none (or they cannot be read).
  /// (One bare key is what an older version stored: epoch 1.)
  Future<SyncCrypto?> load() async {
    if (!isSecure) return null;
    final text = await readSecret(_file);
    if (text == null) return null;
    try {
      if (text.startsWith('{')) {
        final json = jsonDecode(text) as Map<String, dynamic>;
        final keys = {
          for (final e in (json['keys'] as Map<String, dynamic>).entries)
            int.parse(e.key): base64Decode(e.value as String),
        };
        if (keys.values.any((k) => k.length != 32)) return null;
        return SyncCrypto.epochs(keys, current: json['current'] as int);
      }
      final key = base64Decode(text);
      return key.length == 32 ? SyncCrypto(key) : null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Stores [crypto]'s keys (replacing any others) and checks they can be
  /// read back.
  Future<SyncCrypto> saveCrypto(SyncCrypto crypto) async {
    if (!isSecure) {
      throw const FileSystemException(
        'No protected key storage on this platform',
      );
    }
    final keys = crypto.exportKeys();
    await writeSecret(
      _file,
      jsonEncode({
        'v': 2,
        'current': crypto.current,
        'keys': {
          for (final e in keys.entries) '${e.key}': base64Encode(e.value),
        },
      }),
    );
    final back = await load();
    if (back == null ||
        back.current != crypto.current ||
        !_same(back.exportKey(), crypto.exportKey())) {
      throw const FileSystemException('The sync key could not be stored');
    }
    return back;
  }

  /// Stores one key as epoch 1 (the first key of a workspace).
  Future<SyncCrypto> save(Uint8List key) => saveCrypto(SyncCrypto(key));

  /// The stored keys, or a new random key (the first device of a workspace).
  Future<SyncCrypto> loadOrCreate() async =>
      await load() ?? await save(SyncCrypto.generate().exportKey());

  /// This device's key pair, made on first use.
  Future<DeviceKeyPair> loadOrCreateDeviceKey() async {
    if (!isSecure) {
      throw const FileSystemException(
        'No protected key storage on this platform',
      );
    }
    final text = await readSecret(_deviceFile);
    if (text != null) {
      try {
        final json = jsonDecode(text) as Map<String, dynamic>;
        return DeviceKeyPair(
          base64Decode(json['private'] as String),
          base64Decode(json['public'] as String),
        );
      } on FormatException {
        // Unreadable: a new pair is made (the hub is told about it).
      } on TypeError {
        // Same.
      }
    }
    final pair = DeviceKeyPair.generate();
    await writeSecret(
      _deviceFile,
      jsonEncode({
        'private': base64Encode(pair.privateBytes),
        'public': base64Encode(pair.publicBytes),
      }),
    );
    return pair;
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
