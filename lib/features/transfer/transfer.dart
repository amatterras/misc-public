// Drag and drop between THEapp's units, all through one typed mechanism:
// what is dragged ([Transfer]), where it is dropped ([DropPlace]), which
// operations that place supports for it ([TransferOp]: move, copy, convert,
// link) and how each one is carried out on the existing records and
// canvases. Every page uses the same widgets ([TransferSource] and
// [TransferTarget]), so there is one system, not one per page.
//
// Data safety: copies and conversions never change the original. A move
// first places the content, checks it arrived, and only then removes it
// from where it came from. Cancelling the drag or the operation menu
// changes nothing. Attachments always travel as references to the same
// managed asset (no file is copied).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/canvas_ops.dart';
import '../../app/theme.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../data/models/record.dart';
import '../../data/models/task_models.dart';
import '../../data/workspace.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_export.dart';
import '../links/archive_library.dart';

/// Something being dragged.
sealed class Transfer {
  const Transfer();

  /// A short name for menus and messages.
  String get label;
}

/// Items selected on a mindmap (or the Archive board).
class CanvasItemsTransfer extends Transfer {
  const CanvasItemsTransfer(this.source, this.itemIds);
  final CanvasController source;
  final List<String> itemIds;

  List<CanvasItem> get items => [
    for (final id in itemIds) ?source.itemById(id),
  ];

  @override
  String get label =>
      itemIds.length == 1 ? '1 item' : '${itemIds.length} items';
}

/// A whole note.
class NoteTransfer extends Transfer {
  const NoteTransfer(this.noteId, this.title);
  final String noteId;
  final String title;
  @override
  String get label => '“$title”';
}

/// A task (from the task list or a calendar day). [from] is the day it was
/// dragged from, if any.
class TaskTransfer extends Transfer {
  const TaskTransfer(this.taskId, this.title, {this.from});
  final String taskId;
  final String title;
  final DateTime? from;
  @override
  String get label => '“$title”';
}

/// An entry or task label dragged from one calendar day to another.
class CalendarItemTransfer extends Transfer {
  const CalendarItemTransfer(this.item, this.from);
  final DayItem item;
  final DateTime from;
  @override
  String get label => '“${item.label}”';
}

/// Text selected in a note.
class TextTransfer extends Transfer {
  const TextTransfer(this.text, {this.sourceNoteId});
  final String text;
  final String? sourceNoteId;
  @override
  String get label => 'the selected text';
}

/// Links, photos or PDFs (managed assets).
class AssetsTransfer extends Transfer {
  const AssetsTransfer(this.assetIds);
  final List<String> assetIds;
  @override
  String get label =>
      assetIds.length == 1 ? '1 attachment' : '${assetIds.length} attachments';
}

/// A project (with its tasks).
class ProjectTransfer extends Transfer {
  const ProjectTransfer(this.projectId, this.name);
  final String projectId;
  final String name;
  @override
  String get label => 'project “$name”';
}

/// A web address (a Safari tab or page), dragged by the user: nothing is
/// captured from a page unless it is dragged or sent explicitly.
class UrlTransfer extends Transfer {
  const UrlTransfer(this.url, {this.title = ''});
  final String url;
  final String title;
  @override
  String get label => title.isEmpty ? 'the page' : '“$title”';
}

/// Where something is dropped.
sealed class DropPlace {
  const DropPlace();
}

/// An Archive folder ([folderId] null = the top level).
class ArchivePlace extends DropPlace {
  const ArchivePlace(this.folderId);
  final String? folderId;
}

/// A notes folder ([folderId] null = no folder).
class NoteFolderPlace extends DropPlace {
  const NoteFolderPlace(this.folderId);
  final String? folderId;
}

/// One task: dropping a task makes it a step (subtask) or a dependency.
class TaskPlace extends DropPlace {
  const TaskPlace(this.taskId);
  final String taskId;
}

/// A mindmap (or the Archive board), at [at] in its coordinates.
class CanvasPlace extends DropPlace {
  const CanvasPlace(this.canvasId, {this.at});
  final String canvasId;
  final Offset? at;
}

class NotePlace extends DropPlace {
  const NotePlace(this.noteId);
  final String noteId;
}

/// The Notes page itself: makes a new note.
class NewNotePlace extends DropPlace {
  const NewNotePlace();
}

class DayPlace extends DropPlace {
  const DayPlace(this.day);
  final DateTime day;
}

/// The task list (optionally a project's).
class TasksPlace extends DropPlace {
  const TasksPlace({this.projectId});
  final String? projectId;
}

/// What a drop does.
enum TransferOp { move, copy, convert, link }

/// One choice offered at a drop: the operation and how it is described.
class TransferChoice {
  const TransferChoice(this.op, this.label);
  final TransferOp op;
  final String label;
}

class TransferResult {
  const TransferResult(this.message, {this.undo});
  final String message;

  /// Takes the drop back (removes what was created, puts moved content
  /// back); null when the canvas's own undo covers it.
  final FutureOr<void> Function()? undo;
}

