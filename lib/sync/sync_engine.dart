// Device-side sync: pushes local changes to the hub and pulls everyone
// else's. Used by the Windows app now and the iPhone/iPad app later.
//
// What is pending is derived from the data itself: a record is pending when
// its local revision differs from the last revision this device knows the
// hub has ("base"). So offline edits are never lost or forgotten, and a
// retry after any interruption just resends — the hub recognises repeats.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/models/canvas_models.dart';
import '../data/models/library_models.dart';
import '../data/repositories/canvas_repository.dart';
import '../data/storage/app_log.dart';
import '../data/workspace.dart';
import 'canvas_merge.dart';
import 'protocol.dart';
import 'sync_client.dart';

/// Lets the engine reach the canvas documents open on screen (the canvas
/// and an open note's handwriting), so remote changes merge into them
/// instead of being overwritten by their next save.
abstract class OpenCanvasBridge {
  /// Whether the document [canvasId] is open in an editor.
  bool isOpen(String canvasId);

  /// Saves the open documents so their edits are visible in their files.
  Future<void> flushOpenCanvas();

  /// Applies changes to the open document [canvasId]; returns the keys.
  Set<String> applyToOpenCanvas(
    String canvasId,
    List<SyncChange> changes,
    bool Function(String key, String? localRev) isPending,
  );
}

class SyncReport {
  int pushed = 0;
  int pulled = 0;
  int conflicts = 0;
  int uploaded = 0;
  int downloaded = 0;
  int skipped = 0;
  final List<String> problems = [];

  @override
  String toString() =>
      'pushed $pushed, pulled $pulled, conflicts $conflicts, files up $uploaded/down $downloaded'
      '${problems.isEmpty ? '' : ', ${problems.length} problem(s)'}';
}

/// Remembered per device: which hub, how far we have read, and the hub
/// revision of every record we have in sync.
class SyncState {
  SyncState({this.hubId, this.cursor = 0, Map<String, String>? base})
    : base = base ?? {};

  String? hubId;
  int cursor;
  final Map<String, String> base;

  Map<String, dynamic> toJson() => {
    'hubId': hubId,
    'cursor': cursor,
    'base': base,
  };

  factory SyncState.fromJson(Map<String, dynamic>? j) => j == null
      ? SyncState()
      : SyncState(
          hubId: j['hubId'] as String?,
          cursor: j['cursor'] as int? ?? 0,
          base: {...?(j['base'] as Map?)?.cast<String, String>()},
        );
}

final _safeFileName = RegExp(r'^[A-Za-z0-9_-]{1,80}(\.[A-Za-z0-9]{1,8})?$');

class SyncEngine {
  SyncEngine({
    required this.workspace,
    required this.canvases,
    required this.client,
    this.openCanvas,
  });

  final Workspace workspace;
  final CanvasRepository canvases;
  final SyncClient client;
  final OpenCanvasBridge? openCanvas;
  bool _running = false;
  Completer<void>? _idle;

  /// Completes when no sync is running (used before opening a canvas, so
  /// a sync never writes a canvas file that is being opened).
  Future<void> whenIdle() => _idle?.future ?? Future.value();

  Future<SyncState> loadState() async =>
      SyncState.fromJson(await workspace.store.read('sync', 'client_state'));

  Future<void> _saveState(SyncState s) =>
      workspace.store.write('sync', 'client_state', s.toJson());

  /// One full cycle. Throws [SyncFailure] if the hub can't be reached; the
  /// local data is never changed by a failed cycle except for records
  /// already applied (and saved) before the failure.
  Future<SyncReport> syncOnce() async {
    if (_running) {
      throw const SyncFailure(
        'busy',
        'A sync is already running.',
        retryable: true,
      );
    }
    _running = true;
    _idle = Completer<void>();
    final report = SyncReport();
    try {
      await openCanvas?.flushOpenCanvas();
      await workspace.flush();
      final state = await loadState();
      await _fillAttachmentHashes();
      await _push(state, report);
      await _pull(state, report);
      await _downloadMissingAttachments(report);
      AppLog.info('Sync: $report');
      return report;
    } finally {
      _running = false;
      _idle?.complete();
      _idle = null;
    }
  }

  void _checkHub(SyncState state, String hubId, int lastSeq) {
    if (state.hubId != hubId || lastSeq < state.cursor) {
      // A different hub, or one restored from an older backup: start over.
      // Everything is offered again; the hub recognises what it already has.
      if (state.hubId != null) {
        AppLog.warn('Sync: hub changed or was restored; resynchronising.');
      }
      state
        ..hubId = hubId
        ..cursor = 0
        ..base.clear();
    }
  }

