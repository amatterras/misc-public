import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:flutter/foundation.dart' show kProfileMode, kReleaseMode;
import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'app/build_info.dart';
import 'app/interface_version.dart';
import 'app/test_environment.dart';
import 'app/shell.dart';
import 'app/startup.dart';
import 'app/theme.dart';
import 'data/repositories/canvas_repository.dart';
import 'data/storage/app_log.dart';
import 'data/storage/attachment_store.dart';
import 'data/storage/backup_service.dart';
import 'data/storage/encryption_migration.dart';
import 'data/storage/storage_encryption.dart';
import 'data/storage/json_file_store.dart';
import 'data/storage/recovery_service.dart';
import 'data/workspace.dart';
import 'features/browser/webview_selftest.dart';
import 'features/capture/send_to.dart';
import 'platform/app_lock.dart';
import 'platform/device_idiom.dart';
import 'platform/file_protection.dart';
import 'platform/ios_bridge.dart';
import 'sync/secret_store.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final progress = StartupProgress();
  try {
    await _start(args, progress);
  } catch (e, s) {
    // Shown on screen (never a blank window), and logged.
    AppLog.error('Start-up failed at "${progress.step}"', e, s);
    progress.fail(e, s);
    runApp(StartupApp(progress: progress));
  }
}

Future<void> _start(List<String> args, StartupProgress progress) async {
  if (Platform.isIOS) {
    // iOS does not set HOME for apps: ask iOS for the app's real folders
    // (without this the data folder was a relative path iOS refused).
    try {
      final folders = await IosBridge.instance.appFolders();
      iosApplicationSupport = folders?['applicationSupport'];
      iosDocuments = folders?['documents'];
      // iPhone or iPad (decides the New interface's shell, not the width).
      DeviceIdiom.resolve(await IosBridge.instance.deviceModel());
    } catch (e) {
      debugPrint('App folders not reported by iOS ($e); using fallbacks');
    }
  }
  // Normally %APPDATA%\THEapp. `--data-dir=<test folder>` switches to a
  // prepared, disposable test folder (manual testing only).
  final real = defaultDataDirectory();
  final Directory root;
  try {
    TestEnvironment.dataDir = TestEnvironment.fromArgs(
      args,
      realDirs: [
        real,
        Directory('${real.parent.path}${Platform.pathSeparator}THEapp-hub'),
      ],
    );
    root = TestEnvironment.dataDir ?? real;
  } on TestEnvironmentError catch (e) {
    // Nothing has been read or written yet.
    runApp(
      MaterialApp(
        theme: buildAppTheme(),
        home: _DataProblemPage(message: e.message),
      ),
    );
    return;
  }
  // iPhone/iPad: a copy of the log in the app's Documents folder, readable
  // in the Files app (On My iPad → THEapp), unlike the data folder.
  File? logCopy;
  if (Platform.isIOS) {
    try {
      final documents = iosFolder(
        'Documents',
        reported: iosDocuments,
        home: Platform.environment['HOME'],
        systemTemp: Directory.systemTemp.path,
      );
      logCopy = File('$documents/THEapp-log.txt');
    } on FileSystemException catch (e) {
      debugPrint('No Documents folder for the log copy: $e');
    }
  }
  if (logCopy != null) {
    startupLogHint =
        'Full log on the iPad: Files → On My iPad → misc. → THEapp-log.txt';
  }
  AppLog.init(root, copy: logCopy);
  if (Platform.isIOS) {
    // Everything private is NSFileProtectionComplete, including files made
    // by earlier versions and the temporary folder.
    FileProtection.backend = IosBridge.instance;
    await FileProtection.start();
    await FileProtection.protect([
      root.path,
      ?logCopy?.parent.path,
      Directory.systemTemp.path,
    ], tree: true);
  }

  // Release builds: a part of the screen that fails to build says why,
  // instead of showing a plain grey box.
  if (kReleaseMode || kProfileMode) ErrorWidget.builder = readableErrorWidget;

  // Unexpected errors are written to the local log instead of vanishing.
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.error('UI error', details.exception, details.stack);
    defaultOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.error('Unhandled error', error, stack);
    return true;
  };

  if (Platform.isWindows) {
    final bridge = SendToBridge(root);
    // Launched from Explorer's "Send to": hand the files to the running
    // window (if there is one) and quit.
    if (await bridge.forward(args)) exit(0);
    // Only one THEapp window may use the data folder at a time; two would
    // overwrite each other's changes. Bring the open one forward instead.
    // (iOS runs one copy by itself; there, an old heartbeat file would make
    // a quick relaunch quit at once.)
    if (await bridge.isAnotherInstanceRunning()) {
      await bridge.requestFocus();
      exit(0);
    }
  }
  // Something on screen at once: the start-up steps below can take a moment
  // (and if one fails or hangs, this screen says which).
  runApp(StartupApp(progress: progress));

  // iPhone/iPad keep the hub token in the Keychain.
  if (Platform.isIOS) secretKeychain = IosBridge.instance;
  AppLog.info(
    'Started build $appBuild (pid $pid, ${Platform.operatingSystem} '
    '${Platform.operatingSystemVersion})'
    '${TestEnvironment.active ? ' in TEST DATA mode' : ''}',
  );

  // Encryption at rest (data/storage/storage_encryption.dart). Without the
  // key of already-encrypted data nothing is opened, changed or replaced.
  progress.to('Opening the encryption key');
  final encryption = await StorageEncryption.open(root);
  if (encryption.status == EncryptionStatus.keyMissing) {
    AppLog.error('Encrypted data found but no key: ${encryption.message}');
    runApp(
      MaterialApp(
        theme: buildAppTheme(),
        home: _DataProblemPage(message: encryption.message, recoveryRoot: root),
      ),
    );
    return;
  }
  StorageEncryption.active = encryption.cipher;
  AttachmentStore.clearViewCopies(); // decrypted view copies never outlive a run
  String? encryptionNotice;
  if (encryption.cipher == null) {
    AppLog.warn(encryption.message);
  } else {
    progress.to('Encrypting your data');
    final upgrade = await migrateToEncrypted(
      root,
      encryption.cipher!,
      backups: BackupService(root),
      extraBackupRoots: [?AppState.backupCopiesFolder()],
    );
    if (!upgrade.complete) {
      encryptionNotice =
          'Encrypting your existing data is not finished: '
          '${upgrade.problems.first} Nothing was lost; it will be tried again.';
    }
  }

  progress.to('Opening the data folder');
  final workspace = Workspace(root);
  if (encryptionNotice != null) {
    workspace.store.recoveries.add(encryptionNotice);
  }
  final state = AppState(
    canvases: FileCanvasRepository(workspace.store),
    settings: SettingsRepository(workspace.store),
    workspace: workspace,
    enableSendTo: Platform.isWindows,
  );
  await state.init(onStep: progress.to);
  // Face ID / Touch ID lock (iPhone/iPad only; see platform/app_lock.dart).
  // Disabled on purpose: THEapp opens without Face ID / Touch ID / passcode.
  const AppLockController? lock = null;
  runApp(TheApp(state: state, appLock: lock));
  if (lock != null) {
    unawaited(
      lock.start().then(
        (_) => state.setAppLockActive(lock.state != AppLockState.disabled),
      ),
    );
  }
  // Unattended check of the Windows browser engine (test data mode only).
  const selfTest = '--webview-selftest=';
  final check = args.where((a) => a.startsWith(selfTest)).firstOrNull;
  if (check != null && TestEnvironment.active && Platform.isWindows) {
    unawaited(runWebViewSelfTest(check.substring(selfTest.length)));
  }
}

