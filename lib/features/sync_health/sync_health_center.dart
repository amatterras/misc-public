// Sync Health and Recovery Center: one window that says, in plain words,
// whether this device's data is safe and in step, what is waiting, and the
// safe next step. Every action here is non-destructive: it syncs, shows
// conflicts, makes a backup, copies a scrubbed report, or starts re-pairing
// through the existing verified flow. Nothing is deleted or overwritten.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../sync/storage_modes.dart';
import '../../sync/sync_health.dart';
import '../settings/storage_section.dart' show showStorageSwitchDialog;
import '../settings/sync_section.dart' show showConflictsDialog;

SyncFacts syncFactsOf(AppState s, int pending) => SyncFacts(
  paired: s.syncPaired,
  needsPairing: s.syncNeedsPairing,
  enabled: s.syncEnabled,
  connection: s.syncConnection,
  syncing: s.syncing,
  lastSynced: s.lastSynced,
  pendingCount: pending,
  conflictCount: s.workspace.conflicts.length,
  lastAttemptFailed: s.syncHistory.isNotEmpty && !s.syncHistory.last.ok,
);

Color levelColor(SyncLevel l) => switch (l) {
  SyncLevel.ok => AppColors.success,
  SyncLevel.waiting => AppColors.accent,
  SyncLevel.attention => AppColors.warm,
  SyncLevel.problem => AppColors.danger,
};

IconData levelIcon(SyncLevel l) => switch (l) {
  SyncLevel.ok => Icons.check_circle_outline,
  SyncLevel.waiting => Icons.schedule,
  SyncLevel.attention => Icons.info_outline,
  SyncLevel.problem => Icons.error_outline,
};

Future<void> showSyncHealthCenter(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    builder: (_) => SyncHealthCenter(state: state),
  );
}

class SyncHealthCenter extends StatefulWidget {
  const SyncHealthCenter({super.key, required this.state});
  final AppState state;

  @override
  State<SyncHealthCenter> createState() => _SyncHealthCenterState();
}

class _SyncHealthCenterState extends State<SyncHealthCenter> {
  AppState get s => widget.state;
  Map<String, int> _pending = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final p = await s.syncPendingCounts();
    if (mounted) setState(() => _pending = p);
  }

  int get _pendingTotal => _pending.values.fold(0, (a, b) => a + b);

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backup() => _run(() async {
    await s.flush();
    await s.workspace.backups.snapshot('manual');
    s.showToast('Backup created.');
  });

  Future<void> _copy(SyncFacts f, SyncDiagnosis d) async {
    await Clipboard.setData(
      ClipboardData(
        text: syncDiagnosticsText(
          facts: f,
          diagnosis: d,
          pendingByKind: _pending,
          history: s.syncHistory,
          now: DateTime.now(),
        ),
      ),
    );
    s.showToast('Report copied (no addresses, keys or note text).');
  }

  Future<void> _do(SyncStep step) async {
    switch (step) {
      case SyncStep.none:
        break;
      case SyncStep.syncNow:
        await _run(s.syncNow);
      case SyncStep.turnOnSync:
        await _run(() async {
          await s.setSyncEnabled(true);
        });
      case SyncStep.reviewConflicts:
        await showConflictsDialog(context, s);
        await _refresh();
      case SyncStep.pairAgain:
        await showStorageSwitchDialog(context, s, StorageMode.local);
    }
  }

  static String _label(SyncStep s) => switch (s) {
    SyncStep.none => '',
    SyncStep.syncNow => 'Sync now',
    SyncStep.reviewConflicts => 'Review conflicts',
    SyncStep.turnOnSync => 'Turn sync on',
    SyncStep.pairAgain => 'Disconnect and pair again',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.workspace.conflicts]),
      builder: (context, _) {
        final now = DateTime.now();
        final f = syncFactsOf(s, _pendingTotal);
        final d = diagnoseSync(f);
        final color = levelColor(d.level);
        final steps = [for (final x in d.steps) if (x != SyncStep.none) x];
        return AlertDialog(
          key: const ValueKey('sync-health-center'),
          title: const Text('Sync health', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(levelIcon(d.level), color: color, size: 26),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              d.title,
                              key: const ValueKey('sync-health-title'),
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: color,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              d.detail,
                              key: const ValueKey('sync-health-detail'),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (d.help.isNotEmpty) ...[
                    const SizedBox(height: Space.md),
                    for (final h in d.help)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          '•  $h',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: Space.lg),
                  _row('Connection', connectionLabel(f)),
                  _row('Last successful sync', agoLabel(f.lastSynced, now)),
                  _row(
                    'Changes waiting',
                    _pendingTotal == 0
                        ? 'none'
                        : '$_pendingTotal (${[
                            for (final e in _pending.entries)
                              '${e.value} ${e.key.replaceAll('_', ' ')}',
                          ].join(', ')})',
                  ),
                  _row('Conflicts', f.conflictCount == 0 ? 'none' : '${f.conflictCount}'),
                  const SizedBox(height: Space.md),
                  Text(
                    'RECENT SYNCS',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.5,
                      color: AppColors.textFaint,
                    ),
                  ),
                  if (s.syncHistory.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'No sync has run since the app started.',
                        style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                      ),
                    ),
                  for (final a in s.syncHistory.reversed.take(6))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            a.ok ? Icons.check : Icons.close,
                            size: 14,
                            color: a.ok ? AppColors.success : AppColors.danger,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${agoLabel(a.at, now)} — ${a.text}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: Space.lg),
                  Text(
                    'Safe to try: none of these delete or replace anything.',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textFaint),
                  ),
                  const SizedBox(height: Space.sm),
                  Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    children: [
                      for (var i = 0; i < steps.length; i++)
                        (i == 0 ? FilledButton.new : OutlinedButton.new)(
                          key: ValueKey('sync-health-${steps[i].name}'),
                          onPressed: _busy ? null : () => _do(steps[i]),
                          child: Text(_label(steps[i])),
                        ),
                      OutlinedButton.icon(
                        key: const ValueKey('sync-health-backup'),
                        onPressed: _busy ? null : _backup,
                        icon: const Icon(Icons.save_alt, size: 16),
                        label: const Text('Back up now'),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('sync-health-copy'),
                        onPressed: () => _copy(f, d),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy report'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(k, style: TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
        ),
        Expanded(child: Text(v, style: const TextStyle(fontSize: 12.5))),
      ],
    ),
  );
}
