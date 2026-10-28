// Where this device keeps the workspace key used for end-to-end encrypted
// sync (see e2ee.dart): in OS-protected storage only (Windows DPAPI, the iOS
// Keychain), never beside the data in the clear and never in a backup (the
// `.key` name keeps it out of backups, exports and restores).
//
// Without protected storage (any other platform) there is no key and sync is
// not started: it is never run unencrypted or with a key left in a plain file.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'e2ee.dart';
import 'secret_store.dart';

class SyncKeyStore {
  SyncKeyStore(Directory root)
    : _file = File(
        '${root.path}${Platform.pathSeparator}keys'
        '${Platform.pathSeparator}sync.key',
      );

  final File _file;

  /// Whether this platform can protect the key.
  bool get isSecure => Platform.isWindows || secretKeychain != null;

  /// The stored key, or null if there is none (or it cannot be read).
  Future<SyncCrypto?> load() async {
    if (!isSecure) return null;
    final text = await readSecret(_file);
    if (text == null) return null;
    try {
      final key = base64Decode(text);
      return key.length == 32 ? SyncCrypto(key) : null;
    } on FormatException {
      return null;
    }
  }

  /// Stores [key] (replacing any other) and checks it can be read back.
  Future<SyncCrypto> save(Uint8List key) async {
    if (!isSecure) {
      throw const FileSystemException(
        'No protected key storage on this platform',
      );
    }
    await writeSecret(_file, base64Encode(key));
    final back = await load();
    if (back == null || !_same(back.exportKey(), key)) {
      throw const FileSystemException('The sync key could not be stored');
    }
    return back;
  }

  /// The stored key, or a new random one (the first device of a workspace).
  Future<SyncCrypto> loadOrCreate() async =>
      await load() ?? await save(SyncCrypto.generate().exportKey());

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
