// Settings → Storage: the three storage modes, the copy-and-verify switch
// between them, and the data-safety tools (integrity check, recently
// deleted). See STORAGE_MODES.md.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/test_environment.dart';
import '../../app/theme.dart';
import '../../data/integrity/integrity_check.dart';
import '../../sync/local_hub.dart';
import '../../sync/storage_modes.dart';
import '../../sync/sync_client.dart';
import '../../widgets/common.dart';

/// The mode in use, with an honest status line, and the other two modes
/// with a "Switch…" button each.
class StorageModeSection extends StatelessWidget {
  const StorageModeSection({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final current = state.storageMode;
      return Column(
        key: const ValueKey('storage-modes'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final mode in StorageMode.values)
            _ModeTile(state: state, mode: mode, selected: mode == current),
          const SizedBox(height: Space.xs),
          Text(
            _statusLine(state),
            key: const ValueKey('storage-status'),
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      );
    },
  );

  static String _statusLine(AppState s) {
    final p = s.storageProvider;
    if (p is LocalOnlyProvider) {
      return 'Stored on this device only. Nothing is uploaded, and your other '
          'devices do not receive these changes. Keep backups (below) and '
          'use "Save a copy" to move data off this device.';
    }
    final last = s.lastSynced;
    return '${p.mode.label} (${p.displayAddress}): ${s.syncStatus}'
        '${last == null ? '' : ' · last successful sync ${_time(last)}'}';
  }

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.state,
    required this.mode,
    required this.selected,
  });

  final AppState state;
  final StorageMode mode;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('storage-mode-${mode.name}'),
    margin: const EdgeInsets.only(bottom: Space.xs),
    padding: const EdgeInsets.all(Space.sm),
    decoration: BoxDecoration(
      color: selected ? AppColors.card : null,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: selected ? AppColors.accent : AppColors.border),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          size: 18,
          color: selected ? AppColors.accent : AppColors.textFaint,
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                selected ? '${mode.label}  ·  in use' : mode.label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                mode.explanation,
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        if (!selected)
          TextButton(
            key: ValueKey('switch-to-${mode.name}'),
            onPressed: () => showStorageSwitchDialog(context, state, mode),
            child: const Text('Switch…'),
          ),
      ],
    ),
  );
}

/// The switch, step by step: destination details → check and connect →
/// copy and verify → confirm. Cancel at any step changes nothing here.
/// Returns true when the new mode was activated.
Future<bool> showStorageSwitchDialog(
  BuildContext context,
  AppState state,
  StorageMode target, {
  String? address,
  String? pairingCode,
  String? email,
  String? invite,
}) async {
  if (target == StorageMode.local) {
    final ok = await confirm(
      context,
      title: 'Store on this device only?',
      message:
          'THEapp stops syncing. Everything stays on this device, and the '
          '${state.storageMode.label.toLowerCase()} keeps its copy (nothing '
          'is deleted there). Changes made here afterwards reach no other '
          'device.',
      action: 'Switch to this device only',
    );
    if (!ok) return false;
    final note = await state.switchToLocalOnly();
    state.showToast(note ?? 'Now storing on this device only.');
    return true;
  }
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SwitchDialog(
      state: state,
      target: target,
      address: address,
      pairingCode: pairingCode,
      email: email,
      invite: invite,
    ),
  );
  return result ?? false;
}

class _SwitchDialog extends StatefulWidget {
  const _SwitchDialog({
    required this.state,
    required this.target,
    this.address,
    this.pairingCode,
    this.email,
    this.invite,
  });

  final AppState state;
  final StorageMode target;
  final String? address;
  final String? pairingCode;
  final String? email;
  final String? invite;

  @override
  State<_SwitchDialog> createState() => _SwitchDialogState();
}

enum _Step { details, copy, confirm }

class _SwitchDialogState extends State<_SwitchDialog> {
  late final _address = TextEditingController(
    text:
        widget.address ??
        (widget.target == StorageMode.hosted
            ? 'https://'
            : widget.state.ios != null
            ? ''
            : TestEnvironment.active
            ? 'http://127.0.0.1:${TestEnvironment.testHubPort}'
            : 'http://127.0.0.1:47710'),
  );
  late final _code = TextEditingController(text: widget.pairingCode ?? '');
  late final _email = TextEditingController(text: widget.email ?? '');
  final _password = TextEditingController();
  late final _invite = TextEditingController(text: widget.invite ?? '');

  _Step _step = _Step.details;
  bool _busy = false;
  String? _error;
  String? _info;
  StorageSwitch? _switch;
  int _destinationChanges = 0;
  SwitchVerification? _verification;

  bool get _hosted => widget.target == StorageMode.hosted;

