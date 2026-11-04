// Creates, checks and uses the recovery envelope of a workspace (see
// sync/recovery_code.dart for what it is and what it guarantees).
//
// The envelope lives in `<workspace>/recovery/recovery.json`. That folder is
// part of ordinary backups, so a backup together with the code is enough to
// get back into the data on a new device. The code itself is returned once
// by [create] and never written anywhere by this class.
import 'dart:convert';
import 'dart:io';

import '../../sync/e2ee.dart' show SyncCrypto;
import '../../sync/recovery_code.dart';
import '../../sync/sync_key_store.dart';
import 'app_log.dart';
import 'storage_encryption.dart';

enum RecoveryState {
  /// No envelope: the workspace has no recovery code yet.
  none,

  /// An envelope exists and covers the current keys.
  current,

  /// An envelope exists but the sync key has changed since (a device was
  /// removed): a new code should be made so it covers the newest key.
  outOfDate,
}

class RecoveryStatus {
  const RecoveryStatus(this.state, {this.created});
  final RecoveryState state;
  final DateTime? created;
}

class RecoveryRestoreResult {
  const RecoveryRestoreResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}

class RecoveryService {
  RecoveryService(this.root, {WorkspaceKeyStore? keys, SyncKeyStore? syncKeys})
    : keys = keys ?? OsWorkspaceKeyStore(root),
      syncKeys = syncKeys ?? SyncKeyStore(root);

  final Directory root;
  final WorkspaceKeyStore keys;
  final SyncKeyStore syncKeys;

  static const folder = 'recovery';
  static const fileName = 'recovery.json';

  File get file => File(
    '${root.path}${Platform.pathSeparator}$folder'
    '${Platform.pathSeparator}$fileName',
  );

  Future<Map<String, dynamic>?> _readEnvelope([File? from]) async {
    final f = from ?? file;
    if (!await f.exists()) return null;
    try {
      final json = jsonDecode(await f.readAsString());
      return json is Map<String, dynamic> ? json : null;
    } on FormatException {
      return null;
    }
  }

  Future<RecoveryStatus> status() async {
    final env = await _readEnvelope();
    if (env == null) return const RecoveryStatus(RecoveryState.none);
    final created = DateTime.tryParse(env['created'] as String? ?? '');
    final epoch = env['syncEpoch'] as int?;
    final now = await syncKeys.load();
    final outOfDate = now != null && (epoch == null || now.current > epoch);
    return RecoveryStatus(
      outOfDate ? RecoveryState.outOfDate : RecoveryState.current,
      created: created,
    );
  }

  /// Makes a new recovery code, replacing any earlier envelope (the earlier
  /// code stops working). The returned code is shown to the person once;
  /// this class does not keep it. Throws if this device has no key to
  /// protect (a platform without protected key storage).
  Future<RecoveryCode> create({DateTime? now}) async {
    final atRest = await keys.read();
    if (atRest == null) {
      throw StateError('There is no workspace key on this device to protect.');
    }
    final sync = await syncKeys.load();
    final code = RecoveryCode.generate();
    final envelope = RecoveryEnvelope.seal(
      RecoveryMaterial(
        atRestKey: atRest,
        syncKeys: sync?.exportKeys() ?? const {},
        syncCurrent: sync?.current,
      ),
      code,
      now: now,
    );
    // The new envelope must open with the new code before it replaces the
    // old one.
    RecoveryEnvelope.open(envelope, code);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(envelope), flush: true);
    await tmp.rename(file.path);
    AppLog.info('Recovery code created (the code itself is never logged)');
    return code;
  }

  /// Gets the keys back with [codeText], from this workspace's envelope or
  /// from [envelope] (e.g. the `recovery/recovery.json` of a backup). The
  /// keys are only installed if they open this folder's encrypted data (or
  /// if it has none yet); otherwise nothing on this device is changed.
  Future<RecoveryRestoreResult> restore(
    String codeText, {
    File? envelope,
  }) async {
    final code = RecoveryCode.parse(codeText);
    if (code == null) {
      return const RecoveryRestoreResult(
        ok: false,
        message:
            'That is not a valid recovery code. Check it for typing mistakes.',
      );
    }
    final env = await _readEnvelope(envelope);
    if (env == null) {
      return const RecoveryRestoreResult(
        ok: false,
        message: 'No recovery envelope was found with this data.',
      );
    }
    final RecoveryMaterial material;
    try {
      material = RecoveryEnvelope.open(env, code);
    } on RecoveryFailure catch (e) {
      return RecoveryRestoreResult(ok: false, message: e.message);
    }
    final cipher = FileCipher(material.atRestKey);
    if (!await StorageEncryption.keyOpens(root, cipher)) {
      return const RecoveryRestoreResult(
        ok: false,
        message:
            'The code is right, but its keys do not open the data in this '
            'folder. Nothing was changed.',
      );
    }
    await keys.write(material.atRestKey);
    if (material.syncKeys.isNotEmpty && material.syncCurrent != null) {
      await syncKeys.saveCrypto(
        SyncCrypto.epochs(material.syncKeys, current: material.syncCurrent!),
      );
    }
    AppLog.info('Workspace keys restored with the recovery code');
    return const RecoveryRestoreResult(
      ok: true,
      message: 'Access restored. Close and reopen misc. to continue.',
    );
  }
}