extension Transfers on AppState {
  /// The operations [place] supports for [t]; empty = cannot drop here.
  List<TransferChoice> transferChoices(Transfer t, DropPlace place) {
    switch ((t, place)) {
      case (CanvasItemsTransfer t, CanvasPlace p):
        if (p.canvasId == t.source.id) return const [];
        return [
          const TransferChoice(TransferOp.copy, 'Copy here'),
          if (t.items.any((i) => !t.source.isLocked(i.id)))
            const TransferChoice(TransferOp.move, 'Move here'),
          if (canvasList.any((c) => c.id == t.source.id))
            const TransferChoice(TransferOp.link, 'Link to the source mindmap'),
        ];
      case (CanvasItemsTransfer t, NotePlace()):
        return [
          const TransferChoice(TransferOp.copy, 'Copy onto the note’s pages'),
          if (t.items.any((i) => !t.source.isLocked(i.id)))
            const TransferChoice(TransferOp.move, 'Move onto the note’s pages'),
          if (_assetsIn(t).isNotEmpty)
            const TransferChoice(TransferOp.link, 'Attach the links / files'),
        ];
      case (CanvasItemsTransfer t, NewNotePlace()):
        return [
          const TransferChoice(TransferOp.convert, 'New note from the text'),
          if (t.items.isNotEmpty)
            const TransferChoice(TransferOp.copy, 'New note with these items'),
        ];
      case (CanvasItemsTransfer t, DayPlace()):
        return [
          if (_textsIn(t).isNotEmpty)
            const TransferChoice(TransferOp.convert, 'Make tasks on this day'),
          const TransferChoice(TransferOp.copy, 'Attach a picture to this day'),
          if (_assetsIn(t).isNotEmpty)
            const TransferChoice(TransferOp.link, 'Attach the links / files'),
        ];
      case (CanvasItemsTransfer t, TasksPlace()):
        return [
          if (_textsIn(t).isNotEmpty)
            const TransferChoice(
              TransferOp.convert,
              'Make tasks from the text',
            ),
        ];
      case (NoteTransfer(), CanvasPlace()):
        return const [
          TransferChoice(TransferOp.link, 'Place a card of the note'),
          TransferChoice(TransferOp.copy, 'Copy the note’s text'),
        ];
      case (NoteTransfer n, NotePlace p):
        if (n.noteId == p.noteId) return const [];
        return const [TransferChoice(TransferOp.link, 'Link the notes')];
      case (NoteTransfer(), DayPlace()):
        return const [
          TransferChoice(TransferOp.link, 'Mention the note on this day'),
          TransferChoice(TransferOp.convert, 'Task to review it on this day'),
        ];
      case (NoteTransfer(), TasksPlace()):
        return const [TransferChoice(TransferOp.convert, 'New task about it')];
      case (TaskTransfer t, DayPlace p):
        if (t.from != null && daysBetween(t.from!, p.day) == 0) return const [];
        return const [TransferChoice(TransferOp.move, 'Schedule on this day')];
      case (CalendarItemTransfer t, DayPlace p):
        // Google / Outlook events are changed there, not moved here.
        if (t.item is ExternalOnDay || daysBetween(t.from, p.day) == 0) {
          return const [];
        }
        return const [TransferChoice(TransferOp.move, 'Move to this day')];
      case (TaskTransfer(), NotePlace()):
        return const [TransferChoice(TransferOp.link, 'Link the task')];
      case (TaskTransfer(), CanvasPlace()):
        return const [TransferChoice(TransferOp.copy, 'Write the task here')];
      case (TextTransfer(), CanvasPlace()):
        return const [TransferChoice(TransferOp.copy, 'Copy as a text box')];
      case (TextTransfer(), TasksPlace()):
        return const [TransferChoice(TransferOp.convert, 'Make a task')];
      case (TextTransfer(), DayPlace()):
        return const [
          TransferChoice(TransferOp.convert, 'Make a task on this day'),
          TransferChoice(TransferOp.copy, 'Add to the day’s notes'),
        ];
      case (TextTransfer t, NotePlace p):
        if (t.sourceNoteId == p.noteId) return const [];
        return const [TransferChoice(TransferOp.copy, 'Add to the note')];
      case (TextTransfer(), NewNotePlace()):
        return const [TransferChoice(TransferOp.convert, 'New note')];
      case (AssetsTransfer(), CanvasPlace()):
        return const [TransferChoice(TransferOp.link, 'Place here')];
      case (AssetsTransfer(), NotePlace()):
        return const [TransferChoice(TransferOp.link, 'Attach to the note')];
      case (AssetsTransfer(), DayPlace()):
        return const [TransferChoice(TransferOp.link, 'Attach to this day')];
      case (AssetsTransfer(), NewNotePlace()):
        return const [TransferChoice(TransferOp.convert, 'New note with them')];
      // ---- web addresses (Safari) ----
      case (UrlTransfer(), CanvasPlace()):
        return const [TransferChoice(TransferOp.link, 'Place a link card')];
      case (UrlTransfer(), NotePlace()):
        return const [TransferChoice(TransferOp.link, 'Attach the link')];
      case (UrlTransfer(), DayPlace()):
        return const [TransferChoice(TransferOp.link, 'Attach to this day')];
      case (UrlTransfer(), NewNotePlace()):
        return const [TransferChoice(TransferOp.convert, 'New note with it')];
      case (UrlTransfer(), TasksPlace()):
        return const [TransferChoice(TransferOp.convert, 'Task to read it')];
      case (UrlTransfer(), ArchivePlace()):
        return const [TransferChoice(TransferOp.copy, 'Save to the Archive')];
      // ---- Archive folders ----
      case (AssetsTransfer t, ArchivePlace p):
        if (t.assetIds.every(
          (id) => workspace.assets[id]?.folderId == p.folderId,
        )) {
          return const [];
        }
        return const [TransferChoice(TransferOp.move, 'Move into this folder')];
      case (CanvasItemsTransfer t, ArchivePlace()):
        return [
          if (_assetsIn(t).isNotEmpty)
            const TransferChoice(
              TransferOp.link,
              'File the links / files here',
            ),
        ];
      // ---- notes ----
      case (NoteTransfer n, NoteFolderPlace p):
        if (workspace.notes[n.noteId]?.folderId == p.folderId) return const [];
        return const [TransferChoice(TransferOp.move, 'Move to this folder')];
      case (NoteTransfer(), NewNotePlace()):
        return const [TransferChoice(TransferOp.copy, 'Duplicate the note')];
      // ---- tasks and projects ----
      case (TaskTransfer t, TaskPlace p):
        if (t.taskId == p.taskId || _isStepOf(p.taskId, t.taskId)) {
          return const [];
        }
        return const [
          TransferChoice(TransferOp.move, 'Make it a step of this task'),
          TransferChoice(TransferOp.link, 'Wait for this task first'),
        ];
      case (TaskTransfer t, TasksPlace p):
        final task = workspace.tasks[t.taskId];
        if (task == null || task.projectId == p.projectId) return const [];
        return [
          TransferChoice(
            TransferOp.move,
            p.projectId == null ? 'Take out of its project' : 'Move here',
          ),
        ];
      case (TaskTransfer(), NewNotePlace()):
        return const [TransferChoice(TransferOp.convert, 'New note about it')];
      case (ProjectTransfer(), CanvasPlace()):
        return const [
          TransferChoice(TransferOp.copy, 'Write its outline here'),
        ];
      case (ProjectTransfer(), NotePlace()):
        return const [
          TransferChoice(TransferOp.link, 'Link the note to the project'),
          TransferChoice(TransferOp.copy, 'Add its task list'),
        ];
      case (ProjectTransfer(), NewNotePlace()):
        return const [
          TransferChoice(TransferOp.convert, 'New note with its task list'),
        ];
      case (ProjectTransfer p, DayPlace()):
        if (!workspace.tasks.all.any(
          (t) => t.projectId == p.projectId && !t.done && t.dueDate != null,
        )) {
          return const [];
        }
        return const [
          TransferChoice(TransferOp.move, 'Shift its dates to start this day'),
        ];
      // ---- calendar entries elsewhere ----
      case (CalendarItemTransfer(), NotePlace()):
        return const [TransferChoice(TransferOp.copy, 'Add to the note')];
      case (CalendarItemTransfer(), CanvasPlace()):
        return const [TransferChoice(TransferOp.copy, 'Write it here')];
      case (CalendarItemTransfer(), NewNotePlace()):
        return const [TransferChoice(TransferOp.convert, 'New note about it')];
      case (CalendarItemTransfer t, TasksPlace()):
        return [
          if (t.item is EntryOnDay)
            const TransferChoice(TransferOp.convert, 'Make a task'),
        ];
      default:
        return const [];
    }
  }

