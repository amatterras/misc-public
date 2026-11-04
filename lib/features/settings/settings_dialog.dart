import 'dart:io';

import 'package:flutter/material.dart';

import 'privacy_summary.dart';
import '../../app/app_state.dart';
import '../../app/build_info.dart';
import '../../app/interface_version.dart';
import '../../app/test_environment.dart';
import '../../app/theme.dart';
import '../../data/storage/app_log.dart';
import '../../platform/input_hints.dart';
import '../../platform/platform.dart' as native;
import '../../widgets/common.dart';
import '../capture/send_to.dart';
import 'storage_section.dart';
import 'sync_section.dart';
import '../tasks/completion_messages.dart';
import '../ai/ai_settings_section.dart';
import '../sharing/share_dialog.dart';
import '../calendar/external/calendar_accounts_section.dart';

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
      'auto-full' => 'automatic weekly backup with photos and PDFs',
      final r? when r.startsWith('pre-') => 'before data upgrade',
      'before-restore' => 'before a restore',
      final other => other ?? '',
    };
    return '${m.group(1)}-${m.group(2)}-${m.group(3)} ${m.group(4)}:${m.group(5)}  ·  $reason';
  }

  Future<void> _saveCopy() async {
    setState(() => _busy = true);
    try {
      final copy = await s.saveBackupCopy();
      if (copy != null) {
        s.showToast(
          'Backup saved in the Files app: On My iPad (or iPhone) → THEapp → '
          'THEapp Backups. '
          'Move it to iCloud Drive or your PC to keep it safe.',
        );
      }
    } catch (e, st) {
      AppLog.error('Saving a backup copy failed', e, st);
      s.showToast('Could not save the backup copy. Nothing was changed.');
    }
    await _loadBackups();
    if (mounted) setState(() => _busy = false);
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
              const _Heading('Appearance'),
              DropdownButtonFormField<String>(
                key: const ValueKey('theme-mode'),
                initialValue: s.themeModePreference.value,
                decoration: const InputDecoration(labelText: 'Theme'),
                items: const [
                  DropdownMenuItem(value: 'system', child: Text('System')),
                  DropdownMenuItem(value: 'light', child: Text('Light')),
                  DropdownMenuItem(value: 'dark', child: Text('Dark')),
                ],
                onChanged: (mode) async {
                  if (mode == null) return;
                  await s.setThemeMode(mode);
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: Space.md),
              Text(
                'Interface Version',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              const SizedBox(height: Space.sm),
              SegmentedButton<InterfaceVersion>(
                key: const ValueKey('interface-version'),
                showSelectedIcon: false,
                segments: [
                  for (final v in InterfaceVersion.values)
                    ButtonSegment(value: v, label: Text(v.label)),
                ],
                selected: {s.interfaceVersion},
                onSelectionChanged: (choice) async {
                  await s.setInterfaceVersion(choice.first);
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: Space.xs),
              Text(
                'Original is the interface you know. New is the redesign. '
                'Your data is the same in both, and this choice applies to '
                '$thisDevice only.',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint),
              ),
              const _Heading('Privacy'),
              PrivacySummary(state: s),
              const _Heading('Your data'),
              Text(
                'Everything is stored only on $thisDevice, in:\n$dataPath',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              const SizedBox(height: Space.sm),
              OutlinedButton.icon(
                onPressed: native.canOpenFolders
                    ? () => native.openFolder(dataPath)
                    : null,
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Open data folder'),
              ),
              const _Heading('Clipboard between my devices'),
              SwitchListTile(
                key: const ValueKey('share-clipboard'),
                contentPadding: EdgeInsets.zero,
                value: s.shareClipboard,
                onChanged: (v) async {
                  await s.setShareClipboard(v);
                  if (mounted) setState(() {});
                },
                title: const Text(
                  'Share copied text with my other devices',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  touchFirst
                      ? 'Text copied on your PC arrives here, ready to paste '
                            'in any app (while THEapp is open). To send text '
                            'from here, use “Share clipboard now”. Goes only '
                            'through your own hub.'
                      : 'While THEapp runs, text you copy in any app is sent '
                            'to your other devices through your own hub, and '
                            'text copied there arrives on this clipboard. Off '
                            'by default: copied passwords would be shared too. '
                            'The hub must run this version of THEapp.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              ),
              if (s.shareClipboard && touchFirst)
                OutlinedButton(
                  onPressed: () async {
                    final clip = await s.checkClipboard();
                    s.showToast(
                      clip == null
                          ? 'Nothing new on the clipboard.'
                          : 'Shared with your other devices.',
                    );
                  },
                  child: const Text('Share clipboard now'),
                ),
              const _Heading('AI'),
              AiSettingsSection(state: s),
              const _Heading('Calendar accounts'),
              CalendarAccountsSection(state: s),
              const _Heading('Sharing'),
              ListTile(
                key: const ValueKey('shared-links'),
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Shared links',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  '${s.workspace.shares.all.where((l) => l.activeAt(DateTime.now())).length} '
                  'active. Read-only links served by your own hub; revoke '
                  'them here.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showSharedLinks(context, s),
              ),
              ListTile(
                key: const ValueKey('open-vault'),
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Private vault',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  'Notes encrypted with a password; never searched, sent to '
                  'AI, shared or exported.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
                trailing: const Icon(Icons.lock_outline),
                onTap: () {
                  Navigator.pop(context);
                  s.openVault();
                },
              ),
              if (s.ios != null)
                SwitchListTile(
                  key: const ValueKey('pencil-double-tap'),
                  contentPadding: EdgeInsets.zero,
                  value: s.pencilDoubleTapUndo,
                  onChanged: (v) async {
                    await s.setPencilDoubleTapUndo(v);
                    if (mounted) setState(() {});
                  },
                  title: const Text(
                    'Apple Pencil double-tap undoes',
                    style: TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    'On the drawing you are using (canvas, note handwriting, '
                    'Calendar in Draw mode). Apple Pencil 2 and Pro. Turning '
                    'double-tap off in iPadOS Settings is respected too.',
                    style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                  ),
                ),
              const _Heading('Window'),
              SwitchListTile(
                key: const ValueKey('immersive'),
                contentPadding: EdgeInsets.zero,
                value: s.immersive,
                onChanged: (_) async {
                  await s.toggleImmersive();
                  if (mounted) setState(() {});
                },
                title: const Text(
                  'Full screen',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  'Windows: no window frame (F11). iPhone/iPad: no status bar '
                  '(swipe from the edge to see it; the home indicator stays).',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              ),
              SwitchListTile(
                key: const ValueKey('always-on-top'),
                contentPadding: EdgeInsets.zero,
                value: s.alwaysOnTop && s.alwaysOnTopSupported,
                onChanged: s.alwaysOnTopSupported
                    ? (v) async {
                        await s.setAlwaysOnTop(v);
                        if (mounted) setState(() {});
                      }
                    : null,
                title: const Text(
                  'Always on top',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  s.alwaysOnTopSupported
                      ? 'Keeps the THEapp window above other windows. '
                            'Saved on this device only.'
                      : 'Not available here: iPhone and iPad apps cannot '
                            'stay above other apps.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              ),
              const _Heading('Calendar'),
              Row(
                children: [
                  const Expanded(
                    child: Text('Date format', style: TextStyle(fontSize: 14)),
                  ),
                  DropdownButton<DateOrder>(
                    key: const ValueKey('date-order'),
                    value: DatePrefs.order,
                    items: [
                      for (final o in DateOrder.values)
                        DropdownMenuItem(value: o, child: Text(o.label)),
                    ],
                    onChanged: (v) async {
                      await s.setDatePrefs(order: v);
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Week starts on',
                      style: TextStyle(fontSize: 14),
                    ),
                  ),
                  DropdownButton<int>(
                    key: const ValueKey('first-weekday'),
                    value: DatePrefs.firstWeekday,
                    items: const [
                      DropdownMenuItem(
                        value: DateTime.monday,
                        child: Text('Monday'),
                      ),
                      DropdownMenuItem(
                        value: DateTime.saturday,
                        child: Text('Saturday'),
                      ),
                      DropdownMenuItem(
                        value: DateTime.sunday,
                        child: Text('Sunday'),
                      ),
                    ],
                    onChanged: (v) async {
                      await s.setDatePrefs(firstWeekday: v);
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
              const _Heading('Tasks'),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Message when a task is completed',
                      style: TextStyle(fontSize: 14),
                    ),
                  ),
                  DropdownButton<CompletionStyle>(
                    key: const ValueKey('completion-style'),
                    value: s.completionStyle,
                    items: [
                      for (final c in CompletionStyle.values)
                        DropdownMenuItem(value: c, child: Text(c.label)),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      await s.setCompletionStyle(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ],
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
                subtitle: Text(
                  'THEapp visits the page you pasted, like a browser would. '
                  'None of your own content is sent anywhere.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              ),
              // Windows File Explorer only; on iPhone/iPad, sharing goes
              // through the Share menu / Shortcut (see ios/README_IOS.md).
              if (!touchFirst) ...[
                const _Heading('Send to THEapp'),
                Text(
                  'Adds “THEapp” to the right-click “Send to” menu in File Explorer. '
                  'Photos and files you send are saved in the Archive.',
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
              const _Heading('Storage'),
              StorageModeSection(state: s),
              const _Heading('Sync hub'),
              SyncSection(state: s),
              const _Heading('Backups'),
              Text(
                'A backup of all records is made automatically once a day (the '
                'last 14 are kept), and once a week one that also holds photos '
                'and PDFs (the last 4 are kept). Backups stay on $thisDevice'
                '${s.workspace.backups.copiesDir == null ? '.' : ': use “Save a copy to Files” to keep one elsewhere.'}',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _backupNow,
                    icon: const Icon(Icons.backup_outlined, size: 16),
                    label: const Text('Back up now'),
                  ),
                  if (s.workspace.backups.copiesDir != null)
                    OutlinedButton.icon(
                      key: const ValueKey('save-backup-copy'),
                      onPressed: _busy ? null : _saveCopy,
                      icon: const Icon(Icons.save_alt, size: 16),
                      label: const Text('Save a copy to Files'),
                    ),
                ],
              ),
              const SizedBox(height: Space.sm),
              for (final b in _backups.take(20))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.history,
                    size: 18,
                    color: AppColors.textFaint,
                  ),
                  title: Text(
                    '${_describe(b)}${s.workspace.backups.isCopy(b) ? '  ·  copy in Files' : ''}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: TextButton(
                    onPressed: _busy ? null : () => _restore(b),
                    child: const Text('Restore…'),
                  ),
                ),
              if (_backups.isEmpty)
                Text(
                  'No backups yet.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              const _Heading('Data safety'),
              DataSafetySection(state: s),
              const _Heading('About'),
              SelectableText(
                'THEapp build $appBuild',
                key: ValueKey('about-build'),
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              Text(
                'Every device paired with the same hub should run the same '
                'build (at least 371c6ca).',
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
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 0.6,
        color: AppColors.textFaint,
      ),
    ),
  );
}
