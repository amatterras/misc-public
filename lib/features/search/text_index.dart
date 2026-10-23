// Full-text search helpers: the text of PDF documents (read in the
// background, kept in a local cache that is not backed up or synced) and
// a ranked any-order word match with excerpts.
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/models/library_models.dart';
import '../../data/workspace.dart';
import 'pdf_text.dart';

/// PDF text by asset id, read once per file and cached on this device.
class PdfTextCache extends ChangeNotifier {
  PdfTextCache(this.ws)
    : dir = Directory('${ws.root.path}${Platform.pathSeparator}search_cache');

  final Workspace ws;
  final Directory dir;
  final Map<String, String> _text = {};
  bool _running = false;

  /// Documents read so far / documents to read (for a progress line).
  int done = 0, total = 0;
  bool get running => _running;

  String? operator [](String assetId) => _text[assetId];

  File _cacheFile(Asset a) =>
      File('${dir.path}${Platform.pathSeparator}${a.fileSha256 ?? a.id}.txt');

  /// Reads every PDF not read yet, one at a time, off the UI thread.
  Future<void> indexAll() async {
    if (_running) return;
    _running = true;
    try {
      final docs = [
        for (final a in ws.assets.all)
          if (a.kind == AssetKind.document &&
              a.file != null &&
              !_text.containsKey(a.id))
            a,
      ];
      done = 0;
      total = docs.length;
      notifyListeners();
      for (final a in docs) {
        try {
          final cached = _cacheFile(a);
          if (await cached.exists()) {
            _text[a.id] = await cached.readAsString();
          } else {
            final file = ws.attachments.fileFor(a.file!);
            if (await file.exists() && await file.length() <= maxPdfBytes) {
              final path = file.path;
              final text = await compute(_pdfFileText, path);
              _text[a.id] = text;
              await dir.create(recursive: true);
              await cached.writeAsString(text);
            } else {
              _text[a.id] = '';
            }
          }
        } catch (_) {
          _text[a.id] = ''; // unreadable: skip it, search the rest
        }
        done++;
        notifyListeners();
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  /// Forgets the cache (Settings → clear search cache).
  Future<void> clear() async {
    _text.clear();
    if (await dir.exists()) await dir.delete(recursive: true);
    notifyListeners();
  }
}

/// Lowercase words of [query] (at most 8).
List<String> queryTerms(String query) => query
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where((t) => t.isNotEmpty)
    .take(8)
    .toList();

/// True if every term occurs somewhere in [texts].
bool matchesAll(List<String> terms, Iterable<String?> texts) {
  final all = texts.whereType<String>().join('\n').toLowerCase();
  return terms.isNotEmpty && terms.every(all.contains);
}

/// A short piece of [text] around the first match of any term.
String excerpt(String text, List<String> terms, {int width = 140}) {
  final lower = text.toLowerCase();
  var at = -1;
  var len = 0;
  for (final t in terms) {
    final i = lower.indexOf(t);
    if (i >= 0 && (at < 0 || i < at)) {
      at = i;
      len = t.length;
    }
  }
  final flat = text.replaceAll(RegExp(r'\s+'), ' ');
  if (at < 0) {
    return flat.length > width ? '${flat.substring(0, width)}…' : flat;
  }
  // Positions shift a little when whitespace collapses; find it again.
  final again = flat.toLowerCase().indexOf(lower.substring(at, at + len));
  final i = again < 0 ? 0 : again;
  final start = (i - width ~/ 3).clamp(0, flat.length);
  final end = (i + len + width * 2 ~/ 3).clamp(0, flat.length);
  return '${start > 0 ? '…' : ''}${flat.substring(start, end)}'
      '${end < flat.length ? '…' : ''}';
}

String _pdfFileText(String path) => pdfText(File(path).readAsBytesSync());
