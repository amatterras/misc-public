// PDF page anchors: a note (or any text) that points at one page of a PDF in
// the Archive. The anchor is the PDF's record id plus the page number, so it
// survives renaming or moving the PDF, never turns into a link to another
// document, and says so when the PDF's file is missing or was replaced.
// The PDF itself is never copied: notes only point at it.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../app/app_state.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../platform/platform.dart' as native;
import '../smartlinks/smart_links.dart';

/// The page count recorded in a PDF's page tree (null if it cannot be told
/// without a full PDF reader, e.g. compressed object streams).
int? pdfPageCountGuess(Uint8List bytes) {
  final text = String.fromCharCodes(bytes.length > 4 * 1024 * 1024 ? bytes.sublist(0, 4 * 1024 * 1024) : bytes);
  int? best;
  for (final m in RegExp(r'/Type\s*/Pages[^>]*?/Count\s+(\d+)').allMatches(text)) {
    final n = int.parse(m.group(1)!);
    if (best == null || n > best) best = n;
  }
  for (final m in RegExp(r'/Count\s+(\d+)[^>]*?/Type\s*/Pages').allMatches(text)) {
    final n = int.parse(m.group(1)!);
    if (best == null || n > best) best = n;
  }
  return best;
}

/// One anchor to a page of a PDF found in some text.
class PdfAnchorHit {
  const PdfAnchorHit({
    required this.page,
    required this.label,
    required this.source,
    required this.sourceTitle,
    required this.snippet,
  });

  final int page;
  final String label;

  /// The note (or other record) the anchor is in.
  final WorkspaceRef source;
  final String sourceTitle;
  final String snippet;
}

/// Every note anchor to pages of the PDF [assetId], by page.
List<PdfAnchorHit> pdfAnchorsOf(AppState s, String assetId) {
  final out = <PdfAnchorHit>[];
  for (final n in s.workspace.notes.all) {
    for (final t in findLinks(n.body)) {
      if (t.ref.kind != RefKind.pdf || t.ref.id != assetId) continue;
      final at = n.body.substring(0, t.start).split('\n').last.trim();
      out.add(
        PdfAnchorHit(
          page: t.ref.page ?? 1,
          label: t.label,
          source: WorkspaceRef(RefKind.note, n.id),
          sourceTitle: n.displayTitle,
          snippet: at.isEmpty ? t.label : at,
        ),
      );
    }
  }
  out.sort((a, b) {
    final c = a.page.compareTo(b.page);
    return c != 0 ? c : a.sourceTitle.compareTo(b.sourceTitle);
  });
  return out;
}

/// The anchor text for [page] (from 1) of PDF [asset].
String pdfAnchorToken(Asset asset, int page) =>
    WorkspaceRef(RefKind.pdf, asset.id, '$page').token('${asset.label} · p. $page');

/// A note for a page of a PDF. With [noteId] the anchor is added to that
/// note (unless it is already there: asking twice changes nothing), else a
/// new note is made. The PDF is attached to the note as a reference, not
/// copied. Returns the note.
Note createPdfAnchorNote(
  AppState s,
  String assetId,
  int page, {
  String? noteId,
}) {
  final ws = s.workspace;
  final asset = ws.assets[assetId];
  if (asset == null || asset.kind != AssetKind.document) {
    throw ArgumentError('That is not a PDF in the Archive.');
  }
  if (page < 1) throw ArgumentError('Pages start at 1.');
  final token = pdfAnchorToken(asset, page);
  final ref = WorkspaceRef(RefKind.pdf, assetId, '$page');
  if (noteId == null) {
    final note = ws.createNote(title: '${asset.label} · page $page');
    ws.notes.put(note.copyWith(body: '$token\n'));
    ws.attachToNote(note.id, assetId);
    return ws.notes[note.id]!;
  }
  final note = ws.notes[noteId];
  if (note == null) throw ArgumentError('That note is gone.');
  if (findLinks(note.body).any((t) => t.ref == ref)) {
    ws.attachToNote(noteId, assetId);
    return note;
  }
  final sep = note.body.isEmpty || note.body.endsWith('\n') ? '' : '\n';
  ws.notes.put(note.copyWith(body: '${note.body}$sep$token\n'));
  ws.attachToNote(noteId, assetId);
  return ws.notes[noteId]!;
}

/// A note that shows page [page0] (from 0) of PDF [assetId] as one of its
/// handwriting pages, with the notebook page number; null if none does.
Future<({String noteId, int pageIndex})?> notebookShowingPdfPage(
  AppState s,
  String assetId,
  int page0,
) async {
  for (final n in s.workspace.notes.all) {
    if (!n.assetIds.contains(assetId)) continue;
    final doc = await s.canvases.load(notebookIdFor(n.id));
    if (doc == null) continue;
    for (final b in doc.pageBackgrounds) {
      if (b.assetId == assetId && b.pdfPage == page0) {
        return (noteId: n.id, pageIndex: b.pageIndex);
      }
    }
  }
  return null;
}

/// Opens page [ref] of its PDF. Where a note shows that page it is opened
/// there at the right page; otherwise the PDF is opened in this device's
/// viewer (and the page number is shown, for viewers that cannot be told).
/// Nothing in any open note is touched. False if it could not be opened.
Future<bool> openPdfAnchor(AppState s, WorkspaceRef ref) async {
  final ws = s.workspace;
  final asset = ws.assets[ref.id];
  final page = ref.page ?? 1;
  if (asset == null || asset.kind != AssetKind.document) {
    s.showToast('That PDF was deleted. The link is kept in case it comes back.');
    return false;
  }
  final file = ws.documentFile(asset);
  if (file == null || !file.existsSync()) {
    s.showToast('The file of “${asset.label}” is not on this device.');
    return false;
  }
  s.pdfFocus.value = (assetId: asset.id, page: page);
  final inNote = await notebookShowingPdfPage(s, asset.id, page - 1);
  if (inNote != null) {
    s.notebookJump.value = (noteId: inNote.noteId, page: inNote.pageIndex);
    s.openNote(inNote.noteId);
    return true;
  }
  final open = s.pdfOpener ?? _defaultOpener;
  final ok = await open(file, page);
  s.showToast(
    ok
        ? 'Opened “${asset.label}”. Go to page $page.'
        : 'Could not open “${asset.label}” here. The page is $page.',
  );
  return ok;
}

Future<bool> _defaultOpener(File file, int page) async =>
    native.openDocument(file.path);

/// Why a PDF page link may not lead where it did, in words (null: fine).
String? pdfAnchorWarning(AppState s, WorkspaceRef ref) {
  final asset = s.workspace.assets[ref.id];
  final page = ref.page;
  if (asset == null || page == null) return null;
  final file = s.workspace.documentFile(asset);
  if (file == null || !file.existsSync()) return 'The PDF file is missing.';
  if (asset.fileSize != null && file.lengthSync() != asset.fileSize) {
    return 'The PDF file was changed; page $page may be a different page.';
  }
  try {
    final count = pdfPageCountGuess(file.readAsBytesSync());
    if (count != null && page > count) {
      return 'The PDF has only $count pages.';
    }
  } on FileSystemException {
    return 'The PDF file cannot be read.';
  }
  return null;
}
