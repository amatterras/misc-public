// Exports for use outside THEapp: a mindmap as a picture or a read-only
// web page, a note as Markdown, as pictures of its pages, or as a web
// page. Files go to the "THEapp Exports" folder; the note, mindmap and
// attachments are only read. Read-only web pages are files you can send
// or put online yourself; THEapp does not host them (see MASTER_SPEC).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../app/app_state.dart';
import '../../app/test_environment.dart';
import '../../platform/platform.dart' as native;
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../data/storage/app_log.dart';
import '../../data/storage/json_file_store.dart' show iosDocuments, iosFolder;
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
  if (Platform.isIOS) {
    // iOS sets no HOME: "null/Documents/..." made iOS answer "operation not
    // permitted". Use the Documents folder iOS reported (as the data folder).
    final docs = iosFolder(
      'Documents',
      reported: iosDocuments,
      home: Platform.environment['HOME'],
      systemTemp: Directory.systemTemp.path,
    );
    return Directory('$docs${sep}THEapp Exports');
  }
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    return Directory('${Directory.systemTemp.path}${sep}THEapp Exports');
  }
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

/// An export that could not be made; [message] says why, plainly.
class ExportFailure implements Exception {
  const ExportFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A finished export: the file, and photos that could not be drawn (shown
/// as placeholders: their file is missing or unreadable).
class ExportResult {
  const ExportResult(this.file, {this.missingImages = 0});
  final File file;
  final int missingImages;
}

/// The background of an exported picture.
enum ExportBackground {
  /// As on screen.
  canvas,

  /// No background at all (PNG keeps the transparency).
  transparent,
}

/// Picture sizes offered: the longest side in pixels (a small mindmap is
/// never blown up beyond 2x).
const exportResolutions = <(String, int)>[
  ('Small', 1200),
  ('Standard', 2400),
  ('Large', 4800),
];

/// What a picture export should look like. Remembered between exports.
class ExportOptions {
  const ExportOptions({
    this.background = ExportBackground.canvas,
    this.maxSide = 2400,
  });

  final ExportBackground background;
  final int maxSide;

  Color? get color =>
      background == ExportBackground.transparent ? const Color(0x00000000) : null;

  ExportOptions copyWith({ExportBackground? background, int? maxSide}) =>
      ExportOptions(
        background: background ?? this.background,
        maxSide: maxSide ?? this.maxSide,
      );

  Map<String, Object> toJson() => {
    'background': background.name,
    'maxSide': maxSide,
  };

  /// Safe from anything stored: unknown values give the defaults.
  factory ExportOptions.fromJson(Object? json) {
    if (json is! Map) return const ExportOptions();
    final bg = ExportBackground.values.asNameMap()[json['background']];
    final side = json['maxSide'];
    return ExportOptions(
      background: bg ?? ExportBackground.canvas,
      maxSide: exportResolutions.any((r) => r.$2 == side) ? side as int : 2400,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExportOptions &&
      other.background == background &&
      other.maxSide == maxSide;

  @override
  int get hashCode => Object.hash(background, maxSide);
}

/// Checks that [png] opens as a picture (before anything is saved).
Future<void> checkPicture(Uint8List png) async {
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final ok = frame.image.width > 0 && frame.image.height > 0;
    frame.image.dispose();
    if (!ok) throw const FormatException('empty picture');
  } catch (_) {
    throw const ExportFailure(
      'The picture could not be made (it would not open). Nothing was saved.',
    );
  } finally {
    codec?.dispose();
  }
}

/// Writes [bytes] to [file] through a temporary file that is read back and
/// compared first, so a failed or cut-off write never leaves a broken file
/// under the real name (an existing file is replaced only at the end).
Future<File> saveChecked(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final part = File('${file.path}.part');
  try {
    await part.writeAsBytes(bytes, flush: true);
    final back = await part.readAsBytes();
    if (back.length != bytes.length) {
      throw const ExportFailure('The file was not written completely.');
    }
    for (var i = 0; i < back.length; i++) {
      if (back[i] != bytes[i]) {
        throw const ExportFailure('The file was not written correctly.');
      }
    }
    return await replaceExportFile(part, file);
  } finally {
    if (await part.exists()) await part.delete();
  }
}

Future<ExportResult?> exportCanvasPicture(
  AppState s,
  CanvasController c, {
  Directory? to,
  File? file,
  String? name,
  ExportOptions options = const ExportOptions(),
}) async {
  final picture = await renderItemsPicture(
    c,
    margin: 48,
    maxSide: options.maxSide.toDouble(),
    background: options.color,
  );
  if (picture == null) return null;
  await checkPicture(picture.png);
  final f =
      file ??
      freshFile(to ?? exportsFolder(s), safeFileName(name ?? c.title), 'png');
  return ExportResult(
    await saveChecked(f, picture.png),
    missingImages: picture.missingImages,
  );
}

/// Asks where to save (Windows "Save as"); replaceable in tests. Null:
/// the user cancelled. [hasExportDialog] false: no dialog on this
/// platform (iPhone/iPad), the exports folder is used and shared.
String? Function({
  required String suggestedName,
  required String extension,
  required String typeLabel,
  String? initialDir,
})
askExportPath = native.askSavePath;
bool hasExportDialog =
    native.hasSaveDialog && !Platform.environment.containsKey('FLUTTER_TEST');
Future<File> Function(File source, File destination) replaceExportFile =
    native.replaceFile;

/// Asks where to save until the destination works: after a failed write
/// the dialog opens again so another place can be chosen (cancel stops).
/// [save] gets the chosen file (null: no dialog here, the exports folder).
/// Returns false when cancelled or when no destination worked.
Future<bool> saveWithRetry(
  AppState s, {
  required String name,
  required String ext,
  required String typeLabel,
  required Future<void> Function(File? target) save,
}) async {
  while (true) {
    File? target;
    if (hasExportDialog) {
      final folder = exportsFolder(s);
      try {
        await folder.create(recursive: true);
      } on FileSystemException {
        // The dialog then opens in its own default folder.
      }
      final path = askExportPath(
        suggestedName: '${safeFileName(name)}.$ext',
        extension: ext,
        typeLabel: typeLabel,
        initialDir: folder.path,
      );
      if (path == null) {
        s.showToast('Export cancelled. Nothing was saved.');
        return false;
      }
      target = File(path);
    }
    try {
      await save(target);
      return true;
    } on ExportFailure catch (e) {
      s.showToast(e.message);
      return false;
    } on FileSystemException catch (e, stack) {
      AppLog.error('Export could not be saved', e, stack);
      final why = e.osError?.message.trim() ?? '';
      s.showToast(
        'Could not save the export${target == null ? '' : ' to ${target.path}'}'
        '${why.isEmpty ? '' : ': $why'}. Nothing was changed.'
        '${hasExportDialog ? ' Choose another place.' : ''}',
      );
      if (!hasExportDialog) return false;
    }
  }
}

/// Export from a menu: asks where (if this platform can), saves, checks
/// the file, and reports in plain words. Cancelling saves nothing; a failed
/// write offers the dialog again.
Future<void> exportCanvasFromMenu(
  AppState s,
  CanvasController c, {
  required bool web,
}) async {
  if (c.items.isEmpty) {
    s.showToast('This mindmap is empty.');
    return;
  }
  await saveWithRetry(
    s,
    name: c.title,
    ext: web ? 'html' : 'png',
    typeLabel: web ? 'Web page' : 'PNG picture',
    save: (target) async {
      final r = web
          ? await exportCanvasWebPage(s, c, file: target)
          : await exportCanvasPicture(s, c, file: target);
      if (r == null) {
        s.showToast('This mindmap is empty.');
        return;
      }
      s.showToast(
        'Saved ${r.file.path}'
        '${r.missingImages == 0 ? '' : ' (${r.missingImages} photo(s) could not be read and show as a placeholder)'}',
      );
      if (target == null) await revealExport(s, r.file);
    },
  );
}

String _escape(String s) => const HtmlEscape().convert(s);

/// A self-contained, view-only page: no scripts (a content security policy
/// forbids them even if something slipped through), no forms or editable
/// parts, pictures embedded so nothing is fetched, every text escaped.
/// It is a file to send or put online yourself; it does not expire (share
/// links on the hub do: see share_dialog.dart).
String viewOnlyPage(String title, String body) =>
    '''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex">
<title>${_escape(title)}</title>
<style>
body{margin:0;background:#191A1D;color:#F5F3EF;font:16px/1.6 -apple-system,"SF Pro Text","Segoe UI",system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:32px 20px}
h1{font-weight:700;margin:0 0 4px;overflow-wrap:anywhere}
h2{font-size:15px;color:#AAAEB6;margin:28px 0 8px}
.meta{color:#AAAEB6;font-size:13px;margin-bottom:24px}
.text{white-space:pre-wrap;overflow-wrap:anywhere;background:#222429;border:1px solid #41444A;border-radius:10px;padding:18px}
img{max-width:100%;border:1px solid #41444A;border-radius:10px;margin:12px 0}
a{color:#8AB4F8}
ul{padding-left:20px}
.missing{color:#E8A87C;font-size:13px}
footer{color:#AAAEB6;font-size:12px;margin-top:32px}
.tag{display:inline-block;background:#303239;border-radius:10px;padding:1px 8px;margin-right:6px;font-size:12px}
</style></head><body><main>
$body
<footer>Shared from THEapp · view-only copy made ${_escape(DateTime.now().toIso8601String().substring(0, 10))}</footer>
</main></body></html>
''';

/// Pictures embedded in one page together at most (more are listed only).
const maxEmbeddedBytes = 40 * 1024 * 1024;

Future<ExportResult?> exportCanvasWebPage(
  AppState s,
  CanvasController c, {
  Directory? to,
  File? file,
  String? name,
  ExportOptions options = const ExportOptions(),
}) async {
  final picture = await renderItemsPicture(
    c,
    margin: 48,
    maxSide: options.maxSide.toDouble(),
  );
  if (picture == null) return null;
  await checkPicture(picture.png);
  final f =
      file ??
      freshFile(to ?? exportsFolder(s), safeFileName(name ?? c.title), 'html');
  final missing = picture.missingImages;
  final html = viewOnlyPage(
    c.title,
    '<h1>${_escape(c.title)}</h1><div class="meta">Mindmap</div>'
    '<img alt="${_escape(c.title)}" src="data:image/png;base64,${base64Encode(picture.png)}">'
    '${missing == 0 ? '' : '<p class="missing">$missing photo(s) could not be read and show as a placeholder.</p>'}',
  );
  return ExportResult(
    await saveChecked(f, utf8.encode(html)),
    missingImages: missing,
  );
}

/// The type of a picture file from its first bytes, for a data: address;
/// null when it is not a picture a browser shows.
String? _pictureType(Uint8List b) {
  bool starts(List<int> sig, [int at = 0]) =>
      b.length >= at + sig.length &&
      [for (var i = 0; i < sig.length; i++) b[at + i] == sig[i]]
          .every((x) => x);
  if (starts(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
      starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}

/// A link only when it is a web address (never javascript: and the like).
String _linkHtml(String label, String? url) {
  final uri = Uri.tryParse(url ?? '');
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return _escape(label);
  }
  return '<a href="${const HtmlEscape(HtmlEscapeMode.attribute).convert(uri.toString())}" rel="noopener noreferrer nofollow">'
      '${_escape(label)}</a>';
}

Future<ExportResult> exportNoteWebPage(
  AppState s,
  Note n, {
  Directory? to,
  File? file,
  String? name,
}) async {
  final pictures = await notePagePictures(s, n);
  final ws = s.workspace;
  final photos = <String>[], links = <String>[], others = <String>[];
  var missing = 0, embedded = 0;
  for (final id in n.assetIds) {
    final a = ws.assets[id];
    if (a == null) {
      missing++;
      continue;
    }
    switch (a.kind) {
      case AssetKind.image:
        Uint8List? bytes;
        try {
          bytes = a.file == null
              ? null
              : await ws.attachments.fileFor(a.file!).readAsBytes();
        } on FileSystemException {
          bytes = null;
        }
        final type = bytes == null ? null : _pictureType(bytes);
        if (bytes == null || type == null) {
          missing++;
          others.add(
            '${_escape(a.label)} <span class="missing">(photo not available)</span>',
          );
        } else if (embedded + bytes.length > maxEmbeddedBytes) {
          others.add(
            '${_escape(a.label)} <span class="missing">(photo too large to include)</span>',
          );
        } else {
          embedded += bytes.length;
          photos.add(
            '<img alt="${_escape(a.label)}" src="data:$type;base64,${base64Encode(bytes)}">',
          );
        }
      case AssetKind.link:
        links.add(_linkHtml(a.label, a.url));
      case AssetKind.document:
        others.add(
          '${_escape(a.label)} <span class="missing">(document not included)</span>',
        );
    }
  }
  final f =
      file ??
      freshFile(
        to ?? exportsFolder(s),
        safeFileName(name ?? n.displayTitle),
        'html',
      );
  final html = viewOnlyPage(
    n.displayTitle,
    '<h1>${_escape(n.displayTitle)}</h1>'
    '<div class="meta">${n.tags.map((t) => '<span class="tag">#${_escape(t)}</span>').join()}</div>'
    '${n.body.trim().isEmpty ? '' : '<div class="text">${_escape(n.body)}</div>'}'
    '${pictures.pages.map((p) => '<img alt="Page" src="data:image/png;base64,${base64Encode(p)}">').join()}'
    '${photos.isEmpty ? '' : '<h2>Photos</h2>${photos.join()}'}'
    '${links.isEmpty ? '' : '<h2>Links</h2><ul>${links.map((l) => '<li>$l</li>').join()}</ul>'}'
    '${others.isEmpty ? '' : '<h2>Other attachments</h2><ul>${others.map((o) => '<li>$o</li>').join()}</ul>'}',
  );
  return ExportResult(
    await saveChecked(f, utf8.encode(html)),
    missingImages: missing,
  );
}

String noteMarkdown(Note n) => [
  '# ${n.displayTitle}',
  if (n.tags.isNotEmpty) n.tags.map((t) => '#$t').join(' '),
  '',
  n.body,
].join('\n');

Future<File> exportNoteMarkdown(
  AppState s,
  Note n, {
  Directory? to,
  File? file,
  String? name,
}) => saveChecked(
  file ??
      freshFile(
        to ?? exportsFolder(s),
        safeFileName(name ?? n.displayTitle),
        'md',
      ),
  utf8.encode(noteMarkdown(n)),
);

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

Future<List<File>> exportNotePages(
  AppState s,
  Note n, {
  Directory? to,
  String? name,
}) async {
  final pictures = await notePagePictures(s, n);
  final dir = to ?? exportsFolder(s);
  await dir.create(recursive: true);
  final files = <File>[];
  for (var i = 0; i < pictures.pages.length; i++) {
    final f = freshFile(
      dir,
      '${safeFileName(name ?? n.displayTitle)} page ${i + 1}',
      'png',
    );
    await checkPicture(pictures.pages[i]);
    files.add(await saveChecked(f, pictures.pages[i]));
  }
  return files;
}

/// Export of a note from its menu: [kind] 'md', 'png' (page pictures, to
/// the exports folder) or 'html'. Asks where to save the Markdown or web
/// page where the platform can; cancelling saves nothing.
Future<void> exportNoteFromMenu(AppState s, Note n, String kind) async {
  try {
    if (kind == 'png') {
      final files = await exportNotePages(s, n);
      if (files.isEmpty) {
        s.showToast('No handwriting or text boxes to export.');
        return;
      }
      s.showToast('Saved ${files.length} page picture(s).');
      await revealExport(s, files.first);
      return;
    }
    final ext = kind == 'md' ? 'md' : 'html';
    await saveWithRetry(
      s,
      name: n.displayTitle,
      ext: ext,
      typeLabel: kind == 'md' ? 'Markdown text' : 'Web page',
      save: (target) async {
        final File saved;
        var missing = 0;
        if (kind == 'md') {
          saved = await exportNoteMarkdown(s, n, file: target);
        } else {
          final r = await exportNoteWebPage(s, n, file: target);
          saved = r.file;
          missing = r.missingImages;
        }
        s.showToast(
          'Saved ${saved.path}'
          '${missing == 0 ? '' : ' ($missing attachment(s) could not be included)'}',
        );
        if (target == null) await revealExport(s, saved);
      },
    );
  } on ExportFailure catch (e) {
    s.showToast(e.message);
  } on FileSystemException catch (e, stack) {
    AppLog.error('Export could not be saved', e, stack);
    s.showToast('Could not save the export there. Nothing was changed.');
  }
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
