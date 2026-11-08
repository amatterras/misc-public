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
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import '../data/models/canvas_models.dart';
import '../data/models/library_models.dart';
import '../data/repositories/canvas_repository.dart';
import '../data/storage/app_log.dart';
import '../data/storage/storage_encryption.dart'
    show DecryptionFailure, FileCipher;
import '../data/workspace.dart';
import 'canvas_manifest.dart';
import 'canvas_merge.dart';
import 'device_keys.dart';
import 'e2ee.dart';
import 'record_merge.dart';
import 'protocol.dart';
import 'sync_client.dart';
import 'transfer_tracker.dart';

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

  /// Adds [ours] to the open notebook's PDF pages (see
  /// `mergePageBackgrounds`); true if anything was added.
  bool mergeOpenPages(String canvasId, List<PageBackground> ours);
}

class SyncReport {
  int pushed = 0;
  int pulled = 0;
  int conflicts = 0;
  int uploaded = 0;
  int downloaded = 0;
  int skipped = 0;

  /// Attachment transfers (and the records that need them) left for the next
  /// cycle because this cycle's transfer time was used up, so that small
  /// changes are never stuck behind a big file. Nothing is lost: a paused
  /// transfer continues from where it stopped.
  int deferred = 0;

  /// Conflicts where both sides' tags or PDF pages were kept.
  int merged = 0;
  final List<String> problems = [];

  @override
  String toString() =>
      'pushed $pushed, pulled $pulled, conflicts $conflicts'
      '${merged == 0 ? '' : ' ($merged merged)'}, files up $uploaded/down $downloaded'
      '${deferred == 0 ? '' : ', $deferred file(s) continue next cycle'}'
      '${problems.isEmpty ? '' : ', ${problems.length} problem(s)'}';
}

/// Remembered per device: which hub, how far we have read, and the hub
/// revision of every record we have in sync.
class SyncState {
  SyncState({
    this.hubId,
    this.cursor = 0,
    Map<String, String>? base,
    Map<String, List<String>>? tagBase,
    Map<String, Map<String, List<String>>>? tagBaseByRev,
    Set<String>? mergedConflicts,
  }) : base = base ?? {},
       tagBase = tagBase ?? {},
       tagBaseByRev = tagBaseByRev ?? {},
       mergedConflicts = mergedConflicts ?? {};

  String? hubId;
  int cursor;
  final Map<String, String> base;

  /// Each link's tags as last synced (asset id → tags), so a conflict can
  /// tell which tags this device added or removed (see `mergeLinkTags`).
  final Map<String, List<String>> tagBase;

  /// The tag base for recent locally pushed revisions. A peer may report a
  /// conflict after this device has already acknowledged its own edit; retain
  /// that edit's original base so conflict merging can still distinguish an
  /// independent addition from an unchanged tag.
  final Map<String, Map<String, List<String>>> tagBaseByRev;

  void rememberTagBase(String assetId, String revision, List<String> tags) {
    final history = tagBaseByRev.putIfAbsent(assetId, () => {});
    history.putIfAbsent(revision, () => [...tags]);
    while (history.length > 10) {
      history.remove(history.keys.first);
    }
  }

  /// Hub conflict records already merged here (so a merge is never redone
  /// over a later edit). Only the most recent ones are kept.
  final Set<String> mergedConflicts;
  static const maxMergedConflicts = 500;

  /// Remembers the tags of a link record as synced ([data] null: deleted).
  void rememberTags(String assetId, Map<String, dynamic>? data) {
    final tags = [
      for (final t in (data?['linkTags'] as List?) ?? const [])
        if (t is String) t,
    ];
    if (tags.isEmpty) {
      tagBase.remove(assetId);
    } else {
      tagBase[assetId] = tags;
    }
  }

  Map<String, dynamic> toJson() => {
    'hubId': hubId,
    'cursor': cursor,
    'base': base,
    if (tagBase.isNotEmpty) 'tagBase': tagBase,
    if (tagBaseByRev.isNotEmpty) 'tagBaseByRev': tagBaseByRev,
    if (mergedConflicts.isNotEmpty)
      'mergedConflicts': mergedConflicts
          .skip(
            mergedConflicts.length > maxMergedConflicts
                ? mergedConflicts.length - maxMergedConflicts
                : 0,
          )
          .toList(),
  };

  factory SyncState.fromJson(Map<String, dynamic>? j) => j == null
      ? SyncState()
      : SyncState(
          hubId: j['hubId'] as String?,
          cursor: j['cursor'] as int? ?? 0,
          base: {...?(j['base'] as Map?)?.cast<String, String>()},
          tagBase: {
            for (final e in ((j['tagBase'] as Map?) ?? const {}).entries)
              if (e.value is List)
                e.key as String: [
                  for (final t in e.value as List)
                    if (t is String) t,
                ],
          },
          tagBaseByRev: {
            for (final e in ((j['tagBaseByRev'] as Map?) ?? const {}).entries)
              if (e.value is Map)
                e.key as String: {
                  for (final rev in (e.value as Map).entries)
                    if (rev.value is List)
                      rev.key as String: [
                        for (final t in rev.value as List)
                          if (t is String) t,
                      ],
                },
          },
          mergedConflicts: {
            for (final id in (j['mergedConflicts'] as List?) ?? const [])
              if (id is String) id,
          },
        );
}

final _safeFileName = RegExp(r'^[A-Za-z0-9_-]{1,80}(\.[A-Za-z0-9]{1,8})?$');

/// Whether [name] is a valid attachment file name (no folders, no `..`).
bool isAttachmentFileName(String name) => _safeFileName.hasMatch(name);

class SyncEngine {
  SyncEngine({
    required this.workspace,
    required this.canvases,
    required this.client,
    this.openCanvas,
    this.remote = '',
  });

