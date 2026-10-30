import 'record.dart';

enum LibraryObjectType {
  image,
  article,
  website,
  document,
  note,
  product,
  book,
  video,
  file,
  other,
}

enum LibraryEntityType { person, place, product, book, organization, concept, other }
enum LibraryTagOrigin { manual, ai }
enum LibrarySpaceKind { regular, smart }
enum LibraryJobStage {
  extract,
  metadata,
  thumbnail,
  searchIndex,
  ocr,
  aiEnrichment,
  embedding,
}
enum LibraryJobStatus { pending, running, retry, complete, failed, cancelled }

/// A saved item is independent of its format and of the entity it describes.
class LibraryObject implements Record {
  const LibraryObject({
    required this.id,
    required this.type,
    required this.createdAt,
    required this.updatedAt,
    this.title = '',
    this.sourceUrl,
    this.canonicalUrl,
    this.content,
    this.description,
    this.summary,
    this.mainEntity,
    this.metadata = const {},
    this.attachmentIds = const [],
    this.thumbnailId,
    this.screenshotId,
    this.contentHash,
    this.lastSavedAt,
    this.processing = const {},
    this.schemaVersion = 1,
    this.deleted = false,
  });

  @override final String id;
  final LibraryObjectType type;
  final String title;
  final String? sourceUrl;
  final String? canonicalUrl;
  final String? content;
  final String? description;
  final String? summary;
  final LibraryEntity? mainEntity;
  final Map<String, dynamic> metadata;
  final List<String> attachmentIds;
  final String? thumbnailId;
  final String? screenshotId;
  @override final DateTime updatedAt;
  final DateTime createdAt;
  final DateTime? lastSavedAt;
  final String? contentHash;
  final Map<String, String> processing;
  final int schemaVersion;
  final bool deleted;

  LibraryObject copyWith({String? title, String? content, String? description,
    String? summary, LibraryEntity? mainEntity, Map<String, dynamic>? metadata,
    List<String>? attachmentIds, String? thumbnailId, String? screenshotId, String? contentHash,
    DateTime? lastSavedAt, Map<String, String>? processing, bool? deleted,
    DateTime? updatedAt}) => LibraryObject(
      id: id, type: type, title: title ?? this.title, sourceUrl: sourceUrl,
      canonicalUrl: canonicalUrl, content: content ?? this.content,
      description: description ?? this.description, summary: summary ?? this.summary,
      mainEntity: mainEntity ?? this.mainEntity, metadata: metadata ?? this.metadata,
      attachmentIds: attachmentIds ?? this.attachmentIds,
      thumbnailId: thumbnailId ?? this.thumbnailId, screenshotId: screenshotId ?? this.screenshotId,
      createdAt: createdAt, updatedAt: updatedAt ?? DateTime.now().toUtc(),
      lastSavedAt: lastSavedAt ?? this.lastSavedAt, contentHash: contentHash ?? this.contentHash,
      processing: processing ?? this.processing, schemaVersion: schemaVersion,
      deleted: deleted ?? this.deleted,
    );

  @override Map<String, dynamic> toJson() => {
    'id': id, 'type': type.name, 'title': title, 'sourceUrl': sourceUrl,
    'canonicalUrl': canonicalUrl, 'content': content, 'description': description,
    'summary': summary, 'mainEntity': mainEntity?.toJson(), 'metadata': metadata,
    'attachmentIds': attachmentIds, 'thumbnailId': thumbnailId,
    'screenshotId': screenshotId, 'createdAt': utcIso(createdAt),
    'updatedAt': utcIso(updatedAt), 'lastSavedAt': lastSavedAt == null ? null : utcIso(lastSavedAt!),
    'contentHash': contentHash, 'processing': processing,
    'schemaVersion': schemaVersion, 'deleted': deleted,
  };

