// Read-only mirror of the hub (e.g. on a Raspberry Pi later), for disaster
// recovery. Pure Dart, no paid services, local network / Tailscale only.
//
// * The Windows hub stays the only writable authority. The mirror pairs like
//   a device (one-time code) but only ever *reads* from the hub.
// * It stores what it reads in the hub's own journal format (versions in
//   committed batches), so `restoreToCleanHub` produces a folder that
//   `HubStore` loads as a working hub.
// * A mirror folder must be given explicitly and may never be a hub folder,
//   so the mirror can't write into a live hub.
// * If the hub is replaced or restored (new hub id, or behind the mirror),
//   replication stops. `--reseed` keeps the old copy aside, never deletes it.
// * A batch left half-written (crash, power cut, full disk) is cut off before
//   anything new is appended, so damage never ends up mid-journal.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../sync/protocol.dart';
import '../sync/secret_store.dart';
import '../sync/sync_client.dart';
import 'hub_store.dart';

enum MirrorStatus {
  inSync,
  primaryHubChanged,
  networkError,

  /// The mirror's own disk failed (for example full). Nothing half-written
  /// is kept; the run can simply be repeated.
  storageError,
  notPaired,

  /// Another run is still working on this mirror folder; nothing was done.
  busy,
}

/// A lock older than this is treated as left behind by a crashed run.
const mirrorLockStaleAfter = Duration(hours: 2);

/// How long a copy may go without a successful run before it counts as stale.
const mirrorStaleAfter = Duration(hours: 48);

class MirrorState {
  MirrorState({
    required this.primaryUrl,
    required this.deviceId,
    this.hubId,
    this.cursor = 0,
    this.replicatedAt,
    this.lastAttemptAt,
    this.lastError,
    Set<String>? missingAttachments,
  }) : missingAttachments = missingAttachments ?? {};

  final String primaryUrl;
  final String deviceId;
  String? hubId;

  /// Hub change number the journal is complete up to.
  int cursor;

  /// Last successful run.
  DateTime? replicatedAt;

  /// Last run (successful or not) and why it failed, for `mirror-status`.
  DateTime? lastAttemptAt;
  String? lastError;

  /// Attachment hashes not downloaded yet (retried on every run).
  final Set<String> missingAttachments;

  Map<String, dynamic> toJson() => {
    'primaryUrl': primaryUrl,
    'deviceId': deviceId,
    'hubId': hubId,
    'cursor': cursor,
    'replicatedAt': replicatedAt?.toUtc().toIso8601String(),
    'lastAttemptAt': lastAttemptAt?.toUtc().toIso8601String(),
    'lastError': lastError,
    'missingAttachments': missingAttachments.toList()..sort(),
  };

  factory MirrorState.fromJson(Map<String, dynamic> j) => MirrorState(
    primaryUrl: j['primaryUrl'] as String,
    deviceId: j['deviceId'] as String,
    hubId: j['hubId'] as String?,
    cursor: j['cursor'] as int? ?? 0,
    replicatedAt: DateTime.tryParse(j['replicatedAt'] as String? ?? ''),
    lastAttemptAt: DateTime.tryParse(j['lastAttemptAt'] as String? ?? ''),
    lastError: j['lastError'] as String?,
    missingAttachments: {
      ...?(j['missingAttachments'] as List?)?.cast<String>(),
    },
  );

  /// One-line health summary: ok, stale, failing or never run.
  String health({DateTime? now}) {
    final ok = replicatedAt;
    final failedLast =
        lastError != null &&
        (ok == null || (lastAttemptAt?.isAfter(ok) ?? false));
    if (failedLast) return 'failing: $lastError';
    if (ok == null) return 'never run';
    if ((now ?? DateTime.now()).difference(ok) > mirrorStaleAfter) {
      return 'stale: last good copy ${ok.toLocal()}';
    }
    if (missingAttachments.isNotEmpty) {
      return 'ok, but ${missingAttachments.length} attachment(s) missing';
    }
    return 'ok';
  }
}

