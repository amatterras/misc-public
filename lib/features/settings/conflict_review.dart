// Review of sync conflicts: the version in place now next to the one that was
// kept aside, and an explicit choice for each. Nothing is decided by
// opening this window, and nothing is deleted by deciding: both versions
// stay in the settled conflict (see sync/conflict_resolver.dart), which can
// be taken back from the "Settled" list.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/sync_models.dart';
import '../../sync/conflict_resolver.dart';
import '../../sync/hlc.dart';

const _reasons = {
  'concurrent_edit': 'Edited on two devices at the same time',
  'edited_after_delete': 'Edited on one device after being deleted on another',
  'deleted_here_edited_elsewhere':
      'Deleted on one device but edited on another (the edit was kept)',
};

const _kinds = {
  'notes': 'Note',
  'tasks': 'Task',
  'projects': 'Project',
  'folders': 'Folder',
  'inbox': 'Inbox item',
  'calendar_entries': 'Calendar entry',
  'calendar_days': 'Calendar day',
  'assets': 'Link or photo',
  'canvases': 'Mindmap or notebook settings',
  'canvas_items': 'Item on a mindmap or notebook page',
  'archive_folders': 'Archive folder',
  'templates': 'Template',
  'smart_views': 'Saved task view',
  'thought_experiments': 'Thought experiment',
};

/// A short, plain-words look at one version of a record.
String conflictPreview(Map<String, dynamic>? json, {required bool deleted}) {
  if (deleted) return 'Deleted';
  if (json == null) return 'Not available on this device';
  final type = json['type'];
  final parts = <String>[];
  for (final key in const ['title', 'name', 'text', 'body', 'content', 'url']) {
    final v = json[key];
    if (v is String && v.trim().isNotEmpty) {
      parts.add(v.trim());
      if (parts.length == 2) break;
    }
  }
  if (parts.isEmpty) {
    return type is String
        ? '${type[0].toUpperCase()}${type.substring(1)} (no text to show)'
        : 'No text to show';
  }
  final text = parts.join('\n');
  return text.length > 280 ? '${text.substring(0, 280)}…' : text;
}

