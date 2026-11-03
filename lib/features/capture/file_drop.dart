// Files dragged from File Explorer onto THEapp's window. The Windows
// runner reports them on the "theapp/windows" channel ("filesDropped").
// Photos and PDFs land on the open mindmap (when it is shown) or in the
// Archive; Markdown/text files become notes; a dropped folder is imported
// like a folder of notes. The dropped files are only read.
import 'dart:io';

import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../data/models/library_models.dart';
import '../../data/models/object_library_models.dart';
import '../import/note_import.dart';

const windowsChannel = MethodChannel('theapp/windows');

/// Starts listening for dropped files (Windows only; harmless elsewhere).
void listenForDroppedFiles(AppState s) {
  if (!Platform.isWindows) return;
  windowsChannel.setMethodCallHandler((call) async {
    if (call.method != 'filesDropped') return null;
    final paths = [
      for (final p in (call.arguments as List?) ?? const [])
        if (p is String) p,
    ];
    await s.handleDroppedFiles(paths);
    return null;
  });
}

extension FileDrop on AppState {
  static const _images = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};
  static const _notes = {'.md', '.markdown', '.txt'};

  /// Imports dropped [paths]. Returns a short summary (also shown).
  Future<String> handleDroppedFiles(List<String> paths) async {
    final images = <String>[], pdfs = <String>[], texts = <String>[];
    final folders = <Directory>[];
    final skipped = <String>[];
    for (final p in paths) {
      if (await FileSystemEntity.isDirectory(p)) {
        folders.add(Directory(p));
        continue;
      }
      final lower = p.toLowerCase();
      final ext = lower.contains('.')
          ? lower.substring(lower.lastIndexOf('.'))
          : '';
      if (_images.contains(ext)) {
        images.add(p);
      } else if (ext == '.pdf') {
        pdfs.add(p);
      } else if (_notes.contains(ext)) {
        texts.add(p);
      } else {
        skipped.add(p.split(RegExp(r'[\\/]')).last);
      }
    }
    final assets = [
      ...await capture.imagesFromFiles(images),
      ...await capture.documentsFromFiles(pdfs),
    ];
    var onCanvas = 0, inLibrary = 0;
    final c = canvas;
    if (page == AppPage.links) {
      for (final a in assets) {
        final info=a.file==null?null:await workspace.attachments.contentInfo(a.file!);
        if(info!=null){workspace.assets.put(a.copyWith(fileSha256:info.$1,fileSize:info.$2));await workspace.assets.flush();}
        await library.save(type:a.kind==AssetKind.image?LibraryObjectType.image:LibraryObjectType.document,
          title:a.label,attachmentIds:[a.id],metadata:{'legacyAssetId':a.id});
        inLibrary++;
      }
    } else if (page == AppPage.canvas && c != null) {
      var at = canvasDropPoint(c);
      for (final a in assets) {
        if (a.kind == AssetKind.image) {
          c.insertImage(a, at);
        } else {
          c.insertLink(a, at);
        }
        at += const Offset(40, 40);
        onCanvas++;
      }
    } else {
      for (final a in assets) {
        await capture.saveAssetToArchive(a);
        inLibrary++;
      }
    }
    var notes = 0;
    for (final t in texts) {
      try {
        final file = File(t);
        final name = file.uri.pathSegments.last;
        final title = name.contains('.')
            ? name.substring(0, name.lastIndexOf('.'))
            : name;
        final front = splitFrontMatter(
          (await file.readAsString()).replaceAll('\r\n', '\n'),
        );
        final body = front.body.trim();
        final known = workspace.notes.all.any(
          (n) => n.title == title && n.body == body,
        );
        if (known) continue; // dropped before
        final n = workspace.createNote(title: title, body: body);
        final tags = {...front.tags, ...inlineTags(body)}.toList();
        if (tags.isNotEmpty) workspace.notes.put(n.copyWith(tags: tags));
        notes++;
      } on FileSystemException {
        skipped.add(t.split(RegExp(r'[\\/]')).last);
      } on FormatException {
        skipped.add(t.split(RegExp(r'[\\/]')).last);
      }
    }
    for (final dir in folders) {
      final report = await importNotes(
        workspace,
        dir,
        source: ImportSource.markdown,
      );
      notes += report.created;
    }
    final summary = [
      if (onCanvas > 0) '$onCanvas on the mindmap',
      if (inLibrary > 0) '$inLibrary in the library',
      if (notes > 0) '$notes note(s)',
      if (skipped.isNotEmpty)
        'not added: ${skipped.take(3).join(', ')}${skipped.length > 3 ? '…' : ''}',
    ].join(' · ');
    showToast(summary.isEmpty ? 'Nothing to add.' : 'Added: $summary');
    return summary;
  }
}
