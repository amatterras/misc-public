import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'models/calendar_models.dart';
import 'models/canvas_models.dart' show newId;
import 'models/library_models.dart';
import 'models/record.dart';
import 'models/sync_models.dart';
import 'models/task_models.dart';
import 'repositories/record_collection.dart';
import 'storage/attachment_store.dart';
import 'storage/backup_service.dart';
import 'storage/json_file_store.dart';
import 'sync/sync_clock.dart';

class CalendarLimitException implements Exception {
  const CalendarLimitException(this.category);
  final CalendarCategory category;

  @override
  String toString() =>
      '${category.label} already has ${CalendarEntry.maxActivePerCategory} '
      'active entries. Archive one first.';
}

/// Something shown on a calendar day: either a calendar entry or a task.
/// Both are the original records, never copies.
sealed class DayItem {
  const DayItem();
  String get id;
  String get label;
  int get colorIndex;
}

class EntryOnDay extends DayItem {
  const EntryOnDay(this.entry);
  final CalendarEntry entry;
  @override
  String get id => entry.id;
  @override
  String get label => entry.name;
  @override
  int get colorIndex => entry.colorIndex;
}

class TaskOnDay extends DayItem {
  const TaskOnDay(this.task, this.colorIndex);
  final Task task;
  @override
  final int colorIndex;
  @override
  String get id => task.id;
  @override
  String get label => task.isExam ? 'Exam: ${task.title}' : task.title;
}

/// All non-canvas records plus attachments and backups, shared by every
/// screen. Business rules (limits, de-duplication) live here so each view
/// behaves the same way.
class Workspace {
  Workspace(this.root)
    : store = JsonFileStore(root),
      attachments = AttachmentStore(root),
      backups = BackupService(root) {
    assets = _c('assets', Asset.fromJson);
    notes = _c('notes', Note.fromJson);
    folders = _c('folders', Folder.fromJson);
    inbox = _c('inbox', InboxItem.fromJson);
    entries = _c('calendar_entries', CalendarEntry.fromJson);
    days = _c('calendar_days', DayRecord.fromJson);
    tasks = _c('tasks', Task.fromJson);
    projects = _c('projects', Project.fromJson);
    conflicts = _c('conflicts', SyncConflict.fromJson);
  }

  final Directory root;
  final JsonFileStore store;
  final AttachmentStore attachments;
  final BackupService backups;

  late final RecordCollection<Asset> assets;
  late final RecordCollection<Note> notes;
  late final RecordCollection<Folder> folders;
  late final RecordCollection<InboxItem> inbox;
  late final RecordCollection<CalendarEntry> entries;
  late final RecordCollection<DayRecord> days;
  late final RecordCollection<Task> tasks;
  late final RecordCollection<Project> projects;
  late final RecordCollection<SyncConflict> conflicts;

  /// The record collections that sync, by their protocol name.
  Map<String, RecordCollection> get syncCollections => {
    'assets': assets,
    'notes': notes,
    'folders': folders,
    'inbox': inbox,
    'calendar_entries': entries,
    'calendar_days': days,
    'tasks': tasks,
    'projects': projects,
    'conflicts': conflicts,
  };

  final List<RecordCollection> _all = [];

  /// Revision stamps for every change made on this device (see [SyncClock]).
  final SyncClock clock = SyncClock();

  /// This installation's identity; set by [load].
  DeviceIdentity? device;

  /// Deleted canvases (id → deletion stamp), so a future sync removes them
  /// on other devices instead of bringing them back.
  final Map<String, String> canvasTombstones = {};

  RecordCollection<T> _c<T extends Record>(
    String name,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final c = RecordCollection<T>(
      store: store,
      name: name,
      fromJson: fromJson,
      clock: clock,
    );
    _all.add(c);
    return c;
  }

  /// Fires when any record anywhere changes.
  late final Listenable changes = Listenable.merge(_all);

  Future<void> load() async {
    device = await DeviceIdentity.loadOrCreate(store);
    clock.deviceId = device!.id;
    final deleted = await store.read('sync', 'canvas_tombstones');
    canvasTombstones
      ..clear()
      ..addAll((deleted?['tombstones'] as Map?)?.cast<String, String>() ?? {});
    canvasTombstones.values.forEach(clock.observe);
    for (final c in _all) {
      await c.load();
    }
  }

  /// Remembers that a canvas was deleted on this device.
  Future<void> recordCanvasDeletion(String canvasId, {String? rev}) async {
    if (rev != null) clock.observe(rev);
    canvasTombstones[canvasId] = rev ?? clock.now();
    await store.write('sync', 'canvas_tombstones', {
      'schema': 1,
      'tombstones': canvasTombstones,
    });
  }

  /// Newest schema among the record files as loaded.
  int get newestRecordSchema => _all.isEmpty
      ? 0
      : _all.map((c) => c.loadedSchema).reduce((a, b) => a > b ? a : b);

