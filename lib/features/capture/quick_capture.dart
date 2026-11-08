// Quick Capture: a small window you can open from anywhere (Ctrl+Shift+Space
// on Windows, the bolt button in the bar on every device) to put a thought,
// a task or a link into the Inbox / Tasks without leaving what you are doing.
// Opening and closing it never touches the page underneath, so unsaved
// edits stay exactly as they were. Saving is safe to repeat: the item has a
// fixed id for as long as the window is open, so a retry after a failure
// (or a double tap) never makes a second copy.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../data/models/task_models.dart';
import '../smartlinks/smart_links.dart';

enum QuickKind { thought, task, link }

/// Something the capture can point back at (written as a workspace link,
/// so it keeps working when the target is renamed or moved).
class QuickContext {
  const QuickContext(this.label, this.token, {this.noteId});
  final String label;
  final String token;

  /// For a note: lets a task also be linked to the note itself.
  final String? noteId;
}

/// What is open right now that a capture could refer to.
List<QuickContext> quickContexts(AppState s) {
  final out = <QuickContext>[];
  final noteId = s.activeNoteId.value;
  final note = noteId == null ? null : s.workspace.notes[noteId];
  if (note != null) {
    out.add(
      QuickContext(
        'Note “${note.displayTitle}”',
        WorkspaceRef(RefKind.note, note.id).token(note.displayTitle),
        noteId: note.id,
      ),
    );
  }
  final canvas = s.canvas;
  if (s.page == AppPage.canvas && canvas != null && canvas.selection.isNotEmpty) {
    final picked = canvas.selectedItems.where((i) => i is! ConnectorItem).take(5);
    final tokens = <String>[];
    for (final i in picked) {
      final label = switch (i) {
        TextItem() => i.text.trim().split('\n').first,
        LinkItem() => 'Link card',
        ImageItem() => 'Photo',
        NoteCardItem() => 'Note card',
        _ => 'Object',
      };
      tokens.add(WorkspaceRef(RefKind.object, canvas.id, i.id).token(label));
    }
    if (tokens.isNotEmpty) {
      out.add(
        QuickContext(
          '${canvas.selection.length == 1 ? '1 selected object' : '${canvas.selection.length} selected objects'}'
          ' on “${canvas.title}”',
          tokens.join(' '),
        ),
      );
    }
  } else if (s.page == AppPage.canvas && canvas != null) {
    out.add(
      QuickContext(
        'Mindmap “${canvas.title}”',
        WorkspaceRef(RefKind.canvas, canvas.id).token(canvas.title),
      ),
    );
  }
  return out;
}

/// The outcome of a capture.
class QuickResult {
  const QuickResult(this.message);
  final String message;
}

