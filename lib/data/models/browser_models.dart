// Browser records kept on this device (not synced): bookmarks (with
// folders), history and site permission decisions. Private tabs never
// write history.
import 'record.dart';

class Bookmark implements Record {
  const Bookmark({
    required this.id,
    required this.title,
    required this.url,
    required this.updatedAt,
    this.folder = '',
  });

  @override
  final String id;
  final String title;
  final String url;

  /// Folder path, "Study/Biology" ('' = top level).
  final String folder;
  @override
  final DateTime updatedAt;

  Bookmark copyWith({String? title, String? url, String? folder}) => Bookmark(
    id: id,
    title: title ?? this.title,
    url: url ?? this.url,
    folder: folder ?? this.folder,
    updatedAt: DateTime.now(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    if (folder.isNotEmpty) 'folder': folder,
    'updatedAt': utcIso(updatedAt),
  };

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    url: j['url'] as String? ?? '',
    folder: j['folder'] as String? ?? '',
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}

class HistoryEntry implements Record {
  const HistoryEntry({
    required this.id,
    required this.url,
    required this.title,
    required this.visitedAt,
  });

  @override
  final String id;
  final String url;
  final String title;
  final DateTime visitedAt;

  @override
  DateTime get updatedAt => visitedAt;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'title': title,
    'visitedAt': utcIso(visitedAt),
  };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
    id: j['id'] as String,
    url: j['url'] as String? ?? '',
    title: j['title'] as String? ?? '',
    visitedAt: parseDate(j['visitedAt']) ?? DateTime.now(),
  );
}

/// What the user decided for one site and one kind of access.
class SitePermission implements Record {
  const SitePermission({
    required this.id,
    required this.host,
    required this.kind,
    required this.allowed,
    required this.updatedAt,
  });

  /// `host|kind`.
  @override
  final String id;
  final String host;

  /// "camera", "microphone", "location", "popups", "external".
  final String kind;
  final bool allowed;
  @override
  final DateTime updatedAt;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'host': host,
    'kind': kind,
    'allowed': allowed,
    'updatedAt': utcIso(updatedAt),
  };

  factory SitePermission.fromJson(Map<String, dynamic> j) => SitePermission(
    id: j['id'] as String,
    host: j['host'] as String? ?? '',
    kind: j['kind'] as String? ?? '',
    allowed: j['allowed'] == true,
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}