  @override
  void dispose() {
    for (final c in [_address, _code, _email, _password, _invite]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on SyncFailure catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Something went wrong (${e.runtimeType}). Nothing was changed.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _codeFromThisPc() => _guard(() async {
    try {
      final r = await localPairingCode();
      _code.text = r.code;
      _address.text = 'http://127.0.0.1:${r.port}';
    } on LocalHubException catch (e) {
      _error = e.message;
    }
  });

  /// Check the destination and connect (pairing / sign-in).
  Future<void> _connect() => _guard(() async {
    final uri = Uri.tryParse(_address.text.trim());
    if (uri == null || uri.host.isEmpty) {
      throw const SyncFailure('bad_address', 'Enter the address.');
    }
    final to = _hosted ? HostedProvider(uri) : PcHubProvider(uri);
    final problem = to.problem;
    if (problem != null) throw SyncFailure('bad_address', problem);
    final change = await widget.state.beginStorageSwitch(to);
    await change.plan();
    _destinationChanges = await change.connect(
      _hosted
          ? ProviderCredentials.account(
              _email.text,
              _password.text,
              invite: _invite.text,
            )
          : ProviderCredentials.pairing(_code.text),
    );
    _password.clear();
    _switch = change;
    _step = _Step.copy;
  });

  Future<void> _copy() => _guard(() async {
    final v = _verification = await _switch!.copyAndVerify();
    if (v.ok) _step = _Step.confirm;
  });

  Future<void> _activate() => _guard(() async {
    await widget.state.activateStorage(_switch!);
    if (mounted) Navigator.pop(context, true);
    widget.state.showToast('Now using ${widget.target.label.toLowerCase()}.');
  });

  Future<void> _cancel() async {
    await _switch?.cancel();
    if (mounted) Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    final children = switch (_step) {
      _Step.details => _detailsStep(),
      _Step.copy => _copyStep(),
      _Step.confirm => _confirmStep(),
    };
    return AlertDialog(
      title: Text(
        'Switch to: ${widget.target.label}',
        style: const TextStyle(fontSize: 16),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...children,
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    _error!,
                    key: const ValueKey('switch-error'),
                    style: TextStyle(fontSize: 12, color: AppColors.danger),
                  ),
                ),
              if (_info != null)
                Text(_info!, style: const TextStyle(fontSize: 12)),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: Space.sm),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('switch-cancel'),
          onPressed: _busy ? null : _cancel,
          child: const Text('Cancel'),
        ),
        if (_step == _Step.details)
          FilledButton(
            key: const ValueKey('switch-connect'),
            onPressed: _busy ? null : _connect,
            child: Text(_hosted ? 'Sign in' : 'Pair'),
          ),
        if (_step == _Step.copy)
          FilledButton(
            key: const ValueKey('switch-copy'),
            onPressed: _busy ? null : _copy,
            child: const Text('Copy and verify'),
          ),
        if (_step == _Step.confirm)
          FilledButton(
            key: const ValueKey('switch-activate'),
            onPressed: _busy ? null : _activate,
            child: Text('Use ${widget.target.label.toLowerCase()}'),
          ),
      ],
    );
  }

  List<Widget> _detailsStep() => [
    Text(
      widget.target.explanation,
      style: TextStyle(fontSize: 13, color: AppColors.textMuted),
    ),
    const SizedBox(height: Space.sm),
    Text(
      'Nothing changes until the copy is verified and you confirm. Your data '
      'on this device is never replaced by the switch.',
      style: TextStyle(fontSize: 12, color: AppColors.textFaint),
    ),
    TextField(
      key: const ValueKey('switch-address'),
      controller: _address,
      decoration: InputDecoration(
        labelText: _hosted ? 'Service address (https://…)' : 'Hub address',
      ),
    ),
    if (!_hosted) ...[
      TextField(
        key: const ValueKey('switch-code'),
        controller: _code,
        decoration: const InputDecoration(labelText: 'Pairing code'),
      ),
      if (widget.state.ios == null && Platform.isWindows)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy ? null : _codeFromThisPc,
            icon: const Icon(Icons.key_outlined, size: 16),
            label: const Text('Get a code from the hub on this PC'),
          ),
        ),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _address,
        builder: (context, value, _) {
          final uri = Uri.tryParse(value.text.trim());
          final unencrypted =
              uri != null && isAllowedHubUrl(uri) && !isEncryptedHubRoute(uri);
          if (!unencrypted) return const SizedBox.shrink();
          return Text(
            'Home-network address: this connection is not encrypted. Prefer '
            '127.0.0.1 or a Tailscale address (100.x.y.z).',
            key: ValueKey('switch-unencrypted-warning'),
            style: TextStyle(fontSize: 12, color: AppColors.danger),
          );
        },
      ),
    ] else ...[
      TextField(
        key: const ValueKey('switch-email'),
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(labelText: 'Email'),
      ),
      TextField(
        key: const ValueKey('switch-password'),
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Password (12 characters or more)',
        ),
      ),
      TextField(
        key: const ValueKey('switch-invite'),
        controller: _invite,
        decoration: const InputDecoration(
          labelText: 'Invite code (only to create a new account)',
        ),
      ),
    ],
  ];

  List<Widget> _copyStep() {
    final v = _verification;
    return [
      Text(
        _destinationChanges > 0
            ? 'Connected. The destination already holds data '
                  '($_destinationChanges change(s)). Your records will be '
                  'MERGED with it, not replace it: where both sides have '
                  'different versions, both are kept and shown as conflicts.'
            : 'Connected. The destination is empty.',
        key: const ValueKey('switch-destination'),
        style: TextStyle(
          fontSize: 13,
          color: _destinationChanges > 0 ? AppColors.warm : null,
        ),
      ),
      const SizedBox(height: Space.sm),
      Text(
        'Next: a full backup of this device is made and checked, copied to '
        'the destination from that backup (your live data is not touched), '
        'then every record and attachment is read back and compared.',
        style: TextStyle(fontSize: 12, color: AppColors.textMuted),
      ),
      if (v != null && !v.ok) ...[
        const SizedBox(height: Space.sm),
        Text(
          'The copy could not be verified (${v.problems.length} problem(s)), '
          'so nothing was switched. First: ${v.problems.first}. You can try '
          'again or cancel.',
          key: const ValueKey('switch-verify-failed'),
          style: TextStyle(fontSize: 12, color: AppColors.danger),
        ),
      ],
    ];
  }

  List<Widget> _confirmStep() {
    final v = _verification!;
    return [
      Text(
        'Verified: ${v.checked} record version(s) and '
        '${v.attachmentsChecked} attachment(s) are on the destination.'
        '${v.conflicts > 0 ? ' ${v.conflicts} conflict(s) were kept for review.' : ''}',
        key: const ValueKey('switch-verified'),
        style: const TextStyle(fontSize: 13),
      ),
      const SizedBox(height: Space.sm),
      Text(
        'Switch now? This device keeps all its data. '
        '${widget.state.storageMode == StorageMode.local ? '' : 'The ${widget.state.storageMode.label.toLowerCase()} keeps its copy; nothing is deleted there. '}'
        'A backup from just before the copy is kept on this device.',
        style: TextStyle(fontSize: 12, color: AppColors.textMuted),
      ),
    ];
  }
}

