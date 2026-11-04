// The Settings window: a category rail on the left and one calm page per
// category on the right (a list that opens each page, on a narrow screen).
// Every control here is an existing action of AppState; this file only
// arranges them. The pages are built from settings_widgets.dart.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;

import 'privacy_summary.dart';
import '../../app/app_state.dart';
import '../../app/build_info.dart';
import '../../app/interface_version.dart';
import '../../app/test_environment.dart';
import '../../app/theme.dart';
import '../../data/storage/app_log.dart';
import '../../ipad/ipad_profile.dart';
import '../../platform/input_hints.dart';
import '../../platform/platform.dart' as native;
import '../../widgets/common.dart';
import '../capture/send_to.dart';
import 'backup_actions.dart';
import 'backup_details.dart';
import 'security_status.dart';
import 'settings_widgets.dart';
import 'storage_section.dart';
import 'sync_section.dart';
import '../tasks/completion_messages.dart';
import '../ai/ai_settings_section.dart';
import '../sharing/share_dialog.dart';
import '../calendar/external/calendar_accounts_section.dart';

/// The pages of the Settings window.
enum SettingsCategory {
  appearance(Icons.palette_outlined, 'Appearance', 'Theme, interface, window'),
  calendar(
    Icons.event_note_outlined,
    'Calendar & Tasks',
    'Dates, weeks, accounts',
  ),
  archive(Icons.bookmarks_outlined, 'Archive & Links', 'Previews, sharing'),
  pencil(Icons.draw_outlined, 'Apple Pencil', 'Double-tap'),
  sync(Icons.sync_alt, 'Sync & Devices', 'Hub, storage mode, clipboard'),
  data(Icons.shield_outlined, 'Data & Storage', 'Backups, restore, export'),
  privacy(
    Icons.lock_outline,
    'Security & Privacy',
    'Protection, sync, backups, devices',
  ),
  ai(Icons.auto_awesome_outlined, 'AI', 'Assistant and keys'),
  about(Icons.info_outline, 'About', 'Build');

  const SettingsCategory(this.icon, this.label, this.hint);
  final IconData icon;
  final String label;
  final String hint;
}

