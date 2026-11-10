// Settings → Security & Privacy: one honest status for each thing that keeps
// the data safe. It is a status page, not a control panel: every line is
// worked out from the real state of the app ([SecurityFacts]), nothing is
// scored, and "Protected" is never shown for the whole app while a part of it
// is failing.
//
// The model ([securityAreas], [overallStatus]) is plain Dart so tests can
// state any combination of facts; the widget only draws it.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/storage/storage_encryption.dart';
import '../../sync/storage_modes.dart';
import '../../sync/sync_scheduler.dart' show SyncConnection;
import 'backup_actions.dart';
import 'devices_section.dart';
import 'settings_widgets.dart';

/// The words shown to the user. Short, calm, and the same everywhere.
enum SecurityStatus {
  protected('Protected'),
  backingUp('Backing up'),
  syncPaused('Sync paused'),
  backupNeedsAttention('Backup needs attention'),
  authorizationExpired('Device authorization expired'),

  /// A local-protection problem (no key, or no secure storage on this
  /// platform). Not part of the fixed set above because it is a different
  /// kind of problem: the data cannot be opened or is not encrypted.
  needsAttention('Needs attention'),

  /// Not in use (e.g. no hub is set up): neither good nor bad.
  notInUse('Not in use');

  const SecurityStatus(this.label);
  final String label;

  /// Something is wrong that the user may need to know about.
  bool get isProblem => switch (this) {
    syncPaused ||
    backupNeedsAttention ||
    authorizationExpired ||
    needsAttention => true,
    _ => false,
  };
}

/// What the status page is worked out from.
class SecurityFacts {
  const SecurityFacts({
    required this.encryption,
    required this.dataProblem,
    required this.syncMode,
    required this.syncEnabled,
    required this.needsPairing,
    required this.connection,
    required this.pendingLocal,
    required this.lastSynced,
    required this.backupEnabled,
    required this.backupRunning,
    required this.lastBackup,
    required this.backupInterval,
    required this.recoveryPoints,
    this.backupIntact,
    this.backupFailure,
    this.now,
  });

  final EncryptionStatus encryption;

  /// The app opened the data read-only or refused it (newer data, failed
  /// upgrade): [AppState.dataProblem].
  final String? dataProblem;
  final StorageMode syncMode;
  final bool syncEnabled;
  final bool needsPairing;
  final SyncConnection connection;
  final bool pendingLocal;
  final DateTime? lastSynced;
  final bool backupEnabled;
  final bool backupRunning;
  final DateTime? lastBackup;

  /// How often automatic backups are due (daily or weekly).
  final Duration backupInterval;
  final int recoveryPoints;

  /// The newest backup was checked against its manifest: true intact, false
  /// damaged, null not checked (yet).
  final bool? backupIntact;

  /// The backup job's last failure, while it is still failing.
  final String? backupFailure;

  /// "Now" for the wording (tests set it); null means the real time.
  final DateTime? now;

  DateTime get at => now ?? DateTime.now();

  factory SecurityFacts.of(
    AppState s, {
    required DateTime? lastBackup,
    required int recoveryPoints,
    bool? backupIntact,
  }) {
    final job = s.maintenance?.job('backup');
    return SecurityFacts(
      encryption: StorageEncryption.active != null
          ? EncryptionStatus.enabled
          : s.dataProblem != null && s.dataProblem!.contains('key')
          ? EncryptionStatus.keyMissing
          : EncryptionStatus.unsupportedPlatform,
      dataProblem: s.dataProblem,
      syncMode: s.storageMode,
      syncEnabled: s.syncEnabled,
      needsPairing: s.syncNeedsPairing,
      connection: s.syncConnection,
      pendingLocal: s.syncPendingLocal,
      lastSynced: s.lastSynced,
      backupEnabled: s.autoBackupEnabled,
      backupRunning: job?.running ?? false,
      lastBackup: lastBackup,
      backupInterval: s.autoBackupEvery,
      recoveryPoints: recoveryPoints,
      backupIntact: backupIntact,
      backupFailure: (job?.failures ?? 0) >= 3
          ? job?.lastError
          : s.autoBackupError,
    );
  }
}

