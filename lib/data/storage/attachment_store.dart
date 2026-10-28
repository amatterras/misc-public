import 'dart:io';
import 'dart:typed_data';

import '../../platform/file_protection.dart';
import '../models/canvas_models.dart' show newId;

/// Keeps copies of imported files (photos, link previews) inside the app's
/// data folder, so they survive even if the original is moved or deleted.
///
/// Files are never overwritten or removed here; records refer to them by
/// file name.
class AttachmentStore {
  AttachmentStore(Directory root)
    : dir = Directory('${root.path}${Platform.pathSeparator}attachments');

  final Directory dir;

  static const imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

  File fileFor(String name) =>
      File('${dir.path}${Platform.pathSeparator}$name');

  static String extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }

  /// Copies [source] in and returns the stored file name.
  Future<String> importFile(File source) async {
    await dir.create(recursive: true);
    final ext = extensionOf(source.path);
    final name = '${newId()}${ext.isEmpty ? '' : '.$ext'}';
    await FileProtection.whenUnlocked(() => source.copy(fileFor(name).path));
    await FileProtection.protect([fileFor(name).path]);
    return name;
  }

  Future<String> importBytes(Uint8List bytes, String extension) async {
    await dir.create(recursive: true);
    final name = '${newId()}.$extension';
    final tmp = File('${fileFor(name).path}.tmp');
    await FileProtection.whenUnlocked(() async {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(fileFor(name).path);
    });
    await FileProtection.protect([fileFor(name).path]);
    return name;
  }
}
