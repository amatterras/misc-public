import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/canvas_models.dart' show newId;
import '../models/library_models.dart' show AssetKind;
import '../models/object_library_models.dart';
import '../models/tag_models.dart';
import '../../features/links/link_tags.dart';
import '../workspace.dart';
import 'archive_duplicates.dart';

export 'archive_duplicates.dart';

/// Local-first persistence and indexed discovery for the replacement library.
/// Binary bytes remain in Workspace.attachments; this repository stores IDs.
class LibraryRepository {
  LibraryRepository(this.workspace) {
    scheduleMicrotask(_recoverLocalState);
  }
  final Workspace workspace;
  bool _processing = false;
  Timer? _retryTimer;

  void dispose() => _retryTimer?.cancel();

  Future<void> _recoverLocalState() async {
    for (final object in objects) {
      if (workspace.libraryIndex[object.id] == null) await _writeIndex(object);
      await enqueueDefaultJobs(object);
    }
    await processPendingJobs();
  }

  List<LibraryObject> get objects =>
      workspace.libraryObjects.all.where((o) => !o.deleted).toList();

  final _duplicates = ArchiveDuplicateFinder();

  /// An item already in the Archive that saving this would repeat (see
  /// archive_duplicates.dart), or null. Uses local records only, so it works
  /// offline. Attachments are compared by their content hash: fill in
  /// `Asset.fileSha256` first (see CaptureService.hashAsset).
  ArchiveDuplicate? findDuplicate({
    String? sourceUrl,
    String? content,
    List<String> attachmentIds = const [],
  }) => _duplicates.find(
    objects: workspace.libraryObjects.all,
    assetOf: (id) => workspace.assets[id],
    sourceUrl: sourceUrl,
    contentHash: content == null
        ? null
        : sha256.convert(utf8.encode(content)).toString(),
    newAssets: [
      for (final id in attachmentIds)
        if (workspace.assets[id] != null) workspace.assets[id]!,
    ],
  );

  /// Saves an Archive item.
  ///
  /// When the same link, file content or text is already saved (a proven
  /// duplicate) and [allowDuplicate] is false, nothing new is created: the
  /// existing item is returned (and filed in [spaceId]). This keeps share
  /// imports and retried requests from piling up copies. Pass
  /// [allowDuplicate] after the user chose "Save anyway" to always create a
  /// new item. Existing items are never overwritten or removed.
  Future<LibraryObject> save({
    required LibraryObjectType type,
    String title = '',
    String? sourceUrl,
    String? content,
    String? description,
    List<String> attachmentIds = const [],
    String? thumbnailId,
    Map<String, dynamic> metadata = const {},
    String? spaceId,
    bool allowDuplicate = false,
  }) async => (await saveWithResult(
    type: type,
    title: title,
    sourceUrl: sourceUrl,
    content: content,
    description: description,
    attachmentIds: attachmentIds,
    thumbnailId: thumbnailId,
    metadata: metadata,
    spaceId: spaceId,
    allowDuplicate: allowDuplicate,
  )).object;