/// One of the four areas of the page.
class SecurityArea {
  const SecurityArea(this.id, this.title, this.status, this.detail);

  /// 'local', 'sync', 'backups' or 'devices'.
  final String id;
  final String title;
  final SecurityStatus status;

  /// One or two plain sentences: what it means, and what (if anything) to do.
  final String detail;
}

String _ago(DateTime? t, DateTime now) {
  if (t == null) return 'not yet';
  final d = now.difference(t);
  if (d.inMinutes < 2) return 'just now';
  if (d.inMinutes < 90) return '${d.inMinutes} minutes ago';
  if (d.inHours < 36) return '${d.inHours} hours ago';
  return '${d.inDays} days ago';
}

/// The four areas, from [f] alone.
List<SecurityArea> securityAreas(SecurityFacts f) {
  final now = f.at;
  final out = <SecurityArea>[];

  // A. Local protection
  if (f.dataProblem != null) {
    out.add(
      SecurityArea(
        'local',
        'Local protection',
        SecurityStatus.needsAttention,
        '${f.dataProblem} Nothing was deleted or overwritten.',
      ),
    );
  } else {
    out.add(switch (f.encryption) {
      EncryptionStatus.enabled => const SecurityArea(
        'local',
        'Local protection',
        SecurityStatus.protected,
        'Your data is encrypted on this device, and the key is kept in the '
            'system\'s protected storage. Nothing to do.',
      ),
      EncryptionStatus.unsupportedPlatform => const SecurityArea(
        'local',
        'Local protection',
        SecurityStatus.needsAttention,
        'This platform has no protected key storage, so your data is not '
            'encrypted on disk. It still works normally.',
      ),
      EncryptionStatus.keyMissing => const SecurityArea(
        'local',
        'Local protection',
        SecurityStatus.needsAttention,
        'This device does not have the key for the encrypted data, so it '
            'cannot be opened here. Nothing was changed. The key cannot be '
            'recreated; open misc. on a device that has it, or restore a '
            'backup made on this device.',
      ),
    });
  }

  // B. Hub synchronization
  if (f.syncMode == StorageMode.local) {
    out.add(
      const SecurityArea(
        'sync',
        'Hub synchronization',
        SecurityStatus.notInUse,
        'Nothing syncs: your data stays on this device. Set up a hub in '
            'Sync & Devices to use several devices.',
      ),
    );
  } else if (f.needsPairing) {
    out.add(
      const SecurityArea(
        'sync',
        'Hub synchronization',
        SecurityStatus.authorizationExpired,
        'This device needs to be authorized again before synchronization '
            'can resume. Your data here is safe and unsent changes are kept. '
            'Pair it again with a new code from the hub.',
      ),
    );
  } else if (!f.syncEnabled) {
    out.add(
      const SecurityArea(
        'sync',
        'Hub synchronization',
        SecurityStatus.syncPaused,
        'Sync is turned off here. Your changes are saved on this device and '
            'will sync when you turn it back on.',
      ),
    );
  } else if (f.connection == SyncConnection.offline ||
      f.connection == SyncConnection.paused ||
      f.connection == SyncConnection.blocked) {
    out.add(
      SecurityArea(
        'sync',
        'Hub synchronization',
        SecurityStatus.syncPaused,
        switch (f.connection) {
          SyncConnection.paused =>
            'Sync is paused on the PC. Your local changes are safe and '
                'will synchronize automatically when it is back on.',
          SyncConnection.blocked =>
            'The hub answers but refuses this device for now (see Settings → '
                'Sync for the reason). Your local changes are safe and are '
                'kept; sync resumes once the cause is fixed.',
          _ =>
            'The hub is currently unavailable. Your local changes are safe '
                'and will synchronize automatically when the connection '
                'returns.',
        },
      ),
    );
  } else {
    out.add(
      SecurityArea(
        'sync',
        'Hub synchronization',
        SecurityStatus.protected,
        'Connected and authorized. Last sync ${_ago(f.lastSynced, now)}.'
            '${f.pendingLocal ? ' Some changes are waiting to be sent.' : ''}',
      ),
    );
  }

  // C. Backups
  final last = f.lastBackup;
  final stale =
      last == null ||
      now.difference(last) > f.backupInterval + const Duration(days: 1);
  if (f.backupIntact == false) {
    out.add(
      const SecurityArea(
        'backups',
        'Backups',
        SecurityStatus.backupNeedsAttention,
        'The newest backup failed its check. Older backups were kept, and a '
            'new one is made automatically. Local saving continues normally.',
      ),
    );
  } else if (f.backupFailure != null) {
    out.add(
      const SecurityArea(
        'backups',
        'Backups',
        SecurityStatus.backupNeedsAttention,
        'Backups have been failing repeatedly (for example the disk is '
            'full). Your earlier backups are kept and local saving '
            'continues normally.',
      ),
    );
  } else if (f.backupRunning) {
    out.add(
      SecurityArea(
        'backups',
        'Backups',
        SecurityStatus.backingUp,
        'A backup is being made in the background. Last one: '
            '${_ago(last, now)}.',
      ),
    );
  } else if (!f.backupEnabled) {
    out.add(
      const SecurityArea(
        'backups',
        'Backups',
        SecurityStatus.backupNeedsAttention,
        'Automatic backups are turned off in Data & Storage, so nothing new '
            'is being backed up. Turn them on to protect new changes.',
      ),
    );
  } else if (stale) {
    out.add(
      SecurityArea(
        'backups',
        'Backups',
        SecurityStatus.backupNeedsAttention,
        last == null
            ? 'No backup has been made yet. One is made automatically; open '
                  'Data & Storage if it does not appear.'
            : 'The last backup is ${_ago(last, now)}, older than expected. '
                  'A new one is made automatically when misc. is open.',
      ),
    );
  } else {
    out.add(
      SecurityArea(
        'backups',
        'Backups',
        SecurityStatus.protected,
        'Last backup ${_ago(last, now)}; ${f.recoveryPoints} recovery '
            '${f.recoveryPoints == 1 ? 'point' : 'points'} on this device'
            '${f.backupIntact == true ? ', newest one checked and intact' : ''}'
            '. iCloud is not built in; export to iCloud Drive from Data & '
            'Storage for a copy outside this device.',
      ),
    );
  }

  // D. Device authorization
  if (f.syncMode == StorageMode.local) {
    out.add(
      const SecurityArea(
        'devices',
        'Device authorization',
        SecurityStatus.notInUse,
        'No other device is connected.',
      ),
    );
  } else if (f.needsPairing) {
    out.add(
      const SecurityArea(
        'devices',
        'Device authorization',
        SecurityStatus.authorizationExpired,
        'The hub no longer accepts this device. It needs to be authorized '
            'again before synchronization can resume.',
      ),
    );
  } else {
    out.add(
      const SecurityArea(
        'devices',
        'Device authorization',
        SecurityStatus.protected,
        'This device is authorized. Each device has its own credential, and '
            'removing one cuts it off at once.',
      ),
    );
  }
  return out;
}

