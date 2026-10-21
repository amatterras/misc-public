import 'dart:math' as math;
import 'dart:ui';

import 'record.dart' show utcIso;

/// Generates a reasonably unique id without extra dependencies.
String newId() {
  final rand = math.Random();
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final suffix = rand.nextInt(1 << 32).toRadixString(36);
  return '$time$suffix';
}

/// Base type for everything placed on a canvas.
///
/// Items are immutable: every edit produces a new instance. This keeps
/// undo/redo simple (history is just a list of item lists) and makes
/// future sync/conflict handling easier.
sealed class CanvasItem {
  const CanvasItem({required this.id});

  final String id;

  /// Stored world-space bounds. Boxes may render taller to fit content;
  /// the controller computes the real on-screen bounds.
  Rect get bounds;

  CanvasItem translated(Offset delta);

  /// Same content with a new id (used by duplicate and paste).
  CanvasItem withId(String id);

  Map<String, dynamic> toJson();

  static CanvasItem fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'text':
        return TextItem.fromJson(json);
      case 'stroke':
        return StrokeItem.fromJson(json);
      case 'image':
        return ImageItem.fromJson(json);
      case 'link':
        return LinkItem.fromJson(json);
      case 'noteCard':
        return NoteCardItem.fromJson(json);
      default:
        throw FormatException('Unknown canvas item type: ${json['type']}');
    }
  }
}

/// Items that are rectangles with a position and a size.
sealed class BoxItem extends CanvasItem {
  const BoxItem({
    required super.id,
    required this.position,
    required this.width,
    required this.minHeight,
  });

  final Offset position;
  final double width;

  /// The box is at least this tall; text-like boxes grow to fit content.
  final double minHeight;

  @override
  Rect get bounds => position & Size(width, minHeight);

  BoxItem withBox({Offset? position, double? width, double? minHeight});

  @override
  BoxItem translated(Offset delta) => withBox(position: position + delta);
}

enum TextAlignment { left, center, right }

class TextItem extends BoxItem {
  const TextItem({
    required super.id,
    required super.position,
    required super.width,
    required super.minHeight,
    required this.text,
    this.fontSize = 16,
    this.bold = false,
    this.italic = false,
    this.align = TextAlignment.left,
    this.textColor,
    this.background,
  });

  static const double defaultWidth = 260;
  static const double minWidth = 60;

  final String text;
  final double fontSize;
  final bool bold;
  final bool italic;
  final TextAlignment align;

  /// Null means the default text colour.
  final Color? textColor;

  /// Null means no card behind the text.
  final Color? background;

  TextItem copyWith({
    Offset? position,
    double? width,
    double? minHeight,
    String? text,
    double? fontSize,
    bool? bold,
    bool? italic,
    TextAlignment? align,
    Color? Function()? textColor,
    Color? Function()? background,
  }) {
    return TextItem(
      id: id,
      position: position ?? this.position,
      width: width ?? this.width,
      minHeight: minHeight ?? this.minHeight,
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      align: align ?? this.align,
      textColor: textColor != null ? textColor() : this.textColor,
      background: background != null ? background() : this.background,
    );
  }

  @override
  TextItem withBox({Offset? position, double? width, double? minHeight}) =>
      copyWith(position: position, width: width, minHeight: minHeight);

  @override
  TextItem translated(Offset delta) => copyWith(position: position + delta);

  @override
  TextItem withId(String id) => TextItem(
    id: id,
    position: position,
    width: width,
    minHeight: minHeight,
    text: text,
    fontSize: fontSize,
    bold: bold,
    italic: italic,
    align: align,
    textColor: textColor,
    background: background,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'text',
    'id': id,
    'x': position.dx,
    'y': position.dy,
    'w': width,
    'h': minHeight,
    'text': text,
    'fontSize': fontSize,
    if (bold) 'bold': true,
    if (italic) 'italic': true,
    if (align != TextAlignment.left) 'align': align.name,
    if (textColor != null) 'textColor': textColor!.toARGB32(),
    if (background != null) 'background': background!.toARGB32(),
  };

