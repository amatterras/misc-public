// Where the workspace is stored and shared: one provider abstraction for the
// three storage modes (see STORAGE_MODES.md).
//
//   local   – this device only. Nothing is uploaded anywhere.
//   pcHub   – this device + the Windows PC hub (127.0.0.1 or Tailscale).
//   hosted  – this device + a hosted hub service (HTTPS), no PC needed.
//
// In every mode the device's own data folder is the durable working copy:
// edits are saved here first and synced afterwards, so a remote is never
// the only copy. The PC hub and the hosted service run the same hub code
// (HubStore rules, tombstones, conflict copies, attachments by SHA-256), so
// there is one set of business rules, not three.
//
// Changing the provider is a deliberate copy-and-verify workflow
// ([StorageSwitch]); it never silently changes where data goes and never
// deletes the previous remote copy.
import 'dart:io';

import '../data/repositories/canvas_repository.dart';
import '../data/storage/app_log.dart';
import '../data/storage/backup_verifier.dart';
import '../data/workspace.dart';
import 'protocol.dart';
import 'e2ee.dart';
import 'sync_client.dart';
import 'sync_engine.dart';

enum StorageMode {
  local(
    'This device only',
    'Everything is saved on this device. Nothing is uploaded. Other devices '
        'do not see these changes; use backups to move data.',
  ),
  pcHub(
    'This device + PC hub',
    'Saved here and synced with the misc. hub on your Windows PC (on this '
        'PC or over Tailscale). Syncs while the PC is on and reachable.',
  ),
  hosted(
    'This device + hosted service',
    'Saved here and synced with a hosted misc. service you set up. Works '
        'without the PC. Your data is stored on that server.',
  );

  const StorageMode(this.label, this.explanation);
  final String label;
  final String explanation;
}

/// A place the workspace can be shared through. Local device storage is
/// not a remote: [LocalOnlyProvider] has no endpoint and never connects.
sealed class StorageProvider {
  const StorageProvider();

  StorageMode get mode;

  /// The remote address, or null for local only.
  Uri? get endpoint;

  /// Why this provider cannot be used as configured, or null.
  String? get problem;

  /// What the status line may show about the address (host only: never a
  /// path, query or credentials).
  String get displayAddress =>
      endpoint == null ? 'this device' : '${endpoint!.host}:${endpoint!.port}';

  /// The provider described by a stored sync config (`sync/hub.json`).
  static StorageProvider fromConfig(Map<String, dynamic>? config) {
    final url = config?['url'] as String?;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) return const LocalOnlyProvider();
    return config?['hosted'] == true ? HostedProvider(uri) : PcHubProvider(uri);
  }
}

class LocalOnlyProvider extends StorageProvider {
  const LocalOnlyProvider();
  @override
  StorageMode get mode => StorageMode.local;
  @override
  Uri? get endpoint => null;
  @override
  String? get problem => null;
}

class PcHubProvider extends StorageProvider {
  const PcHubProvider(this.endpoint);
  @override
  final Uri endpoint;
  @override
  StorageMode get mode => StorageMode.pcHub;
  @override
  String? get problem => isAllowedHubUrl(endpoint) && !isHostedHubUrl(endpoint)
      ? null
      : 'The PC hub address must be this PC (http://127.0.0.1:47710), a '
            'Tailscale address (100.x.y.z or *.ts.net) or your home network.';
}

class HostedProvider extends StorageProvider {
  const HostedProvider(this.endpoint);
  @override
  final Uri endpoint;
  @override
  StorageMode get mode => StorageMode.hosted;

  /// Tests run a real hosted hub on 127.0.0.1 without TLS; the app itself
  /// only ever accepts https:// to a named server.
  static bool allowLoopbackForTests = false;

  @override
  String? get problem {
    if (isHostedHubUrl(endpoint)) return null;
    if (allowLoopbackForTests && isLoopbackHubUrl(endpoint)) return null;
    return 'A hosted service address must start with https:// and use a '
        'server name.';
  }
}

