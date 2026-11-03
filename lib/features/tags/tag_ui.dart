// Custom tags on screen: the chip, the readable text colour for any tag
// colour, and the one picker used by the Archive and the Mindmap (choose
// tags, make a new one with a colour, rename, recolour, delete). Temporary
// selection highlighting stays separate: it never changes a tag's colour.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/tag_models.dart';
import '../../widgets/common.dart';

/// Text on a tag colour: dark on light colours, light on dark ones.
Color tagForeground(Color background) => background.computeLuminance() > 0.45
    ? const Color(0xFF1B1F27)
    : const Color(0xFFFFFFFF);

class TagChip extends StatelessWidget {
  const TagChip(this.tag, {super.key, this.onDeleted, this.small = false});

  final CustomTag tag;
  final VoidCallback? onDeleted;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final bg = Color(tag.color);
    final fg = tagForeground(bg);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tag.name,
            style: TextStyle(fontSize: small ? 11 : 12, color: fg),
          ),
          if (onDeleted != null) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: onDeleted,
              child: Icon(Icons.close, size: 12, color: fg),
            ),
          ],
        ],
      ),
    );
  }
}

/// Colours offered for tags: the app's ink colours (the existing picker).
final tagPalette = InkColors.all;

/// Chooses custom tags for [what] (e.g. "2 items"). Starts with
/// [selected] ticked; returns the chosen ids, or null when cancelled
/// (then nothing changes). New tags made here are kept even if the
/// dialog is cancelled; a tag with an existing name is reused.
Future<Set<String>?> showTagPicker(
  BuildContext context,
  AppState s, {
  required Set<String> selected,
  required String what,
}) => showDialog<Set<String>>(
  context: context,
  builder: (_) => _TagPicker(state: s, selected: selected, what: what),
);

class _TagPicker extends StatefulWidget {
  const _TagPicker({
    required this.state,
    required this.selected,
    required this.what,
  });

  final AppState state;
  final Set<String> selected;
  final String what;

  @override
  State<_TagPicker> createState() => _TagPickerState();
}

class _TagPickerState extends State<_TagPicker> {
  late final Set<String> _chosen = {...widget.selected};
  final _name = TextEditingController();
  int _color = tagPalette.first.toARGB32();
  String? _problem;

  AppState get s => widget.state;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create() {
    final problem = CustomTag.problemWith(_name.text);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    final ({CustomTag tag, bool existed}) r;
    try {
      r = s.workspace.createTag(_name.text, _color);
    } on ArgumentError catch (e) {
      setState(() => _problem = '${e.message}');
      return;
    }
    setState(() {
      _chosen.add(r.tag.id);
      _problem = r.existed
          ? '“${r.tag.name}” already exists, so it was used.'
          : null;
      _name.clear();
    });
  }

  Future<void> _manage(CustomTag tag, Offset at) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(value: 'color', child: Text('Change colour')),
        PopupMenuItem(value: 'delete', child: Text('Delete tag')),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'rename':
        final name = await promptText(
          context,
          title: 'Rename tag',
          initial: tag.name,
        );
        if (name == null) return;
        final problem = s.workspace.renameTag(tag.id, name);
        setState(() => _problem = problem);
      case 'color':
        final color = await showDialog<int>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Tag colour', style: TextStyle(fontSize: 16)),
            content: _Palette(
              value: tag.color,
              onPick: (c) => Navigator.pop(context, c),
            ),
          ),
        );
        if (color != null) s.workspace.recolorTag(tag.id, color);
        setState(() {});
      case 'delete':
        final ok = await confirm(
          context,
          title: 'Delete the tag “${tag.name}”?',
          message:
              'It is taken off everything that has it. The resources and '
              'items themselves are kept.',
        );
        if (!ok) return;
        s.workspace.deleteTag(tag.id);
        setState(() => _chosen.remove(tag.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tags = s.workspace.tagsByName;
    return AlertDialog(
      title: Text(
        'Tags for ${widget.what}',
        style: const TextStyle(fontSize: 16),
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tags.isEmpty)
                Text(
                  'No tags yet. Make one below.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in tags)
                    GestureDetector(
                      key: ValueKey('tag-${t.id}'),
                      onSecondaryTapUp: (d) => _manage(t, d.globalPosition),
                      onLongPressStart: (d) => _manage(t, d.globalPosition),
                      child: FilterChip(
                        avatar: CircleAvatar(
                          backgroundColor: Color(t.color),
                          radius: 6,
                        ),
                        label: Text(t.name),
                        selected: _chosen.contains(t.id),
                        onSelected: (on) => setState(
                          () => on ? _chosen.add(t.id) : _chosen.remove(t.id),
                        ),
                      ),
                    ),
                ],
              ),
              if (tags.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Right-click or press and hold a tag to rename, recolour '
                    'or delete it.',
                    style: TextStyle(fontSize: 11, color: AppColors.textFaint),
                  ),
                ),
              const Divider(height: 24),
              TextField(
                key: const ValueKey('tag-new-name'),
                controller: _name,
                maxLength: CustomTag.maxNameLength,
                decoration: const InputDecoration(
                  labelText: 'New tag',
                  hintText: 'Type a name',
                ),
                onSubmitted: (_) => _create(),
              ),
              _Palette(
                value: _color,
                onPick: (c) => setState(() => _color = c),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: const ValueKey('tag-create'),
                  onPressed: _create,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Make tag'),
                ),
              ),
              if (_problem != null)
                Text(
                  _problem!,
                  key: const ValueKey('tag-problem'),
                  style: TextStyle(fontSize: 12, color: AppColors.warm),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('tag-apply'),
          onPressed: () => Navigator.pop(context, {
            for (final id in _chosen)
              if (s.workspace.customTags[id] != null) id,
          }),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _Palette extends StatelessWidget {
  const _Palette({required this.value, required this.onPick});

  final int value;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final c in tagPalette)
        GestureDetector(
          onTap: () => onPick(c.toARGB32()),
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(
                color: c.toARGB32() == value
                    ? AppColors.accent
                    : AppColors.border,
                width: c.toARGB32() == value ? 2.5 : 1,
              ),
            ),
          ),
        ),
    ],
  );
}
