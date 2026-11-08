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
import '../export/export_dialog.dart';
import 'branch_conversion.dart';
import 'canvas_controller.dart';
import 'canvas_toolbar.dart' show showDotOpacityDialog;
import 'time_machine.dart';
import 'canvas_export.dart';
import '../interaction/item_actions.dart';
import '../smartlinks/smart_links.dart';
import '../smartlinks/smart_links_ui.dart';

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
    items: hit is ConnectorItem
        ? [
            item('connColor', 'Line color…', Icons.palette_outlined),
            item('connCurved', 'Curved', Icons.gesture),
            item('connStraight2', 'Straight', Icons.show_chart),
            item('connElbow', 'Elbow (right angles)', Icons.stacked_line_chart),
            item(
              'connAuto',
              hit.auto ? 'Manual routing' : 'Route around objects',
              Icons.alt_route,
            ),
            if (hit.bends.isNotEmpty) ...[
              item('connStraight', 'Straighten', Icons.horizontal_rule),
            ],
            const PopupMenuDivider(),
            if (!locked) item('delete', 'Delete line', Icons.delete_outline),
          ]
        : selected.isNotEmpty
        ? [
            if (hit is LinkItem ||
                hit is NoteCardItem ||
                (hit is TextItem && hit.sourceNoteId != null))
              item('open', 'Open', Icons.open_in_new),
            item('duplicate', 'Duplicate', Icons.copy_all_outlined),
            if (hit is TextItem)
              item('linkTo', 'Insert a link…', Icons.add_link),
            if (selected.length == 1)
              item('smartLinks', 'Links & backlinks…', Icons.link),
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
            item(
              'alignGuides',
              c.alignGuides ? 'Alignment guides: on (turn off)' : 'Alignment guides: off (turn on)',
              Icons.straighten,
            ),
            item(
              'gridSnap',
              c.gridSnap ? 'Snap to grid: on (turn off)' : 'Snap to grid: off (turn on)',
              Icons.grid_4x4,
            ),
            item('gridSize', 'Grid size: ${c.gridSize.round()}…', Icons.grid_on),
            item('dots', 'Background dots…', Icons.grain),
          ],
  );
  if (choice == null || !context.mounted) return;
  final items = c.selectedItems;
  switch (choice) {
    case 'connColor':
      final color = await showMenu<Color>(
        context: context,
        position: RelativeRect.fromLTRB(global.dx, global.dy, global.dx, global.dy),
        items: [
          for (final swatch in InkColors.library)
            PopupMenuItem(
              value: swatch.color,
              height: 30,
              child: Row(
                children: [
                  Container(width: 40, height: 14, color: swatch.color),
                  const SizedBox(width: 8),
                  Text(swatch.name, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
        ],
      );
      if (color != null) c.setConnectorColor(color);
    case 'connCurved':
      c.setConnectorStyle(ConnectorStyle.curved);
    case 'connStraight2':
      c.setConnectorStyle(ConnectorStyle.straight);
    case 'connElbow':
      c.setConnectorStyle(ConnectorStyle.orthogonal);
    case 'connAuto':
      c.setConnectorAuto(!(hit! as ConnectorItem).auto);
    case 'connStraight':
      c.straightenSelectedConnectors();
    case 'open':
      s.activateCanvasItem(hit!);
    case 'duplicate':
      c.duplicateSelection();
    case 'linkTo':
      final token = await pickWorkspaceLink(
        context,
        s,
        exclude: WorkspaceRef(RefKind.object, c.id, hit!.id),
      );
      if (token == null) return;
      c.updateSelectedTexts(
        (t) => t.copyWith(text: '${t.text}${t.text.isEmpty ? '' : ' '}$token'),
      );
    case 'smartLinks':
      final owner = WorkspaceRef(RefKind.object, c.id, hit!.id);
      final body = hit is TextItem ? hit.text : '';
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Links & backlinks', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: SmartLinksPanel(
                state: s,
                owner: owner,
                text: body,
                beforeOpen: () async {
                  Navigator.pop(dialog);
                  return true;
                },
                onRemoveLink: (target) {
                  c.updateSelectedTexts(
                    (t) => t.copyWith(text: removeLinkTo(t.text, target)),
                  );
                  Navigator.pop(dialog);
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Close'),
            ),
          ],
        ),
      );
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
      await showExportDialog(context, s, c, web: choice == 'exportWeb');
    case 'release':
      c.releaseReferences();
    case 'alignGuides':
      await s.setAlignment(c, guides: !c.alignGuides);
    case 'gridSnap':
      await s.setAlignment(c, grid: !c.gridSnap);
    case 'gridSize':
      final size = await showMenu<double>(
        context: context,
        position: RelativeRect.fromLTRB(global.dx, global.dy, global.dx, global.dy),
        items: [
          for (final g in CanvasController.gridSizes)
            PopupMenuItem(
              value: g,
              height: 30,
              child: Text('${g.round()}${g == c.gridSize ? '  (now)' : ''}'),
            ),
        ],
      );
      if (size != null) await s.setAlignment(c, size: size);
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
