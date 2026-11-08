// The private vault window: create (password + one-time recovery code),
// unlock, recover, and read/write private notes while unlocked.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/floating_windows.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart';
import 'vault_crypto.dart';
import 'vault_service.dart';

FloatingWindowSpec vaultWindow(AppState s) => FloatingWindowSpec(
  id: 'vault',
  title: 'Private vault',
  initialRect: const Rect.fromLTWH(160, 80, 620, 480),
  minSize: const Size(380, 320),
  builder: (_) => VaultPage(state: s),
  onClose: () {
    s.vault.lock();
    s.floating.close('vault');
  },
);

class VaultPage extends StatefulWidget {
  const VaultPage({super.key, required this.state});
  final AppState state;

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  final _title = TextEditingController();
  final _text = TextEditingController();
  bool _busy = false;
  bool _recovering = false;
  String? _error;
  String? _editing; // item id, '' for a new one

  VaultService get v => widget.state.vault;

  @override
  void initState() {
    super.initState();
    v.addListener(_onVault);
  }

  /// Locked: forget what was on screen.
  void _onVault() {
    if (v.unlocked) return;
    _editing = null;
    _title.clear();
    _text.clear();
  }

  @override
  void dispose() {
    v.removeListener(_onVault);
    for (final c in [_pw, _pw2, _title, _text]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      _pw.clear();
      _pw2.clear();
    } on VaultCryptoException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showRecovery(String code) => showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text(
        'Your recovery code',
        style: TextStyle(fontSize: AppType.sizeHeading),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            code,
            key: const ValueKey('vault-recovery-code'),
            style: const TextStyle(fontSize: 18, fontFamily: 'monospace'),
          ),
          const SizedBox(height: AppSpace.sm),
          const Text(
            'Write it down and keep it somewhere safe, away from this '
            'device. It is shown only now. Without the password or this '
            'code, nobody (not even misc.) can open the vault.',
            style: TextStyle(fontSize: AppType.sizeLabel),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            // Copying the code must not feed the shared clipboard.
            widget.state.suppressClipboardShare(code);
            Clipboard.setData(ClipboardData(text: code));
          },
          child: const Text('Copy'),
        ),
        TextButton(
          key: const ValueKey('vault-recovery-done'),
          onPressed: () => Navigator.pop(context),
          child: const Text('I saved it'),
        ),
      ],
    ),
  );

  Widget _field(TextEditingController c, String label, {Key? key}) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: TextField(
      key: key,
      controller: c,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      decoration: InputDecoration(labelText: label),
    ),
  );

  Widget _locked() {
    final creating = !v.exists;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Text(
          creating
              ? 'Make a private vault'
              : _recovering
              ? 'Open with the recovery code'
              : 'The vault is locked',
          style: const TextStyle(
            fontSize: AppType.sizeHeading,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          creating
              ? 'Private notes encrypted with your password (Argon2id + '
                    'AES-256-GCM). Only encrypted data is saved, backed up '
                    'and synced. They are never searched, sent to AI, shared '
                    'or exported. If another device already has a vault, '
                    'sync first so both use the same one.'
              : 'Locks itself after ${VaultService.idleLimit.inMinutes} '
                    'minutes without use and when misc. is hidden.',
          style: TextStyle(
            fontSize: AppType.sizeLabel,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: AppSpace.md),
        if (_recovering)
          _field(_pw2, 'Recovery code', key: const ValueKey('vault-code')),
        _field(
          _pw,
          creating || _recovering ? 'New password' : 'Password',
          key: const ValueKey('vault-password'),
        ),
        if (creating)
          _field(
            _pw2,
            'The same password again',
            key: const ValueKey('vault-password2'),
          ),
        if (_error != null)
          Text(_error!, style: TextStyle(color: AppColors.warm)),
        const SizedBox(height: AppSpace.sm),
        Row(
          children: [
            FilledButton(
              key: const ValueKey('vault-go'),
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      if (creating) {
                        if (_pw.text != _pw2.text) {
                          throw const VaultCryptoException(
                            'The two passwords are not the same.',
                          );
                        }
                        final code = await v.create(_pw.text);
                        if (mounted) await _showRecovery(code);
                      } else if (_recovering) {
                        await v.recover(_pw2.text, _pw.text);
                        _recovering = false;
                      } else {
                        await v.unlock(_pw.text);
                      }
                    }),
              child: Text(
                _busy
                    ? 'Working…'
                    : creating
                    ? 'Create'
                    : 'Unlock',
              ),
            ),
            if (!creating)
              TextButton(
                onPressed: () => setState(() {
                  _recovering = !_recovering;
                  _error = null;
                }),
                child: Text(
                  _recovering ? 'Use the password' : 'Forgot the password?',
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _unlocked() {
    final list = v.entries();
    if (_editing != null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          children: [
            TextField(
              key: const ValueKey('vault-item-title'),
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            Expanded(
              child: TextField(
                key: const ValueKey('vault-item-text'),
                controller: _text,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(hintText: 'Private text'),
              ),
            ),
            Row(
              children: [
                FilledButton(
                  key: const ValueKey('vault-item-save'),
                  onPressed: () {
                    v.save(
                      id: _editing!.isEmpty ? null : _editing,
                      title: _title.text,
                      text: _text.text,
                    );
                    setState(() => _editing = null);
                  },
                  child: const Text('Save'),
                ),
                TextButton(
                  onPressed: () => setState(() => _editing = null),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: AppSpace.lg),
            const Expanded(
              child: Text(
                'Private vault (unlocked)',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('vault-new'),
              onPressed: () {
                _title.clear();
                _text.clear();
                setState(() => _editing = '');
              },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New'),
            ),
            TextButton(
              onPressed: () async {
                final pw = await promptText(
                  context,
                  title:
                      'New password (at least ${VaultService.minPasswordLength})',
                  action: 'Change',
                );
                if (pw == null) return;
                await _run(() => v.changePassword(pw));
              },
              child: const Text('Change password'),
            ),
            IconButton(
              key: const ValueKey('vault-lock'),
              tooltip: 'Lock now',
              icon: const Icon(Icons.lock_outline, size: 18),
              onPressed: v.lock,
            ),
          ],
        ),
        if (_error != null)
          Text(_error!, style: TextStyle(color: AppColors.warm)),
        const Divider(height: 1),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Text(
                    'Nothing here yet.',
                    style: TextStyle(color: AppColors.textFaint),
                  ),
                )
              : ListView(
                  children: [
                    for (final e in list)
                      ListTile(
                        dense: true,
                        title: Text(e.title.isEmpty ? 'Untitled' : e.title),
                        subtitle: Text(
                          e.text.split('\n').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          _title.text = e.title;
                          _text.text = e.text;
                          setState(() => _editing = e.id);
                        },
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 16),
                          onPressed: () async {
                            if (await confirm(
                              context,
                              title: 'Delete this private note?',
                              message: 'It cannot be brought back.',
                            )) {
                              v.delete(e.id);
                            }
                          },
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.background,
    child: ListenableBuilder(
      listenable: Listenable.merge([v, widget.state.workspace.vaultMeta]),
      builder: (context, _) {
        return v.unlocked ? _unlocked() : _locked();
      },
    ),
  );
}
