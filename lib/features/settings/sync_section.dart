import 'peer_sync_row.dart';

import 'dart:io';

import 'package:flutter/material.dart';

import 'conflict_review.dart';
import 'devices_section.dart';
import '../../app/app_state.dart';
import '../../app/maintenance.dart';
import '../../app/test_environment.dart';
import '../../app/theme.dart';
import '../../hub/hub_host.dart';
import '../../sync/local_hub.dart';
import '../../sync/sync_client.dart';
import '../../sync/storage_modes.dart';
import '../sync_health/sync_health_center.dart';
import 'storage_section.dart';

/// Address pre-filled in the pairing form: the hub this device used before
/// (when it must pair again), else this PC's hub. On iPhone/iPad 127.0.0.1
/// would be the iPad itself, so the field starts empty there.
String defaultHubAddress({required bool onPhoneOrTablet, String? previous}) {
  if (previous != null) return previous;
  if (onPhoneOrTablet) return '';
  return TestEnvironment.active
      ? 'http://127.0.0.1:${TestEnvironment.testHubPort}'
      : 'http://127.0.0.1:47710';
}

/// Pairing with the PC sync hub, sync status, and conflict review.
class SyncSection extends StatefulWidget {
  const SyncSection({super.key, required this.state});

  final AppState state;