  /// Whether [taskId] is (somewhere) a step of [ancestorId], so making the
  /// ancestor its step would loop.
  bool _isStepOf(String taskId, String ancestorId) {
    final seen = <String>{};
    var t = workspace.tasks[taskId];
    while (t != null && t.parentId != null && seen.add(t.id)) {
      if (t.parentId == ancestorId) return true;
      t = workspace.tasks[t.parentId];
    }
    return false;
  }

  /// The project's open tasks as a checklist.
  String _projectList(String projectId) {
    final p = workspace.projects[projectId];
    final tasks = workspace.tasks.all
        .where((t) => t.projectId == projectId)
        .toList();
    String line(Task t, int depth) =>
        '${'  ' * depth}- [${t.done ? 'x' : ' '}] ${t.title}';
    final out = <String>['# ${p?.name ?? 'Project'}'];
    void level(String? parent, int depth) {
      for (final t in tasks.where((t) => t.parentId == parent)) {
        out.add(line(t, depth));
        if (depth < 10) level(t.id, depth + 1);
      }
    }

    level(null, 0);
    return out.join('\n');
  }

  static List<Asset> _assetsFrom(Workspace ws, Iterable<CanvasItem> items) => [
    for (final i in items)
      if (i is LinkItem)
        ?ws.assets[i.assetId]
      else if (i is ImageItem)
        ?ws.assets[i.assetId],
  ];

  List<Asset> _assetsIn(CanvasItemsTransfer t) =>
      _assetsFrom(workspace, t.items);

  List<String> _textsIn(CanvasItemsTransfer t) => [
    for (final i in t.items)
      if (i is TextItem && i.text.trim().isNotEmpty)
        i.text.trim().split('\n').first.replaceFirst(RegExp(r'^[#\-*\s]+'), ''),
  ];

