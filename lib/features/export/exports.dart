// Exports for use outside THEapp: a mindmap as a picture or a read-only
// web page, a note as Markdown, as pictures of its pages, or as a web
// page. Files go to the "THEapp Exports" folder; the note, mindmap and
// attachments are only read. Read-only web pages are files you can send
// or put online yourself; THEapp does not host them (see MASTER_SPEC).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import '../../app/app_state.dart';
import '../../app/test_environment.dart';
import '../../platform/platform.dart' as native;
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_export.dart';
import '../notes/notebook_layout.dart';
import '../notes/paper_painter.dart';

/// Where exports are written: Documents\THEapp Exports (Windows), the
/// app's Documents folder (iPhone/iPad, visible in Files), or inside the
/// test data folder in test mode.
Directory exportsFolder(AppState s) {
  final sep = Platform.pathSeparator;
  if (TestEnvironment.active ||
      Platform.environment.containsKey('FLUTTER_TEST')) {
    return Directory('${s.workspace.root.path}${sep}exports');
  }
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  return Directory('$home${sep}Documents${sep}THEapp Exports');
}

String safeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty
      ? 'Untitled'
      : cleaned.length > 80
      ? cleaned.substring(0, 80)
      : cleaned;
}

/// A file in [dir] named [name] that does not exist yet (" (2)" etc.).
File freshFile(Directory dir, String name, String extension) {
  var f = File('${dir.path}${Platform.pathSeparator}$name.$extension');
  for (var i = 2; f.existsSync(); i++) {
    f = File('${dir.path}${Platform.pathSeparator}$name ($i).$extension');
  }
  return f;
}

Future<File?> exportCanvasPicture(
  AppState s,
  CanvasController c, {
  Directory? to,
}) async {
  final png = await renderItemsPng(c, margin: 48);
  if (png == null) return null;
  final dir = to ?? exportsFolder(s);
  await dir.create(recursive: true);
  final f = freshFile(dir, safeFileName(c.title), 'png');
  await f.writeAsBytes(png);
  return f;
}

String _escape(String s) => const HtmlEscape().convert(s);

String _page(String title, String body) =>
    '''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${_escape(title)}</title>
<style>
body{margin:0;background:#191A1D;color:#F5F3EF;font:16px/1.6 -apple-system,"SF Pro Text","Segoe UI",system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:32px 20px}
h1{font-weight:700;margin:0 0 4px}
.meta{color:#AAAEB6;font-size:13px;margin-bottom:24px}
.text{white-space:pre-wrap;background:#222429;border:1px solid #41444A;border-radius:10px;padding:18px}
img{max-width:100%;border:1px solid #41444A;border-radius:10px;margin:12px 0}
footer{color:#AAAEB6;font-size:12px;margin-top:32px}
.tag{display:inline-block;background:#303239;border-radius:10px;padding:1px 8px;margin-right:6px;font-size:12px}
</style></head><body><main>
$body
<footer>Shared from THEapp · read-only copy</footer>
</main></body></html>
''';

Future<File?> exportCanvasWebPage(
  AppState s,
  CanvasController c, {
  Directory? to,
}) async {
  final png = await renderItemsPng(c, margin: 48);
  if (png == null) return null;
  final dir = to ?? exportsFolder(s);
  await dir.create(recursive: true);
  final f = freshFile(dir, safeFileName(c.title), 'html');
  await f.writeAsString(
    _page(
      c.title,
      '<h1>${_escape(c.title)}</h1><div class="meta">Mindmap</div>'
      '<img alt="${_escape(c.title)}" src="data:image/png;base64,${base64Encode(png)}">',
    ),
  );
  return f;
}

String noteMarkdown(Note n) => [
  '# ${n.displayTitle}',
  if (n.tags.isNotEmpty) n.tags.map((t) => '#$t').join(' '),
  '',
  n.body,
].join('\n');

Future<File> exportNoteMarkdown(AppState s, Note n, {Directory? to}) async {
  final dir = to ?? exportsFolder(s);
  await dir.create(recursive: true);
  final f = freshFile(dir, safeFileName(n.displayTitle), 'md');
  await f.writeAsString(noteMarkdown(n));
  return f;
}

/// Pictures of the note's pages that have handwriting or text boxes, with
/// the note's paper. PDF page contents cannot be drawn on Windows, so
/// those pages show only the ink written on them ([pdfPagesMissing]).
Future<({List<Uint8List> pages, int pdfPagesMissing})> notePagePictures(
  AppState s,
  Note n,
) async {
  final doc = await s.canvases.load(notebookIdFor(n.id));
  if (doc == null || doc.items.isEmpty) {
    return (pages: <Uint8List>[], pdfPagesMissing: 0);
  }
  final c = CanvasController(
    document: doc,
    onSave: (_) async {},
    resources: s.resources,
  );
  try {
    final layout = NotebookLayout(
      backgrounds: c.pageBackgrounds,
      content: NotebookLayout.contentOf(c.items, c.itemBounds),
    );
    final pages = <Uint8List>[];
    var missing = 0;
    final paper = n.paperOrDefault;
    for (var i = 0; i < layout.pageCount; i++) {
      final rect = layout.pageRect(i);
      final used = c.items.any(
        (item) => item is! ConnectorItem && c.itemBounds(item).overlaps(rect),
      );
      if (!used) continue;
      final pdf = layout.background(i) != null;
      if (pdf) missing++;
      final png = await renderRectPng(
        c,
        rect,
        maxSide: 1600,
        background: pdf ? const Color(0xFFFFFFFF) : Color(paper.background),
        underlay: pdf
            ? null
            : (canvas, size) => PaperPainter(
                paper,
                scale: size.width / NotebookLayout.pageWidth,
              ).paint(canvas, size),
      );
      if (png != null) pages.add(png);
    }
    return (pages: pages, pdfPagesMissing: missing);
  } finally {
    c.dispose();
  }
}

Future<List<File>> exportNotePages(AppState s, Note n, {Directory? to}) async {
  final pictures = await notePagePictures(s, n);
  final dir = to ?? exportsFolder(s);
  await dir.create(recursive: true);
  final files = <File>[];
  for (var i = 0; i < pictures.pages.length; i++) {
    final f = freshFile(
      dir,
      '${safeFileName(n.displayTitle)} page ${i + 1}',
      'png',
    );
    await f.writeAsBytes(pictures.pages[i]);
    files.add(f);
  }
  return files;
}

Future<File> exportNoteWebPage(AppState s, Note n, {Directory? to}) async {
  final pictures = await notePagePictures(s, n);
  final dir = to ?? exportsFolder(s);
  await dir.create(recursive: true);
  final f = freshFile(dir, safeFileName(n.displayTitle), 'html');
  await f.writeAsString(
    _page(
      n.displayTitle,
      '<h1>${_escape(n.displayTitle)}</h1>'
      '<div class="meta">${n.tags.map((t) => '<span class="tag">#${_escape(t)}</span>').join()}</div>'
      '${n.body.trim().isEmpty ? '' : '<div class="text">${_escape(n.body)}</div>'}'
      '${pictures.pages.map((p) => '<img alt="Page" src="data:image/png;base64,${base64Encode(p)}">').join()}',
    ),
  );
  return f;
}

/// What happens after an export: show the file (Windows: open the
/// folder; iPhone/iPad: the share sheet, to send it to another app).
Future<void> revealExport(AppState s, File file) async {
  if (Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST')) {
    native.openFolder(file.parent.path);
  } else if (s.ios != null) {
    await s.ios!.shareFile(file.path);
  }
}