  // ------------------------------------------------------ local versions --

  /// Every local record version (rev + data) that syncs, by key.
  Future<Map<String, SyncChange>> _localVersions() async {
    final out = <String, SyncChange>{};
    for (final MapEntry(key: name, value: collection)
        in workspace.syncCollections.entries) {
      for (final v in collection.versions()) {
        final record = v.deleted ? null : collection[v.id];
        if (!v.deleted && record == null) continue;
        out['$name/${v.id}'] = SyncChange(
          collection: name,
          id: v.id,
          rev: v.rev,
          deleted: v.deleted,
          // Includes fields this version does not know (from a newer one).
          data: v.deleted ? null : collection.jsonOf(v.id),
        );
      }
    }
    for (final summary in await canvases.listCanvases()) {
      final doc = await canvases.load(summary.id);
      if (doc == null) continue;
      if (doc.metaRev != null) {
        out['canvases/${doc.id}'] = SyncChange(
          collection: 'canvases',
          id: doc.id,
          rev: doc.metaRev!,
          deleted: false,
          data: canvasMetaData(
            doc.title,
            doc.folderId,
            doc.items,
            doc.metaUnknownFields,
            doc.kind,
            doc.pageBackgrounds,
          ),
        );
      }
      for (final item in doc.items) {
        final rev = doc.itemRevs[item.id];
        if (rev == null) continue;
        out['canvas_items/${doc.id}/${item.id}'] = SyncChange(
          collection: 'canvas_items',
          id: '${doc.id}/${item.id}',
          rev: rev,
          deleted: false,
          data: doc.itemJson(item),
        );
      }
      for (final t in doc.tombstones.entries) {
        out['canvas_items/${doc.id}/${t.key}'] = SyncChange(
          collection: 'canvas_items',
          id: '${doc.id}/${t.key}',
          rev: t.value,
          deleted: true,
        );
      }
    }
    for (final t in workspace.canvasTombstones.entries) {
      out['canvases/${t.key}'] = SyncChange(
        collection: 'canvases',
        id: t.key,
        rev: t.value,
        deleted: true,
      );
    }
    return out;
  }

  // ---------------------------------------------------------------- push --

  Future<void> _push(SyncState state, SyncReport report) async {
    // First learn which hub this is (and whether it was restored from an
    // older backup), so "pending" is judged against the right hub.
    final probe = await client.pull(state.cursor, limit: 1);
    _checkHub(state, probe.hubId, probe.lastSeq);
    final local = await _localVersions();
    final pending = <SyncChange>[];
    for (final c in local.values) {
      if (state.base[c.key] == c.rev) continue;
      if (c.data != null &&
          utf8.encode(jsonEncode(c.data)).length > maxRecordBytes) {
        // Too large for the hub: keep it here, report it, and let every
        // other change sync instead of blocking all of them.
        report.problems.add('A ${c.collection} record is too large to sync.');
        continue;
      }
      pending.add(c);
    }
    if (!_attachmentsReconciled) {
      await _reconcileAttachments(report);
      _attachmentsReconciled = true;
    }
    for (var i = 0; i < pending.length; i += maxPushBatch) {
      final batch = [
        for (final c in pending.skip(i).take(maxPushBatch))
          SyncChange(
            collection: c.collection,
            id: c.id,
            rev: c.rev,
            deleted: c.deleted,
            data: c.data,
            baseRev: state.base[c.key],
          ),
      ];
      for (final c in batch) {
        if (c.collection == 'assets' && !c.deleted) {
          await _uploadFiles(c, report);
        }
      }
      final response = await client.push(batch);
      _checkHub(state, response.hubId, response.lastSeq);
      final sentRev = {for (final c in batch) c.key: c.rev};
      final adopt = <SyncChange>[];
      for (final r in response.results) {
        final key = '${r.collection}/${r.id}';
        switch (r.status) {
          case PushStatus.applied || PushStatus.duplicate:
            state.base[key] = r.rev;
            report.pushed++;
          case PushStatus.keptServer:
            // The hub kept another version (ours is preserved as a conflict
            // when it was a real edit): take the hub's version.
            if (r.current != null) adopt.add(r.current!);
        }
        if (r.conflictId != null) report.conflicts++;
      }
      if (adopt.isNotEmpty) {
        // Take the hub's version only if the record still has exactly the
        // revision we sent: an edit made while the request was in flight
        // stays (it is pending and will be resolved by the next push).
        await _apply(adopt, state, report, sentRev: sentRev);
      }
      await _commitLocal(state);
    }
  }

