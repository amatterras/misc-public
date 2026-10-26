import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/models/canvas_models.dart';

import '../data/models/library_models.dart';
import '../data/models/record.dart';
import '../data/models/task_models.dart';
import '../data/migrations/canonical_color_migration.dart';
import '../data/migrations/migration_runner.dart';
import '../data/storage/backup_service.dart';
import '../data/storage/backup_verifier.dart';
import '../data/repositories/canvas_repository.dart';
import '../data/repositories/record_collection.dart';
import '../data/storage/app_log.dart';
import '../data/storage/json_file_store.dart' show iosDocuments, iosFolder;
import '../data/workspace.dart';
import '../features/canvas/canvas_controller.dart';
import '../features/ink/pen_sizes.dart';
import '../features/ink/pencil_double_tap.dart';
import '../features/ai/ai_service.dart';
import '../features/browser/browser_engine.dart';
import '../features/browser/browser_workspace.dart';
import '../features/ai/ai_session.dart';
import '../features/ai/similarity.dart';
import '../features/canvas/canvas_resources.dart';
import '../features/capture/capture_service.dart';
import '../features/capture/file_drop.dart';
import '../features/capture/send_to.dart';
import '../features/tasks/completion_messages.dart';
import '../features/widgets/widget_snapshot.dart';
import '../platform/ios_bridge.dart';
import '../platform/input_hints.dart';
import '../platform/platform.dart' as native;
import '../widgets/date_prefs.dart';
import '../sync/protocol.dart';
import '../sync/record_merge.dart';
import '../sync/secret_store.dart';
import '../sync/sync_client.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_health.dart';
import '../sync/sync_scheduler.dart';
import '../sync/storage_modes.dart';
import '../data/integrity/integrity_check.dart';
import '../features/handoff/handoff.dart';
import '../hub/hub_host.dart';
import 'maintenance.dart';
import '../sync/local_hub.dart';
import '../features/calendar/external/external_calendar.dart';
import '../features/calendar/external/oauth.dart';
import '../features/graph/relationship_graph.dart';
import '../features/links/archive_library.dart';
import '../features/search/pdf_ocr.dart';
import '../features/search/text_index.dart';
import '../features/think/experiment_page.dart';
import '../features/vault/vault_page.dart';
import '../features/vault/vault_service.dart';
import 'canvas_ops.dart';
import 'floating_windows.dart';
import 'page_windows.dart';
import 'test_environment.dart';

enum AppPage { home, canvas, notes, links, calendar, tasks, browser, ai }

/// Surfaces with background dots (each has its own dot opacity).
enum DotSurface { mindmap, archive }

