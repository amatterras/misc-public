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
/// Non-destructive edits of a photo: the file itself is never changed, the
/// item only remembers how to show it. Everything here is reversible (reset
/// crop / reset all) and travels with the item through save, sync and export.
class ImageEdit {
  const ImageEdit({this.crop, this.turns = 0, this.flip = false});

  static const none = ImageEdit();

  /// The part of the photo that is shown, as fractions (0..1) of the
  /// original, before turning. Null shows all of it.
  final Rect? crop;

  /// Quarter turns clockwise (0-3), applied after the crop.
  final int turns;

  /// Mirrored left-right (before turning).
  final bool flip;

  bool get isNone => crop == null && turns == 0 && !flip;

  /// The shown part's width / height for an original of [w] x [h] pixels,
  /// after cropping and turning.
  double aspect(double w, double h) {
    final c = crop;
    final cw = (c?.width ?? 1) * w, ch = (c?.height ?? 1) * h;
    final ratio = ch <= 0 ? 1.0 : cw / ch;
    return turns.isOdd ? 1 / ratio : ratio;
  }

  /// The shown part's size in original pixels, after turning.
  Size shown(double w, double h) {
    final c = crop;
    final cw = (c?.width ?? 1) * w, ch = (c?.height ?? 1) * h;
    return turns.isOdd ? Size(ch, cw) : Size(cw, ch);
  }

  ImageEdit copyWith({
    Rect? Function()? crop,
    int? turns,
    bool? flip,
  }) => ImageEdit(
    crop: crop != null ? crop() : this.crop,
    turns: turns == null ? this.turns : ((turns % 4) + 4) % 4,
    flip: flip ?? this.flip,
  );

  /// Keeps a crop inside the photo and at least 2% wide / high.
  static Rect? cleanCrop(Rect? r) {
    if (r == null) return null;
    final l = r.left.clamp(0.0, 0.98), t = r.top.clamp(0.0, 0.98);
    final rr = r.right.clamp(l + 0.02, 1.0), bb = r.bottom.clamp(t + 0.02, 1.0);
    final c = Rect.fromLTRB(l, t, rr, bb);
    return c.left <= 0 && c.top <= 0 && c.right >= 1 && c.bottom >= 1
        ? null
        : c;
  }

  Map<String, dynamic> toJson() => {
    if (crop != null) 'crop': [crop!.left, crop!.top, crop!.right, crop!.bottom],
    if (turns != 0) 'turns': turns,
    if (flip) 'flip': true,
  };

