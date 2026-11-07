import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../platform/file_protection.dart';
import 'app_log.dart';
import 'storage_encryption.dart';

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
    base = iosFolder(
      'Library/Application Support',
      reported: iosApplicationSupport,
      home: env['HOME'],
      systemTemp: Directory.systemTemp.path,
    );
  } else {
    base = env['XDG_DATA_HOME'] ?? '${env['HOME']}/.local/share';
  }
  return Directory('$base${Platform.pathSeparator}THEapp');
}

/// iPhone/iPad: the app's folders as iOS reports them (set at start-up from
/// the native side; iOS does not set HOME for apps).
String? iosApplicationSupport;
String? iosDocuments;

/// An iOS app folder ([relative] inside the app's container, e.g.
/// `Library/Application Support`): the path iOS [reported] if any, else
/// derived from HOME, else from the temporary folder (`<container>/tmp`).
/// Never a relative path: a relative path resolves against `/`, where iOS
/// refuses to write (the cause of the first iPad build's start-up failure).
String iosFolder(
  String relative, {
  String? reported,
  String? home,
  String? systemTemp,
}) {
  bool absolute(String? p) => p != null && p.startsWith('/') && p.length > 1;
  if (absolute(reported)) return reported!;
  if (absolute(home)) return '$home/$relative';
  if (absolute(systemTemp)) {
    final tmp = systemTemp!.endsWith('/')
        ? systemTemp.substring(0, systemTemp.length - 1)
        : systemTemp;
    if (tmp.endsWith('/tmp')) {
      return '${tmp.substring(0, tmp.length - 4)}/$relative';
    }
  }
  throw const FileSystemException(
    'Could not find this app\'s folder on the iPhone/iPad',
  );
}

/// Stores JSON documents as individual files with crash-safe writes.
///
/// Every write goes to a temporary file first and is then renamed over the
/// real file, so a crash mid-write never leaves a half-written document.
/// The previous readable version (or, after the first save, a copy of the
/// file itself) is kept as `<name>.bak` and used automatically if
/// the main file is ever unreadable.
class JsonFileStore {
  /// [cipher]: encrypts every file written here (AES-256-GCM, see
  /// storage_encryption.dart). Without one the app-wide
  /// [StorageEncryption.active] is used, and without that, files stay plain
  /// text as before. Older plain files are still read, and are encrypted the
  /// next time they are saved (or by the one-time upgrade).
  // ignore: prefer_initializing_formals
  JsonFileStore(this.root, {FileCipher? cipher}) : _cipher = cipher;

  final Directory root;
  final FileCipher? _cipher;

  FileCipher? get cipher => _cipher ?? StorageEncryption.active;

  File _file(String collection, String id) => File(
    '${root.path}${Platform.pathSeparator}$collection'
    '${Platform.pathSeparator}$id.json',
  );

  Directory _dir(String collection) =>
      Directory('${root.path}${Platform.pathSeparator}$collection');

  /// Pending writes per file, so writes to the same file never overlap.
  final Map<String, Future<void>> _pending = {};

  final List<void Function(String collection, String id)> _writeListeners = [];

  /// Tells [listener] after every write, delete or move to the trash made
  /// through this store (it is called when the change is on disk, or has
  /// failed: either way the file may have changed, so a cache of it must not
  /// be trusted). Used by caches such as the canvas manifest.
  void addWriteListener(void Function(String collection, String id) listener) {
    _writeListeners.add(listener);
  }

  void _changed(String collection, String id) {
    for (final l in List.of(_writeListeners)) {
      try {
        l(collection, id);
      } catch (_) {
        // A faulty listener must never break a save.
      }
    }
  }

  /// A cheap description of the files behind a document (size and
  /// modification time of the file and of its previous-version copy), or null
  /// if neither exists. Changes whenever either file is rewritten, so a cache
  /// that keeps this beside what it read can tell, without reading, whether
  /// the document may have changed.
  Future<String?> fingerprint(String collection, String id) async {
    final file = _file(collection, id);
    String part(FileStat s) => s.type == FileSystemEntityType.notFound
        ? '-'
        : '${s.size}@${s.modified.microsecondsSinceEpoch}';
    try {
      final main = await file.stat();
      final bak = await File('${file.path}.bak').stat();
      if (main.type == FileSystemEntityType.notFound &&
          bak.type == FileSystemEntityType.notFound) {
        return null;
      }
      return 'm:${part(main)}|b:${part(bak)}';
    } on FileSystemException {
      return null;
    }
  }

  /// When true, writes are ignored (used while restoring a backup so no
  /// pending autosave can overwrite the restored files).
  bool readOnly = false;

  Future<void> write(String collection, String id, Map<String, dynamic> json) {
    if (readOnly) return Future.value();
    // Encode now so later changes to [json] can't affect this write.
    return _enqueue(
      collection,
      id,
      const JsonEncoder.withIndent(' ').convert(json),
    );
  }