String _when(String? rev) {
  final parsed = rev == null ? null : SyncClock.parse(rev);
  if (parsed == null) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(
    parsed.$1,
    isUtc: true,
  ).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

String _who(AppState s, String? device) => device == null || device.isEmpty
    ? ''
    : device == s.workspace.device?.id
    ? 'this device'
    : 'another device';

/// Opens the review window.
Future<void> showConflictReview(BuildContext context, AppState state) =>
    showAppDialog<void>(
      context: context,
      builder: (_) => ConflictReviewDialog(state: state),
    );

class ConflictReviewDialog extends StatefulWidget {
  const ConflictReviewDialog({super.key, required this.state});

  final AppState state;

  @override
  State<ConflictReviewDialog> createState() => _ConflictReviewDialogState();
}

class _ConflictReviewDialogState extends State<ConflictReviewDialog> {
  AppState get s => widget.state;
  ConflictResolver get r => s.conflictResolver;
  final _busy = <String>{};

  Future<void> _run(
    SyncConflict c,
    Future<bool> Function() action,
    String ok,
  ) async {
    if (_busy.contains(c.id)) return;
    setState(() => _busy.add(c.id));
    var done = false;
    try {
      done = await action();
    } finally {
      if (mounted) setState(() => _busy.remove(c.id));
    }
    s.showToast(
      done
          ? ok
          : 'That could not be done here (nothing was changed). The conflict '
                'is still open.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.workspace.conflicts]),
      builder: (context, _) {
        final open = r.open();
        final settled = r.settled();
        return AlertDialog(
          key: const ValueKey('conflict-review'),
          title: const Text(
            'Sync conflicts',
            style: TextStyle(fontSize: AppType.sizeHeading),
          ),
          content: SizedBox(
            width: 680,
            height: 520,
            child: ListView(
              children: [
                Text(
                  open.isEmpty
                      ? 'No conflicts waiting.'
                      : 'Both versions are kept until you choose. Opening this '
                            'window changes nothing.',
                  style: TextStyle(
                    fontSize: AppType.sizeLabel,
                    color: AppColors.textFaint,
                  ),
                ),
                const SizedBox(height: Space.sm),
                for (final c in open) _openTile(c),
                if (settled.isNotEmpty) ...[
                  const SizedBox(height: Space.md),
                  Theme(
                    data: Theme.of(context)
                        .copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      key: const ValueKey('conflicts-settled'),
                      tilePadding: EdgeInsets.zero,
                      title: Text(
                        'Settled (${settled.length}) — both versions kept for '
                        '90 days',
                        style: const TextStyle(fontSize: AppType.sizeBodySmall),
                      ),
                      children: [for (final c in settled) _settledTile(c)],
                    ),
                  ),
                ],
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
    );
  }

  Widget _side(String label, String detail, String text) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: AppType.sizeLabel,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (detail.isNotEmpty)
            Text(
              detail,
              style: TextStyle(
                fontSize: AppType.sizeMeta,
                color: AppColors.textFaint,
              ),
            ),
          const SizedBox(height: 4),
          Text(text, style: const TextStyle(fontSize: AppType.sizeBodySmall)),
        ],
      ),
    ),
  );

  Widget _openTile(SyncConflict c) {
    final busy = _busy.contains(c.id);
    final kind = _kinds[c.collection] ?? c.collection.replaceAll('_', ' ');
    return Card(
      key: ValueKey('conflict-${c.id}'),
      margin: const EdgeInsets.only(bottom: Space.md),
      color: AppColors.card,
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: FutureBuilder<ConflictSides>(
          future: r.sides(c),
          builder: (context, snap) {
            final sides = snap.data;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kind,
                  style: const TextStyle(
                    fontSize: AppType.sizeBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _reasons[c.reason] ?? c.reason,
                  style: TextStyle(
                    fontSize: AppType.sizeLabel,
                    color: AppColors.textFaint,
                  ),
                ),
                const SizedBox(height: Space.sm),
                if (sides == null)
                  const LinearProgressIndicator()
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _side(
                        'Current version',
                        [
                          _who(s, c.keptDevice),
                          _when(c.keptRev),
                        ].where((e) => e.isNotEmpty).join(' · '),
                        conflictPreview(
                          sides.current,
                          deleted: sides.currentDeleted && c.keptDeleted,
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      _side(
                        'Other version',
                        [
                          _who(s, c.otherDevice),
                          _when(c.otherRev),
                        ].where((e) => e.isNotEmpty).join(' · '),
                        conflictPreview(
                          sides.other,
                          deleted: sides.otherDeleted,
                        ),
                      ),
                    ],
                  ),
                if (sides != null && sides.editedSince)
                  Padding(
                    key: ValueKey('edited-since-${c.id}'),
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Text(
                      'The current version was changed again after this '
                      'conflict. Using the other version replaces that newer '
                      'work (it stays saved under "Settled").',
                      style: TextStyle(
                        fontSize: AppType.sizeLabel,
                        color: AppColors.warm,
                      ),
                    ),
                  ),
                const SizedBox(height: Space.sm),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.xs,
                  children: [
                    OutlinedButton(
                      key: ValueKey('keep-current-${c.id}'),
                      onPressed: busy
                          ? null
                          : () => _run(
                              c,
                              () async {
                                r.keepCurrent(c);
                                return true;
                              },
                              'Kept the current version. The other one is '
                              'saved under "Settled".',
                            ),
                      child: const Text('Keep current version'),
                    ),
                    Tooltip(
                      message: r.canUseOther(c)
                          ? 'Makes the other version the current one'
                          : 'This kind of conflict cannot be restored from '
                                'here; the other version stays saved',
                      child: FilledButton(
                        key: ValueKey('use-other-${c.id}'),
                        onPressed: busy || !r.canUseOther(c)
                            ? null
                            : () => _run(
                                c,
                                () => r.useOther(c),
                                'The other version is now current. Undo it '
                                'under "Settled".',
                              ),
                        child: const Text('Use other version'),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _settledTile(SyncConflict c) {
    final kind = _kinds[c.collection] ?? c.collection.replaceAll('_', ' ');
    final preview = conflictPreview(
      c.otherData,
      deleted: c.otherDeleted,
    ).split('\n').first;
    return ListTile(
      key: ValueKey('settled-${c.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        '$kind: $preview',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        c.choice == 'used_other'
            ? 'You used the other version'
            : 'You kept the current version',
        style: TextStyle(
          fontSize: AppType.sizeLabel,
          color: AppColors.textFaint,
        ),
      ),
      trailing: TextButton(
        key: ValueKey('undo-${c.id}'),
        onPressed: _busy.contains(c.id)
            ? null
            : () => _run(
                c,
                () => r.reopen(c),
                'Taken back. The conflict is open again.',
              ),
        child: const Text('Undo'),
      ),
    );
  }
}