  bool _attachmentsReconciled = false;

  /// Once per session: makes sure the hub has every photo this device has
  /// (e.g. after the hub lost its attachments folder), uploading any that
  /// are missing. Uploads are checked by size and checksum on the hub.
  Future<void> _reconcileAttachments(SyncReport report) async {
    for (final a in workspace.assets.all.toList()) {
      final data = workspace.assets.jsonOf(a.id) ?? a.toJson();
      await _uploadFiles(
        SyncChange(
          collection: 'assets',
          id: a.id,
          rev: workspace.assets.revOf(a.id) ?? '',
          deleted: false,
          data: data,
        ),
        report,
      );
    }
  }

  Future<void> _uploadFiles(SyncChange asset, SyncReport report) async {
    final data = asset.data!;
    for (final (name, sha) in [
      (data['file'] as String?, data['fileSha256'] as String?),
      (data['previewFile'] as String?, data['previewSha256'] as String?),
    ]) {
      if (name == null || sha == null || !_safeFileName.hasMatch(name)) {
        continue;
      }
      final file = workspace.attachments.fileFor(name);
      if (!await file.exists()) continue;
      if (await client.hasAttachment(sha)) continue;
      await client.upload(sha, file);
      report.uploaded++;
    }
  }

  /// Records file checksums on assets (a local edit, so it syncs).
  Future<void> _fillAttachmentHashes() async {
    for (final a in workspace.assets.all.toList()) {
      String? fileSha = a.fileSha256, previewSha = a.previewSha256;
      int? fileSize = a.fileSize, previewSize = a.previewSize;
      if (a.file != null && fileSha == null) {
        final f = workspace.attachments.fileFor(a.file!);
        if (await f.exists()) {
          fileSha = await fileSha256(f);
          fileSize = await f.length();
        }
      }
      if (a.previewFile != null && previewSha == null) {
        final f = workspace.attachments.fileFor(a.previewFile!);
        if (await f.exists()) {
          previewSha = await fileSha256(f);
          previewSize = await f.length();
        }
      }
      if (fileSha != a.fileSha256 || previewSha != a.previewSha256) {
        workspace.assets.put(
          a.copyWith(
            fileSha256: fileSha,
            fileSize: fileSize,
            previewSha256: previewSha,
            previewSize: previewSize,
          ),
        );
      }
    }
    await workspace.flush();
  }

  // ---------------------------------------------------------------- pull --

  Future<void> _pull(SyncState state, SyncReport report) async {
    while (true) {
      final page = await client.pull(state.cursor);
      _checkHub(state, page.hubId, page.lastSeq);
      if (page.changes.isEmpty) {
        state.cursor = page.next > state.cursor ? page.next : state.cursor;
        await _commitLocal(state);
        return;
      }
      await _apply(page.changes, state, report);
      state.cursor = page.next;
      await _commitLocal(state); // data first, then the cursor
      if (!page.hasMore) return;
    }
  }

  /// Saves applied data, then the sync state, so the cursor never runs
  /// ahead of what is actually on disk.
  Future<void> _commitLocal(SyncState state) async {
    await openCanvas?.flushOpenCanvas();
    await workspace.flush();
    await _saveState(state);
  }

  /// Applies remote versions. Records with an unsent local change are
  /// skipped. With [sentRev] (the hub resolved our push in its favour), a
  /// record is replaced only if it still has exactly the revision we sent.
  Future<void> _apply(
    List<SyncChange> changes,
    SyncState state,
    SyncReport report, {
    Map<String, String>? sentRev,
  }) async {
    bool isPending(String key, String? localRev) => sentRev != null
        ? localRev != null && localRev != sentRev[key]
        : localRev != null && localRev != state.base[key];

    final byCanvas = <String, List<SyncChange>>{};
    for (final c in changes) {
      final collection = workspace.syncCollections[c.collection];
      if (collection != null) {
        final localRev = collection.revOf(c.id) ?? collection.tombstones[c.id];
        if (localRev == c.rev) {
          state.base[c.key] = c.rev;
          continue;
        }
        if (isPending(c.key, localRev)) {
          report.skipped++;
          continue;
        }
        try {
          collection.applyRemote(c.id, c.rev, c.deleted ? null : c.data);
          state.base[c.key] = c.rev;
          report.pulled++;
        } catch (e) {
          // Not readable by this version: leave it on the hub, note it.
          report.problems.add('A ${c.collection} record could not be read.');
        }
      } else if (c.collection == 'canvases' || c.collection == 'canvas_items') {
        final canvasId = c.collection == 'canvases'
            ? c.id
            : c.id.substring(0, c.id.indexOf('/'));
        byCanvas.putIfAbsent(canvasId, () => []).add(c);
      }
    }
    for (final MapEntry(key: canvasId, value: list) in byCanvas.entries) {
      await _applyCanvas(canvasId, list, state, report, isPending);
    }
  }