  /// Which remote this engine syncs with: '' for the hub (the default, and
  /// what every existing install uses), or a peer's id. Each remote has its
  /// own sync state (cursor, last confirmed versions) and attachment tables,
  /// so a device can sync with several remotes (the PC hub and other
  /// devices) independently; what is already identical is recognised by its
  /// revision and never sent twice.
  final String remote;

  String _file(String base) => remote.isEmpty ? base : '${base}_$remote';

  final Workspace workspace;
  final CanvasRepository canvases;
  final SyncClient client;
  final OpenCanvasBridge? openCanvas;
  bool _busy = false;

  /// Syncs with different remotes (the hub, other devices) never overlap:
  /// they all change the same workspace, so they take turns.
  static Future<void> _turn = Future.value();

  /// Completes when no sync is running (used before opening a canvas, so
  /// a sync never writes a canvas file that is being opened).
  Future<void> whenIdle() => _turn.catchError((Object _) {});

  Future<SyncState> loadState() async => SyncState.fromJson(
    await workspace.store.read('sync', _file('client_state')),
  );

  /// How many local records still wait to reach the hub, by collection name
  /// (counts only: nothing about what they contain). Same test as the push.
  Future<Map<String, int>> pendingCounts() async {
    final state = await loadState();
    final out = <String, int>{};
    for (final MapEntry(key: name, value: collection)
        in workspace.syncCollections.entries) {
      for (final v in collection.versions()) {
        if (state.base['$name/${v.id}'] == v.rev) continue;
        if (!v.deleted && collection[v.id] == null) continue;
        out[name] = (out[name] ?? 0) + 1;
      }
    }
    return out;
  }

  /// Whether record [id] of [collection] has a local change the hub does
  /// not have yet.
  Future<bool> isPending(String collection, String id) async {
    final c = workspace.syncCollections[collection];
    if (c == null) return false;
    final state = await loadState();
    for (final v in c.versions()) {
      if (v.id == id) return state.base['$collection/$id'] != v.rev;
    }
    return false;
  }

  Future<void> _saveState(SyncState s) =>
      workspace.store.write('sync', _file('client_state'), s.toJson());

  /// One full cycle. Throws [SyncFailure] if the hub can't be reached; the
  /// local data is never changed by a failed cycle except for records
  /// already applied (and saved) before the failure.
  Future<SyncReport> syncOnce() async {
    if (_busy) {
      throw const SyncFailure(
        'busy',
        'A sync is already running.',
        retryable: true,
      );
    }
    _busy = true;
    try {
      // Wait for the sync of another remote that may be running.
      final run = _turn.catchError((Object _) {}).then((_) => _syncOnce());
      _turn = run.then<void>((_) {}, onError: (Object _) {});
      return await run;
    } finally {
      _busy = false;
    }
  }

  /// How long one cycle may spend on attachment transfers before it pauses
  /// them (they continue in the next cycle, which the app asks for at once).
  /// Small record changes always go first, so a large photo or PDF never
  /// holds back a note edit for longer than this.
  Duration transferBudget = const Duration(seconds: 2);

  final Stopwatch _cycleClock = Stopwatch();

  /// At least one transfer step ran in this cycle (so every cycle makes
  /// progress on big files, however slow the rest of it was).
  bool _transferStarted = false;

  bool _overBudget() =>
      _transferStarted && _cycleClock.elapsed > transferBudget;