/// Settings → Data safety: integrity check and recently deleted records.
class DataSafetySection extends StatelessWidget {
  const DataSafetySection({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: Space.sm,
    runSpacing: Space.sm,
    children: [
      OutlinedButton.icon(
        key: const ValueKey('check-data'),
        onPressed: () => _showIntegrity(context),
        icon: const Icon(Icons.fact_check_outlined, size: 16),
        label: const Text('Check data'),
      ),
      OutlinedButton.icon(
        key: const ValueKey('recently-deleted-records'),
        onPressed: () => _showDeleted(context),
        icon: const Icon(Icons.restore_from_trash_outlined, size: 16),
        label: const Text('Recently deleted'),
      ),
    ],
  );

  Future<void> _showIntegrity(BuildContext context) async {
    final report = await state.checkIntegrity();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Data check', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 560,
          height: 420,
          child: report.clean
              ? Center(
                  child: Text(
                    'No problems found (${report.checked} items checked). '
                    'This check only reads; it never changes or removes '
                    'anything.',
                    key: const ValueKey('integrity-clean'),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView(
                  key: const ValueKey('integrity-issues'),
                  children: [
                    Text(
                      'Nothing was changed or removed. Each item says what '
                      'you can do.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                    for (final i in report.issues)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          i.severity == IntegritySeverity.problem
                              ? Icons.error_outline
                              : Icons.info_outline,
                          size: 18,
                          color: i.severity == IntegritySeverity.problem
                              ? AppColors.danger
                              : AppColors.textFaint,
                        ),
                        title: Text(
                          i.detail,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '${i.where}\n${i.recovery}',
                          style: const TextStyle(fontSize: 11),
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
      ),
    );
  }

  Future<void> _showDeleted(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final items = state.recentlyDeletedRecords()
          ..sort(
            (a, b) => (b.$3['at'] as String? ?? '').compareTo(
              a.$3['at'] as String? ?? '',
            ),
          );
        return AlertDialog(
          title: const Text(
            'Recently deleted (30 days)',
            style: TextStyle(fontSize: 16),
          ),
          content: SizedBox(
            width: 560,
            height: 420,
            child: items.isEmpty
                ? const Center(child: Text('Nothing deleted recently.'))
                : ListView(
                    children: [
                      for (final (collection, id, kept) in items)
                        ListTile(
                          dense: true,
                          title: Text(
                            _title(kept['data'], id),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${collection.replaceAll('_', ' ')} · deleted '
                            '${(kept['at'] as String? ?? '').split('T').first}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: TextButton(
                            onPressed: () {
                              final ok = state.restoreDeletedRecord(
                                collection,
                                id,
                              );
                              state.showToast(
                                ok ? 'Restored.' : 'It could not be restored.',
                              );
                              setState(() {});
                            },
                            child: const Text('Restore'),
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

  static String _title(Object? data, String id) {
    if (data is! Map) return id;
    final t = data['title'] ?? data['name'] ?? data['text'];
    final s = t?.toString().split('\n').first.trim() ?? '';
    return s.isEmpty ? id : s;
  }
}