  Future<void> _applyCanvas(
    String canvasId,
    List<SyncChange> changes,
    SyncState state,
    SyncReport report,
    bool Function(String key, String? localRev) isPending,
  ) async {
    final meta = changes.where((c) => c.collection == 'canvases').lastOrNull;
    if (meta != null && meta.deleted) {
      final localMeta = (await canvases.load(canvasId))?.metaRev;
      if (localMeta != null && isPending(meta.key, localMeta)) {
        report.skipped++;
        return;
      }
      if (openCanvas?.isOpen(canvasId) != true) {
        await canvases.delete(canvasId); // moved to trash, not erased
      }
      await workspace.recordCanvasDeletion(canvasId, rev: meta.rev);
      state.base[meta.key] = meta.rev;
      report.pulled++;
      return;
    }
    Set<String> applied;
    if (openCanvas?.isOpen(canvasId) == true) {
      applied = openCanvas!.applyToOpenCanvas(canvasId, changes, isPending);
    } else {
      final doc = await canvases.load(canvasId);
      final s = CanvasSyncState(
        items: [...?doc?.items],
        itemRevs: {...?doc?.itemRevs},
        tombstones: {...?doc?.tombstones},
        title: doc?.title ?? 'Synced canvas',
        folderId: doc?.folderId,
        metaRev: doc?.metaRev,
        itemUnknownFields: {...?doc?.itemUnknownFields},
        metaUnknownFields: doc?.metaUnknownFields ?? const {},
        kind: doc?.kind,
        pageBackgrounds: doc?.pageBackgrounds ?? const [],
      );
      applied = applyCanvasChanges(s, canvasId, changes, isPending);
      if (applied.isNotEmpty) {
        await canvases.save(
          CanvasDocument(
            id: canvasId,
            title: s.title,
            folderId: s.folderId,
            items: s.items,
            updatedAt: DateTime.now(),
            viewport: doc?.viewport ?? const CanvasViewport(),
            itemRevs: s.itemRevs,
            tombstones: s.tombstones,
            metaRev: s.metaRev,
            unknownItems: doc?.unknownItems ?? const [],
            itemUnknownFields: s.itemUnknownFields,
            unknownKeys: doc?.unknownKeys ?? const {},
            metaUnknownFields: s.metaUnknownFields,
            kind: s.kind,
            pageBackgrounds: s.pageBackgrounds,
          ),
        );
      }
    }
    for (final c in changes) {
      if (applied.contains(c.key)) {
        state.base[c.key] = c.rev;
        report.pulled++;
      } else {
        report.skipped++;
      }
    }
  }

  // --------------------------------------------------------- attachments --

  Future<void> _downloadMissingAttachments(SyncReport report) async {
    for (final Asset a in workspace.assets.all) {
      for (final (name, sha, size) in [
        (a.file, a.fileSha256, a.fileSize),
        (a.previewFile, a.previewSha256, a.previewSize),
      ]) {
        if (name == null || sha == null) continue;
        if (!_safeFileName.hasMatch(name)) {
          report.problems.add(
            'An attachment had an unsafe file name and was skipped.',
          );
          continue;
        }
        final target = workspace.attachments.fileFor(name);
        if (await target.exists()) continue;
        try {
          await client.download(sha, size, target);
          report.downloaded++;
        } on SyncFailure catch (e) {
          if (!e.retryable && e.code != 'not_found') rethrow;
          report.problems.add('An attachment is not available yet.');
        } on FileSystemException {
          report.problems.add('An attachment could not be saved.');
        }
      }
    }
  }
}

/// Small helper so callers don't need dart:io for the default file.
File syncConfigFile(Workspace ws) => File(
  '${ws.root.path}${Platform.pathSeparator}sync${Platform.pathSeparator}hub.json',
);