  /// The controller of canvas-like document [id]: the open one, or one
  /// opened just for this drop (saved and closed afterwards). The mindmap
  /// on screen is never switched mid-drop, so the source stays open.
  Future<CanvasController> _canvasFor(String id) async {
    if (canvas?.id == id) return canvas!;
    if (id == linksBoardId) return openLinksBoard();
    final doc = await canvases.load(id);
    if (doc == null) throw StateError('That mindmap is gone.');
    final c = CanvasController(
      document: doc,
      onSave: saveDocument,
      resources: resources,
      clock: workspace.clock,
    );
    (_temporary[this] ??= []).add(c);
    return c;
  }

  /// Carries out [op] for [t] at [place]. Never changes the original for a
  /// copy, link or conversion; a move removes the original only after the
  /// content arrived.
  Future<TransferResult> performTransfer(
    Transfer t,
    DropPlace place,
    TransferOp op,
  ) async {
    try {
      return await _perform(t, place, op);
    } finally {
      for (final c in _temporary[this] ?? const <CanvasController>[]) {
        await c.flush();
        c.dispose();
      }
      _temporary[this] = null;
    }
  }

  Future<TransferResult> _perform(
    Transfer t,
    DropPlace place,
    TransferOp op,
  ) async {
    final ws = workspace;
    switch ((t, place)) {
      case (CanvasItemsTransfer t, CanvasPlace p):
        if (op == TransferOp.link) {
          final target = await _canvasFor(p.canvasId);
          linkToCanvas(target, t.source.id, p.at ?? canvasDropPoint(target));
          return const TransferResult('Linked to the mindmap.');
        }
        final target = await _canvasFor(p.canvasId);
        final n = await copyItemsInto(
          t.source,
          t.items,
          target,
          at: p.at,
          move: op == TransferOp.move,
        );
        return TransferResult(
          '${op == TransferOp.move ? 'Moved' : 'Copied'} $n item(s).',
        );
      case (CanvasItemsTransfer t, NotePlace p):
        if (op == TransferOp.link) {
          final assets = _assetsIn(t);
          final before = ws.notes[p.noteId]?.assetIds ?? const [];
          for (final a in assets) {
            ws.attachToNote(p.noteId, a.id);
          }
          return TransferResult(
            'Attached ${assets.length} link(s) / file(s).',
            undo: () => _setNoteAssets(p.noteId, before),
          );
        }
        final n = await copyToNote(
          t.source,
          t.items,
          p.noteId,
          move: op == TransferOp.move,
        );
        return TransferResult(
          '${op == TransferOp.move ? 'Moved' : 'Copied'} $n item(s) to the note.',
        );
      case (CanvasItemsTransfer t, NewNotePlace()):
        final note = ws.createNote(
          title: _textsIn(t).firstOrNull ?? 'From ${t.source.title}',
          body: _textsIn(t).skip(1).join('\n'),
        );
        if (op == TransferOp.copy) await copyToNote(t.source, t.items, note.id);
        for (final a in _assetsIn(t)) {
          ws.attachToNote(note.id, a.id);
        }
        return TransferResult(
          'New note “${note.displayTitle}”.',
          undo: () => deleteNote(note.id),
        );
      case (CanvasItemsTransfer t, DayPlace p):
        switch (op) {
          case TransferOp.convert:
            final ids = [
              for (final title in _textsIn(t))
                ws.createTask(title, dueDate: dateOnly(p.day)).id,
            ];
            return TransferResult(
              'Made ${ids.length} task(s) on ${_day(p.day)}.',
              undo: () => ids.forEach(ws.deleteTask),
            );
          case TransferOp.link:
            final before = ws.dayRecord(p.day).assetIds;
            for (final a in _assetsIn(t)) {
              ws.attachToDay(p.day, a.id);
            }
            return TransferResult(
              'Attached to ${_day(p.day)}.',
              undo: () => _setDayAssets(p.day, before),
            );
          case TransferOp.copy || TransferOp.move:
            final png = await renderItemsPng(t.source, items: t.itemIds);
            if (png == null) return const TransferResult('Nothing to attach.');
            final asset = await ws.imageAssetFromBytes(png, 'png');
            final before = ws.dayRecord(p.day).assetIds;
            ws.attachToDay(p.day, asset.id);
            return TransferResult(
              'Attached a picture to ${_day(p.day)}.',
              undo: () => _setDayAssets(p.day, before),
            );
        }
      case (CanvasItemsTransfer t, TasksPlace p):
        final ids = [
          for (final title in _textsIn(t))
            ws.createTask(title, projectId: p.projectId).id,
        ];
        return TransferResult(
          'Made ${ids.length} task(s).',
          undo: () => ids.forEach(ws.deleteTask),
        );
      case (NoteTransfer n, CanvasPlace p):
        final target = await _canvasFor(p.canvasId);
        final at = p.at ?? canvasDropPoint(target);
        if (op == TransferOp.link) {
          target.insertNoteCard(n.noteId, at);
          return const TransferResult('Placed a card of the note.');
        }
        final note = ws.notes[n.noteId];
        if (note == null) return const TransferResult('The note is gone.');
        target.addItems([
          TextItem(
            id: newId(),
            position: at,
            width: TextItem.defaultWidth,
            minHeight: 0,
            text: '# ${note.displayTitle}\n${note.body}',
          ),
        ]);
        return const TransferResult('Copied the note’s text.');
      case (NoteTransfer n, NotePlace p):
        final target = ws.notes[p.noteId];
        if (target == null) return const TransferResult('The note is gone.');
        final link = '[[${n.title}]]';
        if (target.body.contains(link)) {
          return const TransferResult('Already linked.');
        }
        final before = target.body;
        ws.notes.put(
          target.copyWith(body: '${target.body.trimRight()}\n$link'),
        );
        return TransferResult(
          'Linked the notes.',
          undo: () => _setNoteBody(p.noteId, before),
        );
      case (NoteTransfer n, DayPlace p):
        if (op == TransferOp.convert) {
          final task = ws.createTask(
            'Review ${n.title}',
            dueDate: dateOnly(p.day),
          );
          ws.tasks.put(task.copyWith(noteIds: [n.noteId]));
          return TransferResult(
            'Task on ${_day(p.day)}.',
            undo: () => ws.deleteTask(task.id),
          );
        }
        final day = ws.dayRecord(p.day);
        final before = day.text;
        ws.saveDay(
          day.copyWith(text: '${day.text.trimRight()}\n[[${n.title}]]'.trim()),
        );
        return TransferResult(
          'Mentioned on ${_day(p.day)}.',
          undo: () => _setDayText(p.day, before),
        );
      case (NoteTransfer n, TasksPlace p):
        final task = ws.createTask(n.title, projectId: p.projectId);
        ws.tasks.put(task.copyWith(noteIds: [n.noteId]));
        return TransferResult(
          'New task about the note.',
          undo: () => ws.deleteTask(task.id),
        );
      case (TaskTransfer t, DayPlace p):
        final task = ws.tasks[t.taskId];
        if (task == null) return const TransferResult('The task is gone.');
        ws.moveDayItem(TaskOnDay(task, 0), t.from, p.day);
        return TransferResult(
          'Scheduled on ${_day(p.day)}.',
          undo: () => ws.tasks.put(task),
        );
      case (CalendarItemTransfer t, DayPlace p):
        final item = t.item;
        final (CalendarEntry? entry, Task? task) = switch (item) {
          EntryOnDay(:final entry) => (ws.entries[entry.id], null),
          TaskOnDay(:final task) => (null, ws.tasks[task.id]),
          ExternalOnDay() => (null, null),
        };
        ws.moveDayItem(item, t.from, p.day);
        return TransferResult(
          'Moved to ${_day(p.day)}.',
          undo: () {
            if (entry != null) ws.entries.put(entry);
            if (task != null) ws.tasks.put(task);
          },
        );
      case (TaskTransfer t, NotePlace p):
        final task = ws.tasks[t.taskId];
        if (task == null) return const TransferResult('The task is gone.');
        if (task.noteIds.contains(p.noteId)) {
          return const TransferResult('Already linked.');
        }
        ws.tasks.put(task.copyWith(noteIds: [...task.noteIds, p.noteId]));
        return TransferResult(
          'Linked the task.',
          undo: () => ws.tasks.put(task),
        );
      case (TaskTransfer t, CanvasPlace p):
        final target = await _canvasFor(p.canvasId);
        target.addItems([
          TextItem(
            id: newId(),
            position: p.at ?? canvasDropPoint(target),
            width: TextItem.defaultWidth,
            minHeight: 0,
            text: '- [ ] ${t.title}',
          ),
        ]);
        return const TransferResult('Wrote the task on the mindmap.');
      case (TextTransfer t, CanvasPlace p):
        final target = await _canvasFor(p.canvasId);
        target.addItems([
          TextItem(
            id: newId(),
            position: p.at ?? canvasDropPoint(target),
            width: TextItem.defaultWidth,
            minHeight: 0,
            text: t.text,
          ),
        ]);
        return const TransferResult('Copied as a text box.');
      case (TextTransfer t, TasksPlace p):
        final task = ws.createTask(_firstLine(t.text), projectId: p.projectId);
        if (t.sourceNoteId != null) {
          ws.tasks.put(task.copyWith(noteIds: [t.sourceNoteId!]));
        }
        return TransferResult(
          'Made a task.',
          undo: () => ws.deleteTask(task.id),
        );
      case (TextTransfer t, DayPlace p):
        if (op == TransferOp.convert) {
          final task = ws.createTask(
            _firstLine(t.text),
            dueDate: dateOnly(p.day),
          );
          return TransferResult(
            'Task on ${_day(p.day)}.',
            undo: () => ws.deleteTask(task.id),
          );
        }
        final day = ws.dayRecord(p.day);
        final before = day.text;
        ws.saveDay(
          day.copyWith(text: '${day.text.trimRight()}\n${t.text}'.trim()),
        );
        return TransferResult(
          'Added to ${_day(p.day)}.',
          undo: () => _setDayText(p.day, before),
        );
      case (TextTransfer t, NotePlace p):
        final target = ws.notes[p.noteId];
        if (target == null) return const TransferResult('The note is gone.');
        final before = target.body;
        ws.notes.put(
          target.copyWith(body: '${target.body.trimRight()}\n\n${t.text}'),
        );
        return TransferResult(
          'Added to the note.',
          undo: () => _setNoteBody(p.noteId, before),
        );
      case (TextTransfer t, NewNotePlace()):
        final note = ws.createNote(
          title: _firstLine(t.text),
          body: t.text.trim().split('\n').skip(1).join('\n'),
        );
        return TransferResult('New note.', undo: () => deleteNote(note.id));
      case (AssetsTransfer t, CanvasPlace p):
        final target = await _canvasFor(p.canvasId);
        var at = p.at ?? canvasDropPoint(target);
        for (final id in t.assetIds) {
          final a = ws.assets[id];
          if (a == null) continue;
          a.kind == AssetKind.image
              ? target.insertImage(a, at)
              : target.insertLink(a, at);
          at += const Offset(40, 40);
        }
        return const TransferResult('Placed here.');
      case (AssetsTransfer t, NotePlace p):
        final before = ws.notes[p.noteId]?.assetIds ?? const [];
        for (final id in t.assetIds) {
          ws.attachToNote(p.noteId, id);
        }
        return TransferResult(
          'Attached to the note.',
          undo: () => _setNoteAssets(p.noteId, before),
        );
      case (AssetsTransfer t, DayPlace p):
        final before = ws.dayRecord(p.day).assetIds;
        for (final id in t.assetIds) {
          ws.attachToDay(p.day, id);
        }
        return TransferResult(
          'Attached to ${_day(p.day)}.',
          undo: () => _setDayAssets(p.day, before),
        );
      case (AssetsTransfer t, NewNotePlace()):
        final note = ws.createNote(
          title: ws.assets[t.assetIds.firstOrNull ?? '']?.label ?? 'New note',
          assetIds: t.assetIds,
        );
        return TransferResult('New note.', undo: () => deleteNote(note.id));
      // ---- web addresses: become a managed link asset, then as assets ----
      case (UrlTransfer u, ArchivePlace p):
        final count = ws.assets.all.length;
        final asset = ws.linkAsset(
          u.url,
          title: u.title.isEmpty ? null : u.title,
        );
        final existed = ws.assets.all.length == count; // the same link was kept
        if (p.folderId != null) ws.moveAssetToFolder(asset.id, p.folderId);
        return TransferResult(
          existed
              ? 'Already in the Archive (filed here).'
              : 'Saved to the Archive.',
          undo: existed ? null : () => ws.assets.remove(asset.id),
        );
      case (UrlTransfer u, TasksPlace p):
        final asset = ws.linkAsset(
          u.url,
          title: u.title.isEmpty ? null : u.title,
        );
        final task = ws.createTask(
          'Read ${u.title.isEmpty ? asset.label : u.title}',
          projectId: p.projectId,
        );
        ws.tasks.put(task.copyWith(assetIds: [asset.id]));
        return TransferResult(
          'Made a task.',
          undo: () => ws.deleteTask(task.id),
        );
      case (UrlTransfer u, _):
        final asset = ws.linkAsset(
          u.url,
          title: u.title.isEmpty ? null : u.title,
        );
        return _perform(AssetsTransfer([asset.id]), place, switch (place) {
          NewNotePlace() => TransferOp.convert,
          _ => TransferOp.link,
        });
      // ---- Archive folders ----
      case (AssetsTransfer t, ArchivePlace p):
        final before = {
          for (final id in t.assetIds) id: ws.assets[id]?.folderId,
        };
        for (final id in t.assetIds) {
          ws.moveAssetToFolder(id, p.folderId);
        }
        return TransferResult(
          'Moved ${t.assetIds.length} into ${ws.archiveFolderLabel(p.folderId).isEmpty ? 'the top level' : ws.archiveFolderLabel(p.folderId)}.',
          undo: () => before.forEach(ws.moveAssetToFolder),
        );
      case (CanvasItemsTransfer t, ArchivePlace p):
        final ids = [for (final a in _assetsIn(t)) a.id];
        return _perform(AssetsTransfer(ids), p, TransferOp.move);
      // ---- notes ----
      case (NoteTransfer n, NoteFolderPlace p):
        final note = ws.notes[n.noteId];
        if (note == null) return const TransferResult('The note is gone.');
        ws.notes.put(note.copyWith(folderId: () => p.folderId));
        return TransferResult(
          'Moved to ${ws.folderLabel(p.folderId)}.',
          undo: () => _setNoteFolder(n.noteId, note.folderId),
        );
      case (NoteTransfer n, NewNotePlace()):
        final note = ws.notes[n.noteId];
        if (note == null) return const TransferResult('The note is gone.');
        final copy = ws.createNote(
          title: '${note.title} (copy)',
          body: note.body,
          folderId: note.folderId,
          assetIds: note.assetIds,
        );
        return TransferResult(
          'Duplicated the note (its pages stay with the original).',
          undo: () => deleteNote(copy.id),
        );
      // ---- tasks and projects ----
      case (TaskTransfer t, TaskPlace p):
        final task = ws.tasks[t.taskId], parent = ws.tasks[p.taskId];
        if (task == null || parent == null) {
          return const TransferResult('The task is gone.');
        }
        if (op == TransferOp.link) {
          if (task.dependsOn.contains(parent.id)) {
            return const TransferResult('Already waits for it.');
          }
          ws.tasks.put(
            task.copyWith(dependsOn: [...task.dependsOn, parent.id]),
          );
          return TransferResult(
            '“${task.title}” now waits for “${parent.title}”.',
            undo: () => ws.tasks.put(task),
          );
        }
        ws.tasks.put(
          task.copyWith(
            parentId: () => parent.id,
            projectId: () => parent.projectId,
          ),
        );
        return TransferResult(
          '“${task.title}” is now a step of “${parent.title}”.',
          undo: () => ws.tasks.put(task),
        );
      case (TaskTransfer t, TasksPlace p):
        final task = ws.tasks[t.taskId];
        if (task == null) return const TransferResult('The task is gone.');
        // Its steps go with it.
        final moved = [
          task,
          ...ws.tasks.all.where((s) => _isStepOf(s.id, task.id)),
        ];
        for (final m in moved) {
          ws.tasks.put(
            m.copyWith(
              projectId: () => p.projectId,
              parentId: m.id == task.id ? () => null : null,
            ),
          );
        }
        return TransferResult(
          p.projectId == null
              ? 'Taken out of its project.'
              : 'Moved to “${ws.projects[p.projectId]?.name}”.',
          undo: () => ws.tasks.putAll(moved),
        );
      case (TaskTransfer t, NewNotePlace()):
        final task = ws.tasks[t.taskId];
        if (task == null) return const TransferResult('The task is gone.');
        final note = ws.createNote(title: task.title, body: task.notes);
        ws.tasks.put(task.copyWith(noteIds: [...task.noteIds, note.id]));
        return TransferResult(
          'New note, linked to the task.',
          undo: () {
            ws.tasks.put(task);
            return deleteNote(note.id);
          },
        );
      case (ProjectTransfer p, CanvasPlace c):
        final target = await _canvasFor(c.canvasId);
        target.addItems([
          TextItem(
            id: newId(),
            position: c.at ?? canvasDropPoint(target),
            width: TextItem.defaultWidth,
            minHeight: 0,
            text: _projectList(p.projectId),
          ),
        ]);
        return const TransferResult('Wrote the outline on the mindmap.');
      case (ProjectTransfer p, NotePlace n):
        final note = ws.notes[n.noteId];
        if (note == null) return const TransferResult('The note is gone.');
        if (op == TransferOp.link) {
          if (note.projectIds.contains(p.projectId)) {
            return const TransferResult('Already linked.');
          }
          ws.notes.put(
            note.copyWith(projectIds: [...note.projectIds, p.projectId]),
          );
        } else {
          ws.notes.put(
            note.copyWith(
              body: '${note.body.trimRight()}\n\n${_projectList(p.projectId)}',
            ),
          );
        }
        return TransferResult(
          op == TransferOp.link
              ? 'Linked to the project.'
              : 'Added the task list.',
          undo: () => ws.notes.put(note),
        );
      case (ProjectTransfer p, NewNotePlace()):
        final note = ws.createNote(
          title: p.name,
          body: _projectList(p.projectId).split('\n').skip(1).join('\n'),
        );
        ws.notes.put(note.copyWith(projectIds: [p.projectId]));
        return TransferResult('New note.', undo: () => deleteNote(note.id));
      case (ProjectTransfer p, DayPlace d):
        final tasks = [
          for (final t in ws.tasks.all)
            if (t.projectId == p.projectId && !t.done && t.dueDate != null) t,
        ];
        final first = tasks
            .map((t) => t.dueDate!)
            .reduce((a, b) => a.isBefore(b) ? a : b);
        final days = daysBetween(first, d.day);
        final n = ws.shiftProject(p.projectId, days);
        return TransferResult(
          'Moved $n date(s) by $days day(s).',
          undo: () => ws.tasks.putAll(tasks),
        );
      // ---- calendar entries elsewhere ----
      case (CalendarItemTransfer t, _):
        final text = switch (t.item) {
          EntryOnDay(:final entry) => [
            entry.name,
            if (entry.description.isNotEmpty) entry.description,
          ].join('\n'),
          TaskOnDay(:final task) => task.title,
          ExternalOnDay(:final event) => event.title,
        };
        return switch (place) {
          TasksPlace() => _perform(TextTransfer(text), place, op),
          NewNotePlace() => _perform(TextTransfer(text), place, op),
          _ => _perform(TextTransfer(text), place, TransferOp.copy),
        };
      default:
        return const TransferResult('That cannot be dropped here.');
    }
  }

