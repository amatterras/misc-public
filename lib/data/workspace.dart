import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'storage/transaction_log.dart';
import 'models/calendar_models.dart';
import 'models/canvas_models.dart' show newId;
import 'models/library_models.dart';
import 'models/record.dart';
import 'models/sync_models.dart';
import 'models/task_models.dart';
import 'models/smart_view_models.dart';
import 'repositories/record_collection.dart';
import 'storage/attachment_store.dart';
import 'storage/app_log.dart';
import 'storage/backup_service.dart';
import 'storage/json_file_store.dart';
import 'storage/storage_issue.dart';
import 'sync/sync_clock.dart';
import 'models/ai_models.dart';
import 'models/browser_models.dart';
import 'models/knowledge_models.dart';
import 'models/tag_models.dart';
import 'models/vault_models.dart';
import 'models/template_models.dart';
import 'models/calendar_sync_models.dart';
import 'models/object_library_models.dart';

class CalendarLimitException implements Exception {
  const CalendarLimitException(this.category);
  final CalendarCategory category;

  @override
  String toString() =>
      '${category.label} already has ${CalendarEntry.maxActivePerCategory} '
      'active entries. Archive one first.';
}

class CalendarEntryExpiredException implements Exception {
  const CalendarEntryExpiredException();

  @override
  String toString() => 'This calendar entry has permanently expired.';
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

/// An event from a connected Google / Outlook calendar (read-only here).
class ExternalOnDay extends DayItem {
  const ExternalOnDay(this.event);
  final ExternalEvent event;
  @override
  String get id => event.id;
  @override
  String get label => event.title.isEmpty ? '(no title)' : event.title;
  @override
  int get colorIndex => CalendarCategory.events.index;
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
  /// [clock] is replaceable in tests (e.g. a device whose clock is wrong).
  Workspace(this.root, {SyncClock? clock, DateTime Function()? now})
    : clock = clock ?? SyncClock(),
      _now = now ?? DateTime.now,
      store = JsonFileStore(root),
      attachments = AttachmentStore(root),
      backups = BackupService(root) {
    assets = _c('assets', Asset.fromJson);
    notes = _c('notes', Note.fromJson);
    folders = _c('folders', Folder.fromJson);
    inbox = _c('inbox', InboxItem.fromJson);
    calendarExpirations = _c(
      'calendar_entry_expirations',
      CalendarEntryExpiration.fromJson,
    );
    entries = _c('calendar_entries', CalendarEntry.fromJson);
    days = _c('calendar_days', DayRecord.fromJson);
    tasks = _c('tasks', Task.fromJson);
    projects = _c('projects', Project.fromJson);
    smartViews = _c('smart_views', SmartView.fromJson);
    conflicts = _c('conflicts', SyncConflict.fromJson);
    clipboard = _c('clipboard', ClipboardClip.fromJson);
    purges = _c('purges', PurgeMark.fromJson);
    archiveFolders = _c('archive_folders', Folder.fromJson);
    shares = _c('shares', ShareLink.fromJson);
    customTags = _c('custom_tags', CustomTag.fromJson);
    experiments = _c('thought_experiments', ThoughtExperiment.fromJson);
    // Private vault: ciphertext only (see vault_service.dart).
    vaultMeta = _c('vault_meta', VaultMeta.fromJson);
    vaultItems = _c('vault_items', VaultItem.fromJson);
    templates = _c('templates', ContentTemplate.fromJson);
    externalEvents = _c('external_events', ExternalEvent.fromJson);
    calendarLinks = _c('calendar_links', CalendarLink.fromJson);
    // AI conversations stay on this device (not in [syncCollections]).
    aiConversations = _c('ai_conversations', AiConversation.fromJson);
    // Browser records stay on this device too.
    bookmarks = _c('browser_bookmarks', Bookmark.fromJson);
    history = _c('browser_history', HistoryEntry.fromJson);
    sitePermissions = _c('browser_permissions', SitePermission.fromJson);
    libraryObjects = _c('library_objects', LibraryObject.fromJson);
    libraryRelations = _c('library_relations', LibraryRelation.fromJson);
    librarySpaces = _c('library_spaces', LibrarySpace.fromJson);
    libraryIndex = _c('library_index', LibraryIndexEntry.fromJson);
    libraryJobs = _c('library_jobs', LibraryProcessingJob.fromJson);
    // Version history stays on this device (not in [syncCollections]).
    noteVersions = _c('note_versions', NoteVersion.fromJson);
    notes.onReplace = _keepNoteVersion;
    // "Recently deleted" keeps what a person deleted, not housekeeping:
    // pruned note versions, browser history and clipboard clips are not
    // kept, and an expired calendar entry must stay gone (7-day purge).
    noteVersions.keepDeleted = (_) => false;
    history.keepDeleted = (_) => false;
    clipboard.keepDeleted = (_) => false;
    entries.keepDeleted = (id) =>
        !_expiredArchivedEntryIds.contains(id) &&
        calendarExpirations[id] == null;
    entries.addListener(_onEntriesChanged);
    calendarExpirations.addListener(_onCalendarExpirationsChanged);
  }

  final Directory root;
  final JsonFileStore store;
  final AttachmentStore attachments;
  final BackupService backups;

  late final RecordCollection<Asset> assets;
  late final RecordCollection<Note> notes;
  late final RecordCollection<NoteVersion> noteVersions;
  late final RecordCollection<Folder> folders;
  late final RecordCollection<InboxItem> inbox;
  late final RecordCollection<CalendarEntryExpiration> calendarExpirations;
  late final RecordCollection<CalendarEntry> entries;
  late final RecordCollection<DayRecord> days;
  late final RecordCollection<Task> tasks;
  late final RecordCollection<Project> projects;

  /// Saved Smart Views of the Calendar's Tasks column (filters only).
  late final RecordCollection<SmartView> smartViews;
  late final RecordCollection<SyncConflict> conflicts;

  /// Text shared between the user's devices (synced only while
  /// [shareClipboard] is on).
  late final RecordCollection<ClipboardClip> clipboard;
  late final RecordCollection<AiConversation> aiConversations;