class MirrorReport {
  MirrorStatus status = MirrorStatus.inSync;
  int changes = 0;
  int attachmentsDownloaded = 0;
  int attachmentsRepaired = 0;
  int attachmentsMissing = 0;
  int bytesTrimmed = 0;
  int cursor = 0;
  String? message;

  @override
  String toString() =>
      '${status.name}: $changes change(s) copied, $attachmentsDownloaded '
      'file(s) downloaded, $attachmentsMissing file(s) still missing, '
      '${attachmentsRepaired == 0 ? '' : '$attachmentsRepaired damaged file(s) set aside, '}'
      '${bytesTrimmed == 0 ? '' : 'unfinished batch removed ($bytesTrimmed bytes), '}'
      'complete up to change #$cursor${message == null ? '' : ' — $message'}';
}

class MirrorVerifyReport {
  const MirrorVerifyReport({
    required this.valid,
    required this.records,
    required this.lastSeq,
    required this.attachments,
    required this.errors,
  });

  final bool valid;
  final int records;
  final int lastSeq;
  final int attachments;
  final List<String> errors;

  @override
  String toString() =>
      '${valid ? 'valid' : 'NOT valid'}: $records record(s) up to change '
      '#$lastSeq, $attachments attachment file(s)'
      '${errors.isEmpty ? '' : '; ${errors.join('; ')}'}';
}

class MirrorEngine {
  MirrorEngine(this.dir);

  final Directory dir;

  static final String _sep = Platform.pathSeparator;
  File get stateFile => File('${dir.path}${_sep}mirror.json');
  File get tokenFile => File('${dir.path}${_sep}mirror.token');
  File get journal => File('${dir.path}${_sep}journal.jsonl');
  File get lockFile => File('${dir.path}${_sep}mirror.lock');

  /// Takes the folder's run lock; false if another run holds a fresh one.
  Future<bool> _lock() async {
    try {
      await lockFile.create(exclusive: true);
    } on FileSystemException {
      final age = DateTime.now().difference(await lockFile.lastModified());
      if (age < mirrorLockStaleAfter) return false;
      // Left behind by a run that crashed: take it over.
      await lockFile.setLastModified(DateTime.now());
    }
    await lockFile.writeAsString(
      jsonEncode({'pid': pid, 'at': DateTime.now().toUtc().toIso8601String()}),
      flush: true,
    );
    return true;
  }

  Future<void> _unlock() async {
    try {
      await lockFile.delete();
    } catch (_) {}
  }

  Directory get attachmentsDir => Directory('${dir.path}${_sep}attachments');

  /// Refuses a folder that holds a hub, so a mirror can never write into it.
  static Future<void> checkNotAHub(Directory dir) async {
    for (final name in ['hub-id', 'devices.json', 'admin.token']) {
      if (await File('${dir.path}$_sep$name').exists()) {
        throw ArgumentError(
          '${dir.path} is a hub folder. Use a separate, empty folder for the mirror.',
        );
      }
    }
  }

  Future<MirrorState?> loadState() async {
    if (!await stateFile.exists()) return null;
    return MirrorState.fromJson(
      jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>,
    );
  }

  Future<void> _saveState(MirrorState s) async {
    final tmp = File('${stateFile.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent(' ').convert(s.toJson()),
      flush: true,
    );
    await tmp.rename(stateFile.path);
  }

  /// Saves a failure for `mirror-status`; ignores a second failure (the disk
  /// may be full).
  Future<void> _recordError(MirrorState s, String message) async {
    s.lastError = message;
    try {
      await _saveState(s);
    } catch (_) {}
  }

  /// Pairs this mirror with the hub using a code from `thehub pair`.
  Future<void> pair(Uri hub, String code, {String name = 'Mirror'}) async {
    await checkNotAHub(dir);
    await dir.create(recursive: true);
    final rand = Random.secure();
    final deviceId =
        'mirror${List.generate(8, (_) => rand.nextInt(36).toRadixString(36)).join()}';
    final client = SyncClient(hub);
    try {
      final token = await client.register(code, deviceId, name);
      await writeSecret(tokenFile, token);
      await _saveState(
        MirrorState(primaryUrl: hub.toString(), deviceId: deviceId),
      );
    } finally {
      client.close();
    }
  }