  @override
  State<SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<SyncSection> {
  late final _url = TextEditingController(
    text: defaultHubAddress(
      onPhoneOrTablet: widget.state.ios != null,
      previous: widget.state.hubUrl,
    ),
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

  /// Pairing is a change of storage mode: it goes through the verified
  /// switch (copy, verify, confirm), with the address and code prefilled.
  Future<void> _pair() async {
    setState(() => _error = null);
    await showStorageSwitchDialog(
      context,
      widget.state,
      StorageMode.pcHub,
      address: _url.text,
      pairingCode: _code.text,
    );
  }

  /// What to type on an iPhone/iPad, after asking this PC's hub for a code.
  String? _shownCode;

  Future<void> _codeFromThisPc() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.state.newPairingCode();
      _code.text = r.code;
      _url.text = 'http://127.0.0.1:${r.port}';
      _shownCode =
          'Code ${r.code} (valid ${r.minutes} minutes). '
          '${widget.state.syncPaired ? '' : 'Press Pair to connect this PC, or '}'
          'type the code on your iPhone/iPad with this PC’s '
          'Tailscale address (http://100.x.y.z:${r.port}).';
    } on LocalHubException catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.workspace.conflicts]),
      builder: (context, _) {
        if (!s.syncPaired) {
          final mobile = s.ios != null;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (s.syncNeedsPairing)
                Padding(
                  key: const ValueKey('repair-notice'),
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: Text(
                    s.syncStatus,
                    style: TextStyle(
                      fontSize: AppType.sizeBodySmall,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              if (s.syncNeedsPairing)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('open-sync-health'),
                    onPressed: () => showSyncHealthCenter(context, s),
                    icon: const Icon(Icons.health_and_safety_outlined, size: 16),
                    label: const Text('Sync health'),
                  ),
                ),
              _ConnectGuide(mobile: mobile),
              _HostedForm(state: s),
              if (!mobile && Platform.isWindows)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('local-pair-code'),
                    onPressed: _busy ? null : _codeFromThisPc,
                    icon: const Icon(Icons.key_outlined, size: 16),
                    label: const Text('Get a code from the hub on this PC'),
                  ),
                ),
              if (_shownCode != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: SelectableText(
                    _shownCode!,
                    key: const ValueKey('local-pair-result'),
                    style: const TextStyle(fontSize: AppType.sizeLabel),
                  ),
                ),
              const SizedBox(height: AppSpace.sm),
              // Address on its own line when the dialog is narrow.
              if (MediaQuery.sizeOf(context).width < 640) ...[
                TextField(
                  controller: _url,
                  style: const TextStyle(fontSize: AppType.sizeBodySmall),
                  decoration: const InputDecoration(
                    labelText: 'Hub address',
                    hintText: 'http://100.x.y.z:47710',
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
              ],
              Row(
                children: [
                  if (MediaQuery.sizeOf(context).width >= 640) ...[
                    Expanded(
                      child: TextField(
                        controller: _url,
                        style: const TextStyle(fontSize: AppType.sizeBodySmall),
                        decoration: const InputDecoration(
                          labelText: 'Hub address',
                          hintText: 'http://100.x.y.z:47710',
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                  ],
                  Flexible(
                    child: SizedBox(
                      width: 150,
                      child: TextField(
                        controller: _code,
                        style: const TextStyle(fontSize: AppType.sizeBodySmall),
                        decoration: const InputDecoration(
                          labelText: 'Pairing code',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  FilledButton(
                    onPressed: _busy ? null : _pair,
                    child: Text(_busy ? 'Pairing…' : 'Pair'),
                  ),
                ],
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _url,
                builder: (context, value, _) {
                  final uri = Uri.tryParse(value.text.trim());
                  final unencrypted = uri != null && isInsecureHubUrl(uri);
                  if (!unencrypted) return const SizedBox.shrink();
                  return Padding(
                    key: ValueKey('unencrypted-warning'),
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'This address is refused: plain http:// over a network '
                      'could be read by others on it. Use https://, this PC '
                      '(127.0.0.1) or a Tailscale address (100.x.y.z).',
                      style: TextStyle(
                        fontSize: AppType.sizeLabel,
                        color: AppColors.danger,
                      ),
                    ),
                  );
                },
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: AppType.sizeLabel,
                      color: AppColors.danger,
                    ),
                  ),
                ),
            ],
          );
        }
        final conflicts = s.openConflictCount;
        final last = s.lastSynced;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${s.syncing ? 'Syncing…' : s.syncStatus}'
              '${last == null ? '' : '  ·  last ${TimeOfDay.fromDateTime(last).format(context)}'}',
              style: const TextStyle(fontSize: AppType.sizeBodySmall),
            ),
            Text(
              'Hub: ${s.hubUrl}',
              style: TextStyle(
                fontSize: AppType.sizeLabel,
                color: AppColors.textFaint,
              ),
            ),
            if (s.syncNeedsPairing)
              Padding(
                key: const ValueKey('reauthorize-notice'),
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Sync is stopped: the hub does not accept this device. '
                      'Your changes are kept here.',
                      style: TextStyle(
                        fontSize: AppType.sizeLabel,
                        color: AppColors.danger,
                      ),
                    ),
                    // The hub that answered may have been the wrong one: this
                    // looks again, and a hub that accepts the device clears
                    // the state by itself.
                    OutlinedButton(
                      key: const ValueKey('reauthorize-check'),
                      onPressed: s.syncing ? null : s.syncNow,
                      child: const Text('Check again'),
                    ),
                  ],
                ),
              ),
            if (s.maintenance case final m?)
              MaintenanceStatusView(state: s, m: m),
            if (s.peerSync.isSupported) PeerSyncRow(state: s),
            // The master switch lives on the Windows PC (it also pauses the
            // hub there); devices just show "paused".
            if (Platform.isWindows)
              SwitchListTile(
                key: const ValueKey('sync-enabled'),
                contentPadding: EdgeInsets.zero,
                value: s.syncEnabled,
                onChanged: _busy
                    ? null
                    : (on) async {
                        setState(() => _busy = true);
                        final problem = await s.setSyncEnabled(on);
                        if (mounted) {
                          setState(() {
                            _busy = false;
                            _error = problem;
                          });
                        }
                      },
                title: const Text(
                  'Sync between devices',
                  style: TextStyle(fontSize: AppType.sizeBody),
                ),
                subtitle: Text(
                  'Off pauses syncing on every device. Nothing is deleted: '
                  'changes are kept and sync when it is turned back on.',
                  style: TextStyle(
                    fontSize: AppType.sizeLabel,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
            const SizedBox(height: AppSpace.sm),
            DevicesSection(state: s),
            const SizedBox(height: AppSpace.sm),
            SwitchListTile(
              key: const ValueKey('handoff-enabled'),
              contentPadding: EdgeInsets.zero,
              value: s.handoff.enabled,
              onChanged: (on) async {
                await s.handoff.setEnabled(on);
                if (mounted) setState(() {});
              },
              title: const Text(
                'Let my other devices resume where I am',
                style: TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                'Records which page, note or mindmap is open here (ids '
                'only, no text) so another device can offer to continue. '
                'Nothing opens by itself.',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              children: [
                OutlinedButton.icon(
                  onPressed: s.syncing ? null : s.syncNow,
                  icon: const Icon(Icons.sync, size: 16),
                  label: const Text('Sync now'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('open-sync-health'),
                  onPressed: () => showSyncHealthCenter(context, s),
                  icon: const Icon(Icons.health_and_safety_outlined, size: 16),
                  label: const Text('Sync health'),
                ),
                if (conflicts > 0)
                  OutlinedButton.icon(
                    onPressed: () => showConflictsDialog(context, s),
                    icon: const Icon(Icons.call_split, size: 16),
                    label: Text(
                      'Review $conflicts conflict${conflicts == 1 ? '' : 's'}',
                    ),
                  ),
                TextButton(
                  onPressed: () async {
                    // The same deliberate switch as Settings → Storage.
                    await showStorageSwitchDialog(
                      context,
                      s,
                      StorageMode.local,
                    );
                  },
                  child: const Text('Disconnect'),
                ),
                if (s.ios == null && Platform.isWindows)
                  TextButton(
                    key: const ValueKey('local-pair-code'),
                    onPressed: _busy ? null : _codeFromThisPc,
                    child: const Text('Get a code for another device'),
                  ),
              ],
            ),
            if (_shownCode != null) SelectableText(_shownCode!),
            if (_error != null)
              Text(_error!, style: TextStyle(color: AppColors.danger)),
          ],
        );
      },
    );
  }
}

