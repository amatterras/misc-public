// The canvas's right-click menu: actions for what was clicked (or for the
// empty canvas). Separate from the command palette, which lists commands
// and places across the whole app.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/canvas_ops.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../widgets/common.dart';
import '../ai/ai_service.dart';
import '../ai/ai_session.dart';
import '../export/exports.dart';
import 'branch_conversion.dart';
import 'canvas_controller.dart';
import 'canvas_toolbar.dart' show showDotOpacityDialog;
import 'canvas_export.dart';
import '../interaction/item_actions.dart';

Future<void> showCanvasMenu(
  BuildContext context,
  AppState s,
  CanvasController c,
  Offset global,
  Offset world, {
  bool canvasOnly = false, // the canvas actions, whatever is under [world]
}) async {
  final hit = canvasOnly ? null : c.hitTest(world);
  if (hit != null && !c.selection.contains(hit.id)) {
    c.select(c.withGroups({hit.id}));
  }
  final selected = hit == null ? const <CanvasItem>[] : c.selectedItems;
  final locked = selected.isNotEmpty && selected.every((i) => c.isLocked(i.id));
  PopupMenuItem<String> item(String value, String label, IconData icon) =>
      PopupMenuItem(
        value: value,
        height: 34,
        child: Row(
          children: [
            Icon(icon, size: 16, color: AppColors.textMuted),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(fontSize: AppType.sizeBodySmall),
            ),
          ],
        ),
      );
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(global.dx, global.dy, global.dx, global.dy),
    items: selected.isNotEmpty
        ? [
            if (hit is LinkItem ||
                hit is NoteCardItem ||
                (hit is TextItem && hit.sourceNoteId != null))
              item('open', 'Open', Icons.open_in_new),
            item('duplicate', 'Duplicate', Icons.copy_all_outlined),
            item('toNote', 'Copy to a note…', Icons.note_add_outlined),
            item(
              'moveToNote',
              'Move to a note…',
              Icons.drive_file_move_outline,
            ),
            item('toCanvas', 'Copy to another mindmap…', Icons.hub_outlined),
            item(
              'moveCanvas',
              'Move to another mindmap…',
              Icons.drive_file_move_outline,
            ),
            item('shareExternal', 'Share externally', Icons.ios_share_outlined),
            item('component', 'Save as component…', Icons.widgets_outlined),
            if (hit is TextItem) ...[
              item('branchTasks', switch (branchProgress(
                c,
                s.workspace,
                hit.id,
              )) {
                (_, 0) => 'Make tasks from this branch',
                (final d, final t) =>
                  'Update tasks from this branch ($d/$t done)',
              }, Icons.account_tree_outlined),
              item(
                'branchNote',
                'Branch as a note draft',
                Icons.format_list_bulleted,
              ),
            ],
            if (s.ai.enabled)
              item(
                'ai',
                'Ask AI about this (as a picture)',
                Icons.auto_awesome_outlined,
              ),
            const PopupMenuDivider(),
            item('lock', locked ? 'Unlock' : 'Lock', Icons.lock_outline),
            if (selected.length > 1)
              item('group', 'Group', Icons.workspaces_outline),
            if (selected.any((i) => c.groupOf(i.id) != null))
              item('ungroup', 'Ungroup', Icons.workspaces_outline),
            item('front', 'Bring to front', Icons.flip_to_front),
            item('back', 'Send to back', Icons.flip_to_back),
            const PopupMenuDivider(),
            if (!locked) item('delete', 'Delete', Icons.delete_outline),
          ]
        : [
            item('text', 'New text here', Icons.title),
            item('linkCanvas', 'Link to another mindmap…', Icons.link),
            item(
              'insertComponent',
              'Insert a component…',
              Icons.widgets_outlined,
            ),
            const PopupMenuDivider(),
            item('snapshot', 'Save a version…', Icons.bookmark_add_outlined),
            item('versions', 'Versions…', Icons.history),
            item('exportPicture', 'Export as picture', Icons.image_outlined),
            item('exportWeb', 'Export as read-only web page', Icons.public),
            if (c.hasReferences)
              item(
                'release',
                'Release reference overlays',
                Icons.layers_clear_outlined,
              ),
            item('selectAll', 'Select all', Icons.select_all),
            item('dots', 'Background dots…', Icons.grain),
          ],
  );
  if (choice == null || !context.mounted) return;
  final items = c.selectedItems;
  switch (choice) {
    case 'open':
      s.activateCanvasItem(hit!);
    case 'duplicate':
      c.duplicateSelection();
    case 'toNote' || 'moveToNote':
      final noteId = await _pickNote(context, s);
      if (noteId == null) return;
      final n = await s.copyToNote(
        c,
        items,
        noteId,
        move: choice == 'moveToNote',
      );
      s.showToast(
        '${choice == 'moveToNote' ? 'Moved' : 'Copied'} $n item(s) to '
        '“${s.workspace.notes[noteId]?.displayTitle}”.',
      );
    case 'toCanvas':
      final id = await _pickCanvas(context, s, except: c.id);
      if (id == null) return;
      final n = await s.copyToCanvas(c, items, id);
      s.showToast('Copied $n item(s).');
    case 'moveCanvas':
      await moveActionItem(context, s, CanvasActionItems(c, items));
    case 'shareExternal':
      await shareActionItem(context, s, CanvasActionItems(c, items));
    case 'component':
      final name = await promptText(
        context,
        title: 'Name this component',
        action: 'Save',
      );
      if (name == null) return;
      await s.saveComponent(name, items, c.marksOf(items.map((i) => i.id)));
      s.showToast(
        'Saved “$name”. Insert it on any mindmap from the right-click menu.',
      );
    case 'ai':
      final png = s.ai.allowImages
          ? await renderItemsPng(c, items: items.map((i) => i.id))
          : null;
      s.sendToAi(
        AiContext(
          title: 'Selection on “${c.title}”',
          source: AiSource.canvases,
          image: png,
          text: [
            for (final i in items)
              if (i is TextItem) i.text,
          ].join('\n'),
        ),
      );
    case 'branchTasks':
      final r = convertBranch(c, s.workspace, hit!.id);
      s.showToast(
        r.created + r.updated == 0
            ? 'The tasks are already up to date.'
            : 'Tasks: ${r.created} new, ${r.updated} updated'
                  '${r.projectId == null ? '' : ' (project “${s.workspace.projects[r.projectId]?.name}”)'}.',
      );
    case 'branchNote':
      final n = s.workspace.createNote(
        title: (hit as TextItem).text.trim().split('\n').first,
        body: branchAsText(c, hit.id),
      );
      s.openNote(n.id);
    case 'lock':
      c.toggleLockSelection();
    case 'group':
      c.groupSelection();
    case 'ungroup':
      c.ungroupSelection();
    case 'front':
      c.bringToFront();
    case 'back':
      c.sendToBack();
    case 'delete':
      c.deleteSelection();
    case 'text':
      c.createText(world);
    case 'linkCanvas':
      final id = await _pickCanvas(context, s, except: c.id);
      if (id != null) s.linkToCanvas(c, id, world);
    case 'insertComponent':
      final list = await s.components();
      if (!context.mounted) return;
      if (list.isEmpty) {
        s.showToast(
          'No components yet. Select something, right-click it and choose '
          '“Save as component…”.',
        );
        return;
      }
      final picked = await showAppDialog<CanvasComponent>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text(
            'Insert a component',
            style: TextStyle(fontSize: AppType.sizeHeading),
          ),
          children: [
            for (final comp in list)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, comp),
                child: Text('${comp.name}  (${comp.items.length} items)'),
              ),
          ],
        ),
      );
      if (picked != null) s.insertComponent(c, picked, world);
    case 'snapshot':
      final name = await promptText(
        context,
        title: 'Name this version',
        initial: formatShortDate(DateTime.now()),
        action: 'Save',
      );
      if (name == null) return;
      await s.saveSnapshot(c, name);
      s.showToast('Version “$name” saved on this device.');
    case 'versions':
      await showCanvasVersions(context, s, c);
    case 'exportPicture' || 'exportWeb':
      await exportCanvasFromMenu(s, c, web: choice == 'exportWeb');
    case 'release':
      c.releaseReferences();
    case 'selectAll':
      c.selectAll();
    case 'dots':
      await showDotOpacityDialog(
        context,
        c,
        s.setDotOpacity,
        saveSize: s.setDotSize,
      );
  }
}