/// A simple focus (Pomodoro-style) timer that keeps running while you
/// switch pages.
/// Where to go back to after following a workspace link.
typedef ReturnPoint = ({String label, Future<void> Function() restore});

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
    IosBridge? ios,
  }) : capture = CaptureService(workspace),
       sendTo = SendToBridge(workspace.root),
       ios = ios ?? (Platform.isIOS ? IosBridge.instance : null) {
    resources = WorkspaceCanvasResources(workspace);
  }

  /// iPhone/iPad services (links opened from outside, shared items); null
  /// on other platforms. Replaceable in tests.
  final IosBridge? ios;
  SendToBridge? _sharedInbox;

  final CanvasRepository canvases;
  final SettingsRepository settings;
  final Workspace workspace;
  final CaptureService capture;
  final SendToBridge sendTo;
  final bool enableSendTo;
  late final WorkspaceCanvasResources resources;
  final FocusTimer timer = FocusTimer();

  /// Floating panels (draggable, resizable; places kept on this device).
  late final FloatingWindows floating = FloatingWindows(settings);

  /// Opens a link in the browser; replaceable in tests.
  bool Function(String url) openUrl = native.openUrl;

  /// Opens a stored document file; replaceable in tests.
  bool Function(String path) openDocument = native.openDocument;

  AppPage _page = AppPage.home;
  AppPage get page => _page;

  bool _sidebarCollapsed = false;
  bool get sidebarCollapsed => _sidebarCollapsed;

  List<CanvasSummary> _canvasList = const [];
  List<CanvasSummary> get canvasList => _canvasList;

  CanvasController? _canvas;
  CanvasController? get canvas => _canvas;

  /// After a tag was deleted: takes it off the objects of the open
  /// mindmaps (the Archive items were cleaned by the workspace). Other
  /// mindmaps just stop showing it; its id is never reused.
  void scrubDeletedTags() {
    bool exists(String id) => workspace.customTags[id] != null;
    for (final c in {_canvas, ...openNotebooks}) {
      c?.scrubCustomTags(exists);
    }
  }

  /// The handwriting of the note open in the note editor, if any (set by
  /// the editor), so sync merges remote changes into it.
  ///
  /// Several notes can be open at once (in windows): all are kept here.
  final Set<CanvasController> openNotebooks = {};

  /// The note handwriting with document id [id], if it is open.
  CanvasController? openNotebookFor(String id) =>
      openNotebooks.where((c) => c.id == id).firstOrNull;

  /// Note to show when the Notes page opens (set by "open note" links).
  String? selectedNoteId;

  /// Day to highlight when Calendar opens.
  DateTime? focusDay;

  /// Task to show when Tasks opens.
  String? selectedTaskId;

  void openTask(String id) {
    selectedTaskId = id;
    goTo(AppPage.tasks);
  }

  /// Tasks live in a collapsible column inside Calendar (there is no
  /// separate Tasks destination); whether it is open is remembered.
  bool get calendarTasksOpen => _calendarTasksOpen;
  bool _calendarTasksOpen = false;

  void setCalendarTasksOpen(bool open) {
    if (open == _calendarTasksOpen) return;
    _calendarTasksOpen = open;
    unawaited(settings.set('calendarTasksOpen', open));
    notifyListeners();
  }

  /// Pages that are restored at the next start (see [goTo]).
  static const _restorablePages = {
    AppPage.home,
    AppPage.canvas,
    AppPage.notes,
    AppPage.links,
    AppPage.calendar,
    AppPage.browser,
    AppPage.ai,
  };

  /// Short message shown at the bottom of the window.
  final ValueNotifier<String?> toast = ValueNotifier(null);
  final ValueNotifier<String> themeModePreference = ValueNotifier('dark');

  /// Per mindmap: when the last version was made and what the canvas looked
  /// like then (for the Time Machine's automatic versions).
  final Map<String, ({DateTime at, int fingerprint})> snapshotState = {};

  /// Whether saving a mindmap may make automatic versions (tests turn it off
  /// to control exactly which versions exist).
  bool autoSnapshots = true;

  /// The note being edited right now (set by the note editor), so Quick
  /// Capture can offer to refer to it.
  final ValueNotifier<String?> activeNoteId = ValueNotifier(null);

  /// How a PDF is opened for a page link (tests replace it; the default
  /// opens the file in this device's viewer).
  Future<bool> Function(File file, int page)? pdfOpener;

  /// How a saved link is opened when reading resumes (tests replace it).
  void Function(String url)? urlOpener;

  /// The PDF page last asked for by a link (a PDF window follows it).
  final ValueNotifier<({String assetId, int page})?> pdfFocus = ValueNotifier(null);

  /// A note page a link asks to scroll to (the note's page view follows it).
  final ValueNotifier<({String noteId, int page})?> notebookJump = ValueNotifier(null);

  /// The places the user followed workspace links from, newest last (see
  /// smart_links.dart); the bar above the app offers 'Back'.
  final ValueNotifier<List<ReturnPoint>> linkReturn = ValueNotifier(const []);

  /// The text in the global search: kept while results are opened and while
  /// the user moves around; only the search's own clear button empties it.
  final ValueNotifier<String> searchQuery = ValueNotifier('');

  Future<void> setThemeMode(String mode) async {
    if (!const {'system', 'light', 'dark'}.contains(mode)) return;
    await settings.set('themeMode', mode);
    themeModePreference.value = mode;
  }

  /// Opens the data and starts the background services. [onStep] is told
  /// which step is running, for the start-up screen and the log.
  Future<void> init({void Function(String step)? onStep}) async {
    void step(String name) {
      AppLog.info('Start-up: $name');
      onStep?.call(name);
    }

    BackupService.schemaVersions = {
      'records': RecordCollection.schemaVersion,
      'canvases': CanvasDocument.schemaVersion,
      'dataFeatureLevel': dataFeatureLevel,
    };
    step('Loading settings');
    await settings.load();
    themeModePreference.value = settings.get<String>('themeMode') ?? 'dark';
    step('Loading your data');
    await workspace.load();
    _sidebarCollapsed = settings.get<bool>('sidebarCollapsed') ?? false;
    _calendarTasksOpen = settings.get<bool>('calendarTasksOpen') ?? false;
    // Reopen where the user was (the last canvas is restored below).
    final lastPage = AppPage.values
        .asNameMap()[settings.get<String>('lastPage')];
    if (lastPage != null && _restorablePages.contains(lastPage)) {
      _page = lastPage;
      if (lastPage == AppPage.links) unawaited(openLinksBoard());
    }
    capture.fetchPreviews = settings.get<bool>('linkPreviews') ?? true;
    if (alwaysOnTop && alwaysOnTopSupported) applyAlwaysOnTop(true);
    if (immersive) applyImmersive(true);
    DatePrefs.order =
        DateOrder.values.asNameMap()[settings.get<String>('dateOrder')] ??
        DateOrder.monthDay;
    DatePrefs.firstWeekday =
        (settings.get<int>('firstWeekday') ?? DateTime.monday).clamp(
          DateTime.monday,
          DateTime.sunday,
        );

    // Data written by a newer version of THEapp must never be rewritten in
    // an older format: stop before anything is saved.
    step('Checking the data version');
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
        verified =
            await workspace.backups.verify(backup) &&
            (await verifyRestorable(workspace.backups, backup)).ok;
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
    if (!await _checkFeatureLevel()) return;
    step('Checking data upgrades');
    if (!await runMigrations()) return;
    workspace.backups.copiesDir ??= backupCopiesFolder();
    step('Daily backup');
    try {
      await workspace.backups.automaticBackup();
    } catch (e, s) {
      AppLog.error('Automatic backup failed', e, s);
    }

    step('Opening canvases');
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
      // Files dragged onto the window (Windows runner).
      listenForDroppedFiles(this);
      sendTo.onFocusRequested = native.focusMainWindow;
      sendTo.start(capture);
    }
    if (ios != null) {
      step('Starting iPhone/iPad services');
      // Links from outside and shared items are extras: if iOS does not
      // answer, THEapp still opens (the reason is in the log).
      try {
        await _startIosCapture(ios!);
      } catch (e, s) {
        AppLog.error('iPhone/iPad link and share services unavailable', e, s);
      }
      _startWidgets();
    }
    final recoveries = workspace.store.recoveries;
    if (recoveries.isNotEmpty) {
      // Shown once the window is up; details are in the log.
      Timer(const Duration(seconds: 1), () => showToast(recoveries.join('  ')));
    }
    await _startHubHost(step);
    step('Starting sync');
    await _startSyncIfPaired();
    handoff.start();
    // Replies that were being written when the app closed are marked
    // interrupted (never shown as finished).
    for (final c in workspace.aiConversations.all.toList()) {
      final fixed = c.recovered();
      if (fixed != null) workspace.aiConversations.put(fixed);
    }
    windows.restore();
    step('Starting reminders');
    _startReminders();
    _applyClipboardSetting();
    _startCalendarSyncSchedule();
    unawaited(syncCalendarAccounts());
    _startMaintenance();
    step('Ready');
  }

  // ------------------------------------------------ hub and every 10 s --
  //
  // On Windows, THEapp runs the hub itself while it is open (unless a hub
  // already runs on this PC: then it uses that one), and every 10 seconds
  // checks the hub, syncs, and backs up what changed (maintenance.dart).

  static bool get _isRealWindowsApp =>
      Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

  /// Whether the 10-second work runs (tests switch it on themselves).
  late bool runMaintenance = _isRealWindowsApp;
  Duration maintenanceInterval = const Duration(seconds: 10);

  /// Makes the hub this app runs, or null (no hub on this device). By
  /// default: the real Windows app, not in test-data mode, and only when
  /// this PC already has a hub folder (it was set up as the hub).
  late HubHost? Function() makeHubHost = () {
    if (!_isRealWindowsApp || TestEnvironment.active) return null;
    final dir = defaultLocalHubDir();
    if (!dir.existsSync()) return null;
    return HubHost(dir: dir, log: AppLog.info);
  };

  HubHost? hubHost;
  MaintenanceScheduler? maintenance;

  /// Record and drawing changes not in a frequent backup yet.
  int _changesSinceBackup = 0;

  /// Sync and the frequent backup never touch the data at the same time.
  final _dataLock = SerialLock();

  Future<void> _startHubHost(void Function(String) step) async {
    if (hubHost != null) return;
    final host = hubHost = makeHubHost();
    if (host == null) return;
    step('Starting the hub');
    try {
      // The window opens even if the hub needs longer (it keeps starting).
      await host.start().timeout(const Duration(seconds: 15));
    } on TimeoutException {
      AppLog.warn('Hub: still starting after 15 s; continuing');
    } catch (e, s) {
      AppLog.error('Hub could not start', e, s);
    }
  }

  void _startMaintenance() {
    if (!runMaintenance || maintenance != null) return;
    // Edits count for the backup even when this device is not paired.
    if (!_listeningForEdits) {
      _listeningForEdits = true;
      workspace.changes.addListener(_editedLocally);
    }
    // A backup interrupted last time (app closed while copying) left a
    // hidden folder; it was never a backup.
    unawaited(
      workspace.backups.removeInterrupted().then((n) {
        if (n > 0) AppLog.info('Removed $n interrupted backup folder(s)');
      }),
    );
    final m = maintenance = MaintenanceScheduler(
      [
        MaintenanceJob('hub', _checkHub, label: 'Checking the hub'),
        MaintenanceJob('sync', _syncTick, label: 'Syncing'),
        MaintenanceJob('backup', _backupTick, label: 'Backing up'),
        MaintenanceJob(
          'hubBackup',
          _hubBackupTick,
          label: 'Backing up the hub',
        ),
      ],
      interval: maintenanceInterval,
      onError: (job, e, s) {
        // Logged once per streak, not every 10 seconds.
        if (job.failures == 1) {
          AppLog.warn('${job.name} failed: ${job.lastError}');
        }
      },
    );
    m.start();
  }

  Future<bool> _checkHub() async {
    final host = hubHost;
    if (host == null) return false;
    final h = await host.check();
    if (h.recovered != null) AppLog.info('Hub: recovered (${h.recovered})');
    if (!h.ok) throw JobProblem(h.problem ?? 'The hub is not running.');
    return true;
  }

  /// A sync every 10 seconds (on top of the live updates). Counts as done
  /// only if a sync cycle really completed now.
  Future<bool> _syncTick() async {
    final s = _scheduler;
    if (s == null || !syncEnabled || syncNeedsPairing) return false;
    final before = s.lastSuccess;
    await s.syncNow();
    if (s.lastSuccess == before) {
      throw JobProblem(_lastResult);
    }
    return true;
  }

  /// A frequent backup of the records, only if something changed (the
  /// first one after start always runs). Checked before it counts.
  Future<bool> _backupTick() async {
    final pending = _changesSinceBackup;
    final job = maintenance?.job('backup');
    if (pending == 0 && job?.lastSuccess != null) return false;
    await flush(); // the latest edits on disk first
    await _dataLock.run(() => workspace.backups.liveSnapshot());
    _changesSinceBackup -= pending;
    return true;
  }

  /// Closing the app: lets a backup or sync that is running finish (up to
  /// 20 s), saves everything, then stops the hub this app runs.
  Future<void> shutdown() async {
    await maintenance?.stop();
    _scheduler?.stop();
    await flush();
    await hubHost?.stop();
  }

  Future<bool> _hubBackupTick() async {
    final host = hubHost;
    if (host == null || host.state != HubHostState.running) return false;
    return await host.backupLive() != null;
  }

  // ---------------------------------------------------------------- sync --
  //
  // Optional. Until this PC's app is paired with a hub nothing here runs.
  // The app never depends on the hub: if it is off, edits wait locally and
  // go out on a later attempt.

  static const syncInterval = Duration(minutes: 1);
  SyncEngine? _sync;
  SyncScheduler? _scheduler;
  bool syncing = false;
  String? hubUrl;
  String syncStatus = 'Not set up';
  DateTime? lastSynced;

  File get _hubTokenFile => File(
    '${workspace.root.path}${Platform.pathSeparator}sync${Platform.pathSeparator}hub.token',
  );

  bool get syncPaired => _sync != null;

  /// Cross-device handoff: this device's place, and the others' (see
  /// handoff.dart). Only ids and numbers are recorded.
  late final HandoffService handoff = HandoffService(this);

  /// The last few sync attempts (newest last), for the Sync Health center.
  /// Plain words only: no addresses, keys or note text.
  final List<SyncAttempt> syncHistory = [];

  void _noteSyncAttempt(bool ok, String text) {
    syncHistory.add(SyncAttempt(DateTime.now(), ok, scrubDiagnostic(text)));
    if (syncHistory.length > 20) syncHistory.removeAt(0);
  }

  /// Whether a local change to one record has not reached the hub yet.
  Future<bool> syncRecordPending(String collection, String id) async =>
      await _sync?.isPending(collection, id) ?? false;

  /// Local records still waiting for the hub, by kind (counts only).
  Future<Map<String, int>> syncPendingCounts() async =>
      await _sync?.pendingCounts() ?? const {};

  /// The hub rejected this device's token; automatic sync is stopped until
  /// the device is paired again.
  bool syncNeedsPairing = false;

  /// Whether automatic (timed) sync is currently scheduled.
  bool get syncScheduled => _scheduler?.scheduled ?? false;

  /// iPhone/iPad: Documents/THEapp Backups, shown in the Files app (On My
  /// iPad → THEapp), so a backup can be moved off the device. Null
  /// elsewhere: on Windows the data folder itself is reachable.
  static Directory? backupCopiesFolder() {
    if (!Platform.isIOS) return null;
    try {
      final documents = iosFolder(
        'Documents',
        reported: iosDocuments,
        home: Platform.environment['HOME'],
        systemTemp: Directory.systemTemp.path,
      );
      return Directory('$documents/THEapp Backups');
    } on FileSystemException {
      return null;
    }
  }

  /// Makes a backup of everything (records, photos, PDFs) and saves a
  /// checked copy of it in [backups.copiesDir]. Returns the copy, or null
  /// if there is no such folder here.
  Future<Directory?> saveBackupCopy() async {
    final dest = workspace.backups.copiesDir;
    if (dest == null) return null;
    await flush();
    final backup = await workspace.backups.snapshot(
      'manual',
      includeAttachments: true,
    );
    if (!await workspace.backups.verify(backup)) {
      throw const FileSystemException('The backup could not be verified');
    }
    await dest.create(recursive: true);
    final copy = await workspace.backups.copyTo(backup, dest);
    AppLog.info('Saved a backup copy outside the data folder');
    return copy;
  }

  /// Raised whenever a build starts writing fields that an older build would
  /// drop (schema numbers alone did not change for those). 1: notebooks,
  /// PDF pages, pressure strokes, link tags (Phases 2 and 3).
  static const dataFeatureLevel = 2;

  /// First start of a build with a higher [dataFeatureLevel]: a verified
  /// backup (with photos) before anything is written, so the old state can
  /// be restored. Data marked by a newer build opens read-only, so this
  /// build never rewrites it without the newer fields. False = stop here.
  Future<bool> _checkFeatureLevel() async {
    final stored = settings.get<int>('dataFeatureLevel') ?? 0;
    if (stored > dataFeatureLevel) {
      workspace.store.readOnly = true;
      dataProblem =
          'Your data was saved by a newer build of THEapp. To protect it, '
          'this build will not change it. Please install the newer build.';
      AppLog.error(
        'Data feature level $stored > $dataFeatureLevel; wrote nothing.',
      );
      notifyListeners();
      return false;
    }
    if (stored == dataFeatureLevel) return true;
    final hasData =
        workspace.hasRecords || (await canvases.listCanvases()).isNotEmpty;
    if (hasData) {
      Directory? backup;
      var verified = false;
      try {
        backup = await workspace.backups.snapshot(
          'pre-level$dataFeatureLevel',
          includeAttachments: true,
        );
        verified =
            await workspace.backups.verify(backup) &&
            (await verifyRestorable(workspace.backups, backup)).ok;
      } catch (e, s) {
        AppLog.error('Pre-upgrade backup failed', e, s);
      }
      if (backup == null || !verified) {
        workspace.store.readOnly = true;
        dataProblem =
            'THEapp could not make a verified backup before using this new '
            'build with your data, so nothing was changed. Free some space '
            'and restart THEapp.';
        AppLog.error('Pre-upgrade backup failed verification; data untouched.');
        notifyListeners();
        return false;
      }
      AppLog.info('Verified backup before data level $dataFeatureLevel');
    }
    try {
      await _migrateCanonicalColors();
      await settings.set(
        'canonicalColorMigration',
        CanonicalColorMigration.version,
      );
    } catch (e, s) {
      workspace.store.readOnly = true;
      dataProblem =
          'THEapp could not complete the color migration safely. Your verified '
          'backup is preserved and this data folder is now read-only.';
      AppLog.error('Canonical color migration failed', e, s);
      notifyListeners();
      return false;
    }
    await settings.set('dataFeatureLevel', dataFeatureLevel);
    return true;
  }

  /// The last failed data upgrade (null when none): the app shows it with
  /// Retry and Restore instead of opening, and writes nothing meanwhile.
  MigrationOutcome? migrationFailure;

  /// The versioned migrations to run (replaceable in tests).
  List<MigrationStep> migrationSteps = MigrationRunner.registry;

  /// Runs the pending versioned migrations (migration_runner.dart). False =
  /// one failed: the data folder is read-only and [dataProblem] says why.
  /// Never deletes or re-creates the data.
  Future<bool> runMigrations() async {
    final hasData =
        workspace.hasRecords || (await canvases.listCanvases()).isNotEmpty;
    final outcome = await MigrationRunner(
      workspace: workspace,
      canvases: canvases,
      steps: migrationSteps,
    ).run(hasData: hasData);
    if (!outcome.failed) {
      migrationFailure = null;
      return true;
    }
    migrationFailure = outcome;
    workspace.store.readOnly = true;
    dataProblem =
        'THEapp could not finish upgrading your data: ${outcome.message} '
        'Nothing was deleted, and THEapp will not change this data folder '
        'until the upgrade succeeds. '
        '${outcome.backup == null ? '' : 'A verified copy from before the upgrade is kept in backups.'}';
    notifyListeners();
    return false;
  }

  /// "Retry" on the upgrade problem screen. Returns what to tell the user.
  Future<String> retryMigrations() async {
    workspace.store.readOnly = false;
    if (await runMigrations()) {
      return 'The upgrade finished. Close and reopen THEapp.';
    }
    return dataProblem ?? 'The upgrade failed again.';
  }

  /// "Restore" on the upgrade problem screen: puts back the verified
  /// backup made before the failed upgrade (the current state is backed up
  /// first by BackupService.restore). Returns what to tell the user.
  Future<String> restoreBeforeMigration() async {
    final backup = migrationFailure?.backup;
    if (backup == null || !await backup.exists()) {
      return 'No backup from before the upgrade was recorded. Your data '
          'folder was not changed.';
    }
    // Pending saves must not write over the restored files.
    workspace.store.readOnly = true;
    try {
      await workspace.backups.restore(backup);
    } catch (e, s) {
      AppLog.error('Restoring the pre-upgrade backup failed', e, s);
      return 'Restoring failed (${e.runtimeType}); your data was not '
          'replaced. The backup is still at ${backup.path}.';
    }
    AppLog.info('Restored the backup from before the failed upgrade');
    return 'Restored the data from before the upgrade. Close and reopen '
        'THEapp; it will try the upgrade again and stop safely if it fails.';
  }

  Future<void> _migrateCanonicalColors() async {
    for (final entry in workspace.entries.all.toList()) {
      final migrated = CanonicalColorMigration.migrateCalendarEntry(entry);
      if (!identical(migrated, entry)) workspace.entries.put(migrated);
    }
    for (final summary in await canvases.listCanvases()) {
      final document = await canvases.load(summary.id);
      if (document == null) continue;
      final migrated = CanonicalColorMigration.migrateCanvas(
        document,
        workspace.clock.now(),
      );
      if (!identical(migrated, document)) await canvases.save(migrated);
    }
    await workspace.flush();
  }

  Future<void> _startSyncIfPaired() async {
    final config = await workspace.store.read('sync', 'hub');
    final url = config?['url'] as String?;
    hubHosted = config?['hosted'] == true;
    final token = await readSecret(_hubTokenFile);
    if (url == null) return;
    if (token == null) {
      // Paired before, but this device's key is gone, e.g. a backup restored
      // onto another iPad (the Keychain entry stays on the old device).
      hubUrl = url;
      syncNeedsPairing = true;
      syncStatus =
          'This device needs to be paired again: its sync key is missing '
          '(for example after restoring a backup). Your data here is safe.';
      AppLog.warn('Sync not started: hub key missing; pair again');
      return;
    }
    try {
      _startSync(Uri.parse(url), token);
    } on SyncFailure catch (e) {
      syncStatus = e.message;
    }
  }

  void _startSync(Uri url, String token) {
    _scheduler?.stop();
    final engine = _sync = SyncEngine(
      workspace: workspace,
      canvases: canvases,
      client: SyncClient(url, token: token),
      openCanvas: _SyncBridge(this),
    );
    hubUrl = url.toString();
    syncNeedsPairing = false;
    syncStatus = 'Waiting for first sync';
    // Syncs a moment after each local edit, at once when the hub reports
    // another device's change (live), and on a slow timer as a safety net.
    _scheduler = SyncScheduler(
      run: _runSync,
      cursor: () async => (await engine.loadState()).cursor,
      client: engine.client,
      fallback: syncInterval,
      onChange: () {
        _logConnection();
        _updateSyncStatus();
        notifyListeners();
      },
      onError: (e, s) {
        if (e is! SyncFailure) AppLog.error('Sync error', e, s);
      },
    );
    // The Windows switch (Settings → Sync) may have paused sync.
    if (syncEnabled) _scheduler!.start();
    _updateSyncStatus();
    if (!_listeningForEdits) {
      _listeningForEdits = true;
      workspace.changes.addListener(_editedLocally);
    }
  }

  bool _listeningForEdits = false;

  /// Each change of the sync connection is logged once (with the time):
  /// failures used to leave no trace, so a hub that went away looked like
  /// a log that simply stopped.
  SyncConnection? _loggedConnection;
  void _logConnection() {
    final c = _scheduler?.connection;
    if (c == null || c == _loggedConnection) return;
    final before = _loggedConnection;
    _loggedConnection = c;
    switch (c) {
      case SyncConnection.offline:
        AppLog.warn('Sync: hub not reachable ($hubUrl); retrying');
      case SyncConnection.live || SyncConnection.polling
          when before == SyncConnection.offline ||
              before == SyncConnection.paused:
        AppLog.info('Sync: connected again (${c.name})');
      case SyncConnection.paused:
        AppLog.info('Sync: paused on the hub');
      default:
        break;
    }
  }

  /// Any record changed here: sync soon. (Changes written by a running sync
  /// only ask for one more cycle, so they do not show as "waiting".)
  void _editedLocally() {
    _changesSinceBackup++;
    final s = _scheduler;
    if (s == null) return;
    syncing ? s.request() : s.localChange();
  }

  /// Pairs this app with a hub using a code from `thehub pair`. Returns an
  /// error message, or null on success.
  Future<String?> pairWithHub(String url, String code) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !isAllowedHubUrl(uri)) {
      return 'The hub address must be this PC (http://127.0.0.1:47710), your home network or Tailscale.';
    }
    // On iPhone/iPad, 127.0.0.1 is the iPad itself; the hub runs on the PC.
    if (ios != null && isLoopbackHubUrl(uri)) {
      return 'On iPhone/iPad, 127.0.0.1 is this device, not your PC. Enter '
          'the PC’s Tailscale address, e.g. http://100.x.y.z:47710.';
    }
    // Test data mode talks only to the test hub (port 47799, on this PC or
    // over Tailscale), so a test copy can never reach a real hub.
    if (TestEnvironment.active && !TestEnvironment.isTestHub(uri)) {
      return 'Test data mode: pair only with the test hub '
          '(http://127.0.0.1:${TestEnvironment.testHubPort}), never the real hub.';
    }
    final client = SyncClient(uri);
    try {
      final device = workspace.device!;
      final token = await client.register(
        code,
        device.id,
        await _deviceLabel(device.name),
      );
      try {
        await writeSecret(_hubTokenFile, token);
      } catch (e, s) {
        // Keychain / DPAPI refused: nothing is stored, nothing is synced.
        AppLog.error('Could not store the hub key', e, s);
        return 'Paired, but this device could not store its key securely, so '
            'sync was not started. Try again; if it keeps failing, remove '
            'this device on the hub ("thehub revoke").';
      }
      await workspace.store.write('sync', 'hub', {'url': uri.toString()});
      hubHosted = false;
      AppLog.info(
        isEncryptedHubRoute(uri)
            ? 'Paired with a hub (this PC or Tailscale)'
            : 'Paired with a hub on the home network (unencrypted)',
      );
      _startSync(uri, token);
      notifyListeners();
      return null;
    } on SyncFailure catch (e) {
      return e.message;
    } finally {
      client.close();
    }
  }

  /// Signs this device in to a hosted sync service (HTTPS), creating the
  /// account first when [invite] is given. The same sync engine then runs
  /// against it; local data stays usable when the service is unreachable.
  /// Returns an error message, or null on success.
  Future<String?> signInHosted(
    String url,
    String email,
    String password, {
    String? invite,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !isHostedHubUrl(uri)) {
      return 'A hosted service address must start with https:// and use a '
          'server name.';
    }
    if (TestEnvironment.active) {
      return 'Test data mode never connects to a hosted service.';
    }
    final client = SyncClient(uri);
    try {
      if (invite != null && invite.trim().isNotEmpty) {
        await client.createAccount(email.trim(), password, invite.trim());
      }
      final device = workspace.device!;
      final token = await client.signIn(
        email.trim(),
        password,
        device.id,
        await _deviceLabel(device.name),
      );
      try {
        await writeSecret(_hubTokenFile, token);
      } catch (e, s) {
        AppLog.error('Could not store the hosted sync key', e, s);
        return 'Signed in, but this device could not store its key securely, '
            'so sync was not started.';
      }
      await workspace.store.write('sync', 'hub', {
        'url': uri.toString(),
        'hosted': true,
      });
      hubHosted = true;
      AppLog.info('Signed in to a hosted sync service');
      _startSync(uri, token);
      notifyListeners();
      return null;
    } on SyncFailure catch (e) {
      return e.message;
    } finally {
      client.close();
    }
  }

  /// Name shown in the hub's device list. iOS reports a generic host name
  /// ("localhost"), so the device model ("iPad") is used there instead.
  Future<String> _deviceLabel(String hostName) async =>
      hubDeviceName(hostName, await ios?.deviceModel());

  static String hubDeviceName(String hostName, String? model) {
    if (model == null || model.isEmpty) return hostName;
    return hostName.isEmpty || hostName == 'localhost'
        ? model
        : '$model ($hostName)';
  }

  /// Called when the app comes back to the front (iPhone/iPad: after being
  /// in the background, where timers do not run). Imports shared items and
  /// syncs if the last sync is more than [resumeSyncAfter] old.
  Future<void> appResumed() async {
    // iOS shows its bars again after the app was in the background.
    if (immersive) applyImmersive(true);
    await importSharedItems();
    _startCalendarSyncSchedule();
    unawaited(syncCalendarAccounts());
    // Timers and the live connection stop in the background (iOS): start
    // again and catch up.
    final s = _scheduler;
    if (s == null || syncNeedsPairing || !syncEnabled) return;
    s.start();
    final last = lastSynced;
    if (last != null && DateTime.now().difference(last) < resumeSyncAfter) {
      return;
    }
    await s.syncNow(); // catch up now (and let callers wait for it)
  }

  static const resumeSyncAfter = Duration(seconds: 20);

  static const calendarSyncInterval = Duration(minutes: 5);
  Timer? _calendarSyncTimer;

  void _startCalendarSyncSchedule() {
    _calendarSyncTimer?.cancel();
    _calendarSyncTimer = Timer.periodic(calendarSyncInterval, (_) {
      unawaited(syncCalendarAccounts());
    });
  }

  /// The app went to the background (iPhone/iPad): stop the live
  /// connection and timers; [appResumed] starts them again.
  void syncPaused() => _scheduler?.stop();

  // ------------------------------------------------------- storage modes --
  //
  // Local only, PC hub or hosted service (sync/storage_modes.dart). The data
  // folder on this device is the working copy in every mode; a mode only
  // says where it is shared. Changing it goes through StorageSwitch (copy,
  // verify, confirm) and never deletes the previous remote copy.

  /// Whether the configured hub is a hosted service (not the PC hub).
  bool hubHosted = false;

  /// Where this workspace is shared now.
  StorageProvider get storageProvider {
    final url = hubUrl;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) return const LocalOnlyProvider();
    return hubHosted ? HostedProvider(uri) : PcHubProvider(uri);
  }

  StorageMode get storageMode => storageProvider.mode;

  /// Starts the copy-and-verify workflow towards [to] (nothing changes
  /// until [activateStorage] is called with it).
  Future<StorageSwitch> beginStorageSwitch(StorageProvider to) async {
    if (TestEnvironment.active && to is! LocalOnlyProvider) {
      final uri = to.endpoint!;
      if (to is HostedProvider || !TestEnvironment.isTestHub(uri)) {
        throw const SyncFailure(
          'test_mode',
          'Test data mode connects only to the test hub on port '
              '${TestEnvironment.testHubPort}.',
        );
      }
    }
    if (ios != null && to is PcHubProvider && isLoopbackHubUrl(to.endpoint)) {
      throw const SyncFailure(
        'bad_address',
        'On iPhone/iPad, 127.0.0.1 is this device, not your PC. Enter the '
            'PC’s Tailscale address, e.g. http://100.x.y.z:47710.',
      );
    }
    return StorageSwitch(
      workspace: workspace,
      from: storageProvider,
      to: to,
      deviceName: await _deviceLabel(workspace.device!.name),
    );
  }

  /// Makes [change]'s destination the active provider. Only after a
  /// successful copy and verification, and only when the user confirmed.
  /// The previous remote keeps its data; this device keeps all of its own.
  Future<void> activateStorage(StorageSwitch change) async {
    if (change.stage != SwitchStage.verified || change.token == null) {
      throw StateError('Copy and verify before switching');
    }
    final to = change.to;
    final uri = to.endpoint!;
    // Stop the old connection first; its bookkeeping is replaced below.
    _scheduler?.stop();
    _scheduler = null;
    _sync?.client.close();
    _sync = null;
    await writeSecret(_hubTokenFile, change.token!);
    await workspace.store.write('sync', 'hub', {
      'url': uri.toString(),
      if (to is HostedProvider) 'hosted': true,
    });
    // New destination, so no bookkeeping carries over: this device offers
    // everything once (the destination already has it: duplicates), then
    // follows the destination's change list.
    for (final name in ['client_state.json', 'client_state.json.bak']) {
      final f = File(
        '${workspace.root.path}${Platform.pathSeparator}sync'
        '${Platform.pathSeparator}$name',
      );
      if (await f.exists()) await f.delete();
    }
    hubHosted = to is HostedProvider;
    await settings.set('storageMode', to.mode.name);
    AppLog.info('Storage mode: ${to.mode.name} (copy verified)');
    _startSync(uri, change.token!);
    notifyListeners();
  }

  /// Back to "this device only": tries one last sync so nothing waits to be
  /// sent (bounded), then stops syncing. Nothing is deleted here or on the
  /// previous hub/service. Returns a note for the user, or null.
  Future<String?> switchToLocalOnly() async {
    String? note;
    final s = _scheduler;
    if (s != null && syncEnabled && !syncNeedsPairing) {
      try {
        await s.syncNow().timeout(const Duration(seconds: 20));
      } catch (_) {
        // Reported below via pendingLocal.
      }
      if (s.pendingLocal) {
        note =
            'Some recent changes had not reached the previous hub/service. '
            'They are safe on this device.';
      }
    }
    await disconnectHub();
    await settings.set('storageMode', StorageMode.local.name);
    AppLog.info('Storage mode: local (previous remote copy kept)');
    return note;
  }

  // --------------------------------------------------- integrity, undo --

  /// Read-only check of this device's data (reports, never repairs).
  Future<IntegrityReport> checkIntegrity() async {
    await flush();
    return IntegrityChecker(workspace, canvases).run();
  }

  /// Deleted records that can still be restored, as (collection, id, kept).
  List<(String, String, Map<String, dynamic>)> recentlyDeletedRecords() => [
    for (final MapEntry(key: name, value: c)
        in workspace.allCollections.entries)
      for (final MapEntry(key: id, value: kept) in c.recentlyDeleted.entries)
        (name, id, kept),
  ];

  /// Restores one deleted record (a new edit that syncs; nothing else is
  /// restored). False if it is gone or already back.
  bool restoreDeletedRecord(String collection, String id) =>
      workspace.allCollections[collection]?.restoreDeleted(id) != null;

  /// Stops syncing and forgets the hub (local data is untouched).
  Future<void> disconnectHub() async {
    hubHosted = false;
    syncNeedsPairing = false;
    _scheduler?.stop();
    _scheduler = null;
    _sync?.client.close();
    _sync = null;
    hubUrl = null;
    syncStatus = 'Not set up';
    await deleteSecret(_hubTokenFile);
    final sync =
        '${workspace.root.path}${Platform.pathSeparator}sync${Platform.pathSeparator}';
    for (final name in ['hub.json', 'client_state.json']) {
      final f = File('$sync$name');
      if (await f.exists()) await f.delete();
    }
    notifyListeners();
  }

  // ------------------------------------------------ sync on/off (Windows) --
  //
  // The switch controls synchronisation, never local saving: while off,
  // edits are saved here as always and stay queued (revisions, bookkeeping
  // and pairing are untouched); the hub on this PC also pauses, so other
  // devices keep their changes queued too and show "paused". Turning it on
  // restarts the connection and reconciles everything that waited.

  bool get syncEnabled => settings.get<bool>('syncEnabled') ?? true;

  /// Pauses/resumes the hub on this PC (replaceable in tests). Returns
  /// false when no hub runs here.
  late Future<bool> Function(bool paused) pauseLocalHub = (paused) =>
      Platform.isWindows ? setLocalHubPaused(paused) : Future.value(false);

  /// Turns cross-device sync off or on. Returns a message when the hub on
  /// this PC could not be switched (this app's own sync is switched anyway).
  Future<String?> setSyncEnabled(bool on) async {
    await settings.set('syncEnabled', on);
    String? problem;
    try {
      await pauseLocalHub(!on);
    } on LocalHubException catch (e) {
      problem = e.message;
    }
    final s = _scheduler;
    if (on) {
      s?.start();
      await s?.syncNow(); // reconcile what waited, now
    } else {
      s?.stop();
    }
    AppLog.info(on ? 'Sync turned on' : 'Sync turned off (paused)');
    _updateSyncStatus();
    notifyListeners();
    return problem;
  }

  /// Syncs now (Settings → Sync now) and waits for it.
  Future<void> syncNow() async {
    final s = _scheduler;
    if (s == null || syncNeedsPairing || !syncEnabled) return;
    await s.syncNow();
  }

  /// The text of the last finished cycle ("Synced", conflicts, problems).
  String _lastResult = 'Waiting for first sync';

  /// What the sync line says: the truth about this moment, not only the
  /// last result (an offline hub or unsent edits are never shown as
  /// "Synced").
  void _updateSyncStatus() {
    if (syncNeedsPairing) return; // its own message stays
    final s = _scheduler;
    if (s == null) return;
    if (!syncEnabled) {
      syncStatus =
          'Sync is paused — changes are saved here and sync when you turn it '
          'back on.';
      return;
    }
    syncStatus = switch (s.connection) {
      SyncConnection.paused =>
        'Sync is paused on the PC — your changes are saved here and sync '
            'when it is turned back on.',
      SyncConnection.offline =>
        'Hub not reachable — your changes are saved here and will sync when '
            'it is back. Will retry.',
      _ when s.pendingLocal => 'Changes waiting to sync…',
      SyncConnection.live => '$_lastResult · live',
      _ => _lastResult,
    };
  }

  /// Live (updates arrive within about a second), polling, offline or
  /// stopped.
  SyncConnection get syncConnection =>
      _scheduler?.connection ?? SyncConnection.stopped;

  /// One sync cycle (run by the scheduler). Failures are shown and logged,
  /// then passed on so the scheduler knows the hub is unreachable.
  Future<void> _runSync() async {
    final engine = _sync;
    if (engine == null) return;
    syncing = true;
    notifyListeners();
    try {
      final report = await _dataLock.run(engine.syncOnce);
      lastSynced = DateTime.now();
      _lastResult = report.conflicts > 0
          ? 'Synced — ${report.conflicts} conflict(s) kept for review'
          : 'Synced';
      if (report.problems.isNotEmpty) {
        _lastResult += ' (${report.problems.first})';
      }
      _noteSyncAttempt(true, _lastResult);
      await _refreshList();
    } on SyncFailure catch (e) {
      if (e.code == 'unauthorized') {
        // Removed with `thehub revoke`, or the hub was replaced: retrying
        // cannot help. Nothing local is lost; unsent changes stay queued
        // and go out after pairing again.
        _scheduler?.stop();
        syncNeedsPairing = true;
        syncStatus =
            'This hub no longer accepts this device (it was removed, or the '
            'hub was reset). Your data here is safe. Disconnect, then pair '
            'again with a new code.';
        AppLog.warn('Sync stopped: device not accepted by the hub');
        _noteSyncAttempt(false, 'The hub no longer accepts this device.');
      } else {
        _lastResult = e.retryable ? '${e.message} Will retry.' : e.message;
        _noteSyncAttempt(false, _lastResult);
        if (!e.retryable) AppLog.warn('Sync stopped: ${e.code}');
      }
      rethrow;
    } catch (e, s) {
      _lastResult = 'Sync hit an unexpected error (see log).';
      _noteSyncAttempt(false, _lastResult);
      AppLog.error('Sync error', e, s);
      rethrow;
    } finally {
      syncing = false;
      _updateSyncStatus();
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
          itemUnknownFields: doc.itemUnknownFields,
          unknownKeys: doc.unknownKeys,
          metaUnknownFields: doc.metaUnknownFields,
          kind: doc.kind,
          pageBackgrounds: doc.pageBackgrounds,
          layers: doc.layers,
        ),
      );
      migrated++;
    }
    if (migrated > 0) AppLog.info('Upgraded $migrated canvas file(s)');
    return migrated;
  }

  Future<void> _refreshList() async {
    // Note handwriting and the Links board are stored like canvases but
    // are not ones.
    final all = await canvases.listCanvases();
    _canvasList = [
      for (final c in all)
        if (c.isCanvas) c,
    ];
    // Their typed text is still searchable (see [pageSearchText]).
    _pageText
      ..clear()
      ..addAll({
        for (final c in all)
          if (!c.isCanvas && c.searchText.trim().isNotEmpty) c.id: c.searchText,
      });
    notifyListeners();
  }

  final Map<String, String> _pageText = {};

  /// Text typed on note pages (`nb-<note id>`) and on the Archive board, by
  /// document id, for global search. Kept current by [saveDocument].
  Map<String, String> get pageSearchText => _pageText;

  /// Saves a note's pages or the Archive board and keeps its search text
  /// current. (Canvases save through [_saveCanvas].)
  Future<void> saveDocument(CanvasDocument doc) async {
    await canvases.save(doc);
    // A mindmap saved after an edit: sync it soon (canvas files are not
    // workspace records, so they do not tell the scheduler themselves).
    _editedLocally();
    final tagNames = {
      for (final fields in doc.itemUnknownFields.values)
        for (final id
            in fields[CanvasController.customTagsMark] as List? ?? const [])
          if (id is String) ?workspace.customTags[id]?.name,
    };
    final text = [
      for (final i in doc.items)
        if (i is TextItem) i.text,
      ...tagNames, // items' own tags make the mindmap findable by tag
    ].join('\n');
    if (text.trim().isEmpty) {
      _pageText.remove(doc.id);
    } else {
      _pageText[doc.id] = text;
    }
  }

  /// Shows a link's card on the Archive board (search result). Returns
  /// false if the link has no card there.
  Future<bool> openLinkCard(String assetId) async {
    final board = await openLinksBoard();
    final card = board.items
        .whereType<LinkItem>()
        .where((i) => i.assetId == assetId)
        .firstOrNull;
    if (card == null) return false;
    goTo(AppPage.links);
    board.reveal(card.id);
    return true;
  }

  // ----------------------------------------------------------- reminders --
  //
  // While THEapp runs, a task whose reminder time has passed is listed in
  // [dueReminders] (shown on every page) until dismissed. Reminders missed
  // while the app was closed appear at the next start. Which reminders were
  // dismissed is kept per device (settings), not synced.

  /// Due, undismissed reminders, oldest first.
  final ValueNotifier<List<Task>> dueReminders = ValueNotifier(const []);

  /// Current time; replaceable in tests.
  DateTime Function() clock = DateTime.now;

  /// Draws attention to the window; replaceable in tests (and never touches
  /// a real window while `flutter test` runs).
  void Function() attention = Platform.environment.containsKey('FLUTTER_TEST')
      ? () {}
      : native.flashMainWindow;

  Timer? _reminderTimer;

  void _startReminders() {
    workspace.tasks.addListener(checkReminders);
    _reminderTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => checkReminders(),
    );
    checkReminders();
  }

  Map<String, dynamic> get _dismissedReminders => {
    ...?settings.get<Map<String, dynamic>>('remindersDismissed'),
  };

  /// Reminders still to come, soonest first, at most [limit] (iOS keeps at
  /// most 64 pending notifications per app).
  List<ScheduledReminder> upcomingReminders({int limit = 60}) {
    final now = clock();
    final list = [
      for (final t in workspace.tasks.all)
        if (!t.done && t.reminderTime != null && t.reminderTime!.isAfter(now))
          ScheduledReminder(t.id, t.title, t.reminderTime!),
    ]..sort((a, b) => a.at.compareTo(b.at));
    return list.take(limit).toList();
  }

  String? _scheduledSignature;

  /// iPhone/iPad: hands the upcoming reminders to the system, so they
  /// appear as notifications even when THEapp is closed. Sent only when the
  /// list changed. Not yet run on a device.
  void _scheduleSystemReminders() {
    final ios = this.ios;
    if (ios == null) return;
    final upcoming = upcomingReminders();
    final signature = [
      for (final r in upcoming)
        '${r.id}|${r.title}|${r.at.millisecondsSinceEpoch}',
    ].join('\n');
    if (signature == _scheduledSignature) return;
    _scheduledSignature = signature;
    unawaited(ios.scheduleReminders(upcoming));
  }

  /// Updates [dueReminders] from the tasks and the clock.
  void checkReminders() {
    _scheduleSystemReminders();
    final now = clock();
    final dismissed = _dismissedReminders;
    final due = [
      for (final t in workspace.tasks.all)
        if (!t.done &&
            t.reminderTime != null &&
            !t.reminderTime!.isAfter(now) &&
            dismissed[t.id] != t.reminderTime!.toIso8601String())
          t,
    ]..sort((a, b) => a.reminderTime!.compareTo(b.reminderTime!));
    final before = {for (final t in dueReminders.value) t.id};
    final ids = [for (final t in due) t.id];
    if (listEquals([for (final t in dueReminders.value) t.id], ids)) return;
    dueReminders.value = due;
    if (ids.any((id) => !before.contains(id))) attention();
  }

  /// Hides a reminder on this device until its next occurrence (a
  /// recurring task's next date gives a new reminder time).
  void dismissReminder(String taskId) {
    final when = workspace.tasks[taskId]?.reminderTime;
    final dismissed = _dismissedReminders
      ..removeWhere((id, _) => !workspace.tasks.contains(id));
    if (when != null) dismissed[taskId] = when.toIso8601String();
    settings.set('remindersDismissed', dismissed);
    checkReminders();
  }

  // ------------------------------------------------- home-screen widgets --

  Timer? _widgetTimer;
  Timer? _widgetMidnight;
  String? _lastWidgetJson;

  /// How long changes are collected before the widgets are updated.
  static Duration widgetDelay = const Duration(seconds: 2);

  /// Keeps the iPhone/iPad widgets' snapshot (today and tomorrow) up to
  /// date. The snapshot is derived display data only; see [WidgetSnapshot].
  void _startWidgets() {
    for (final c in [workspace.tasks, workspace.entries, workspace.projects]) {
      c.addListener(_scheduleWidgetUpdate);
    }
    unawaited(updateWidgets());
  }

  void _scheduleWidgetUpdate() {
    _widgetTimer?.cancel();
    _widgetTimer = Timer(widgetDelay, () => unawaited(updateWidgets()));
  }

  /// Writes a fresh snapshot if it changed (and again after midnight,
  /// when "tomorrow" becomes "today"). Returns false if not written.
  Future<bool> updateWidgets({DateTime? now}) async {
    final ios = this.ios;
    if (ios == null) return false;
    final at = now ?? DateTime.now();
    _widgetMidnight?.cancel();
    _widgetMidnight = Timer(
      addDays(dateOnly(at), 1).difference(at) + const Duration(seconds: 5),
      () => unawaited(updateWidgets()),
    );
    final json = jsonEncode(WidgetSnapshot.build(workspace, at));
    // generatedAt changes every time; compare the rest.
    final key = json.replaceFirst(RegExp(r'"generatedAt":"[^"]*"'), '');
    if (key == _lastWidgetJson) return false;
    try {
      if (!await ios.writeWidgetSnapshot(json)) return false;
    } catch (e, s) {
      AppLog.error('Could not update the home-screen widgets', e, s);
      return false;
    }
    _lastWidgetJson = key;
    return true;
  }

  /// Opens what a widget was tapped on (`theapp://open?task=…` or
  /// `theapp://open?day=…`). Returns false for any other link.
  bool openWidgetLink(Uri uri) {
    final target = WidgetSnapshot.parseLink(uri);
    if (target == null) return false;
    final taskId = target.taskId;
    if (taskId != null && workspace.tasks.contains(taskId)) {
      openTask(taskId);
    } else if (target.day != null) {
      openCalendarDay(target.day!);
    } else {
      goTo(AppPage.tasks);
      showToast('That task is no longer there.');
    }
    return true;
  }

  // ------------------------------------------------------- iPhone / iPad --

  /// Links opened from outside (e.g. an iOS Shortcut opening
  /// `theapp://capture?url=...`) and requests left by the Share Extension
  /// go to the Inbox, through the same code as Windows "Send to". Only ever
  /// adds Inbox items. Not yet verified on a device.
  /// Apple Pencil double-tap = Undo on the drawing in use (see
  /// pencil_double_tap.dart). Drawing pages register themselves.
  late final PencilDoubleTap pencilDoubleTap = PencilDoubleTap()
    ..enabled = pencilDoubleTapUndo;
  StreamSubscription<String>? _pencilTaps;

  bool get pencilDoubleTapUndo =>
      settings.get<bool>('pencilDoubleTapUndo') ?? true;

  Future<void> setPencilDoubleTapUndo(bool on) async {
    pencilDoubleTap.enabled = on;
    await settings.set('pencilDoubleTapUndo', on);
    notifyListeners();
  }

  /// Handles one double-tap (from iOS, or a test). Says so when there was
  /// nothing to undo, so a tap never seems to do nothing for no reason.
  PencilTapResult onPencilDoubleTap(String preferredAction) {
    final result = pencilDoubleTap.handle(preferredAction);
    if (result == PencilTapResult.nothingToUndo) showToast('Nothing to undo.');
    return result;
  }

  Future<void> _startIosCapture(IosBridge ios) async {
    _pencilTaps ??= ios.pencilDoubleTap.listen(onPencilDoubleTap);
    final shared = await ios.sharedContainerPath();
    _sharedInbox = shared == null ? null : SendToBridge(Directory(shared));
    await importSharedItems();
    await ios.listenForLinks((uri) async {
      if (completeOAuthRedirect(uri)) return; // a calendar sign-in
      if (openWidgetLink(uri)) return;
      if (await addSharedLinkToLinks(uri)) return;
      final items = await sendTo.handleUri(uri, capture);
      if (items.isEmpty) return;
      await workspace.flush();
      showToast('Added ${items.length} item(s) to the Inbox');
    });
  }

  /// `theapp://capture?url=…&to=links[&tags=resource,projects]` (e.g. an
  /// iOS Shortcut in the share sheet): puts the link straight on the Links
  /// board instead of the Inbox. Returns false for any other link.
  Future<bool> addSharedLinkToLinks(Uri uri) async {
    if (uri.scheme != 'theapp' || uri.queryParameters['to'] != 'links') {
      return false;
    }
    final url = extractUrl(uri.queryParameters['url'] ?? '');
    if (url == null) return false;
    final tags = [
      for (final t in (uri.queryParameters['tags'] ?? '').split(','))
        if (t.trim().isNotEmpty) t.trim().toLowerCase(),
    ];
    final asset = capture.link(url, title: uri.queryParameters['title']);
    await addToLinks(asset, tags: tags);
    showToast('Added to Links');
    return true;
  }

  /// Imports items shared through the Share Extension (at start and when
  /// the app comes back to the front). Returns how many were added.
  Future<int> importSharedItems() async {
    final count = await _sharedInbox?.processRequests(capture) ?? 0;
    if (count > 0) showToast('Added $count shared item(s) to the Inbox');
    return count;
  }

  /// The last drag-and-drop's result while it can still be taken back
  /// (shown with an Undo button for a few seconds).
  final ValueNotifier<({String message, FutureOr<void> Function()? undo})?>
  lastTransfer = ValueNotifier(null);
  Timer? _transferTimer;

  void showTransferResult(
    ({String message, FutureOr<void> Function()? undo}) r,
  ) {
    _transferTimer?.cancel();
    lastTransfer.value = r;
    _transferTimer = Timer(const Duration(seconds: 8), () {
      lastTransfer.value = null;
    });
  }

  /// Takes the last drop back.
  Future<void> undoLastTransfer() async {
    final undo = lastTransfer.value?.undo;
    lastTransfer.value = null;
    _transferTimer?.cancel();
    if (undo != null) await undo();
  }

  void showToast(String message) {
    toast.value = message;
    Timer(const Duration(seconds: 3), () {
      if (toast.value == message) toast.value = null;
    });
  }

  void goTo(AppPage page) {
    if (page == AppPage.tasks) {
      // Tasks are shown in Calendar's task column.
      page = AppPage.calendar;
      if (!_calendarTasksOpen) setCalendarTasksOpen(true);
    }
    // A destination already floating in a window is brought forward
    // instead of opening it twice.
    final own = windows.find(page, null);
    if (own != null && own.mode == PageMode.floating) {
      windows.focus(own.id);
      return;
    }
    if (own != null) {
      windows.dock(own.id); // that page instance is the destination now
    } else {
      windows.showDestination();
    }
    if (page == _page) {
      notifyListeners(); // e.g. a task was selected
      return;
    }
    _canvas?.endEditing();
    _links?.endEditing();
    if (page == AppPage.links) unawaited(openLinksBoard());
    _page = page;
    if (_restorablePages.contains(page)) {
      unawaited(settings.set('lastPage', page.name));
    }
    notifyListeners();
  }

  void toggleSidebar() {
    _sidebarCollapsed = !_sidebarCollapsed;
    settings.set('sidebarCollapsed', _sidebarCollapsed);
    notifyListeners();
  }

  /// Expanded/collapsed state for navigation groups lives in local settings,
  /// never in the notes or canvas records those rows point to.
  bool sidebarGroupExpanded(String group) {
    final saved = settings.get<Map<String, dynamic>>('sidebarGroupExpanded');
    return saved?[group] as bool? ?? true;
  }

  void toggleSidebarGroup(String group) {
    final saved = <String, dynamic>{
      ...?settings.get<Map<String, dynamic>>('sidebarGroupExpanded'),
    };
    saved[group] = !sidebarGroupExpanded(group);
    unawaited(settings.set('sidebarGroupExpanded', saved));
    notifyListeners();
  }

  /// Keeps THEapp's window above other windows (Windows only; a setting
  /// of this device). Never touches a real window during `flutter test`.
  bool get alwaysOnTop => settings.get<bool>('alwaysOnTop') ?? false;

  bool get alwaysOnTopSupported => native.supportsAlwaysOnTop;

  /// Applies the setting to the window; replaceable in tests.
  bool Function(bool on) applyAlwaysOnTop =
      Platform.environment.containsKey('FLUTTER_TEST')
      ? (_) => false
      : native.setAlwaysOnTop;

  Future<void> setAlwaysOnTop(bool on) async {
    await settings.set('alwaysOnTop', on);
    if (alwaysOnTopSupported) applyAlwaysOnTop(on);
    notifyListeners();
  }

  // ------------------------------------------------------------------ ai --

  /// Safari: tabs, history, bookmarks, downloads (see browser_workspace).
  late final BrowserWorkspace browser = BrowserWorkspace(workspace, settings);

  /// AI settings of this device (off by default).
  late final AiSettings ai = AiSettings(settings);

  /// Each service's key in its own protected file (the OpenAI-compatible
  /// one keeps its earlier name), so switching services keeps both.
  File _aiKeyFileFor(AiProvider p) => File(
    '${workspace.root.path}${Platform.pathSeparator}ai${Platform.pathSeparator}'
    '${p == AiProvider.gemini ? 'gemini' : 'service'}.key',
  );

  File get _aiKeyFile => _aiKeyFileFor(ai.provider);

  /// Stores the current service's key, protected like the hub key
  /// (Windows DPAPI / iOS Keychain); never in settings, exports, logs or
  /// conversations. Null removes it.
  Future<void> setAiKey(String? key) async {
    if (key == null || key.trim().isEmpty) {
      await deleteSecret(_aiKeyFile);
    } else {
      await _aiKeyFile.parent.create(recursive: true);
      await writeSecret(_aiKeyFile, key.trim());
    }
  }

  Future<bool> get hasAiKey async => await readSecret(_aiKeyFile) != null;

  /// Makes the AI client; replaceable in tests.
  late Future<AiClient> Function() aiClient = () async => aiClientFor(
    ai,
    apiKey: ai.provider.needsKey ? await readSecret(_aiKeyFile) : null,
  );

  late final AiSession aiSession = AiSession(
    settings: ai,
    client: () => aiClient(),
    store: workspace.aiConversations,
  );

  /// Embeddings from the local model; replaceable in tests.
  late Embedder Function() aiEmbedder = () =>
      ollamaEmbedder(Uri.parse(ai.endpoint));

  SemanticIndex? _semantic;

  /// Whether search by meaning may run: AI on, the local model (nothing
  /// leaves this PC) and notes allowed.
  bool get canSearchByMeaning =>
      ai.enabled &&
      ai.provider == AiProvider.ollama &&
      ai.isLocal &&
      ai.sources.contains(AiSource.notes);

  /// Notes ranked by meaning (the user asked for it; local model only).
  Future<List<(Note, double)>> searchByMeaning(String query) async {
    if (!canSearchByMeaning || query.trim().isEmpty) return const [];
    final index = _semantic ??= SemanticIndex(aiEmbedder());
    return index.search(query, workspace.notes.all);
  }

  static const aiWindowId = 'ai';

  /// Gives [context] to the AI and opens the AI window. Nothing is sent
  /// yet: the user reviews it and presses Send. Returns false (with a
  /// message) when AI is off or this kind of content is not allowed.
  bool sendToAi(AiContext context) {
    if (!ai.enabled) {
      showToast('AI is off. Turn it on in Settings → AI.');
      return false;
    }
    if (!ai.sources.contains(context.source)) {
      showToast(
        '${context.source.label} may not be sent to AI (Settings → AI).',
      );
      return false;
    }
    aiSession.attach(context);
    openAiWindow();
    return true;
  }

  /// Opens (or brings forward) the floating AI window: the AI page in a
  /// window, sharing [aiSession] (so attached material shows there).
  void openAiWindow() {
    final open = windows.find(AppPage.ai, null);
    if (open != null && open.mode == PageMode.docked && _page == AppPage.ai) {
      return; // already in front in the main area
    }
    if (open != null && open.mode != PageMode.floating) {
      windows.float(open.id);
    } else {
      windows.open(AppPage.ai, title: 'AI', mode: PageMode.floating);
    }
  }

  // ----------------------------------------------------- page windows --

  /// Pages added to the top bar, docked, floating or minimized.
  late final PageWindows windows = PageWindows(settings, floating)
    ..onClosed = forgetPage
    ..onShow = (p) {
      // The page shown in the main area is the current destination.
      final kind = p.kind == AppPage.tasks ? AppPage.calendar : p.kind;
      if (_page != kind) {
        _page = kind;
        if (_restorablePages.contains(kind)) {
          unawaited(settings.set('lastPage', kind.name));
        }
      }
    };

  final Map<String, AiSession> _aiSessions = {};
  final Map<String, BrowserWorkspace> _browsers = {};

  /// The AI conversation of one AI window ([aiSession] for the main one).
  AiSession aiSessionFor(PageInstance? p) {
    if (p == null || p.refId == null) return aiSession;
    return _aiSessions.putIfAbsent(p.id, () {
      final session = AiSession(
        settings: ai,
        client: () => aiClient(),
        store: workspace.aiConversations,
      );
      final ref = p.refId!;
      if (!ref.startsWith('new')) session.openConversation(ref);
      // A new chat gets its conversation with the first message: the
      // window then reopens that conversation after a restart.
      session.addListener(() {
        final id = session.conversationId;
        if (id != null) windows.rebind(p.id, id);
      });
      return session;
    });
  }

  /// A fresh page in its own instance: a genuinely new note or mindmap,
  /// an independent Calendar or Archive view (same records, its own view
  /// state), a new Safari window or a new AI chat.
  Future<PageInstance> newPage(
    AppPage kind, {
    PageMode mode = PageMode.docked,
  }) async {
    switch (kind) {
      case AppPage.notes:
        final n = workspace.createNote();
        return windows.open(kind, refId: n.id, title: 'New note', mode: mode);
      case AppPage.canvas:
        final doc = CanvasDocument(
          id: newId(),
          title: 'Untitled Mindmap',
          items: const [],
          updatedAt: DateTime.now(),
          // Stamped now, so it syncs even if it is never edited.
          metaRev: workspace.clock.now(),
        );
        await canvases.save(doc);
        await _refreshList();
        return windows.open(kind, refId: doc.id, title: doc.title, mode: mode);
      case AppPage.calendar || AppPage.tasks:
        return windows.open(
          AppPage.calendar,
          refId: 'view-${newId()}',
          title: 'Calendar',
          mode: mode,
        );
      case AppPage.links:
        return windows.open(
          kind,
          refId: 'view-${newId()}',
          title: 'Archive',
          mode: mode,
        );
      case AppPage.browser:
        return windows.open(kind, refId: newId(), title: 'Safari', mode: mode);
      case AppPage.ai:
        return windows.open(
          kind,
          refId: 'new-${newId()}',
          title: 'New chat',
          mode: mode,
        );
      case AppPage.home:
        return windows.open(kind, title: 'start', mode: mode);
    }
  }

  /// Opens an Archive folder or resource in its own page.
  PageInstance openArchiveItem({
    String? folderId,
    String? assetId,
    PageMode mode = PageMode.docked,
  }) {
    final ref = assetId != null ? 'res:$assetId' : 'folder:$folderId';
    final title = assetId != null
        ? workspace.assets[assetId]?.label ?? 'Resource'
        : workspace.archiveFolders[folderId]?.name ?? 'Folder';
    return windows.open(AppPage.links, refId: ref, title: title, mode: mode);
  }

  /// Closes the page in the main area (its content stays).
  Future<void> closeActivePage() async {
    final id = windows.activeId;
    if (id != null) await windows.close(id);
  }

  /// The tabs of one Safari window ([browser] for the main one).
  BrowserWorkspace browserFor(PageInstance? p) {
    if (p == null || p.refId == null) return browser;
    return _browsers.putIfAbsent(
      p.id,
      () => BrowserWorkspace(
        workspace,
        settings,
        sessionKey: 'browser.session.${p.id}',
      ),
    );
  }

  /// Lets go of what a closed page window used.
  void forgetPage(String id) {
    _aiSessions.remove(id)?.dispose();
    _browsers.remove(id)?.dispose();
  }

  /// Reopens AI conversation [id] on the AI page.
  void openAiConversation(String id) {
    aiSession.openConversation(id);
    goTo(AppPage.ai);
  }

  /// Opens [url] in a new Safari tab (in the default browser where THEapp
  /// has no browser engine yet, i.e. Windows).
  void openInSafari(String url) {
    if (!BrowserEngine.available) {
      native.openUrl(url);
      return;
    }
    browser.newTab(url: url);
    goTo(AppPage.browser);
  }

  /// Opens thought experiment [id] in a floating window.
  void openExperiment(String id) => floating.show(experimentWindow(this, id));

  // ------------------------------------------ Google / Outlook calendars --

  /// The Google "Desktop app" client secret (Google documents it as not
  /// confidential for installed apps); kept in the secret store anyway and
  /// cached here once read.
  String? _googleClientSecret;

  File get _googleSecretFile => File(
    '${workspace.root.path}${Platform.pathSeparator}calendar'
    '${Platform.pathSeparator}google.client',
  );

  Future<void> loadCalendarSecrets() async =>
      _googleClientSecret = await readSecret(_googleSecretFile);

  Future<void> setGoogleClientSecret(String? secret) async {
    if (secret == null || secret.trim().isEmpty) {
      await deleteSecret(_googleSecretFile);
      _googleClientSecret = null;
    } else {
      await _googleSecretFile.parent.create(recursive: true);
      await writeSecret(_googleSecretFile, secret.trim());
      _googleClientSecret = secret.trim();
    }
  }

  /// The two calendar accounts (each connected and revoked on its own).
  /// Client ids are the user's own app registrations (not secret, kept in
  /// settings); see THEAPP_IMPLEMENTATION_HANDOFF.md for setup.
  late final Map<String, ExternalCalendarSync> calendarAccounts = {
    'google': ExternalCalendarSync(
      ws: workspace,
      settings: settings,
      provider: 'google',
      oauth: () => GoogleCalendarProvider.config(
        clientId: settings.get<String>('calendar.google.clientId') ?? '',
        clientSecret: _googleClientSecret,
        iosRedirect: settings.get<String>('calendar.google.iosRedirect'),
      ),
    ),
    'microsoft': ExternalCalendarSync(
      ws: workspace,
      settings: settings,
      provider: 'microsoft',
      oauth: () => MicrosoftCalendarProvider.config(
        clientId: settings.get<String>('calendar.microsoft.clientId') ?? '',
        iosRedirect: 'msauth.com.amaterasu.theapp://auth',
      ),
    ),
  };

  /// Syncs every connected calendar account that has a calendar chosen.
  Future<void> syncCalendarAccounts() async {
    for (final MapEntry(:key, :value) in calendarAccounts.entries) {
      try {
        if (value.calendarId != null && await value.connected) {
          await value.syncOnce();
        }
      } catch (error, stack) {
        // Scheduled runs are launched without awaiting them. Keep one
        // provider's unexpected storage/runtime failure from becoming an
        // unhandled background error or preventing the other account syncing.
        AppLog.error('Unexpected $key calendar sync failure', null, stack);
        await settings.set(
          'calendar.$key.status',
          'Calendar sync could not complete. Check the app log and account setup.',
        );
      }
    }
    notifyListeners();
  }

  /// The private vault (locked until the user opens it).
  late final VaultService vault = VaultService(
    meta: workspace.vaultMeta,
    items: workspace.vaultItems,
  );

  /// Opens the relationship graph in a floating window.
  void openGraph() => floating.show(graphWindow(this));

  /// Opens the private vault in a floating window.
  void openVault() => floating.show(vaultWindow(this));

  /// Text of PDF documents for search (read on this device, cached).
  late final PdfTextCache pdfTexts = PdfTextCache(
    workspace,
    ocr: (path) => ocrPdf(path, ios: ios),
    ocrEnabled: () => settings.get<bool>('ocrEnabled') ?? true,
  );

  // -------------------------------------------------------- archive --

  /// The last Archive repair, to undo it.
  ArchiveUndo? lastArchiveRepair;

  /// Checks every reference to Archive resources (all canvases are read).
  Future<(LinkReport, Map<String, Set<ResourceRef>>)> checkArchive() async {
    await flush();
    final refs = await referenceMap(workspace, canvases);
    return (checkLinks(workspace, refs), refs);
  }

  /// Runs an Archive repair after a backup; it can be undone.
  Future<void> repairArchive(ArchiveUndo Function() repair) async {
    await flush();
    await workspace.backups.snapshot('before-archive-repair');
    final undo = repair();
    lastArchiveRepair = undo.isEmpty ? null : undo;
    notifyListeners();
  }

  void undoArchiveRepair() {
    final undo = lastArchiveRepair;
    if (undo == null) return;
    undo.apply(workspace);
    lastArchiveRepair = null;
    showToast('${undo.label}: undone.');
    notifyListeners();
  }

  // ----------------------------------------------------------- clipboard --
  //
  // "Clipboard between my devices" (off by default). While on, text copied
  // anywhere on this PC (THEapp watches the system clipboard while it is
  // running) is synced through the user's own hub, and text copied on
  // another device is put on this device's clipboard, ready to paste in any
  // app. Text only, the 20 newest clips are kept.

  static const maxClips = 20;
  static const maxClipLength = 20000;

  bool get shareClipboard => settings.get<bool>('shareClipboard') ?? false;

  /// Reads the system clipboard's text; replaceable in tests.
  Future<String?> Function() readClipboardText = () async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  /// Puts text on the system clipboard; replaceable in tests.
  Future<void> Function(String text) writeClipboardText = (text) =>
      Clipboard.setData(ClipboardData(text: text));

  Timer? _clipTimer;
  String? _lastClipText;
  String? _appliedClipId;

  Future<void> setShareClipboard(bool on) async {
    await settings.set('shareClipboard', on);
    _applyClipboardSetting();
    notifyListeners();
  }

  void _applyClipboardSetting() {
    final on = shareClipboard;
    workspace.shareClipboard = on;
    _clipTimer?.cancel();
    _clipTimer = null;
    workspace.clipboard.removeListener(_onClipsChanged);
    if (!on) return;
    workspace.clipboard.addListener(_onClipsChanged);
    // iPhone/iPad ask before every paste-read, so they only share what the
    // user sends with "Share clipboard now"; Windows watches the clipboard.
    if (Platform.isWindows) {
      _clipTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(checkClipboard()),
      );
    }
  }

  /// Shares the system clipboard's text if it changed. Returns the new
  /// clip, or null.
  Future<ClipboardClip?> checkClipboard() async {
    if (!shareClipboard) return null;
    String? text;
    try {
      text = await readClipboardText();
    } catch (_) {
      return null;
    }
    if (text == null || text.trim().isEmpty || text == _lastClipText) {
      return null;
    }
    _lastClipText = text;
    if (text.length > maxClipLength) return null;
    final newest = _newestClip;
    if (newest != null && newest.text == text) return null; // came from sync
    final clip = ClipboardClip(
      id: newId(),
      text: text,
      device: workspace.device?.name ?? 'This device',
      copiedAt: clock(),
    );
    workspace.clipboard.put(clip);
    _appliedClipId = clip.id;
    final old = workspace.clipboard.all.toList()
      ..sort((a, b) => b.copiedAt.compareTo(a.copiedAt));
    for (final c in old.skip(maxClips)) {
      workspace.clipboard.remove(c.id);
    }
    return clip;
  }

  ClipboardClip? get _newestClip {
    ClipboardClip? newest;
    for (final c in workspace.clipboard.all) {
      if (newest == null || c.copiedAt.isAfter(newest.copiedAt)) newest = c;
    }
    return newest;
  }

  /// A newer clip from another device goes onto this clipboard.
  void _onClipsChanged() {
    final newest = _newestClip;
    if (newest == null || newest.id == _appliedClipId) return;
    _appliedClipId = newest.id;
    if (newest.text == _lastClipText) return;
    _lastClipText = newest.text;
    unawaited(writeClipboardText(newest.text));
  }

  // ------------------------------------------------------------ activity --

  static const _visitsKey = 'recentVisits';
  static const maxVisits = 50;

  /// Notes and mindmaps opened recently (this device only), newest first.
  List<({String kind, String id, DateTime at})> get recentVisits => [
    for (final v in settings.get<List<dynamic>>(_visitsKey) ?? const [])
      if (v is Map &&
          v['kind'] is String &&
          v['id'] is String &&
          parseDate(v['at']) != null)
        (
          kind: v['kind'] as String,
          id: v['id'] as String,
          at: parseDate(v['at'])!,
        ),
  ];

  Future<void> _recordVisit(String kind, String id) {
    final list = [
      {'kind': kind, 'id': id, 'at': utcIso(clock())},
      for (final v in recentVisits)
        if (v.id != id) {'kind': v.kind, 'id': v.id, 'at': utcIso(v.at)},
    ];
    return settings.set(_visitsKey, list.take(maxVisits).toList());
  }

  /// Start-page sections in the user's order; hidden ones are left out.
  /// Kept per device, so a tablet layout never changes the PC's.
  List<String> get homeSections {
    final saved = settings.get<List<dynamic>>('homeSections');
    if (saved == null) return defaultHomeSections;
    return [
      for (final v in saved)
        if (v is String && allHomeSections.contains(v)) v,
    ];
  }

  static const allHomeSections = [
    'today',
    'upcoming',
    'inbox',
    'notes',
    'canvases',
    'activity',
  ];
  static const defaultHomeSections = allHomeSections;

  Future<void> setHomeSections(List<String> sections) async {
    await settings.set('homeSections', sections);
    notifyListeners();
  }

  // ----------------------------------------------------- full screen --

  /// Full screen. On iPhone/iPad it is on unless turned off: the status bar
  /// stays hidden while THEapp is in front (the system may still show it,
  /// e.g. in Split View, Slide Over or Stage Manager windows, and always
  /// keeps the home indicator and edge gestures). On Windows it is off
  /// unless turned on.
  bool get immersive => settings.get<bool>('immersive') ?? Platform.isIOS;

  /// Applies full screen to the window/system bars; replaceable in tests.
  bool Function(bool on) applyImmersive = native.setImmersive;

  Future<void> toggleImmersive() async {
    final on = !immersive;
    await settings.set('immersive', on);
    applyImmersive(on);
    notifyListeners();
  }

  // --------------------------------------------------------------- tasks --

  CompletionStyle get completionStyle =>
      CompletionStyle.values.asNameMap()[settings.get<String>(
        'completionStyle',
      )] ??
      CompletionStyle.understated;

  Future<void> setCompletionStyle(CompletionStyle style) async {
    await settings.set('completionStyle', style.name);
    notifyListeners();
  }

  /// Ticks a task off (or back on). Completing says a short message (see
  /// [completionStyle]) and mentions unfinished prerequisites; it never
  /// blocks.
  void toggleTask(String id) {
    final before = workspace.tasks[id];
    if (before == null) return;
    workspace.toggleTask(id);
    if (before.done) return; // reopened
    final waiting = workspace.openPrerequisites(before);
    final message = completionMessage(completionStyle);
    if (waiting.isNotEmpty) {
      showToast(
        '${message ?? 'Done.'} Still open before it: '
        '${waiting.map((t) => t.title).take(2).join(', ')}'
        '${waiting.length > 2 ? '…' : ''}',
      );
    } else if (message != null) {
      showToast(message);
    }
  }

  void setLinkPreviews(bool on) {
    capture.fetchPreviews = on;
    settings.set('linkPreviews', on);
    notifyListeners();
  }

  // ------------------------------------------------------------ calendar --

  /// How dates are written and which day starts the week (this device).
  Future<void> setDatePrefs({DateOrder? order, int? firstWeekday}) async {
    if (order != null) {
      DatePrefs.order = order;
      await settings.set('dateOrder', order.name);
    }
    if (firstWeekday != null) {
      DatePrefs.firstWeekday = firstWeekday;
      await settings.set('firstWeekday', firstWeekday);
    }
    notifyListeners();
  }

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
    unawaited(_recordVisit('note', id));
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
        final asset = workspace.assets[item.assetId];
        if (asset?.kind == AssetKind.document) {
          final file = workspace.documentFile(asset!);
          if (file == null) {
            showToast('This document is not on this device yet.');
          } else if (!openDocument(file.path)) {
            showToast('No app could open ${asset.label}.');
          }
          return;
        }
        final url = asset?.url;
        final target = canvasLinkTarget(url);
        if (target != null) {
          // A link to another mindmap opens it inside THEapp.
          if (_canvasList.any((c) => c.id == target)) {
            unawaited(openCanvas(target));
          } else {
            showToast('That mindmap no longer exists.');
          }
          return;
        }
        if (url != null && !openUrl(url)) {
          showToast('Could not open $url');
        }
      case NoteCardItem():
        if (workspace.notes.contains(item.noteId)) {
          openNote(item.noteId);
        } else {
          showToast('That note no longer exists.');
        }
      case ImageItem():
        if (workspace.assets.contains(item.assetId)) {
          openArchiveItem(assetId: item.assetId);
        } else {
          showToast('That image reference no longer exists.');
        }
      case TextItem(:final sourceNoteId?, :final sourceNoteTitle)
          when sourceNoteId.isNotEmpty:
        if (workspace.notes.contains(sourceNoteId)) {
          openNote(sourceNoteId);
        } else {
          showToast(
            'The original note “${sourceNoteTitle ?? sourceNoteId}” is no longer available.',
          );
        }
      case TextItem() || StrokeItem() || ConnectorItem():
        break;
    }
  }

  void activateCanvasItem(CanvasItem item) => _activateCanvasItem(item);

  Future<void> openCanvas(String id, {bool show = true}) async {
    if (_canvas?.id != id) {
      await _sync?.whenIdle();
      // Already open in a window: share that controller (never two
      // controllers on one document).
      final shared = _canvasRefs[id]?.$1;
      final doc = shared == null ? await canvases.load(id) : null;
      if (shared == null && doc == null) return;
      await _closeCanvas();
      _canvas =
          shared ??
          (CanvasController(
              document: doc!,
              onSave: _saveCanvas,
              resources: resources,
              onActivate: _activateCanvasItem,
              clock: workspace.clock,
            )
            ..setEraser(
              mode: eraserMode,
              size: eraserSize,
              highlighterOnly: eraserHighlighterOnly,
            )
            ..setPen(width: canvasPenWidth)
            ..setAlignment(
              guides: alignGuidesPref,
              grid: gridSnapPref,
              size: gridSizePref,
            )
            ..setDotOpacity(dotOpacityFor(DotSurface.mindmap)));
      await settings.set('lastCanvasId', id);
    }
    if (show) {
      _canvas?.endEditing();
      _page = AppPage.canvas;
      await _recordVisit('mindmap', id);
    }
    notifyListeners();
  }

  Future<void> _saveCanvas(CanvasDocument doc) async {
    await canvases.save(doc);
    if (autoSnapshots &&
        !isLinksBoardId(doc.id) &&
        doc.id != calendarInkId &&
        !isComponentsId(doc.id)) {
      unawaited(autoSnapshot(doc));
    }
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
    // Still shown in a window: that window keeps it.
    if (!_canvasRefs.containsKey(old.id)) old.dispose();
  }

  // Mindmaps open in windows: one shared controller per document, counted.
  final Map<String, (CanvasController, int)> _canvasRefs = {};

  /// The controller for mindmap [id] for a window (shared with the main
  /// mindmap when it is the same one). Call [releaseCanvas] when done.
  Future<CanvasController?> acquireCanvas(String id) async {
    final known = _canvasRefs[id];
    if (known != null) {
      _canvasRefs[id] = (known.$1, known.$2 + 1);
      return known.$1;
    }
    CanvasController? c = _canvas?.id == id ? _canvas : null;
    if (c == null) {
      final doc = await canvases.load(id);
      if (doc == null) return null;
      // Opened meanwhile by another window or the main view.
      final again = _canvasRefs[id];
      if (again != null) {
        _canvasRefs[id] = (again.$1, again.$2 + 1);
        return again.$1;
      }
      c = _canvas?.id == id
          ? _canvas
          : (CanvasController(
                document: doc,
                onSave: _saveCanvas,
                resources: resources,
                onActivate: _activateCanvasItem,
                clock: workspace.clock,
              )
              ..setEraser(
                mode: eraserMode,
                size: eraserSize,
                highlighterOnly: eraserHighlighterOnly,
              )
              ..setPen(width: canvasPenWidth)
              ..setAlignment(
                guides: alignGuidesPref,
                grid: gridSnapPref,
                size: gridSizePref,
              )
              ..setDotOpacity(dotOpacityFor(DotSurface.mindmap)));
    }
    _canvasRefs[id] = (c!, 1);
    return c;
  }

  Future<void> releaseCanvas(String id) async {
    final known = _canvasRefs[id];
    if (known == null) return;
    if (known.$2 > 1) {
      _canvasRefs[id] = (known.$1, known.$2 - 1);
      return;
    }
    _canvasRefs.remove(id);
    final c = known.$1;
    if (!identical(c, _canvas)) {
      c.endEditing();
      await c.flush();
      c.dispose();
    }
  }

  // --------------------------------------------------------------- links --

  CanvasController? _links;
  Future<CanvasController>? _linksOpening;

  /// The Links library board, once opened (see [openLinksBoard]).
  CanvasController? get linksBoard => _links;

  /// Opens the Links library board: one canvas-like document of link cards
  /// (it may also hold ink and text). Nothing is written until something
  /// changes, so opening an empty library creates no record.
  Future<CanvasController> openLinksBoard() =>
      _linksOpening ??= _openLinksBoard();

  Future<CanvasController> _openLinksBoard() async {
    final doc =
        await canvases.load(linksBoardId) ??
        CanvasDocument(
          id: linksBoardId,
          title: 'Links',
          items: const [],
          updatedAt: DateTime.now(),
          kind: 'links',
        );
    final c = CanvasController(
      document: doc,
      onSave: saveDocument,
      resources: resources,
      onActivate: _activateCanvasItem,
      clock: workspace.clock,
    )..setDotOpacity(dotOpacityFor(DotSurface.archive));
    _links = c;
    notifyListeners();
    return c;
  }

  // The app's own canvas-like documents that are not canvases (Calendar
  // drawings, saved components). Opened once and kept open, so sync merges
  // into them and they are saved with everything else.
  final Map<String, CanvasController> _special = {};
  final Map<String, Future<CanvasController>> _specialOpening = {};

  Future<CanvasController> _openSpecial(String id, String kind, String title) =>
      _specialOpening[id] ??= () async {
        final doc =
            await canvases.load(id) ??
            CanvasDocument(
              id: id,
              title: title,
              items: const [],
              updatedAt: DateTime.now(),
              kind: kind,
            );
        final c = CanvasController(
          document: doc,
          onSave: saveDocument,
          resources: resources,
          clock: workspace.clock,
        );
        _special[id] = c;
        notifyListeners();
        return c;
      }();

  /// The Calendar's drawings, once opened (see [openCalendarInk]).
  CanvasController? get calendarInk => _special[calendarInkId];

  /// Opens the one document of Calendar drawings (each stroke sits in its
  /// date's place, see calendar_ink.dart). Nothing is written until
  /// something is drawn.
  Future<CanvasController> openCalendarInk() async {
    final c = await _openSpecial(
      calendarInkId,
      'calendarInk',
      'Calendar drawings',
    );
    if (c.tool != CanvasTool.pen && c.tool != CanvasTool.eraser) {
      c.tool = CanvasTool.pen;
    }
    c.setPen(width: calendarPenWidth);
    c.setEraser(
      mode: eraserMode,
      size: eraserSize,
      highlighterOnly: eraserHighlighterOnly,
    );
    return c;
  }

  /// The canvas tool strip and the colour/options strip, folded away or
  /// not (this device; the Mindmap and the Archive board share them, as
  /// they share the strips). Folding hides them only.
  bool get canvasToolsCollapsed =>
      settings.get<bool>('canvasToolsCollapsed') ?? false;
  bool get canvasOptionsCollapsed =>
      settings.get<bool>('canvasOptionsCollapsed') ?? false;

  Future<void> toggleCanvasTools() {
    final saved = settings.set('canvasToolsCollapsed', !canvasToolsCollapsed);
    notifyListeners(); // shown at once, saved meanwhile
    return saved;
  }

  Future<void> toggleCanvasOptions() {
    final saved = settings.set(
      'canvasOptionsCollapsed',
      !canvasOptionsCollapsed,
    );
    notifyListeners();
    return saved;
  }

  /// How visible the background dots are, per surface (this device): the
  /// Mindmap and the Archive board are set apart, since they are used
  /// differently (all mindmaps share one setting).
  double dotOpacityFor(DotSurface surface) {
    final v = settings.get<num>('dotOpacity.${surface.name}')?.toDouble();
    return v == null || !v.isFinite
        ? CanvasController.defaultDotOpacity
        : v
              .clamp(
                CanvasController.dotOpacityMin,
                CanvasController.dotOpacityMax,
              )
              .toDouble();
  }

  /// The surface [c] belongs to.
  DotSurface dotSurfaceOf(CanvasController c) =>
      c.id == linksBoardId ? DotSurface.archive : DotSurface.mindmap;

  /// Shows [value] on [c] at once and keeps it for its surface.
  Future<void> setDotOpacity(CanvasController c, double value) {
    c.setDotOpacity(value);
    return settings.set('dotOpacity.${dotSurfaceOf(c).name}', c.dotOpacity);
  }

  /// The canvas pen thickness (this device; see pen_sizes.dart). Older
  /// saved values in range load as they were; anything else is made safe.
  double get canvasPenWidth => savedPenWidth(settings.get<num>('penWidth'));

  /// Uses [width] for new strokes on [c] and keeps it for next time.
  Future<void> setCanvasPenWidth(CanvasController c, double width) {
    final w = savedPenWidth(width);
    c.setPen(width: w);
    return settings.set('penWidth', w);
  }

  /// The eraser's mode and size (this device), the same for the canvas
  /// and the Calendar.
  EraserMode get eraserMode =>
      EraserMode.values.asNameMap()[settings.get<String>('eraserMode')] ??
      EraserMode.stroke;

  bool get eraserHighlighterOnly =>
      settings.get<bool>('eraserHighlighterOnly') ?? false;

  double get eraserSize =>
      (settings.get<num>('eraserSize')?.toDouble() ?? 16).clamp(
        CanvasController.eraserSizes.min,
        CanvasController.eraserSizes.max,
      );

  // ---------------------------------------------- alignment preferences --

  bool get alignGuidesPref => settings.get<bool>('alignGuides') ?? false;
  bool get gridSnapPref => settings.get<bool>('gridSnap') ?? false;
  double get gridSizePref {
    final v = settings.get<num>('gridSize')?.toDouble();
    return v != null && CanvasController.gridSizes.contains(v) ? v : 24;
  }

  /// Turns guides / grid snapping on or off, or changes the grid size, on
  /// [c] and keeps it for next time (this device).
  Future<void> setAlignment(
    CanvasController c, {
    bool? guides,
    bool? grid,
    double? size,
  }) async {
    c.setAlignment(guides: guides, grid: grid, size: size);
    await settings.set('alignGuides', c.alignGuides);
    await settings.set('gridSnap', c.gridSnap);
    await settings.set('gridSize', c.gridSize);
  }

  /// Changes the eraser on [c] and on the other open drawings, and keeps
  /// it for next time.
  Future<void> setEraser(
    CanvasController c, {
    EraserMode? mode,
    double? size,
    bool? highlighterOnly,
  }) async {
    c.setEraser(mode: mode, size: size, highlighterOnly: highlighterOnly);
    for (final other in {_canvas, calendarInk}) {
      if (other != null && other != c) {
        other.setEraser(
          mode: c.eraserMode,
          size: c.eraserSize,
          highlighterOnly: c.eraserHighlighterOnly,
        );
      }
    }
    await settings.set('eraserMode', c.eraserMode.name);
    await settings.set('eraserSize', c.eraserSize);
    await settings.set('eraserHighlighterOnly', c.eraserHighlighterOnly);
  }

  /// Thinnest and thickest Calendar pen (world units: 1 = one point at
  /// the 38-day grid's size).
  static const calendarPenMin = 0.3;
  static const calendarPenMax = 30.0;

  /// The Calendar pen's thickness (this device's setting). Each stroke
  /// keeps the thickness it was drawn with, also through undo and sync.
  double get calendarPenWidth =>
      (settings.get<num>('calendarPenWidth')?.toDouble() ?? 2.5).clamp(
        calendarPenMin,
        calendarPenMax,
      );

  Future<void> setCalendarPenWidth(double width) {
    final w = width.clamp(calendarPenMin, calendarPenMax).toDouble();
    calendarInk?.setPen(width: w);
    return settings.set('calendarPenWidth', w);
  }

  /// Opens the document of saved reusable canvas components.
  Future<CanvasController> openComponents() =>
      _openSpecial(componentsId, 'components', 'Components');

  /// Size of one place in the Links board's grid of new cards.
  static const linkSlot = Size(340, 380);
  static const linkColumns = 4;

  /// Puts [asset] on the Links board in the first free place of its grid,
  /// or selects its card if the link is already there. Returns the card.
  Future<LinkItem> addToLinks(Asset asset, {List<String>? tags}) async {
    final c = await openLinksBoard();
    if (tags != null && tags.isNotEmpty) {
      setLinkTags(asset.id, {...asset.linkTags, ...tags}.toList());
    }
    for (final item in c.items) {
      if (item is LinkItem && item.assetId == asset.id) {
        c.select([item.id]);
        return item;
      }
    }
    final taken = [
      for (final item in c.items)
        if (item is! ConnectorItem) c.itemBounds(item),
    ];
    for (var i = 0; ; i++) {
      final slot =
          Offset(
            (i % linkColumns) * linkSlot.width,
            (i ~/ linkColumns) * linkSlot.height,
          ) &
          linkSlot;
      if (taken.any((r) => r.overlaps(slot.deflate(1)))) continue;
      final item = c.insertLink(
        asset,
        slot.topLeft + const Offset(LinkItem.defaultWidth / 2 + 20, 60),
      );
      c.select([item.id]);
      return item;
    }
  }

  /// Sets the Links library tags of link [assetId] (synced with the link).
  void setLinkTags(String assetId, List<String> tags) {
    final asset = workspace.assets[assetId];
    if (asset == null) return;
    final next = [
      for (final t in tags)
        if (t.isNotEmpty) t,
    ];
    if (listEquals(next, asset.linkTags)) return;
    workspace.assets.put(asset.copyWith(linkTags: next));
  }

  Future<void> createCanvas({
    String title = 'Untitled Canvas',
    bool withWelcome = false,
    bool show = true,
    String? folderId,
  }) async {
    final items = withWelcome ? _welcomeItems() : const <CanvasItem>[];
    final doc = CanvasDocument(
      id: newId(),
      title: title,
      updatedAt: DateTime.now(),
      folderId: folderId,
      items: items,
      // Stamped now, so it syncs even if it is never edited.
      itemRevs: {for (final i in items) i.id: workspace.clock.now()},
      metaRev: workspace.clock.now(),
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

  /// Deletes a note: all of it is kept as a version first (Recently
  /// deleted), and its handwriting and PDF pages go to the trash folder.
  Future<void> deleteNote(String noteId) async {
    workspace.deleteNote(noteId);
    await trashNotebookOf(noteId);
  }

  /// Moves the handwriting of a deleted note to the trash folder (never
  /// erased) and tells other devices, like a deleted canvas.
  Future<void> trashNotebookOf(String noteId) async {
    final id = notebookIdFor(noteId);
    if (await canvases.load(id) == null) return;
    await canvases.delete(id);
    await workspace.recordCanvasDeletion(id);
  }

  /// Brings back a deleted note from its kept version, together with its
  /// handwriting and PDF pages from the trash folder. Returns the note.
  Future<Note?> restoreDeletedNote(String versionId) async {
    final note = workspace.restoreNoteVersion(versionId);
    if (note == null) return null;
    await restoreNotebookOf(note.id);
    return note;
  }

  /// Puts a note's trashed handwriting back. Every item and the page list
  /// get new revisions, so the restored copy wins over the deletion on
  /// every device. Does nothing if the notebook exists or none was kept.
  Future<bool> restoreNotebookOf(String noteId) async {
    final id = notebookIdFor(noteId);
    if (await canvases.load(id) != null) return false;
    final json = await workspace.store.readFromTrash('canvases', id);
    if (json == null) return false;
    final trashed = CanvasDocument.fromJson(json);
    final clock = workspace.clock;
    clock.observe(workspace.canvasTombstones[id]);
    await canvases.save(
      CanvasDocument(
        id: id,
        title: trashed.title,
        items: trashed.items,
        updatedAt: DateTime.now(),
        viewport: trashed.viewport,
        folderId: trashed.folderId,
        itemRevs: {for (final i in trashed.items) i.id: clock.now()},
        tombstones: trashed.tombstones,
        metaRev: clock.now(),
        unknownItems: trashed.unknownItems,
        itemUnknownFields: trashed.itemUnknownFields,
        unknownKeys: trashed.unknownKeys,
        metaUnknownFields: trashed.metaUnknownFields,
        kind: trashed.kind ?? 'notebook',
        pageBackgrounds: trashed.pageBackgrounds,
        layers: trashed.layers,
      ),
    );
    await workspace.forgetCanvasDeletion(id);
    AppLog.info('Restored a note\'s handwriting from the trash');
    return true;
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
    await _links?.flush();
    for (final c in _special.values) {
      await c.flush();
    }
    await workspace.flush();
    // Settings and any other direct writes still in flight.
    await workspace.store.flush();
  }

  static List<CanvasItem> _welcomeItems() => [
    TextItem(
      id: welcomeGuideItemId,
      position: const Offset(0, 0),
      width: 460,
      minHeight: 0,
      fontSize: 16,
      text: touchFirst
          ? '# Welcome to your canvas\n'
                '- Drag this guide to the top or either side to dismiss it\n'
                '- Double-tap empty space to write a note\n'
                '- Drag to move, use the corner handle to resize\n'
                '- Select a note to change size, **bold**, colours\n'
                '- Pick the pen to draw; while Apple Pencil touches the '
                'screen, your hand is ignored\n'
                '- Pinch with two fingers to zoom and move around\n'
                '- **Quick Add** captures text, links and photos from anywhere'
          : '# Welcome to your canvas\n'
                '- Drag this guide to the top or either side to dismiss it\n'
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
    handoff.stop();
    _scheduler?.stop();
    unawaited(maintenance?.stop(wait: Duration.zero));
    unawaited(hubHost?.stop());
    _calendarSyncTimer?.cancel();
    _pencilTaps?.cancel();
    if (_listeningForEdits) workspace.changes.removeListener(_editedLocally);
    _widgetTimer?.cancel();
    _widgetMidnight?.cancel();
    for (final c in [workspace.tasks, workspace.entries, workspace.projects]) {
      c.removeListener(_scheduleWidgetUpdate);
    }
    _reminderTimer?.cancel();
    _clipTimer?.cancel();
    _transferTimer?.cancel();
    workspace.tasks.removeListener(checkReminders);
    _sync?.client.close();
    sendTo.dispose();
    themeModePreference.dispose();
    timer.dispose();
    _canvas?.dispose();
    _links?.dispose();
    for (final c in _special.values) {
      c.dispose();
    }
    for (final (c, _) in _canvasRefs.values) {
      if (!identical(c, _canvas)) c.dispose();
    }
    for (final s in [..._aiSessions.values, ..._browsers.values]) {
      s.dispose();
    }
    resources.dispose();
    super.dispose();
  }
}

/// Gives the sync engine access to the canvas open on screen.
class _SyncBridge implements OpenCanvasBridge {
  _SyncBridge(this.state);

  final AppState state;

  CanvasController? _open(String id) {
    if (state._canvas?.id == id) return state._canvas;
    if (state.openNotebookFor(id) case final c?) return c;
    if (state._canvasRefs[id] case (final c, _)) return c;
    if (state._links?.id == id) return state._links;
    if (state._special[id] case final c?) return c;
    return null;
  }

  @override
  bool isOpen(String canvasId) => _open(canvasId) != null;

  @override
  Future<void> flushOpenCanvas() async {
    await state._canvas?.flush();
    for (final c in [...state.openNotebooks]) {
      await c.flush();
    }
    for (final (c, _) in state._canvasRefs.values.toList()) {
      await c.flush();
    }
    await state._links?.flush();
    for (final c in state._special.values) {
      await c.flush();
    }
  }

  @override
  Set<String> applyToOpenCanvas(
    String canvasId,
    List<SyncChange> changes,
    bool Function(String key, String? localRev) isPending,
  ) => _open(canvasId)?.applyRemote(changes, isPending) ?? const {};

  @override
  bool mergeOpenPages(String canvasId, List<PageBackground> ours) {
    final c = _open(canvasId);
    if (c == null) return false;
    final merged = mergePageBackgrounds(c.pageBackgrounds, ours);
    if (merged == null) return false;
    c.setPageBackgrounds(merged);
    return true;
  }
}