  Future<SyncReport> _syncOnce() async {
    final report = SyncReport();
    _cycleClock
      ..reset()
      ..start();
    _transferStarted = false;
    try {
      await openCanvas?.flushOpenCanvas();
      await workspace.flush();
      await _syncKeys(report);
      final state = await loadState();
      await _fillAttachmentHashes();
      await sweepTransferLeftovers();
      await _push(state, report);
      await _purgeHubBlobs();
      await _pull(state, report);
      await _downloadMissingAttachments(report);
      await _ensureHubSealed(state, report);
      AppLog.info('Sync: $report');
      return report;
    } finally {}
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

  /// Every local record version (rev + data) that syncs, by key. This reads
  /// EVERY canvas: it is the reference ("full scan") that the incremental path
  /// [pendingVersions] must always agree with, and what the one-time
  /// end-to-end upgrade uses.
  Future<Map<String, SyncChange>> localVersions() async {
    final out = _recordVersions();
    for (final id in await _canvasIds()) {
      final doc = await _loadCanvas(id);
      if (doc != null) out.addAll(_canvasChanges(doc));
    }
    out.addAll(_deletedCanvasChanges());
    return out;
  }

  /// The ids of the canvases to look at (every readable canvas file).
  Future<List<String>> _canvasIds() async {
    final repo = canvases;
    if (repo is FileCanvasRepository) return repo.store.list('canvases');
    return [for (final c in await repo.listCanvases()) c.id];
  }

  /// A canvas that cannot be read is skipped (and logged) instead of
  /// failing every sync: one damaged file must not stop all the others.
  Future<CanvasDocument?> _loadCanvas(String id) async {
    try {
      return await canvases.load(id);
    } catch (e) {
      AppLog.warn('Sync: canvas $id could not be read and was skipped ($e)');
      return null;
    }
  }

  Map<String, SyncChange> _recordVersions() {
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
    return out;
  }

  /// The versions inside one canvas: its title/folder/order record, each
  /// item that has a stamp, and its item tombstones.
  Map<String, SyncChange> _canvasChanges(CanvasDocument doc) {
    final out = <String, SyncChange>{};
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
          doc.layers,
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
    return out;
  }

  Map<String, SyncChange> _deletedCanvasChanges() => {
    for (final t in workspace.canvasTombstones.entries)
      'canvases/${t.key}': SyncChange(
        collection: 'canvases',
        id: t.key,
        rev: t.value,
        deleted: true,
      ),
  };

  // ------------------------------------------------------- pending changes --

  static final Expando<CanvasManifest> _manifests = Expando<CanvasManifest>();

  /// The revision cache for this workspace's canvases (shared by every
  /// engine of the workspace), or null when the canvases are not plain files
  /// (then every cycle reads them all, as before).
  CanvasManifest? get canvasManifest {
    final repo = canvases;
    if (repo is! FileCanvasRepository) return null;
    return _manifests[workspace] ??= CanvasManifest(
      store: repo.store,
      metaStore: workspace.store,
      load: _loadCanvas,
    );
  }

  /// Only what differs from what the remote last confirmed, by key: the
  /// result of a full scan filtered by `state.base`, found without reading
  /// canvases that cannot have changed.
  Future<Map<String, SyncChange>> pendingVersions(SyncState state) async {
    final manifest = canvasManifest;
    if (manifest == null) return pendingVersionsFullScan(state);
    // A cache is only believed after it was checked against the files:
    // when it is new (first cycle of this run) and then once a day.
    if (manifest.dueForVerify) await manifest.verify();
    final view = await manifest.refresh();
    final all = _recordVersions();
    for (final entry in view.values) {
      if (!entry.hasPending(state.base)) continue;
      final doc = await _loadCanvas(entry.id);
      if (doc != null) all.addAll(_canvasChanges(doc));
    }
    all.addAll(_deletedCanvasChanges());
    return _differing(all, state);
  }

  /// The same answer, by reading every canvas (the reference).
  Future<Map<String, SyncChange>> pendingVersionsFullScan(
    SyncState state,
  ) async => _differing(await localVersions(), state);

  Map<String, SyncChange> _differing(
    Map<String, SyncChange> all,
    SyncState state,
  ) => {
    for (final e in all.entries)
      if (state.base[e.key] != e.value.rev) e.key: e.value,
  };

  /// Checks the manifest against every canvas file and repairs it; returns
  /// how many entries were wrong (0 normally).
  Future<int> verifyManifest() async => await canvasManifest?.verify() ?? 0;

  // ---------------------------------------------------------------- push --

  Future<void> _push(SyncState state, SyncReport report) async {
    // First learn which hub this is (and whether it was restored from an
    // older backup), so "pending" is judged against the right hub.
    final probe = await client.pull(state.cursor, limit: 1);
    _checkHub(state, probe.hubId, probe.lastSeq);
    final local = await pendingVersions(state);
    final pending = <SyncChange>[];
    for (final c in local.values) {
      if (c.data != null &&
          utf8.encode(jsonEncode(c.data)).length > maxRecordBytes) {
        // Too large for the hub: keep it here, report it, and let every
        // other change sync instead of blocking all of them.
        report.problems.add('A ${c.collection} record is too large to sync.');
        continue;
      }
      pending.add(c);
    }
    // Kinds added after the first hub version go last, each on its own: an
    // older hub refuses them, and that must not stop everything else.
    final late = {
      for (final name in newerCollections)
        name: [
          for (final c in pending)
            if (c.collection == name) c,
        ],
    };
    pending.removeWhere((c) => newerCollections.contains(c.collection));
    // Small changes first: attachment records (which may need a big file
    // uploaded before they can go) are sent after every other record, in
    // their own batches, so a large file never delays a note or a task.
    final assets = [
      for (final c in pending)
        if (c.collection == 'assets' && !c.deleted) c,
    ];
    pending.removeWhere((c) => c.collection == 'assets' && !c.deleted);
    final groups = [
      for (var i = 0; i < pending.length; i += maxPushBatch)
        pending.skip(i).take(maxPushBatch).toList(),
      for (var i = 0; i < assets.length; i += maxPushBatch)
        assets.skip(i).take(maxPushBatch).toList(),
      for (final list in late.values)
        for (var i = 0; i < list.length; i += maxPushBatch)
          list.skip(i).take(maxPushBatch).toList(),
    ];
    final refused = <String>{};
    for (final group in groups) {
      if (refused.contains(group.first.collection)) continue;
      final batch = [
        for (final c in group)
          SyncChange(
            collection: c.collection,
            id: c.id,
            rev: c.rev,
            deleted: c.deleted,
            data: c.data,
            baseRev: state.base[c.key],
          ),
      ];
      for (var i = 0; i < batch.length; i++) {
        final c = batch[i];
        if (c.collection == 'assets' && !c.deleted) {
          // End-to-end: the file is sealed and uploaded under its own id,
          // and the record carries that id (inside the sealed record).
          final ready = await _withBlobs(c, report);
          if (ready == null) {
            // Its file is still on its way: the record waits (it stays
            // pending here) and goes with the next cycle.
            batch.removeAt(i);
            i--;
            report.deferred++;
          } else {
            batch[i] = ready;
          }
        }
      }
      if (batch.isEmpty) continue;
      final ({List<PushResult> results, int lastSeq, String hubId}) response;
      try {
        response = await client.push(batch);
      } on SyncFailure catch (e) {
        final name = group.first.collection;
        if (e.code == 'bad_change' && newerCollections.contains(name)) {
          refused.add(name);
          report.problems.add(
            name == 'clipboard'
                ? 'The hub does not accept the shared clipboard yet: restart '
                      'it with this version of misc.'
                : 'The hub does not accept $name yet: restart it with this '
                      'version of misc.',
          );
          continue;
        }
        rethrow;
      }
      _checkHub(state, response.hubId, response.lastSeq);
      final sentRev = {for (final c in batch) c.key: c.rev};
      final sent = {for (final c in batch) c.key: c};
      final adopt = <SyncChange>[];
      // Our tags / PDF pages, merged back in after taking the hub's version.
      final tagMerges = <(String, List<String>, List<String>?)>[];
      final pageMerges = <(String, List<PageBackground>)>[];
      for (final r in response.results) {
        final key = '${r.collection}/${r.id}';
        final ours = sent[key];
        switch (r.status) {
          case PushStatus.applied || PushStatus.duplicate:
            state.base[key] = r.rev;
            if (r.collection == 'assets') {
              final sentAsset = ours;
              if (sentAsset != null) {
                state.rememberTagBase(
                  r.id,
                  sentAsset.rev,
                  state.tagBase[r.id] ?? const [],
                );
              }
              state.rememberTags(
                r.id,
                sentAsset?.deleted == true ? null : sentAsset?.data,
              );
            }
            report.pushed++;
          case PushStatus.keptServer:
            // The hub kept another version (ours is preserved as a conflict
            // when it was a real edit): take the hub's version.
            if (r.current != null) adopt.add(r.current!);
            final data = ours?.data;
            if (data != null && r.collection == 'assets') {
              tagMerges.add((
                r.id,
                [
                  for (final t in (data['linkTags'] as List?) ?? const [])
                    if (t is String) t,
                ],
                state.tagBase[r.id],
              ));
              final conflict = r.conflictId;
              if (conflict != null) state.mergedConflicts.add(conflict);
            } else if (data != null && r.collection == 'canvases') {
              final pages = [
                for (final b in (data['backgrounds'] as List?) ?? const [])
                  PageBackground.fromJson(b as Map<String, dynamic>),
              ];
              if (pages.isNotEmpty) pageMerges.add((r.id, pages));
              final conflict = r.conflictId;
              if (conflict != null) state.mergedConflicts.add(conflict);
            }
        }
        if (r.conflictId != null) report.conflicts++;
      }
      if (adopt.isNotEmpty) {
        // Take the hub's version only if the record still has exactly the
        // revision we sent: an edit made while the request was in flight
        // stays (it is pending and will be resolved by the next push).
        await _apply(adopt, state, report, sentRev: sentRev);
      }
      // Neither device's tags or PDF pages are lost: the merged result is
      // a new local edit, sent with the next push.
      for (final (id, ours, base) in tagMerges) {
        final asset = workspace.assets[id];
        if (asset == null) continue;
        final merged = mergeLinkTags(
          local: asset.linkTags,
          ours: ours,
          base: base,
        );
        if (!_sameList(merged, asset.linkTags)) {
          workspace.assets.put(asset.copyWith(linkTags: merged));
          report.merged++;
        }
      }
      for (final (id, ours) in pageMerges) {
        if (await _mergePages(id, ours)) report.merged++;
      }
      await _commitLocal(state);
    }
    // Once per session, after every record went out (a missing file on the
    // hub must not hold back small changes either): finished only when no
    // upload had to wait for the next cycle.
    if (!_attachmentsReconciled) {
      _attachmentsReconciled = await _reconcileAttachments(report);
    }
  }

  /// A hub conflict record says our edit of a link or a notebook's metadata
  /// lost against a newer edit from another device: add our tags (keeping
  /// the other device's too) or our PDF pages back, once.
  Future<void> _mergeLostEdit(
    Map<String, dynamic> conflict,
    SyncState state,
    SyncReport report,
    Map<String, List<String>> tagBaseBefore,
    Map<String, SyncChange> serverChanges,
  ) async {
    final id = conflict['id'];
    final other = conflict['otherData'];
    if (id is! String ||
        conflict['reason'] != 'concurrent_edit' ||
        conflict['otherDevice'] != workspace.device?.id ||
        other is! Map<String, dynamic> ||
        state.mergedConflicts.contains(id)) {
      return;
    }
    final recordId = conflict['recordId'] as String?;
    if (recordId == null) return;
    switch (conflict['collection']) {
      case 'assets':
        final collection = workspace.syncCollections['assets']!;
        final server = serverChanges['assets/$recordId'];
        final otherRev = conflict['otherRev'] as String?;
        final keptRev = conflict['keptRev'] as String?;
        final localRev = collection.revOf(recordId);
        // The hub's winning asset may have arrived in this same pull, but
        // the ordinary pending-edit check correctly left our losing local
        // copy untouched. Replace it only when it is still exactly the
        // revision named by this conflict.
        if (localRev == otherRev &&
            server != null &&
            server.rev == keptRev &&
            !server.deleted &&
            server.data != null) {
          collection.applyRemote(recordId, server.rev, server.data);
          state.base[server.key] = server.rev;
          state.rememberTags(recordId, server.data);
        }
        final asset = workspace.assets[recordId];
        if (asset != null) {
          final merged = mergeLinkTags(
            local: asset.linkTags,
            ours: [
              for (final t in (other['linkTags'] as List?) ?? const [])
                if (t is String) t,
            ],
            base:
                (otherRev == null
                    ? null
                    : state.tagBaseByRev[recordId]?[otherRev]) ??
                tagBaseBefore[recordId],
          );
          if (!_sameList(merged, asset.linkTags)) {
            workspace.assets.put(asset.copyWith(linkTags: merged));
            report.merged++;
          }
        }
      case 'canvases':
        final pages = [
          for (final b in (other['backgrounds'] as List?) ?? const [])
            PageBackground.fromJson(b as Map<String, dynamic>),
        ];
        if (pages.isNotEmpty && await _mergePages(recordId, pages)) {
          report.merged++;
        }
    }
    state.mergedConflicts.add(id);
  }

  static bool _sameList(List<String> a, List<String> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  /// Adds our PDF pages back to a notebook after the hub's version was
  /// taken. The result gets a new metadata revision, so it is sent next.
  Future<bool> _mergePages(String canvasId, List<PageBackground> ours) async {
    final bridge = openCanvas;
    if (bridge != null && bridge.isOpen(canvasId)) {
      return bridge.mergeOpenPages(canvasId, ours);
    }
    final doc = await canvases.load(canvasId);
    if (doc == null) return false;
    final merged = mergePageBackgrounds(doc.pageBackgrounds, ours);
    if (merged == null) return false;
    await canvases.save(
      CanvasDocument(
        id: doc.id,
        title: doc.title,
        folderId: doc.folderId,
        items: doc.items,
        updatedAt: DateTime.now(),
        viewport: doc.viewport,
        itemRevs: doc.itemRevs,
        tombstones: doc.tombstones,
        metaRev: workspace.clock.now(),
        unknownItems: doc.unknownItems,
        itemUnknownFields: doc.itemUnknownFields,
        unknownKeys: doc.unknownKeys,
        metaUnknownFields: doc.metaUnknownFields,
        kind: doc.kind,
        pageBackgrounds: merged,
        layers: doc.layers,
      ),
    );
    return true;
  }

  bool _attachmentsReconciled = false;

  bool _swept = false;

  /// Removes what interrupted transfers leave behind, once per run: partial
  /// downloads in `incoming/` untouched for [partialDownloadKeep], and staged
  /// uploads in `outbox/` that no pending upload refers to (a crash between
  /// staging and noting it) untouched for a day. A download or upload that is
  /// still wanted is never removed: a partial file this old is simply fetched
  /// again, and a pending staged upload is kept as long as it is pending.
  Future<void> sweepTransferLeftovers({
    Duration partialDownloadKeep = const Duration(days: 7),
    Duration strayUploadKeep = const Duration(days: 1),
    bool force = false,
  }) async {
    if (_swept && !force) return;
    _swept = true;
    final root = workspace.root.path;
    final sep = Platform.pathSeparator;
    final now = DateTime.now();
    Future<void> sweep(
      String folder,
      String suffix,
      Duration older,
      bool Function(String name) keep,
    ) async {
      final dir = Directory('$root$sep$folder');
      if (!await dir.exists()) return;
      await for (final f in dir.list()) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last;
        if (!name.endsWith(suffix) || keep(name)) continue;
        try {
          if (now.difference(await f.lastModified()) > older) {
            await f.delete();
          }
        } on FileSystemException {
          // Busy or already gone: nothing to do.
        }
      }
    }

    final pending = {...(await _pendingTable()).values};
    await sweep('incoming', '.dl', partialDownloadKeep, (_) => false);
    await sweep(
      'outbox',
      '.up',
      strayUploadKeep,
      (name) => pending.contains(name.substring(0, name.length - 3)),
    );
  }

  /// Once per session: makes sure the hub has every photo this device has
  /// (e.g. after the hub lost its attachments folder), uploading any that
  /// are missing. Uploads are checked by size and checksum on the hub.
  Future<bool> _reconcileAttachments(SyncReport report) async {
    var complete = true;
    for (final a in workspace.assets.all.toList()) {
      final data = workspace.assets.jsonOf(a.id) ?? a.toJson();
      final done = await _withBlobs(
        SyncChange(
          collection: 'assets',
          id: a.id,
          rev: workspace.assets.revOf(a.id) ?? '',
          deleted: false,
          data: data,
        ),
        report,
      );
      if (done == null) {
        complete = false;
        report.deferred++;
      }
    }
    return complete;
  }

  /// This device's key pair, and where a changed workspace key is stored
  /// (set by the app). Without them a key change cannot be received.
  DeviceKeyPair? deviceKey;
  Future<void> Function(SyncCrypto)? saveKeys;
  bool _deviceKeyPublished = false;

  /// Once per session tells the hub this device's public key (endorsed by
  /// the workspace key); every cycle takes in a key change made by another
  /// device (wrapped for this one, and authenticated by the old key).
  Future<void> _syncKeys(SyncReport report) async {
    final crypto = client.crypto;
    final dk = deviceKey;
    if (crypto == null || dk == null) return;
    final first = crypto.exportKeys()[1];
    try {
      if (!_deviceKeyPublished && first != null) {
        final info = await client.devices();
        final mine = info.devices.where((d) => d.id == info.self).firstOrNull;
        if (mine?.publicKey != dk.publicBase64) {
          await client.publishDeviceKey(
            dk.publicBase64,
            endorseDeviceKey(first, info.self, dk.publicBase64),
          );
        }
        _deviceKeyPublished = true;
      }
      final found = await client.keysSince(crypto.current);
      if (found.epoch <= crypto.current || first == null) return;
      var changed = false;
      for (final w in [
        ...found.wraps,
      ]..sort((a, b) => a.epoch.compareTo(b.epoch))) {
        final key = unwrapRotatedKey(
          device: dk,
          epoch: w.epoch,
          deviceId: workspace.device!.id,
          wrapped: w.wrapped,
          firstWorkspaceKey: first,
        );
        if (key == null) {
          report.problems.add(
            'A change of the workspace key could not be verified, so it was '
            'not used. This device may need to be paired again.',
          );
          continue;
        }
        crypto.addEpoch(w.epoch, key);
        changed = true;
      }
      if (changed) await saveKeys?.call(crypto);
    } on SyncFailure catch (e) {
      if (e.code != 'not_found') rethrow; // an older hub: nothing to do
    }
  }

  /// A device was removed: makes the next workspace key and wraps it for
  /// every remaining device that has an endorsed public key (including this
  /// one, so a crash cannot lose it). The removed device, and the hub, get
  /// nothing; records written from now on are sealed under the new key.
  /// [notUpdated] names devices without a usable key (they must be paired
  /// again to read new records).
  Future<({int epoch, List<String> notUpdated})> rotateKey() async {
    final crypto = client.crypto;
    if (crypto == null) {
      throw const SyncFailure('no_key', 'This device has no workspace key.');
    }
    final first = crypto.exportKeys()[1];
    if (first == null) {
      throw const SyncFailure('no_key', 'The first workspace key is missing.');
    }
    final info = await client.devices();
    final epoch = crypto.current + 1;
    final newKey = FileCipher.randomBytes(32);
    final wraps = <String, String>{};
    final notUpdated = <String>[];
    for (final d in info.devices) {
      if (d.revoked || d.readOnly) continue;
      final pub = d.publicKey, end = d.endorsement;
      if (pub == null ||
          end == null ||
          !verifyDeviceKey(first, d.id, pub, end)) {
        notUpdated.add(d.name);
        continue;
      }
      wraps[d.id] = wrapRotatedKey(
        recipientPublic: base64Decode(pub),
        epoch: epoch,
        deviceId: d.id,
        newKey: newKey,
        firstWorkspaceKey: first,
      );
    }
    await client.rotateKeys(epoch, wraps);
    crypto.addEpoch(epoch, newKey);
    await saveKeys?.call(crypto);
    AppLog.info('Sync: workspace key changed to epoch $epoch');
    return (epoch: epoch, notUpdated: notUpdated);
  }

  /// Once per purge: asks the hub to delete the sealed attachment copies of a
  /// record deleted for good (only those no remaining asset still uses).
  Future<void> _purgeHubBlobs() async {
    final done = await workspace.store.read('sync', 'purged_blobs');
    final handled = {...((done?['done'] as List?)?.whereType<String>() ?? [])};
    final table = await _blobTable();
    var changed = false;
    for (final mark in workspace.purges.all.toList()) {
      if (handled.contains(mark.id) || mark.blobs.isEmpty) continue;
      final stillUsed = {
        for (final a in workspace.assets.all)
          for (final k in ['fileBlob', 'previewBlob'])
            ?workspace.assets.jsonOf(a.id)?[k] as String?,
        ...table.values.where(
          (id) => workspace.assets.all.any(
            (a) => table[a.fileSha256] == id || table[a.previewSha256] == id,
          ),
        ),
      };
      final ids = [
        for (final b in mark.blobs)
          if (!stillUsed.contains(b)) b,
      ];
      if (ids.isNotEmpty) {
        try {
          await client.purgeBlobs(ids);
        } on SyncFailure catch (e) {
          if (e.code != 'not_found') rethrow; // an older hub: nothing to do
        }
      }
      table.removeWhere((_, id) => ids.contains(id));
      handled.add(mark.id);
      changed = true;
    }
    if (changed) {
      await workspace.store.write('sync', 'purged_blobs', {
        'done': handled.toList(),
      });
      await workspace.store.write('sync', _file('blobs'), {'blobs': table});
    }
  }

  bool _sealedChecked = false;

  /// Makes the hub hold only end-to-end encrypted data, once: with a
  /// workspace key, everything this device has is offered again (sealed;
  /// a sealed copy replaces the hub's plain one of the same revision), the
  /// hub is asked to confirm it holds no plain record, a read-back of every
  /// record is opened and compared with what is stored here, and only then
  /// the hub is switched to encrypted-only (which also removes its plain
  /// attachments and old backups). Any failure stops here, is reported,
  /// and nothing is claimed; the next sync tries again.
  Future<void> _ensureHubSealed(SyncState state, SyncReport report) async {
    final crypto = client.crypto;
    if (crypto == null || _sealedChecked) return;
    final ({bool required, int plaintextRecords}) status;
    try {
      status = await client.e2eeStatus();
    } on SyncFailure catch (e) {
      if (e.code == 'not_found') {
        report.problems.add(
          'This hub is too old for end-to-end encryption: restart it with '
          'this version of misc.',
        );
        _sealedChecked = true; // nothing to retry until it is updated
        return;
      }
      rethrow;
    }
    if (status.required) {
      client.requireSealed = true;
      _sealedChecked = true;
      return;
    }
    if (status.plaintextRecords > 0) {
      // Share links made before have no key in their address: they cannot
      // be sealed for the same link, so they stop working (make a new one).
      for (final link in workspace.shares.all.toList()) {
        if (link.sealed == null && !link.revoked) {
          workspace.shares.put(link.revoke());
        }
      }
      state.base.clear(); // offer everything again, sealed
      await _saveState(state);
      await _push(state, report);
      final after = await client.e2eeStatus();
      if (after.plaintextRecords > 0) {
        report.problems.add(
          '${after.plaintextRecords} record(s) on the hub are still not '
          'end-to-end encrypted, so it was not switched over.',
        );
        return;
      }
    }
    if (!await _readBackMatches(report)) return;
    await client.commitEncryption();
    client.requireSealed = true;
    _sealedChecked = true;
    AppLog.info('Sync: the hub now accepts only end-to-end encrypted data');
  }

  /// Reads every record back from the hub (opening each sealed one) and
  /// checks it against this device's copy where the revisions are the same.
  Future<bool> _readBackMatches(SyncReport report) async {
    final local = await localVersions();
    var cursor = 0;
    var checked = 0;
    while (true) {
      final page = await client.pull(cursor, limit: maxPullLimit);
      for (final c in page.changes) {
        if (c.deleted || c.data == null) continue;
        final mine = local[c.key];
        if (mine == null || mine.rev != c.rev || mine.data == null) continue;
        if (_canonical(_withoutBlobIds(mine.data)) !=
            _canonical(_withoutBlobIds(c.data))) {
          report.problems.add(
            'A ${c.collection} record did not read back correctly from the '
            'hub, so it was not switched to end-to-end encryption.',
          );
          return false;
        }
        checked++;
      }
      if (!page.hasMore) break;
      cursor = page.next;
    }
    AppLog.info('Sync: $checked record(s) read back from the hub and verified');
    return true;
  }

  /// The sealed attachment ids are added to an asset only on its way out.
  static Map<String, dynamic>? _withoutBlobIds(Map<String, dynamic>? data) =>
      data == null
      ? null
      : (Map<String, dynamic>.of(data)
          ..remove('fileBlob')
          ..remove('previewBlob'));

  static String _canonical(Object? v) => jsonEncode(_sorted(v));

  static Object? _sorted(Object? v) => switch (v) {
    Map() => {
      for (final k in (v.keys.map((k) => '$k').toList()..sort()))
        k: _sorted(v[k]),
    },
    List() => [for (final e in v) _sorted(e)],
    _ => v,
  };

  Map<String, String>? _blobIds;

  /// plain SHA-256 of an attachment -> id of its sealed copy on the hub.
  /// Sealed copies waiting in the outbox: plain SHA-256 -> sealed id.
  Map<String, String>? _pendingIds;

  /// Attachments being sealed for upload (plain SHA-256 -> the sealed id,
  /// or null if the file changed); a sealing outlives the cycle that began it.
  final Map<String, Future<String?>> _sealing = {};
  static const _stillSealing = '\u0000sealing';

  /// Seals attachment [name] off the UI isolate and stages the sealed copy in
  /// the outbox (noted in the outbox table), so an interrupted upload
  /// continues with the same bytes. Null if the file no longer matches [sha].
  Future<String?> _sealAndStage(
    String name,
    String sha,
    SyncCrypto crypto,
    Directory outbox,
  ) async {
    try {
      final plain = await workspace.attachments.readBytes(name);
      if (sha256.convert(plain).toString() != sha) return null;
      final sealed = await crypto.sealBlobAsync(plain);
      final staged = File(
        '${outbox.path}${Platform.pathSeparator}${sealed.id}.up',
      );
      await staged.writeAsBytes(sealed.bytes, flush: true);
      final pending = await _pendingTable();
      pending[sha] = sealed.id;
      await workspace.store.write('sync', _file('outbox'), {
        'pending': pending,
      });
      return sealed.id;
    } finally {
      _sealing.remove(sha);
    }
  }

  Future<Map<String, String>> _pendingTable() async {
    if (_pendingIds != null) return _pendingIds!;
    final saved = await workspace.store.read('sync', _file('outbox'));
    return _pendingIds = {
      for (final e in ((saved?['pending'] as Map?) ?? const {}).entries)
        '${e.key}': '${e.value}',
    };
  }

  /// What the attachment transfers are doing (progress, retries, failures).
  final TransferTracker transfers = TransferTracker();

  Future<Map<String, String>> _blobTable() async {
    if (_blobIds != null) return _blobIds!;
    final saved = await workspace.store.read('sync', _file('blobs'));
    return _blobIds = {
      for (final e in ((saved?['blobs'] as Map?) ?? const {}).entries)
        '${e.key}': '${e.value}',
    };
  }

  /// With a workspace key: seals each file of [asset], makes sure the hub
  /// holds it (uploading when not), and returns the asset change carrying the
  /// sealed copy's id as `fileBlob` / `previewBlob`. Without a key (older
  /// setups) the plain file is uploaded as before.
  ///
  /// Returns null when this cycle's transfer time is used up before the
  /// hub holds every file: the record then waits for the next cycle (a
  /// started upload continues from what the hub already has).
  Future<SyncChange?> _withBlobs(SyncChange asset, SyncReport report) async {
    final crypto = client.crypto;
    if (crypto == null) {
      await _uploadFiles(asset, report);
      return asset;
    }
    final data = Map<String, dynamic>.of(asset.data!);
    final table = await _blobTable();
    for (final (nameKey, shaKey, blobKey) in [
      ('file', 'fileSha256', 'fileBlob'),
      ('previewFile', 'previewSha256', 'previewBlob'),
    ]) {
      final name = data[nameKey] as String?;
      final sha = data[shaKey] as String?;
      if (name == null || sha == null || !_safeFileName.hasMatch(name)) {
        continue;
      }
      var id = table[sha] ?? data[blobKey] as String?;
      final haveLocal = await workspace.attachments.fileFor(name).exists();
      if (haveLocal && (id == null || !await client.hasAttachment(id))) {
        if (_overBudget()) return null;
        // The sealed copy is kept in the outbox until the hub has all of it,
        // so an interrupted upload continues instead of sealing (and
        // sending) the file again under a new id.
        final outbox = Directory(
          '${workspace.root.path}${Platform.pathSeparator}outbox',
        );
        await outbox.create(recursive: true);
        final pending = await _pendingTable();
        var sealedId = pending[sha];
        var staged = File(
          '${outbox.path}${Platform.pathSeparator}$sealedId.up',
        );
        if (sealedId == null ||
            !await staged.exists() ||
            await fileSha256(staged) != sealedId) {
          // Sealing a big file takes a while: it runs in the background and
          // the cycle waits only for what is left of its transfer time. If
          // it is not finished by then, the record waits for a later cycle
          // (the sealing carries on meanwhile) and small changes keep going.
          _transferStarted = true;
          final job = _sealing[sha] ??= _sealAndStage(
            name,
            sha,
            crypto,
            outbox,
          );
          final left = transferBudget - _cycleClock.elapsed;
          final result = await Future.any<String?>([
            job,
            Future<String?>.delayed(
              left.isNegative ? Duration.zero : left,
              () => _stillSealing,
            ),
          ]);
          if (result == _stillSealing) return null;
          if (result == null) {
            report.problems.add(
              'An attachment changed on disk and was not sent.',
            );
            continue;
          }
          sealedId = result;
          staged = File('${outbox.path}${Platform.pathSeparator}$sealedId.up');
        }
        final total = await staged.length();
        transfers.update(
          sealedId,
          upload: true,
          stage: TransferStage.active,
          total: total,
        );
        _transferStarted = true;
        final bool complete;
        try {
          complete = await client.upload(
            sealedId,
            staged,
            onProgress: (sent, all) => transfers.update(
              sealedId!,
              upload: true,
              stage: TransferStage.active,
              bytes: sent,
              total: all,
            ),
            shouldPause: _overBudget,
          );
        } on SyncFailure catch (e) {
          transfers.update(
            sealedId,
            upload: true,
            stage: e.retryable ? TransferStage.retrying : TransferStage.failed,
            error: e.message,
          );
          rethrow;
        }
        if (!complete) {
          // Paused to let small changes through; the hub keeps what it has.
          transfers.update(
            sealedId,
            upload: true,
            stage: TransferStage.waiting,
          );
          return null;
        }
        // Done only now: the hub confirmed the complete, checked file.
        transfers.update(
          sealedId,
          upload: true,
          stage: TransferStage.done,
          total: total,
        );
        if (await staged.exists()) await staged.delete();
        pending.remove(sha);
        await workspace.store.write('sync', _file('outbox'), {
          'pending': pending,
        });
        id = sealedId;
        table[sha] = id;
        await workspace.store.write('sync', _file('blobs'), {'blobs': table});
        report.uploaded++;
      }
      if (id != null) data[blobKey] = id;
    }
    return SyncChange(
      collection: asset.collection,
      id: asset.id,
      rev: asset.rev,
      deleted: asset.deleted,
      data: data,
      baseRev: asset.baseRev,
      seq: asset.seq,
    );
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
      // The hub and other devices get the content, never this device's
      // ciphertext: a decrypted view copy is uploaded.
      final file = workspace.attachments.viewFile(name);
      if (file == null) continue;
      if (await client.hasAttachment(sha)) continue;
      await client.upload(sha, file);
      report.uploaded++;
    }
  }

