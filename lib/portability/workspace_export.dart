// Portable export of a workspace, and the checks that go with it. This is the
// foundation of workstream "data portability": a format other tools (and
// misc. itself, later) can read, that proves it is complete, and that can be
// previewed against a workspace before anything is changed.
//
// Layout of an export folder:
//   manifest.json            format, version, when, counts, every file with
//                            its size and SHA-256 (written last)
//   records/<collection>.json  every record of a collection, as stored
//   notes/<title>-<id>.md      each note as Markdown
//   attachments/<file>         photos and documents, decrypted copies
//
// An export is NOT a backup. It is plain (unencrypted) on purpose, so it
// can be read outside misc.; it holds no keys, tokens or device secrets, and
// it is made only when asked for. Backups (backup_service.dart) stay the way
// misc. protects and restores itself.
//
// Safety: the export is written to `<folder>.partial` and renamed only when
// the manifest is complete, so an interrupted export leaves no half folder;
// nothing in the workspace is changed.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../data/workspace.dart';
import '../features/export/exports.dart' show noteMarkdown, safeFileName;

class ExportFailure implements Exception {
  const ExportFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ExportSummary {
  const ExportSummary({
    required this.folder,
    required this.records,
    required this.notes,
    required this.attachments,
    required this.missingAttachments,
  });

  final Directory folder;
  final Map<String, int> records;
  final int notes;
  final int attachments;

  /// Attachments the records mention but whose file is not on this device
  /// (not yet synced); they are listed in the manifest, not silently dropped.
  final List<String> missingAttachments;
}

abstract final class WorkspaceExport {
  static const format = 'misc-export';
  static const version = 1;

  static final String _sep = Platform.pathSeparator;

  /// Writes the export of [ws] to [out] (which must not exist yet, or be an
  /// empty folder).
  static Future<ExportSummary> write(
    Workspace ws,
    Directory out, {
    DateTime? now,
  }) async {
    if (await out.exists() && (await out.list().isEmpty) == false) {
      throw const ExportFailure(
        'That folder is not empty; nothing was exported.',
      );
    }
    final partial = Directory('${out.path}.partial');
    if (await partial.exists()) await partial.delete(recursive: true);
    await partial.create(recursive: true);
    final files = <Map<String, Object>>[];
    try {
      Future<void> add(String rel, List<int> bytes) async {
        final f = File('${partial.path}$_sep${rel.replaceAll('/', _sep)}');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes, flush: true);
        files.add({
          'path': rel,
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        });
      }

      // Records, exactly as stored.
      final counts = <String, int>{};
      final collections = ws.syncCollections.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final MapEntry(key: name, value: c) in collections) {
        final ids = [for (final r in c.all) r.id]..sort();
        counts[name] = ids.length;
        if (ids.isEmpty) continue;
        await add(
          'records/$name.json',
          utf8.encode(
            const JsonEncoder.withIndent(' ').convert({
              'collection': name,
              'records': [for (final id in ids) c.jsonOf(id)],
            }),
          ),
        );
      }

      // Notes as Markdown.
      var notes = 0;
      for (final n in ws.notes.all) {
        final name = '${safeFileName(n.displayTitle)}-${_short(n.id)}.md';
        await add('notes/$name', utf8.encode(noteMarkdown(n)));
        notes++;
      }

      // Attachments: streamed copies, hashed while copying.
      final missing = <String>[];
      var attachments = 0;
      final seen = <String>{};
      for (final a in ws.assets.all) {
        for (final name in [a.file, a.previewFile]) {
          if (name == null || !seen.add(name)) continue;
          final source = ws.attachments.viewFile(name);
          if (source == null) {
            missing.add(name);
            continue;
          }
          final rel = 'attachments/$name';
          final target = File('${partial.path}$_sep$rel'.replaceAll('/', _sep));
          await target.parent.create(recursive: true);
          final out = _DigestSink();
          final hasher = sha256.startChunkedConversion(out);
          final sink = target.openWrite();
          var size = 0;
          await for (final chunk in source.openRead()) {
            hasher.add(chunk);
            sink.add(chunk);
            size += chunk.length;
          }
          await sink.flush();
          await sink.close();
          hasher.close();
          files.add({
            'path': rel,
            'size': size,
            'sha256': out.value.toString(),
          });
          attachments++;
        }
      }

