// The user's own tags, one registry shared by the Archive and the Mindmap
// (the same tag is never defined twice). Synced like other records
// ("custom_tags"). Where a tag is used, only its id is stored: on an
// Archive resource in `linkTags` as "tag:<id>" (next to the fixed
// category ids), on a mindmap item in its "customTags" mark. Renaming or
// recolouring a tag therefore changes it everywhere at once, and a
// deleted tag is simply no longer shown (its id is never reused).
import 'record.dart';

class CustomTag implements Record {
  const CustomTag({
    required this.id,
    required this.name,
    required this.color,
    required this.createdAt,
    required this.updatedAt,
  });

  @override
  final String id;
  final String name;

  /// ARGB colour chosen by the user.
  final int color;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;

  static const maxNameLength = 40;

  /// Most custom tags that can exist (the Archive and the Mindmap share
  /// one registry). An existing tag can always be reused or deleted.
  static const maxTags = 15;

  /// How a tag id is written into an Archive resource's `linkTags`.
  static String assetRef(String id) => 'tag:$id';

  /// The tag id in a `linkTags` entry, or null for a fixed category.
  static String? idOfAssetRef(String ref) =>
      ref.startsWith('tag:') ? ref.substring(4) : null;

  /// A name as typed, tidied: trimmed, inner spaces collapsed.
  static String clean(String name) =>
      name.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// The key two names must share to be "the same tag": case-insensitive
  /// in any script, with the Turkish dotted/dotless i treated as one
  /// letter (so "Işık", "IŞIK" and "ışık" are one tag, and so are
  /// "Ideas" and "İdeas").
  static String keyOf(String name) => clean(name)
      .toLowerCase()
      .replaceAll(
        'i${String.fromCharCode(0x0307)}',
        'i',
      ) // "İ".toLowerCase() is i + combining dot
      .replaceAll('ı', 'i');

  /// Why [name] cannot be a tag name, or null.
  static String? problemWith(String name) {
    final n = clean(name);
    if (n.isEmpty) return 'Type a name for the tag.';
    if (n.runes.length > maxNameLength) {
      return 'Tag names can be at most $maxNameLength characters.';
    }
    return null;
  }

  CustomTag copyWith({String? name, int? color}) => CustomTag(
    id: id,
    name: name ?? this.name,
    color: color ?? this.color,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': color,
    'createdAt': utcIso(createdAt),
    'updatedAt': utcIso(updatedAt),
  };

  factory CustomTag.fromJson(Map<String, dynamic> j) => CustomTag(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    color: (j['color'] as num?)?.toInt() ?? 0xFF8AB4F8,
    createdAt: parseDate(j['createdAt']) ?? DateTime.now(),
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}