  factory TextItem.fromJson(Map<String, dynamic> json) => TextItem(
    id: json['id'] as String,
    position: Offset(
      (json['x'] as num).toDouble(),
      (json['y'] as num).toDouble(),
    ),
    width: (json['w'] as num).toDouble(),
    minHeight: (json['h'] as num).toDouble(),
    text: json['text'] as String,
    fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16,
    bold: json['bold'] as bool? ?? false,
    italic: json['italic'] as bool? ?? false,
    align: TextAlignment.values.byName(json['align'] as String? ?? 'left'),
    textColor: json['textColor'] == null
        ? null
        : Color(json['textColor'] as int),
    background: json['background'] == null
        ? null
        : Color(json['background'] as int),
  );
}

/// A photo placed on the canvas; the file lives in the attachments folder
/// and is described by a shared Asset record.
class ImageItem extends BoxItem {
  const ImageItem({
    required super.id,
    required super.position,
    required super.width,
    required super.minHeight,
    required this.assetId,
  });

  final String assetId;
  double get height => minHeight;

  @override
  ImageItem withBox({Offset? position, double? width, double? minHeight}) =>
      ImageItem(
        id: id,
        assetId: assetId,
        position: position ?? this.position,
        width: width ?? this.width,
        minHeight: minHeight ?? this.minHeight,
      );

  @override
  ImageItem withId(String id) => ImageItem(
    id: id,
    assetId: assetId,
    position: position,
    width: width,
    minHeight: minHeight,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'id': id,
    'assetId': assetId,
    'x': position.dx,
    'y': position.dy,
    'w': width,
    'h': minHeight,
  };

  factory ImageItem.fromJson(Map<String, dynamic> j) => ImageItem(
    id: j['id'] as String,
    assetId: j['assetId'] as String,
    position: Offset((j['x'] as num).toDouble(), (j['y'] as num).toDouble()),
    width: (j['w'] as num).toDouble(),
    minHeight: (j['h'] as num).toDouble(),
  );
}

/// A compact link card; the URL, title and preview live in a shared Asset.
class LinkItem extends BoxItem {
  const LinkItem({
    required super.id,
    required super.position,
    required super.width,
    required this.assetId,
    super.minHeight = 0,
  });

  static const double defaultWidth = 300;
  final String assetId;

  @override
  LinkItem withBox({Offset? position, double? width, double? minHeight}) =>
      LinkItem(
        id: id,
        assetId: assetId,
        position: position ?? this.position,
        width: width ?? this.width,
        minHeight: minHeight ?? this.minHeight,
      );

  @override
  LinkItem withId(String id) => LinkItem(
    id: id,
    assetId: assetId,
    position: position,
    width: width,
    minHeight: minHeight,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'link',
    'id': id,
    'assetId': assetId,
    'x': position.dx,
    'y': position.dy,
    'w': width,
    'h': minHeight,
  };

  factory LinkItem.fromJson(Map<String, dynamic> j) => LinkItem(
    id: j['id'] as String,
    assetId: j['assetId'] as String,
    position: Offset((j['x'] as num).toDouble(), (j['y'] as num).toDouble()),
    width: (j['w'] as num).toDouble(),
    minHeight: (j['h'] as num?)?.toDouble() ?? 0,
  );
}

/// A card that shows an existing Note (by reference, not a copy).
class NoteCardItem extends BoxItem {
  const NoteCardItem({
    required super.id,
    required super.position,
    required super.width,
    required this.noteId,
    super.minHeight = 0,
  });

  final String noteId;

  @override
  NoteCardItem withBox({Offset? position, double? width, double? minHeight}) =>
      NoteCardItem(
        id: id,
        noteId: noteId,
        position: position ?? this.position,
        width: width ?? this.width,
        minHeight: minHeight ?? this.minHeight,
      );

