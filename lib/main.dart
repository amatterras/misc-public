import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'app/shell.dart';
import 'app/theme.dart';
import 'data/repositories/canvas_repository.dart';
import 'data/storage/app_log.dart';
import 'data/storage/json_file_store.dart';
import 'data/workspace.dart';
import 'features/capture/send_to.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = defaultDataDirectory();
  AppLog.init(root);

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

  final bridge = SendToBridge(root);
  // Launched from Explorer's "Send to": hand the files to the running
  // window (if there is one) and quit.
  if (await bridge.forward(args)) exit(0);
  // Only one THEapp window may use the data folder at a time; two would
  // overwrite each other's changes. Bring the open one forward instead.
  if (await bridge.isAnotherInstanceRunning()) {
    await bridge.requestFocus();
    exit(0);
  }
  AppLog.info('Started (pid $pid)');

  final workspace = Workspace(root);
  final state = AppState(
    canvases: FileCanvasRepository(workspace.store),
    settings: SettingsRepository(workspace.store),
    workspace: workspace,
  );
  await state.init();
  runApp(TheApp(state: state));
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
          await widget.state.flush();
          AppLog.info('Window closed; all changes saved');
        } catch (e, s) {
          AppLog.error('Saving on exit failed', e, s);
        }
        return AppExitResponse.exit;
      },
      onInactive: () => unawaited(widget.state.flush()),
      onHide: () => unawaited(widget.state.flush()),
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
                color: OrganizerColors.amber,
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
