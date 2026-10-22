import 'record.dart';

/// `document` (PDF) files are stored and synced like photos and open in
/// the default viewer; older app versions skip them as unreadable records.
enum AssetKind { link, image, document }

/// A captured link or image, stored once and referenced from anywhere
/// (canvas cards, notes, calendar days and entries) by its id.
class Asset implements Record {
  const Asset({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.updatedAt,
    this.url,
    this.title,
    this.description,
    this.siteName,
    this.file,
    this.previewFile,
    this.width,
    this.height,
    this.fileSha256,
    this.fileSize,
    this.previewSha256,
    this.previewSize,
  });

  @override
  final String id;
  final AssetKind kind;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;

  /// Link target (links only).
  final String? url;
  final String? title;
  final String? description;
  final String? siteName;

  /// Image file name inside the attachments folder (images only).
  final String? file;

  /// Downloaded preview image for a link, inside the attachments folder.
  final String? previewFile;

  /// Pixel size of the image (or preview image).
  final int? width;
  final int? height;

  /// SHA-256 (hex) and byte size of [file] and [previewFile], filled in
  /// before syncing so transfers can be checked and identical files are
  /// stored once on the hub.
  final String? fileSha256;
  final int? fileSize;
  final String? previewSha256;
  final int? previewSize;

  /// What to show as a one-line name.
  String get label {
    if (title != null && title!.trim().isNotEmpty) return title!.trim();
    if (url != null) return displayUrl(url!);
    return kind == AssetKind.document ? 'Document' : 'Image';
  }

  Asset copyWith({
    String? title,
    String? description,
    String? siteName,
    String? previewFile,
    int? width,
    int? height,
    String? fileSha256,
    int? fileSize,
    String? previewSha256,
    int? previewSize,
  }) => Asset(
    id: id,
    kind: kind,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
    url: url,
    file: file,
    title: title ?? this.title,
    description: description ?? this.description,
    siteName: siteName ?? this.siteName,
    previewFile: previewFile ?? this.previewFile,
    width: width ?? this.width,
    height: height ?? this.height,
    fileSha256: fileSha256 ?? this.fileSha256,
    fileSize: fileSize ?? this.fileSize,
    previewSha256: previewSha256 ?? this.previewSha256,
    previewSize: previewSize ?? this.previewSize,
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'createdAt': utcIso(createdAt),
    'updatedAt': utcIso(updatedAt),
    'url': url,
    'title': title,
    'description': description,
    'siteName': siteName,
    'file': file,
    'previewFile': previewFile,
    'width': width,
    'height': height,
    'fileSha256': ?fileSha256,
    'fileSize': ?fileSize,
    'previewSha256': ?previewSha256,
    'previewSize': ?previewSize,
  };

  factory Asset.fromJson(Map<String, dynamic> j) => Asset(
    id: j['id'] as String,
    kind: AssetKind.values.byName(j['kind'] as String),
    createdAt: parseDate(j['createdAt']) ?? DateTime.now(),
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
    url: j['url'] as String?,
    title: j['title'] as String?,
    description: j['description'] as String?,
    siteName: j['siteName'] as String?,
    file: j['file'] as String?,
    previewFile: j['previewFile'] as String?,
    width: j['width'] as int?,
    height: j['height'] as int?,
    fileSha256: j['fileSha256'] as String?,
    fileSize: j['fileSize'] as int?,
    previewSha256: j['previewSha256'] as String?,
    previewSize: j['previewSize'] as int?,
  );
}

/// `https://www.example.com/a/b?x` → `example.com/a/b`
String displayUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  final host = uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
  final path = uri.path == '/' ? '' : uri.path;
  return '$host$path';
}

/// Detects a single web address in pasted text.
String? extractUrl(String text) {
  final trimmed = text.trim();
  if (trimmed.contains(RegExp(r'\s'))) return null;
  var candidate = trimmed;
  if (RegExp(r'^www\.', caseSensitive: false).hasMatch(candidate)) {
    candidate = 'https://$candidate';
  }
  final uri = Uri.tryParse(candidate);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  return uri.host.contains('.') || uri.host == 'localhost' ? candidate : null;
}