  /// Copies [items] of [from] into [target] (placed at [at], or to the right
  /// of what is there), with their tags, locks and groups. With [move] the
  /// unlocked originals are removed afterwards (one undo step on [from]).
  Future<int> copyItemsInto(
    CanvasController from,
    List<CanvasItem> items,
    CanvasController target, {
    Offset? at,
    bool move = false,
  }) async {
    if (move) {
      items = [
        for (final i in items)
          if (!from.isLocked(i.id)) i,
      ];
    }
    if (items.isEmpty || identical(from, target)) return 0;
    final area = from.boundsOf(items) ?? Rect.zero;
    var place = at;
    if (place == null) {
      var right = 0.0;
      for (final i in target.items) {
        final b = target.itemBounds(i);
        if (b.right > right) right = b.right;
      }
      place = Offset(right + 80 + area.width / 2, area.height / 2);
    }
    final (copies, ids) = CanvasController.copyItems(
      items,
      place - area.center,
    );
    final marks = from.marksOf(items.map((i) => i.id));
    target.addItemsWithMarks(copies, {
      for (final e in ids.entries) e.value: ?marks[e.key],
    });
    await target.flush();
    // Only after the copy arrived: remove the originals of a move.
    final arrived = copies.every((c) => target.itemById(c.id) != null);
    if (move && arrived) {
      from.select(items.map((i) => i.id));
      from.deleteSelection();
    }
    return copies.length;
  }

