// Encryption at rest for everything THEapp stores in its data folder.
//
// * Cipher: AES-256-GCM (pointycastle, a maintained library). Nothing here
//   is a home-made cipher.
// * Keys: one random 256-bit workspace key, made with the operating
//   system's secure random generator, kept ONLY in OS-protected storage
//   (Windows DPAPI, the iOS Keychain; see sync/secret_store.dart). Each file
//   gets its own key, derived with HKDF-SHA256 from the workspace key and a
//   fresh random 16-byte salt, plus a fresh random 96-bit nonce, so a
//   (key, nonce) pair is never reused.
// * Format (version 1): "TAEF" | version(1) | algorithm(1) | salt(16) |
//   nonce(12) | ciphertext | GCM tag(16). The header is authenticated.
// * No password, passphrase or recovery code exists. A device that does not
//   hold the workspace key cannot read the data, and never invents a new key
//   while encrypted data exists.
// * Platforms without OS-protected key storage (anything but Windows and
//   iPhone/iPad) get NO encryption and say so ([EncryptionStatus]); the key
//   is never written beside the data.
//
// What is NOT covered (see STORAGE_MODES / MASTER_SPEC): the log, user-asked
// exports, the home-screen widget snapshot, and the short-lived decrypted
// copies that native viewers need (see AttachmentStore.viewFile).
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../../sync/secret_store.dart';

/// Tag or format check failed: wrong key, tampering, or damage.
class DecryptionFailure implements Exception {
  const DecryptionFailure(this.message);
  final String message;
  @override
  String toString() => 'DecryptionFailure: $message';
}

/// The data is encrypted but this device holds no (or the wrong) key, so
/// nothing is read or written. Never "fixed" by making a new key.
class StorageLockedException implements Exception {
  const StorageLockedException(this.message);
  final String message;
  @override
  String toString() => message;
}

final class FileCipher {
  FileCipher(Uint8List key) : _key = Uint8List.fromList(key) {
    if (key.length != keyLength) {
      throw ArgumentError('The workspace key must be $keyLength bytes');
    }
  }

  static const keyLength = 32;
  static const _magic = [0x54, 0x41, 0x45, 0x46]; // "TAEF"
  static const formatVersion = 1;
  static const _algorithm = 1; // AES-256-GCM, HKDF-SHA256
  static const _saltLength = 16;
  static const _nonceLength = 12;
  static const _tagLength = 16;
  static const headerLength = 4 + 1 + 1 + _saltLength + _nonceLength;

  final Uint8List _key;
  static final Random _random = Random.secure();

  static Uint8List randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  /// A fresh random workspace key.
  static Uint8List generateKey() => randomBytes(keyLength);

  /// Whether [bytes] look like something this class wrote.
  static bool isEncrypted(List<int> bytes) {
    if (bytes.length < headerLength + _tagLength) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  /// Whether the file starts with the encrypted-file marker.
  static Future<bool> fileIsEncrypted(File file) async {
    final raf = await file.open();
    try {
      final head = await raf.read(headerLength + _tagLength);
      return isEncrypted(head);
    } finally {
      await raf.close();
    }
  }

  Uint8List _fileKey(Uint8List salt) {
    // HKDF-SHA256 (RFC 5869): extract, then one expand block (32 bytes).
    final prk = Hmac(sha256, salt).convert(_key).bytes;
    final okm = Hmac(
      sha256,
      prk,
    ).convert([...utf8.encode('THEapp file key v1'), 1]).bytes;
    return Uint8List.fromList(okm);
  }

  /// [context]: extra data that is authenticated but not stored (e.g. which
  /// record this is), so a ciphertext cannot be moved to another place and
  /// still open. The same [context] must be given to [decrypt].
  Uint8List encrypt(List<int> plain, {List<int> context = const []}) {
    final salt = randomBytes(_saltLength);
    final nonce = randomBytes(_nonceLength);
    final header = Uint8List.fromList([
      ..._magic,
      formatVersion,
      _algorithm,
      ...salt,
      ...nonce,
    ]);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(_fileKey(salt)),
          _tagLength * 8,
          nonce,
          Uint8List.fromList([...header, ...context]),
        ),
      );
    final body = gcm.process(Uint8List.fromList(plain));
    return Uint8List.fromList([...header, ...body]);
  }

  /// Throws [DecryptionFailure] for a wrong key, a changed byte, a
  /// truncated file or a format this version does not know.
  Uint8List decrypt(List<int> data, {List<int> context = const []}) {
    if (!isEncrypted(data)) {
      throw const DecryptionFailure('Not an encrypted misc. file');
    }
    if (data[4] != formatVersion || data[5] != _algorithm) {
      throw const DecryptionFailure(
        'Written by a newer version of misc. (kept untouched)',
      );
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final header = Uint8List.sublistView(bytes, 0, headerLength);
    final salt = Uint8List.sublistView(bytes, 6, 6 + _saltLength);
    final nonce = Uint8List.sublistView(bytes, 6 + _saltLength, headerLength);
    final body = Uint8List.sublistView(bytes, headerLength);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(_fileKey(salt)),
          _tagLength * 8,
          nonce,
          Uint8List.fromList([...header, ...context]),
        ),
      );
    try {
      return gcm.process(body);
    } on InvalidCipherTextException {
      throw const DecryptionFailure(
        'Authentication failed (wrong key or changed data)',
      );
    }
  }

  /// Encrypts a string (UTF-8).
  Uint8List encryptText(String text) => encrypt(utf8.encode(text));

  /// Data at least this large is encrypted and decrypted on a background
  /// isolate: AES-GCM here is plain Dart (measured about 2 s per MB in a
  /// debug build), and on the UI isolate a large photo or PDF would freeze
  /// typing and drawing while it runs.
  static const backgroundBytes = 64 * 1024;

  /// [encrypt], off the UI isolate for large data.
  Future<Uint8List> encryptAsync(
    List<int> plain, {
    List<int> context = const [],
  }) {
    if (plain.length < backgroundBytes) {
      return Future.value(encrypt(plain, context: context));
    }
    final data = plain is Uint8List ? plain : Uint8List.fromList(plain);
    return Isolate.run(() => encrypt(data, context: context));
  }

  /// [decrypt], off the UI isolate for large data. Throws
  /// [DecryptionFailure] like [decrypt].
  Future<Uint8List> decryptAsync(
    List<int> data, {
    List<int> context = const [],
  }) {
    if (data.length < backgroundBytes) {
      return Future.value(decrypt(data, context: context));
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    return Isolate.run(() => decrypt(bytes, context: context));
  }

  /// Overwrites the key in memory (best effort: Dart may have copied it).
  void dispose() => _key.fillRange(0, _key.length, 0);

  /// The key, for key-checking only.
  bool sameKeyAs(FileCipher other) {
    var diff = 0;
    for (var i = 0; i < keyLength; i++) {
      diff |= _key[i] ^ other._key[i];
    }
    return diff == 0;
  }
}