/// Lists the saved versions of [c]; restoring one is a single undo step.
Future<void> showCanvasVersions(
  BuildContext context,
  AppState s,
  CanvasController c,
) async {
  final list = await s.snapshotsOf(c.id);
  if (!context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text(
        'Versions of this mindmap',
        style: TextStyle(fontSize: AppType.sizeHeading),
      ),
      content: SizedBox(
        width: 420,
        child: list.isEmpty
            ? Text(
                'No versions saved yet. Right-click the empty canvas and '
                'choose “Save a version…”.',
                style: TextStyle(color: AppColors.textFaint),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final v in list)
                    ListTile(
                      title: Text(v.name),
                      subtitle: Text(
                        '${formatShortDate(v.savedAt)} · ${v.itemCount} items',
                        style: const TextStyle(fontSize: AppType.sizeLabel),
                      ),
                      trailing: TextButton(
                        onPressed: () async {
                          final ok = await s.restoreSnapshot(c, v.key);
                          if (context.mounted) Navigator.pop(context);
                          s.showToast(
                            ok ? 'Restored “${v.name}”. Undo takes it back.' : 'That version could not be read; nothing changed.',
                          );
                        },
                        child: const Text('Restore'),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Future<String?> _pickNote(BuildContext context, AppState s) {
  final notes = s.workspace.notes.all.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return showAppDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text(
        'Choose a note',
        style: TextStyle(fontSize: AppType.sizeHeading),
      ),
      children: [
        if (notes.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No notes yet.'),
          ),
        for (final n in notes.take(40))
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, n.id),
            child: Text(n.displayTitle),
          ),
      ],
    ),
  );
}

Future<String?> _pickCanvas(
  BuildContext context,
  AppState s, {
  required String except,
}) {
  final list = [
    for (final c in s.canvasList)
      if (c.id != except) c,
  ];
  return showAppDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text(
        'Choose a mindmap',
        style: TextStyle(fontSize: AppType.sizeHeading),
      ),
      children: [
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('There is no other mindmap yet.'),
          ),
        for (final c in list)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, c.id),
            child: Text(c.title),
          ),
      ],
    ),
  );
}
