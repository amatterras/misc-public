import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/test_environment.dart';
import '../../app/theme.dart';
import '../../sync/local_hub.dart';
import '../../sync/sync_client.dart';
import '../../widgets/common.dart';

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

  /// What to type on an iPhone/iPad, after asking this PC's hub for a code.
  String? _shownCode;

  Future<void> _codeFromThisPc() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await localPairingCode();
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
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: Text(
                    s.syncStatus,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.danger,
                    ),
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
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: SelectableText(
                    _shownCode!,
                    key: const ValueKey('local-pair-result'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              const SizedBox(height: Space.sm),
              // Address on its own line when the dialog is narrow.
              if (MediaQuery.sizeOf(context).width < 640) ...[
                TextField(
                  controller: _url,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'Hub address',
                    hintText: 'http://100.x.y.z:47710',
                  ),
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
                          hintText: 'http://100.x.y.z:47710',
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
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _url,
                builder: (context, value, _) {
                  final uri = Uri.tryParse(value.text.trim());
                  final unencrypted =
                      uri != null &&
                      isAllowedHubUrl(uri) &&
                      !isEncryptedHubRoute(uri);
                  if (!unencrypted) return const SizedBox.shrink();
                  return const Padding(
                    key: ValueKey('unencrypted-warning'),
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'This is a home-network address: the connection is not '
                      'encrypted, so others on that network could read your '
                      'notes and this device’s key. Use this PC '
                      '(127.0.0.1) or a Tailscale address (100.x.y.z) instead '
                      'where you can.',
                      style: TextStyle(fontSize: 12, color: AppColors.danger),
                    ),
                  );
                },
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
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: const Text(
                  'Off pauses syncing on every device. Nothing is deleted: '
                  'changes are kept and sync when it is turned back on.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
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
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
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
            'only between your devices and that PC. THEapp works the same '
            'without it.',
      ),
      (
        'Start the hub on the PC',
        'Run "thehub serve" once (or "thehub startup enable" to start it '
            'with Windows). For an iPhone/iPad away from home, install '
            'Tailscale on both (free; SYNC_ARCHITECTURE.md §17).',
      ),
      (
        mobile ? 'Pair this iPhone/iPad' : 'Pair this PC',
        mobile
            ? 'On the PC, open THEapp → Settings → Sync → "Get a code" (or '
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
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 10,
                  backgroundColor: AppColors.card,
                  child: Text('${i + 1}', style: const TextStyle(fontSize: 11)),
                ),
                const SizedBox(width: Space.sm),
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
                    style: const TextStyle(
                      fontSize: 13,
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
  bool _busy = false;

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
      style: TextStyle(fontSize: 13),
    ),
    subtitle: const Text(
      'A server run for you (e.g. one you deployed from deploy/hosted). '
      'Your data is stored there; THEapp keeps working offline.',
      style: TextStyle(fontSize: 11, color: AppColors.textFaint),
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
            style: const TextStyle(fontSize: 12, color: AppColors.danger),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const ValueKey('hosted-sign-in'),
          onPressed: _busy
              ? null
              : () async {
                  setState(() {
                    _busy = true;
                    _error = null;
                  });
                  final error = await widget.state.signInHosted(
                    _url.text,
                    _email.text,
                    _password.text,
                    invite: _invite.text,
                  );
                  _password.clear();
                  if (mounted) {
                    setState(() {
                      _busy = false;
                      _error = error;
                    });
                  }
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