/// The headline: the most important problem, else "Backing up", else
/// "Protected". Never "Protected" while an area has a problem.
SecurityStatus overallStatus(List<SecurityArea> areas) {
  const order = [
    SecurityStatus.needsAttention,
    SecurityStatus.authorizationExpired,
    SecurityStatus.backupNeedsAttention,
    SecurityStatus.syncPaused,
    SecurityStatus.backingUp,
  ];
  for (final s in order) {
    if (areas.any((a) => a.status == s)) return s;
  }
  return SecurityStatus.protected;
}

// ------------------------------------------------------------------ page --

/// The body of the Security & Privacy page: the headline, the four areas,
/// and the device list.
class SecurityStatusView extends StatefulWidget {
  const SecurityStatusView({super.key, required this.state});

  final AppState state;

  @override
  State<SecurityStatusView> createState() => _SecurityStatusViewState();
}

class _SecurityStatusViewState extends State<SecurityStatusView> {
  DateTime? _lastBackup;
  int _points = 0;
  bool? _intact;
  bool _checking = false;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final backups = s.workspace.backups;
    final list = await backups.list();
    final labels = list
        .map(BackupLabel.new)
        .where((l) => l.at != null && l.reasonId != 'imported')
        .toList();
    if (!mounted) return;
    setState(() {
      _lastBackup = labels.firstOrNull?.at;
      _points = labels.length;
    });
  }

  /// Checks the newest backup against its manifest (reads every file in it).
  Future<void> _check() async {
    final backups = s.workspace.backups;
    final newest = (await backups.list())
        .map(BackupLabel.new)
        .where((l) => l.at != null && l.reasonId != 'imported')
        .firstOrNull;
    if (newest == null || !mounted) return;
    setState(() => _checking = true);
    final problems = await backups.checkManifest(newest.directory);
    if (!mounted) return;
    setState(() {
      _intact = problems.isEmpty;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final areas = securityAreas(
          SecurityFacts.of(
            s,
            lastBackup: _lastBackup,
            recoveryPoints: _points,
            backupIntact: _intact,
          ),
        );
        final overall = overallStatus(areas);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Headline(status: overall, key: const ValueKey('security-overall')),
            const SizedBox(height: 20),
            for (final a in areas) ...[
              _AreaCard(
                area: a,
                action: a.id == 'backups'
                    ? SettingsButton(
                        key: const ValueKey('check-backup'),
                        label: _checking ? 'Checking…' : 'Check newest backup',
                        icon: Icons.fact_check_outlined,
                        onPressed: _checking ? null : _check,
                      )
                    : null,
              ),
              if (a.id == 'devices' &&
                  a.status != SecurityStatus.notInUse &&
                  a.status != SecurityStatus.authorizationExpired)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SettingsGroup(
                    padded: true,
                    children: [DevicesSection(state: s)],
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

Color _colorOf(SecurityStatus s) => switch (s) {
  SecurityStatus.protected => AppColors.success,
  SecurityStatus.backingUp => AppColors.accent,
  SecurityStatus.notInUse => AppColors.textFaint,
  _ => AppColors.warm,
};

class _Headline extends StatelessWidget {
  const _Headline({super.key, required this.status});

  final SecurityStatus status;

  @override
  Widget build(BuildContext context) {
    final color = _colorOf(status);
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Text(
          status.label,
          style: TextStyle(
            fontSize: AppType.sizeTitle,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
          ),
        ),
      ],
    );
  }
}

class _AreaCard extends StatelessWidget {
  const _AreaCard({required this.area, this.action});

  final SecurityArea area;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final color = _colorOf(area.status);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        key: ValueKey('security-area-${area.id}'),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.card),
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      area.title,
                      style: TextStyle(
                        fontSize: AppType.sizeBody,
                        fontWeight: FontWeight.w600,
                        color: AppColors.text,
                      ),
                    ),
                  ),
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
                    area.status.label,
                    key: ValueKey('security-status-${area.id}'),
                    style: TextStyle(
                      fontSize: AppType.sizeBodySmall,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                area.detail,
                style: TextStyle(
                  fontSize: AppType.sizeBodySmall,
                  height: 1.45,
                  color: AppColors.textMuted,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerLeft, child: action),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