  void _setNoteAssets(String noteId, List<String> ids) {
    final n = workspace.notes[noteId];
    if (n != null) workspace.notes.put(n.copyWith(assetIds: ids));
  }

  void _setNoteFolder(String noteId, String? folderId) {
    final n = workspace.notes[noteId];
    if (n != null) workspace.notes.put(n.copyWith(folderId: () => folderId));
  }

  void _setNoteBody(String noteId, String body) {
    final n = workspace.notes[noteId];
    if (n != null) workspace.notes.put(n.copyWith(body: body));
  }

  void _setDayAssets(DateTime day, List<String> ids) =>
      workspace.saveDay(workspace.dayRecord(day).copyWith(assetIds: ids));

  void _setDayText(DateTime day, String text) =>
      workspace.saveDay(workspace.dayRecord(day).copyWith(text: text));

  static String _firstLine(String text) {
    final line = text.trim().split('\n').first.trim();
    return line.length > 120 ? '${line.substring(0, 117)}…' : line;
  }

  static String _day(DateTime d) => '${d.year}-${d.month}-${d.day}';
}

/// Canvases opened only for a drop in progress (see [Transfers]).
final _temporary = Expando<List<CanvasController>>();

/// Makes [child] draggable as [transfer]. Mouse and pen drag at once;
/// touch uses press-and-hold, so scrolling still works.
class TransferSource extends StatelessWidget {
  const TransferSource({
    super.key,
    required this.transfer,
    required this.child,
    this.feedback,
    this.touch = false,
  });