/// How to join a provider: a pairing code (PC hub) or an account (hosted).
class ProviderCredentials {
  const ProviderCredentials.pairing(String this.pairingCode)
    : email = null,
      password = null,
      invite = null;
  const ProviderCredentials.account(
    String this.email,
    String this.password, {
    this.invite,
    this.pairingCode,
  });

  final String? pairingCode;
  final String? email;
  final String? password;
  final String? invite;
}

/// What a switch would do, shown before anything is copied.
class SwitchPlan {
  const SwitchPlan({
    required this.from,
    required this.to,
    required this.localRecords,
    required this.destinationChanges,
  });

  final StorageProvider from;
  final StorageProvider to;

  /// Records (and canvas items) on this device.
  final int localRecords;

  /// Changes the destination already holds (0 = empty). When not empty,
  /// both sides are merged; neither replaces the other.
  final int destinationChanges;

  bool get destinationHasData => destinationChanges > 0;
}

/// The result of copying to the destination and reading it back.
class SwitchVerification {
  const SwitchVerification({
    required this.problems,
    required this.checked,
    required this.attachmentsChecked,
    required this.conflicts,
  });

  /// Empty when every record and attachment arrived intact.
  final List<String> problems;

  /// Record versions compared with the destination.
  final int checked;
  final int attachmentsChecked;

  /// Records both sides had in different versions (kept as conflict copies).
  final int conflicts;

  bool get ok => problems.isEmpty;
}

enum SwitchStage { idle, connected, copied, verified, failed, cancelled }

/// The deliberate copy-and-verify workflow for changing [StorageMode]:
///
/// 1. [plan]: the destination answers, and how much data it already holds.
/// 2. [connect]: pairing / sign-in; the device key is kept in memory only.
/// 3. [copyAndVerify]: a verified backup of this device is restored into a
///    temporary folder and synced to the destination from there, so the
///    live data is not changed by the copy. Then every record version and
///    attachment checksum is read back from the destination and compared.
/// 4. The caller asks the user, and only then activates the new provider
///    with [token] (AppState.activateProvider).
/// [cancel] at any point leaves this device's data and the active provider
/// as they were; data already copied to the destination stays there
/// (nothing remote is ever deleted by THEapp).
class StorageSwitch {
  StorageSwitch({
    required this.workspace,
    required this.from,
    required this.to,
    required this.deviceName,
    this.crypto,
  });

  final Workspace workspace;
  final StorageProvider from;
  final StorageProvider to;
  final String deviceName;

  /// This device's workspace key (end-to-end encryption). Replaced by the
  /// key a pairing code delivers, when one is entered.
  SyncCrypto? crypto;

  /// SHA-256 of the hub's own HTTPS certificate when it was pinned at
  /// pairing (home-network hub with its own certificate).
  String? pinnedCert;

  /// True when [crypto] came from a pairing code (the app then stores it).
  bool keyFromPairing = false;

  SwitchStage stage = SwitchStage.idle;
  String? _token;
  Directory? _temp;

  /// The destination's device key once connected (never written to disk by
  /// this class).
  String? get token => _token;

  /// The backup made before copying (kept).
  Directory? backup;

  SyncClient _client({String? token}) {
    final problem = to.problem;
    if (problem != null) throw SyncFailure('bad_address', problem);
    return SyncClient(
      to.endpoint!,
      token: token,
      crypto: crypto,
      pinnedCertSha256: pinnedCert,
    );
  }

  Future<int> _localRecordCount() async {
    var n = 0;
    for (final c in workspace.syncCollections.values) {
      n += c.length;
    }
    final canvases = FileCanvasRepository(workspace.store);
    for (final s in await canvases.listCanvases()) {
      n += 1 + ((await canvases.load(s.id))?.items.length ?? 0);
    }
    return n;
  }