  /// Records deleted for good (see PurgeMark): they sync, and an old copy or
  /// backup cannot bring them back.
  late final RecordCollection<PurgeMark> purges;
  late final RecordCollection<Bookmark> bookmarks;
  late final RecordCollection<HistoryEntry> history;
  late final RecordCollection<SitePermission> sitePermissions;
  late final RecordCollection<LibraryObject> libraryObjects;
  late final RecordCollection<LibraryRelation> libraryRelations;
  late final RecordCollection<LibrarySpace> librarySpaces;
  late final RecordCollection<LibraryIndexEntry> libraryIndex;
  late final RecordCollection<LibraryProcessingJob> libraryJobs;

  /// Archive folders (separate from note folders).
  late final RecordCollection<Folder> archiveFolders;

  /// Read-only share links served by the hub (see ShareLink).
  late final RecordCollection<ShareLink> shares;

  /// The user's own tags (Archive and Mindmap; see tag_models.dart).
  late final RecordCollection<CustomTag> customTags;
  late final RecordCollection<ThoughtExperiment> experiments;
  late final RecordCollection<VaultMeta> vaultMeta;
  late final RecordCollection<VaultItem> vaultItems;
  late final RecordCollection<ContentTemplate> templates;

  /// Google / Outlook events shown on the calendar, and THEapp entries
  /// exported there (see features/calendar/external).
  late final RecordCollection<ExternalEvent> externalEvents;
  late final RecordCollection<CalendarLink> calendarLinks;
  bool shareClipboard = false;

  /// The record collections that sync, by their protocol name.
  Map<String, RecordCollection> get syncCollections => {
    // Expiration locks must be pushed before calendar entries. The hub uses
    // these to reject stale writes before applying the accompanying tombstone.
    'calendar_entry_expirations': calendarExpirations,
    'assets': assets,
    'notes': notes,
    'folders': folders,
    'inbox': inbox,
    'calendar_entries': entries,
    'calendar_days': days,
    'tasks': tasks,
    'projects': projects,
    'conflicts': conflicts,
    'purges': purges,
    'archive_folders': archiveFolders,
    'shares': shares,
    'custom_tags': customTags,
    'smart_views': smartViews,
    'thought_experiments': experiments,
    'vault_meta': vaultMeta,
    'vault_items': vaultItems,
    'templates': templates,
    'external_events': externalEvents,
    'calendar_links': calendarLinks,
    'library_objects': libraryObjects,
    'library_relations': libraryRelations,
    'library_spaces': librarySpaces,
    'library_index': libraryIndex,
    'library_jobs': libraryJobs,
    if (shareClipboard) 'clipboard': clipboard,
  };

  final List<RecordCollection> _all = [];

  /// Every record collection by its file name, synced or not (backups,
  /// migrations and integrity checks look at all of them).
  Map<String, RecordCollection> get allCollections => {
    for (final c in _all) c.name: c,
  };

