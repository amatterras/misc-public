// The `.theappbackup` file: one self-contained file holding a complete
// backup folder (records, attachments, and the manifest with every file's
// SHA-256), so a backup can leave the app's own folder: saved to Files or
// iCloud Drive, AirDropped, copied to the PC, and imported again after a
// reinstall.
//
// Layout (all of it inside one gzip stream, written and read as a stream so a
// large attachments folder never has to fit in memory):
//
//   "THEAPPBACKUP\n"            13 bytes, identifies the file
//   uint32  format version      1; a newer version is refused, not guessed at
//   entries, each:
//     uint32 path length (0 = end of file), UTF-8 relative path ('/' separators)
//     uint64 content length, content
//
// The first entry is `manifest.json`. Nothing here is trusted on import: every
// path is checked, the file is unpacked into a hidden staging folder, and it
// only becomes a backup once BackupService.checkManifest agrees with it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// File extension, without the dot.
const backupFileExtension = 'theappbackup';

class BackupFileException implements Exception {
  const BackupFileException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract final class BackupFile {
  static const _magic = 'THEAPPBACKUP\n';
  static const formatVersion = 1;

  /// Folders a backup may contain (plus `manifest.json`). Anything else in a
  /// file is refused.
  static const _allowedTop = {
    'canvases',
    'data',
    'settings',
    'sync',
    'canvas_snapshots',
    'retention',
    'migrations',
    'attachments',
  };

  /// Packs the backup folder [backup] into [out]. Written next to the final
  /// name first and renamed when complete, so an interrupted export never
  /// leaves a half file with a real name.
  static Future<File> pack(Directory backup, File out) async {
    final sep = Platform.pathSeparator;
    final staging = File('${out.path}.partial');
    if (await staging.exists()) await staging.delete();
    final raw = staging.openWrite();
    final sink = gzip.encoder.startChunkedConversion(_Forward(raw));
    try {
      sink.add(utf8.encode(_magic));
      sink.add(_u32(formatVersion));
      Future<void> entry(String rel, File file) async {
        final path = utf8.encode(rel);
        sink.add(_u32(path.length));
        sink.add(path);
        sink.add(_u64(await file.length()));
        await for (final chunk in file.openRead()) {
          sink.add(chunk);
        }
        await raw.flush();
      }

      final manifest = File('${backup.path}${sep}manifest.json');
      if (!await manifest.exists()) {
        throw const BackupFileException('The backup has no manifest.');
      }
      await entry('manifest.json', manifest);
      final entities = await backup.list(recursive: true).toList();
      entities.sort((a, b) => a.path.compareTo(b.path));
      for (final e in entities) {
        if (e is! File) continue;
        final rel = e.path
            .substring(backup.path.length + 1)
            .replaceAll(sep, '/');
        if (rel == 'manifest.json') continue;
        await entry(rel, e);
      }
      sink.add(_u32(0));
      sink.close();
      await raw.flush();
      await raw.close();
    } catch (_) {
      try {
        await raw.close();
      } catch (_) {}
      if (await staging.exists()) await staging.delete();
      rethrow;
    }
    if (await out.exists()) await out.delete();
    return staging.rename(out.path);
  }

  /// Unpacks [file] into the empty folder [into]. Throws
  /// [BackupFileException] for anything that is not a THEapp backup file of a
  /// version this build understands, or whose entries are not safe paths.
  static Future<void> unpack(File file, Directory into) async {
    final sep = Platform.pathSeparator;
    final reader = _Reader(gzip.decoder.bind(file.openRead()));
    try {
      final head = await reader.readExact(_magic.length);
      if (utf8.decode(head, allowMalformed: true) != _magic) {
        throw const BackupFileException('This is not a misc. backup file.');
      }
      final version = _readU32(await reader.readExact(4));
      if (version > formatVersion) {
        throw BackupFileException(
          'This backup was made by a newer misc. (file format $version). '
          'Update misc. to open it.',
        );
      }
      var seenManifest = false;
      while (true) {
        final pathLength = _readU32(await reader.readExact(4));
        if (pathLength == 0) break;
        if (pathLength > 1024) {
          throw const BackupFileException('The backup file is damaged.');
        }
        final rel = utf8.decode(await reader.readExact(pathLength));
        _checkPath(rel);
        if (!seenManifest && rel != 'manifest.json') {
          throw const BackupFileException(
            'The backup file is damaged (no manifest first).',
          );
        }
        seenManifest = true;
        final size = _readU64(await reader.readExact(8));
        final dest = File('${into.path}$sep${rel.replaceAll('/', sep)}');
        await dest.parent.create(recursive: true);
        final out = dest.openWrite();
        try {
          await reader.copyTo(out, size);
        } finally {
          await out.close();
        }
      }
      if (!seenManifest) {
        throw const BackupFileException('The backup file is empty.');
      }
    } on FormatException {
      throw const BackupFileException('The backup file is damaged.');
    } on FileSystemException catch (e) {
      // gzip stops with a FileSystemException-free FormatException; this is
      // a real disk problem (full disk, no access).
      throw BackupFileException('Could not unpack the backup: ${e.message}');
    }
  }

  /// Whether [file] starts like a THEapp backup file (cheap check before
  /// doing any work).
  static Future<bool> looksLikeBackup(File file) async {
    try {
      final reader = _Reader(gzip.decoder.bind(file.openRead()));
      final head = await reader.readExact(_magic.length);
      await reader.close();
      return utf8.decode(head, allowMalformed: true) == _magic;
    } catch (_) {
      return false;
    }
  }

  static void _checkPath(String rel) {
    final parts = rel.split('/');
    final bad =
        rel.isEmpty ||
        rel.startsWith('/') ||
        rel.contains('\\') ||
        rel.contains(':') ||
        rel.contains('\u0000') ||
        parts.any((p) => p.isEmpty || p == '.' || p == '..');
    if (bad) {
      throw const BackupFileException(
        'The backup file contains an unsafe path and was refused.',
      );
    }
    if (rel != 'manifest.json' && !_allowedTop.contains(parts.first)) {
      throw const BackupFileException(
        'The backup file contains something misc. does not store and was '
        'refused.',
      );
    }
  }

  static Uint8List _u32(int v) =>
      (ByteData(4)..setUint32(0, v, Endian.big)).buffer.asUint8List();
  static Uint8List _u64(int v) =>
      (ByteData(8)..setUint64(0, v, Endian.big)).buffer.asUint8List();
  static int _readU32(Uint8List b) =>
      ByteData.sublistView(b).getUint32(0, Endian.big);
  static int _readU64(Uint8List b) =>
      ByteData.sublistView(b).getUint64(0, Endian.big);
}

/// Passes bytes on to [_target] but leaves it open when the encoder closes,
/// so the file can still be flushed and closed in order.
class _Forward implements Sink<List<int>> {
  _Forward(this._target);
  final IOSink _target;
  @override
  void add(List<int> data) => _target.add(data);
  @override
  void close() {}
}

/// Reads exact byte counts from a chunked stream.
class _Reader {
  _Reader(Stream<List<int>> source) : _it = StreamIterator(source);

  final StreamIterator<List<int>> _it;
  List<int> _buf = const [];
  int _pos = 0;

  Future<bool> _fill() async {
    while (_pos >= _buf.length) {
      if (!await _it.moveNext()) return false;
      _buf = _it.current;
      _pos = 0;
    }
    return true;
  }

  Future<Uint8List> readExact(int n) async {
    final out = BytesBuilder(copy: false);
    var need = n;
    while (need > 0) {
      if (!await _fill()) {
        throw const BackupFileException(
          'The backup file ends early (it was not copied completely).',
        );
      }
      final take = need < _buf.length - _pos ? need : _buf.length - _pos;
      out.add(Uint8List.fromList(_buf.sublist(_pos, _pos + take)));
      _pos += take;
      need -= take;
    }
    return out.takeBytes();
  }

  Future<void> copyTo(IOSink sink, int n) async {
    var need = n;
    while (need > 0) {
      if (!await _fill()) {
        throw const BackupFileException(
          'The backup file ends early (it was not copied completely).',
        );
      }
      final take = need < _buf.length - _pos ? need : _buf.length - _pos;
      sink.add(_buf.sublist(_pos, _pos + take));
      _pos += take;
      need -= take;
    }
  }

  Future<void> close() => _it.cancel();
}