  factory LibraryObject.fromJson(Map<String, dynamic> j) => LibraryObject(
    id: j['id'] as String, type: LibraryObjectType.values.firstWhere(
      (e) => e.name == j['type'], orElse: () => LibraryObjectType.other),
    title: j['title'] as String? ?? '', sourceUrl: j['sourceUrl'] as String?,
    canonicalUrl: j['canonicalUrl'] as String?, content: j['content'] as String?,
    description: j['description'] as String?, summary: j['summary'] as String?,
    mainEntity: j['mainEntity'] is Map ? LibraryEntity.fromJson((j['mainEntity'] as Map).cast<String, dynamic>()) : null,
    metadata: (j['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
    attachmentIds: [for (final x in (j['attachmentIds'] as List?) ?? const []) if (x is String) x],
    thumbnailId: j['thumbnailId'] as String?, screenshotId: j['screenshotId'] as String?,
    createdAt: parseDate(j['createdAt']) ?? DateTime.now().toUtc(),
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now().toUtc(),
    lastSavedAt: parseDate(j['lastSavedAt']), contentHash: j['contentHash'] as String?,
    processing: (j['processing'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const {},
    schemaVersion: (j['schemaVersion'] as num?)?.toInt() ?? 1, deleted: j['deleted'] == true,
  );
}

class LibraryEntity {
  const LibraryEntity({required this.type, required this.name, this.properties = const {}});
  final LibraryEntityType type;
  final String name;
  final Map<String, dynamic> properties;
  Map<String, dynamic> toJson() => {'type': type.name, 'name': name, 'properties': properties};
  factory LibraryEntity.fromJson(Map<String, dynamic> j) => LibraryEntity(
    type: LibraryEntityType.values.firstWhere((e) => e.name == j['type'], orElse: () => LibraryEntityType.other),
    name: j['name'] as String? ?? '', properties: (j['properties'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}

class LibraryRelation implements Record {
  const LibraryRelation({required this.id, required this.objectId, required this.kind,
    required this.targetId, required this.updatedAt, this.origin, this.confidence, this.value = const {}});
  @override final String id;
  final String objectId, kind, targetId;
  final LibraryTagOrigin? origin;
  final double? confidence;
  final Map<String, dynamic> value;
  @override final DateTime updatedAt;
  @override Map<String, dynamic> toJson() => {'id':id,'objectId':objectId,'kind':kind,'targetId':targetId,
    'origin':origin?.name,'confidence':confidence,'value':value,'updatedAt':utcIso(updatedAt)};
  factory LibraryRelation.fromJson(Map<String,dynamic> j) => LibraryRelation(id:j['id'] as String,
    objectId:j['objectId'] as String,kind:j['kind'] as String? ?? 'attachment',targetId:j['targetId'] as String? ?? '',
    origin: LibraryTagOrigin.values.where((e)=>e.name==j['origin']).firstOrNull,
    confidence:(j['confidence'] as num?)?.toDouble(),value:(j['value'] as Map?)?.cast<String,dynamic>() ?? const {},
    updatedAt:parseDate(j['updatedAt']) ?? DateTime.now().toUtc());
}

class LibrarySpace implements Record {
  const LibrarySpace({required this.id,required this.name,required this.kind,required this.updatedAt,this.query = ''});
  @override final String id; final String name; final LibrarySpaceKind kind; final String query;
  @override final DateTime updatedAt;
  LibrarySpace copyWith({String? name,String? query})=>LibrarySpace(id:id,name:name??this.name,kind:kind,query:query??this.query,updatedAt:DateTime.now().toUtc());
  @override Map<String,dynamic> toJson()=>{'id':id,'name':name,'kind':kind.name,'query':query,'updatedAt':utcIso(updatedAt)};
  factory LibrarySpace.fromJson(Map<String,dynamic> j)=>LibrarySpace(id:j['id'] as String,name:j['name'] as String? ?? '',
    kind:LibrarySpaceKind.values.where((e)=>e.name==j['kind']).firstOrNull ?? LibrarySpaceKind.regular,
    query:j['query'] as String? ?? '',updatedAt:parseDate(j['updatedAt']) ?? DateTime.now().toUtc());
}

class LibraryIndexEntry implements Record {
  const LibraryIndexEntry({required this.id,required this.objectId,required this.text,required this.updatedAt});
  @override final String id; final String objectId, text; @override final DateTime updatedAt;
  @override Map<String,dynamic> toJson()=>{'id':id,'objectId':objectId,'text':text,'updatedAt':utcIso(updatedAt)};
  factory LibraryIndexEntry.fromJson(Map<String,dynamic> j)=>LibraryIndexEntry(id:j['id'] as String,objectId:j['objectId'] as String,
    text:j['text'] as String? ?? '',updatedAt:parseDate(j['updatedAt']) ?? DateTime.now().toUtc());
}

class LibraryProcessingJob implements Record {
  const LibraryProcessingJob({required this.id,required this.objectId,required this.stage,required this.status,
    required this.updatedAt,this.attempts=0,this.nextAttemptAt,this.error,this.cancelled=false});
  @override final String id; final String objectId; final LibraryJobStage stage; final LibraryJobStatus status;
  final int attempts; final DateTime? nextAttemptAt; final String? error; final bool cancelled; @override final DateTime updatedAt;
  @override Map<String,dynamic> toJson()=>{'id':id,'objectId':objectId,'stage':stage.name,'status':status.name,'attempts':attempts,
    'nextAttemptAt':nextAttemptAt == null ? null : utcIso(nextAttemptAt!), 'error':error,'cancelled':cancelled,'updatedAt':utcIso(updatedAt)};
  factory LibraryProcessingJob.fromJson(Map<String,dynamic> j)=>LibraryProcessingJob(id:j['id'] as String,objectId:j['objectId'] as String,
    stage:LibraryJobStage.values.firstWhere((e)=>e.name==j['stage'],orElse:()=>LibraryJobStage.extract),
    status:LibraryJobStatus.values.firstWhere((e)=>e.name==j['status'],orElse:()=>LibraryJobStatus.pending),
    attempts:(j['attempts'] as num?)?.toInt() ?? 0,nextAttemptAt:parseDate(j['nextAttemptAt']),error:j['error'] as String?,cancelled:j['cancelled']==true,
    updatedAt:parseDate(j['updatedAt']) ?? DateTime.now().toUtc());
}
