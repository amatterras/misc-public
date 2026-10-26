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
import 'record_merge.dart';
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

  /// Conflicts where both sides' tags or PDF pages were kept.
  int merged = 0;
  final List<String> problems = [];

  @override
  String toString() =>
      'pushed $pushed, pulled $pulled, conflicts $conflicts'
      '${merged == 0 ? '' : ' ($merged merged)'}, files up $uploaded/down $downloaded'
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
  Future<Map<String, SyncChange>> localVersions() async {
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
    final local = await localVersions();
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
    final groups = [
      for (var i = 0; i < pending.length; i += maxPushBatch)
        pending.skip(i).take(maxPushBatch).toList(),
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
      for (final c in batch) {
        if (c.collection == 'assets' && !c.deleted) {
          await _uploadFiles(c, report);
        }
      }
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
                      'it with this version of THEapp.'
                : 'The hub does not accept $name yet: restart it with this '
                      'version of THEapp.',
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

/// Records file checksums on [workspace]'s assets (a local edit, so it
/// syncs).
Future<void> fillAttachmentHashes(Workspace workspace) async {
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
