// A short, accurate summary of where private content goes, for Settings.
// Every line is worked out from the real state of the app (what is
// encrypted, how it syncs, what the AI may see): nothing is claimed that is
// not true now, and the limits are stated next to the protections.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/storage/storage_encryption.dart';
import '../../sync/storage_modes.dart';
import '../ai/ai_service.dart';

/// What the summary is made from (so tests can state any combination).
class PrivacyFacts {
  const PrivacyFacts({
    required this.encryptedAtRest,
    required this.biometricLock,
    required this.syncMode,
    required this.hubEncryptedOnly,
    required this.activeShares,
    required this.aiEnabled,
    required this.aiLocal,
    required this.aiSources,
    required this.aiHost,
    required this.clipboardSync,
    required this.vaultExists,
  });

  /// Files in the data folder are AES-256-GCM encrypted.
  final bool encryptedAtRest;

  /// Face ID / Touch ID covers the app (iPhone/iPad).
  final bool biometricLock;
  final StorageMode syncMode;

  /// The hub is confirmed to accept only end-to-end encrypted data.
  final bool hubEncryptedOnly;
  final int activeShares;
  final bool aiEnabled;
  final bool aiLocal;
  final List<String> aiSources;
  final String aiHost;
  final bool clipboardSync;
  final bool vaultExists;

  factory PrivacyFacts.of(AppState s) {
    final engine = s.syncClientForSummary;
    return PrivacyFacts(
      encryptedAtRest: StorageEncryption.active != null,
      biometricLock: s.appLockActive,
      syncMode: s.storageMode,
      hubEncryptedOnly: engine?.requireSealed ?? false,
      activeShares: [
        for (final l in s.workspace.shares.all)
          if (l.activeAt(DateTime.now())) l,
      ].length,
      aiEnabled: s.ai.enabled,
      aiLocal: s.ai.isLocal,
      aiSources: [for (final x in s.ai.sources) x.label],
      aiHost: Uri.tryParse(s.ai.endpoint)?.host ?? '',
      clipboardSync: s.shareClipboard,
      vaultExists: s.vault.exists,
    );
  }
}

class PrivacyLine {
  const PrivacyLine(this.topic, this.text, {this.warn = false});
  final String topic;
  final String text;

  /// Something the user should know is NOT protected.
  final bool warn;
}

/// The lines of the summary, from [facts] alone.
List<PrivacyLine> privacyLines(PrivacyFacts f) {
  final out = <PrivacyLine>[];

  out.add(
    f.encryptedAtRest
        ? const PrivacyLine(
            'On this device',
            'Your notes, tasks, mindmaps, attachments, AI chats, browser '
                'history and backups are encrypted on disk with a key kept in '
                'the operating system\'s protected storage. While the app is '
                'open they are decrypted in memory. The log, exports you ask '
                'for, and short-lived copies for the PDF viewer are not '
                'encrypted.',
          )
        : const PrivacyLine(
            'On this device',
            'Not encrypted on disk: this platform has no protected key '
                'storage. Anyone who can read your files can read your notes.',
            warn: true,
          ),
  );

  out.add(
    f.biometricLock
        ? const PrivacyLine(
            'Locking',
            'The app is covered until Face ID or Touch ID succeeds: on '
                'opening, after leaving the app, and after 5 minutes without '
                'use. There is no password fallback.',
          )
        : const PrivacyLine(
            'Locking',
            'No app lock on this device (it needs Face ID or Touch ID).',
          ),
  );

  switch (f.syncMode) {
    case StorageMode.local:
      out.add(
        const PrivacyLine(
          'Sync',
          'Nothing is synchronized: your data stays on this device.',
        ),
      );
    case StorageMode.pcHub || StorageMode.hosted:
      final where = f.syncMode == StorageMode.hosted
          ? 'the hosted service'
          : 'your hub';
      out.add(
        f.hubEncryptedOnly
            ? PrivacyLine(
                'Sync',
                'Records and attachments are encrypted on your devices '
                    'before they reach $where. $where stores ciphertext and '
                    'can see only that it exists: record ids, when it '
                    'changed, which device, its size, and whether it was '
                    'deleted. It cannot read titles, text, links or file '
                    'names. Your devices hold the keys.',
              )
            : PrivacyLine(
                'Sync',
                'This device is set up to sync with $where, but it has not '
                    'yet been confirmed that $where holds only encrypted '
                    'data. Until the first successful sync, do not assume '
                    'it is end-to-end encrypted.',
                warn: true,
              ),
      );
  }

  out.add(
    f.activeShares == 0
        ? const PrivacyLine(
            'Shared links',
            'No active links. A link you make carries its key after the # '
                'in the address: the hub stores only ciphertext. Anyone '
                'with the whole link can read it until it expires or you '
                'revoke it; it cannot be un-read.',
          )
        : PrivacyLine(
            'Shared links',
            '${f.activeShares} active link(s). Anyone with the whole link '
                '(including the part after #) can read the shared text until '
                'it expires or you revoke it. The hub holds only ciphertext.',
          ),
  );

  if (f.vaultExists) {
    out.add(
      const PrivacyLine(
        'Private vault',
        'Vault notes are encrypted with your vault password and never go '
            'to search, AI, links, exports or the shared clipboard. They '
            'sync and are backed up only as ciphertext. If you lose both '
            'the password and the recovery code they cannot be opened.',
      ),
    );
  }

  if (!f.aiEnabled) {
    out.add(
      const PrivacyLine('AI', 'AI is off. Nothing is sent to any AI service.'),
    );
  } else if (f.aiLocal) {
    out.add(
      PrivacyLine(
        'AI',
        'AI runs on this computer (${f.aiHost}). What you choose to send '
            'does not leave it. Allowed material: ${f.aiSources.join(', ')}.',
      ),
    );
  } else {
    out.add(
      PrivacyLine(
        'AI',
        'AI uses a service on the internet (${f.aiHost}). When you press '
            'Send, the text (and pictures, if allowed) you see in the '
            'preview is sent to that company, under its terms. Allowed '
            'material: ${f.aiSources.join(', ')}. Vault notes are never '
            'sent.',
        warn: true,
      ),
    );
  }

  out.add(
    f.clipboardSync
        ? const PrivacyLine(
            'Clipboard',
            'Shared clipboard is on: text you copy is synced to your other '
                'devices (as ciphertext through the hub). Passwords, keys, '
                'tokens and vault text are never synced.',
            warn: true,
          )
        : const PrivacyLine(
            'Clipboard',
            'Shared clipboard is off. Nothing you copy is synced.',
          ),
  );

  out.add(
    const PrivacyLine(
      'Deleting',
      'Deleting removes your copies from this app, its backups and the hub '
          '(older versions are dropped, and devices are told). It does not '
          'promise forensic erasure: disks and operating systems may keep '
          'traces, and anything already shared, copied or exported stays '
          'where it went.',
    ),
  );
  return out;
}

/// The summary as shown in Settings.
class PrivacySummary extends StatelessWidget {
  const PrivacySummary({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final lines = privacyLines(PrivacyFacts.of(state));
        return Column(
          key: const ValueKey('privacy-summary'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.topic,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: l.warn ? AppColors.danger : null,
                      ),
                    ),
                    Text(
                      l.text,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              'This describes what the app does, not an independent security '
              'review.',
              style: TextStyle(fontSize: 11, color: AppColors.textFaint),
            ),
          ],
        );
      },
    );
  }
}
