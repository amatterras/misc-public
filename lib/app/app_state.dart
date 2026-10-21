import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../data/models/canvas_models.dart';
import '../data/models/record.dart';
import '../data/repositories/canvas_repository.dart';
import '../data/repositories/record_collection.dart';
import '../data/storage/app_log.dart';
import '../data/workspace.dart';
import '../features/canvas/canvas_controller.dart';
import '../features/canvas/canvas_resources.dart';
import '../features/capture/capture_service.dart';
import '../features/capture/send_to.dart';
import '../platform/windows_native.dart' as native;
import '../sync/protocol.dart';
import '../sync/secret_store.dart';
import '../sync/sync_client.dart';
import '../sync/sync_engine.dart';

enum AppPage { home, canvas, notes, calendar, tasks }

/// A simple focus (Pomodoro-style) timer that keeps running while you
/// switch pages.
class FocusTimer extends ChangeNotifier {
  static const focusLength = Duration(minutes: 25);
  static const breakLength = Duration(minutes: 5);

  Duration remaining = focusLength;
  bool running = false;
  bool onBreak = false;
  String? taskId;
  Timer? _ticker;

  void start() {
    if (running) return;
    running = true;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    notifyListeners();
  }

  void pause() {
    running = false;
    _ticker?.cancel();
    notifyListeners();
  }

  void reset({bool toBreak = false}) {
    pause();
    onBreak = toBreak;
    remaining = toBreak ? breakLength : focusLength;
    notifyListeners();
  }

  void _tick() {
    remaining -= const Duration(seconds: 1);
    if (remaining <= Duration.zero) {
      reset(toBreak: !onBreak);
      return;
    }
    notifyListeners();
  }