  /// Copies everything new from the hub. With [reseed], a replaced or
  /// restored hub is accepted: the old copy is moved aside, not deleted.
  /// With [repair], every copied attachment is re-hashed first and damaged
  /// ones are set aside and downloaded again.
  /// Only one run works on a mirror folder at a time (a scheduled run may
  /// overlap a slow or manual one); a second run returns [MirrorStatus.busy].
  Future<MirrorReport> replicateOnce({
    bool reseed = false,
    bool repair = false,
  }) async {
    await checkNotAHub(dir);
    if (!await dir.exists()) return _replicate(reseed: reseed, repair: repair);
    if (!await _lock()) {
      return MirrorReport()
        ..status = MirrorStatus.busy
        ..message = 'Another mirror run is still working on this folder.';
    }
    try {
      return await _replicate(reseed: reseed, repair: repair);
    } finally {
      await _unlock();
    }
  }

  Future<MirrorReport> _replicate({
    required bool reseed,
    required bool repair,
  }) async {
    final report = MirrorReport();
    final state = await loadState();
    final token = await readSecret(tokenFile);
    if (state == null || token == null) {
      report
        ..status = MirrorStatus.notPaired
        ..message = 'Pair this mirror first (mirror-pair).';
      return report;
    }
    state.lastAttemptAt = DateTime.now();
    final client = SyncClient(Uri.parse(state.primaryUrl), token: token);
    try {
      final probe = await client.pull(state.cursor, limit: 1);
      final replaced =
          state.hubId != null &&
          (probe.hubId != state.hubId || probe.lastSeq < state.cursor);
      if (replaced && !reseed) {
        report
          ..status = MirrorStatus.primaryHubChanged
          ..cursor = state.cursor
          ..message =
              'The hub was replaced or restored. Nothing was changed; run '
              'with --reseed to start a fresh copy (the old one is kept).';
        await _recordError(state, 'hub replaced or restored');
        return report;
      }
      if (replaced) await _setAside();
      if (replaced || state.hubId == null) {
        state
          ..hubId = probe.hubId
          ..cursor = 0
          ..missingAttachments.clear();
      }

      await dir.create(recursive: true);
      report.bytesTrimmed = await _trimUnfinishedBatch();
      if (repair) report.attachmentsRepaired = await _setAsideDamaged(state);
      while (true) {
        final page = await client.pull(state.cursor, limit: maxPullLimit);
        if (page.hubId != state.hubId) {
          throw const SyncFailure(
            'hub_changed',
            'The hub changed during replication.',
          );
        }
        if (page.changes.isNotEmpty) {
          await _appendBatch(page.changes);
          for (final c in page.changes) {
            if (c.collection == 'assets' && c.data != null) {
              for (final key in ['fileSha256', 'previewSha256']) {
                final sha = c.data![key];
                if (sha is String && sha256Pattern.hasMatch(sha)) {
                  state.missingAttachments.add(sha);
                }
              }
            }
          }
          report.changes += page.changes.length;
        }
        // The batch is on disk before the cursor moves past it.
        state.cursor = page.next;
        await _saveState(state);
        if (!page.hasMore) break;
      }

      await attachmentsDir.create(recursive: true);
      for (final sha in state.missingAttachments.toList()) {
        final target = File('${attachmentsDir.path}$_sep$sha');
        if (await target.exists()) {
          state.missingAttachments.remove(sha);
          continue;
        }
        try {
          // Written to a temporary file, checked by SHA-256, then renamed:
          // an interrupted download never leaves a wrong file in place.
          await client.download(sha, null, target);
          state.missingAttachments.remove(sha);
          report.attachmentsDownloaded++;
        } on SyncFailure {
          // Kept in the list and retried next run.
        }
      }
      state
        ..replicatedAt = DateTime.now()
        ..lastError = null;
      await _saveState(state);
      report
        ..cursor = state.cursor
        ..attachmentsMissing = state.missingAttachments.length;
      return report;
    } on SyncFailure catch (e) {
      report
        ..status = MirrorStatus.networkError
        ..cursor = state.cursor
        ..message = e.message;
      await _recordError(state, e.message);
      return report;
    } on FileSystemException catch (e) {
      report
        ..status = MirrorStatus.storageError
        ..cursor = state.cursor
        ..message =
            'The mirror folder could not be written '
            '(${e.osError?.message ?? e.message}). Free some space and run again.';
      await _recordError(state, report.message!);
      return report;
    } finally {
      client.close();
    }
  }