class TheApp extends StatefulWidget {
  const TheApp({super.key, required this.state, this.appLock});

  final AppState state;

  /// Covers the workspace until Face ID / Touch ID succeeds (null: no lock).
  final AppLockController? appLock;

  @override
  State<TheApp> createState() => _TheAppState();
}

class _TheAppState extends State<TheApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Save pending changes when the window is closed or loses focus.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        try {
          // Lets a running backup or sync finish, saves, stops the hub.
          await widget.state.shutdown();
          AttachmentStore.clearViewCopies();
          AppLog.info('Window closed; all changes saved');
        } catch (e, s) {
          AppLog.error('Saving on exit failed', e, s);
        }
        return AppExitResponse.exit;
      },
      // Covering first, saving second: the screen is hidden before anything
      // slow happens. Pending edits are written either way (the cover only
      // hides the app, it never stops it).
      onInactive: () {
        widget.appLock?.lifecycleChanged(AppLifecycleState.inactive);
        unawaited(widget.state.flush());
      },
      onHide: () {
        widget.appLock?.lifecycleChanged(AppLifecycleState.hidden);
        widget.state.vault.lock(); // the private vault never stays open hidden
        AttachmentStore.clearViewCopies();
        unawaited(widget.state.flush());
      },
      onPause: () {
        widget.appLock?.lifecycleChanged(AppLifecycleState.paused);
        widget.state.vault.lock();
        AttachmentStore.clearViewCopies();
        widget.state.syncPaused();
      },
      // Back in front: pick up items shared while away (iPhone/iPad) and
      // sync if the last sync is not recent (timers stop in the background).
      onResume: () {
        widget.appLock?.lifecycleChanged(AppLifecycleState.resumed);
        unawaited(widget.state.appResumed());
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.state.themeModePreference,
        widget.state.interfaceVersionListenable,
      ]),
      builder: (context, _) {
        final rawMode = widget.state.themeModePreference.value;
        final mode = ThemeMode.values.asNameMap()[rawMode] ?? ThemeMode.dark;
        AppColors.mode = mode;
        // New interface: its own palette everywhere (see AppColors).
        AppColors.newDesign =
            widget.state.interfaceVersion == InterfaceVersion.newDesign;
        return MaterialApp(
          title: 'misc.',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(brightness: Brightness.light),
          darkTheme: buildAppTheme(brightness: Brightness.dark),
          themeMode: mode,
          builder: widget.appLock == null
              ? null
              : (context, child) =>
                    AppLockGate(controller: widget.appLock!, child: child!),
          home: widget.state.dataProblem == null
              ? AppShell(state: widget.state)
              : _DataProblemPage(state: widget.state),
        );
      },
    );
  }
}