  String get label {
    final m = remaining.inMinutes.toString().padLeft(2, '0');
    final s = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

/// App-wide state: navigation, the canvas list and open canvas, and the
/// shared [Workspace] used by every page.
class AppState extends ChangeNotifier {
  AppState({
    required this.canvases,
    required this.settings,
    required this.workspace,
    this.enableSendTo = true,
  }) : capture = CaptureService(workspace),
       sendTo = SendToBridge(workspace.root) {
    resources = WorkspaceCanvasResources(workspace);
  }

  final CanvasRepository canvases;
  final SettingsRepository settings;
  final Workspace workspace;
  final CaptureService capture;
  final SendToBridge sendTo;
  final bool enableSendTo;
  late final WorkspaceCanvasResources resources;
  final FocusTimer timer = FocusTimer();

  /// Opens a link in the browser; replaceable in tests.
  bool Function(String url) openUrl = native.openUrl;

  AppPage _page = AppPage.home;
  AppPage get page => _page;

  bool _sidebarCollapsed = false;
  bool get sidebarCollapsed => _sidebarCollapsed;

  List<CanvasSummary> _canvasList = const [];
  List<CanvasSummary> get canvasList => _canvasList;

  CanvasController? _canvas;
  CanvasController? get canvas => _canvas;

  /// Note to show when the Notes page opens (set by "open note" links).
  String? selectedNoteId;

  /// Day to highlight when Calendar opens.
  DateTime? focusDay;

  /// Task to show when Tasks opens.
  String? selectedTaskId;

  void openTask(String id) {
    selectedTaskId = id;
    _canvas?.endEditing();
    _page = AppPage.tasks;
    notifyListeners();
  }

  /// Short message shown at the bottom of the window.
  final ValueNotifier<String?> toast = ValueNotifier(null);

  Future<void> init() async {
    await settings.load();
    await workspace.load();
    _sidebarCollapsed = settings.get<bool>('sidebarCollapsed') ?? false;
    capture.fetchPreviews = settings.get<bool>('linkPreviews') ?? true;

    // Data written by a newer version of THEapp must never be rewritten in
    // an older format: stop before anything is saved.
    if (await canvases.newestSchema() > CanvasDocument.schemaVersion ||
        workspace.newestRecordSchema > RecordCollection.schemaVersion) {
      workspace.store.readOnly = true;
      dataProblem =
          'Your data was saved by a newer version of THEapp. To protect it, '
          'this version will not open or change it. Please update THEapp.';
      AppLog.error('Newer data schema found; opened nothing, wrote nothing.');
      notifyListeners();
      return;
    }

    // Upgrade older files: verified backup (with photos) first, then all at
    // once, so the data is never left half-upgraded for long.
    final needsMigration =
        await canvases.oldestSchema() < CanvasDocument.schemaVersion ||
        workspace.oldestRecordSchema < RecordCollection.schemaVersion;
    if (needsMigration) {
      Directory? backup;
      var verified = false;
      try {
        backup = await workspace.backups.snapshot(
          'pre-v${CanvasDocument.schemaVersion}',
          includeAttachments: true,
        );
        verified = await workspace.backups.verify(backup);
      } catch (e, s) {
        AppLog.error('Pre-upgrade backup failed', e, s);
      }
      if (backup == null || !verified) {
        workspace.store.readOnly = true;
        dataProblem =
            'THEapp needs to upgrade your data but could not make a verified '
            'backup first, so nothing was changed. Free some disk space and '
            'restart THEapp.';
        AppLog.error('Pre-upgrade backup failed verification; data untouched.');
        notifyListeners();
        return;
      }
      AppLog.info('Verified pre-upgrade backup ${backup.path}');
      await migrateCanvases();
      await workspace.flush();
      await settings.set('backupBeforeSchema', CanvasDocument.schemaVersion);
    }
    try {
      await workspace.backups.automaticBackup();
    } catch (e, s) {
      AppLog.error('Automatic backup failed', e, s);
    }

    await _refreshList();
    if (_canvasList.isEmpty) {
      await createCanvas(
        title: 'My First Canvas',
        withWelcome: true,
        show: false,
      );
    } else {
      final last = settings.get<String>('lastCanvasId');
      final id = _canvasList.any((c) => c.id == last)
          ? last!
          : _canvasList.first.id;
      await openCanvas(id, show: false);
    }
    if (enableSendTo) {
      sendTo.onFocusRequested = native.focusMainWindow;
      sendTo.start(capture);
    }
    final recoveries = workspace.store.recoveries;
    if (recoveries.isNotEmpty) {
      // Shown once the window is up; details are in the log.
      Timer(const Duration(seconds: 1), () => showToast(recoveries.join('  ')));
    }
    await _startSyncIfPaired();
  }

  // ---------------------------------------------------------------- sync --
  //
  // Optional. Until this PC's app is paired with a hub nothing here runs.
  // The app never depends on the hub: if it is off, edits wait locally and
  // go out on a later attempt.

  static const syncInterval = Duration(minutes: 1);
  SyncEngine? _sync;
  Timer? _syncTimer;
  bool syncing = false;
  String? hubUrl;
  String syncStatus = 'Not set up';
  DateTime? lastSynced;

  File get _hubTokenFile => File(
    '${workspace.root.path}${Platform.pathSeparator}sync${Platform.pathSeparator}hub.token',
  );

  bool get syncPaired => _sync != null;

  Future<void> _startSyncIfPaired() async {
    final config = await workspace.store.read('sync', 'hub');
    final url = config?['url'] as String?;
    final token = await readSecret(_hubTokenFile);
    if (url == null || token == null) return;
    try {
      _startSync(Uri.parse(url), token);
    } on SyncFailure catch (e) {
      syncStatus = e.message;
    }
  }

  void _startSync(Uri url, String token) {
    _sync = SyncEngine(
      workspace: workspace,
      canvases: canvases,
      client: SyncClient(url, token: token),
      openCanvas: _SyncBridge(this),
    );
    hubUrl = url.toString();
    syncStatus = 'Waiting for first sync';
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(syncInterval, (_) => syncNow());
    Timer(const Duration(seconds: 3), syncNow);
  }

  /// Pairs this app with a hub using a code from `thehub pair`. Returns an
  /// error message, or null on success.
  Future<String?> pairWithHub(String url, String code) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !isAllowedHubUrl(uri)) {
      return 'The hub address must be this PC (http://127.0.0.1:47710), your home network or Tailscale.';
    }
    final client = SyncClient(uri);
    try {
      final device = workspace.device!;
      final token = await client.register(code, device.id, device.name);
      await writeSecret(_hubTokenFile, token);
      await workspace.store.write('sync', 'hub', {'url': uri.toString()});
      AppLog.info('Paired with a hub');
      _startSync(uri, token);
      notifyListeners();
      return null;
    } on SyncFailure catch (e) {
      return e.message;
    } finally {
      client.close();
    }
  }

  /// Stops syncing and forgets the hub (local data is untouched).
  Future<void> disconnectHub() async {
    _syncTimer?.cancel();
    _sync?.client.close();
    _sync = null;
    hubUrl = null;
    syncStatus = 'Not set up';
    if (await _hubTokenFile.exists()) await _hubTokenFile.delete();
    final sync =
        '${workspace.root.path}${Platform.pathSeparator}sync${Platform.pathSeparator}';
    for (final name in ['hub.json', 'client_state.json']) {
      final f = File('$sync$name');
      if (await f.exists()) await f.delete();
    }
    notifyListeners();
  }

