import 'dart:math' as math;
import 'dart:ui';

import 'record.dart' show utcIso;
import 'unknown_fields.dart';

/// Stable id for the first-canvas welcome guide, so it can be dismissed as a
/// distinct canvas item without matching or changing user-authored text.
const welcomeGuideItemId = 'theapp-welcome-guide';

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
      case 'connector':
        return ConnectorItem.fromJson(json);
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
    this.sourceNoteId,
    this.sourceNoteTitle,
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

  /// Stable source context for text brought in from a note. This points to
  /// the original record; the text box remains an independent THEapp item.
  final String? sourceNoteId;
  final String? sourceNoteTitle;

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
    String? Function()? sourceNoteId,
    String? Function()? sourceNoteTitle,
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
      sourceNoteId: sourceNoteId != null ? sourceNoteId() : this.sourceNoteId,
      sourceNoteTitle: sourceNoteTitle != null
          ? sourceNoteTitle()
          : this.sourceNoteTitle,
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
    sourceNoteId: sourceNoteId,
    sourceNoteTitle: sourceNoteTitle,
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
    if (sourceNoteId != null) 'sourceNoteId': sourceNoteId,
    if (sourceNoteTitle != null) 'sourceNoteTitle': sourceNoteTitle,
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
    sourceNoteId: json['sourceNoteId'] as String?,
    sourceNoteTitle: json['sourceNoteTitle'] as String?,
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

/// Shortest distance from [p] to the segment [a]–[b].
double distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSquared == 0) return (p - a).distance;
  final ap = p - a;
  final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / lengthSquared).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// How a connection is drawn between its waypoints.
enum ConnectorStyle {
  /// A smooth curve (a straight line while it has no bends).
  curved,

  /// Straight pieces with sharp corners.
  straight,

  /// Horizontal and vertical pieces only (elbows).
  orthogonal,
}

/// A mind-map connection between two items on the same canvas. It stores
/// only the two item ids (never copies), so it follows them when they move;
/// it is hidden while either end is missing.
class ConnectorItem extends CanvasItem {
  const ConnectorItem({
    required super.id,
    required this.fromId,
    required this.toId,
    this.fromT,
    this.toT,
    this.color,
    this.bends = const [],
    this.style = ConnectorStyle.curved,
    this.auto = false,
  });

  final String fromId;
  final String toId;

  /// Where on a drawn line (stroke) an end is attached: 0 = its first
  /// point, 1 = its last, in between = that share of its points. Stored
  /// against the stroke's own points, so the end stays on the same ink when
  /// the stroke is moved, resized, scaled or rotated. Null for objects
  /// (boxes): the end sits on their edge. Optional and written only when
  /// set, so older files and app versions are unaffected.
  final double? fromT;
  final double? toT;

  /// The line's own color (null: the default connector color). Optional.
  final Color? color;

  /// Waypoints the line is bent through, in world coordinates, in order
  /// from the start to the end. The line is a smooth curve through them.
  /// Empty: a straight line. Optional and written only when set.
  final List<Offset> bends;

  /// How the line is drawn (curved, straight or elbow).
  final ConnectorStyle style;

  /// Automatic routing: the line goes around the other objects by itself.
  /// The manual [bends] are kept (unused) and come back when this is off.
  final bool auto;

  ConnectorItem copyWith({
    Color? Function()? color,
    List<Offset>? bends,
    ConnectorStyle? style,
    bool? auto,
  }) => ConnectorItem(
    id: id,
    fromId: fromId,
    toId: toId,
    fromT: fromT,
    toT: toT,
    color: color != null ? color() : this.color,
    bends: bends ?? this.bends,
    style: style ?? this.style,
    auto: auto ?? this.auto,
  );

  /// The line's real extent depends on the two items; the controller
  /// computes it (see `CanvasController.itemBounds`).
  @override
  Rect get bounds => Rect.zero;

  /// Moves with its ends, not by itself (the controller shifts [bends]
  /// when both ends move).
  @override
  ConnectorItem translated(Offset delta) => this;

  /// The same line with its waypoints moved by [delta].
  ConnectorItem bendsShifted(Offset delta) => bends.isEmpty
      ? this
      : copyWith(bends: [for (final b in bends) b + delta]);

  @override
  ConnectorItem withId(String id) => ConnectorItem(
    id: id,
    fromId: fromId,
    toId: toId,
    fromT: fromT,
    toT: toT,
    color: color,
    bends: bends,
    style: style,
    auto: auto,
  );

  /// The same connection between other items (copies keep their anchors).
  ConnectorItem rejoined(String id, String from, String to) => ConnectorItem(
    id: id,
    fromId: from,
    toId: to,
    fromT: fromT,
    toT: toT,
    color: color,
    bends: bends,
    style: style,
    auto: auto,
  );

  bool touches(String itemId) => fromId == itemId || toId == itemId;