class Folder implements Record {
  const Folder({
    required this.id,
    required this.name,
    required this.updatedAt,
    this.parentId,
  });

  @override
  final String id;
  final String name;
  final String? parentId;
  @override
  final DateTime updatedAt;

  Folder copyWith({String? name, String? Function()? parentId}) => Folder(
    id: id,
    name: name ?? this.name,
    parentId: parentId != null ? parentId() : this.parentId,
    updatedAt: DateTime.now(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
    'updatedAt': utcIso(updatedAt),
  };

  factory Folder.fromJson(Map<String, dynamic> j) => Folder(
    id: j['id'] as String,
    name: j['name'] as String,
    parentId: j['parentId'] as String?,
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}

/// An earlier version of a note (version history). Kept on this device:
/// made whenever the note's text is replaced, here or by a synced change.
class NoteVersion implements Record {
  const NoteVersion({
    required this.id,
    required this.noteId,
    required this.title,
    required this.body,
    required this.savedAt,
  });

  @override
  final String id;
  final String noteId;
  final String title;
  final String body;

  /// When this version was set aside.
  final DateTime savedAt;

  @override
  DateTime get updatedAt => savedAt;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'noteId': noteId,
    'title': title,
    'body': body,
    'savedAt': utcIso(savedAt),
  };

  factory NoteVersion.fromJson(Map<String, dynamic> j) => NoteVersion(
    id: j['id'] as String,
    noteId: j['noteId'] as String,
    title: j['title'] as String? ?? '',
    body: j['body'] as String? ?? '',
    savedAt: parseDate(j['savedAt']) ?? DateTime.now(),
  );
}

class Note implements Record {
  const Note({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    this.folderId,
    this.tags = const [],
    this.favorite = false,
    this.assetIds = const [],
  });

  @override
  final String id;
  final String title;
  final String body;
  final String? folderId;
  final List<String> tags;
  final bool favorite;

  /// Links and images attached to this note (shared [Asset] records).
  final List<String> assetIds;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;

  String get displayTitle =>
      title.trim().isEmpty ? 'Untitled note' : title.trim();

  /// `[[Other note]]` references inside the body.
  Iterable<String> get linkedTitles =>
      RegExp(r'\[\[([^\[\]]+)\]\]')
          .allMatches(body)
          .map((m) => m.group(1)!.trim());

  Note copyWith({
    String? title,
    String? body,
    String? Function()? folderId,
    List<String>? tags,
    bool? favorite,
    List<String>? assetIds,
  }) => Note(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    folderId: folderId != null ? folderId() : this.folderId,
    tags: tags ?? this.tags,
    favorite: favorite ?? this.favorite,
    assetIds: assetIds ?? this.assetIds,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'folderId': folderId,
    'tags': tags,
    'favorite': favorite,
    'assetIds': assetIds,
    'createdAt': utcIso(createdAt),
    'updatedAt': utcIso(updatedAt),
  };

  factory Note.fromJson(Map<String, dynamic> j) => Note(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    body: j['body'] as String? ?? '',
    folderId: j['folderId'] as String?,
    tags: [...?(j['tags'] as List?)?.cast<String>()],
    favorite: j['favorite'] as bool? ?? false,
    assetIds: [...?(j['assetIds'] as List?)?.cast<String>()],
    createdAt: parseDate(j['createdAt']) ?? DateTime.now(),
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}

/// Something captured (e.g. via Windows "Send to") that has not been filed
/// into Canvas, Notes or Calendar yet.
class InboxItem implements Record {
  const InboxItem({
    required this.id,
    required this.createdAt,
    this.text,
    this.assetId,
  });

  @override
  final String id;
  final String? text;
  final String? assetId;
  final DateTime createdAt;
  @override
  DateTime get updatedAt => createdAt;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'assetId': assetId,
    'createdAt': utcIso(createdAt),
  };

  factory InboxItem.fromJson(Map<String, dynamic> j) => InboxItem(
    id: j['id'] as String,
    text: j['text'] as String?,
    assetId: j['assetId'] as String?,
    createdAt: parseDate(j['createdAt']) ?? DateTime.now(),
  );
}