  /// Damaged values fall back to "no edit".
  factory ImageEdit.fromJson(Object? raw) {
    if (raw is! Map) return none;
    Rect? crop;
    final c = raw['crop'];
    if (c is List && c.length == 4 && c.every((v) => v is num)) {
      crop = cleanCrop(
        Rect.fromLTRB(
          (c[0] as num).toDouble(),
          (c[1] as num).toDouble(),
          (c[2] as num).toDouble(),
          (c[3] as num).toDouble(),
        ),
      );
    }
    final turns = raw['turns'];
    return ImageEdit(
      crop: crop,
      turns: turns is int ? ((turns % 4) + 4) % 4 : 0,
      flip: raw['flip'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ImageEdit &&
      other.crop == crop &&
      other.turns == turns &&
      other.flip == flip;

  @override
  int get hashCode => Object.hash(crop, turns, flip);
}

class ImageItem extends BoxItem {
  const ImageItem({
    required super.id,
    required super.position,
    required super.width,
    required super.minHeight,
    required this.assetId,
    this.edit = ImageEdit.none,
  });

  final String assetId;
  final ImageEdit edit;
  double get height => minHeight;

  @override
  ImageItem withBox({Offset? position, double? width, double? minHeight}) =>
      ImageItem(
        id: id,
        assetId: assetId,
        edit: edit,
        position: position ?? this.position,
        width: width ?? this.width,
        minHeight: minHeight ?? this.minHeight,
      );

  ImageItem withEdit(ImageEdit edit) => ImageItem(
    id: id,
    assetId: assetId,
    edit: edit,
    position: position,
    width: width,
    minHeight: minHeight,
  );

  @override
  ImageItem withId(String id) => ImageItem(
    id: id,
    assetId: assetId,
    edit: edit,
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
    if (!edit.isNone) 'edit': edit.toJson(),
  };

  factory ImageItem.fromJson(Map<String, dynamic> j) => ImageItem(
    id: j['id'] as String,
    assetId: j['assetId'] as String,
    edit: ImageEdit.fromJson(j['edit']),
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

//// One sampled point of a freehand stroke, as the pen delivered it.
///
/// Mouse and finger input record pressure 0.5. The pen's angle and the
/// sample's time are kept whenever the hardware reports them (Apple Pencil
/// through the native observer); they are never made up, so they are null
/// for input that has none and for strokes saved by earlier versions.
class StrokePoint {
  const StrokePoint(
    this.x,
    this.y, [
    this.pressure = 0.5,
    this.time,
    this.altitude,
    this.azimuth,
  ]);

  final double x;
  final double y;
  final double pressure;

  /// Milliseconds since the stroke's first sample.
  final int? time;

  /// The pen's angle above the surface in radians (pi/2: upright).
  final double? altitude;

  /// The direction the pen leans towards, in radians (0: along +x).
  final double? azimuth;

  Offset get offset => Offset(x, y);

  /// The same sample at another position (moving, scaling, rotating).
  StrokePoint at(double x, double y) =>
      StrokePoint(x, y, pressure, time, altitude, azimuth);

  /// The same sample with another pressure.
  StrokePoint withPressure(double pressure) =>
      StrokePoint(x, y, pressure, time, altitude, azimuth);

  /// The same sample taken at [time] (milliseconds into the stroke).
  StrokePoint withTime(int time) =>
      StrokePoint(x, y, pressure, time, altitude, azimuth);

  /// The sample a share [t] of the way from [a] to [b]: position, pressure
  /// and, when both have them, time and pen angle.
  static StrokePoint lerp(StrokePoint a, StrokePoint b, double t) {
    final ta = a.time, tb = b.time;
    final la = a.altitude, lb = b.altitude;
    final za = a.azimuth, zb = b.azimuth;
    double? azimuth;
    if (za != null && zb != null) {
      // The short way round the circle.
      var d = (zb - za) % (2 * math.pi);
      if (d > math.pi) d -= 2 * math.pi;
      azimuth = za + d * t;
    }
    return StrokePoint(
      a.x + (b.x - a.x) * t,
      a.y + (b.y - a.y) * t,
      a.pressure + (b.pressure - a.pressure) * t,
      ta != null && tb != null ? (ta + (tb - ta) * t).round() : null,
      la != null && lb != null ? la + (lb - la) * t : null,
      azimuth,
    );
  }

  static double _milli(double v) => (v * 1000).roundToDouble() / 1000;

  /// `[x, y, pressure]`, then the time and the pen angle only when known,
  /// so strokes without them are stored exactly as before.
  List<num> toJson() {
    final t = time, altitude = this.altitude, azimuth = this.azimuth;
    if (altitude != null && azimuth != null) {
      return [x, y, pressure, t ?? -1, _milli(altitude), _milli(azimuth)];
    }
    return t == null ? [x, y, pressure] : [x, y, pressure, t];
  }

  factory StrokePoint.fromJson(List<dynamic> json) {
    final n = json.length;
    final t = n > 3 ? json[3] : null;
    final altitude = n > 5 ? json[4] : null;
    final azimuth = n > 5 ? json[5] : null;
    return StrokePoint(
      (json[0] as num).toDouble(),
      (json[1] as num).toDouble(),
      n > 2 ? (json[2] as num).toDouble() : 0.5,
      t is num && t.isFinite && t >= 0 ? t.round() : null,
      altitude is num && altitude.isFinite ? altitude.toDouble() : null,
      azimuth is num && azimuth.isFinite ? azimuth.toDouble() : null,
    );
  }
}

class StrokeItem extends CanvasItem {
  StrokeItem({
    required super.id,
    required this.points,
    required this.color,
    required this.strokeWidth,
    this.pressureWidth = false,
    this.penInk = false,
    this.tiltWidth = false,
  }) : bounds = _computeBounds(
         points,
         strokeWidth * (pressureWidth ? 1.6 : 1) * (tiltWidth ? 3 : 1),
       );

  final List<StrokePoint> points;
  final Color color;
  final double strokeWidth;

  /// Drawn with a width that follows the pen pressure (Apple Pencil strokes
  /// from Phase 2 on; pressure stored 0..1). Older strokes keep one width.
  final bool pressureWidth;

  /// Drawn by the pen at less than full opacity. Tells a see-through pen
  /// line from a highlighter line (which older files mark only by being
  /// see-through). Written only when set.
  final bool penInk;

  /// The line widens as the pen is laid flat (shading with the side of the
  /// tip), for points that carry the pen's angle. Written only when set.
  final bool tiltWidth;

  /// A highlighter line: see-through and not drawn by the pen.
  bool get isHighlighter => color.a < 0.99 && !penInk;

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

  /// The same stroke (colour, width, kind) through other [points].
  StrokeItem withPoints(List<StrokePoint> points, {String? id}) => StrokeItem(
    id: id ?? this.id,
    points: points,
    color: color,
    strokeWidth: strokeWidth,
    pressureWidth: pressureWidth,
    penInk: penInk,
    tiltWidth: tiltWidth,
  );

  /// The same stroke drawn at one even width (a pen that turned out to
  /// report no pressure) or following the pressure.
  StrokeItem withPressureWidth(bool pressureWidth) => StrokeItem(
    id: id,
    points: points,
    color: color,
    strokeWidth: strokeWidth,
    pressureWidth: pressureWidth,
    penInk: penInk,
    tiltWidth: tiltWidth,
  );

  /// The same stroke with every point moved by [map].
  StrokeItem mapped(Offset Function(double x, double y) map) => withPoints([
    for (final p in points)
      () {
        final q = map(p.x, p.y);
        return p.at(q.dx, q.dy);
      }(),
  ]);

  @override
  StrokeItem translated(Offset delta) => withPoints([
    for (final p in points) p.at(p.x + delta.dx, p.y + delta.dy),
  ]);

  /// The same stroke in [newColor], keeping its own opacity (a highlighter
  /// stays see-through) and its shape.
  StrokeItem recolored(Color newColor) => StrokeItem(
    id: id,
    points: points,
    color: newColor.withValues(alpha: color.a),
    strokeWidth: strokeWidth,
    pressureWidth: pressureWidth,
    penInk: penInk,
    tiltWidth: tiltWidth,
  );

  @override
  StrokeItem withId(String id) => withPoints(points, id: id);

  /// Half the drawn width at [p]: the chosen width, or what the pressure
  /// (and the pen's angle) make of it, as the stroke is painted.
  double halfWidthAt(StrokePoint p) =>
      strokeWidth * inkWidthFactor(this, p) / 2;

  /// Whether [point] lies within [tolerance] of the ink of this stroke as
  /// it is drawn (a pressure line is tested with its width at each place,
  /// not one width for the whole line).
  bool hitTest(Offset point, double tolerance) {
    if (!bounds.inflate(tolerance).contains(point)) return false;
    if (points.length == 1) {
      return (points.first.offset - point).distance <=
          tolerance + halfWidthAt(points.first);
    }
    final varies = pressureWidth || tiltWidth;
    final flat = tolerance + strokeWidth / 2;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i], b = points[i + 1];
      final limit = varies
          ? tolerance + math.max(halfWidthAt(a), halfWidthAt(b))
          : flat;
      // Cheap rejection before the exact distance.
      if (point.dx < math.min(a.x, b.x) - limit ||
          point.dx > math.max(a.x, b.x) + limit ||
          point.dy < math.min(a.y, b.y) - limit ||
          point.dy > math.max(a.y, b.y) + limit) {
        continue;
      }
      if (distanceToSegment(point, a.offset, b.offset) <= limit) return true;
    }
    return false;
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'stroke',
    'id': id,
    'color': color.toARGB32(),
    'width': strokeWidth,
    'points': [for (final p in points) p.toJson()],
    if (pressureWidth) 'pw': true,
    if (penInk) 'pen': true,
    if (tiltWidth) 'tw': true,
  };

  factory StrokeItem.fromJson(Map<String, dynamic> json) => StrokeItem(
    id: json['id'] as String,
    color: Color(json['color'] as int),
    strokeWidth: (json['width'] as num).toDouble(),
    pressureWidth: json['pw'] == true,
    penInk: json['pen'] == true,
    tiltWidth: json['tw'] == true,
    points: [
      for (final p in json['points'] as List) StrokePoint.fromJson(p as List),
    ],
  );
}

/// Width factor for a pen pressure (0..1).
///
/// Ordinary handwriting presses an Apple Pencil at about 0.15-0.4 of its
/// range, so the curve is steep at the light end and flat at the firm
/// end: normal writing comes out at about the chosen pen size (factor
/// about 0.85-1.05), the lightest touch at 62 % and the firmest at 138 %.
/// A table instead of math.pow per sample; pressure steps of 1/1024 change
/// the width by under 0.1 %.
double pressureFactor(double pressure) {
  final i = (pressure.clamp(0.0, 1.0) * 1024).round();
  return (_pressureTable ??= [
    for (var k = 0; k <= 1024; k++)
      0.62 + 0.76 * math.pow(k / 1024, 0.6).toDouble(),
  ])[i];
}

List<double>? _pressureTable;

/// Width factor of the pen's angle: 1 while the pen is held as for writing
/// (60 degrees or more above the surface), growing smoothly to 3 as it is
/// laid flat (20 degrees or less), like the side of a pencil tip. 1 for
/// points without a pen angle.
double tiltWidthFactor(double? altitude) {
  if (altitude == null) return 1;
  const upright = 60 * math.pi / 180, flat = 20 * math.pi / 180;
  final t = ((upright - altitude) / (upright - flat)).clamp(0.0, 1.0);
  return 1 + 2 * t * t * (3 - 2 * t);
}

/// The drawn width of [stroke] at [p] as a multiple of its chosen width.
double inkWidthFactor(StrokeItem stroke, StrokePoint p) =>
    (stroke.pressureWidth ? pressureFactor(p.pressure) : 1) *
    (stroke.tiltWidth ? tiltWidthFactor(p.altitude) : 1);

// Saved camera position so a canvas reopens where you left it.
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
/// A named layer of a mindmap (see CanvasController layers).
class CanvasLayer {
  const CanvasLayer({
    required this.id,
    required this.name,
    this.hidden = false,
    this.locked = false,
  });

  final String id;
  final String name;
  final bool hidden;
  final bool locked;

  CanvasLayer copyWith({String? name, bool? hidden, bool? locked}) =>
      CanvasLayer(
        id: id,
        name: name ?? this.name,
        hidden: hidden ?? this.hidden,
        locked: locked ?? this.locked,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (hidden) 'hidden': true,
    if (locked) 'locked': true,
  };

  /// Null for anything that is not a usable layer record.
  static CanvasLayer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], name = raw['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    return CanvasLayer(
      id: id,
      name: name,
      hidden: raw['hidden'] == true,
      locked: raw['locked'] == true,
    );
  }

  /// A list read from stored data: unusable records and repeated ids are
  /// left out.
  static List<CanvasLayer> listFrom(Object? raw) {
    final seen = <String>{};
    return [
      for (final r in raw as List? ?? const [])
        if (fromJson(r) case final l? when seen.add(l.id)) l,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is CanvasLayer &&
      other.id == id &&
      other.name == name &&
      other.hidden == hidden &&
      other.locked == locked;

  @override
  int get hashCode => Object.hash(id, name, hidden, locked);
}

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
    this.layers = const [],
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

  /// The mindmap's layers, bottom to top (empty: none).
  final List<CanvasLayer> layers;

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
    'layers',
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
      layers: layers,
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
    if (layers.isNotEmpty) 'layers': [for (final l in layers) l.toJson()],
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
      layers: CanvasLayer.listFrom(json['layers']),
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
