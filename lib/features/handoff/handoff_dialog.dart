// "Continue on this device": shows where the user's other devices were and
// resumes one only when asked. Says plainly when something has not synced.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../sync/sync_scheduler.dart' show SyncConnection;
import 'handoff.dart';

Future<void> showContinueDialog(BuildContext context, AppState s) =>
    showAppDialog<void>(
      context: context,
      builder: (_) => ContinueDialog(state: s),
    );

String _ago(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// What a state points at, in this device's own words (titles come from
/// this device's copy of the data, never from the synced state).
String describeResume(AppState s, ResumeState r) {
  if (r.noteId != null) {
    final n = s.workspace.notes[r.noteId!];
    return n == null
        ? 'A note that has not reached this device yet'
        : 'Note “${n.displayTitle.isEmpty ? 'untitled' : n.displayTitle}”';
  }
  if (r.canvasId != null) {
    final c = s.canvasList.where((c) => c.id == r.canvasId).firstOrNull;
    return c == null
        ? 'A mindmap that has not reached this device yet'
        : 'Mindmap “${c.title}”';
  }
  return switch (r.page) {
    'calendar' => 'Calendar',
    'tasks' => 'Tasks',
    'links' => 'Archive',
    'notes' => 'Notes',
    'canvas' => 'Mindmaps',
    'browser' => 'Browser',
    'ai' => 'AI',
    _ => 'Home',
  };
}

class ContinueDialog extends StatefulWidget {
  const ContinueDialog({super.key, required this.state});
  final AppState state;

  @override
  State<ContinueDialog> createState() => _ContinueDialogState();
}

class _ContinueDialogState extends State<ContinueDialog> {
  AppState get s => widget.state;
  bool _ownUnsynced = false;

  @override
  void initState() {
    super.initState();
    s.handoff.publishNow();
    _check();
  }

  Future<void> _check() async {
    final u = await s.handoff.ownUnsynced();
    if (mounted) setState(() => _ownUnsynced = u);
  }

  Future<void> _resume(ResumeState r) async {
    final stale = DateTime.now().toUtc().difference(r.at) > staleAfter;
    if (stale) {
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(
            'This is an old position',
            style: TextStyle(fontSize: 16),
          ),
          content: Text(
            'It was recorded ${_ago(r.at, DateTime.now().toUtc())} on '
            '${r.deviceName}. Continue from there anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final outcome = await applyResume(s, r);
    if (!mounted) return;
    if (outcome == ResumeOutcome.opened) {
      Navigator.pop(context);
    } else {
      s.showToast(
        'That item has not reached this device yet. Sync, then try again.',
      );
      await s.syncNow();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.workspace.shares]),
      builder: (context, _) {
        final now = DateTime.now().toUtc();
        final choice = s.handoff.choice();
        final offline = s.syncConnection == SyncConnection.offline;
        final notes = <String>[
          if (!s.syncPaired) 'This device is not connected to a hub, so it cannot see other devices.',
          if (s.syncPaired && offline) 'The hub cannot be reached. The positions below may be out of date.',
          if (_ownUnsynced)
            'Your latest position on this device has not synced yet, so your '
                'other devices will see an older one.',
          if (!s.handoff.enabled)
            'Recording is off on this device (Settings → Sync).',
        ];
        return AlertDialog(
          key: const ValueKey('continue-dialog'),
          title: const Text(
            'Continue on this device',
            style: TextStyle(fontSize: 16),
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Nothing opens by itself. Pick a position to open it here; '
                    'what you are doing on this device is saved first.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                  for (final n in notes)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        n,
                        key: const ValueKey('handoff-note'),
                        style: TextStyle(fontSize: 12.5, color: AppColors.warm),
                      ),
                    ),
                  const SizedBox(height: AppSpace.md),
                  if (choice.candidates.isEmpty)
                    Text(
                      'No other device has recorded a position yet.',
                      key: const ValueKey('handoff-empty'),
                      style: TextStyle(color: AppColors.textFaint),
                    ),
                  if (choice.needsChoice)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'More than one device was used at about the same time: '
                        'choose which position to continue from.',
                        key: const ValueKey('handoff-choose'),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  if (choice.localIsNewer && choice.candidates.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'This device was used more recently than the others.',
                        key: const ValueKey('handoff-local-newer'),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  for (final r in choice.candidates)
                    ListTile(
                      key: ValueKey('handoff-${r.deviceId}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.devices_other,
                        size: 20,
                        color: r == choice.suggested
                            ? AppColors.accent
                            : AppColors.textMuted,
                      ),
                      title: Text(
                        describeResume(s, r),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${r.deviceName} · ${_ago(r.at, now)}'
                        '${now.difference(r.at) > staleAfter ? ' · old' : ''}'
                        '${r == choice.suggested ? ' · latest' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: FilledButton.tonal(
                        key: ValueKey('handoff-resume-${r.deviceId}'),
                        onPressed: () => _resume(r),
                        child: const Text('Continue'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: s.syncPaired && !s.syncing ? s.syncNow : null,
              child: const Text('Sync now'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}