  /// Like [write], with the document already encoded (as [write] would) or
  /// still being encoded elsewhere (a large drawing on a background
  /// isolate). The write keeps its place in the order of writes of the same
  /// document from the moment it is called, however long [text] takes.
  Future<void> writeText(String collection, String id, Future<String> text) {
    if (readOnly) return Future.value();
    return _enqueue(collection, id, text);
  }

  /// Queues the write of [text] (a String, or a Future of one) after the
  /// writes of the same document already queued.
  Future<void> _enqueue(String collection, String id, Object text) {
    final file = _file(collection, id);
    final previous = _pending[file.path] ?? Future<void>.value();
    // On a locked iPhone/iPad the write waits (still in order, still once)
    // instead of being made less protected.
    Future<void> save(String t) =>
        FileProtection.whenUnlocked(() => _writeNow(file, t));
    final next = previous.catchError((_) {}).then(
      (_) => text is Future<String> ? text.then(save) : save(text as String),
    );
    _pending[file.path] = next;
    return next.whenComplete(() {
      if (identical(_pending[file.path], next)) _pending.remove(file.path);
      _changed(collection, id);
    });
  }

  /// Removes the temporary files of writes that never finished (the app
  /// was closed or crashed in the middle of a save). Such a write never
  /// replaced its real file, so nothing is lost by removing it. Only files
  /// no write of this session is using are touched; returns how many went.
  Future<int> removeInterruptedWrites() async {
    if (!await root.exists()) return 0;
    var removed = 0;
    // Record folders only: attachments and backups have their own clean-up
    // and can be large.
    final places = <FileSystemEntity>[];
    await for (final e in root.list(followLinks: false)) {
      final name = e.uri.pathSegments.where((p) => p.isNotEmpty).last;
      if (e is Directory && (name == 'attachments' || name == 'backups')) {
        continue;
      }
      places.add(e);
    }
    final files = [
      for (final p in places)
        if (p is File) p,
      for (final p in places)
        if (p is Directory)
          ...await p
              .list(recursive: true, followLinks: false)
              .where((e) => e is File)
              .toList(),
    ];
    for (final e in files) {
      final path = e.path;
      if (!path.endsWith('.json.tmp') && !path.endsWith('.json.bak.tmp')) {
        continue;
      }
      final target = path.endsWith('.bak.tmp')
          ? path.substring(0, path.length - '.bak.tmp'.length)
          : path.substring(0, path.length - '.tmp'.length);
      if (_pending.containsKey(target)) continue;
      try {
        await e.delete();
        removed++;
      } on FileSystemException {
        // Locked by something else: tried again at the next start.
      }
    }
    if (removed > 0) {
      AppLog.info('Removed $removed unfinished save file(s) left by a crash');
    }
    return removed;
  }

