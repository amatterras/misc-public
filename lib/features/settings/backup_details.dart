// One backup, opened from the history list: when it was made, by which build
// of THEapp, what it holds, a button that checks every file against its
// manifest, and Restore. Nothing is changed by looking at it.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import 'backup_actions.dart';
import 'settings_widgets.dart';

Future<void> showBackupDetails(
  BuildContext context,
  AppState state,
  Directory backup,
) => showDialog<void>(
  context: context,
  builder: (_) => _BackupDetails(state: state, backup: backup),
);

class _BackupDetails extends StatefulWidget {
  const _BackupDetails({required this.state, required this.backup});

  final AppState state;
  final Directory backup;

  @override
  State<_BackupDetails> createState() => _BackupDetailsState();
}

enum _Check { idle, running, ok, problems }

class _BackupDetailsState extends State<_BackupDetails> {
  Map<String, dynamic>? _manifest;
  bool _loaded = false;
  _Check _check = _Check.idle;
  List<String> _problems = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await widget.state.workspace.backups.readManifest(widget.backup);
    if (mounted) {
      setState(() {
        _manifest = m;
        _loaded = true;
      });
    }
  }

  Future<void> _runCheck() async {
    setState(() => _check = _Check.running);
    final problems = await widget.state.workspace.backups.checkManifest(
      widget.backup,
    );
    if (!mounted) return;
    setState(() {
      _problems = problems;
      _check = problems.isEmpty ? _Check.ok : _Check.problems;
    });
  }

  int get _records {
    final counts = _manifest?['recordCounts'];
    if (counts is! Map) return 0;
    return counts.values.whereType<int>().fold(0, (a, b) => a + b);
  }

  @override
  Widget build(BuildContext context) {
    final label = BackupLabel(widget.backup);
    final m = _manifest;
    final build = m?['appBuild'];
    final withPhotos = m?['includesAttachments'] == true;
    final copy = widget.state.workspace.backups.isCopy(widget.backup);
    return AlertDialog(
      title: Text(
        label.when(),
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsGroup(
                children: [
                  SettingsRow(title: 'Made', subtitle: label.reason),
                  SettingsRow(
                    title: 'misc. build',
                    subtitle: !_loaded
                        ? '…'
                        : build is String && build.isNotEmpty
                        ? build
                        : 'not recorded (made by an older build)',
                  ),
                  SettingsRow(
                    title: 'Contains',
                    subtitle: !_loaded
                        ? '…'
                        : m == null
                        ? 'No manifest: an older backup. It can be restored, '
                              'but it cannot be checked file by file.'
                        : '$_records records'
                              '${withPhotos ? ', with photos and PDFs' : ', without photos and PDFs (they are kept apart and never replaced)'}',
                  ),
                  if (copy)
                    const SettingsRow(
                      title: 'Stored in',
                      subtitle: 'The Files app (a copy kept outside the app’s own data)',
                    ),
                ],
              ),
              Row(
                children: [
                  SettingsButton(
                    key: const ValueKey('backup-check'),
                    icon: Icons.fact_check_outlined,
                    label: _check == _Check.running ? 'Checking…' : 'Check it',
                    onPressed: _check == _Check.running ? null : _runCheck,
                  ),
                  const SizedBox(width: 12),
                  if (_check == _Check.ok)
                    Flexible(
                      child: Text(
                        'Intact: every file matches.',
                        key: const ValueKey('backup-intact'),
                        style: TextStyle(fontSize: 13, color: AppColors.success),
                      ),
                    ),
                  if (_check == _Check.problems)
                    Flexible(
                      child: Text(
                        'Damaged: ${_problems.first}'
                        '${_problems.length > 1 ? ' (+${_problems.length - 1} more)' : ''}',
                        key: const ValueKey('backup-damaged'),
                        style: TextStyle(fontSize: 13, color: AppColors.danger),
                      ),
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
          child: Text('Close', style: TextStyle(color: AppColors.textMuted)),
        ),
        FilledButton(
          key: const ValueKey('backup-restore'),
          onPressed: _check == _Check.problems
              ? null
              : () => restoreBackup(context, widget.state, widget.backup),
          child: const Text('Restore…'),
        ),
      ],
    );
  }
}