  @override
  NoteCardItem withId(String id) => NoteCardItem(
    id: id,
    noteId: noteId,
    position: position,
    width: width,
    minHeight: minHeight,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'noteCard',
    'id': id,
    'noteId': noteId,
    'x': position.dx,
    'y': position.dy,
    'w': width,
    'h': minHeight,
  };

  factory NoteCardItem.fromJson(Map<String, dynamic> j) => NoteCardItem(
    id: j['id'] as String,
    noteId: j['noteId'] as String,
    position: Offset((j['x'] as num).toDouble(), (j['y'] as num).toDouble()),
    width: (j['w'] as num).toDouble(),
    minHeight: (j['h'] as num?)?.toDouble() ?? 0,
  );
}

/// One sampled point of a freehand stroke.
///
/// [pressure] is stored now so pen/stylus input (e.g. Apple Pencil) can use
/// it later without a data migration. Mouse input records 0.5.
class StrokePoint {
  const StrokePoint(this.x, this.y, [this.pressure = 0.5]);

  final double x;
  final double y;
  final double pressure;

  Offset get offset => Offset(x, y);

  List<double> toJson() => [x, y, pressure];

  factory StrokePoint.fromJson(List<dynamic> json) => StrokePoint(
    (json[0] as num).toDouble(),
    (json[1] as num).toDouble(),
    json.length > 2 ? (json[2] as num).toDouble() : 0.5,
  );
}

class StrokeItem extends CanvasItem {
  StrokeItem({
    required super.id,
    required this.points,
    required this.color,
    required this.strokeWidth,
  }) : bounds = _computeBounds(points, strokeWidth);

  final List<StrokePoint> points;
  final Color color;
  final double strokeWidth;

  @override
  final Rect bounds;

  static Rect _computeBounds(List<StrokePoint> points, double width) {
    if (points.isEmpty) return Rect.zero;
    var minX = points.first.x, maxX = points.first.x;
    var minY = points.first.y, maxY = points.first.y;
    for (final p in points) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY).inflate(width / 2);
  }

  @override
  StrokeItem translated(Offset delta) => StrokeItem(
    id: id,
    points: [
      for (final p in points)
        StrokePoint(p.x + delta.dx, p.y + delta.dy, p.pressure),
    ],
    color: color,
    strokeWidth: strokeWidth,
  );

  @override
  StrokeItem withId(String id) => StrokeItem(
    id: id,
    points: points,
    color: color,
    strokeWidth: strokeWidth,
  );

  /// Whether [point] lies within [tolerance] of any segment of this stroke.
  bool hitTest(Offset point, double tolerance) {
    if (!bounds.inflate(tolerance).contains(point)) return false;
    final limit = tolerance + strokeWidth / 2;
    if (points.length == 1) {
      return (points.first.offset - point).distance <= limit;
    }
    for (var i = 0; i < points.length - 1; i++) {
      if (_distanceToSegment(point, points[i].offset, points[i + 1].offset) <=
          limit) {
        return true;
      }
    }
    return false;
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSquared == 0) return (p - a).distance;
    final ap = p - a;
    final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / lengthSquared).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'stroke',
    'id': id,
    'color': color.toARGB32(),
    'width': strokeWidth,
    'points': [for (final p in points) p.toJson()],
  };

  factory StrokeItem.fromJson(Map<String, dynamic> json) => StrokeItem(
    id: json['id'] as String,
    color: Color(json['color'] as int),
    strokeWidth: (json['width'] as num).toDouble(),
    points: [
      for (final p in json['points'] as List) StrokePoint.fromJson(p as List),
    ],
  );
}

/// Saved camera position so a canvas reopens where you left it.
class CanvasViewport {
  const CanvasViewport({this.offset = Offset.zero, this.scale = 1});

  /// Screen-space translation applied after scaling.
  final Offset offset;
  final double scale;

  Map<String, dynamic> toJson() => {
    'dx': offset.dx,
    'dy': offset.dy,
    'scale': scale,
  };