  /// Checks that the destination answers as a THEapp hub of this protocol.
  /// For a local-only destination there is nothing to check.
  Future<SwitchPlan> plan() async {
    final local = await _localRecordCount();
    if (to is LocalOnlyProvider) {
      return SwitchPlan(
        from: from,
        to: to,
        localRecords: local,
        destinationChanges: 0,
      );
    }
    final client = _client();
    try {
      final status = await client.status();
      if (status['protocol'] != syncProtocolVersion) {
        throw const SyncFailure(
          'protocol_mismatch',
          'The destination runs a different misc. sync version. Update '
              'misc. or the hub first.',
        );
      }
    } finally {
      client.close();
    }
    return SwitchPlan(
      from: from,
      to: to,
      localRecords: local,
      destinationChanges: -1, // known after connect
    );
  }

  /// Pairs / signs in. Returns how many changes the destination already
  /// holds for this account (0 = empty).
  Future<int> connect(ProviderCredentials credentials) async {
    final device = workspace.device!;
    // An end-to-end pairing code (26 characters) brings the workspace key;
    // the hub gets only a one-way function of it. An ordinary short code
    // pairs this device with the key it already has.
    final secret = PairingSecret.parse(credentials.pairingCode ?? '');
    final endpoint = to.endpoint;
    if (secret?.certPrefix != null && endpoint != null) {
      // The code carries the hub certificate's fingerprint: pin it, or stop.
      pinnedCert = await fetchPinnedCertificate(endpoint, secret!.certPrefix!);
      if (pinnedCert == null) {
        throw const SyncFailure(
          'certificate_rejected',
          'The hub\'s certificate does not match the pairing code, so '
              'nothing was sent.',
        );
      }
    }
    final client = _client();
    try {
      if (to is PcHubProvider) {
        final code = credentials.pairingCode?.trim() ?? '';
        if (code.isEmpty) {
          throw const SyncFailure('bad_request', 'Enter the pairing code.');
        }
        if (secret != null) {
          final r = await client.registerWithKey(
            secret.registerCode,
            device.id,
            deviceName,
          );
          _token = r.token;
          final keys = r.wrappedKey == null
              ? null
              : secret.unwrapCrypto(r.wrappedKey!);
          if (keys == null) {
            throw const SyncFailure(
              'pairing_key',
              'The hub did not deliver a workspace key that matches your '
                  'code. Nothing was changed; make a new code and try again.',
            );
          }
          crypto = keys;
          keyFromPairing = true;
          client.token = _token;
        } else {
          _token = await client.register(code, device.id, deviceName);
        }
      } else if (to is HostedProvider) {
        final email = credentials.email?.trim() ?? '';
        final password = credentials.password ?? '';
        final invite = credentials.invite?.trim() ?? '';
        if (invite.isNotEmpty) {
          await client.createAccount(email, password, invite);
        }
        _token = await client.signIn(email, password, device.id, deviceName);
        // A second device: the key arrives wrapped under a pairing code made
        // on a device that already has it (the service never sees either).
        if (secret != null) {
          final wrapped = await client.redeemPairing(secret.registerCode);
          final keys = secret.unwrapCrypto(wrapped);
          if (keys == null) {
            throw const SyncFailure(
              'pairing_key',
              'The service did not deliver a workspace key that matches your '
                  'code. Nothing was changed.',
            );
          }
          crypto = keys;
          keyFromPairing = true;
        }
      } else {
        throw const SyncFailure('bad_request', 'Nothing to connect to.');
      }
      final probe = await client.pull(0, limit: 1);
      stage = SwitchStage.connected;
      return probe.lastSeq;
    } finally {
      client.close();
    }
  }

