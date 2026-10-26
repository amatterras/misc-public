import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../data/models/library_models.dart';
import '../data/models/calendar_models.dart';
import '../data/workspace.dart';
import '../platform/platform.dart' as native;
import 'date_prefs.dart';

export 'date_prefs.dart';

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

/// "Wednesday, October 21" (or as chosen in [DatePrefs]).
String formatLongDate(DateTime d) => switch (DatePrefs.order) {
  DateOrder.monthDay =>
    '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}',
  DateOrder.dayMonth =>
    '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}',
  DateOrder.iso => '${_weekdays[d.weekday - 1]}, ${_iso(d)}',
};

/// "Oct 21" (or as chosen in [DatePrefs]).
String formatShortDate(DateTime d) => switch (DatePrefs.order) {
  DateOrder.monthDay => '${_months[d.month - 1].substring(0, 3)} ${d.day}',
  DateOrder.dayMonth => '${d.day} ${_months[d.month - 1].substring(0, 3)}',
  DateOrder.iso => _iso(d),
};

String _iso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "October 2026"
String formatMonth(DateTime d) => '${_months[d.month - 1]} ${d.year}';

/// "Wed"
String weekdayShort(DateTime d) => _weekdays[d.weekday - 1].substring(0, 3);

Color calendarCategoryColor(CalendarCategory category) => switch (category) {
  CalendarCategory.reading => CalendarCategoryColors.reading,
  CalendarCategory.habits => CalendarCategoryColors.habits,
  CalendarCategory.events => CalendarCategoryColors.reminderEvent,
  CalendarCategory.other => CalendarCategoryColors.other,
};

class ColorDot extends StatelessWidget {
  const ColorDot({super.key, required this.color, this.size = 10});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
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

  /// Below this width the label goes above the field, so narrow panels
  /// (phone width, side panels) keep room for the control itself.
  static const stackBelow = 300.0;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: TextStyle(fontSize: 13, color: AppColors.textMuted),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth < stackBelow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [text, child],
              )
            : Row(
                children: [
                  SizedBox(width: 96, child: text),
                  Expanded(child: child),
                ],
              ),
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
                  Icon(
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
/// Opens a stored PDF in its default app, or says why it can't.
void openDocumentAsset(BuildContext context, Workspace ws, Asset asset) {
  final file = ws.documentFile(asset);
  if (file != null && native.openDocument(file.path)) return;
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(asset.label, style: const TextStyle(fontSize: 16)),
      content: Text(
        file == null
            ? 'This document is not on this device yet. It arrives with the '
                  'next sync.'
            : 'No app on this device could open it.',
        style: TextStyle(color: AppColors.textMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class AssetChip extends StatelessWidget {
  const AssetChip({
    super.key,
    required this.workspace,
    required this.asset,
    this.onRemove,
    this.onOpenPdfEditor,
    this.onPdfNotes,
  });

  /// Opens the PDF with the notes that point at its pages (documents only).
  final VoidCallback? onPdfNotes;

  final Workspace workspace;
  final Asset asset;
  final VoidCallback? onRemove;
  final VoidCallback? onOpenPdfEditor;

  @override
  Widget build(BuildContext context) {
    final isLink = asset.kind == AssetKind.link;
    final isDocument = asset.kind == AssetKind.document;
    final Widget leading;
    if (isLink) {
      leading = Icon(Icons.link, size: 16, color: AppColors.accent);
    } else if (isDocument) {
      leading = Icon(
        Icons.picture_as_pdf_outlined,
        size: 16,
        color: AppColors.danger,
      );
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
        side: BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: isLink && asset.url != null
            ? () => native.openUrl(asset.url!)
            : isDocument
            ? () => openDocumentAsset(context, workspace, asset)
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
                  isLink || isDocument ? asset.label : 'Image',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              if (isDocument && onPdfNotes != null)
                IconButton(
                  key: ValueKey('pdf-notes-${asset.id}'),
                  tooltip: 'Notes on this PDF, page by page',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  onPressed: onPdfNotes,
                  icon: const Icon(Icons.vertical_split_outlined, size: 16),
                ),
              if (isDocument && onOpenPdfEditor != null)
                IconButton(
                  tooltip: 'Open in PDF editor',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  onPressed: onOpenPdfEditor,
                  icon: const Icon(Icons.edit_document, size: 16),
                ),
              if (onRemove != null) ...[
                const SizedBox(width: 4),
                InkWell(
                  onTap: onRemove,
                  child: Icon(
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
      content: Text(message, style: TextStyle(color: AppColors.textMuted)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Cancel', style: TextStyle(color: AppColors.textMuted)),
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
  // The dialog owns its text controller, so it is disposed only after the
  // closing animation (disposing it here crashed while the dialog faded).
  final result = await showDialog<String>(
    context: context,
    builder: (context) => _PromptDialog(
      initial: initial,
      builder: (context, controller) => AlertDialog(
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
            child: Text('Cancel', style: TextStyle(color: AppColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
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

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({required this.initial, required this.builder});

  final String initial;
  final Widget Function(BuildContext, TextEditingController) builder;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}