  static final _commitPrefix = utf8.encode('{"t":"c"');

  static bool _isCommitLine(List<int> bytes, int start, int end) {
    if (end - start < _commitPrefix.length) return false;
    for (var i = 0; i < _commitPrefix.length; i++) {
      if (bytes[start + i] != _commitPrefix[i]) return false;
    }
    return true;
  }

  /// Cuts off a batch left unfinished by a crash, power cut or full disk, so
  /// new batches never land after damage (which the hub loader refuses). The
  /// removed bytes are kept next to the journal as `journal.jsonl.tail-<ms>`.
  /// Returns how many bytes were removed.
  Future<int> _trimUnfinishedBatch() async {
    if (!await journal.exists()) return 0;
    final length = await journal.length();
    if (length == 0) return 0;
    // Fast path: the journal ends with a complete commit line.
    final raf = await journal.open();
    try {
      final tailStart = max(0, length - 256);
      await raf.setPosition(tailStart);
      final tail = await raf.read(length - tailStart);
      if (tail.last == 0x0A) {
        var start = tail.length - 1;
        while (start > 0 && tail[start - 1] != 0x0A) {
          start--;
        }
        if ((start > 0 || tailStart == 0) &&
            _isCommitLine(tail, start, tail.length - 1)) {
          return 0;
        }
      }
    } finally {
      await raf.close();
    }
    final bytes = await journal.readAsBytes();
    var keep = 0, lineStart = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0x0A) continue;
      if (_isCommitLine(bytes, lineStart, i)) keep = i + 1;
      lineStart = i + 1;
    }
    final removed = bytes.length - keep;
    if (removed == 0) return 0;
    await File('${journal.path}.tail-${DateTime.now().millisecondsSinceEpoch}')
        .writeAsBytes(bytes.sublist(keep), flush: true);
    final f = await journal.open(mode: FileMode.append);
    try {
      await f.truncate(keep);
      await f.flush();
    } finally {
      await f.close();
    }
    return removed;
  }

  /// Re-hashes every copied attachment. A damaged one is moved to
  /// `damaged\` (kept, never deleted) and queued for download again.
  Future<int> _setAsideDamaged(MirrorState state) async {
    if (!await attachmentsDir.exists()) return 0;
    final files = [
      await for (final f in attachmentsDir.list())
        if (f is File && sha256Pattern.hasMatch(f.uri.pathSegments.last)) f,
    ];
    var damaged = 0;
    final aside = Directory('${dir.path}${_sep}damaged');
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      if (await fileSha256(f) == name) continue;
      await aside.create(recursive: true);
      await f.rename(
        '${aside.path}$_sep$name-${DateTime.now().millisecondsSinceEpoch}',
      );
      state.missingAttachments.add(name);
      damaged++;
    }
    return damaged;
  }

  /// Appends versions in the hub's journal format, as one committed batch.
  /// If the write fails (e.g. the disk is full) the file is cut back, so no
  /// half batch is left behind.
  Future<void> _appendBatch(List<SyncChange> changes) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final buffer = StringBuffer();
    for (final c in changes) {
      buffer.writeln(
        jsonEncode({
          't': 'v',
          'seq': c.seq,
          'c': c.collection,
          'id': c.id,
          'rev': c.rev,
          'del': c.deleted,
          if (c.data != null) 'data': c.data,
          'dev': deviceOfRev(c.rev) ?? 'hub',
          'at': now,
        }),
      );
    }
    buffer.writeln(jsonEncode({'t': 'c', 'n': changes.length}));
    final f = await journal.open(mode: FileMode.append);
    final start = await f.length();
    try {
      await f.writeString(buffer.toString());
      await f.flush();
    } catch (_) {
      try {
        await f.truncate(start);
      } catch (_) {
        // Cut off by _trimUnfinishedBatch on the next run instead.
      }
      rethrow;
    } finally {
      await f.close();
    }
  }

  /// Moves the current copy into `previous-<time>\` (kept, never deleted).
  Future<void> _setAside() async {
    final aside = Directory(
      '${dir.path}${_sep}previous-${DateTime.now().millisecondsSinceEpoch}',
    );
    await aside.create(recursive: true);
    if (await journal.exists()) {
      await journal.rename('${aside.path}${_sep}journal.jsonl');
    }
    if (await attachmentsDir.exists()) {
      await attachmentsDir.rename('${aside.path}${_sep}attachments');
    }
  }

  /// Checks the copy by loading it exactly as a hub would (in a temporary
  /// folder) and re-hashing every attachment file.
  Future<MirrorVerifyReport> verify() async {
    final errors = <String>[];
    var records = 0, lastSeq = 0, files = 0;
    final state = await loadState();
    if (!await journal.exists()) {
      errors.add('No journal yet.');
    } else {
      final tmp = await Directory.systemTemp.createTemp('mirror_verify_');
      try {
        await journal.copy('${tmp.path}${_sep}journal.jsonl');
        final hub = await HubStore.open(tmp);
        records = hub.stats.records;
        lastSeq = hub.lastSeq;
        await hub.close();
        if (await File('${tmp.path}${_sep}journal.jsonl').length() !=
            await journal.length()) {
          errors.add('The journal ends with an unfinished batch.');
        }
        if (state != null && lastSeq > state.cursor) {
          errors.add('The journal is ahead of the saved position.');
        }
      } catch (e) {
        errors.add('The journal cannot be loaded as a hub: $e');
      } finally {
        await tmp.delete(recursive: true);
      }
    }
    if (await attachmentsDir.exists()) {
      await for (final f in attachmentsDir.list()) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last;
        if (!sha256Pattern.hasMatch(name)) continue;
        files++;
        if (await fileSha256(f) != name) {
          errors.add('Damaged attachment $name (run mirror-run --repair).');
        }
      }
    }
    if (state != null && state.missingAttachments.isNotEmpty) {
      errors.add(
        '${state.missingAttachments.length} attachment(s) not downloaded yet.',
      );
    }
    return MirrorVerifyReport(
      valid: errors.isEmpty,
      records: records,
      lastSeq: lastSeq,
      attachments: files,
      errors: errors,
    );
  }

  /// Restores the verified copy into [target], which must be new or empty.
  /// The restored hub gets a new random id when it first starts (so devices
  /// re-offer their data) and has no paired devices: pair them again.
  static Future<void> restoreToCleanHub({
    required Directory mirrorDir,
    required Directory target,
  }) async {
    final mirror = MirrorEngine(mirrorDir);
    final check = await mirror.verify();
    if (!check.valid) {
      throw FileSystemException(
        'The mirror is not complete or not valid: ${check.errors.join('; ')}',
        mirrorDir.path,
      );
    }
    if (await target.exists() && !await target.list().isEmpty) {
      throw FileSystemException('Restore target is not empty', target.path);
    }
    await target.create(recursive: true);
    await mirror.journal.copy('${target.path}${_sep}journal.jsonl');
    final dest = Directory('${target.path}${_sep}attachments');
    await dest.create(recursive: true);
    if (await mirror.attachmentsDir.exists()) {
      await for (final f in mirror.attachmentsDir.list()) {
        if (f is File && sha256Pattern.hasMatch(f.uri.pathSegments.last)) {
          await f.copy('${dest.path}$_sep${f.uri.pathSegments.last}');
        }
      }
    }
  }
}
