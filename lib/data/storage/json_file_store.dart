import 'dart:convert';
import 'dart:io';

import 'app_log.dart';

/// Returns the folder where the app keeps its data.
///
/// On Windows this is `%APPDATA%\THEapp` (e.g.
/// `C:\Users\<you>\AppData\Roaming\THEapp`). We resolve it ourselves rather
/// than through the path_provider plugin, because Flutter plugins on Windows
/// require Developer Mode to be enabled.
Directory defaultDataDirectory() {
  final env = Platform.environment;
  final String base;
  if (Platform.isWindows) {
    base = env['APPDATA'] ?? env['USERPROFILE'] ?? Directory.current.path;
  } else if (Platform.isMacOS) {
    base = '${env['HOME']}/Library/Application Support';
  } else if (Platform.isIOS) {
    // In iOS sandbox containers, env['HOME'] points to the application container.
    // Library/Application Support is durable and excluded from user Document browsing.
    final home = env['HOME'] ?? '.';
    base = '$home/Library/Application Support';
  } else {
    base = env['XDG_DATA_HOME'] ?? '${env['HOME']}/.local/share';
  }
  return Directory('$base${Platform.pathSeparator}THEapp');
}

/// Stores JSON documents as individual files with crash-safe writes.
///
/// Every write goes to a temporary file first and is then renamed over the
/// real file, so a crash mid-write never leaves a half-written document.
/// The previous version is kept as `<name>.bak` and used automatically if
/// the main file is ever unreadable.
class JsonFileStore {
  JsonFileStore(this.root);

  final Directory root;

  File _file(String collection, String id) => File(
    '${root.path}${Platform.pathSeparator}$collection'
    '${Platform.pathSeparator}$id.json',
  );

  Directory _dir(String collection) =>
      Directory('${root.path}${Platform.pathSeparator}$collection');

  /// Pending writes per file, so writes to the same file never overlap.
  final Map<String, Future<void>> _pending = {};

  /// When true, writes are ignored (used while restoring a backup so no
  /// pending autosave can overwrite the restored files).
  bool readOnly = false;

  Future<void> write(String collection, String id, Map<String, dynamic> json) {
    if (readOnly) return Future.value();
    final file = _file(collection, id);
    // Encode now so later changes to [json] can't affect this write.
    final text = const JsonEncoder.withIndent(' ').convert(json);
    final previous = _pending[file.path] ?? Future<void>.value();
    final next = previous.catchError((_) {}).then((_) => _writeNow(file, text));
    _pending[file.path] = next;
    return next.whenComplete(() {
      if (identical(_pending[file.path], next)) _pending.remove(file.path);
    });
  }

  Future<void> _writeNow(File file, String text) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    if (await file.exists()) {
      await _retry(() => file.copy('${file.path}.bak'));
    }
    await _retry(() => tmp.rename(file.path));
  }

  /// Antivirus or search indexing can briefly lock a file on Windows;
  /// retry a few times before giving up.
  static Future<T> _retry<T>(Future<T> Function() action) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await action();
      } on FileSystemException {
        if (attempt >= 5) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 40 * attempt));
      }
    }
  }

  /// Problems found while reading (damaged files moved aside, backups
  /// used). Shown to the user once after start-up.
  final List<String> recoveries = [];

  /// Moves an unreadable file aside so it is never written over, and so
  /// the next save cannot copy it over the good `.bak`.
  Future<void> _quarantine(File file) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    try {
      await file.rename('${file.path}.corrupt-$stamp');
    } catch (e) {
      AppLog.error('Could not move damaged file ${file.path} aside', e);
    }
  }

  /// Reads a document, falling back to its backup if the main file is
  /// missing or corrupt. Returns null if neither is readable.
  Future<Map<String, dynamic>?> read(String collection, String id) async {
    final file = _file(collection, id);
    final bak = File('${file.path}.bak');
    final main = await _tryRead(file);
    if (main != null) return main;
    final mainDamaged = await file.exists();
    if (mainDamaged) await _quarantine(file);
    final backup = await _tryRead(bak);
    if (backup != null) {
      if (mainDamaged) {
        final message =
            '$collection/$id.json was damaged; restored its previous version.';
        recoveries.add(message);
        AppLog.warn(message);
        // Put the good copy back as the main file straight away.
        await _retry(() => bak.copy(file.path));
      }
      return backup;
    }
    if (await bak.exists()) await _quarantine(bak);
    if (mainDamaged) {
      final message =
          '$collection/$id.json was damaged and had no usable backup copy. '
          'The damaged file was kept (.corrupt); restore from Settings → Backups.';
      recoveries.add(message);
      AppLog.error(message);
    }
    return null;
  }

  Future<Map<String, dynamic>?> _tryRead(File file) async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Ids of all documents in [collection].
  Future<List<String>> list(String collection) async {
    final dir = _dir(collection);
    if (!await dir.exists()) return [];
    final ids = <String>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      // Include ids that only survive as a backup.
      for (final suffix in ['.json', '.json.bak']) {
        if (name.endsWith(suffix)) {
          ids.add(name.substring(0, name.length - suffix.length));
        }
      }
    }
    return ids.toList();
  }

  /// Moves a document into `<collection>/.trash` rather than deleting it,
  /// so nothing is lost permanently by accident.
  Future<void> moveToTrash(String collection, String id) async {
    final file = _file(collection, id);
    if (!await file.exists()) return;
    final trash = Directory(
      '${_dir(collection).path}${Platform.pathSeparator}.trash',
    );
    await trash.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await file.rename('${trash.path}${Platform.pathSeparator}$id-$stamp.json');
    final bak = File('${file.path}.bak');
    if (await bak.exists()) await bak.delete();
  }
}