/// Lists the preserved versions from sync conflicts, with an explicit choice
/// for each (see conflict_review.dart).
Future<void> showConflictsDialog(BuildContext context, AppState state) =>
    showConflictReview(context, state);

/// The three steps of connecting, in plain words.
class _ConnectGuide extends StatelessWidget {
  const _ConnectGuide({required this.mobile});
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final steps = [
      (
        'What this is',
        'Optional. Your own hub is a small program on your PC that keeps '
            'your devices in step. It is not a cloud service: your data goes '
            'only between your devices and that PC. misc. works the same '
            'without it.',
      ),
      (
        'Start the hub on the PC',
        'Run "thehub startup enable" once: it builds the hub program if '
            'needed and starts it, without a window, every time you sign in '
            'to Windows ("thehub startup status" shows whether it is running). '
            'THEapp also runs the hub itself while it is open. For an '
            'iPhone/iPad away from home, install Tailscale on both (free; '
            'docs/SYNC_ARCHITECTURE.md §17).',
      ),
      (
        mobile ? 'Pair this iPhone/iPad' : 'Pair this PC',
        mobile
            ? 'On the PC, open misc. → Settings → Sync → "Get a code" (or '
                  'run "thehub pair"). Type the PC’s Tailscale address '
                  '(http://100.x.y.z:47710) and the code below.'
            : 'Press "Get a code from the hub on this PC", then Pair.',
      ),
    ];
    return Column(
      key: const ValueKey('connect-guide'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, (title, text)) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 10,
                  backgroundColor: AppColors.card,
                  child: Text(
                    '${i + 1}',
                    style: const TextStyle(fontSize: AppType.sizeMeta),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$title. ',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(text: text),
                      ],
                    ),
                    style: TextStyle(
                      fontSize: AppType.sizeBodySmall,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Sign-in to a hosted sync service (instead of your own hub). Optional;
/// it uses the same sync as the hub and needs an account on the service.
class _HostedForm extends StatefulWidget {
  const _HostedForm({required this.state});
  final AppState state;

  @override
  State<_HostedForm> createState() => _HostedFormState();
}

class _HostedFormState extends State<_HostedForm> {
  final _url = TextEditingController(text: 'https://');
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _invite = TextEditingController();
  String? _error;
  final bool _busy = false;

  @override
  void dispose() {
    for (final c in [_url, _email, _password, _invite]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const ValueKey('hosted-sync'),
    tilePadding: EdgeInsets.zero,
    title: const Text(
      'Or use a hosted sync service',
      style: TextStyle(fontSize: AppType.sizeBodySmall),
    ),
    subtitle: Text(
      'A server run for you (e.g. one you deployed from deploy/hosted). '
      'Your data is stored there; misc. keeps working offline.',
      style: TextStyle(fontSize: AppType.sizeMeta, color: AppColors.textFaint),
    ),
    children: [
      TextField(
        controller: _url,
        decoration: const InputDecoration(labelText: 'Service address'),
      ),
      TextField(
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(labelText: 'Email'),
      ),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Password (12 characters or more)',
        ),
      ),
      TextField(
        controller: _invite,
        decoration: const InputDecoration(
          labelText: 'Invite code (only to create a new account)',
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            _error!,
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              color: AppColors.danger,
            ),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const ValueKey('hosted-sign-in'),
          onPressed: _busy
              ? null
              // Signing in changes the storage mode: verified switch.
              : () async {
                  setState(() => _error = null);
                  _password.clear();
                  await showStorageSwitchDialog(
                    context,
                    widget.state,
                    StorageMode.hosted,
                    address: _url.text,
                    email: _email.text,
                    invite: _invite.text,
                  );
                },
          child: Text(
            _busy
                ? 'Signing in…'
                : _invite.text.trim().isEmpty
                ? 'Sign in'
                : 'Create account and sign in',
          ),
        ),
      ),
    ],
  );
}

