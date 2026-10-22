import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../data/models/record.dart';
import '../../platform/input_hints.dart';
import '../../widgets/common.dart';
import 'capture_service.dart';

enum CaptureDestination { canvas, notes, calendar, task, inbox }

/// Opens Quick Add. [initial] pre-fills it (e.g. from the clipboard);
/// [inboxItem] files an Inbox item, reusing its records.
Future<void> showCaptureDialog(
  BuildContext context,
  AppState state, {
  ClipboardContent? initial,
  InboxItem? inboxItem,
  CaptureDestination? destination,
  DateTime? day,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => CaptureDialog(
      state: state,
      initial: initial,
      inboxItem: inboxItem,
      destination: destination,
      day: day,
    ),
  );
}

/// A pending image in the dialog: either new bytes/file or an existing asset.
class _PendingImage {
  _PendingImage.bytes(this.bytes, this.extension) : path = null, asset = null;
  _PendingImage.file(this.path) : bytes = null, extension = null, asset = null;
  _PendingImage.asset(this.asset) : bytes = null, extension = null, path = null;

  final Uint8List? bytes;
  final String? extension;
  final String? path;
  Asset? asset;
}

class CaptureDialog extends StatefulWidget {
  const CaptureDialog({
    super.key,
    required this.state,
    this.initial,
    this.inboxItem,
    this.destination,
    this.day,
  });

  final AppState state;
  final ClipboardContent? initial;
  final InboxItem? inboxItem;
  final CaptureDestination? destination;
  final DateTime? day;

  @override
  State<CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<CaptureDialog> {
  final _text = TextEditingController();
  final _title = TextEditingController();
  final List<_PendingImage> _images = [];
  Asset? _existingLink;
  late CaptureDestination _dest;
  String? _canvasId;
  bool _newNote = true;
  String? _folderId;
  String? _noteId;
  late DateTime _day;
  String? _entryId;
  DateTime? _taskDue;
  String? _projectId;
  bool _saving = false;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _dest = widget.destination ?? CaptureDestination.canvas;
    _canvasId =
        s.canvas?.id ?? (s.canvasList.isEmpty ? null : s.canvasList.first.id);
    _day = widget.day ?? dateOnly(DateTime.now());
    final initial = widget.initial;
    if (initial != null) _apply(initial);
    final inbox = widget.inboxItem;
    if (inbox != null) {
      _text.text = inbox.text ?? '';
      final asset = s.workspace.assets[inbox.assetId];
      if (asset?.kind == AssetKind.image) {
        _images.add(_PendingImage.asset(asset));
      }
      if (asset?.kind == AssetKind.link) {
        _existingLink = asset;
        _text.text = asset!.url!;
      }
    }
    _text.addListener(() => setState(() {}));
  }