  /// Like [save], and also says whether an existing item was reused.
  Future<LibrarySaveResult> saveWithResult({
    required LibraryObjectType type,
    String title = '',
    String? sourceUrl,
    String? content,
    String? description,
    List<String> attachmentIds = const [],
    String? thumbnailId,
    Map<String, dynamic> metadata = const {},
    String? spaceId,
    bool allowDuplicate = false,
  }) async {
    final canonical = sourceUrl == null ? null : canonicalizeUrl(sourceUrl);
    if (sourceUrl != null && canonical == null) {
      throw ArgumentError.value(
        sourceUrl,
        'sourceUrl',
        'Expected a public http or https URL without credentials.',
      );
    }
    final hash = content == null
        ? null
        : sha256.convert(utf8.encode(content)).toString();
    // Only proven duplicates are reused; a name-and-size hint never is.
    // Checked and saved without an await in between, so two quick saves of
    // the same thing cannot both create an item.
    final match = allowDuplicate
        ? null
        : findDuplicate(
            sourceUrl: sourceUrl,
            content: content,
            attachmentIds: attachmentIds,
          );
    final duplicate = match != null && match.certain ? match.existing : null;
    final now = DateTime.now().toUtc();
    final object = duplicate == null
        ? LibraryObject(
            id: newId(),
            type: type,
            title: title,
            sourceUrl: sourceUrl,
            canonicalUrl: canonical,
            content: content,
            description: description,
            attachmentIds: attachmentIds,
            thumbnailId: thumbnailId,
            metadata: metadata,
            contentHash: hash,
            createdAt: now,
            updatedAt: now,
            lastSavedAt: now,
          )
        : duplicate.copyWith(lastSavedAt: now);
    workspace.libraryObjects.put(object);
    await workspace.libraryObjects.flush();
    for (final attachmentId in object.attachmentIds) {
      final relationId = '${object.id}.attachment.$attachmentId';
      workspace.libraryRelations.put(
        LibraryRelation(
          id: relationId,
          objectId: object.id,
          kind: 'attachment',
          targetId: attachmentId,
          updatedAt: now,
        ),
      );
    }
    await workspace.libraryRelations.flush();
    await _writeIndex(object);
    await workspace.libraryIndex.flush();
    if (spaceId != null) await addToRegularSpace(spaceId, object.id);
    if (duplicate == null) {
      await enqueueDefaultJobs(object);
      await workspace.libraryJobs.flush();
      // Saving is durable before any background work starts.
      processPendingJobs();
    }
    return LibrarySaveResult(
      object,
      duplicate == null ? null : ArchiveDuplicate(duplicate, match!.reason),
    );
  }

  Future<void> update(LibraryObject object) async {
    final updated = object.copyWith(
      updatedAt: DateTime.now().toUtc(),
      contentHash: object.content == null
          ? null
          : sha256.convert(utf8.encode(object.content!)).toString(),
    );
    workspace.libraryObjects.put(updated);
    await workspace.libraryObjects.flush();
    await _writeIndex(updated);
    await workspace.libraryIndex.flush();
  }

  Future<void> delete(String id) async {
    final item = workspace.libraryObjects[id];
    if (item == null || item.deleted) return;
    workspace.libraryObjects.put(item.copyWith(deleted: true));
    workspace.libraryIndex.remove(id);
    for (final r
        in workspace.libraryRelations.all
            .where((r) => r.objectId == id)
            .toList()) {
      if (r.kind == 'space') workspace.libraryRelations.remove(r.id);
    }
    await workspace.libraryObjects.flush();
    await workspace.libraryIndex.flush();
    await workspace.libraryRelations.flush();
  }