/// What the 10-second work did, each part on its own (Windows): the hub on
/// this PC, the last sync and backups that really completed, what runs
/// now, and the last problem with whether it is being retried.
class MaintenanceStatusView extends StatelessWidget {
  const MaintenanceStatusView({
    super.key,
    required this.state,
    required this.m,
  });

  final AppState state;
  final MaintenanceScheduler m;

  static String _time(DateTime? t) {
    if (t == null) return 'not yet';
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final today =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return '${today ? '' : '${t.year}-${two(t.month)}-${two(t.day)} '}'
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      final small = TextStyle(
        fontSize: AppType.sizeLabel,
        color: AppColors.textMuted,
      );
      final host = state.hubHost;
      final failing = [
        for (final j in m.jobs)
          if (j.lastError != null) j,
      ];
      return Padding(
        key: const ValueKey('maintenance-status'),
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (host != null)
              Text(switch (host.state) {
                HubHostState.running =>
                  'Hub on this PC: running in misc. (${host.listening.join(', ')})',
                HubHostState.external =>
                  'Hub on this PC: running separately (${host.listening.join(', ')})',
                HubHostState.recovering =>
                  'Hub on this PC: restarting — ${host.problem ?? ''}',
                HubHostState.failed =>
                  'Hub on this PC: ${host.problem ?? 'stopped'}',
                _ => 'Hub on this PC: starting…',
              }, style: small),
            Text(
              'Every 10 s — last sync ${_time(m.job('sync').lastSuccess)}, '
              'last backup ${_time(m.job('backup').lastSuccess)}'
              '${host == null ? '' : ', hub backup ${_time(m.job('hubBackup').lastSuccess)}'}',
              style: small,
            ),
            if (m.current case final j?)
              Text('Now: ${j.label ?? j.name}…', style: small),
            for (final j in failing)
              Text(
                '${j.label ?? j.name} failed at ${_time(j.lastErrorAt)}: '
                '${j.lastError} — retrying every 10 s',
                style: TextStyle(
                  fontSize: AppType.sizeLabel,
                  color: AppColors.warm,
                ),
              ),
          ],
        ),
      );
    },
  );
}
