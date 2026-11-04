// What THEapp shows while it starts, so start-up is never a blank screen:
// the current step, a notice when a step takes too long, and the error with
// the latest log lines when start-up fails (ready for a screenshot).
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/storage/app_log.dart';
import 'theme.dart';

/// The start-up step that is running, or the error that stopped it.
class StartupProgress extends ChangeNotifier {
  String step = 'Starting';
  DateTime stepSince = DateTime.now();
  Object? error;
  StackTrace? stack;

  void to(String name) {
    step = name;
    stepSince = DateTime.now();
    notifyListeners();
  }

  void fail(Object e, StackTrace s) {
    error = e;
    stack = s;
    notifyListeners();
  }
}

/// Where the log can be read without a computer (set on iPhone/iPad).
String? startupLogHint;

class StartupApp extends StatelessWidget {
  const StartupApp({super.key, required this.progress});

  final StartupProgress progress;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'misc.',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: StartupScreen(progress: progress),
  );
}

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key, required this.progress});

  final StartupProgress progress;

  /// A step running longer than this is reported as stuck.
  static Duration stuckAfter = const Duration(seconds: 15);

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _changed());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tick.cancel();
    widget.progress.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.progress;
    final failed = p.error != null;
    final stuck =
        !failed &&
        DateTime.now().difference(p.stepSince) >= StartupScreen.stuckAfter;
    final log = AppLog.session.length > 12
        ? AppLog.session.sublist(AppLog.session.length - 12)
        : AppLog.session;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'misc.',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: Space.lg),
                  if (!failed && !stuck)
                    Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: Space.md),
                        Text(
                          '${p.step}…',
                          key: const ValueKey('startup-step'),
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  if (stuck)
                    Text(
                      'Still waiting for: ${p.step} '
                      '(${DateTime.now().difference(p.stepSince).inSeconds} s). '
                      'Please take a screenshot of this screen.',
                      key: const ValueKey('startup-stuck'),
                      style: TextStyle(color: AppColors.warm),
                    ),
                  if (failed) ...[
                    Text(
                      'misc. could not start (step: ${p.step}). Nothing was '
                      'deleted. Please take a screenshot of this screen.',
                      key: const ValueKey('startup-error'),
                      style: TextStyle(color: AppColors.danger),
                    ),
                    const SizedBox(height: Space.md),
                    SelectableText(
                      '${p.error}\n'
                      '${(p.stack?.toString() ?? '').split('\n').take(8).join('\n')}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                  if (failed || stuck) ...[
                    const SizedBox(height: Space.lg),
                    Text(
                      'Latest log lines',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: Space.sm),
                    SelectableText(
                      log.join('\n'),
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                    if (startupLogHint != null) ...[
                      const SizedBox(height: Space.md),
                      Text(
                        startupLogHint!,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textFaint,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Replaces Flutter's plain grey box (release builds) for a part of the
/// screen that failed to build: it says what went wrong instead.
Widget readableErrorWidget(FlutterErrorDetails details) => Directionality(
  textDirection: TextDirection.ltr,
  child: ColoredBox(
    color: AppColors.background,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        'This part of misc. could not be shown: ${details.exceptionAsString()}',
        style: TextStyle(color: AppColors.danger, fontSize: 12),
        maxLines: 6,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  ),
);