  /// Copies this device's data to the destination from a verified backup
  /// (see the class comment), then reads everything back and compares.
  Future<SwitchVerification> copyAndVerify() async {
    final token = _token;
    if (token == null || stage == SwitchStage.cancelled) {
      throw StateError('Connect first');
    }
    // Checksums are filled in here, on the live data, so the copy has no
    // edits of its own to make.
    await fillAttachmentHashes(workspace);
    await workspace.flush();
    final snapshot = backup = await workspace.backups.snapshot(
      'before-switch',
      includeAttachments: true,
    );
    final check = await verifyRestorable(workspace.backups, snapshot);
    if (!check.ok) {
      stage = SwitchStage.failed;
      return SwitchVerification(
        problems: ['The backup before copying failed: ${check.problems.first}'],
        checked: 0,
        attachmentsChecked: 0,
        conflicts: 0,
      );
    }
    final temp = _temp = await Directory.systemTemp.createTemp(
      'theapp-switch-',
    );
    final sep = Platform.pathSeparator;
    Workspace? copy;
    final client = _client(token: token);
    try {
      await workspace.backups.restoreTo(snapshot, temp);
      // The copy has no bookkeeping for the destination: it offers
      // everything, and the hub judges each version by its usual rules.
      for (final name in ['client_state.json', 'client_state.json.bak']) {
        final f = File('${temp.path}${sep}sync$sep$name');
        if (await f.exists()) await f.delete();
      }
      // The same device id and the SAME clock as the live data: a revision
      // the copy makes (e.g. while merging what the destination holds) can
      // never equal one the live data makes.
      copy = Workspace(temp, clock: workspace.clock);
      await copy.load();
      final canvases = FileCanvasRepository(copy.store);
      final engine = SyncEngine(
        workspace: copy,
        canvases: canvases,
        client: client,
      );
      final report = await engine.syncOnce();
      stage = SwitchStage.copied;

      // Read everything back from the destination.
      final remote = <String, SyncChange>{};
      var since = 0;
      while (true) {
        final page = await client.pull(since, limit: 500);
        for (final c in page.changes) {
          remote[c.key] = c; // later changes replace earlier ones
        }
        since = page.next;
        if (!page.hasMore) break;
      }
      final problems = <String>[];
      // Anything without a revision stamp cannot sync: it is not in the
      // list compared below, so it is checked on its own.
      for (final s in await canvases.listCanvases()) {
        final doc = await canvases.load(s.id);
        if (doc == null) continue;
        if (doc.metaRev == null ||
            doc.items.any((i) => !doc.itemRevs.containsKey(i.id))) {
          problems.add('Canvas ${doc.id} has items that cannot sync yet');
        }
      }
      final local = await engine.localVersions();
      for (final c in local.values) {
        final r = remote[c.key];
        if (r == null) {
          problems.add('Not on the destination: ${c.key}');
        } else if (r.rev != c.rev || r.deleted != c.deleted) {
          problems.add('Different version on the destination: ${c.key}');
        }
      }
      var attachments = 0;
      for (final a in copy.assets.all) {
        for (final (name, sha, blobKey) in [
          (a.file, a.fileSha256, 'fileBlob'),
          (a.previewFile, a.previewSha256, 'previewBlob'),
        ]) {
          if (name == null || sha == null) continue;
          if (!await copy.attachments.fileFor(name).exists()) continue;
          attachments++;
          // End-to-end: the destination holds the sealed copy, named in the
          // (sealed) asset record it also holds.
          final id = crypto == null
              ? sha
              : remote['assets/${a.id}']?.data?[blobKey] as String?;
          if (id == null || !await client.hasAttachment(id)) {
            problems.add('Attachment not on the destination: asset ${a.id}');
          }
        }
      }
      stage = problems.isEmpty ? SwitchStage.verified : SwitchStage.failed;
      AppLog.info(
        'Storage switch to ${to.mode.name}: ${local.length} version(s) and '
        '$attachments attachment(s) checked, ${problems.length} problem(s)',
      );
      return SwitchVerification(
        problems: problems,
        checked: local.length,
        attachmentsChecked: attachments,
        conflicts: report.conflicts,
      );
    } on SyncFailure {
      stage = SwitchStage.failed;
      rethrow;
    } finally {
      client.close();
      copy?.dispose();
      await _removeTemp();
    }
  }

  /// Gives up: nothing on this device changes; the destination keeps what
  /// was copied (THEapp never deletes remote data).
  Future<void> cancel() async {
    stage = SwitchStage.cancelled;
    _token = null;
    await _removeTemp();
  }

  Future<void> _removeTemp() async {
    final t = _temp;
    _temp = null;
    if (t == null) return;
    try {
      await t.delete(recursive: true);
    } catch (_) {
      // In the system temp folder; harmless if left behind.
    }
  }
}