  void _apply(ClipboardContent c) {
    if (c.text != null && c.text!.trim().isNotEmpty) {
      _text.text = c.text!.trim();
    }
    if (c.imageBytes != null) {
      _images.add(_PendingImage.bytes(c.imageBytes, c.imageExtension));
    }
    for (final f in c.imageFiles) {
      _images.add(_PendingImage.file(f));
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final content = await s.capture.readClipboard();
    if (!mounted) return;
    if (content.isEmpty) {
      s.showToast('The clipboard is empty.');
      return;
    }
    setState(() => _apply(content));
  }

  Future<void> _pickPhotos() async {
    final assets = await s.capture.pickImages();
    if (!mounted) return;
    setState(() => _images.addAll(assets.map(_PendingImage.asset)));
  }

  String? get _url => extractUrl(_text.text);

  bool get _canSave =>
      !_saving && (_text.text.trim().isNotEmpty || _images.isNotEmpty);

  Future<List<Asset>> _resolveImages() async {
    final result = <Asset>[];
    for (final img in _images) {
      img.asset ??= img.bytes != null
          ? await s.capture.imageFromBytes(img.bytes!, img.extension!)
          : (await s.capture.imagesFromFiles([img.path!])).firstOrNull;
      if (img.asset != null) result.add(img.asset!);
    }
    return result;
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    final ws = s.workspace;
    final images = await _resolveImages();
    final url = _url;
    final title = _title.text.trim();
    final link = url == null
        ? null
        : (_existingLink?.url == url
              ? _existingLink
              : s.capture.link(url, title: title.isEmpty ? null : title));
    final text = url == null ? _text.text.trim() : '';
    final assets = [?link, ...images];
    final now = DateTime.now();
    String done;

    switch (_dest) {
      case CaptureDestination.canvas:
        if (_canvasId == null) {
          setState(() => _saving = false);
          s.showToast('Choose a canvas first.');
          return;
        }
        await s.openCanvas(_canvasId!, show: false);
        final c = s.canvas!;
        final center = s.canvasDropPoint(c);
        var x = center.dx - (assets.length + (text.isEmpty ? 0 : 1) - 1) * 170;
        final added = <CanvasItem>[];
        for (final a in assets) {
          if (a.kind == AssetKind.link) {
            added.add(c.insertLink(a, Offset(x, center.dy)));
          } else {
            added.add(c.insertImage(a, Offset(x, center.dy), maxSide: 320));
          }
          x += 340;
        }
        if (text.isNotEmpty) {
          added.add(
            c.insertText(
              title.isEmpty ? text : '# $title\n$text',
              Offset(x, center.dy),
            ),
          );
        }
        c.select(added.map((i) => i.id));
        s.goTo(AppPage.canvas);
        done = 'Added to canvas “${c.title}”';
      case CaptureDestination.notes:
        if (_newNote || _noteId == null) {
          final noteTitle = title.isNotEmpty
              ? title
              : (link?.label ??
                    (text.split('\n').first.length > 60
                        ? ''
                        : text.split('\n').first));
          final body =
              text.split('\n').first == noteTitle && text.contains('\n')
              ? text.substring(text.indexOf('\n') + 1)
              : (text == noteTitle ? '' : text);
          final note = ws.createNote(
            title: noteTitle,
            body: body,
            folderId: _folderId,
            assetIds: [for (final a in assets) a.id],
          );
          done = 'Saved as note “${note.displayTitle}”';
        } else {
          final note = ws.notes[_noteId]!;
          ws.notes.put(
            note.copyWith(
              body: text.isEmpty
                  ? note.body
                  : '${note.body.trimRight()}\n\n$text'.trimLeft(),
              assetIds: [
                ...note.assetIds,
                for (final a in assets)
                  if (!note.assetIds.contains(a.id)) a.id,
              ],
            ),
          );
          done = 'Added to note “${note.displayTitle}”';
        }
      case CaptureDestination.calendar:
        if (_entryId == null) {
          final day = ws.dayRecord(_day);
          ws.saveDay(
            day.copyWith(
              text: text.isEmpty
                  ? day.text
                  : '${day.text.trimRight()}\n$text'.trim(),
              assetIds: [
                ...day.assetIds,
                for (final a in assets)
                  if (!day.assetIds.contains(a.id)) a.id,
              ],
            ),
          );
        } else {
          final entry = ws.entries[_entryId]!;
          ws.entries.put(
            entry.copyWith(
              notes: text.isEmpty
                  ? entry.notes
                  : '${entry.notes.trimRight()}\n$text'.trim(),
              assetIds: [
                ...entry.assetIds,
                for (final a in assets)
                  if (!entry.assetIds.contains(a.id)) a.id,
              ],
            ),
          );
        }
        done = 'Added to ${formatShortDate(_day)} in Calendar';
      case CaptureDestination.task:
        final lines = text.split('\n');
        final taskTitle = title.isNotEmpty
            ? title
            : (link?.label ??
                  (lines.first.trim().isEmpty
                      ? 'New task'
                      : lines.first.trim()));
        final taskNotes = title.isNotEmpty
            ? text
            : lines.skip(1).join('\n').trim();
        final task = ws.createTask(
          taskTitle,
          projectId: _projectId,
          dueDate: _taskDue,
        );
        ws.tasks.put(
          task.copyWith(
            notes: taskNotes,
            assetIds: [for (final a in assets) a.id],
          ),
        );
        done = 'Added task “$taskTitle”';
      case CaptureDestination.inbox:
        for (final a in assets) {
          ws.inbox.put(InboxItem(id: newId(), assetId: a.id, createdAt: now));
        }
        if (text.isNotEmpty) {
          ws.inbox.put(InboxItem(id: newId(), text: text, createdAt: now));
        }
        done = 'Saved to Inbox';
    }
    final inbox = widget.inboxItem;
    if (inbox != null && _dest != CaptureDestination.inbox) {
      ws.inbox.remove(inbox.id);
    }
    s.showToast(done);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
      },
      child: AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        title: const Row(
          children: [
            Icon(Icons.bolt_outlined, size: 20, color: AppColors.textMuted),
            SizedBox(width: Space.sm),
            Text('Quick Add', style: TextStyle(fontSize: 17)),
          ],
        ),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _text,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 8,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: 'Type a note, or paste a link or image…',
                  ),
                ),
                const SizedBox(height: Space.sm),
                if (url != null) ...[
                  Row(
                    children: [
                      const Icon(
                        Icons.link,
                        size: 16,
                        color: OrganizerColors.blue,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Link: ${displayUrl(url)}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  TextField(
                    controller: _title,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: s.capture.fetchPreviews
                          ? 'Title (optional — fetched from the page if empty)'
                          : 'Title (optional)',
                    ),
                  ),
                  const SizedBox(height: Space.sm),
                ],
                if (_images.isNotEmpty)
                  SizedBox(
                    height: 84,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final img in _images)
                          Padding(
                            padding: const EdgeInsets.only(right: Space.sm),
                            child: Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: SizedBox(
                                    width: 110,
                                    height: 84,
                                    child: _thumb(img),
                                  ),
                                ),
                                Positioned(
                                  right: 2,
                                  top: 2,
                                  child: SmallIconButton(
                                    icon: Icons.close,
                                    tooltip: 'Remove',
                                    onTap: () =>
                                        setState(() => _images.remove(img)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: Space.sm),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _paste,
                      icon: const Icon(Icons.content_paste, size: 16),
                      label: const Text('Paste'),
                    ),
                    const SizedBox(width: Space.sm),
                    OutlinedButton.icon(
                      onPressed: _pickPhotos,
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 16,
                      ),
                      label: const Text('Add photos…'),
                    ),
                  ],
                ),
                const SizedBox(height: Space.xl),
                const Text(
                  'SAVE TO',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textFaint,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: Space.sm),
                SegmentedButton<CaptureDestination>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: CaptureDestination.canvas,
                      label: Text('Canvas'),
                      icon: Icon(Icons.grid_view, size: 16),
                    ),
                    ButtonSegment(
                      value: CaptureDestination.notes,
                      label: Text('Notes'),
                      icon: Icon(Icons.description_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: CaptureDestination.calendar,
                      label: Text('Calendar'),
                      icon: Icon(Icons.calendar_today_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: CaptureDestination.task,
                      label: Text('Task'),
                      icon: Icon(Icons.check_box_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: CaptureDestination.inbox,
                      label: Text('Inbox'),
                      icon: Icon(Icons.inbox_outlined, size: 16),
                    ),
                  ],
                  selected: {_dest},
                  onSelectionChanged: (v) => setState(() => _dest = v.first),
                ),
                const SizedBox(height: Space.md),
                _destinationOptions(),
              ],
            ),
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
          FilledButton(
            onPressed: _canSave ? _save : null,
            child: Text(
              _saving ? 'Saving…' : withShortcut('Save', 'Ctrl+Enter'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(_PendingImage img) {
    if (img.bytes != null) return Image.memory(img.bytes!, fit: BoxFit.cover);
    if (img.path != null) return Image.file(File(img.path!), fit: BoxFit.cover);
    final file = img.asset?.file;
    if (file != null) {
      return Image.file(
        s.workspace.attachments.fileFor(file),
        fit: BoxFit.cover,
      );
    }
    return const ColoredBox(color: AppColors.cardRaised);
  }

  Widget _destinationOptions() {
    final ws = s.workspace;
    switch (_dest) {
      case CaptureDestination.canvas:
        return LabeledField(
          label: 'Canvas',
          child: DropdownButton<String>(
            isExpanded: true,
            value: _canvasId,
            items: [
              for (final c in s.canvasList)
                DropdownMenuItem(value: c.id, child: Text(c.title)),
            ],
            onChanged: (v) => setState(() => _canvasId = v),
          ),
        );
      case CaptureDestination.notes:
        final notes = ws.notes.all.toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ChoiceChip(
                  label: const Text('New note'),
                  selected: _newNote,
                  onSelected: (_) => setState(() => _newNote = true),
                ),
                const SizedBox(width: Space.sm),
                ChoiceChip(
                  label: const Text('Add to existing note'),
                  selected: !_newNote,
                  onSelected: notes.isEmpty
                      ? null
                      : (_) => setState(() => _newNote = false),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            if (_newNote)
              LabeledField(
                label: 'Folder',
                child: FolderDropdown(
                  workspace: ws,
                  value: _folderId,
                  onChanged: (v) => setState(() => _folderId = v),
                ),
              )
            else
              LabeledField(
                label: 'Note',
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _noteId,
                  hint: const Text('Choose a note'),
                  items: [
                    for (final n in notes)
                      DropdownMenuItem(
                        value: n.id,
                        child: Text(n.displayTitle),
                      ),
                  ],
                  onChanged: (v) => setState(() => _noteId = v),
                ),
              ),
          ],
        );
      case CaptureDestination.calendar:
        final active = ws.entries.all.where((e) => !e.archived).toList()
          ..sort((a, b) => a.category.index.compareTo(b.category.index));
        return Column(
          children: [
            LabeledField(
              label: 'Date',
              child: TextButton.icon(
                style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                icon: const Icon(Icons.event, size: 16),
                label: Text(formatLongDate(_day)),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _day,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _day = picked);
                },
              ),
            ),
            LabeledField(
              label: 'Attach to',
              child: DropdownButton<String?>(
                isExpanded: true,
                value: _entryId,
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('The day itself'),
                  ),
                  for (final e in active)
                    DropdownMenuItem(
                      value: e.id,
                      child: Row(
                        children: [
                          ColorDot(index: e.colorIndex),
                          const SizedBox(width: 8),
                          Text('${e.category.label}: ${e.name}'),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _entryId = v),
              ),
            ),
          ],
        );
      case CaptureDestination.task:
        final projects = ws.projects.all.where((p) => !p.archived).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        return Column(
          children: [
            LabeledField(
              label: 'Due',
              child: Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.event, size: 16),
                    label: Text(
                      _taskDue == null ? 'No date' : formatLongDate(_taskDue!),
                    ),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _taskDue ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setState(() => _taskDue = picked);
                    },
                  ),
                  if (_taskDue != null)
                    GhostIconButton(
                      icon: Icons.close,
                      tooltip: 'No date',
                      size: 14,
                      onTap: () => setState(() => _taskDue = null),
                    ),
                ],
              ),
            ),
            LabeledField(
              label: 'Project',
              child: DropdownButton<String?>(
                isExpanded: true,
                value: _projectId,
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  for (final p in projects)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: (v) => setState(() => _projectId = v),
              ),
            ),
          ],
        );
      case CaptureDestination.inbox:
        return const Text(
          'Keep it in the Inbox (on Home) and decide later.',
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        );
    }
  }
}
