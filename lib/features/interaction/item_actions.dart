// Shared item-level context actions for Notes, Archive and canvas items.
// Source identity stays in the existing typed record ids (noteId/assetId).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../canvas/canvas_controller.dart';
import '../links/archive_library.dart';

File? _managedFile(AppState s, Asset asset) {
  final name = asset.file;
  if (name == null ||
      name.contains('/') ||
      name.contains(r'\') ||
      name.contains('..')) {
    return null;
  }
  return s.workspace.attachments.viewFile(name);
}

sealed class ActionItem {
  const ActionItem();
  String get title;
}

class ArchiveActionItem extends ActionItem {
  const ArchiveActionItem(this.asset);
  final Asset asset;
  @override
  String get title => asset.label;
}

class NoteActionItem extends ActionItem {
  const NoteActionItem(this.note);
  final Note note;
  @override
  String get title => note.displayTitle;
}

class CanvasActionItems extends ActionItem {
  const CanvasActionItems(this.controller, this.items);
  final CanvasController controller;
  final List<CanvasItem> items;
  @override
  String get title => items.length == 1 ? 'item' : '${items.length} items';
}

/// Adds long-press, right-click and keyboard context actions without delaying
/// taps. Drag gesture ownership remains with the existing TransferSource.
class ItemActionRegion extends StatelessWidget {
  const ItemActionRegion({
    super.key,
    required this.state,
    required this.item,
    required this.child,
  });
  final AppState state;
  final ActionItem item;
  final Widget child;

  Future<void> _show(BuildContext context, Offset position) =>
      showItemActions(context, state, item, position);

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: true,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.contextMenu): () {
          final box = context.findRenderObject() as RenderBox?;
          if (box != null) {
            unawaited(
              _show(context, box.localToGlobal(box.size.center(Offset.zero))),
            );
          }
        },
        const SingleActivator(LogicalKeyboardKey.f10, shift: true): () {
          final box = context.findRenderObject() as RenderBox?;
          if (box != null) {
            unawaited(
              _show(context, box.localToGlobal(box.size.center(Offset.zero))),
            );
          }
        },
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (d) => unawaited(_show(context, d.globalPosition)),
        onSecondaryTapUp: (d) => unawaited(_show(context, d.globalPosition)),
        child: child,
      ),
    ),
  );
}

Future<void> showItemActions(
  BuildContext context,
  AppState s,
  ActionItem item,
  Offset at,
) async {
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    items: [
      const PopupMenuItem(value: 'delete', child: Text('Delete')),
      const PopupMenuItem(value: 'move', child: Text('Move to…')),
      const PopupMenuItem(value: 'share', child: Text('Share externally')),
    ],
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'share':
      await shareActionItem(context, s, item);
    case 'move':
      await moveActionItem(context, s, item);
    case 'delete':
      await _delete(context, s, item);
  }
}