  Future<void> _fillAttachmentHashes() => fillAttachmentHashes(workspace);

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
    final lostEdits = <Map<String, dynamic>>[];
    final tagBaseBefore = {
      for (final e in state.tagBase.entries) e.key: [...e.value],
    };
    final serverChanges = {for (final c in changes) c.key: c};
    for (final c in changes) {
      final collection = workspace.syncCollections[c.collection];
      if (collection != null) {
        final localRev = collection.revOf(c.id) ?? collection.tombstones[c.id];
        if (localRev == c.rev) {
          state.base[c.key] = c.rev;
          if (c.collection == 'assets') {
            state.rememberTags(c.id, c.deleted ? null : c.data);
          }
          continue;
        }
        if (isPending(c.key, localRev)) {
          report.skipped++;
          continue;
        }
        try {
          collection.applyRemote(c.id, c.rev, c.deleted ? null : c.data);
          state.base[c.key] = c.rev;
          if (c.collection == 'assets') {
            state.rememberTags(c.id, c.deleted ? null : c.data);
          }
          if (c.collection == 'conflicts' && c.data != null) {
            lostEdits.add(c.data!);
          }
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
    // Our tags or PDF pages that lost against another device's newer edit
    // (recorded by the hub as a conflict) are added back.
    for (final conflict in lostEdits) {
      await _mergeLostEdit(
        conflict,
        state,
        report,
        tagBaseBefore,
        serverChanges,
      );
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
        layers: doc?.layers ?? const [],
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
            layers: s.layers,
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
    // A canvas deleted earlier was brought back on another device (e.g. a
    // restored note's handwriting): it exists again here too.
    if (meta != null &&
        applied.contains(meta.key) &&
        workspace.canvasTombstones.containsKey(canvasId)) {
      await workspace.forgetCanvasDeletion(canvasId);
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
        if (await workspace.attachments.fileFor(name).exists()) continue;
        if (_overBudget()) {
          // This cycle's transfer time is used up: next cycle.
          report.deferred++;
          continue;
        }
        _transferStarted = true;
        // Downloaded into a staging file, then stored encrypted here.
        final staged = workspace.attachments.stagingFile(name);
        try {
          final crypto = client.crypto;
          final blob =
              workspace.assets.jsonOf(a.id)?[name == a.file
                      ? 'fileBlob'
                      : 'previewBlob']
                  as String?;
          if (crypto != null && blob != null && sha256Pattern.hasMatch(blob)) {
            // The partial file lives in `incoming/` (not the view-copy
            // folder, which is emptied whenever the app goes to the
            // background), so a cut download continues next time.
            final partial = File(
              '${workspace.root.path}${Platform.pathSeparator}incoming'
              '${Platform.pathSeparator}$blob.dl',
            );
            transfers.update(blob, upload: false, stage: TransferStage.active);
            final bool complete;
            try {
              complete = await client.download(
                blob,
                null,
                partial,
                onProgress: (got, all) => transfers.update(
                  blob,
                  upload: false,
                  stage: TransferStage.active,
                  bytes: got,
                  total: all ?? size,
                ),
                shouldPause: _overBudget,
              );
            } on SyncFailure catch (e) {
              transfers.update(
                blob,
                upload: false,
                stage: e.retryable
                    ? TransferStage.retrying
                    : TransferStage.failed,
                error: e.message,
              );
              rethrow;
            }
            if (!complete) {
              // Paused; the partial file in `incoming/` is continued next
              // cycle.
              transfers.update(
                blob,
                upload: false,
                stage: TransferStage.waiting,
              );
              report.deferred++;
              continue;
            }
            transfers.update(
              blob,
              upload: false,
              stage: TransferStage.verifying,
            );
            final Uint8List plain;
            try {
              plain = await crypto.openBlobAsync(await partial.readAsBytes());
            } on DecryptionFailure {
              transfers.update(
                blob,
                upload: false,
                stage: TransferStage.failed,
                error: 'could not be decrypted',
              );
              report.problems.add('An attachment could not be decrypted.');
              continue;
            } finally {
              if (await partial.exists()) await partial.delete();
            }
            if (sha256.convert(plain).toString() != sha) {
              report.problems.add('A downloaded attachment is damaged.');
              continue;
            }
            await workspace.attachments.storeBytes(name, plain);
            transfers.update(blob, upload: false, stage: TransferStage.done);
          } else if (client.requireSealed) {
            report.problems.add('An attachment is not available yet.');
            continue;
          } else {
            await client.download(sha, size, staged);
            await workspace.attachments.adopt(name, staged);
          }
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

/// Records file checksums on [workspace]'s assets (a local edit, so it
/// syncs).
Future<void> fillAttachmentHashes(Workspace workspace) async {
  for (final a in workspace.assets.all.toList()) {
    String? fileSha = a.fileSha256, previewSha = a.previewSha256;
    int? fileSize = a.fileSize, previewSize = a.previewSize;
    if (a.file != null && fileSha == null) {
      if (await workspace.attachments.fileFor(a.file!).exists()) {
        (fileSha, fileSize) = await workspace.attachments.contentInfo(a.file!);
      }
    }
    if (a.previewFile != null && previewSha == null) {
      if (await workspace.attachments.fileFor(a.previewFile!).exists()) {
        (previewSha, previewSize) = await workspace.attachments.contentInfo(
          a.previewFile!,
        );
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
