import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../data/models/library_models.dart';
import '../data/workspace.dart';
import '../platform/windows_native.dart' as native;

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "Wednesday, October 21"
String formatLongDate(DateTime d) =>
    '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';

/// "Oct 21"
String formatShortDate(DateTime d) =>
    '${_months[d.month - 1].substring(0, 3)} ${d.day}';

/// "Wed"
String weekdayShort(DateTime d) => _weekdays[d.weekday - 1].substring(0, 3);

Color organizerColor(int index) =>
    OrganizerColors.all[index.clamp(0, OrganizerColors.all.length - 1)];

class ColorDot extends StatelessWidget {
  const ColorDot({super.key, required this.index, this.size = 10});

  final int index;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: organizerColor(index),
      shape: BoxShape.circle,
    ),
  );
}

/// The ten organiser colours as selectable dots.
class ColorPicker extends StatelessWidget {
  const ColorPicker({super.key, required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < OrganizerColors.all.length; i++)
          InkWell(
            onTap: () => onChanged(i),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: organizerColor(i),
                shape: BoxShape.circle,
                border: Border.all(
                  color: value == i ? AppColors.text : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class SmallIconButton extends StatelessWidget {
  const SmallIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
    this.size = 16,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0xAA000000),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(icon, size: size, color: color ?? AppColors.text),
          ),
        ),
      ),
    );
  }
}

/// Plain icon button in the app's muted style.
class GhostIconButton extends StatelessWidget {
  const GhostIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.size = 18,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: size,
            color: onTap == null
                ? AppColors.textFaint
                : active
                ? AppColors.text
                : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Picks one of the shared folders (or none).
class FolderDropdown extends StatelessWidget {
  const FolderDropdown({
    super.key,
    required this.workspace,
    required this.value,
    required this.onChanged,
  });

  final Workspace workspace;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final tree = workspace.folderTree();
    return DropdownButton<String?>(
      isExpanded: true,
      value: workspace.folders.contains(value ?? '') ? value : null,
      items: [
        const DropdownMenuItem(value: null, child: Text('No folder')),
        for (final (folder, depth) in tree)
          DropdownMenuItem(
            value: folder.id,
            child: Padding(
              padding: EdgeInsets.only(left: depth * 14.0),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder_outlined,
                    size: 15,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(folder.name, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// A compact link or image attachment. Links open in the browser on click;
/// images show a thumbnail.
class AssetChip extends StatelessWidget {
  const AssetChip({
    super.key,
    required this.workspace,
    required this.asset,
    this.onRemove,
  });

  final Workspace workspace;
  final Asset asset;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final isLink = asset.kind == AssetKind.link;
    final Widget leading;
    if (isLink) {
      leading = const Icon(Icons.link, size: 16, color: OrganizerColors.blue);
    } else {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          workspace.attachments.fileFor(asset.file!),
          width: 40,
          height: 32,
          fit: BoxFit.cover,
          cacheWidth: 120,
          errorBuilder: (_, _, _) =>
              const Icon(Icons.broken_image_outlined, size: 16),
        ),
      );
    }
    return Material(
      color: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: isLink && asset.url != null
            ? () => native.openUrl(asset.url!)
            : () => showImageViewer(context, workspace, asset),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              leading,
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  isLink ? asset.label : 'Image',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              if (onRemove != null) ...[
                const SizedBox(width: 4),
                InkWell(
                  onTap: onRemove,
                  child: const Icon(
                    Icons.close,
                    size: 14,
                    color: AppColors.textFaint,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showImageViewer(BuildContext context, Workspace ws, Asset asset) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      child: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: InteractiveViewer(
          child: Image.file(ws.attachments.fileFor(asset.file!)),
        ),
      ),
    ),
  );
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String action = 'Delete',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: Text(
        message,
        style: const TextStyle(color: AppColors.textMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Asks for a short piece of text; returns null if cancelled or empty.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String action = 'Save',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 340,
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(action),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = result?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// Keeps an open text field in step with its record when the record is
/// changed elsewhere (e.g. Quick Add appending to an open note). Without
/// this the field would later write its old text back over the change.
void syncText(State state, TextEditingController controller, String value) {
  if (controller.text == value) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!state.mounted || controller.text == value) return;
    final offset = controller.selection.baseOffset.clamp(0, value.length);
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: offset),
    );
  });
}
