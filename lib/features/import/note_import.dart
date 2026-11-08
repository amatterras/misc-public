// Importing notes from other apps' exports: an Obsidian vault, a Notion
// export (Markdown & CSV, unzipped), Apple Notes exported as HTML or text
// files, or any folder of Markdown/text files. Folders become THEapp
// folders, front-matter and #tags become tags, [[links]] stay links,
// embedded images and PDFs become attachments. Importing the same files
// again skips them instead of making duplicates. The source files are only
// read, never changed. What cannot be imported is listed in the report.
import 'dart:io';

import '../../data/workspace.dart';

enum ImportSource { obsidian, notion, appleNotes, markdown }

extension ImportSourceInfo on ImportSource {
  String get label => switch (this) {
    ImportSource.obsidian => 'Obsidian vault',
    ImportSource.notion => 'Notion export (Markdown & CSV, unzipped)',
    ImportSource.appleNotes => 'Apple Notes export (HTML or text files)',
    ImportSource.markdown => 'Folder of Markdown or text files',
  };
}

class ImportReport {
  int created = 0;
  int skipped = 0;
  int folders = 0;
  int attachments = 0;

  /// Files that were not imported, with the reason.
  final List<String> notImported = [];

  String get summary {
    final parts = [
      '$created note(s) imported',
      if (skipped > 0) '$skipped already there (skipped)',
      if (folders > 0) '$folders folder(s)',
      if (attachments > 0) '$attachments attachment(s)',
      if (notImported.isNotEmpty) '${notImported.length} file(s) not imported',
    ];
    return parts.join(', ');
  }
}

const _noteExtensions = {'.md', '.markdown', '.txt', '.html', '.htm'};
const _imageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