  final Transfer Function() transfer;
  final Widget child;
  final Widget? feedback;

  /// Use press-and-hold (iPhone/iPad, or rows that also scroll).
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final data = transfer();
    final preview = Material(
      color: AppColors.cardRaised,
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child:
            feedback ??
            Text(
              'Drag ${data.label}',
              style: const TextStyle(fontSize: 13, color: AppColors.text),
            ),
      ),
    );
    return touch
        ? LongPressDraggable<Transfer>(
            data: data,
            // The whole area catches the pointer, even where nothing is
            // painted (the selection grip is an invisible circle).
            hitTestBehavior: HitTestBehavior.opaque,
            feedback: preview,
            childWhenDragging: Opacity(opacity: 0.4, child: child),
            child: child,
          )
        : Draggable<Transfer>(
            data: data,
            hitTestBehavior: HitTestBehavior.opaque,
            feedback: preview,
            childWhenDragging: Opacity(opacity: 0.4, child: child),
            child: child,
          );
  }
}

/// A place things can be dropped on. Highlights while something it accepts
/// hovers over it; on drop, offers the choices (or does the only one).
class TransferTarget extends StatelessWidget {
  const TransferTarget({
    super.key,
    required this.state,
    required this.place,
    required this.child,
    this.placeAt,
  });