      // The manifest is the last thing written: without it the folder is
      // not an export.
      final manifest = {
        'format': format,
        'version': version,
        'app': 'misc.',
        'created': (now ?? DateTime.now()).toUtc().toIso8601String(),
        'counts': {...counts, 'notes': notes, 'attachments': attachments},
        'missingAttachments': missing,
        'files': files,
      };
      await File('${partial.path}${_sep}manifest.json').writeAsString(
        const JsonEncoder.withIndent(' ').convert(manifest),
        flush: true,
      );
      final problems = await verify(partial);
      if (problems.isNotEmpty) {
        throw ExportFailure(
          'The export failed its own check: ${problems.first}',
        );
      }
      if (await out.exists()) await out.delete();
      await partial.rename(out.path);
      return ExportSummary(
        folder: out,
        records: counts,
        notes: notes,
        attachments: attachments,
        missingAttachments: missing,
      );
    } catch (_) {
      if (await partial.exists()) await partial.delete(recursive: true);
      rethrow;
    }
  }

  /// Checks an export folder against its manifest: format, version, and every
  /// file's presence, size and SHA-256. Returns the problems (empty: sound).
  static Future<List<String>> verify(Directory dir) async {
    final problems = <String>[];
    final m = await readManifest(dir);
    if (m == null) return ['There is no readable manifest.json.'];
    if (m['format'] != format) return ['This is not a misc. export.'];
    if ((m['version'] as int? ?? 0) > version) {
      return ['This export was made by a newer version of misc.'];
    }
    for (final f in (m['files'] as List? ?? const [])) {
      final entry = (f as Map).cast<String, dynamic>();
      final rel = entry['path'] as String;
      if (rel.contains('..') || rel.startsWith('/') || rel.contains(':')) {
        problems.add('Unsafe path in the manifest: $rel');
        continue;
      }
      final file = File('${dir.path}$_sep${rel.replaceAll('/', _sep)}');
      if (!await file.exists()) {
        problems.add('Missing: $rel');
        continue;
      }
      if (await file.length() != entry['size']) {
        problems.add('Wrong size: $rel');
        continue;
      }
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (digest != entry['sha256']) problems.add('Damaged: $rel');
    }
    return problems;
  }

  static Future<Map<String, dynamic>?> readManifest(Directory dir) async {
    final f = File('${dir.path}${_sep}manifest.json');
    if (!await f.exists()) return null;
    try {
      final json = jsonDecode(await f.readAsString());
      return json is Map<String, dynamic> ? json : null;
    } on FormatException {
      return null;
    }
  }

  static String _short(String id) => id.length <= 8 ? id : id.substring(0, 8);
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// What importing an export would do, worked out without changing anything.
class ImportPreview {
  const ImportPreview({
    required this.problems,
    required this.collections,
    required this.attachmentsInExport,
    required this.missingAttachments,
  });

  /// Reasons the export cannot be trusted (empty: it is sound).
  final List<String> problems;

  /// Per collection: how many records are new here, identical, or share an
  /// id with a different record here (a collision the person must decide).
  final Map<String, ({int total, int fresh, int same, int different})>
  collections;
  final int attachmentsInExport;
  final List<String> missingAttachments;

  bool get sound => problems.isEmpty;
  int get collisions => collections.values.fold(0, (n, c) => n + c.different);

  static Future<ImportPreview> of(Directory dir, Workspace ws) async {
    final problems = await WorkspaceExport.verify(dir);
    if (problems.isNotEmpty) {
      return ImportPreview(
        problems: problems,
        collections: const {},
        attachmentsInExport: 0,
        missingAttachments: const [],
      );
    }
    final manifest = (await WorkspaceExport.readManifest(dir))!;
    final result =
        <String, ({int total, int fresh, int same, int different})>{};
    for (final f in (manifest['files'] as List)) {
      final path = (f as Map)['path'] as String;
      if (!path.startsWith('records/')) continue;
      final json = jsonDecode(
        await File('${dir.path}$_sepStatic$path'.replaceAll('/', _sepStatic))
            .readAsString(),
      ) as Map<String, dynamic>;
      final name = json['collection'] as String;
      final collection = ws.syncCollections[name];
      var fresh = 0, same = 0, different = 0;
      final records = (json['records'] as List).cast<Map<String, dynamic>>();
      for (final r in records) {
        final id = r['id'] as String?;
        if (id == null) continue;
        final mine = collection?.jsonOf(id);
        if (mine == null) {
          fresh++;
        } else if (_content(mine) == _content(r)) {
          same++;
        } else {
          different++;
        }
      }
      result[name] = (
        total: records.length,
        fresh: fresh,
        same: same,
        different: different,
      );
    }
    return ImportPreview(
      problems: const [],
      collections: result,
      attachmentsInExport:
          (manifest['counts'] as Map)['attachments'] as int? ?? 0,
      missingAttachments: [
        for (final m in (manifest['missingAttachments'] as List? ?? const []))
          '$m',
      ],
    );
  }

  static String get _sepStatic => Platform.pathSeparator;

  static String _content(Map<String, dynamic> j) {
    Object? norm(Object? v) {
      if (v is Map) {
        final keys = v.keys.map((k) => '$k').toList()..sort();
        return {for (final k in keys) k: norm(v[k])};
      }
      if (v is List) return [for (final e in v) norm(e)];
      return v;
    }

    final c = Map<String, dynamic>.of(j)..remove('updatedAt');
    return jsonEncode(norm(c));
  }
}