/// Opens the Settings window, on [open] if given.
Future<void> showSettingsDialog(
  BuildContext context,
  AppState state, {
  SettingsCategory? open,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SettingsDialog(state: state, open: open),
  );
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.state, this.open});

  final AppState state;
  final SettingsCategory? open;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late SettingsCategory _selected = widget.open ?? SettingsCategory.appearance;

  /// Narrow screens: false shows the list of categories, true one page.
  late bool _inPage = widget.open != null;

  List<Directory> _backups = [];
  bool _busy = false;
  bool _allBackups = false;
  ({int records, int attachments, int backups})? _usage;

  AppState get s => widget.state;

  List<SettingsCategory> get _categories => [
    for (final c in SettingsCategory.values)
      if (c != SettingsCategory.pencil || s.ios != null) c,
  ];

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  Future<void> _loadBackups() async {
    final list = await s.workspace.backups.list();
    final usage = await s.workspace.backups.usage();
    if (mounted) {
      setState(() {
        _backups = list;
        _usage = usage;
      });
    }
  }

  Future<void> _run(Future<void> Function() task) async {
    setState(() => _busy = true);
    try {
      await task();
    } finally {
      await _loadBackups();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(880.0, screen.width - 32);
    final height = math.min(640.0, screen.height - 48);
    final wide = width >= 640;
    final radius = BorderRadius.circular(AppColors.newDesign ? 24 : 14);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: ListenableBuilder(
          listenable: s,
          builder: (context, _) => wide ? _wide() : _narrow(),
        ),
      ),
    );
  }

  // ----------------------------------------------------------- layouts --

  Widget _wide() => Row(
    children: [
      Container(
        width: 232,
        decoration: BoxDecoration(
          color: AppColors.card,
          border: Border(right: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
              child: Text(
                'Settings',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: AppColors.text,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  for (final c in _categories)
                    _RailItem(
                      category: c,
                      selected: c == _selected,
                      onTap: () => setState(() => _selected = c),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(child: _page(_selected)),
            Positioned(top: 10, right: 10, child: _closeButton()),
          ],
        ),
      ),
    ],
  );

  Widget _narrow() {
    if (!_inPage) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Settings',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                    ),
                  ),
                ),
                _closeButton(),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
              children: [
                for (final c in _categories)
                  _RailItem(
                    category: c,
                    selected: false,
                    showHint: true,
                    onTap: () => setState(() {
                      _selected = c;
                      _inPage = true;
                    }),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
          child: Row(
            children: [
              TextButton.icon(
                key: const ValueKey('settings-back'),
                onPressed: () => setState(() => _inPage = false),
                icon: const Icon(Icons.chevron_left, size: 20),
                label: const Text('Settings'),
              ),
              const Spacer(),
              _closeButton(),
            ],
          ),
        ),
        Expanded(child: _page(_selected)),
      ],
    );
  }

  Widget _closeButton() => IconButton(
    key: const ValueKey('settings-close'),
    tooltip: 'Close',
    icon: Icon(Icons.close, size: 20, color: AppColors.textMuted),
    onPressed: () => Navigator.pop(context),
  );

  // ------------------------------------------------------------- pages --

  Widget _page(SettingsCategory c) => switch (c) {
    SettingsCategory.appearance => _appearance(),
    SettingsCategory.calendar => _calendar(),
    SettingsCategory.archive => _archive(),
    SettingsCategory.pencil => _pencil(),
    SettingsCategory.sync => _sync(),
    SettingsCategory.data => _data(),
    SettingsCategory.privacy => _privacy(),
    SettingsCategory.ai => _ai(),
    SettingsCategory.about => _about(),
  };

  Widget _appearance() => SettingsPage(
    key: const ValueKey('settings-page-appearance'),
    title: 'Appearance',
    subtitle: 'How misc. looks on $thisDevice.',
    children: [
      SettingsGroup(
        label: 'Look',
        // The interface switch is not offered on an iPhone (iPhone and iPad
        // have their own interface), so its caption is not either.
        footer: IpadProfile.fixedInterface
            ? null
            : 'Original is the interface you know. New is the redesign. Your '
                  'data is the same in both, and this choice applies to '
                  '$thisDevice only.',
        children: [
          SettingsSegmentRow<String>(
            key: const ValueKey('theme-mode'),
            title: 'Theme',
            value: s.themeModePreference.value,
            options: const [
              ('system', 'System'),
              ('light', 'Light'),
              ('dark', 'Dark'),
            ],
            onChanged: (mode) async {
              await s.setThemeMode(mode);
              if (mounted) setState(() {});
            },
          ),
          if (!IpadProfile.fixedInterface)
            SettingsSegmentRow<InterfaceVersion>(
              key: const ValueKey('interface-version'),
              title: 'Interface',
              value: s.interfaceVersion,
              options: [for (final v in InterfaceVersion.values) (v, v.label)],
              onChanged: (choice) async {
                await s.setInterfaceVersion(choice);
                if (mounted) setState(() {});
              },
            ),
        ],
      ),
      SettingsGroup(
        label: 'Window',
        children: [
          SettingsSwitch(
            key: const ValueKey('immersive'),
            title: 'Full screen',
            subtitle: touchFirst
                ? 'No status bar (swipe from the edge to see it; the home '
                      'indicator stays).'
                : 'No window frame (F11).',
            value: s.immersive,
            onChanged: (_) async {
              await s.toggleImmersive();
              if (mounted) setState(() {});
            },
          ),
          SettingsSwitch(
            key: const ValueKey('always-on-top'),
            title: 'Always on top',
            subtitle: s.alwaysOnTopSupported
                ? 'Keeps the misc. window above other windows. Saved on '
                      'this device only.'
                : 'Not available here: iPhone and iPad apps cannot stay '
                      'above other apps.',
            value: s.alwaysOnTop && s.alwaysOnTopSupported,
            onChanged: s.alwaysOnTopSupported
                ? (v) async {
                    await s.setAlwaysOnTop(v);
                    if (mounted) setState(() {});
                  }
                : null,
          ),
        ],
      ),
    ],
  );

  Widget _calendar() => SettingsPage(
    key: const ValueKey('settings-page-calendar'),
    title: 'Calendar & Tasks',
    subtitle: 'How dates are written and what happens when you finish a task.',
    children: [
      SettingsGroup(
        label: 'Dates',
        children: [
          SettingsMenu<DateOrder>(
            menuKey: const ValueKey('date-order'),
            title: 'Date format',
            value: DatePrefs.order,
            options: [for (final o in DateOrder.values) (o, o.label)],
            onChanged: (v) async {
              await s.setDatePrefs(order: v);
              if (mounted) setState(() {});
            },
          ),
          SettingsMenu<int>(
            menuKey: const ValueKey('first-weekday'),
            title: 'Week starts on',
            value: DatePrefs.firstWeekday,
            options: const [
              (DateTime.monday, 'Monday'),
              (DateTime.saturday, 'Saturday'),
              (DateTime.sunday, 'Sunday'),
            ],
            onChanged: (v) async {
              await s.setDatePrefs(firstWeekday: v);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      SettingsGroup(
        label: 'Tasks',
        children: [
          SettingsMenu<CompletionStyle>(
            menuKey: const ValueKey('completion-style'),
            title: 'Message when a task is completed',
            value: s.completionStyle,
            options: [for (final c in CompletionStyle.values) (c, c.label)],
            onChanged: (v) async {
              await s.setCompletionStyle(v);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      SettingsGroup(
        label: 'Calendar accounts',
        padded: true,
        children: [CalendarAccountsSection(state: s)],
      ),
    ],
  );

  Widget _archive() => SettingsPage(
    key: const ValueKey('settings-page-archive'),
    title: 'Archive & Links',
    subtitle: 'What misc. does with the links and files you save.',
    children: [
      SettingsGroup(
        label: 'Saving links',
        footer:
            'misc. visits the page you pasted, like a browser would. None of '
            'your own content is sent anywhere.',
        children: [
          SettingsSwitch(
            title: 'Fetch titles and previews for pasted links',
            value: s.capture.fetchPreviews,
            onChanged: (v) => setState(() => s.setLinkPreviews(v)),
          ),
        ],
      ),
      SettingsGroup(
        label: 'Sharing',
        children: [
          SettingsRow(
            key: const ValueKey('shared-links'),
            title: 'Shared links',
            subtitle:
                '${s.workspace.shares.all.where((l) => l.activeAt(DateTime.now())).length} '
                'active. Read-only links served by your own hub; revoke them '
                'here.',
            onTap: () => showSharedLinks(context, s),
          ),
          SettingsRow(
            key: const ValueKey('open-vault'),
            icon: Icons.lock_outline,
            title: 'Private vault',
            subtitle:
                'Notes encrypted with a password; never searched, sent to '
                'AI, shared or exported.',
            onTap: () {
              Navigator.pop(context);
              s.openVault();
            },
          ),
        ],
      ),
      // Windows File Explorer only; on iPhone/iPad, sharing goes through the
      // Share menu / Shortcut (see ios/README_IOS.md).
      if (!touchFirst)
        SettingsGroup(
          label: 'Send to misc.',
          footer:
              'Adds “misc.” to the right-click “Send to” menu in File '
              'Explorer. Photos and files you send are saved in the Archive.',
          children: [
            SettingsRow(
              title: SendToBridge.isInstalled
                  ? 'Remove from the Send to menu'
                  : 'Add to the Send to menu',
              trailing: SettingsButton(
                label: SendToBridge.isInstalled ? 'Remove' : 'Add',
                icon: SendToBridge.isInstalled
                    ? Icons.remove_circle_outline
                    : Icons.add_circle_outline,
                // The menu entry is user-wide, so test data mode leaves it
                // alone.
                onPressed:
                    _busy || !Platform.isWindows || TestEnvironment.active
                    ? null
                    : _toggleSendTo,
              ),
            ),
          ],
        ),
    ],
  );

  Future<void> _toggleSendTo() => _run(() async {
    if (SendToBridge.isInstalled) {
      await SendToBridge.uninstall();
      s.showToast('Removed misc. from the Send to menu.');
    } else {
      final ok = await SendToBridge.install();
      s.showToast(
        ok ? 'Added misc. to the Send to menu.' : 'Could not add the shortcut.',
      );
    }
  });

  Widget _pencil() => SettingsPage(
    key: const ValueKey('settings-page-pencil'),
    title: 'Apple Pencil',
    subtitle: 'Gestures of the Pencil on this iPad.',
    children: [
      SettingsGroup(
        footer:
            'On the drawing you are using (canvas, note handwriting, Calendar '
            'in Draw mode). Apple Pencil 2 and Pro. Turning double-tap off in '
            'iPadOS Settings is respected too.',
        children: [
          SettingsSwitch(
            key: const ValueKey('pencil-double-tap'),
            title: 'Double-tap undoes',
            value: s.pencilDoubleTapUndo,
            onChanged: (v) async {
              await s.setPencilDoubleTapUndo(v);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    ],
  );

  Widget _sync() => SettingsPage(
    key: const ValueKey('settings-page-sync'),
    title: 'Sync & Devices',
    subtitle: 'Keep your devices in step through your own hub.',
    children: [
      SettingsGroup(
        label: 'Where your data is kept',
        padded: true,
        children: [StorageModeSection(state: s)],
      ),
      SettingsGroup(
        label: 'Sync hub',
        padded: true,
        children: [SyncSection(state: s)],
      ),
      SettingsGroup(
        label: 'Clipboard between my devices',
        footer: s.shareClipboard && touchFirst
            ? null
            : touchFirst
            ? 'Text copied on your PC arrives here, ready to paste in any app '
                  '(while misc. is open). Goes only through your own hub.'
            : 'While misc. runs, text you copy in any app is sent to your '
                  'other devices through your own hub, and text copied there '
                  'arrives on this clipboard. Off by default: copied '
                  'passwords would be shared too. The hub must run this '
                  'version of misc.',
        children: [
          SettingsSwitch(
            key: const ValueKey('share-clipboard'),
            title: 'Share copied text with my other devices',
            value: s.shareClipboard,
            onChanged: (v) async {
              await s.setShareClipboard(v);
              if (mounted) setState(() {});
            },
          ),
          if (s.shareClipboard && touchFirst)
            SettingsRow(
              title: 'Share clipboard now',
              subtitle: 'Text copied on this device is sent only when you ask.',
              trailing: SettingsButton(
                label: 'Share',
                icon: Icons.ios_share,
                onPressed: () async {
                  final clip = await s.checkClipboard();
                  s.showToast(
                    clip == null
                        ? 'Nothing new on the clipboard.'
                        : 'Shared with your other devices.',
                  );
                },
              ),
            ),
        ],
      ),
    ],
  );

  // ------------------------------------------------------ data & storage --

  /// The newest backup THEapp made of this data (an imported file is not
  /// one: it was made elsewhere, earlier).
  BackupLabel? get _lastBackup => _backups
      .map(BackupLabel.new)
      .where((l) => l.at != null && l.reasonId != 'imported')
      .firstOrNull;

  Widget _data() {
    final dataPath = s.workspace.root.path;
    final backups = s.workspace.backups;
    final last = _lastBackup;
    final shown = _allBackups ? _backups : _backups.take(6).toList();
    final usage = _usage;
    return SettingsPage(
      key: const ValueKey('settings-page-data'),
      title: 'Data & Storage',
      subtitle:
          'Your data belongs to you, not to one installation of misc. '
          'Keep a copy outside it.',
      children: [
        SettingsGroup(
          label: 'Automatic backup',
          footer:
              'Backups are checked file by file, never overwrite an earlier '
              'good one, and an interrupted backup is thrown away. A safety '
              'copy is always made before a data upgrade or a restore, '
              'whatever is set here.',
          children: [
            SettingsSwitch(
              key: const ValueKey('auto-backup'),
              title: 'Back up automatically',
              subtitle: touchFirst
                  ? 'A backup each time misc. starts and the schedule is due.'
                  : 'At start, and (while misc. runs) after changes.',
              value: s.autoBackupEnabled,
              onChanged: (v) => s.setAutoBackup(v),
            ),
            SettingsMenu<String>(
              menuKey: const ValueKey('auto-backup-frequency'),
              title: 'How often',
              subtitle: 'A weekly backup with photos and PDFs is always made.',
              value: s.autoBackupFrequency,
              options: const [('daily', 'Every day'), ('weekly', 'Every week')],
              onChanged: s.autoBackupEnabled
                  ? (v) => s.setAutoBackupFrequency(v)
                  : null,
            ),
            SettingsRow(
              title: 'Last backup',
              subtitle: last == null
                  ? 'None yet'
                  : '${last.when()} · ${last.reason}',
              trailing: SettingsButton(
                key: const ValueKey('backup-now'),
                icon: Icons.backup_outlined,
                label: 'Back up now',
                primary: true,
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await s.flush();
                        await backups.snapshot('manual');
                        s.showToast('Backup created.');
                      }),
              ),
            ),
          ],
        ),
        SettingsGroup(
          label: 'Keep a copy outside misc.',
          footer:
              'Deleting the app deletes its own folder, backups included. A '
              'file saved to Files, iCloud Drive or your PC survives. '
              '${touchFirst ? 'To update misc. without losing data, install the new build over the old one (same bundle ID); do not delete the app first unless you have exported a file.' : ''}',
          children: [
            SettingsRow(
              key: const ValueKey('export-all'),
              icon: Icons.ios_share,
              title: 'Export all data',
              subtitle:
                  'One .theappbackup file with everything, photos and PDFs '
                  'included. ${touchFirst ? 'Save it to Files or iCloud Drive in the sheet that opens.' : 'You choose where to save it.'}',
              onTap: _busy ? null : () => _run(() => exportAllData(s)),
            ),
            SettingsRow(
              key: const ValueKey('import-backup'),
              icon: Icons.file_open_outlined,
              title: 'Import a backup file',
              subtitle:
                  'Adds a .theappbackup to the list below after checking it. '
                  'Nothing is replaced until you restore it.',
              onTap: _busy ? null : () => _run(() => importBackupFile(s)),
            ),
            if (backups.copiesDir != null)
              SettingsRow(
                key: const ValueKey('save-backup-copy'),
                icon: Icons.save_alt,
                title: 'Save a copy in the Files app',
                subtitle:
                    'On My ${touchFirst ? 'iPad' : 'device'} → misc. → THEapp '
                    'Backups. Move it to iCloud Drive or your PC to keep it '
                    'safe.',
                onTap: _busy
                    ? null
                    : () => _run(() async {
                        try {
                          final copy = await s.saveBackupCopy();
                          if (copy != null) {
                            s.showToast(
                              'Backup saved in the Files app: On My iPad (or '
                              'iPhone) → misc. → THEapp Backups.',
                            );
                          }
                        } catch (e, st) {
                          AppLog.error('Saving a backup copy failed', e, st);
                          s.showToast(
                            'Could not save the backup copy. Nothing was '
                            'changed.',
                          );
                        }
                      }),
              ),
            SettingsRow(
              icon: Icons.computer_outlined,
              title: 'PC hub',
              subtitle: s.syncEnabled && !s.syncNeedsPairing
                  ? 'Paired: the hub keeps its own synced copy of your records '
                        'while it is reachable (${s.syncStatus}).'
                  : 'Not paired. When it is, the hub keeps a synced copy; '
                        'misc. works fully without it.',
            ),
            const SettingsRow(
              icon: Icons.cloud_outlined,
              title: 'iCloud',
              subtitle:
                  'Not built in. Save the exported file to iCloud Drive from '
                  'the share sheet instead.',
            ),
          ],
        ),
        SettingsGroup(
          label: 'Backup history',
          footer: _backups.isEmpty
              ? null
              : 'Open one to see when and by which build it was made, check '
                    'it, and restore it.',
          children: [
            if (_backups.isEmpty) const SettingsRow(title: 'No backups yet'),
            for (final b in shown)
              SettingsRow(
                key: ValueKey('backup-${BackupLabel(b).name}'),
                icon: Icons.history,
                title: BackupLabel(b).when(),
                subtitle:
                    '${BackupLabel(b).reason}${backups.isCopy(b) ? ' · copy in Files' : ''}',
                onTap: _busy ? null : () => showBackupDetails(context, s, b),
              ),
            if (_backups.length > shown.length || _allBackups)
              SettingsRow(
                title: _allBackups
                    ? 'Show fewer'
                    : 'Show all ${_backups.length}',
                onTap: () => setState(() => _allBackups = !_allBackups),
              ),
          ],
        ),
        SettingsGroup(
          label: 'Storage',
          padded: true,
          children: [
            SettingsNote(
              'Everything is stored only on $thisDevice, in:\n$dataPath',
            ),
            if (usage != null) ...[
              const SizedBox(height: 8),
              _UsageBar(usage: usage),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SettingsButton(
                  icon: Icons.folder_open,
                  label: 'Open data folder',
                  onPressed: native.canOpenFolders
                      ? () => native.openFolder(dataPath)
                      : null,
                ),
              ],
            ),
          ],
        ),
        SettingsGroup(
          label: 'Data safety',
          padded: true,
          children: [DataSafetySection(state: s)],
        ),
      ],
    );
  }

  // ------------------------------------------------------ the other pages --

  Widget _privacy() => SettingsPage(
    key: const ValueKey('settings-page-privacy'),
    title: 'Security & Privacy',
    subtitle:
        'How your data is protected, and whether it is working. Everything '
        'here happens automatically.',
    children: [
      SecurityStatusView(state: s),
      const SizedBox(height: 12),
      SettingsGroup(
        label: 'What stays on this device',
        padded: true,
        children: [PrivacySummary(state: s)],
      ),
    ],
  );

  Widget _ai() => SettingsPage(
    key: const ValueKey('settings-page-ai'),
    title: 'AI',
    subtitle: 'The assistant is off until you set it up.',
    children: [
      SettingsGroup(padded: true, children: [AiSettingsSection(state: s)]),
    ],
  );

  Widget _about() => SettingsPage(
    key: const ValueKey('settings-page-about'),
    title: 'About',
    children: [
      SettingsGroup(
        footer:
            'Every device paired with the same hub should run the same build '
            '(at least 371c6ca).',
        children: [
          SettingsRow(
            title: 'misc. build',
            trailing: SelectableText(
              appBuild,
              key: const ValueKey('about-build'),
              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
          ),
          SettingsRow(
            title: 'Platform',
            trailing: Text(
              defaultTargetPlatform.name,
              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    ],
  );
}

/// One entry of the category rail (or of the narrow list).
class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.category,
    required this.selected,
    required this.onTap,
    this.showHint = false,
  });

  final SettingsCategory category;
  final bool selected;
  final bool showHint;
  final VoidCallback onTap;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.category;
    final selected = widget.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: ValueKey('settings-category-${c.name}'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: widget.showHint ? 12 : 9,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.12)
                  : _hover
                  ? AppColors.hover
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AppColors.newDesign ? 12 : 8),
            ),
            child: Row(
              children: [
                Icon(
                  c.icon,
                  size: 19,
                  color: selected ? AppColors.accent : AppColors.textMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: selected ? AppColors.text : AppColors.text,
                        ),
                      ),
                      if (widget.showHint)
                        Text(
                          c.hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textFaint,
                          ),
                        ),
                    ],
                  ),
                ),
                if (widget.showHint)
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: AppColors.textFaint,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A stacked bar and legend: records, photos & documents, backups.
class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.usage});

  final ({int records, int attachments, int backups}) usage;

  @override
  Widget build(BuildContext context) {
    final total = usage.records + usage.attachments + usage.backups;
    final parts = [
      ('Records', usage.records, AppColors.accent),
      ('Photos & PDFs', usage.attachments, AppColors.warm),
      ('Backups', usage.backups, AppColors.textFaint),
    ];
    return Column(
      key: const ValueKey('storage-usage'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 8,
            child: total == 0
                ? ColoredBox(color: AppColors.cardRaised)
                : Row(
                    children: [
                      for (final (_, bytes, color) in parts)
                        if (bytes > 0)
                          Expanded(
                            flex: math.max(1, (bytes * 1000 ~/ total)),
                            child: ColoredBox(color: color),
                          ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            for (final (label, bytes, color) in parts)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$label  ${formatBytes(bytes)}',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}
