// Full-text search helpers: the text of PDF documents (read in the
// background, kept in a local cache that is not backed up or synced) and
// a ranked any-order word match with excerpts.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/models/library_models.dart';
import '../../data/storage/storage_encryption.dart';
import '../../data/workspace.dart';
import 'pdf_ocr.dart' show ocrVersion;
import 'pdf_text.dart';

/// PDF text by asset id, read once per file and cached on this device.
/// Scanned PDFs (little or no text) are also read with on-device OCR
/// where available ([ocr]); its pages are kept apart so results can name
/// the page.
class PdfTextCache extends ChangeNotifier {
  PdfTextCache(this.ws, {this.ocr, this.ocrEnabled})
    : dir = Directory('${ws.root.path}${Platform.pathSeparator}search_cache');

  final Workspace ws;
  final Directory dir;

  /// Recognises the pages of the PDF at a path (null: no OCR here).
  final Future<List<String>?> Function(String path)? ocr;

  /// Whether OCR may run (Settings); on by default.
  final bool Function()? ocrEnabled;

  final Map<String, String> _text = {};
  final Map<String, List<String>> _ocrPages = {};
  bool _running = false;

  /// Below this much text a PDF is treated as scanned.
  static const scannedBelowChars = 100;

  /// Documents read so far / documents to read (for a progress line).
  int done = 0, total = 0;
  bool get running => _running;

  /// All searchable text of a document (its own text and OCR text).
  String? operator [](String assetId) {
    final t = _text[assetId];
    final pages = _ocrPages[assetId];
    if (pages == null || pages.isEmpty) return t;
    return [?t, ...pages].join('\n');
  }

  /// The first OCR page containing every term: (page number, its text).
  (int, String)? pageMatch(String assetId, List<String> terms) {
    final pages = _ocrPages[assetId];
    if (pages == null) return null;
    for (final (i, p) in pages.indexed) {
      final lower = p.toLowerCase();
      if (terms.every(lower.contains)) return (i + 1, p);
    }
    return null;
  }

  String _key(Asset a) => a.fileSha256 ?? a.id;

  File _cacheFile(Asset a) =>
      File('${dir.path}${Platform.pathSeparator}${_key(a)}.txt');

  /// OCR results are versioned: a new recognition version reads again.
  File _ocrFile(Asset a) => File(
    '${dir.path}${Platform.pathSeparator}${_key(a)}.ocr$ocrVersion.json',
  );

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
          final file = ws.attachments.fileFor(a.file!);
          final cipher = ws.attachments.cipher;
          if (await cached.exists()) {
            _text[a.id] = await StorageEncryption.readText(cached, cipher);
          } else {
            if (await file.exists() && await file.length() <= maxPdfBytes) {
              final bytes = await ws.attachments.readBytes(a.file!);
              final text = await compute(pdfText, bytes);
              _text[a.id] = text;
              await dir.create(recursive: true);
              // Cached private content is encrypted like everything else.
              await StorageEncryption.writeText(cached, text, cipher);
            } else {
              _text[a.id] = '';
            }
          }
          if ((_text[a.id] ?? '').trim().length < scannedBelowChars) {
            await _readScanned(a, file);
          }
        } catch (_) {
          _text[a.id] ??= ''; // unreadable: skip it, search the rest
        }
        done++;
        notifyListeners();
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _readScanned(Asset a, File file) async {
    final f = _ocrFile(a);
    if (await f.exists()) {
      final raw = jsonDecode(
        await StorageEncryption.readText(f, ws.attachments.cipher),
      );
      if (raw is List) _ocrPages[a.id] = [for (final p in raw) '$p'];
      return;
    }
    final run = ocr;
    if (run == null || !(ocrEnabled?.call() ?? true)) return;
    if (!await file.exists() || await file.length() > maxPdfBytes) return;
    // The recogniser needs a real file: a decrypted view copy.
    final view = ws.attachments.viewFile(a.file!);
    if (view == null) return;
    final pages = await run(view.path);
    if (pages == null) return; // not available: try again another time
    _ocrPages[a.id] = pages;
    await dir.create(recursive: true);
    await StorageEncryption.writeText(
      f,
      jsonEncode(pages),
      ws.attachments.cipher,
    );
  }

  /// Forgets the cache (Settings → clear search cache).
  Future<void> clear() async {
    _text.clear();
    _ocrPages.clear();
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