String _extension(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

String _baseName(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/// Notion adds " 0123…" (32 hex characters) to every exported name.
String cleanNotionName(String name) =>
    name.replaceFirst(RegExp(r'\s+[0-9a-f]{32}$'), '').trim();

/// Front matter (`---` … `---`) split off: its tags and the rest.
({List<String> tags, String body}) splitFrontMatter(String text) {
  final m = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n?').firstMatch(text);
  if (m == null) return (tags: const [], body: text);
  final yaml = m.group(1)!;
  final tags = <String>[];
  final inline = RegExp(
    r'^tags:\s*\[(.*)\]\s*$',
    multiLine: true,
  ).firstMatch(yaml);
  if (inline != null) {
    tags.addAll(inline.group(1)!.split(',').map((t) => t.trim()));
  } else {
    final block = RegExp(
      r'^tags:\s*\r?\n((?:\s*-\s*.+\r?\n?)+)',
      multiLine: true,
    ).firstMatch(yaml);
    if (block != null) {
      for (final line in block.group(1)!.split('\n')) {
        final t = line.trim().replaceFirst(RegExp(r'^-\s*'), '');
        if (t.isNotEmpty) tags.add(t);
      }
    } else {
      final single = RegExp(
        r'^tags:\s*(\S.*)$',
        multiLine: true,
      ).firstMatch(yaml);
      if (single != null) {
        tags.addAll(single.group(1)!.split(RegExp(r'[,\s]+')));
      }
    }
  }
  return (
    tags: [
      for (final t in tags)
        if (t.replaceAll(RegExp('[\'"#]'), '').isNotEmpty)
          t.replaceAll(RegExp('[\'"#]'), ''),
    ],
    body: text.substring(m.end),
  );
}

/// `#tags` written in the text (not headings, not inside code).
List<String> inlineTags(String body) {
  final plain = body
      .replaceAll(RegExp(r'```[\s\S]*?```'), '')
      .replaceAll(RegExp(r'`[^`]*`'), '');
  return {
    for (final m in RegExp(
      r'(?:^|\s)#([\p{L}\p{N}_/-]+)',
      unicode: true,
    ).allMatches(plain))
      if (!RegExp(r'^\d+$').hasMatch(m.group(1)!)) m.group(1)!,
  }.toList();
}

/// Notion's Markdown links to other pages (`[Title](Title%20abc….md)`)
/// written as THEapp links (`[[Title]]`).
String notionLinksToWiki(String body) => body.replaceAllMapped(
  RegExp(r'\[([^\]]+)\]\(([^)\s]+\.md)\)'),
  (m) => '[[${m.group(1)}]]',
);

/// Very plain text from an HTML note (Apple Notes exports, Notion HTML).
String htmlToText(String html) {
  var t = html
      .replaceAll(
        RegExp(r'<(script|style)[\s\S]*?</\1>', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'</(p|div|h[1-6]|li|tr)>', caseSensitive: false),
        '\n',
      )
      .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '- ')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  const entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
  };
  entities.forEach((k, v) => t = t.replaceAll(k, v));
  return t.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// Images and documents a note embeds (`![[a.png]]`, `![](b.png)`,
/// `[report](report.pdf)`), as written.
List<String> embeddedFiles(String body) => [
  for (final m in RegExp(r'!\[\[([^\]|]+)(?:\|[^\]]*)?\]\]').allMatches(body))
    m.group(1)!.trim(),
  for (final m in RegExp(
    r'!?\[[^\]]*\]\(([^)\s]+\.(?:png|jpe?g|gif|webp|bmp|pdf))\)',
    caseSensitive: false,
  ).allMatches(body))
    Uri.decodeComponent(m.group(1)!),
];

Future<ImportReport> importNotes(
  Workspace ws,
  Directory root, {
  required ImportSource source,
}) async {
  final report = ImportReport();
  if (!await root.exists()) {
    report.notImported.add('${root.path}: the folder does not exist');
    return report;
  }
  final topName = source == ImportSource.notion
      ? cleanNotionName(_baseName(root.path))
      : _baseName(root.path);
  final folderIds = <String, String>{};

  String folderFor(String relDir) {
    if (folderIds[relDir] case final id?) return id;
    final parts = relDir.isEmpty ? <String>[] : relDir.split('/');
    final parentKey = parts.isEmpty
        ? null
        : parts.take(parts.length - 1).join('/');
    final parentId = parts.isEmpty ? null : folderFor(parentKey!);
    final name = parts.isEmpty
        ? topName
        : (source == ImportSource.notion
              ? cleanNotionName(parts.last)
              : parts.last);
    final existing = ws.folders.all
        .where((f) => f.name == name && f.parentId == parentId)
        .firstOrNull;
    final id = existing?.id ?? ws.createFolder(name, parentId: parentId).id;
    if (existing == null) report.folders++;
    return folderIds[relDir] = id;
  }

  final files = <File>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(root.path.length).replaceAll('\\', '/');
    // Obsidian settings and trash, hidden files.
    if (rel.split('/').any((p) => p.startsWith('.'))) continue;
    files.add(e);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  final byName = {
    for (final f in files) f.path.split(RegExp(r'[\\/]')).last.toLowerCase(): f,
  };

  for (final file in files) {
    final rel = file.path
        .substring(root.path.length)
        .replaceAll('\\', '/')
        .replaceFirst(RegExp('^/'), '');
    final ext = _extension(file.path);
    // Images and PDFs are attached to the notes that embed them.
    if (_imageExtensions.contains(ext) || ext == '.pdf') continue;
    if (!_noteExtensions.contains(ext)) {
      report.notImported.add(
        ext == '.csv'
            ? '$rel: a table (database); tables are not imported yet'
            : '$rel: this kind of file is not supported',
      );
      continue;
    }
    String text;
    try {
      text = await file.readAsString();
    } on FileSystemException {
      report.notImported.add('$rel: could not be read');
      continue;
    } on FormatException {
      report.notImported.add('$rel: not a text file (unknown encoding)');
      continue;
    }
    final isHtml = ext == '.html' || ext == '.htm';
    var body = isHtml ? htmlToText(text) : text.replaceAll('\r\n', '\n');
    final front = splitFrontMatter(body);
    body = front.body.trim();
    if (source == ImportSource.notion) body = notionLinksToWiki(body);
    var title = _baseName(file.path);
    if (source == ImportSource.notion) title = cleanNotionName(title);
    // A Markdown file that starts with its own "# Title".
    final heading = RegExp(r'^#\s+(.+)\n?').firstMatch(body);
    if (heading != null && heading.group(1)!.trim() == title) {
      body = body.substring(heading.end).trimLeft();
    }
    final relDir = rel.contains('/')
        ? rel.substring(0, rel.lastIndexOf('/'))
        : '';
    final folderId = folderFor(relDir);
    final duplicate = ws.notes.all.any(
      (n) => n.folderId == folderId && n.title == title && n.body == body,
    );
    if (duplicate) {
      report.skipped++;
      continue;
    }
    final assetIds = <String>[];
    for (final embed in embeddedFiles(body)) {
      final target = File(
        File('${file.parent.path}${Platform.pathSeparator}$embed').absolute.uri
            .normalizePath()
            .toFilePath(),
      );
      // Only files inside the imported folder (no "../" escapes).
      final inside = target.path.toLowerCase().startsWith(
        root.absolute.uri.normalizePath().toFilePath().toLowerCase(),
      );
      final found = inside && await target.exists()
          ? target
          : byName[embed.split('/').last.toLowerCase()];
      if (found == null) {
        report.notImported.add('$rel: embedded “$embed” was not found');
        continue;
      }
      try {
        final asset = _extension(found.path) == '.pdf'
            ? await ws.documentAssetFromFile(found)
            : await ws.imageAssetFromFile(found);
        assetIds.add(asset.id);
        report.attachments++;
      } catch (_) {
        report.notImported.add('$rel: “$embed” could not be attached');
      }
    }
    final tags = {
      for (final t in [...front.tags, if (!isHtml) ...inlineTags(body)])
        t.replaceAll(' ', '-'),
    }.toList();
    final note = ws.createNote(
      title: title,
      body: body,
      folderId: folderId,
      assetIds: assetIds,
    );
    if (tags.isNotEmpty) ws.notes.put(note.copyWith(tags: tags));
    report.created++;
  }
  return report;
}

