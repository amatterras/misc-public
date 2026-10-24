import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:flutter/foundation.dart' show kProfileMode, kReleaseMode;
import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'app/build_info.dart';
import 'app/test_environment.dart';
import 'app/shell.dart';
import 'app/startup.dart';
import 'app/theme.dart';
import 'data/repositories/canvas_repository.dart';
import 'data/storage/app_log.dart';
import 'data/storage/json_file_store.dart';
import 'data/workspace.dart';
import 'features/browser/webview_selftest.dart';
import 'features/capture/send_to.dart';
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
        'Full log on the iPad: Files → On My iPad → THEapp → THEapp-log.txt';
  }
  AppLog.init(root, copy: logCopy);

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

  progress.to('Opening the data folder');
  final workspace = Workspace(root);
  final state = AppState(
    canvases: FileCanvasRepository(workspace.store),
    settings: SettingsRepository(workspace.store),
    workspace: workspace,
    enableSendTo: Platform.isWindows,
  );
  await state.init(onStep: progress.to);
  runApp(TheApp(state: state));
  // Unattended check of the Windows browser engine (test data mode only).
  const selfTest = '--webview-selftest=';
  final check = args.where((a) => a.startsWith(selfTest)).firstOrNull;
  if (check != null && TestEnvironment.active && Platform.isWindows) {
    unawaited(runWebViewSelfTest(check.substring(selfTest.length)));
  }
}

class TheApp extends StatefulWidget {
  const TheApp({super.key, required this.state});

  final AppState state;

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
          AppLog.info('Window closed; all changes saved');
        } catch (e, s) {
          AppLog.error('Saving on exit failed', e, s);
        }
        return AppExitResponse.exit;
      },
      onInactive: () => unawaited(widget.state.flush()),
      onHide: () {
        widget.state.vault.lock(); // the private vault never stays open hidden
        unawaited(widget.state.flush());
      },
      onPause: () {
        widget.state.vault.lock();
        widget.state.syncPaused();
      },
      // Back in front: pick up items shared while away (iPhone/iPad) and
      // sync if the last sync is not recent (timers stop in the background).
      onResume: () => unawaited(widget.state.appResumed()),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'THEapp',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: widget.state.dataProblem == null
          ? AppShell(state: widget.state)
          : _DataProblemPage(message: widget.state.dataProblem!),
    );
  }
}

/// Shown instead of the app when the data can't be opened safely.
class _DataProblemPage extends StatelessWidget {
  const _DataProblemPage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.shield_outlined,
                size: 40,
                color: AppColors.warm,
              ),
              const SizedBox(height: Space.lg),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, height: 1.5),
              ),
              const SizedBox(height: Space.md),
              Text(
                'Nothing was changed. Data folder: ${defaultDataDirectory().path}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