/// A capture that could not be completed (the text is kept for a retry).
class QuickCaptureFailure implements Exception {
  const QuickCaptureFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Saves a capture. [id] must stay the same for retries of the same
/// capture. [persist] makes the records safe on disk (default: the
/// workspace flush); if it fails the records stay in memory and the same
/// call can be repeated.
Future<QuickResult> saveQuickCapture(
  AppState s, {
  required String id,
  required String text,
  required QuickKind kind,
  List<QuickContext> contexts = const [],
  Future<void> Function()? persist,
}) async {
  final ws = s.workspace;
  final body = text.trim();
  if (body.isEmpty) throw const QuickCaptureFailure('Type something first.');
  final refs = contexts.map((c) => c.token).join(' ');
  final now = DateTime.now();
  String done;
  switch (kind) {
    case QuickKind.link:
      final url = extractUrl(body);
      if (url == null) {
        throw const QuickCaptureFailure('That does not look like a web address.');
      }
      final asset = s.capture.link(url);
      ws.inbox.put(
        InboxItem(
          id: id,
          assetId: asset.id,
          text: refs.isEmpty ? null : 'From $refs',
          createdAt: ws.inbox[id]?.createdAt ?? now,
        ),
      );
      done = 'Link saved to the Inbox';
    case QuickKind.thought:
      ws.inbox.put(
        InboxItem(
          id: id,
          text: refs.isEmpty ? body : '$body\n\nFrom $refs',
          createdAt: ws.inbox[id]?.createdAt ?? now,
        ),
      );
      done = 'Saved to the Inbox';
    case QuickKind.task:
      final lines = body.split('\n');
      final title = lines.first.trim();
      final rest = lines.skip(1).join('\n').trim();
      final existing = ws.tasks[id];
      ws.tasks.put(
        Task(
          id: id,
          title: title.length > 200 ? title.substring(0, 200) : title,
          notes: [
            if (rest.isNotEmpty) rest,
            if (refs.isNotEmpty) 'From $refs',
          ].join('\n\n'),
          noteIds: [
            for (final c in contexts)
              if (c.noteId != null) c.noteId!,
          ],
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        ),
      );
      done = 'Task added';
  }
  try {
    await (persist ?? ws.flush)();
  } catch (_) {
    throw const QuickCaptureFailure(
      'Could not save to this device. Your text is kept; try again.',
    );
  }
  return QuickResult(done);
}

/// Opens the capture window above whatever is showing.
Future<void> showQuickCapture(
  BuildContext context,
  AppState s, {
  Future<void> Function()? persist,
  QuickKind? kind,
}) => showAppDialog<void>(
  context: context,
  builder: (_) => _QuickCapture(state: s, persist: persist, kind: kind),
);

class _QuickCapture extends StatefulWidget {
  const _QuickCapture({required this.state, this.persist, this.kind});
  final AppState state;
  final Future<void> Function()? persist;
  final QuickKind? kind;

  @override
  State<_QuickCapture> createState() => _QuickCaptureState();
}

class _QuickCaptureState extends State<_QuickCapture> {
  final _text = TextEditingController();
  late final String _id = newId(); // fixed for every retry of this capture
  late final List<QuickContext> _options = quickContexts(widget.state);
  late final Set<int> _attach = {};
  QuickKind? _chosen;
  String? _error;
  bool _busy = false;

  QuickKind get _kind {
    if (_chosen != null) return _chosen!;
    return extractUrl(_text.text.trim()) != null &&
            _text.text.trim().split(RegExp(r'\s+')).length == 1
        ? QuickKind.link
        : QuickKind.thought;
  }

  @override
  void initState() {
    super.initState();
    _chosen = widget.kind;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return; // a double tap is one save
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await saveQuickCapture(
        widget.state,
        id: _id,
        text: _text.text,
        kind: _kind,
        contexts: [for (final i in _attach) _options[i]],
        persist: widget.persist,
      );
      widget.state.showToast(r.message);
      if (mounted) Navigator.pop(context);
    } on QuickCaptureFailure catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
      },
      child: AlertDialog(
        key: const ValueKey('quick-capture'),
        title: const Text('Quick capture', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('quick-capture-text'),
                controller: _text,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                onChanged: (_) => setState(() => _error = null),
                decoration: const InputDecoration(
                  hintText: 'A thought, a task or a link…',
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final (k, label) in const [
                    (QuickKind.thought, 'Thought'),
                    (QuickKind.task, 'Task'),
                    (QuickKind.link, 'Link'),
                  ])
                    ChoiceChip(
                      key: ValueKey('quick-kind-${k.name}'),
                      label: Text(label),
                      selected: _kind == k,
                      onSelected: (_) => setState(() => _chosen = k),
                    ),
                ],
              ),
              for (var i = 0; i < _options.length; i++)
                CheckboxListTile(
                  key: ValueKey('quick-context-$i'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    'Refer to ${_options[i].label}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  value: _attach.contains(i),
                  onChanged: (on) => setState(
                    () => on == true ? _attach.add(i) : _attach.remove(i),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    key: const ValueKey('quick-capture-error'),
                    style: TextStyle(fontSize: 12, color: AppColors.warm),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _kind == QuickKind.task
                      ? 'Goes to Tasks. Nothing is scheduled.'
                      : 'Goes to the Inbox on Home; file it later.',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textFaint),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('quick-capture-cancel'),
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('quick-capture-save'),
            onPressed: _busy ? null : _save,
            child: Text(_error != null ? 'Try again' : 'Save'),
          ),
        ],
      ),
    );
  }
}