  Future<void> _writeIndex(LibraryObject o) async {
    final related = workspace.libraryRelations.all
        .where((r) => r.objectId == o.id)
        .map((r) => '${_tagName(r) ?? r.targetId} ${r.value.values.join(' ')}')
        .join(' ');
    final text = [
      o.title,
      o.description,
      o.summary,
      o.content,
      o.sourceUrl,
      o.canonicalUrl,
      o.mainEntity?.name,
      jsonEncode(o.metadata),
      related,
    ].whereType<String>().join('\n');
    workspace.libraryIndex.put(
      LibraryIndexEntry(
        id: o.id,
        objectId: o.id,
        text: text,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> enqueueDefaultJobs(LibraryObject o) async {
    // The only automatic work is local, deterministic extraction/indexing.
    final hasDocument = o.attachmentIds.any(
      (id) => workspace.assets[id]?.kind == AssetKind.document,
    );
    final stages = [
      LibraryJobStage.extract,
      LibraryJobStage.metadata,
      if (hasDocument) LibraryJobStage.ocr,
      LibraryJobStage.searchIndex,
    ];
    for (final stage in stages) {
      final id = '${o.id}.${stage.name}';
      if (workspace.libraryJobs[id] != null) continue;
      workspace.libraryJobs.put(
        LibraryProcessingJob(
          id: id,
          objectId: o.id,
          stage: stage,
          status: LibraryJobStatus.pending,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    }
  }

  Future<void> processPendingJobs() async {
    if (_processing) return;
    _processing = true;
    try {
      final due = workspace.libraryJobs.all
          .where(
            (j) =>
                (j.status == LibraryJobStatus.pending ||
                    j.status == LibraryJobStatus.retry) &&
                (j.nextAttemptAt == null ||
                    !j.nextAttemptAt!.isAfter(DateTime.now())),
          )
          .toList();
      for (final job in due) {
        final object = workspace.libraryObjects[job.objectId];
        if (object == null || object.deleted || job.cancelled) {
          workspace.libraryJobs.put(
            LibraryProcessingJob(
              id: job.id,
              objectId: job.objectId,
              stage: job.stage,
              status: LibraryJobStatus.cancelled,
              attempts: job.attempts,
              cancelled: true,
              updatedAt: DateTime.now().toUtc(),
            ),
          );
          continue;
        }
        workspace.libraryJobs.put(
          LibraryProcessingJob(
            id: job.id,
            objectId: job.objectId,
            stage: job.stage,
            status: LibraryJobStatus.running,
            attempts: job.attempts,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        try {
          if (job.stage == LibraryJobStage.metadata &&
              object.sourceUrl != null) {
            final host = Uri.tryParse(object.sourceUrl!)?.host;
            if (host != null && !object.metadata.containsKey('domain')) {
              await update(
                object.copyWith(metadata: {...object.metadata, 'domain': host}),
              );
            }
          } else if (job.stage == LibraryJobStage.ocr) {
            final assetIds = object.attachmentIds.toSet();
            final docs = workspace.assets.all
                .where(
                  (a) =>
                      assetIds.contains(a.id) && a.kind == AssetKind.document,
                )
                .toList();
            if (docs.isNotEmpty) {
              await onIndexDocuments?.call();
              final text = docs
                  .map((a) => indexedDocumentText?.call(a.id) ?? '')
                  .where((t) => t.trim().isNotEmpty)
                  .join('\n');
              if (text.isNotEmpty) {
                final current = workspace.libraryObjects[object.id] ?? object;
                await update(
                  current.copyWith(
                    content: [
                      current.content,
                      text,
                    ].whereType<String>().where((t) => t.isNotEmpty).join('\n'),
                  ),
                );
              }
              await _writeIndex(workspace.libraryObjects[object.id] ?? object);
              await workspace.libraryIndex.flush();
            }
          } else if (job.stage == LibraryJobStage.searchIndex) {
            await _writeIndex(object);
          }
          workspace.libraryJobs.put(
            LibraryProcessingJob(
              id: job.id,
              objectId: job.objectId,
              stage: job.stage,
              status: LibraryJobStatus.complete,
              attempts: job.attempts,
              updatedAt: DateTime.now().toUtc(),
            ),
          );
        } catch (e) {
          final attempts = job.attempts + 1;
          final permanent = e is FormatException || attempts >= 5;
          final status = permanent
              ? LibraryJobStatus.failed
              : LibraryJobStatus.retry;
          workspace.libraryJobs.put(
            LibraryProcessingJob(
              id: job.id,
              objectId: job.objectId,
              stage: job.stage,
              status: status,
              attempts: attempts,
              nextAttemptAt: status == LibraryJobStatus.retry
                  ? DateTime.now().add(Duration(seconds: 1 << attempts))
                  : null,
              error: '$e',
              updatedAt: DateTime.now().toUtc(),
            ),
          );
        }
      }
    } finally {
      _processing = false;
      _scheduleRetries();
    }
  }

  void _scheduleRetries() {
    _retryTimer?.cancel();
    final times = workspace.libraryJobs.all
        .where(
          (j) => j.status == LibraryJobStatus.retry && j.nextAttemptAt != null,
        )
        .map((j) => j.nextAttemptAt!)
        .toList();
    if (times.isEmpty) return;
    times.sort();
    final wait = times.first.difference(DateTime.now());
    _retryTimer = Timer(
      wait.isNegative ? Duration.zero : wait,
      processPendingJobs,
    );
  }

  Future<void> retryJob(String id) async {
    final job = workspace.libraryJobs[id];
    if (job == null) return;
    workspace.libraryJobs.put(
      LibraryProcessingJob(
        id: job.id,
        objectId: job.objectId,
        stage: job.stage,
        status: LibraryJobStatus.pending,
        attempts: 0,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    await processPendingJobs();
  }

  Future<void> Function()? onIndexDocuments;
  String? Function(String assetId)? indexedDocumentText;

  Future<LibrarySpace> createSpace(
    String name, {
    LibrarySpaceKind kind = LibrarySpaceKind.regular,
    String query = '',
  }) async {
    final space = LibrarySpace(
      id: newId(),
      name: name.trim(),
      kind: kind,
      query: query,
      updatedAt: DateTime.now().toUtc(),
    );
    workspace.librarySpaces.put(space);
    await workspace.librarySpaces.flush();
    return space;
  }

  Future<void> addToRegularSpace(String spaceId, String objectId) async {
    final space = workspace.librarySpaces[spaceId];
    if (space == null ||
        space.kind != LibrarySpaceKind.regular ||
        workspace.libraryObjects[objectId] == null) {
      return;
    }
    final id = '$spaceId.$objectId';
    workspace.libraryRelations.put(
      LibraryRelation(
        id: id,
        objectId: objectId,
        kind: 'space',
        targetId: spaceId,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    await workspace.libraryRelations.flush();
  }

  Future<void> removeFromRegularSpace(String spaceId, String objectId) async {
    workspace.libraryRelations.remove('$spaceId.$objectId');
    await workspace.libraryRelations.flush();
  }

  Future<void> setManualTag(String objectId, String tag) async {
    final cleaned = tag.trim();
    if (cleaned.isEmpty) return;
    final id = '$objectId.tag.${Uri.encodeComponent(cleaned.toLowerCase())}';
    workspace.libraryRelations.put(
      LibraryRelation(
        id: id,
        objectId: objectId,
        kind: 'tag',
        targetId: cleaned,
        origin: LibraryTagOrigin.manual,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    await workspace.libraryRelations.flush();
    final item = workspace.libraryObjects[objectId];
    if (item != null) await _writeIndex(item);
    await workspace.libraryIndex.flush();
  }

  /// The name of the custom tag a 'tag' relation points at, if it does.
  String? _tagName(LibraryRelation r) {
    if (r.kind != 'tag') return null;
    final id = CustomTag.idOfAssetRef(r.targetId);
    return id == null ? null : workspace.customTags[id]?.name;
  }

  /// Archive categories on [objectId]: ids of the five canonical [LinkTag]s.
  Set<String> categoriesOf(String objectId) => {
    for (final r in workspace.libraryRelations.all)
      if (r.objectId == objectId &&
          r.kind == 'category' &&
          LinkTag.byId(r.targetId) != null)
        r.targetId,
  };

  Future<void> setCategory(String objectId, String categoryId, bool on) async {
    final tag = LinkTag.byId(categoryId);
    if (tag == null || workspace.libraryObjects[objectId] == null) return;
    final id = '$objectId.category.$categoryId';
    if (on) {
      workspace.libraryRelations.put(
        LibraryRelation(
          id: id,
          objectId: objectId,
          kind: 'category',
          targetId: categoryId,
          value: {'label': tag.label},
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    } else {
      workspace.libraryRelations.remove(id);
    }
    await workspace.libraryRelations.flush();
    await _reindex(objectId);
  }

  /// Ids of the registry (custom) tags on [objectId] that still exist.
  Set<String> tagIdsOf(String objectId) => {
    for (final r in workspace.libraryRelations.all)
      if (r.objectId == objectId && r.kind == 'tag')
        if (CustomTag.idOfAssetRef(r.targetId) case final id?
            when workspace.customTags[id] != null)
          id,
  };

  /// Sets the custom tags of [objectId] to [tagIds] (ids from the shared tag
  /// registry; unknown ids are ignored). Older free-text tags stay as they are.
  Future<void> setTags(String objectId, Set<String> tagIds) async {
    if (workspace.libraryObjects[objectId] == null) return;
    for (final r
        in workspace.libraryRelations.all
            .where((r) => r.objectId == objectId && r.kind == 'tag')
            .toList()) {
      final id = CustomTag.idOfAssetRef(r.targetId);
      if (id != null && !tagIds.contains(id)) {
        workspace.libraryRelations.remove(r.id);
      }
    }
    for (final id in tagIds) {
      if (workspace.customTags[id] == null) continue;
      final ref = CustomTag.assetRef(id);
      workspace.libraryRelations.put(
        LibraryRelation(
          id: '$objectId.tag.${Uri.encodeComponent(ref)}',
          objectId: objectId,
          kind: 'tag',
          targetId: ref,
          origin: LibraryTagOrigin.manual,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    }
    await workspace.libraryRelations.flush();
    await _reindex(objectId);
  }

  Future<void> _reindex(String objectId) async {
    final item = workspace.libraryObjects[objectId];
    if (item != null) {
      await _writeIndex(item);
      await workspace.libraryIndex.flush();
    }
  }

  /// Library objects in [items] that carry every chosen category and tag.
  List<LibraryObject> withLabels(
    Iterable<LibraryObject> items, {
    Set<String> categories = const {},
    Set<String> tagIds = const {},
  }) => [
    for (final o in items)
      if (categoriesOf(o.id).containsAll(categories) &&
          tagIdsOf(o.id).containsAll(tagIds))
        o,
  ];

  Future<void> removeRelation(String relationId) async {
    final relation = workspace.libraryRelations[relationId];
    if (relation == null) return;
    workspace.libraryRelations.remove(relationId);
    await workspace.libraryRelations.flush();
    final item = workspace.libraryObjects[relation.objectId];
    if (item != null) {
      await _writeIndex(item);
      await workspace.libraryIndex.flush();
    }
  }

  Future<void> setUserNote(String objectId, String text) async {
    final id = '$objectId.note.user';
    if (text.trim().isEmpty) {
      workspace.libraryRelations.remove(id);
    } else {
      workspace.libraryRelations.put(
        LibraryRelation(
          id: id,
          objectId: objectId,
          kind: 'note',
          targetId: 'user',
          value: {'text': text},
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    }
    await workspace.libraryRelations.flush();
    final item = workspace.libraryObjects[objectId];
    if (item != null) await _writeIndex(item);
    await workspace.libraryIndex.flush();
  }

  List<LibraryObject> inSpace(String id) {
    final space = workspace.librarySpaces[id];
    if (space == null) return const [];
    if (space.kind == LibrarySpaceKind.regular) {
      final ids = workspace.libraryRelations.all
          .where((r) => r.kind == 'space' && r.targetId == id)
          .map((r) => r.objectId)
          .toSet();
      return objects.where((o) => ids.contains(o.id)).toList();
    }
    return search(space.query).items;
  }

  LibrarySearchResult search(String raw) {
    final parsed = LibraryQuery.parse(raw);
    if (parsed.error != null) {
      return LibrarySearchResult(const [], parsed.error!);
    }
    final byId = {for (final o in objects) o.id: o};
    final rows = workspace.libraryIndex.all.where(
      (r) => byId.containsKey(r.objectId),
    );
    final found = <(LibraryObject, int)>[];
    for (final row in rows) {
      final o = byId[row.objectId]!;
      if (parsed.type != null && o.type != parsed.type) continue;
      if (parsed.entity != null &&
          (o.mainEntity?.name.toLowerCase().contains(
                    parsed.entity!.toLowerCase(),
                  ) ??
                  false) ==
              false) {
        continue;
      }
      if (parsed.domain != null &&
          (Uri.tryParse(o.sourceUrl ?? '')?.host
                      .toLowerCase()
                      .endsWith(parsed.domain!.toLowerCase()) ??
                  false) ==
              false) {
        continue;
      }
      if (parsed.since != null && o.createdAt.isBefore(parsed.since!)) continue;
      if (parsed.color != null &&
          '${o.metadata['color'] ?? ''}'.toLowerCase() !=
              parsed.color!.toLowerCase()) {
        continue;
      }
      final lower = row.text.toLowerCase();
      if (parsed.tag != null && !lower.contains(parsed.tag!.toLowerCase())) {
        continue;
      }
      if (parsed.space != null) {
        final requested = workspace.librarySpaces.all
            .where(
              (sp) =>
                  sp.id == parsed.space ||
                  sp.name.toLowerCase() == parsed.space!.toLowerCase(),
            )
            .firstOrNull;
        if (requested == null) continue;
        if (requested.kind == LibrarySpaceKind.regular &&
            !workspace.libraryRelations.all.any(
              (r) =>
                  r.kind == 'space' &&
                  r.targetId == requested.id &&
                  r.objectId == o.id,
            )) {
          continue;
        }
        if (requested.kind == LibrarySpaceKind.smart &&
            !search(requested.query).items.any((item) => item.id == o.id)) {
          continue;
        }
      }
      if (parsed.excluded.any(lower.contains)) continue;
      final terms = parsed.terms;
      final hit = terms.where(lower.contains).length;
      if (terms.isNotEmpty &&
          (parsed.anyTerm ? hit == 0 : hit < terms.length)) {
        continue;
      }
      found.add((o, hit));
    }
    found.sort(
      (a, b) => b.$2.compareTo(a.$2) != 0
          ? b.$2.compareTo(a.$2)
          : b.$1.lastSavedAt?.compareTo(a.$1.lastSavedAt ?? a.$1.updatedAt) ??
                0,
    );
    return LibrarySearchResult(found.map((e) => e.$1).toList(), null);
  }

  static String? canonicalizeUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      return null;
    }
    if (uri.userInfo.isNotEmpty) return null;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final path = uri.path.isEmpty ? '/' : uri.path;
    final query = Map<String, String>.fromEntries(
      uri.queryParametersAll.entries
          .where(
            (e) => !e.key.toLowerCase().startsWith('utm_') && e.key != 'fbclid',
          )
          .map((e) => MapEntry(e.key, e.value.join(','))),
    );
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      host: host,
      path: path,
      queryParameters: query.isEmpty ? null : query,
    ).toString();
  }
}

/// What [LibraryRepository.saveWithResult] did: the saved item, and the
/// existing item that was reused instead of saving a copy (null when a new
/// item was created).
class LibrarySaveResult {
  const LibrarySaveResult(this.object, this.reused);
  final LibraryObject object;
  final ArchiveDuplicate? reused;
}

class LibrarySearchResult {
  const LibrarySearchResult(this.items, this.error);
  final List<LibraryObject> items;
  final String? error;
}

class LibraryQuery {
  const LibraryQuery({
    this.terms = const [],
    this.excluded = const [],
    this.type,
    this.entity,
    this.tag,
    this.domain,
    this.space,
    this.color,
    this.since,
    this.anyTerm = false,
    this.error,
  });
  final List<String> terms, excluded;
  final LibraryObjectType? type;
  final String? entity, tag, domain, space, color;
  final DateTime? since;
  final bool anyTerm;
  final String? error;
  static LibraryQuery parse(String raw) {
    final terms = <String>[], excluded = <String>[];
    LibraryObjectType? type;
    String? entity, tag, domain, space, color;
    DateTime? since;
    var any = false;
    final tokens = RegExp(r'"[^"]+"|\S+')
        .allMatches(raw)
        .map((m) => m.group(0)!)
        .toList();
    for (var token in tokens) {
      if (token == 'OR') {
        any = true;
        continue;
      }
      if (token == 'AND') continue;
      final neg = token.startsWith('-');
      if (neg) token = token.substring(1);
      final sep = token.indexOf(':');
      if (sep < 0) {
        (neg ? excluded : terms).add(token.replaceAll('"', '').toLowerCase());
        continue;
      }
      final key = token.substring(0, sep).toLowerCase(),
          value = token.substring(sep + 1).replaceAll('"', '');
      if (value.isEmpty) return LibraryQuery(error: 'Add a value after $key:.');
      switch (key) {
        case 'type':
          type = LibraryObjectType.values
              .where((e) => e.name == value.toLowerCase())
              .firstOrNull;
          if (type == null) {
            return LibraryQuery(error: 'Unknown object type "$value".');
          }
        case 'object':
          entity = value;
        case 'tag':
          tag = value;
        case 'domain':
          domain = value;
        case 'space':
          space = value;
        case 'color':
          color = value;
        case 'after':
          since = DateTime.tryParse(value);
          if (since == null) {
            return LibraryQuery(error: 'Use after:YYYY-MM-DD.');
          }
        default:
          return LibraryQuery(error: 'Unknown filter "$key:".');
      }
    }
    return LibraryQuery(
      terms: terms,
      excluded: excluded,
      type: type,
      entity: entity,
      tag: tag,
      domain: domain,
      space: space,
      color: color,
      since: since,
      anyTerm: any,
    );
  }
}
