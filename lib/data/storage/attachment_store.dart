import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../platform/file_protection.dart';
import '../models/canvas_models.dart' show newId;
import 'storage_encryption.dart';

/// Keeps copies of imported files (photos, link previews) inside the app's
/// data folder, so they survive even if the original is moved or deleted.
///
/// Files are never overwritten or removed here; records refer to them by
/// file name. With encryption on (see storage_encryption.dart) the stored
/// file holds ciphertext: read it with [readBytes] or, where a native viewer
/// needs a real file, [viewFile].
class AttachmentStore {
  AttachmentStore(Directory root, {FileCipher? cipher})
    : dir = Directory('${root.path}${Platform.pathSeparator}attachments'),
      // ignore: prefer_initializing_formals
      _cipher = cipher;

  final Directory dir;
  final FileCipher? _cipher;

  FileCipher? get cipher => _cipher ?? StorageEncryption.active;

  static const imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

  /// The stored file (ciphertext when encryption is on). Fine for "does it
  /// exist" and its size on disk; to read the content use [readBytes].
  File fileFor(String name) =>
      File('${dir.path}${Platform.pathSeparator}$name');

  static String extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }

  /// Copies [source] in and returns the stored file name.
  Future<String> importFile(File source) async {
    final ext = extensionOf(source.path);
    final name = '${newId()}${ext.isEmpty ? '' : '.$ext'}';
    await _store(name, await source.readAsBytes());
    return name;
  }

  Future<String> importBytes(Uint8List bytes, String extension) async {
    final name = '${newId()}.$extension';
    await _store(name, bytes);
    return name;
  }

  /// Stores [bytes] as the attachment [name] (encrypted when encryption is on).
  Future<void> storeBytes(String name, Uint8List bytes) => _store(name, bytes);

  /// Takes a finished plain file (a download), stores it under [name]
  /// (encrypted) and removes the plain file.
  Future<void> adopt(String name, File plain) async {
    await _store(name, await plain.readAsBytes());
    if (await plain.exists()) await plain.delete();
  }

  Future<void> _store(String name, Uint8List bytes) async {
    await dir.create(recursive: true);
    final target = fileFor(name);
    final tmp = File('${target.path}.tmp');
    final c = cipher;
    final out = c == null ? bytes : c.encrypt(bytes);
    await FileProtection.whenUnlocked(() async {
      await tmp.writeAsBytes(out, flush: true);
      await tmp.rename(target.path);
    });
    await FileProtection.protect([target.path]);
  }

  /// The content of the stored file (decrypted in memory only).
  Future<Uint8List> readBytes(String name) =>
      StorageEncryption.readBytes(fileFor(name), cipher);

  /// SHA-256 (hex) and size of the content, as the hub and other devices see
  /// it (never of the ciphertext).
  Future<(String, int)> contentInfo(String name) async {
    final bytes = await readBytes(name);
    return (sha256.convert(bytes).toString(), bytes.length);
  }

  // ---------------------------------------------------------- view copies --

  /// Where decrypted copies for native viewers (PDF viewer, Quick Look,
  /// the system share sheet) are made. They are the one place decrypted
  /// attachment content touches the disk, in the app's private temporary
  /// folder: removed by [clearViewCopies] when the app locks or quits, and at
  /// the next start.
  static Directory get viewDir => Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}theapp-view',
  );

  /// A readable file with the content of [name], or null if it is missing.
  /// Plain files (no encryption, or not upgraded yet) are returned as they
  /// are. Blocks briefly for a large encrypted file the first time.
  File? viewFile(String name) {
    final source = fileFor(name);
    if (!source.existsSync()) return null;
    final raf = source.openSync();
    final bool encrypted;
    try {
      encrypted = FileCipher.isEncrypted(
        raf.readSync(FileCipher.headerLength + 16),
      );
    } finally {
      raf.closeSync();
    }
    if (!encrypted) return source;
    final target = File('${viewDir.path}${Platform.pathSeparator}$name');
    if (target.existsSync()) return target;
    final plain = StorageEncryption.readBytesSync(source, cipher);
    viewDir.createSync(recursive: true);
    final tmp = File('${target.path}.tmp');
    tmp.writeAsBytesSync(plain, flush: true);
    tmp.renameSync(target.path);
    FileProtection.protect([target.path]);
    return target;
  }

  /// Where a download is written before [adopt] encrypts it.
  File stagingFile(String name) {
    viewDir.createSync(recursive: true);
    return File('${viewDir.path}${Platform.pathSeparator}$name.incoming');
  }

  /// Removes every decrypted view copy.
  static void clearViewCopies() {
    try {
      if (viewDir.existsSync()) viewDir.deleteSync(recursive: true);
    } on FileSystemException {
      // In use by a viewer: removed at the next start.
    }
  }
}