  final AppState state;
  final DropPlace place;
  final Widget child;

  /// A place that depends on where the drop lands (e.g. a canvas point).
  final DropPlace Function(Offset global)? placeAt;

  @override
  Widget build(BuildContext context) => DragTarget<Transfer>(
    onWillAcceptWithDetails: (d) =>
        state.transferChoices(d.data, place).isNotEmpty,
    onAcceptWithDetails: (d) => unawaited(
      dropTransfer(
        context,
        state,
        d.data,
        placeAt?.call(d.offset) ?? place,
        d.offset,
      ),
    ),
    // Accepting: accent outline. Hovered by something it cannot take: a
    // red outline, so a drop there is visibly refused (nothing changes).
    builder: (context, candidates, rejected) => DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: candidates.isNotEmpty
            ? Border.all(color: AppColors.accent, width: 2)
            : rejected.isNotEmpty
            ? Border.all(color: AppColors.danger, width: 1.5)
            : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    ),
  );
}

/// Performs a drop: asks which operation when there are several (closing
/// the menu cancels: nothing changes), then reports the result with Undo.
Future<void> dropTransfer(
  BuildContext context,
  AppState state,
  Transfer t,
  DropPlace place,
  Offset at,
) async {
  final choices = state.transferChoices(t, place);
  if (choices.isEmpty) return;
  var choice = choices.first;
  if (choices.length > 1) {
    final picked = await showMenu<TransferChoice>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        for (final c in choices)
          PopupMenuItem(
            key: ValueKey('transfer-${c.op.name}'),
            value: c,
            height: 34,
            child: Text(c.label),
          ),
      ],
    );
    if (picked == null) return; // cancelled: nothing changed
    choice = picked;
  }
  try {
    final result = await state.performTransfer(t, place, choice.op);
    state.showTransferResult((message: result.message, undo: result.undo));
  } catch (e) {
    state.showToast('The drop did not complete; nothing was removed.');
  }
}