/// Shown instead of the app when the data can't be opened safely. After a
/// failed upgrade it offers Retry and Restore (never "reset" or "clear").
class _DataProblemPage extends StatefulWidget {
  const _DataProblemPage({this.state, this.message, this.recoveryRoot});

  final AppState? state;

  /// The data folder when its keys are missing: a recovery code can bring
  /// them back (see data/storage/recovery_service.dart).
  final Directory? recoveryRoot;

  /// Shown when there is no app state yet (bad test-data folder).
  final String? message;

  @override
  State<_DataProblemPage> createState() => _DataProblemPageState();
}

class _DataProblemPageState extends State<_DataProblemPage> {
  bool _busy = false;
  String? _result;
  final _code = TextEditingController();
  String? _recoveryMessage;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _useRecoveryCode() async {
    setState(() => _busy = true);
    final r = await RecoveryService(widget.recoveryRoot!).restore(_code.text);
    if (mounted) {
      setState(() {
        _busy = false;
        _recoveryMessage = r.message;
      });
    }
  }

  Future<void> _run(Future<String> Function() action) async {
    setState(() => _busy = true);
    final result = await action();
    if (mounted) {
      setState(() {
        _busy = false;
        _result = result;
      });
    }
  }

  Future<void> _restore() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore the data from before the upgrade?'),
        content: const Text(
          'The current data folder is backed up first, then replaced by the '
          'verified copy made just before the upgrade. Photos and PDFs are '
          'only ever added back, never removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-restore-before-migration'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (yes == true) await _run(widget.state!.restoreBeforeMigration);
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message ?? widget.state?.dataProblem ?? '';
    final failure = widget.state?.migrationFailure;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield_outlined, size: 40, color: AppColors.warm),
              const SizedBox(height: Space.lg),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, height: 1.5),
              ),
              const SizedBox(height: Space.md),
              if (widget.recoveryRoot != null &&
                  RecoveryService(widget.recoveryRoot!).file.existsSync()) ...[
                const SizedBox(height: Space.lg),
                const Text(
                  'If you saved a recovery code, enter it to get access back.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Space.sm),
                TextField(
                  key: const ValueKey('recovery-code-input'),
                  controller: _code,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    hintText: 'XXXX-XXXX-XXXX-…',
                  ),
                ),
                const SizedBox(height: Space.sm),
                FilledButton(
                  key: const ValueKey('recovery-code-restore'),
                  onPressed: _busy ? null : _useRecoveryCode,
                  child: const Text('Restore access'),
                ),
                if (_recoveryMessage != null) ...[
                  const SizedBox(height: Space.sm),
                  Text(_recoveryMessage!, textAlign: TextAlign.center),
                ],
              ],
              if (failure != null) ...[
                const SizedBox(height: Space.lg),
                Wrap(
                  spacing: Space.md,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton(
                      key: const ValueKey('retry-migration'),
                      onPressed: _busy
                          ? null
                          : () => _run(widget.state!.retryMigrations),
                      child: const Text('Retry the upgrade'),
                    ),
                    if (failure.backup != null)
                      OutlinedButton(
                        key: const ValueKey('restore-before-migration'),
                        onPressed: _busy ? null : _restore,
                        child: const Text('Restore the backup'),
                      ),
                  ],
                ),
                if (_result != null) ...[
                  const SizedBox(height: Space.md),
                  Text(
                    _result!,
                    key: const ValueKey('migration-action-result'),
                    textAlign: TextAlign.center,
                  ),
                ],
                if (failure.backup != null) ...[
                  const SizedBox(height: Space.md),
                  SelectableText(
                    'Backup: ${failure.backup!.path}',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ],
              const SizedBox(height: Space.md),
              Text(
                'Nothing was deleted. Data folder: ${widget.state?.workspace.root.path ?? defaultDataDirectory().path}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
