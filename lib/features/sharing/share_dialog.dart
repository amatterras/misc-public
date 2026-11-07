// Read-only share links, served by the user's own hub (no outside
// hosting). A link holds a random secret; only its SHA-256 syncs, so the
// hub and other devices never store the secret itself. The secret stays
// on the device that made the link, to copy it again later. Links can
// expire and can be revoked; a revoked or expired link shows nothing.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/knowledge_models.dart';
import '../../sync/e2ee.dart';

const _tokensKey = 'shareTokens';
const _keysKey = 'shareKeys';

/// What may be shared. The private vault is not on the list, so vault
/// content can never be put in a link, sealed or not.
const shareableKinds = {'note', 'link', 'entry', 'canvas', 'experiment'};

String _newToken() {
  final r = Random.secure();
  return base64Url
      .encode([for (var i = 0; i < 32; i++) r.nextInt(256)])
      .replaceAll('=', '');
}

String shareIdFor(String token) =>
    sha256.convert(utf8.encode(token)).toString();

/// The link for [token] on the paired hub, or null when not paired.
///
/// The key that opens the snapshot is in the part after `#`, which browsers
/// never send to the server, so the hub (and its logs) never see it. A link
/// made before sharing was encrypted has no key and gives null.
String? shareUrl(AppState s, String token) {
  final hub = s.hubUrl;
  if (hub == null) return null;
  final key = _keys(s)[shareIdFor(token)];
  if (key == null) return null;
  final base = hub.endsWith('/') ? hub.substring(0, hub.length - 1) : hub;
  return '$base/s/$token#k=$key';
}

Map<String, String> _keys(AppState s) => {
  for (final MapEntry(:key, :value)
      in (s.settings.get<Map>(_keysKey) ?? const {}).entries)
    if (key is String && value is String) key: value,
};

Map<String, String> _tokens(AppState s) => {
  for (final MapEntry(:key, :value)
      in (s.settings.get<Map>(_tokensKey) ?? const {}).entries)
    if (key is String && value is String) key: value,
};

/// Makes a share link (snapshot of [body]); returns its secret token.
Future<String> createShare(
  AppState s, {
  required String kind,
  required String sourceId,
  required String title,
  required String body,
  Duration? lifetime,
}) async {
  if (!shareableKinds.contains(kind)) {
    throw ArgumentError(
      'Only notes, links, entries, canvases and thought '
      'experiments can be shared, not "$kind".',
    );
  }
  final token = _newToken();
  final now = DateTime.now();
  final text = body.length > ShareLink.maxBodyChars
      ? body.substring(0, ShareLink.maxBodyChars)
      : body;
  // Sealed here, on this device: the hub only ever gets ciphertext.
  final seal = ShareSeal.seal(title, text);
  s.workspace.shares.put(
    ShareLink(
      id: shareIdFor(token),
      kind: kind,
      sourceId: sourceId,
      title: title,
      body: text,
      createdAt: now,
      updatedAt: now,
      expiresAt: lifetime == null ? null : now.add(lifetime),
      sealed: seal.ciphertext,
    ),
  );
  await s.settings.set(_tokensKey, {..._tokens(s), shareIdFor(token): token});
  await s.settings.set(_keysKey, {..._keys(s), shareIdFor(token): seal.key});
  return token;
}

void revokeShare(AppState s, String id) {
  final link = s.workspace.shares[id];
  if (link != null && !link.revoked) s.workspace.shares.put(link.revoke());
}

Future<void> showShareDialog(
  BuildContext context,
  AppState s, {
  required String kind,
  required String sourceId,
  required String title,
  required String body,
}) => showAppDialog<void>(
  context: context,
  builder: (_) => _ShareDialog(
    state: s,
    kind: kind,
    sourceId: sourceId,
    title: title,
    body: body,
  ),
);

class _ShareDialog extends StatefulWidget {
  const _ShareDialog({
    required this.state,
    required this.kind,
    required this.sourceId,
    required this.title,
    required this.body,
  });

  final AppState state;
  final String kind, sourceId, title, body;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  Duration? _lifetime = const Duration(days: 7);
  String? _token;

  AppState get s => widget.state;