  /// Oldest schema among the record files as loaded (for migrations).
  int get oldestRecordSchema => _all.isEmpty
      ? RecordCollection.schemaVersion
      : _all.map((c) => c.loadedSchema).reduce((a, b) => a < b ? a : b);

  Future<void> flush() async {
    for (final c in _all) {
      await c.flush();
    }
  }

  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
  }

  // --------------------------------------------------------------- assets --

  /// Returns the existing link asset for [url] or creates one, so the same
  /// link captured twice is still one record.
  Asset linkAsset(String url, {String? title}) {
    for (final a in assets.all) {
      if (a.kind == AssetKind.link && a.url == url) return a;
    }
    final now = DateTime.now();
    final asset = Asset(
      id: newId(),
      kind: AssetKind.link,
      url: url,
      title: title,
      createdAt: now,
      updatedAt: now,
    );
    assets.put(asset);
    return asset;
  }

  Future<Asset> imageAssetFromFile(File file) async {
    final name = await attachments.importFile(file);
    return _imageAsset(name);
  }

  Future<Asset> imageAssetFromBytes(Uint8List bytes, String extension) async {
    final name = await attachments.importBytes(bytes, extension);
    return _imageAsset(name);
  }

  Future<Asset> _imageAsset(String fileName) async {
    final size = await imageSize(attachments.fileFor(fileName));
    final now = DateTime.now();
    final asset = Asset(
      id: newId(),
      kind: AssetKind.image,
      file: fileName,
      title: null,
      width: size?.width.round(),
      height: size?.height.round(),
      createdAt: now,
      updatedAt: now,
    );
    assets.put(asset);
    return asset;
  }

  /// Reads an image's pixel size without fully decoding it.
  static Future<ui.Size?> imageSize(File file) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        await file.readAsBytes(),
      );
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = ui.Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      descriptor.dispose();
      buffer.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- notes --

  Note createNote({
    String title = '',
    String body = '',
    String? folderId,
    List<String> assetIds = const [],
  }) {
    final now = DateTime.now();
    final note = Note(
      id: newId(),
      title: title,
      body: body,
      folderId: folderId,
      assetIds: assetIds,
      createdAt: now,
      updatedAt: now,
    );
    notes.put(note);
    return note;
  }

  void attachToNote(String noteId, String assetId) {
    final note = notes[noteId];
    if (note == null || note.assetIds.contains(assetId)) return;
    notes.put(note.copyWith(assetIds: [...note.assetIds, assetId]));
  }

  Note? noteByTitle(String title) {
    final lower = title.toLowerCase();
    for (final n in notes.all) {
      if (n.displayTitle.toLowerCase() == lower) return n;
    }
    return null;
  }

  /// Folder ids from the top level down to [folderId].
  List<Folder> folderPath(String? folderId) {
    final path = <Folder>[];
    var current = folders[folderId];
    final seen = <String>{};
    while (current != null && seen.add(current.id)) {
      path.insert(0, current);
      current = folders[current.parentId];
    }
    return path;
  }

  /// All folders depth-first, sorted by name, with their nesting depth.
  List<(Folder, int)> folderTree() {
    final children = <String?, List<Folder>>{};
    for (final f in folders.all) {
      final parent = folders.contains(f.parentId ?? '') ? f.parentId : null;
      children.putIfAbsent(parent, () => []).add(f);
    }
    final result = <(Folder, int)>[];
    void walk(String? parent, int depth) {
      final list = [...?children[parent]];
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      for (final f in list) {
        if (result.any((r) => r.$1.id == f.id)) continue; // cycle guard
        result.add((f, depth));
        walk(f.id, depth + 1);
      }
    }

    walk(null, 0);
    return result;
  }

  /// [folderId] and every folder nested inside it.
  Set<String> folderAndDescendants(String folderId) {
    final ids = {folderId};
    var grew = true;
    while (grew) {
      grew = false;
      for (final f in folders.all) {
        if (f.parentId != null && ids.contains(f.parentId) && ids.add(f.id)) {
          grew = true;
        }
      }
    }
    return ids;
  }

  Folder createFolder(String name, {String? parentId}) {
    final folder = Folder(
      id: newId(),
      name: name,
      parentId: parentId,
      updatedAt: DateTime.now(),
    );
    folders.put(folder);
    return folder;
  }

  /// Removes a folder; its notes and subfolders move up one level.
  void deleteFolder(String id) {
    final folder = folders[id];
    if (folder == null) return;
    for (final f in folders.all.where((f) => f.parentId == id).toList()) {
      folders.put(f.copyWith(parentId: () => folder.parentId));
    }
    for (final n in notes.all.where((n) => n.folderId == id).toList()) {
      notes.put(n.copyWith(folderId: () => folder.parentId));
    }
    folders.remove(id);
  }

  String folderLabel(String? folderId) {
    final path = folderPath(folderId);
    return path.isEmpty ? 'No folder' : path.map((f) => f.name).join(' / ');
  }

  // ------------------------------------------------------------- calendar --

  int activeCount(CalendarCategory category, {String? excludeId}) => entries.all
      .where((e) => e.category == category && !e.archived && e.id != excludeId)
      .length;

  bool hasRoomIn(CalendarCategory category, {String? excludeId}) =>
      activeCount(category, excludeId: excludeId) <
      CalendarEntry.maxActivePerCategory;

  /// Saves [entry], enforcing the five-active-entries rule.
  ///
  /// The limit applies when an entry *becomes* active (new, restored, or
  /// moved to another category). Editing an entry that is already active
  /// is always allowed, so a category that went over the limit through a
  /// sync merge (we warn rather than auto-archive) can still be edited.
  void saveEntry(CalendarEntry entry) {
    final existing = entries[entry.id];
    final becomesActive =
        !entry.archived &&
        (existing == null ||
            existing.archived ||
            existing.category != entry.category);
    if (becomesActive && !hasRoomIn(entry.category, excludeId: entry.id)) {
      throw CalendarLimitException(entry.category);
    }
    entries.put(entry);
  }

  /// Categories with more active entries than allowed (only possible after
  /// merging changes from several devices).
  List<CalendarCategory> get overLimitCategories => [
    for (final c in CalendarCategory.values)
      if (activeCount(c) > CalendarEntry.maxActivePerCategory) c,
  ];

  void setArchived(String id, bool archived) {
    final entry = entries[id];
    if (entry == null) return;
    saveEntry(entry.copyWith(archived: archived));
  }

  void toggleHabit(String id, DateTime day) {
    final entry = entries[id];
    if (entry == null) return;
    final key = dayKey(day);
    final checks = {...entry.checkoffs};
    if (!checks.remove(key)) checks.add(key);
    entries.put(entry.copyWith(checkoffs: checks));
  }

  DayRecord dayRecord(DateTime day) =>
      days[dayKey(day)] ??
      DayRecord(id: dayKey(day), updatedAt: DateTime.now());

  void saveDay(DayRecord record) =>
      record.isEmpty ? days.remove(record.id) : days.put(record);

  void attachToDay(DateTime day, String assetId) {
    final record = dayRecord(day);
    if (record.assetIds.contains(assetId)) return;
    saveDay(record.copyWith(assetIds: [...record.assetIds, assetId]));
  }

  void attachToEntry(String entryId, String assetId) {
    final entry = entries[entryId];
    if (entry == null || entry.assetIds.contains(assetId)) return;
    entries.put(entry.copyWith(assetIds: [...entry.assetIds, assetId]));
  }

  /// Entries and tasks on [day], optionally filtered.
  List<DayItem> itemsOn(
    DateTime day, {
    Set<CalendarCategory>? categories,
    Set<int>? colors,
    bool includeTasks = true,
  }) {
    final result = <DayItem>[];
    for (final e in entries.all) {
      if (e.archived) continue;
      if (categories != null && !categories.contains(e.category)) continue;
      if (colors != null && !colors.contains(e.colorIndex)) continue;
      if (e.occursOn(day)) result.add(EntryOnDay(e));
    }
    if (includeTasks) {
      for (final t in tasks.all) {
        final due = t.dueDate;
        if (due == null || t.done || daysBetween(due, day) != 0) continue;
        final color = projects[t.projectId]?.colorIndex ?? 9;
        if (colors != null && !colors.contains(color)) continue;
        result.add(TaskOnDay(t, color));
      }
    }
    int minutes(DayItem i) => switch (i) {
      EntryOnDay(:final entry) => entry.startMinutes ?? -1,
      TaskOnDay(:final task) => task.dueMinutes ?? 24 * 60,
    };
    result.sort((a, b) => minutes(a).compareTo(minutes(b)));
    return result;
  }

  /// Drag-and-drop on the grid: moves one occurrence or a task's due date.
  void moveDayItem(DayItem item, DateTime from, DateTime to) {
    switch (item) {
      case EntryOnDay(:final entry):
        entries.put(entry.movedOccurrence(from, to));
      case TaskOnDay(:final task):
        tasks.put(task.copyWith(dueDate: () => dateOnly(to)));
    }
  }

  // ---------------------------------------------------------------- tasks --

  Task createTask(
    String title, {
    String? projectId,
    String? parentId,
    DateTime? dueDate,
    bool isExam = false,
  }) {
    final now = DateTime.now();
    final task = Task(
      id: newId(),
      title: title,
      projectId: projectId,
      parentId: parentId,
      dueDate: dueDate,
      isExam: isExam,
      createdAt: now,
      updatedAt: now,
    );
    tasks.put(task);
    return task;
  }

  void toggleTask(String id) {
    final task = tasks[id];
    if (task == null) return;
    tasks.put(
      task.done
          ? task.copyWith(done: false, completedAt: () => null)
          : task.completed(),
    );
  }

  /// Deletes a task and its subtasks.
  void deleteTask(String id) {
    for (final sub in tasks.all.where((t) => t.parentId == id).toList()) {
      deleteTask(sub.id);
    }
    tasks.remove(id);
  }
}