Future<void> shareActionItem(
  BuildContext context,
  AppState s,
  ActionItem item,
) async {
  try {
    String? text;
    if (item case ArchiveActionItem(:final asset)) {
      if (asset.url case final url?) {
        text = url;
      } else {
        final file = s.workspace.documentFile(asset) ?? _managedFile(s, asset);
        if (file != null && Platform.isIOS && s.ios != null) {
          await s.ios!.shareFile(file.path);
          return;
        }
        text = file?.path;
      }
    } else if (item case NoteActionItem(:final note)) {
      text = '${note.displayTitle}\n\n${note.body}';
    } else if (item case CanvasActionItems(:final items)) {
      text = items.whereType<TextItem>().map((e) => e.text).join('\n');
      if (text.isEmpty) {
        final link = items
            .whereType<LinkItem>()
            .map((e) => s.workspace.assets[e.assetId]?.url)
            .whereType<String>()
            .firstOrNull;
        text = link;
      }
      if ((text ?? '').isEmpty) {
        final image = items
            .whereType<ImageItem>()
            .map((i) => s.workspace.assets[i.assetId])
            .whereType<Asset>()
            .firstOrNull;
        if (image != null) text = _managedFile(s, image)?.path;
      }
    }
    if (text == null || text.trim().isEmpty) {
      s.showToast('There is no shareable text or source for this item.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    s.showToast('Copied shareable content to the clipboard.');
  } catch (e) {
    s.showToast('Could not share this item.');
  }
}

Future<void> moveActionItem(
  BuildContext context,
  AppState s,
  ActionItem item,
) async {
  if (item case ArchiveActionItem(:final asset)) {
    final folders = [null, ...s.workspace.archiveFolders.all.map((f) => f.id)];
    final picked = await _pick(context, 'Move to Archive folder', [
      for (final id in folders)
        (id, id == null ? 'Top level' : s.workspace.archiveFolderLabel(id)),
    ]);
    if (picked == null) return;
    final folder = picked.isEmpty ? null : picked;
    if (folder == asset.folderId) return;
    s.workspace.moveAssetToFolder(asset.id, folder);
    s.showTransferResult((
      message: 'Moved “${asset.label}”.',
      undo: () => s.workspace.assets.put(asset),
    ));
  } else if (item case NoteActionItem(:final note)) {
    final folders = [null, ...s.workspace.folders.all.map((f) => f.id)];
    final picked = await _pick(context, 'Move note to folder', [
      for (final id in folders)
        (id, id == null ? 'No folder' : s.workspace.folderLabel(id)),
    ]);
    if (picked == null) return;
    final folder = picked.isEmpty ? null : picked;
    if (folder == note.folderId) return;
    s.workspace.notes.put(note.copyWith(folderId: () => folder));
    s.showTransferResult((
      message: 'Moved “${note.displayTitle}”.',
      undo: () => s.workspace.notes.put(note),
    ));
  } else if (item case CanvasActionItems(:final controller, :final items)) {
    if (items.every((i) => controller.isLocked(i.id))) {
      s.showToast('Unlock the item before moving it.');
      return;
    }
    final targets = s.canvasList.where((c) => c.id != controller.id).toList();
    final picked = await _pick(context, 'Move to mindmap', [
      for (final c in targets) (c.id, c.title),
    ]);
    if (picked == null) return;
    final target = await s.acquireCanvas(picked);
    if (target == null) return;
    try {
      final movable = items.where((i) => !controller.isLocked(i.id)).toList();
      if (movable.isEmpty) return;
      if (movable.any((i) => target.itemById(i.id) != null)) {
        s.showToast('The destination already contains an item with that ID.');
        return;
      }
      final marks = controller.marksOf(movable.map((e) => e.id));
      // Insert with the original IDs first; remove source only after the
      // destination has saved successfully. This is a stable-identity move.
      target.applyTransferredItems(add: movable, marks: marks);
      try {
        await target.flush();
      } catch (_) {
        target.applyTransferredItems(
          removeIds: movable.map((i) => i.id).toSet(),
        );
        await target.flush();
        s.showToast(
          'The destination could not save the move; the source was kept.',
        );
        return;
      }
      if (!movable.every((i) => target.itemById(i.id) != null)) {
        target.select(movable.map((i) => i.id));
        target.deleteSelection();
        await target.flush();
        throw StateError('Destination did not retain all items');
      }
      controller.applyTransferredItems(
        removeIds: movable.map((i) => i.id).toSet(),
      );
      try {
        await controller.flush();
      } catch (_) {
        controller.applyTransferredItems(add: movable, marks: marks);
        await controller.flush();
        target.applyTransferredItems(
          removeIds: movable.map((i) => i.id).toSet(),
        );
        await target.flush();
        s.showToast(
          'The source could not save the move; the item was restored.',
        );
        return;
      }
      s.showTransferResult((
        message: 'Moved ${movable.length} item(s) to the mindmap.',
        undo: () async {
          target.applyTransferredItems(
            removeIds: movable.map((e) => e.id).toSet(),
          );
          await target.flush();
          controller.applyTransferredItems(add: movable, marks: marks);
          await controller.flush();
        },
      ));
    } finally {
      s.releaseCanvas(picked);
    }
  }
}

Future<String?> _pick(
  BuildContext context,
  String title,
  List<(String?, String)> choices,
) async {
  return showDialog<String?>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        for (final (id, label) in choices)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, id ?? ''),
            child: Text(label),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

Future<void> _delete(BuildContext context, AppState s, ActionItem item) async {
  final label = item.title;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete this item?'),
      content: Text(
        '“$label” will be removed from misc. Its original source and any other references will stay untouched.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  switch (item) {
    case ArchiveActionItem(:final asset):
      final references = await referenceMap(s.workspace, s.canvases);
      final usedBy = references[asset.id] ?? const <ResourceRef>{};
      if (usedBy.isNotEmpty) {
        s.showToast(
          'This resource is still used in ${usedBy.length} place(s). Remove those references first.',
        );
        return;
      }
      s.workspace.assets.remove(asset.id);
      s.showTransferResult((
        message: 'Removed from the Archive.',
        undo: () => s.workspace.assets.restoreDeleted(asset.id),
      ));
    case NoteActionItem(:final note):
      await s.deleteNote(note.id);
      s.showTransferResult((
        message: 'Deleted “${note.displayTitle}”.',
        undo: () async {
          final version = s.workspace
              .deletedNotes()
              .where((v) => v.noteId == note.id)
              .firstOrNull;
          if (version != null) await s.restoreDeletedNote(version.id);
        },
      ));
    case CanvasActionItems(:final controller, :final items):
      controller.select(items.map((e) => e.id));
      controller.deleteSelection();
      s.showToast('Deleted ${items.length} item(s). Undo from the mindmap.');
  }
}
