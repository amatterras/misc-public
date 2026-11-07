// The switch for direct sync between your own devices (iPhone and iPad).
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../sync/peer_controller.dart';

class PeerSyncRow extends StatelessWidget {
  const PeerSyncRow({super.key, required this.state});

  final AppState state;

  String _text(PeerSyncController c) => switch (c.status) {
    PeerSyncStatus.running =>
      c.peers.isEmpty
          ? 'On. Looking for your other devices on this network…'
          : 'On. Connected to ${c.peers.length} other '
                '${c.peers.length == 1 ? 'device' : 'devices'}.',
    PeerSyncStatus.starting => 'Starting…',
    PeerSyncStatus.needsKey =>
      'This device does not have your workspace key yet. Pair it once with '
          'your PC (or a device that has it), then turn this on.',
    PeerSyncStatus.failed => 'Could not start: ${c.problem ?? 'unknown'}',
    PeerSyncStatus.unsupported => 'Not available on this device.',
    PeerSyncStatus.off =>
      'Syncs with your other devices on the same network, even when the PC '
          'is off. Works while this app is open; iOS does not allow more.',
  };

  @override
  Widget build(BuildContext context) {
    final c = state.peerSync;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => SwitchListTile(
        key: const ValueKey('peer-sync'),
        contentPadding: EdgeInsets.zero,
        value: c.enabled,
        onChanged: (on) => c.setEnabled(on),
        title: const Text(
          'Sync directly between my devices',
          style: TextStyle(fontSize: AppType.sizeBody),
        ),
        subtitle: Text(
          _text(c),
          style: TextStyle(
            fontSize: AppType.sizeLabel,
            color: AppColors.textFaint,
          ),
        ),
      ),
    );
  }
}
