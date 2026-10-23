import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../data/models/canvas_models.dart';

import '../data/models/library_models.dart';
import '../data/models/record.dart';
import '../data/models/task_models.dart';
import '../data/repositories/canvas_repository.dart';
import '../data/repositories/record_collection.dart';
import '../data/storage/app_log.dart';
import '../data/workspace.dart';
import '../features/canvas/canvas_controller.dart';
import '../features/canvas/canvas_resources.dart';
import '../features/capture/capture_service.dart';
import '../features/capture/send_to.dart';
import '../features/widgets/widget_snapshot.dart';
import '../platform/ios_bridge.dart';
import '../platform/input_hints.dart';
import '../platform/platform.dart' as native;
import '../sync/protocol.dart';
import '../sync/secret_store.dart';
import '../sync/sync_client.dart';
import '../sync/sync_engine.dart';
import 'test_environment.dart';

enum AppPage { home, canvas, notes, links, calendar, tasks }

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

  /// The handwriting of the note open in the note editor, if any (set by
  /// the editor), so sync merges remote changes into it.
  CanvasController? openNotebook;

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

  /// Opens the data and starts the background services. [onStep] is told
  /// which step is running, for the start-up screen and the log.
  Future<void> init({void Function(String step)? onStep}) async {
    void step(String name) {
      AppLog.info('Start-up: $name');
      onStep?.call(name);
    }

    step('Loading settings');
    await settings.load();
    step('Loading your data');
    await workspace.load();
    _sidebarCollapsed = settings.get<bool>('sidebarCollapsed') ?? false;
    capture.fetchPreviews = settings.get<bool>('linkPreviews') ?? true;

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
    step('Starting sync');
    await _startSyncIfPaired();
    step('Starting reminders');
    _startReminders();
    step('Ready');
  }

  // ---------------------------------------------------------------- sync --
  //
  // Optional. Until this PC's app is paired with a hub nothing here runs.
  // The app never depends on the hub: if it is off, edits wait locally and
  // go out on a later attempt.

  static const syncInterval = Duration(minutes: 1);
  SyncEngine? _sync;
  Timer? _syncTimer;
  Timer? _firstSync;
  bool syncing = false;
  String? hubUrl;
  String syncStatus = 'Not set up';
  DateTime? lastSynced;

  File get _hubTokenFile => File(
    '${workspace.root.path}${Platform.pathSeparator}sync${Platform.pathSeparator}hub.token',
  );

  bool get syncPaired => _sync != null;

  /// The hub rejected this device's token; automatic sync is stopped until
  /// the device is paired again.
  bool syncNeedsPairing = false;

  /// Whether automatic (timed) sync is currently scheduled.
  bool get syncScheduled => _syncTimer?.isActive ?? false;

  Future<void> _startSyncIfPaired() async {
    final config = await workspace.store.read('sync', 'hub');
    final url = config?['url'] as String?;
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
    _sync = SyncEngine(
      workspace: workspace,
      canvases: canvases,
      client: SyncClient(url, token: token),
      openCanvas: _SyncBridge(this),
    );
    hubUrl = url.toString();
    syncNeedsPairing = false;
    syncStatus = 'Waiting for first sync';
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(syncInterval, (_) => syncNow());
    _firstSync?.cancel();
    _firstSync = Timer(const Duration(seconds: 3), syncNow);
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
    await importSharedItems();
    final last = lastSynced;
    if (_sync == null || syncNeedsPairing || syncing) return;
    if (last != null && DateTime.now().difference(last) < resumeSyncAfter) {
      return;
    }
    await syncNow();
  }

  static const resumeSyncAfter = Duration(seconds: 20);

  /// Stops syncing and forgets the hub (local data is untouched).
  Future<void> disconnectHub() async {
    syncNeedsPairing = false;
    _syncTimer?.cancel();
    _firstSync?.cancel();
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
      if (e.code == 'unauthorized') {
        // Removed with `thehub revoke`, or the hub was replaced: retrying
        // every minute cannot help. Nothing local is lost; unsent changes
        // stay queued and go out after pairing again.
        _syncTimer?.cancel();
        _firstSync?.cancel();
        syncNeedsPairing = true;
        syncStatus =
            'This hub no longer accepts this device (it was removed, or the '
            'hub was reset). Your data here is safe. Disconnect, then pair '
            'again with a new code.';
        AppLog.warn('Sync stopped: device not accepted by the hub');
      } else {
        syncStatus = e.retryable ? '${e.message} Will retry.' : e.message;
        if (!e.retryable) AppLog.warn('Sync stopped: ${e.code}');
      }
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
          itemUnknownFields: doc.itemUnknownFields,
          unknownKeys: doc.unknownKeys,
          metaUnknownFields: doc.metaUnknownFields,
          kind: doc.kind,
          pageBackgrounds: doc.pageBackgrounds,
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
    _canvasList = [
      for (final c in await canvases.listCanvases())
        if (c.isCanvas) c,
    ];
    notifyListeners();
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
  Future<void> _startIosCapture(IosBridge ios) async {
    final shared = await ios.sharedContainerPath();
    _sharedInbox = shared == null ? null : SendToBridge(Directory(shared));
    await importSharedItems();
    await ios.listenForLinks((uri) async {
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

  void showToast(String message) {
    toast.value = message;
    Timer(const Duration(seconds: 3), () {
      if (toast.value == message) toast.value = null;
    });
  }

  void goTo(AppPage page) {
    if (page == _page) return;
    _canvas?.endEditing();
    _links?.endEditing();
    if (page == AppPage.links) unawaited(openLinksBoard());
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
        if (url != null && !openUrl(url)) {
          showToast('Could not open $url');
        }
      case NoteCardItem():
        if (workspace.notes.contains(item.noteId)) {
          openNote(item.noteId);
        } else {
          showToast('That note no longer exists.');
        }
      case TextItem() || ImageItem() || StrokeItem() || ConnectorItem():
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
      onSave: canvases.save,
      resources: resources,
      onActivate: _activateCanvasItem,
      clock: workspace.clock,
    );
    _links = c;
    notifyListeners();
    return c;
  }

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
  /// Moves the handwriting of a deleted note to the trash folder (never
  /// erased) and tells other devices, like a deleted canvas.
  Future<void> trashNotebookOf(String noteId) async {
    final id = notebookIdFor(noteId);
    if (await canvases.load(id) == null) return;
    await canvases.delete(id);
    await workspace.recordCanvasDeletion(id);
  }

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
    await workspace.flush();
    // Settings and any other direct writes still in flight.
    await workspace.store.flush();
  }

  static List<CanvasItem> _welcomeItems() => [
    TextItem(
      id: newId(),
      position: const Offset(0, 0),
      width: 460,
      minHeight: 0,
      fontSize: 16,
      text: touchFirst
          ? '# Welcome to your canvas\n'
                '- Double-tap empty space to write a note\n'
                '- Drag to move, use the corner handle to resize\n'
                '- Select a note to change size, **bold**, colours\n'
                '- Pick the pen to draw; while Apple Pencil touches the '
                'screen, your hand is ignored\n'
                '- Pinch with two fingers to zoom and move around\n'
                '- **Quick Add** captures text, links and photos from anywhere'
          : '# Welcome to your canvas\n'
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
    _widgetTimer?.cancel();
    _widgetMidnight?.cancel();
    for (final c in [workspace.tasks, workspace.entries, workspace.projects]) {
      c.removeListener(_scheduleWidgetUpdate);
    }
    _firstSync?.cancel();
    _reminderTimer?.cancel();
    workspace.tasks.removeListener(checkReminders);
    _sync?.client.close();
    sendTo.dispose();
    timer.dispose();
    _canvas?.dispose();
    _links?.dispose();
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
    if (state.openNotebook?.id == id) return state.openNotebook;
    if (state._links?.id == id) return state._links;
    return null;
  }

  @override
  bool isOpen(String canvasId) => _open(canvasId) != null;

  @override
  Future<void> flushOpenCanvas() async {
    await state._canvas?.flush();
    await state.openNotebook?.flush();
    await state._links?.flush();
  }

  @override
  Set<String> applyToOpenCanvas(
    String canvasId,
    List<SyncChange> changes,
    bool Function(String key, String? localRev) isPending,
  ) => _open(canvasId)?.applyRemote(changes, isPending) ?? const {};
}
