// The Layers panel of a mindmap: a compact list (top layer first) to name,
// show or hide, lock, reorder and delete layers, choose where new objects
// go, and move the selected objects between layers. Selecting a layer's
// objects here is the deliberate way to reach hidden or locked ones.
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../widgets/common.dart' show confirm, promptText;
import 'canvas_controller.dart';

class LayersPanel extends StatelessWidget {
  const LayersPanel({super.key, required this.controller, this.onClose});

  final CanvasController controller;
  final VoidCallback? onClose;

  Future<void> _rename(BuildContext context, CanvasLayer l) async {
    final name = await promptText(
      context,
      title: 'Layer name',
      initial: l.name,
      action: 'Rename',
    );
    if (name != null) controller.renameLayer(l.id, name);
  }

  Future<void> _delete(BuildContext context, CanvasLayer l) async {
    final n = controller.countOnLayer(l.id);
    final ok = await confirm(
      context,
      title: 'Delete the layer “${l.name}”?',
      message: n == 0
          ? 'The layer is empty.'
          : 'Its $n object${n == 1 ? '' : 's'} are not deleted: they move to '
                'the base layer, in the same places and with the same '
                'connections.',
    );
    if (ok) controller.deleteLayer(l.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final top = c.layers.reversed.toList();
        final selectedIds = c.selection;
        return Container(
          key: const ValueKey('layers-panel'),
          width: 280,
          constraints: const BoxConstraints(maxHeight: 420),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
            boxShadow: AppElevation.floating,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Layers',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('layer-add'),
                      tooltip: 'New layer',
                      iconSize: 20,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      icon: const Icon(Icons.add),
                      onPressed: () => c.addLayer(),
                    ),
                    if (onClose != null)
                      IconButton(
                        tooltip: 'Close',
                        iconSize: 18,
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                        icon: const Icon(Icons.close),
                        onPressed: onClose,
                      ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 6),
                  children: [
                    for (final l in top) _row(context, l, selectedIds),
                    _baseRow(context, selectedIds),
                  ],
                ),
              ),
              if (selectedIds.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Text(
                    'Move the ${selectedIds.length == 1 ? 'selected object' : '${selectedIds.length} selected objects'}'
                    ' with the ⇥ button of a layer.',
                    style: TextStyle(fontSize: 11, color: AppColors.textFaint),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _iconButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool active = false,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    iconSize: 17,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
    color: active ? AppColors.accent : AppColors.textMuted,
    icon: Icon(icon),
    onPressed: onPressed,
  );

  Widget _row(BuildContext context, CanvasLayer l, Set<String> selected) {
    final c = controller;
    final active = c.activeLayerId == l.id;
    final count = c.countOnLayer(l.id);
    final index = c.layers.indexWhere((x) => x.id == l.id);
    return Container(
      key: ValueKey('layer-${l.id}'),
      color: active ? AppColors.selected : null,
      child: Row(
        children: [
          _iconButton(
            key: ValueKey('layer-eye-${l.id}'),
            icon: l.hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            tooltip: l.hidden ? 'Show this layer' : 'Hide this layer',
            active: !l.hidden,
            onPressed: () => c.setLayerHidden(l.id, !l.hidden),
          ),
          _iconButton(
            key: ValueKey('layer-lock-${l.id}'),
            icon: l.locked ? Icons.lock : Icons.lock_open,
            tooltip: l.locked ? 'Unlock this layer' : 'Lock this layer',
            active: l.locked,
            onPressed: () => c.setLayerLocked(l.id, !l.locked),
          ),
          Expanded(
            child: InkWell(
              key: ValueKey('layer-name-${l.id}'),
              onTap: () => c.setActiveLayer(l.id),
              onDoubleTap: () => _rename(context, l),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${l.name}  ·  $count',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: l.hidden ? AppColors.textFaint : AppColors.text,
                  ),
                ),
              ),
            ),
          ),
          if (selected.isNotEmpty)
            _iconButton(
              key: ValueKey('layer-move-${l.id}'),
              icon: Icons.keyboard_tab,
              tooltip: 'Move the selected objects to this layer',
              onPressed: () => c.moveToLayer(selected, l.id),
            ),
          PopupMenuButton<String>(
            key: ValueKey('layer-menu-${l.id}'),
            iconSize: 18,
            padding: EdgeInsets.zero,
            icon: Icon(Icons.more_vert, color: AppColors.textMuted),
            onSelected: (v) {
              switch (v) {
                case 'rename':
                  _rename(context, l);
                case 'select':
                  c.selectLayer(l.id);
                case 'up':
                  c.moveLayer(l.id, up: true);
                case 'down':
                  c.moveLayer(l.id, up: false);
                case 'delete':
                  _delete(context, l);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              const PopupMenuItem(
                value: 'select',
                child: Text('Select its objects'),
              ),
              PopupMenuItem(
                value: 'up',
                enabled: index < c.layers.length - 1,
                child: const Text('Move up (draws above)'),
              ),
              PopupMenuItem(
                value: 'down',
                enabled: index > 0,
                child: const Text('Move down'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Delete layer…')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _baseRow(BuildContext context, Set<String> selected) {
    final c = controller;
    final active = c.activeLayerId == null;
    return Container(
      key: const ValueKey('layer-base'),
      color: active ? AppColors.selected : null,
      child: Row(
        children: [
          const SizedBox(width: 68),
          Expanded(
            child: InkWell(
              onTap: () => c.setActiveLayer(null),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Base  ·  ${c.countOnLayer(null)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ),
          ),
          if (selected.isNotEmpty)
            _iconButton(
              key: const ValueKey('layer-move-base'),
              icon: Icons.keyboard_tab,
              tooltip: 'Move the selected objects to the base',
              onPressed: () => c.moveToLayer(selected, null),
            ),
          IconButton(
            key: const ValueKey('layer-select-base'),
            tooltip: 'Select the base objects',
            iconSize: 17,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            color: AppColors.textMuted,
            icon: const Icon(Icons.select_all),
            onPressed: () => c.selectLayer(null),
          ),
        ],
      ),
    );
  }
}