  factory CanvasViewport.fromJson(Map<String, dynamic> json) => CanvasViewport(
    offset: Offset(
      (json['dx'] as num).toDouble(),
      (json['dy'] as num).toDouble(),
    ),
    scale: (json['scale'] as num).toDouble(),
  );
}

/// A whole canvas board as it is stored on disk.
class CanvasDocument {
  CanvasDocument({
    required this.id,
    required this.title,
    required this.items,
    required this.updatedAt,
    this.viewport = const CanvasViewport(),
    this.folderId,
    this.schema = schemaVersion,
    this.itemRevs = const {},
    this.tombstones = const {},
    this.metaRev,
    this.unknownItems = const [],
  });

  /// 2: note styling, images, link and note cards.
  /// 3: per-item revision stamps, item tombstones, title/folder stamp and
  /// preserved unknown items (all optional, so older files load unchanged).
  static const int schemaVersion = 3;

  final String id;
  final String title;
  final List<CanvasItem> items;
  final CanvasViewport viewport;
  final DateTime updatedAt;

  /// Shared folder (same folders as Notes).
  final String? folderId;

  /// Schema of the file this was read from.
  final int schema;

  /// Revision stamp of each item (item id → stamp), for future sync.
  final Map<String, String> itemRevs;

  /// Items deleted from this canvas (item id → deletion stamp).
  final Map<String, String> tombstones;

  /// Stamp of the last title or folder change.
  final String? metaRev;

  /// Items this version cannot read (e.g. written by a newer version on
  /// another device). Kept untouched and written back as they were.
  final List<Map<String, dynamic>> unknownItems;

  CanvasDocument copyWith({
    String? title,
    List<CanvasItem>? items,
    CanvasViewport? viewport,
    DateTime? updatedAt,
    String? Function()? folderId,
  }) {
    return CanvasDocument(
      id: id,
      title: title ?? this.title,
      items: items ?? this.items,
      viewport: viewport ?? this.viewport,
      updatedAt: updatedAt ?? this.updatedAt,
      folderId: folderId != null ? folderId() : this.folderId,
      itemRevs: itemRevs,
      tombstones: tombstones,
      metaRev: metaRev,
      unknownItems: unknownItems,
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': schemaVersion,
    'id': id,
    'title': title,
    'folderId': folderId,
    'updatedAt': utcIso(updatedAt),
    'viewport': viewport.toJson(),
    'items': [for (final item in items) item.toJson(), ...unknownItems],
    if (itemRevs.isNotEmpty) 'itemRevs': itemRevs,
    if (tombstones.isNotEmpty) 'tombstones': tombstones,
    'metaRev': ?metaRev,
  };

  factory CanvasDocument.fromJson(Map<String, dynamic> json) {
    final items = <CanvasItem>[];
    final unknown = <Map<String, dynamic>>[];
    for (final raw in json['items'] as List) {
      final map = raw as Map<String, dynamic>;
      try {
        items.add(CanvasItem.fromJson(map));
      } catch (_) {
        unknown.add(map);
      }
    }
    return CanvasDocument(
      id: json['id'] as String,
      title: json['title'] as String,
      folderId: json['folderId'] as String?,
      schema: json['schema'] as int? ?? 1,
      updatedAt: DateTime.parse(json['updatedAt'] as String).toLocal(),
      viewport: json['viewport'] == null
          ? const CanvasViewport()
          : CanvasViewport.fromJson(json['viewport'] as Map<String, dynamic>),
      items: items,
      unknownItems: unknown,
      itemRevs: {...?(json['itemRevs'] as Map?)?.cast<String, String>()},
      tombstones: {...?(json['tombstones'] as Map?)?.cast<String, String>()},
      metaRev: json['metaRev'] as String?,
    );
  }
}

/// Lightweight listing entry used by the sidebar, Home and folders.
class CanvasSummary {
  const CanvasSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.folderId,
    this.searchText = '',
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final String? folderId;

  /// All text on the canvas, for global search.
  final String searchText;
}
