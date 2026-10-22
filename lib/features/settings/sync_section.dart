import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/test_environment.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart';

/// Pairing with the PC sync hub, sync status, and conflict review.
class SyncSection extends StatefulWidget {
  const SyncSection({super.key, required this.state});

  final AppState state;

  @override
  State<SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<SyncSection> {
  final _url = TextEditingController(
    text: TestEnvironment.active
        ? 'http://127.0.0.1:${TestEnvironment.testHubPort}'
        : 'http://127.0.0.1:47710',
  );
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.state.pairWithHub(_url.text, _code.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.workspace.conflicts]),
      builder: (context, _) {
        if (!s.syncPaired) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Optional. Start the hub on this PC (see SYNC_ARCHITECTURE.md), '
                'run "thehub pair", and enter the code here. THEapp works the '
                'same without it.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              const SizedBox(height: Space.sm),
              // Address on its own line when the dialog is narrow.
              if (MediaQuery.sizeOf(context).width < 640) ...[
                TextField(
                  controller: _url,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(labelText: 'Hub address'),
                ),
                const SizedBox(height: Space.sm),
              ],
              Row(
                children: [
                  if (MediaQuery.sizeOf(context).width >= 640) ...[
                    Expanded(
                      child: TextField(
                        controller: _url,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          labelText: 'Hub address',
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                  ],
                  Flexible(
                    child: SizedBox(
                      width: 150,
                      child: TextField(
                        controller: _code,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          labelText: 'Pairing code',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  FilledButton(
                    onPressed: _busy ? null : _pair,
                    child: Text(_busy ? 'Pairing…' : 'Pair'),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.danger,
                    ),
                  ),
                ),
            ],
          );
        }
        final conflicts = s.workspace.conflicts.length;
        final last = s.lastSynced;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${s.syncing ? 'Syncing…' : s.syncStatus}'
              '${last == null ? '' : '  ·  last ${TimeOfDay.fromDateTime(last).format(context)}'}',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              'Hub: ${s.hubUrl}',
              style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
            ),
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: Space.sm,
              children: [
                OutlinedButton.icon(
                  onPressed: s.syncing ? null : s.syncNow,
                  icon: const Icon(Icons.sync, size: 16),
                  label: const Text('Sync now'),
                ),
                if (conflicts > 0)
                  OutlinedButton.icon(
                    onPressed: () => showConflictsDialog(context, s),
                    icon: const Icon(Icons.call_split, size: 16),
                    label: Text('Review $conflicts conflict(s)'),
                  ),
                TextButton(
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      title: 'Stop syncing?',
                      message:
                          'This PC stops syncing with the hub. Nothing is '
                          'deleted here or on the hub.',
                      action: 'Disconnect',
                    );
                    if (ok) await s.disconnectHub();
                  },
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

const _reasons = {
  'concurrent_edit': 'Edited on two devices at the same time',
  'edited_after_delete': 'Edited on one device after being deleted on another',
  'deleted_here_edited_elsewhere':
      'Deleted on one device but edited on another (the edit was kept)',
};

/// Lists preserved versions from sync conflicts. "Use this version" makes
/// it the current one (as a normal edit, so it syncs); "Dismiss" removes
/// the preserved copy.
Future<void> showConflictsDialog(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: state.workspace.conflicts,
      builder: (context, _) {
        final ws = state.workspace;
        final list = ws.conflicts.all.toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return AlertDialog(
          title: const Text('Sync conflicts', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 560,
            height: 420,
            child: list.isEmpty
                ? const Center(
                    child: Text(
                      'No conflicts.',
                      style: TextStyle(color: AppColors.textFaint),
                    ),
                  )
                : ListView(
                    children: [
                      for (final c in list)
                        ListTile(
                          title: Text(
                            '${c.collection.replaceAll('_', ' ')}: '
                            '${(c.otherData?['title'] ?? c.otherData?['name'] ?? c.otherData?['text'] ?? c.recordId).toString().split('\n').first}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${_reasons[c.reason] ?? c.reason} · other version: '
                            '${c.otherDeleted ? 'deleted' : 'kept here'}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textFaint,
                            ),
                          ),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              if (ws.syncCollections.containsKey(
                                    c.collection,
                                  ) &&
                                  c.collection != 'conflicts')
                                TextButton(
                                  onPressed: () {
                                    final target =
                                        ws.syncCollections[c.collection]!;
                                    if (c.otherDeleted || c.otherData == null) {
                                      target.remove(c.recordId);
                                    } else {
                                      target.put(target.fromJson(c.otherData!));
                                    }
                                    ws.conflicts.remove(c.id);
                                    state.showToast(
                                      'Restored the other version.',
                                    );
                                  },
                                  child: const Text('Use this version'),
                                ),
                              TextButton(
                                onPressed: () => ws.conflicts.remove(c.id),
                                child: const Text('Dismiss'),
                              ),
                            ],
                          ),
                        ),
                    ],
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
    ),
  );
}