  /// Waits until every write started so far is on disk (used before the
  /// app closes, so e.g. a settings change made a moment earlier is kept).
  /// Gives up after [limit] so closing never hangs on a stuck file; every
  /// write is atomic, so an unfinished one leaves the old version intact.
  Future<void> flush({Duration limit = const Duration(seconds: 3)}) async {
    final deadline = DateTime.now().add(limit);
    while (_pending.isNotEmpty) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        AppLog.warn('${_pending.length} save(s) still running when closing');
        return;
      }
      try {
        await Future.wait(_pending.values.map((f) => f.catchError((_) {})))
            .timeout(left);
      } on TimeoutException {
        AppLog.warn('${_pending.length} save(s) still running when closing');
        return;
      }
    }
  }

  Future<void> _writeNow(File file, String text) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    await StorageEncryption.writeText(tmp, text, cipher);
    // Only a readable previous version may become the backup: a file
    // damaged on disk is moved aside (kept), never copied over a good .bak.
    var backupIsGood = false;
    if (await file.exists()) {
      if (await _readable(file)) {
        await _retry(() => _copy(file, bak));
        backupIsGood = true;
      } else {
        await _quarantine(file);
      }
    }
    await _retry(() => tmp.rename(file.path));
    // First save (or the previous version was damaged): copy what was just
    // written, so a file is never without a readable backup.
    if (!backupIsGood && await _tryRead(bak) == null) {
      if (await bak.exists()) await _quarantine(bak);
      await _retry(() => _copy(file, bak));
    }
    await FileProtection.protect([file.path, bak.path]);
  }

  /// Documents at least this long (characters) are checked on a background
  /// isolate.
  static const _bigText = 256 * 1024;

  /// Whether [file] holds a readable document, as [_tryRead] decides, in
  /// the same steps. A large document (a big drawing) is decoded on a
  /// background isolate, so the check before each save does not pause the
  /// app; only the yes/no answer comes back.
  Future<bool> _readable(File file) async {
    try {
      if (!await file.exists()) return false;
      final text = await _retry(() => StorageEncryption.readText(file, cipher));
      if (text.length < _bigText) {
        return jsonDecode(text) is Map<String, dynamic>;
      }
      return await _decodesToMapOnIsolate(text);
    } on FormatException {
      return false;
    } on DecryptionFailure {
      return false;
    }
  }

  /// Static, so the isolate is sent only [text] (a closure made inside a
  /// method would also carry this store and its pending saves).
  static Future<bool> _decodesToMapOnIsolate(String text) => Isolate.run(() {
    try {
      return jsonDecode(text) is Map<String, dynamic>;
    } on FormatException {
      return false;
    }
  });

  /// Makes the previous-version copy (`.bak`) equal to the file as it is now,
  /// and removes damaged-file leftovers of this document. After something was
  /// deleted for good this stops the old content living on in `.bak`.
  Future<void> refreshBackup(String collection, String id) async {
    final file = _file(collection, id);
    if (await _tryRead(file) == null) return;
    final bak = File('${file.path}.bak');
    final tmp = File('${file.path}.bak.tmp');
    await _copy(file, tmp);
    await _retry(() => tmp.rename(bak.path));
    final name = file.uri.pathSegments.last;
    await for (final e in file.parent.list()) {
      if (e is File && e.uri.pathSegments.last.startsWith('$name.corrupt-')) {
        await e.delete();
      }
    }
  }

  /// Copies [from] to [to]; a copy of an older plain file is made encrypted
  /// (when encryption is on), so no plain-text copy is ever created here.
  Future<void> _copy(File from, File to) async {
    final c = cipher;
    if (c == null) {
      await from.copy(to.path);
      return;
    }
    final bytes = await from.readAsBytes();
    await to.writeAsBytes(
      FileCipher.isEncrypted(bytes) ? bytes : c.encrypt(bytes),
      flush: true,
    );
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
    // A save of this document in progress finishes first (its rename would
    // otherwise briefly lock the file on Windows). Not while the device is
    // locked: such a save waits for the unlock, and the read must not.
    if (FileProtection.available) {
      await _pending[file.path]?.catchError((_) {});
    }
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
        await _retry(() => _copy(bak, file));
        _changed(collection, id);
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

  /// The document in [file], or null if it is missing or its content is
  /// damaged. A file that cannot be OPENED (locked for a moment by another
  /// program or by a save in progress, a vanished drive) is not damaged: the
  /// read is retried briefly and then fails with [FileSystemException], so
  /// such a file is never moved aside as "corrupt" or replaced by an older
  /// copy.
  Future<Map<String, dynamic>?> _tryRead(File file) async {
    try {
      if (!await file.exists()) return null;
      final text = await _retry(() => StorageEncryption.readText(file, cipher));
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    } on DecryptionFailure {
      // Changed or damaged ciphertext is handled like a damaged file: kept
      // aside, the previous version (.bak) is used. (A missing key is a
      // StorageLockedException and is NOT caught: nothing may be touched.)
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
  /// The newest copy of [id] in the collection's trash folder, or null.
  /// The trash file stays where it is (reading never removes anything).
  Future<Map<String, dynamic>?> readFromTrash(
    String collection,
    String id,
  ) async {
    final trash = Directory(
      '${_dir(collection).path}${Platform.pathSeparator}.trash',
    );
    if (!await trash.exists()) return null;
    final pattern = RegExp('^${RegExp.escape(id)}-(\\d+)\\.json\$');
    File? newest;
    var newestStamp = -1;
    await for (final f in trash.list()) {
      if (f is! File) continue;
      final m = pattern.firstMatch(f.uri.pathSegments.last);
      final stamp = m == null ? -1 : int.parse(m.group(1)!);
      if (stamp > newestStamp) (newest, newestStamp) = (f, stamp);
    }
    if (newest == null) return null;
    try {
      final decoded = jsonDecode(
        await StorageEncryption.readText(newest, cipher),
      );
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    } on DecryptionFailure {
      return null;
    }
  }

  /// Deletes a document and its previous-version copy. Only for the
  /// store's own bookkeeping (e.g. finished transaction intents); user
  /// content is never removed with this: it goes to the trash instead.
  Future<void> delete(String collection, String id) async {
    await _pending[_file(collection, id).path]?.catchError((_) {});
    final file = _file(collection, id);
    try {
      for (final f in [
        file,
        File('${file.path}.bak'),
        File('${file.path}.tmp'),
      ]) {
        if (await f.exists()) await _retry(f.delete);
      }
    } finally {
      _changed(collection, id);
    }
  }

  Future<void> moveToTrash(String collection, String id) async {
    final file = _file(collection, id);
    if (!await file.exists()) return;
    final trash = Directory(
      '${_dir(collection).path}${Platform.pathSeparator}.trash',
    );
    await trash.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    try {
      await file.rename(
        '${trash.path}${Platform.pathSeparator}$id-$stamp.json',
      );
      final bak = File('${file.path}.bak');
      if (await bak.exists()) await bak.delete();
    } finally {
      _changed(collection, id);
    }
  }
}