/// Where the workspace key lives. Production: DPAPI / Keychain.
abstract class WorkspaceKeyStore {
  /// False where no OS-protected key storage exists.
  bool get isSecure;
  Future<Uint8List?> read();
  Future<void> write(Uint8List key);
}

/// Key kept with sync/secret_store.dart: a DPAPI blob in `keys/workspace.key`
/// on Windows, a Keychain entry on iPhone/iPad (the file then holds no
/// secret). `*.key` files are never copied into backups or exports and a
/// restore never replaces them (BackupService.isSecret).
class OsWorkspaceKeyStore implements WorkspaceKeyStore {
  OsWorkspaceKeyStore(Directory root)
    : _file = File(
        '${root.path}${Platform.pathSeparator}keys'
        '${Platform.pathSeparator}workspace.key',
      );

  final File _file;

  @override
  bool get isSecure => Platform.isWindows || secretKeychain != null;

  @override
  Future<Uint8List?> read() async {
    if (!isSecure) return null;
    final text = await readSecret(_file);
    if (text == null) return null;
    try {
      final bytes = base64Decode(text);
      return bytes.length == FileCipher.keyLength ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(Uint8List key) async {
    if (!isSecure) {
      throw const FileSystemException(
        'No protected key storage on this platform',
      );
    }
    await writeSecret(_file, base64Encode(key));
  }
}

enum EncryptionStatus {
  /// Everything private is encrypted at rest.
  enabled,

  /// No OS-protected key storage here: data is NOT encrypted, and no key was
  /// made.
  unsupportedPlatform,

  /// Encrypted data exists but this device has no key for it. Nothing is
  /// opened, changed or replaced.
  keyMissing,
}

class StorageEncryptionState {
  const StorageEncryptionState(this.status, this.cipher);
  final EncryptionStatus status;
  final FileCipher? cipher;

  String get message => switch (status) {
    EncryptionStatus.enabled => 'Your data is encrypted on this device.',
    EncryptionStatus.unsupportedPlatform =>
      'This platform has no protected key storage, so the data on it is '
          'NOT encrypted.',
    EncryptionStatus.keyMissing =>
      'Your data is encrypted, but this device does not have its key (for '
          'example after a Windows account reset or a backup from another '
          'device). Nothing was changed or deleted. The key cannot be '
          'recreated, and no password or recovery code exists to recover it.',
  };
}

abstract final class StorageEncryption {
  /// The cipher the stores use (set by the app at start-up). Null = data is
  /// kept as before (tests, platforms without key storage).
  static FileCipher? active;

  /// Folders whose files are encrypted ([root] relative). Logs and exports
  /// are deliberately outside.
  static const skippedTopLevel = {'keys', 'logs', 'exports'};

  /// Opens (or, the very first time, creates) the workspace key.
  static Future<StorageEncryptionState> open(
    Directory root, {
    WorkspaceKeyStore? keys,
  }) async {
    final store = keys ?? OsWorkspaceKeyStore(root);
    if (!store.isSecure) {
      return const StorageEncryptionState(
        EncryptionStatus.unsupportedPlatform,
        null,
      );
    }
    final existing = await store.read();
    if (existing != null) {
      final cipher = FileCipher(existing);
      // A key that does not open this folder's data is as good as missing
      // (e.g. another device's key): never used, so nothing is quarantined
      // or overwritten because of it.
      if (!await _keyMatches(root, cipher)) {
        return const StorageEncryptionState(EncryptionStatus.keyMissing, null);
      }
      return StorageEncryptionState(EncryptionStatus.enabled, cipher);
    }
    // No key. Never make one while encrypted data exists: it could not open
    // that data, and later writes would mix keys.
    if (await hasEncryptedData(root)) {
      return const StorageEncryptionState(EncryptionStatus.keyMissing, null);
    }
    final key = FileCipher.generateKey();
    await store.write(key);
    final back = await store.read();
    if (back == null || !_same(back, key)) {
      throw const FileSystemException(
        'The new workspace key could not be stored',
      );
    }
    final cipher = FileCipher(key);
    await _sentinel(root).parent.create(recursive: true);
    await _sentinel(root)
        .writeAsBytes(cipher.encryptText(_sentinelText), flush: true);
    return StorageEncryptionState(EncryptionStatus.enabled, cipher);
  }

  /// Whether [cipher] opens the data in [root] (or there is nothing yet to
  /// compare with). Never changes or quarantines data.
  static Future<bool> keyOpens(Directory root, FileCipher cipher) =>
      _keyMatches(root, cipher);

  static const _sentinelText = 'THEapp key check';

  static File _sentinel(Directory root) => File(
    '${root.path}${Platform.pathSeparator}keys${Platform.pathSeparator}key-check',
  );

  /// Whether [cipher] opens what is in [root]: its key-check file, or (for a
  /// folder made before that file existed) the first encrypted data file.
  static Future<bool> _keyMatches(Directory root, FileCipher cipher) async {
    try {
      final check = _sentinel(root);
      if (await check.exists()) {
        return utf8.decode(cipher.decrypt(await check.readAsBytes())) ==
            _sentinelText;
      }
      await for (final f in managedFiles(root)) {
        if (await FileCipher.fileIsEncrypted(f)) {
          cipher.decrypt(await f.readAsBytes());
          break;
        }
      }
      // Nothing to compare with yet: remember the key for next time.
      await check.parent.create(recursive: true);
      await check.writeAsBytes(cipher.encryptText(_sentinelText), flush: true);
      return true;
    } on DecryptionFailure {
      return false;
    }
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Whether any file in [root] (outside the skipped folders) is encrypted.
  static Future<bool> hasEncryptedData(Directory root) async {
    if (!await root.exists()) return false;
    await for (final f in managedFiles(root)) {
      if (await FileCipher.fileIsEncrypted(f)) return true;
    }
    return false;
  }

  /// Every file the encryption covers: all of [root] except the skipped
  /// folders and credential files (already protected by the OS).
  static Stream<File> managedFiles(Directory root) async* {
    final sep = Platform.pathSeparator;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path.substring(root.path.length + 1);
      final first = rel.split(RegExp(r'[\\/]')).first;
      if (skippedTopLevel.contains(first)) continue;
      final name = rel.split(sep).last.toLowerCase();
      if (name.endsWith('.token') ||
          name.endsWith('.token.bak') ||
          name.endsWith('.key') ||
          name.endsWith('.client')) {
        continue;
      }
      yield e;
    }
  }

  /// The decrypted bytes of a file the stores wrote: ciphertext is opened
  /// with [cipher]; older plain files are returned as they are.
  static Future<Uint8List> readBytes(File file, FileCipher? cipher) async {
    final bytes = await file.readAsBytes();
    if (!FileCipher.isEncrypted(bytes)) return bytes;
    if (cipher == null) {
      throw StorageLockedException(
        'This file is encrypted and no key is available: ${file.path}',
      );
    }
    return cipher.decryptAsync(bytes);
  }

  /// [readBytes], blocking (only for the viewer copies that need a file now).
  static Uint8List readBytesSync(File file, FileCipher? cipher) {
    final bytes = file.readAsBytesSync();
    if (!FileCipher.isEncrypted(bytes)) return bytes;
    if (cipher == null) {
      throw StorageLockedException(
        'This file is encrypted and no key is available: ${file.path}',
      );
    }
    return cipher.decrypt(bytes);
  }

  static Future<String> readText(File file, FileCipher? cipher) async =>
      utf8.decode(await readBytes(file, cipher));

  /// Writes [text] to [file] (encrypted when [cipher] is set), flushed.
  static Future<void> writeText(
    File file,
    String text,
    FileCipher? cipher,
  ) async {
    final plain = utf8.encode(text);
    await file.writeAsBytes(
      cipher == null ? plain : await cipher.encryptAsync(plain),
      flush: true,
    );
  }
}
