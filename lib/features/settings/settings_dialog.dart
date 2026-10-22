import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/test_environment.dart';
import '../../app/theme.dart';
import '../../platform/input_hints.dart';
import '../../platform/platform.dart' as native;
import '../../widgets/common.dart';
import '../capture/send_to.dart';
import 'sync_section.dart';

Future<void> showSettingsDialog(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SettingsDialog(state: state),
  );
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.state});

  final AppState state;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  List<Directory> _backups = [];
  bool _busy = false;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  Future<void> _loadBackups() async {
    final list = await s.workspace.backups.list();
    if (mounted) setState(() => _backups = list);
  }

  String _name(Directory d) =>
      d.uri.pathSegments.where((p) => p.isNotEmpty).last;

  String _describe(Directory d) {
    final name = _name(d);
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})\d{2}-(.*)$')
        .firstMatch(name);
    if (m == null) return name;
    final reason = switch (m.group(6)) {
      'auto' => 'automatic daily backup',
      'manual' => 'manual backup',
      'pre-v2' => 'before data upgrade',
      'before-restore' => 'before a restore',
      final other => other ?? '',
    };
    return '${m.group(1)}-${m.group(2)}-${m.group(3)} ${m.group(4)}:${m.group(5)}  ·  $reason';
  }

  Future<void> _backupNow() async {
    setState(() => _busy = true);
    await s.flush();
    await s.workspace.backups.snapshot('manual');
    await _loadBackups();
    setState(() => _busy = false);
    s.showToast('Backup created.');
  }

  Future<void> _restore(Directory backup) async {
    final ok = await confirm(
      context,
      title: 'Restore this backup?',
      message:
          'Your current data is backed up first, then replaced with the '
          'backup from ${_describe(backup)}. THEapp will close afterwards — '
          'start it again to continue.',
      action: 'Restore and close',
    );
    if (!ok) return;
    setState(() => _busy = true);
    await s.flush();
    s.workspace.store.readOnly = true;
    await s.workspace.backups.restore(backup);
    exit(0);
  }

  Future<void> _toggleSendTo() async {
    setState(() => _busy = true);
    if (SendToBridge.isInstalled) {
      await SendToBridge.uninstall();
      s.showToast('Removed THEapp from the Send to menu.');
    } else {
      final ok = await SendToBridge.install();
      s.showToast(
        ok
            ? 'Added THEapp to the Send to menu.'
            : 'Could not add the shortcut.',
      );
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final dataPath = s.workspace.root.path;
    return AlertDialog(
      title: const Text('Settings', style: TextStyle(fontSize: 17)),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Heading('Your data'),
              Text(
                'Everything is stored only on $thisDevice, in:\n$dataPath',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: Space.sm),
              OutlinedButton.icon(
                onPressed: native.canOpenFolders
                    ? () => native.openFolder(dataPath)
                    : null,
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Open data folder'),
              ),
              const _Heading('Links'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.capture.fetchPreviews,
                onChanged: (v) => setState(() => s.setLinkPreviews(v)),
                title: const Text(
                  'Fetch titles and previews for pasted links',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: const Text(
                  'THEapp visits the page you pasted, like a browser would. '
                  'None of your own content is sent anywhere.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              ),
              // Windows File Explorer only; on iPhone/iPad, sharing goes
              // through the Share menu / Shortcut (see ios/README_IOS.md).
              if (!touchFirst) ...[
                const _Heading('Send to THEapp'),
                const Text(
                  'Adds “THEapp” to the right-click “Send to” menu in File Explorer. '
                  'Photos and files you send land in the Inbox on Home, where you '
                  'choose Canvas, Notes or Calendar.',
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                ),
                const SizedBox(height: Space.sm),
                OutlinedButton.icon(
                  // The menu entry is user-wide, so test data mode leaves it alone.
                  onPressed:
                      _busy || !Platform.isWindows || TestEnvironment.active
                      ? null
                      : _toggleSendTo,
                  icon: Icon(
                    SendToBridge.isInstalled
                        ? Icons.remove_circle_outline
                        : Icons.add_circle_outline,
                    size: 16,
                  ),
                  label: Text(
                    SendToBridge.isInstalled
                        ? 'Remove from Send to menu'
                        : 'Add to Send to menu',
                  ),
                ),
              ],
              const _Heading('Sync hub'),
              SyncSection(state: s),
              const _Heading('Backups'),
              const Text(
                'A backup of all records is made automatically once a day (the '
                'last 14 are kept). Photos are stored separately and never deleted.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              const SizedBox(height: Space.sm),
              OutlinedButton.icon(
                onPressed: _busy ? null : _backupNow,
                icon: const Icon(Icons.backup_outlined, size: 16),
                label: const Text('Back up now'),
              ),
              const SizedBox(height: Space.sm),
              for (final b in _backups.take(20))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.history,
                    size: 18,
                    color: AppColors.textFaint,
                  ),
                  title: Text(
                    _describe(b),
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: TextButton(
                    onPressed: _busy ? null : () => _restore(b),
                    child: const Text('Restore…'),
                  ),
                ),
              if (_backups.isEmpty)
                const Text(
                  'No backups yet.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
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
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.xl, bottom: Space.sm),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 0.6,
        color: AppColors.textFaint,
      ),
    ),
  );
}