  bool joins(String a, String b) =>
      (fromId == a && toId == b) || (fromId == b && toId == a);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'connector',
    'id': id,
    'from': fromId,
    'to': toId,
    'fromT': ?fromT,
    'toT': ?toT,
    if (color != null) 'color': color!.toARGB32(),
    if (bends.isNotEmpty)
      'bends': [
        for (final b in bends) [b.dx, b.dy],
      ],
    if (style != ConnectorStyle.curved) 'style': style.name,
    if (auto) 'auto': true,
  };

  static double? _t(Object? v) =>
      v is num && v.isFinite ? v.toDouble().clamp(0.0, 1.0) : null;

  static List<Offset> _bends(Object? v) {
    if (v is! List) return const [];
    final out = <Offset>[];
    for (final p in v) {
      if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
        final x = (p[0] as num).toDouble(), y = (p[1] as num).toDouble();
        if (x.isFinite && y.isFinite) out.add(Offset(x, y));
      }
    }
    return out;
  }

  factory ConnectorItem.fromJson(Map<String, dynamic> j) => ConnectorItem(
    id: j['id'] as String,
    fromId: j['from'] as String,
    toId: j['to'] as String,
    fromT: _t(j['fromT']),
    toT: _t(j['toT']),
    color: j['color'] is int ? Color(j['color'] as int) : null,
    bends: _bends(j['bends']),
    style:
        ConnectorStyle.values.asNameMap()[j['style']] ?? ConnectorStyle.curved,
    auto: j['auto'] == true,
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
    this.pressureWidth = false,
  }) : bounds = _computeBounds(points, strokeWidth * (pressureWidth ? 1.6 : 1));

  final List<StrokePoint> points;
  final Color color;
  final double strokeWidth;

  /// Drawn with a width that follows the pen pressure (Apple Pencil strokes
  /// from Phase 2 on; pressure stored 0..1). Older strokes keep one width.
  final bool pressureWidth;

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
    pressureWidth: pressureWidth,
  );

  /// The same stroke in [newColor], keeping its own opacity (a highlighter
  /// stays see-through) and its shape.
  StrokeItem recolored(Color newColor) => StrokeItem(
    id: id,
    points: points,
    color: newColor.withValues(alpha: color.a),
    strokeWidth: strokeWidth,
    pressureWidth: pressureWidth,
  );

  @override
  StrokeItem withId(String id) => StrokeItem(
    id: id,
    points: points,
    color: color,
    strokeWidth: strokeWidth,
    pressureWidth: pressureWidth,
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

  static double _distanceToSegment(Offset p, Offset a, Offset b) =>
      distanceToSegment(p, a, b);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'stroke',
    'id': id,
    'color': color.toARGB32(),
    'width': strokeWidth,
    'points': [for (final p in points) p.toJson()],
    if (pressureWidth) 'pw': true,
  };

  factory StrokeItem.fromJson(Map<String, dynamic> json) => StrokeItem(
    id: json['id'] as String,
    color: Color(json['color'] as int),
    strokeWidth: (json['width'] as num).toDouble(),
    pressureWidth: json['pw'] == true,
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
    this.itemUnknownFields = const {},
    this.unknownKeys = const {},
    this.metaUnknownFields = const {},
    this.kind,
    this.pageBackgrounds = const [],
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

  /// Fields of readable items that this version does not know (item id →
  /// fields), written back with the item. See `unknown_fields.dart`.
  final Map<String, Map<String, dynamic>> itemUnknownFields;

  /// Top-level keys of the file that this version does not know.
  final Map<String, dynamic> unknownKeys;

  /// Fields of the synced canvas metadata (title, folder, order) that this
  /// version does not know; sent back with it.
  final Map<String, dynamic> metaUnknownFields;

  /// "notebook" for a note's handwriting (stored like a canvas, not shown
  /// as one); null for an ordinary canvas.
  final String? kind;

  /// Notebook pages that show a PDF page underneath (see [PageBackground]).
  final List<PageBackground> pageBackgrounds;

  /// Whether this document is a note's handwriting. The id prefix also
  /// counts, in case a version that drops [kind] passed it on.
  bool get isNotebook => isNotebookId(id, kind);

  /// Whether this document is the Links library board.
  bool get isLinksBoard => isLinksBoardId(id, kind);

  static const _knownKeys = {
    'schema',
    'id',
    'title',
    'folderId',
    'updatedAt',
    'viewport',
    'items',
    'itemRevs',
    'tombstones',
    'metaRev',
    'metaUnknownFields',
    'kind',
    'pageBackgrounds',
  };

  /// [item] as stored and synced, including fields this version does not
  /// know.
  Map<String, dynamic> itemJson(CanvasItem item) =>
      withUnknownFields(item.toJson(), itemUnknownFields[item.id]);

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
      itemUnknownFields: itemUnknownFields,
      unknownKeys: unknownKeys,
      metaUnknownFields: metaUnknownFields,
      kind: kind,
      pageBackgrounds: pageBackgrounds,
    );
  }

  Map<String, dynamic> toJson() => {
    ...unknownKeys,
    'schema': schemaVersion,
    'id': id,
    'title': title,
    'folderId': folderId,
    'updatedAt': utcIso(updatedAt),
    'viewport': viewport.toJson(),
    'items': [for (final item in items) itemJson(item), ...unknownItems],
    if (itemRevs.isNotEmpty) 'itemRevs': itemRevs,
    if (tombstones.isNotEmpty) 'tombstones': tombstones,
    'metaRev': ?metaRev,
    if (metaUnknownFields.isNotEmpty) 'metaUnknownFields': metaUnknownFields,
    'kind': ?kind,
    if (pageBackgrounds.isNotEmpty)
      'pageBackgrounds': [for (final b in pageBackgrounds) b.toJson()],
  };

  factory CanvasDocument.fromJson(Map<String, dynamic> json) {
    final items = <CanvasItem>[];
    final unknown = <Map<String, dynamic>>[];
    final itemUnknown = <String, Map<String, dynamic>>{};
    for (final raw in json['items'] as List) {
      final map = raw as Map<String, dynamic>;
      try {
        final item = CanvasItem.fromJson(map);
        items.add(item);
        final fields = unknownFields(map, item.toJson().keys);
        if (fields.isNotEmpty) itemUnknown[item.id] = fields;
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
      itemUnknownFields: itemUnknown,
      unknownKeys: unknownFields(json, _knownKeys),
      metaUnknownFields: {
        ...?(json['metaUnknownFields'] as Map?)?.cast<String, dynamic>(),
      },
      kind: json['kind'] as String?,
      pageBackgrounds: [
        for (final b in json['pageBackgrounds'] as List? ?? const [])
          PageBackground.fromJson(b as Map<String, dynamic>),
      ],
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
    this.isNotebook = false,
    this.isLinksBoard = false,
    this.isCalendarInk = false,
    this.isComponents = false,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final String? folderId;

  /// All text on the canvas, for global search.
  final String searchText;

  /// A note's handwriting, not a canvas of its own.
  final bool isNotebook;

  /// The Links library board, not a canvas of its own.
  final bool isLinksBoard;

  /// The Calendar's drawings, not a canvas of its own.
  final bool isCalendarInk;

  /// The saved reusable canvas components, not a canvas of its own.
  final bool isComponents;

  /// Shown in the Canvas list (notebooks, the Links board and the
  /// Calendar drawings are not).
  bool get isCanvas =>
      !isNotebook && !isLinksBoard && !isCalendarInk && !isComponents;
}

/// Id of the handwriting document of note [noteId]. Fixed, so two devices
/// writing in the same note fill one document instead of making two.
String notebookIdFor(String noteId) => 'nb-$noteId';

/// Whether a canvas document is a note's handwriting.
bool isNotebookId(String id, [String? kind]) =>
    kind == 'notebook' || id.startsWith('nb-');

/// Id of the one Links library board. Fixed, so every device fills the
/// same board (its cards merge per item when syncing).
const linksBoardId = 'links-board';

/// Whether a canvas document is the Links library board.
bool isLinksBoardId(String id, [String? kind]) =>
    kind == 'links' || id == linksBoardId;

/// Id of the one document holding all drawings made on the Calendar.
const calendarInkId = 'calendar-ink';

/// Whether a canvas document is the Calendar's drawings.
bool isCalendarInkId(String id, [String? kind]) =>
    kind == 'calendarInk' || id == calendarInkId;

/// Id of the document that keeps the saved reusable canvas components.
const componentsId = 'canvas-components';

/// Whether a canvas document holds the reusable components.
bool isComponentsId(String id, [String? kind]) =>
    kind == 'components' || id == componentsId;

/// A PDF page shown underneath one page of a notebook. The PDF stays an
/// unchanged attachment (asset [assetId]); ink on the page is stored as
/// ordinary strokes in the page's coordinates, so nothing drifts.
class PageBackground {
  const PageBackground({
    required this.pageIndex,
    required this.assetId,
    required this.pdfPage,
    required this.width,
    required this.height,
  });

  /// Notebook page (0-based) this PDF page sits under.
  final int pageIndex;
  final String assetId;

  /// Page in the PDF (0-based).
  final int pdfPage;

  /// The PDF page's size in points (its aspect ratio sets the page shape).
  final double width;
  final double height;

  Map<String, dynamic> toJson() => {
    'at': pageIndex,
    'asset': assetId,
    'page': pdfPage,
    'w': width,
    'h': height,
  };

  factory PageBackground.fromJson(Map<String, dynamic> j) => PageBackground(
    pageIndex: (j['at'] as num).toInt(),
    assetId: j['asset'] as String,
    pdfPage: (j['page'] as num).toInt(),
    width: (j['w'] as num).toDouble(),
    height: (j['h'] as num).toDouble(),
  );
}
