// The recovery code in the app: where it is made and shown (once), where
// Settings tells its state, and the one-time offer after start-up.
// The logic is in data/storage/recovery_service.dart; this file is only the
// screens. The code is never stored by anything here.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/test_environment.dart';
import '../../app/theme.dart';
import '../../data/storage/recovery_service.dart';
import '../../data/storage/storage_encryption.dart';
import '../../sync/recovery_code.dart';
import 'settings_widgets.dart';

const _offeredKey = 'recoveryOffered';

const _riskText =
    'You will not need this code to use misc., sync or make backups. It is '
    'only for one situation: every device that holds your keys is gone (a '
    'new PC, a wiped phone) and you want your data back. Without it, or a '
    'trusted device, encrypted data cannot be opened by anyone, including '
    'us. This code is shown once and is not stored anywhere.';

/// Makes a new recovery code and shows it once. Returns true once the person
/// confirmed they saved it.
Future<bool> showRecoveryCodeDialog(
  BuildContext context,
  AppState state,
) async {
  final RecoveryCode code;
  try {
    code = await RecoveryService(state.workspace.root).create();
  } on Object catch (e) {
    if (context.mounted) {
      state.showToast('Could not make a recovery code: $e');
    }
    return false;
  }
  if (!context.mounted) return false;
  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RecoveryCodeDialog(code: code.text),
  );
  return done == true;
}

class RecoveryCodeDialog extends StatefulWidget {
  const RecoveryCodeDialog({super.key, required this.code});

  final String code;

  @override
  State<RecoveryCodeDialog> createState() => RecoveryCodeDialogState();
}

class RecoveryCodeDialogState extends State<RecoveryCodeDialog> {
  bool _saved = false;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('recovery-code-dialog'),
      backgroundColor: AppColors.card,
      title: const Text('Your recovery code'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                widget.code,
                key: const ValueKey('recovery-code-text'),
                style: TextStyle(
                  fontSize: 19,
                  height: 1.5,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                  color: AppColors.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _riskText,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  SettingsButton(
                    label: _copied ? 'Copied' : 'Copy',
                    icon: Icons.copy_rounded,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: widget.code));
                      if (mounted) setState(() => _copied = true);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Put it in a password manager or print it. Clipboard history '
                'may keep a copy: clear it afterwards if you copy.',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint),
              ),
              CheckboxListTile(
                key: const ValueKey('recovery-saved'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _saved,
                onChanged: (v) => setState(() => _saved = v ?? false),
                title: const Text(
                  'I have saved this code somewhere safe',
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('recovery-done'),
          onPressed: _saved ? () => Navigator.pop(context, true) : null,
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// The Settings group: whether a code exists, and a button to make one.
class RecoverySection extends StatefulWidget {
  const RecoverySection({super.key, required this.state});

  final AppState state;

  @override
  State<RecoverySection> createState() => _RecoverySectionState();
}

class _RecoverySectionState extends State<RecoverySection> {
  late Future<RecoveryStatus> _status = _load();

  Future<RecoveryStatus> _load() =>
      RecoveryService(widget.state.workspace.root).status();

  String _text(RecoveryStatus s) {
    String day(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return switch (s.state) {
      RecoveryState.none =>
        'Not made yet. Optional, but it is the only way back in if every '
            'device that holds your keys is lost.',
      RecoveryState.current =>
        'Made${s.created == null ? '' : ' on ${day(s.created!.toLocal())}'}. '
            'Keep it safe; it is not shown again.',
      RecoveryState.outOfDate =>
        'Made${s.created == null ? '' : ' on ${day(s.created!.toLocal())}'}, '
            'but your sync key has changed since. Make a new one so it '
            'covers the current key.',
    };
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RecoveryStatus>(
      future: _status,
      builder: (context, snap) {
        final s = snap.data;
        return SettingsGroup(
          label: 'Recovery code',
          footer: 'A new code replaces the old one; the old one stops working.',
          children: [
            SettingsRow(
              key: const ValueKey('recovery-row'),
              title: 'Recovery code',
              subtitle: s == null ? 'Checking…' : _text(s),
              trailing: s == null
                  ? null
                  : SettingsButton(
                      label: s.state == RecoveryState.none
                          ? 'Make code'
                          : 'Make a new code',
                      onPressed: () async {
                        await showRecoveryCodeDialog(context, widget.state);
                        if (mounted) setState(() => _status = _load());
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// After start-up, once: offers to make a recovery code. Never blocks
/// anything; "Not now" is final (Settings keeps the option), and nothing is
/// offered where there is no key to protect or in test-data mode.
Future<void> offerRecoveryCodeOnce(BuildContext context, AppState state) async {
  if (TestEnvironment.active) return;
  if (state.settings.get<bool>(_offeredKey) ?? false) return;
  final root = state.workspace.root;
  if (await OsWorkspaceKeyStore(root).read() == null) return;
  if ((await RecoveryService(root).status()).state != RecoveryState.none) {
    await state.settings.set(_offeredKey, true);
    return;
  }
  if (!context.mounted) return;
  final make = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('recovery-offer'),
      backgroundColor: AppColors.card,
      title: const Text('Keep a recovery code?'),
      content: const SizedBox(
        width: 420,
        child: Text(
          'Your data is encrypted, and its keys live only on your devices. '
          'A recovery code, made once, lets you get back in if all of them '
          'are lost. You never need it otherwise.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Make code'),
        ),
      ],
    ),
  );
  await state.settings.set(_offeredKey, true);
  if (make == true && context.mounted) {
    await showRecoveryCodeDialog(context, state);
  }
}