  @override
  Widget build(BuildContext context) {
    final url = _token == null ? null : shareUrl(s, _token!);
    return AlertDialog(
      title: Text(
        'Share "${widget.title}"',
        style: const TextStyle(fontSize: AppType.sizeHeading),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A read-only copy of it as it is now, served by your own hub. '
              'Anyone with the link who can reach your hub can read it: '
              'normally that is your home network only, unless you made '
              'your hub reachable from the internet yourself.',
              style: TextStyle(
                fontSize: AppType.sizeLabel,
                color: AppColors.textMuted,
              ),
            ),
            if (s.hubUrl == null)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  'This device is not connected to a hub, so there is '
                  'nothing to serve the link. Connect one in Settings → Sync.',
                  style: TextStyle(
                    fontSize: AppType.sizeLabel,
                    color: AppColors.warm,
                  ),
                ),
              ),
            const SizedBox(height: Space.md),
            if (_token == null)
              DropdownButton<Duration?>(
                key: const ValueKey('share-lifetime'),
                value: _lifetime,
                onChanged: (v) => setState(() => _lifetime = v),
                items: const [
                  DropdownMenuItem(
                    value: Duration(days: 1),
                    child: Text('Expires in 1 day'),
                  ),
                  DropdownMenuItem(
                    value: Duration(days: 7),
                    child: Text('Expires in 7 days'),
                  ),
                  DropdownMenuItem(
                    value: Duration(days: 30),
                    child: Text('Expires in 30 days'),
                  ),
                  DropdownMenuItem(value: null, child: Text('Never expires')),
                ],
              )
            else ...[
              SelectableText(
                url ?? 'Link made; it works once this device is paired.',
                key: const ValueKey('share-url'),
                style: const TextStyle(fontSize: AppType.sizeLabel),
              ),
              const SizedBox(height: Space.xs),
              Text(
                'It works after the next sync. Revoke it any time in '
                'Settings → Sharing → Shared links.',
                style: TextStyle(
                  fontSize: AppType.sizeMeta,
                  color: AppColors.textFaint,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_token == null)
          TextButton(
            key: const ValueKey('share-create'),
            onPressed: s.hubUrl == null
                ? null
                : () async {
                    final t = await createShare(
                      s,
                      kind: widget.kind,
                      sourceId: widget.sourceId,
                      title: widget.title,
                      body: widget.body,
                      lifetime: _lifetime,
                    );
                    if (mounted) setState(() => _token = t);
                  },
            child: const Text('Make link'),
          )
        else if (url != null)
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: url)),
            child: const Text('Copy link'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Every share link, with copy (on the device that made it) and revoke.
Future<void> showSharedLinks(BuildContext context, AppState s) =>
    showAppDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: s.workspace.shares,
        builder: (context, _) {
          final now = DateTime.now();
          final tokens = _tokens(s);
          final list = s.workspace.shares.all.toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return AlertDialog(
            title: const Text(
              'Shared links',
              style: TextStyle(fontSize: AppType.sizeHeading),
            ),
            content: SizedBox(
              width: 480,
              height: 360,
              child: list.isEmpty
                  ? Center(
                      child: Text(
                        'Nothing is shared.',
                        style: TextStyle(color: AppColors.textFaint),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final l in list)
                          ListTile(
                            dense: true,
                            title: Text(l.title),
                            subtitle: Text(
                              l.revoked
                                  ? 'Revoked'
                                  : !l.activeAt(now)
                                  ? 'Expired'
                                  : l.expiresAt == null
                                  ? 'Active, never expires'
                                  : 'Active until ${l.expiresAt!.toLocal()}'
                                        .split('.')
                                        .first,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (tokens[l.id] case final t?
                                    when l.activeAt(now) &&
                                        shareUrl(s, t) != null)
                                  IconButton(
                                    tooltip: 'Copy link',
                                    icon: const Icon(Icons.copy, size: 16),
                                    onPressed: () => Clipboard.setData(
                                      ClipboardData(text: shareUrl(s, t)!),
                                    ),
                                  ),
                                if (!l.revoked)
                                  TextButton(
                                    key: ValueKey('share-revoke-${l.id}'),
                                    onPressed: () => revokeShare(s, l.id),
                                    child: const Text('Revoke'),
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