  Future<void> syncNow() async {
    final engine = _sync;
    if (engine == null || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      final report = await engine.syncOnce();
      lastSynced = DateTime.now();
      syncStatus = report.conflicts > 0
          ? 'Synced — ${report.conflicts} conflict(s) kept for review'
          : 'Synced';
      if (report.problems.isNotEmpty) {
        syncStatus += ' (${report.problems.first})';
      }
      await _refreshList();
    } on SyncFailure catch (e) {
      syncStatus = e.retryable ? '${e.message} Will retry.' : e.message;
      if (!e.retryable) AppLog.warn('Sync stopped: ${e.code}');
    } catch (e, s) {
      syncStatus = 'Sync hit an unexpected error (see log).';
      AppLog.error('Sync error', e, s);
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Set when the data can't be opened safely; the app then shows this
  /// message instead of its pages and writes nothing.
  String? dataProblem;

  /// Rewrites every canvas stored in an older format. Items keep their ids;
  /// those without a revision get one from the canvas's last edit time.
  Future<int> migrateCanvases() async {
    var migrated = 0;
    for (final summary in await canvases.listCanvases()) {
      final doc = await canvases.load(summary.id);
      if (doc == null || doc.schema >= CanvasDocument.schemaVersion) continue;
      final stamp = workspace.clock.stampAt(doc.updatedAt);
      await canvases.save(
        CanvasDocument(
          id: doc.id,
          title: doc.title,
          items: doc.items,
          updatedAt: doc.updatedAt,
          viewport: doc.viewport,
          folderId: doc.folderId,
          itemRevs: {
            for (final i in doc.items) i.id: doc.itemRevs[i.id] ?? stamp,
          },
          tombstones: doc.tombstones,
          metaRev: doc.metaRev ?? stamp,
          unknownItems: doc.unknownItems,
        ),
      );
      migrated++;
    }
    if (migrated > 0) AppLog.info('Upgraded $migrated canvas file(s)');
    return migrated;
  }

  Future<void> _refreshList() async {
    _canvasList = await canvases.listCanvases();
    notifyListeners();
  }

  void showToast(String message) {
    toast.value = message;
    Timer(const Duration(seconds: 3), () {
      if (toast.value == message) toast.value = null;
    });
  }

  void goTo(AppPage page) {
    if (page == _page) return;
    _canvas?.endEditing();
    _page = page;
    notifyListeners();
  }

  void toggleSidebar() {
    _sidebarCollapsed = !_sidebarCollapsed;
    settings.set('sidebarCollapsed', _sidebarCollapsed);
    notifyListeners();
  }

  void setLinkPreviews(bool on) {
    capture.fetchPreviews = on;
    settings.set('linkPreviews', on);
    notifyListeners();
  }

  // ------------------------------------------------------------ calendar --

  static const maxCalendarDays = 38;

  DateTime get calendarStart {
    final key = settings.get<String>('calendarStart');
    return key == null ? dateOnly(DateTime.now()) : parseDayKey(key);
  }

  int get calendarDays => (settings.get<int>('calendarDays') ?? maxCalendarDays)
      .clamp(1, maxCalendarDays);

  Future<void> setCalendarRange(DateTime start, int days) async {
    await settings.set('calendarStart', dayKey(start));
    await settings.set('calendarDays', days.clamp(1, maxCalendarDays));
    notifyListeners();
  }

  void openCalendarDay(DateTime day) {
    focusDay = dateOnly(day);
    final end = addDays(calendarStart, calendarDays - 1);
    if (daysBetween(calendarStart, day) < 0 || daysBetween(day, end) < 0) {
      unawaited(setCalendarRange(dateOnly(day), calendarDays));
    }
    goTo(AppPage.calendar);
    notifyListeners();
  }

  // --------------------------------------------------------------- notes --

  void openNote(String id) {
    selectedNoteId = id;
    _page = AppPage.notes;
    _canvas?.endEditing();
    notifyListeners();
  }

  /// Puts a card for an existing note on the open canvas (a reference,
  /// not a copy) and switches to it.
  Future<void> placeNoteOnCanvas(String noteId, {String? canvasId}) async {
    if (canvasId != null) await openCanvas(canvasId, show: false);
    final c = _canvas;
    if (c == null) return;
    c.insertNoteCard(noteId, _canvasCenter(c));
    goTo(AppPage.canvas);
  }

  /// Centre of the canvas view in world coordinates (approximate when the
  /// canvas hasn't been laid out yet).
  Offset _canvasCenter(CanvasController c) =>
      c.toWorld(canvasViewportSize.center(Offset.zero));

  /// Updated by the canvas view whenever it is laid out.
  Size canvasViewportSize = const Size(1000, 800);

  Offset canvasDropPoint(CanvasController c) => _canvasCenter(c);

  // -------------------------------------------------------------- canvas --

  void _activateCanvasItem(CanvasItem item) {
    switch (item) {
      case LinkItem():
        final url = workspace.assets[item.assetId]?.url;
        if (url != null && !openUrl(url)) {
          showToast('Could not open $url');
        }
      case NoteCardItem():
        if (workspace.notes.contains(item.noteId)) {
          openNote(item.noteId);
        } else {
          showToast('That note no longer exists.');
        }
      case TextItem() || ImageItem() || StrokeItem():
        break;
    }
  }

  void activateCanvasItem(CanvasItem item) => _activateCanvasItem(item);

  Future<void> openCanvas(String id, {bool show = true}) async {
    if (_canvas?.id != id) {
      await _sync?.whenIdle();
      final doc = await canvases.load(id);
      if (doc == null) return;
      await _closeCanvas();
      _canvas = CanvasController(
        document: doc,
        onSave: _saveCanvas,
        resources: resources,
        onActivate: _activateCanvasItem,
        clock: workspace.clock,
      );
      await settings.set('lastCanvasId', id);
    }
    if (show) {
      _canvas?.endEditing();
      _page = AppPage.canvas;
    }
    notifyListeners();
  }

  Future<void> _saveCanvas(CanvasDocument doc) async {
    await canvases.save(doc);
    final index = _canvasList.indexWhere((c) => c.id == doc.id);
    final text = [
      for (final i in doc.items)
        if (i is TextItem) i.text,
    ].join('\n');
    final summary = CanvasSummary(
      id: doc.id,
      title: doc.title,
      updatedAt: doc.updatedAt,
      folderId: doc.folderId,
      searchText: text,
    );
    if (index >= 0) {
      _canvasList = [..._canvasList]..[index] = summary;
      notifyListeners();
    }
  }

  Future<void> _closeCanvas() async {
    final old = _canvas;
    if (old == null) return;
    old.endEditing();
    await old.flush();
    _canvas = null;
    old.dispose();
  }

  Future<void> createCanvas({
    String title = 'Untitled Canvas',
    bool withWelcome = false,
    bool show = true,
    String? folderId,
  }) async {
    final doc = CanvasDocument(
      id: newId(),
      title: title,
      updatedAt: DateTime.now(),
      folderId: folderId,
      items: withWelcome ? _welcomeItems() : const [],
    );
    await canvases.save(doc);
    await _refreshList();
    await openCanvas(doc.id, show: show);
  }

  Future<void> renameCanvas(String id, String title) async {
    if (_canvas?.id == id) {
      _canvas!.title = title;
      await _canvas!.flush();
    } else {
      final doc = await canvases.load(id);
      if (doc == null) return;
      await canvases.save(doc.copyWith(title: title));
    }
    await _refreshList();
  }

  Future<void> moveCanvasToFolder(String id, String? folderId) async {
    if (_canvas?.id == id) {
      _canvas!.folderId = folderId;
      await _canvas!.flush();
    } else {
      final doc = await canvases.load(id);
      if (doc == null) return;
      await canvases.save(doc.copyWith(folderId: () => folderId));
    }
    await _refreshList();
  }

  /// Moves the canvas file to a trash folder (it is not erased).
  Future<void> deleteCanvas(String id) async {
    if (_canvas?.id == id) await _closeCanvas();
    await canvases.delete(id);
    await workspace.recordCanvasDeletion(id);
    await _refreshList();
    if (_canvasList.isEmpty) {
      await createCanvas(show: _page == AppPage.canvas);
    } else if (_canvas == null) {
      await openCanvas(_canvasList.first.id, show: _page == AppPage.canvas);
    }
  }

  /// Saves everything that is pending. Called before the app exits.
  Future<void> flush() async {
    await _canvas?.flush();
    await workspace.flush();
  }

  static List<CanvasItem> _welcomeItems() => [
    TextItem(
      id: newId(),
      position: const Offset(0, 0),
      width: 460,
      minHeight: 0,
      fontSize: 16,
      text:
          '# Welcome to your canvas\n'
          '- Double-click empty space to write a note\n'
          '- Drag to move, use the corner handle to resize\n'
          '- Select a note to change size, **bold**, colours\n'
          '- **P** draws, **E** erases drawings, **V** selects\n'
          '- Scroll to zoom, hold **Space** or middle mouse to pan\n'
          '- **Ctrl+V** pastes text, links and images here\n'
          '- **Ctrl+N** opens Quick Add from anywhere',
    ),
  ];

  @override
  void dispose() {
    _syncTimer?.cancel();
    _sync?.client.close();
    sendTo.dispose();
    timer.dispose();
    _canvas?.dispose();
    resources.dispose();
    super.dispose();
  }
}

/// Gives the sync engine access to the canvas open on screen.
class _SyncBridge implements OpenCanvasBridge {
  _SyncBridge(this.state);

  final AppState state;

  @override
  String? get openCanvasId => state._canvas?.id;

  @override
  Future<void> flushOpenCanvas() async => state._canvas?.flush();

  @override
  Set<String> applyToOpenCanvas(
    List<SyncChange> changes,
    bool Function(String key, String? localRev) isPending,
  ) => state._canvas?.applyRemote(changes, isPending) ?? const {};
}