  /// Revision stamps for every change made on this device (see [SyncClock]).
  final SyncClock clock;
  final DateTime Function() _now;
  static const archivedEntryRetention = Duration(days: 7);
  Timer? _archivePurgeTimer;
  bool _normalizingArchiveTimestamps = false;
  final Set<String> _expiredArchivedEntryIds = {};
  final Set<String> _pendingArchiveBackupPurges = {};

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
    )..onSaveResult = _noteSaveResult;
    _all.add(c);
    return c;
  }

  /// Collections (and `canvas:<id>` documents) whose latest changes could
  /// not be saved yet (they keep retrying). Empty when everything is on disk.
  final ValueNotifier<Set<String>> unsaved = ValueNotifier(const {});

  /// What kind of problem keeps the changes in [unsaved] off the disk (the
  /// most serious one), or null when everything is saved. Shown in plain
  /// words by the unsaved notice ([unsavedNoticeText]).
  final ValueNotifier<StorageIssue?> saveIssue = ValueNotifier(null);
  final Map<String, StorageIssue> _issues = {};

  void _noteSaveResult(String name, bool saved) {
    Object? error;
    for (final c in _all) {
      if (c.name == name) error = c.lastSaveError;
    }
    noteSaveResult(name, saved, error);
  }

  /// Records the outcome of a save of [name] (a record collection, or
  /// `canvas:<id>` for a mindmap/notebook document), so the notice shows
  /// while anything is not on disk and says why.
  void noteSaveResult(String name, bool saved, [Object? error]) {
    if (saved) {
      _issues.remove(name);
    } else {
      _issues[name] = error == null
          ? StorageIssue.temporary
          : classifyStorageError(error);
    }
    final now = {...unsaved.value};
    final changed = saved ? now.remove(name) : now.add(name);
    if (changed) unsaved.value = now;
    saveIssue.value = worstIssue(_issues.values);
  }

  /// Fires when any record anywhere changes.
  late final Listenable changes = Listenable.merge(_all);

  /// All-or-nothing changes across several collections (see
  /// transaction_log.dart).
  late final TransactionLog txn = TransactionLog(store, allCollections);

  /// What the last start-up finished of an interrupted multi-record change.
  RecoveryReport lastRecovery = const RecoveryReport();

  /// Half-written files a crash left behind, removed by the last [load].
  int lastTempCleanup = 0;

  Future<void> load() async {
    // A crash in the middle of a save leaves its temporary file; the real
    // file and its previous version are untouched, so it is only clutter.
    try {
      lastTempCleanup = await store.removeInterruptedWrites();
    } catch (e) {
      AppLog.warn('Could not remove leftover temporary files ($e)');
    }
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
    lastRecovery = await txn.recover();
    await _loadExpiredArchiveLedger();
    _expiredArchivedEntryIds.addAll(
      calendarExpirations.all.map((expiration) => expiration.id),
    );
    _pendingArchiveBackupPurges.addAll(_expiredArchivedEntryIds);
    for (final id in _expiredArchivedEntryIds) {
      if (calendarExpirations[id] == null) {
        final at = _now().toUtc();
        calendarExpirations.put(
          CalendarEntryExpiration(id: id, expiredAt: at, updatedAt: at),
        );
      }
    }
    _removeExpiredLedgerEntries();
    _backfillArchiveTimestamps();
    await purgeExpiredArchivedEntries();
    await _purgeExpiredEntriesFromBackups();
    _scheduleArchivePurge();
    _wirePurges();
    _enforcePurges();
    await _purgePurgedFromBackups();
  }

  // ----------------------------------------------------------- purges --
  //
  // Deleting for good (as opposed to an ordinary, undoable deletion): the
  // record leaves active storage and "recently deleted", the links that shared
  // it stop and are blanked, its attachment files (if nothing else uses them)
  // and every copy in the app's own backups go, and a permanent mark travels
  // to the other devices and the hub, which also drops the record's old
  // versions from its journal and its backups and refuses to take the record
  // back. That is the logical removal of every copy THEapp manages. It is
  // not forensic erasure: a disk or operating system may keep traces, and
  // copies made outside THEapp (exports, shares already read, copies on a
  // device that is switched off) are out of its reach.

  bool _purgesWired = false;
  final Set<String> _pendingPurgeBackups = {};

  void _wirePurges() {
    if (_purgesWired) return;
    _purgesWired = true;
    for (final c in _all) {
      if (c == purges) continue;
      c.isPurged = (id) => purges.contains('${c.name}.$id');
    }
    purges.addListener(() {
      _enforcePurges();
      unawaited(_purgePurgedFromBackups());
    });
  }

  /// Deletes [id] of [collection] for good.
  Future<void> purgeRecord(String collection, String id) async {
    final c = allCollections[collection];
    if (c == null || collection == 'purges') {
      throw ArgumentError('Cannot purge from "$collection"');
    }
    _wirePurges();
    final blobs = <String>[];
    if (collection == 'assets') {
      // The sealed copies of its files on the hub (named in the sync table,
      // or in the record when it came from another device).
      final table =
          ((await store.read('sync', 'blobs'))?['blobs'] as Map?) ?? const {};
      final a = assets[id];
      final json = c.jsonOf(id);
      for (final (sha, key) in [
        (a?.fileSha256, 'fileBlob'),
        (a?.previewSha256, 'previewBlob'),
      ]) {
        final b = (sha == null ? null : table[sha]) ?? json?[key];
        if (b is String) blobs.add(b);
      }
    }
    purges.put(
      PurgeMark(
        collection: collection,
        recordId: id,
        at: _now().toUtc(),
        blobs: blobs,
      ),
    );
    _enforcePurges();
    await _flushRetentionState();
    await purges.flush();
    await _purgePurgedFromBackups();
  }

  /// What deleting [mark]'s record for good takes with it besides the record:
  /// (collection, id) pairs of records that exist only because of it.
  List<(String, String)> _dependentsOf(PurgeMark mark) => [
    if (mark.collection == 'notes')
      // The note's saved earlier versions are its content too.
      for (final v in noteVersions.all)
        if (v.noteId == mark.recordId) ('note_versions', v.id),
  ];

  void _enforcePurges() {
    for (final mark in purges.all.toList()) {
      final c = allCollections[mark.collection];
      if (c == null) continue;
      final files = <String>[];
      if (mark.collection == 'assets') {
        final a = assets[mark.recordId];
        if (a != null) {
          files.addAll([?a.file, ?a.previewFile]);
        }
      }
      if (c.contains(mark.recordId)) {
        c.remove(mark.recordId, recoverable: false);
      }
      c.forgetDeleted(mark.recordId);
      for (final (collection, id) in _dependentsOf(mark)) {
        final d = allCollections[collection];
        if (d == null) continue;
        if (d.contains(id)) d.remove(id, recoverable: false);
        d.forgetDeleted(id);
        _purgedDependents.putIfAbsent(collection, () => {}).add(id);
      }
      for (final link in shares.all.toList()) {
        if (link.sourceId == mark.recordId && link.title.isNotEmpty) {
          shares.put(link.scrubbed());
        }
      }
      // Attachment files nothing else points at.
      for (final name in files) {
        final used = assets.all.any(
          (x) => x.file == name || x.previewFile == name,
        );
        if (!used) {
          try {
            final f = attachments.fileFor(name);
            if (f.existsSync()) f.deleteSync();
          } on FileSystemException {
            // Left over: removed with the next purge pass.
          }
          _purgedAttachmentFiles.add(name);
        }
      }
      _pendingPurgeBackups.add(mark.id);
    }
  }

  final Set<String> _purgedAttachmentFiles = {};
  final Map<String, Set<String>> _purgedDependents = {};

  Future<void>? _purgeRunning;

  /// One pass at a time: the listener and an explicit purge can ask together,
  /// and two passes rewriting the same backup files would corrupt them.
  /// (No future is made ahead of time: one made in another zone, e.g. a test's
  /// fake clock, could never be waited for from here.)
  Future<void> _purgePurgedFromBackups() async {
    while (_purgeRunning != null) {
      await _purgeRunning;
    }
    final run = _purgeRunning = _purgeBackupsNow();
    try {
      await run;
    } finally {
      _purgeRunning = null;
    }
  }

  Future<void> _purgeBackupsNow() async {
    if (_pendingPurgeBackups.isEmpty) return;
    final records = <String, Map<String, String>>{};
    for (final markId in _pendingPurgeBackups.toList()) {
      final mark = purges[markId];
      if (mark == null) {
        _pendingPurgeBackups.remove(markId);
        continue;
      }
      final c = allCollections[mark.collection];
      var rev = c?.tombstones[mark.recordId];
      if (c != null && rev == null) {
        rev = clock.now();
        c.applyRemote(mark.recordId, rev, null);
      }
      (records[mark.collection] ??= {})[mark.recordId] = rev ?? clock.now();
      // The links that shared it: their snapshot of its text is in the
      // backups too (the live links are already revoked and blanked).
      for (final link in shares.all) {
        if (link.sourceId == mark.recordId) {
          (records['shares'] ??= {})[link.id] = clock.now();
        }
      }
    }
    for (final MapEntry(key: collection, value: ids)
        in _purgedDependents.entries) {
      final c = allCollections[collection];
      for (final id in ids) {
        (records[collection] ??= {})[id] = c?.tombstones[id] ?? clock.now();
      }
    }
    if (records.isEmpty) return;
    // The previous-version copies (.bak) of the live files lose it too.
    final touched = {for (final r in records.keys) r, 'shares'};
    for (final name in touched) {
      await allCollections[name]?.refreshBackup();
    }
    try {
      await backups.purgeRecords(
        records: records,
        attachmentFiles: _purgedAttachmentFiles.toList(),
      );
      _pendingPurgeBackups.clear();
    } catch (error, stack) {
      // The mark still prevents a restore; the backups are cleaned on the
      // next start.
      AppLog.error(
        'Removing a purged record from backups failed',
        error,
        stack,
      );
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

  /// A deleted canvas came back (restored here, or by a newer change from
  /// another device): stop announcing its deletion.
  Future<void> forgetCanvasDeletion(String canvasId) async {
    if (canvasTombstones.remove(canvasId) == null) return;
    await store.write('sync', 'canvas_tombstones', {
      'schema': 1,
      'tombstones': canvasTombstones,
    });
  }

  /// Newest schema among the record files as loaded.
  int get newestRecordSchema => _all.isEmpty
      ? 0
      : _all.map((c) => c.loadedSchema).reduce((a, b) => a > b ? a : b);

  /// Whether any record (note, task, link, entry, …) exists.
  bool get hasRecords => _all.any((c) => c.length > 0);

  /// Oldest schema among the record files as loaded (for migrations).
  int get oldestRecordSchema => _all.isEmpty
      ? RecordCollection.schemaVersion
      : _all.map((c) => c.loadedSchema).reduce((a, b) => a < b ? a : b);

  Future<void> flush() async {
    for (final c in _all) {
      await c.flush();
    }
    await store.flush();
    await _purgeExpiredEntriesFromBackups();
  }

  void dispose() {
    _archivePurgeTimer?.cancel();
    entries.removeListener(_onEntriesChanged);
    calendarExpirations.removeListener(_onCalendarExpirationsChanged);
    for (final c in _all) {
      c.dispose();
    }
  }

  // --------------------------------------------------------------- assets --

  /// Comparison form of a link: spellings of the same address
  /// (`HTTPS://Example.com:443` and `https://example.com/`) match. Paths,
  /// queries and fragments are kept as they are (they can be case-sensitive).
  static String linkKey(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || u.host.isEmpty) return url.trim();
    final defaultPort =
        (u.scheme == 'https' && u.port == 443) ||
        (u.scheme == 'http' && u.port == 80);
    final port = u.hasPort && !defaultPort ? ':${u.port}' : '';
    final path = u.path.isEmpty ? '/' : u.path;
    return '${u.scheme.toLowerCase()}://${u.host.toLowerCase()}$port$path'
        '${u.hasQuery ? '?${u.query}' : ''}'
        '${u.hasFragment ? '#${u.fragment}' : ''}';
  }

  /// Returns the existing link asset for [url] or creates one, so the same
  /// link captured twice is still one record.
  Asset linkAsset(String url, {String? title}) {
    final key = linkKey(url);
    for (final a in assets.all) {
      if (a.kind == AssetKind.link && a.url != null && linkKey(a.url!) == key) {
        return a;
      }
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

  /// File types retained as Archive documents. Quick Look opens the formats
  /// supported by iOS; all listed originals remain byte-for-byte attachments.
  static const documentExtensions = {
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'rtf',
    'txt',
    'md',
    'csv',
    'epub',
    'pages',
    'numbers',
    'key',
    'zip',
    'mov',
    'mp4',
    'm4v',
    'avi',
    'mkv',
    'mp3',
    'm4a',
    'wav',
    'aac',
    'heic',
    'heif',
    'json',
    'xml',
    'html',
    'htm',
    'eml',
    'ics',
    'vcf',
    'psd',
    'ai',
    'tar',
    'gz',
    '7z',
  };

  /// Copies a supported document/media file into attachments and records it
  /// by its original filename.
  Future<Asset> documentAssetFromFile(File file) async {
    final ext = AttachmentStore.extensionOf(file.path);
    if (!documentExtensions.contains(ext)) {
      throw ArgumentError('Not a supported document: .$ext');
    }
    final name = await attachments.importFile(file);
    final now = DateTime.now();
    final asset = Asset(
      id: newId(),
      kind: AssetKind.document,
      file: name,
      title: file.uri.pathSegments.last,
      createdAt: now,
      updatedAt: now,
    );
    assets.put(asset);
    return asset;
  }

  /// The stored file of a document asset, or null if it is not one, is
  /// missing (e.g. not synced yet), or lies outside the attachments folder.
  File? documentFile(Asset asset) {
    final name = asset.file;
    if (asset.kind != AssetKind.document || name == null) return null;
    if (name.contains('/') || name.contains(r'\') || name.contains('..')) {
      return null;
    }
    if (!documentExtensions.contains(AttachmentStore.extensionOf(name))) {
      return null;
    }
    // A readable copy for the native viewer (a decrypted view copy when the
    // stored file is encrypted).
    return attachments.viewFile(name);
  }

  Future<Asset> imageAssetFromBytes(Uint8List bytes, String extension) async {
    final name = await attachments.importBytes(bytes, extension);
    return _imageAsset(name);
  }

  Future<Asset> _imageAsset(String fileName) async {
    final size = await imageSizeOfBytes(await attachments.readBytes(fileName));
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
      return await imageSizeOfBytes(await file.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Size?> imageSizeOfBytes(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
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

  // ------------------------------------------------------ version history --

  /// Edits within this long of the last kept version count as one session,
  /// so typing does not create a version per keystroke.
  static const versionInterval = Duration(minutes: 10);

  /// Versions kept per note (oldest go first).
  static const versionsPerNote = 30;

  /// Current time; replaceable in tests.
  DateTime Function() now = DateTime.now;

  /// Earlier versions of [noteId], newest first.
  List<NoteVersion> versionsOf(String noteId) =>
      noteVersions.all.where((v) => v.noteId == noteId).toList()
        ..sort((a, b) => b.savedAt.compareTo(a.savedAt));

  void _keepNoteVersion(Note previous, Note next) {
    if (previous.title == next.title && previous.body == next.body) return;
    if (previous.title.isEmpty && previous.body.isEmpty) return;
    final versions = versionsOf(previous.id);
    final latest = versions.firstOrNull;
    if (latest != null &&
        now().difference(latest.savedAt) < versionInterval &&
        latest.body != next.body) {
      // Still the same editing session: the version kept at its start
      // already holds the text from before it. (Going back to exactly that
      // version — a restore — always keeps the replaced text, so a restore
      // can itself be undone.)
      return;
    }
    noteVersions.put(
      NoteVersion(
        id: newId(),
        noteId: previous.id,
        title: previous.title,
        body: previous.body,
        savedAt: now(),
      ),
    );
    for (final old in versions.skip(versionsPerNote - 1)) {
      noteVersions.remove(old.id);
    }
  }

  /// Deletes a note, first keeping all of it (text, folder, tags,
  /// attachments) as a version, so it can be restored from Recently deleted.
  void deleteNote(String id) {
    final note = notes[id];
    if (note == null) return;
    // One all-or-nothing change: the kept version and the deletion are
    // never saved separately (a crash cannot leave a note deleted without
    // its version, or the other way round).
    unawaited(
      txn
          .run('Delete note', (tx) {
            tx.put(
              noteVersions,
              NoteVersion(
                id: newId(),
                noteId: id,
                title: note.title,
                body: note.body,
                savedAt: now(),
                deleted: true,
                folderId: note.folderId,
                tags: note.tags,
                favorite: note.favorite,
                assetIds: note.assetIds,
                paper: note.paper,
              ),
            );
            tx.remove(notes, id);
          })
          .catchError((Object e, StackTrace s) {
            AppLog.error('Deleting a note was not saved completely', e, s);
          }),
    );
  }

  /// Deleted notes that can be restored (newest deletion first): the latest
  /// kept version of each note that no longer exists.
  List<NoteVersion> deletedNotes() {
    final latest = <String, NoteVersion>{};
    for (final v in noteVersions.all) {
      if (notes.contains(v.noteId)) continue;
      final seen = latest[v.noteId];
      if (seen == null || v.savedAt.isAfter(seen.savedAt)) latest[v.noteId] = v;
    }
    return latest.values.toList()
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
  }

  /// Puts an earlier version back as a new edit (so the replaced text
  /// becomes a version itself). Also brings back a deleted note, with its
  /// folder, tags and attachments when the version kept them.
  Note? restoreNoteVersion(String versionId) {
    final v = noteVersions[versionId];
    if (v == null) return null;
    final current = notes[v.noteId];
    final restored = current != null
        ? current.copyWith(title: v.title, body: v.body)
        : Note(
            id: v.noteId,
            title: v.title,
            body: v.body,
            createdAt: v.savedAt,
            updatedAt: now(),
            folderId: v.folderId != null && folders.contains(v.folderId!)
                ? v.folderId
                : null,
            tags: v.tags,
            favorite: v.favorite,
            assetIds: v.assetIds,
            paper: v.paper,
          );
    notes.put(restored);
    return restored;
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

  // -------------------------------------------------------- custom tags --
  //
  // One registry for the Archive and the Mindmap (tag_models.dart).

  /// Every tag, by name.
  List<CustomTag> get tagsByName => customTags.all.toList()
    ..sort(
      (a, b) => CustomTag.keyOf(a.name).compareTo(CustomTag.keyOf(b.name)),
    );

  /// The tag called [name] (same letters in any case), if any.
  CustomTag? tagNamed(String name) {
    final key = CustomTag.keyOf(name);
    for (final t in customTags.all) {
      if (CustomTag.keyOf(t.name) == key) return t;
    }
    return null;
  }

  /// Creates a tag; a tag with the same name is reused instead of making
  /// a second one. Throws [ArgumentError] for an empty or too long name.
  ({CustomTag tag, bool existed}) createTag(String name, int color) {
    final problem = CustomTag.problemWith(name);
    if (problem != null) throw ArgumentError(problem);
    final existing = tagNamed(name);
    if (existing != null) return (tag: existing, existed: true);
    if (customTags.all.length >= CustomTag.maxTags) {
      throw ArgumentError(
        'You can have at most ${CustomTag.maxTags} tags. '
        'Delete one to make another.',
      );
    }
    final now = DateTime.now();
    final tag = CustomTag(
      id: newId(),
      name: CustomTag.clean(name),
      color: color,
      createdAt: now,
      updatedAt: now,
    );
    customTags.put(tag);
    return (tag: tag, existed: false);
  }

  /// Renames tag [id]; returns why it cannot be done, or null.
  String? renameTag(String id, String name) {
    final tag = customTags[id];
    if (tag == null) return 'That tag is gone.';
    final problem = CustomTag.problemWith(name);
    if (problem != null) return problem;
    final other = tagNamed(name);
    if (other != null && other.id != id) {
      return 'There is already a tag called “${other.name}”.';
    }
    customTags.put(tag.copyWith(name: CustomTag.clean(name)));
    return null;
  }

  void recolorTag(String id, int color) {
    final tag = customTags[id];
    if (tag != null && tag.color != color) {
      customTags.put(tag.copyWith(color: color));
    }
  }

  /// Deletes tag [id]: it is taken off every Archive resource (the
  /// resources themselves stay). Mindmap items that still name it simply
  /// no longer show it. Returns how many resources had it.
  int deleteTag(String id) {
    final ref = CustomTag.assetRef(id);
    var n = 0;
    for (final a in assets.all.toList()) {
      if (!a.linkTags.contains(ref)) continue;
      assets.put(a.copyWith(linkTags: [...a.linkTags]..remove(ref)));
      n++;
    }
    // Library objects lose it too (the objects themselves stay).
    for (final r in libraryRelations.all.toList()) {
      if (r.kind == 'tag' && r.targetId == ref) {
        libraryRelations.remove(r.id);
        n++;
      }
    }
    customTags.remove(id);
    return n;
  }

  /// The custom tags on resource [a] that still exist, by name.
  List<CustomTag> tagsOfAsset(Asset a) => [
    for (final ref in a.linkTags)
      if (CustomTag.idOfAssetRef(ref) case final id?) ?customTags[id],
  ]..sort((x, y) => CustomTag.keyOf(x.name).compareTo(CustomTag.keyOf(y.name)));

  /// Sets the custom tags of resource [assetId] to [tagIds]; its fixed
  /// categories (and anything unknown) are kept as they are.
  void setAssetTags(String assetId, Set<String> tagIds) {
    final a = assets[assetId];
    if (a == null) return;
    final next = [
      for (final ref in a.linkTags)
        if (CustomTag.idOfAssetRef(ref) == null) ref,
      for (final id in tagIds)
        if (customTags[id] != null) CustomTag.assetRef(id),
    ];
    if (next.length == a.linkTags.length &&
        next.toSet().containsAll(a.linkTags)) {
      return;
    }
    assets.put(a.copyWith(linkTags: next));
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
      .where(
        (e) =>
            e.category == category &&
            !e.archived &&
            e.id != excludeId &&
            !(category == CalendarCategory.reading && e.readingPlanId != null),
      )
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
    if (_expiredArchivedEntryIds.contains(entry.id)) {
      throw const CalendarEntryExpiredException();
    }
    final existing = entries[entry.id];
    final becomesActive =
        !entry.archived &&
        (existing == null ||
            existing.archived ||
            existing.category != entry.category);
    if (becomesActive && !hasRoomIn(entry.category, excludeId: entry.id)) {
      throw CalendarLimitException(entry.category);
    }
    final saved = !entry.archived
        ? entry.copyWith(archivedAt: () => null)
        : entry.copyWith(
            archivedAt: () =>
                entry.archivedAt ?? existing?.archivedAt ?? _now().toUtc(),
          );
    entries.put(saved);
  }

  /// Saves a Reading series and ensures one stable, independently editable
  /// entry exists for every inclusive local calendar date in its range.
  /// Existing pages are never replaced. Removed dates are detached instead
  /// of deleted, so their notes remain available in the Reading list.
  void saveReadingPlan(CalendarEntry series) {
    if (series.category != CalendarCategory.reading) {
      throw ArgumentError.value(series.category, 'category', 'Must be Reading');
    }
    final start = series.readingPlanStartDate;
    final end = series.readingPlanEndDate;
    if ((start == null) != (end == null)) {
      throw ArgumentError('Choose both a start and end date for the plan.');
    }
    if (start != null && end != null && daysBetween(start, end) < 0) {
      throw ArgumentError('The end date must be on or after the start date.');
    }
    // Validate the entire range before writing the parent or any occurrence.
    final dates = <DateTime>[];
    if (start != null && end != null) {
      for (
        var day = dateOnly(start);
        daysBetween(day, end) >= 0;
        day = addDays(day, 1)
      ) {
        dates.add(day);
        if (dates.length > 3660) {
          throw ArgumentError('A reading plan can span at most ten years.');
        }
      }
    }
    saveEntry(series);
    final expected = <String>{};
    for (final day in dates) {
      final key = dayKey(day);
      final id = '${series.id}/$key';
      expected.add(id);
      final existing = entries[id];
      if (existing == null) {
        entries.put(
          CalendarEntry(
            id: id,
            category: CalendarCategory.reading,
            name: '${series.name} · $key',
            createdAt: _now(),
            updatedAt: _now(),
            readingPlanId: series.id,
            readingPlanDate: day,
          ),
        );
      } else if (existing.readingPlanId == series.id &&
          existing.readingPlanDetached) {
        // Re-including a date reattaches the same page, preserving its content.
        entries.put(existing.copyWith(readingPlanDetached: false));
      }
    }
    for (final page in entries.all) {
      if (page.readingPlanId == series.id &&
          !expected.contains(page.id) &&
          !page.readingPlanDetached) {
        entries.put(page.copyWith(readingPlanDetached: true));
      }
    }
  }

  /// Permanently removes archived calendar entries whose seven-day retention
  /// has elapsed. [RecordCollection.remove] creates a sync tombstone, so an
  /// offline or stale device cannot bring an expired entry back.
  Future<List<String>> purgeExpiredArchivedEntries({DateTime? now}) async {
    final cutoff = (now ?? _now()).toUtc();
    final expired = [
      for (final entry in entries.all)
        if (entry.archived &&
            entry.archivedAt != null &&
            !entry.archivedAt!
                .toUtc()
                .add(archivedEntryRetention)
                .isAfter(cutoff))
          entry.id,
    ];
    if (expired.isNotEmpty) {
      _expiredArchivedEntryIds.addAll(expired);
      _pendingArchiveBackupPurges.addAll(expired);
      await _saveExpiredArchiveLedger();
      final instant = (now ?? _now()).toUtc();
      for (final entry in entries.all.where(
        (entry) => expired.contains(entry.id),
      )) {
        final expires = entry.archivedAt!.toUtc().add(archivedEntryRetention);
        calendarExpirations.put(
          CalendarEntryExpiration(
            id: entry.id,
            expiredAt: expires,
            updatedAt: instant,
          ),
        );
      }
    }
    final allDeleted = {..._expiredArchivedEntryIds, ...expired};
    for (final id in allDeleted) {
      entries.remove(id, recoverable: false);
    }
    await _flushRetentionState();
    await _purgeExpiredEntriesFromBackups();
    _scheduleArchivePurge();
    return expired;
  }

  Future<void> _flushRetentionState() async {
    await calendarExpirations.flush();
    await entries.flush();
    await store.flush();
  }

  Future<void> _purgeExpiredEntriesFromBackups() async {
    for (final id in _pendingArchiveBackupPurges.toList()) {
      var rev = entries.tombstones[id];
      if (rev == null) {
        rev = clock.now();
        entries.applyRemote(id, rev, null);
      }
      try {
        await backups.purgeExpiredCalendarEntry(id: id, tombstoneRev: rev);
        _pendingArchiveBackupPurges.remove(id);
      } catch (error, stack) {
        // The durable local ledger and sync expiration record still prevent
        // restoration. Retry backup sanitation next time the workspace opens.
        AppLog.error(
          'Purging expired calendar entry from backups failed',
          error,
          stack,
        );
      }
    }
  }

  void _onEntriesChanged() {
    _pendingArchiveBackupPurges.addAll(_expiredArchivedEntryIds);
    _removeExpiredLedgerEntries();
    if (!_normalizingArchiveTimestamps) _backfillArchiveTimestamps();
    _scheduleArchivePurge();
  }

  void _onCalendarExpirationsChanged() {
    final before = _expiredArchivedEntryIds.length;
    _expiredArchivedEntryIds.addAll(
      calendarExpirations.all.map((expiration) => expiration.id),
    );
    if (_expiredArchivedEntryIds.length == before) return;
    _pendingArchiveBackupPurges.addAll(_expiredArchivedEntryIds);
    unawaited(
      _saveExpiredArchiveLedger().catchError((error, stack) {
        AppLog.error('Saving calendar expiration ledger failed', error, stack);
      }),
    );
    _removeExpiredLedgerEntries();
  }

  Future<void> _loadExpiredArchiveLedger() async {
    final ledger = await store.read('retention', 'expired_calendar_entries');
    if (ledger == null) return;
    if (ledger['schema'] != 1 || ledger['ids'] is! List) {
      throw const FormatException('Invalid calendar archive retention ledger.');
    }
    _expiredArchivedEntryIds
      ..clear()
      ..addAll((ledger['ids'] as List).whereType<String>());
  }

  Future<void> _saveExpiredArchiveLedger() async {
    final ids = _expiredArchivedEntryIds.toList()..sort();
    await store.write('retention', 'expired_calendar_entries', {
      'schema': 1,
      'ids': ids,
    });
  }

  void _removeExpiredLedgerEntries() {
    for (final id in _expiredArchivedEntryIds) {
      if (entries.contains(id)) entries.remove(id, recoverable: false);
      if (entries.recentlyDeleted.containsKey(id)) entries.forgetDeleted(id);
    }
  }

  /// Old archived records have no reliable original archive time. Start
  /// their seven-day clock when this version first encounters them, rather
  /// than guessing from their last edit and unexpectedly deleting data.
  void _backfillArchiveTimestamps() {
    if (_normalizingArchiveTimestamps) return;
    final legacy = entries.all
        .where((entry) => entry.archived && entry.archivedAt == null)
        .toList();
    if (legacy.isEmpty) return;
    _normalizingArchiveTimestamps = true;
    try {
      final at = _now().toUtc();
      for (final entry in legacy) {
        entries.put(entry.copyWith(archivedAt: () => at));
      }
    } finally {
      _normalizingArchiveTimestamps = false;
    }
  }

  void _scheduleArchivePurge() {
    _archivePurgeTimer?.cancel();
    DateTime? next;
    for (final entry in entries.all) {
      final archivedAt = entry.archivedAt;
      if (!entry.archived || archivedAt == null) continue;
      final expiration = archivedAt.toUtc().add(archivedEntryRetention);
      if (next == null || expiration.isBefore(next)) next = expiration;
    }
    if (next == null) return;
    final delay = next.difference(_now().toUtc());
    _archivePurgeTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      unawaited(
        purgeExpiredArchivedEntries().catchError((
          Object error,
          StackTrace stack,
        ) {
          AppLog.error(
            'Purging expired calendar archives failed',
            error,
            stack,
          );
          return <String>[];
        }),
      );
    });
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

  /// Toggles completion for one occurrence of any local calendar entry.
  /// The date key keeps recurring and multi-day entries independent per day.
  void toggleEntryCompletion(String id, DateTime day) {
    final entry = entries[id];
    if (entry == null || entry.archived || !entry.occursOn(day)) return;
    final key = dayKey(day);
    final checks = {...entry.checkoffs};
    if (!checks.remove(key)) checks.add(key);
    entries.put(entry.copyWith(checkoffs: checks));
  }

  /// Compatibility name used by older Habit controls.
  void toggleHabit(String id, DateTime day) => toggleEntryCompletion(id, day);

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

  /// Entries and tasks on [day], optionally filtered: [categories] (the
  /// Calendar's only category filter; external events count as Events)
  /// and [includeTasks] (task cards, independent of the categories).
  List<DayItem> itemsOn(
    DateTime day, {
    Set<CalendarCategory>? categories,
    bool includeTasks = true,
  }) {
    final result = <DayItem>[];
    for (final e in entries.all) {
      if (e.archived) continue;
      if (categories != null && !categories.contains(e.category)) continue;
      if (e.occursOn(day)) result.add(EntryOnDay(e));
    }
    if (includeTasks) {
      for (final t in tasks.all) {
        // Done tasks stay on their day (shown ticked), like in Tasks.
        final due = t.dueDate;
        if (due == null || daysBetween(due, day) != 0) continue;
        result.add(TaskOnDay(t, CalendarCategory.events.index));
      }
    }
    for (final x in externalEvents.all) {
      if (categories != null && !categories.contains(CalendarCategory.events)) {
        break;
      }
      if (x.occursOn(day)) result.add(ExternalOnDay(x));
    }
    int minutes(DayItem i) => switch (i) {
      EntryOnDay(:final entry) => entry.startMinutes ?? -1,
      TaskOnDay(:final task) => task.dueMinutes ?? 24 * 60,
      ExternalOnDay(:final event) => event.startMinutes ?? -1,
    };
    bool done(DayItem i) => i is TaskOnDay && i.task.done;
    // Open items first (by time), finished tasks after them.
    result.sort((a, b) {
      if (done(a) != done(b)) return done(a) ? 1 : -1;
      return minutes(a).compareTo(minutes(b));
    });
    return result;
  }

  /// Drag-and-drop on the grid: moves one occurrence or a task's due date
  /// (an undated task, [from] null, gets [to] as its date).
  void moveDayItem(DayItem item, DateTime? from, DateTime to) {
    switch (item) {
      case EntryOnDay(:final entry):
        if (from == null) return;
        entries.put(entry.movedOccurrence(from, to));
      case TaskOnDay(:final task):
        // A recurring task: only this occurrence moves.
        tasks.put(task.movedOccurrence(to));
      case ExternalOnDay():
        return; // changed in Google / Outlook, not here
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

  /// Whether entry [id] can move to [to] (see [changeEntryCategory]).
  bool canChangeEntryCategory(String id, CalendarCategory to) {
    final entry = entries[id];
    return entry != null &&
        entry.category != to &&
        entry.category != CalendarCategory.reading &&
        to != CalendarCategory.reading &&
        hasRoomIn(to);
  }

  /// Moves entry [id] to category [to], keeping its id, name, notes, time,
  /// attachments and check-offs, and keeping it on [day]: each category
  /// schedules differently (Events: a date range; Other: chosen dates;
  /// Habits: from a start date on its weekdays), so the new schedule starts
  /// from [day]. Reading is left out both ways: its pages, logs and plans
  /// have no counterpart elsewhere. False when not allowed (see
  /// [canChangeEntryCategory]); the five-active rule still applies.
  bool changeEntryCategory(String id, CalendarCategory to, DateTime day) {
    if (!canChangeEntryCategory(id, to)) return false;
    final entry = entries[id]!;
    final d = dateOnly(day);
    saveEntry(switch (to) {
      CalendarCategory.events => entry.copyWith(
        category: to,
        colorIndex: to.index,
        startDate: () => d,
        endDate: () => d,
      ),
      CalendarCategory.other => entry.copyWith(
        category: to,
        colorIndex: to.index,
        dates: {dayKey(d)},
      ),
      CalendarCategory.habits => entry.copyWith(
        category: to,
        colorIndex: to.index,
        startDate: () => d,
        endDate: () => null,
      ),
      CalendarCategory.reading => entry,
    });
    return true;
  }

  /// A copy of calendar entry [id] (same category, schedule and details)
  /// with a new id and no completion history. Null when the entry is gone
  /// or its category already has five active entries (see [saveEntry]).
  CalendarEntry? duplicateEntry(String id) {
    final entry = entries[id];
    if (entry == null || !hasRoomIn(entry.category)) return null;
    final now = DateTime.now();
    final json = {
      ...entry.toJson(),
      'id': newId(),
      'name': '${entry.name} (copy)',
      'archived': false,
      'archivedAt': null,
      'checkoffs': const <String>[],
      'readingLog': const <String, int>{},
      'createdAt': utcIso(now),
      'updatedAt': utcIso(now),
    };
    // A copy stands alone: it is not part of a reading plan.
    for (final k in [...json.keys.where((k) => k.startsWith('readingPlan'))]) {
      json[k] = null;
    }
    final copy = CalendarEntry.fromJson(json);
    saveEntry(copy);
    return copy;
  }

  /// A copy of task [id] (same details, estimate included) with a new id,
  /// not done. Null when the task is gone.
  Task? duplicateTask(String id) {
    final task = tasks[id];
    if (task == null) return null;
    final now = DateTime.now();
    final copy = Task.fromJson({
      ...task.toJson(),
      'id': newId(),
      'title': '${task.title} (copy)',
      'done': false,
      'completedAt': null,
      'createdAt': utcIso(now),
      'updatedAt': utcIso(now),
    });
    tasks.put(copy);
    return copy;
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

  /// Tasks that link note [noteId] (the note's incoming task links).
  List<Task> tasksForNote(String noteId) => [
    for (final t in tasks.all)
      if (t.noteIds.contains(noteId)) t,
  ];

  /// Notes that belong to project [projectId].
  List<Note> notesOfProject(String projectId) => [
    for (final n in notes.all)
      if (n.projectIds.contains(projectId)) n,
  ];

  /// Other notes whose title appears in [note]'s text but is not linked
  /// with [[…]] yet: link suggestions (the text is never changed without
  /// the user choosing one).
  List<Note> mentionedNotes(Note note) {
    // Text outside [[…]] links.
    final plain = note.body
        .replaceAll(RegExp(r'\[\[[^\[\]]*\]\]'), ' ')
        .toLowerCase();
    if (plain.trim().isEmpty) return const [];
    final linked = {for (final t in note.linkedTitles) t.toLowerCase()};
    return [
      for (final other in notes.all)
        if (other.id != note.id &&
            other.title.trim().length >= 3 &&
            !linked.contains(other.displayTitle.toLowerCase()) &&
            RegExp(
              '(^|[^\\p{L}\\p{N}])${RegExp.escape(other.displayTitle.toLowerCase())}(\$|[^\\p{L}\\p{N}])',
              unicode: true,
            ).hasMatch(plain))
          other,
    ];
  }

  /// Turns the first unlinked mention of [title] in note [noteId] into a
  /// [[link]], keeping the text as typed. False if there is none.
  bool linkMention(String noteId, String title) {
    final note = notes[noteId];
    if (note == null) return false;
    final pattern = RegExp(
      '(\\[\\[[^\\[\\]]*\\]\\])|(?<![\\p{L}\\p{N}])(${RegExp.escape(title)})(?![\\p{L}\\p{N}])',
      caseSensitive: false,
      unicode: true,
    );
    for (final m in pattern.allMatches(note.body)) {
      if (m.group(1) != null) continue; // inside an existing link
      final body = note.body.replaceRange(m.start, m.end, '[[${m.group(2)}]]');
      notes.put(note.copyWith(body: body));
      return true;
    }
    return false;
  }

  /// Unfinished tasks that [task] waits for (missing ones are ignored).
  List<Task> openPrerequisites(Task task) => [
    for (final id in task.dependsOn)
      if (tasks[id] case final t? when !t.done) t,
  ];

  /// Whether [taskId] may wait for [otherId] without a loop (A waits for
  /// B waits for A).
  bool canDependOn(String taskId, String otherId) {
    if (taskId == otherId) return false;
    final seen = <String>{};
    final stack = [otherId];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (id == taskId) return false;
      if (!seen.add(id)) continue;
      stack.addAll(tasks[id]?.dependsOn ?? const []);
    }
    return true;
  }

  /// Moves the dates of [ids] by [days], keeping the gaps between them.
  /// Returns how many tasks moved.
  int shiftTasks(Iterable<String> ids, int days) {
    var moved = 0;
    for (final id in ids.toSet()) {
      final t = tasks[id];
      if (t == null || (t.dueDate == null && t.startDate == null)) continue;
      tasks.put(t.shifted(days));
      moved++;
    }
    return moved;
  }

  /// Moves every unfinished dated task of a project (and its subtasks) by
  /// [days], keeping their spacing.
  int shiftProject(String projectId, int days) => shiftTasks([
    for (final t in tasks.all)
      if (!t.done &&
          (t.projectId == projectId ||
              tasks[t.parentId ?? '']?.projectId == projectId))
        t.id,
  ], days);

  /// Every label used by a task, sorted.
  List<String> get taskLabels =>
      {for (final t in tasks.all) ...t.labels}.toList()..sort();

  /// Deletes a task and its subtasks.
  void deleteTask(String id) {
    for (final sub in tasks.all.where((t) => t.parentId == id).toList()) {
      deleteTask(sub.id);
    }
    tasks.remove(id);
  }
}
