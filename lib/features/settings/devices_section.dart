// Settings → Sync: the devices paired with the hub, when each was last heard
// from, whether it can write or only read (a mirror), and a button to remove
// one. Removing is done by the hub: that device is refused from its next
// request on and the workspace key is changed for the devices that remain,
// without anyone typing a secret.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../sync/sync_client.dart' show HubDeviceInfo;

/// "2 minutes ago", "never", …
String lastSeenText(DateTime? at, [DateTime? now]) {
  if (at == null) return 'not seen yet';
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inSeconds < 90) return 'just now';
  if (d.inMinutes < 90) return '${d.inMinutes} minutes ago';
  if (d.inHours < 36) return '${d.inHours} hours ago';
  return '${d.inDays} days ago';
}

class DevicesSection extends StatefulWidget {
  const DevicesSection({super.key, required this.state});

  final AppState state;

  @override
  State<DevicesSection> createState() => _DevicesSectionState();
}

class _DevicesSectionState extends State<DevicesSection> {
  ({String self, List<HubDeviceInfo> devices})? _info;
  bool _loading = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final info = await widget.state.hubDevices();
    if (!mounted) return;
    setState(() {
      _info = info;
      _loading = false;
    });
  }

  Future<void> _remove(HubDeviceInfo d) async {
    final yes = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Remove ${d.name}?',
          style: const TextStyle(fontSize: AppType.sizeHeading),
        ),
        content: const Text(
          'It will stop syncing at once, and a new encryption key is made '
          'for your other devices. Notes it already has stay on it; to be '
          'used again it must be paired again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-remove-device'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _loading = true);
    final message = await widget.state.removeHubDevice(d.id);
    if (!mounted) return;
    setState(() => _message = message);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Column(
      key: const ValueKey('devices-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Devices',
                style: TextStyle(fontSize: AppType.sizeBodySmall),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              visualDensity: VisualDensity.compact,
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh, size: 16),
            ),
          ],
        ),
        if (info == null && !_loading)
          Text(
            'The device list needs the hub to be reachable.',
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              color: AppColors.textFaint,
            ),
          ),
        if (info != null)
          for (final d in info.devices)
            ListTile(
              key: ValueKey('device-${d.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              enabled: !d.revoked,
              title: Text(
                '${d.name}${d.id == info.self ? ' (this device)' : ''}',
                style: const TextStyle(fontSize: AppType.sizeBodySmall),
              ),
              subtitle: Text(
                '${d.revoked
                    ? 'Removed'
                    : d.readOnly
                    ? 'Read-only (a copy; cannot change your data)'
                    : 'Can read and write'}'
                ' · last seen ${lastSeenText(d.lastSeen)}',
                style: TextStyle(
                  fontSize: AppType.sizeLabel,
                  color: AppColors.textFaint,
                ),
              ),
              trailing: d.revoked
                  ? null
                  : TextButton(
                      key: ValueKey('remove-${d.id}'),
                      onPressed: _loading ? null : () => _remove(d),
                      child: const Text('Remove'),
                    ),
            ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(
              _message!,
              key: const ValueKey('device-message'),
              style: const TextStyle(fontSize: AppType.sizeLabel),
            ),
          ),
      ],
    );
  }
}
