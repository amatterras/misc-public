import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import 'connector_path.dart';
import '../../data/models/library_models.dart';
import '../../data/models/tag_models.dart';
import '../../data/storage/app_log.dart';
import '../../data/sync/sync_clock.dart';
import '../../sync/canvas_merge.dart';
import '../../sync/protocol.dart';
import 'canvas_resources.dart';
import 'canvas_text.dart';
import '../ink/stroke_geometry.dart';
import '../ink/partial_erase.dart';
import '../ink/ink_metrics.dart';
import '../ink/shape_recognition.dart';

export 'canvas_text.dart' show kTextPadding, canvasTextStyle;

enum CanvasTool { select, lasso, pan, pen, highlighter, eraser, text, connect }

/// What the eraser removes (see [CanvasController.eraserMode]).
enum EraserMode { stroke, partial }

enum SaveState { saved, pending, saving, failed }

/// What the current pointer drag is doing.
enum _Drag {
  none,
  pan,
  move,
  resize,
  marquee,
  lasso,
  draw,
  erase,
  connect,
  // Connect tool, second tap (choosing the target of a tapped source).
  connectTap,
}

/// Owns the state of one open canvas: its items, camera, selection, current
/// tool, undo/redo history and autosave.
///
/// All pointer input arrives here as plain values (position, buttons, device
/// kind, pressure) rather than Flutter gesture objects. This keeps the logic
/// testable and lets touch and stylus input be routed in later — e.g. pen
/// draws while finger pans — without restructuring.
class CanvasController extends ChangeNotifier {
  CanvasController({
    required CanvasDocument document,
    required this.onSave,
    this.resources,
    this.onActivate,
    SyncClock? clock,
    this.saveDelay = const Duration(milliseconds: 600),
  }) : clock = clock ?? SyncClock(),
       _id = document.id,
       _title = document.title,
       _folderId = document.folderId,
       _items = List.unmodifiable(document.items),
       _offset = document.viewport.offset,
       _scale = document.viewport.scale,
       _saveState = SaveState.saved,
       _itemRevs = {...document.itemRevs},
       _tombstones = {...document.tombstones},
       _metaRev = document.metaRev,
       _unknownItems = document.unknownItems,
       _itemUnknownFields = {...document.itemUnknownFields},
       _unknownKeys = document.unknownKeys,
       _metaUnknownFields = document.metaUnknownFields,
       _docKind = document.kind,
       _pageBackgrounds = document.pageBackgrounds,
       _savedTitle = document.title,
       _savedFolderId = document.folderId,
       _savedItems = {for (final i in document.items) i.id: i} {
    resources?.addListener(_onResourcesChanged);
    _itemRevs.values.forEach(this.clock.observe);
    _tombstones.values.forEach(this.clock.observe);
    this.clock.observe(_metaRev);
    // Old files are rewritten in the new format on first open.
    if (document.schema < CanvasDocument.schemaVersion) _markDirty();
  }

  static const double minScale = 0.03;
  static const double maxScale = 8;

  /// Opening a canvas never starts zoomed out further than this.
  static const double readableScale = 0.6;
  static const int historyLimit = 300;
  static const Duration doubleClickTime = Duration(milliseconds: 350);

  final Future<void> Function(CanvasDocument) onSave;

  /// Source of revision stamps (shared with the rest of the workspace).
  final SyncClock clock;
  final CanvasResources? resources;

  /// Called on double-click (or Ctrl+click) of a link or note card.
  final void Function(CanvasItem item)? onActivate;
  final Duration saveDelay;
  final String _id;

  String get id => _id;

  String? _folderId;
  String? get folderId => _folderId;
  set folderId(String? value) {
    if (value == _folderId) return;
    _folderId = value;
    _markDirty();
    notifyListeners();
  }

  String _title;
  String get title => _title;
  set title(String value) {
    if (value == _title) return;
    _title = value;
    _markDirty();
    notifyListeners();
  }

  void _onResourcesChanged() {
    _clearCardLayouts();
    notifyListeners();
  }

  // ---------------------------------------------------------------- items --

  List<CanvasItem> _items;
  List<CanvasItem> get items => _items;

  CanvasItem? itemById(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _setItems(List<CanvasItem> items) {
    _items = List.unmodifiable(items);
    _markDirty();
  }

  void _replaceItems(Map<String, CanvasItem> replacements) {
    _setItems([for (final i in _items) replacements[i.id] ?? i]);
  }

  // --------------------------------------------------------------- camera --

  Offset _offset;
  double _scale;
  Offset get offset => _offset;
  double get scale => _scale;

  Offset toWorld(Offset screen) => (screen - _offset) / _scale;
  Offset toScreen(Offset world) => world * _scale + _offset;

  Rect visibleWorld(Size viewport) => Rect.fromPoints(
    toWorld(Offset.zero),
    toWorld(viewport.bottomRight(Offset.zero)),
  );

  /// Sets the camera directly without saving it (notebook pages: offset 0
  /// and the page zoom, so screen-pixel tolerances stay right).
  void setView(Offset offset, double scale) {
    if (_offset == offset && _scale == scale) return;
    _offset = offset;
    _scale = scale;
  }

  void panBy(Offset screenDelta) {
    _offset += screenDelta;
    _markDirty();
    notifyListeners();
  }

  /// Zooms by [factor] while keeping the point under [focal] fixed.
  void zoomAt(Offset focal, double factor) {
    final newScale = (_scale * factor).clamp(minScale, maxScale);
    if (newScale == _scale) return;
    final world = toWorld(focal);
    _scale = newScale;
    _offset = focal - world * _scale;
    _markDirty();
    notifyListeners();
  }

  /// Bounds of everything on the canvas, or null if empty.
  Rect? contentBounds() {
    if (_items.isEmpty) return null;
    return _items.map(itemBounds).reduce((a, b) => a.expandToInclude(b));
  }

  /// Size of the view showing this canvas (set by the view; zero until it
  /// is laid out). Lets code outside the view centre on an item.
  Size viewportSize = Size.zero;

  /// Selects [itemId] and, once the view size is known, centres on it.
  void reveal(String itemId) {
    final item = itemById(itemId);
    if (item == null) return;
    select([itemId]);
    if (!viewportSize.isEmpty) {
      centerOn(itemBounds(item).center, viewportSize);
    }
  }

  /// Centres the camera on [world] at the current zoom.
  void centerOn(Offset world, Size viewport) {
    _offset = viewport.center(Offset.zero) - world * _scale;
    _markDirty();
    notifyListeners();
  }

  /// Shows all content, but never zooms out so far that notes become
  /// unreadable ([readableScale]) or in beyond 100 %.
  void fitToContent(Size viewport, {double minScale = readableScale}) {
    final bounds = contentBounds();
    if (bounds == null || viewport.isEmpty) {
      _scale = 1;
      _offset = viewport.center(Offset.zero);
    } else {
      final usable = Size(
        math.max(200, viewport.width - 160),
        math.max(200, viewport.height - 160),
      );
      final fit = math.min(
        usable.width / math.max(1, bounds.width),
        usable.height / math.max(1, bounds.height),
      );
      _scale = fit.clamp(minScale, 1.0);
      // If it doesn't all fit at a readable size, start at the top-left.
      final anchor = fit < minScale
          ? bounds.topLeft + Offset(usable.width, usable.height) / (2 * _scale)
          : bounds.center;
      _offset = viewport.center(Offset.zero) - anchor * _scale;
    }
    _markDirty();
    notifyListeners();
  }

  /// Called once when the canvas opens: keeps the saved view if it is
  /// readable and shows some content, otherwise fits the content.
  void ensureSensibleView(Size viewport) {
    final bounds = contentBounds();
    final showsContent =
        bounds == null || visibleWorld(viewport).overlaps(bounds);
    if (_scale < readableScale || _scale > 3 || !showsContent) {
      fitToContent(viewport);
    }
  }

  // ---------------------------------------------------------------- tools --

  CanvasTool _tool = CanvasTool.select;
  CanvasTool get tool => _tool;

  /// Whether the chosen tool is one that selects photos and items (Select
  /// and Lasso). With any other tool a tap, a long press or a right-click
  /// on a photo or an item is not read as a selection.
  bool get selectsItems =>
      _tool == CanvasTool.select || _tool == CanvasTool.lasso;
  set tool(CanvasTool value) {
    if (value == _tool) return;
    // Choosing another tool always folds the settings panel away.
    _optionsFor = null;
    cancelPendingLineStraightening();
    endEditing();
    _pendingFrom = null;
    // A tool picked by hand during a squeeze stays after the squeeze.
    _toolBeforeSqueeze = null;
    _tool = value;
    if (value != CanvasTool.select && value != CanvasTool.lasso) {
      _selection = const {};
    }
    notifyListeners();
  }

  /// Tools with a settings panel (colour, thickness, opacity, eraser mode):
  /// the pen, the highlighter and the eraser.
  static bool toolHasOptions(CanvasTool t) =>
      t == CanvasTool.pen ||
      t == CanvasTool.highlighter ||
      t == CanvasTool.eraser;

  /// The tool whose settings panel is open, if any. One value for the whole
  /// canvas, so two panels can never be open together, and it is tied to a
  /// tool: any change of tool leaves it pointing at a tool that is no
  /// longer chosen, i.e. folded. Panels start folded. Nothing here touches
  /// the tool settings (colour, width, eraser mode and size stay as set).
  CanvasTool? _optionsFor;

  /// Whether the chosen tool settings panel is open.
  bool get optionsExpanded => _optionsFor != null && _optionsFor == _tool;

  /// Tapping the chosen tool again opens its panel, and again folds it.
  void toggleOptions() => setOptionsExpanded(!optionsExpanded);

  void setOptionsExpanded(bool open) {
    final target = open && toolHasOptions(_tool) ? _tool : null;
    if (_optionsFor == target) return;
    _optionsFor = target;
    notifyListeners();
  }

  Color penColor = AppColors.text;
  double penWidth = 2.5;

  void setPen({Color? color, double? width}) {
    penColor = color ?? penColor;
    penWidth = width ?? penWidth;
    notifyListeners();
  }

  /// How visible the background dots are (their opacity only; items and
  /// text are never faded). The default is the original look.
  double dotOpacity = defaultDotOpacity;
  static const defaultDotOpacity = 0x14 / 255;
  static const dotOpacityMin = 0.02, dotOpacityMax = 0.40;

  void setDotOpacity(double value) {
    final v = value.isFinite
        ? value.clamp(dotOpacityMin, dotOpacityMax).toDouble()
        : defaultDotOpacity;
    if (v == dotOpacity) return;
    dotOpacity = v;
    notifyListeners();
  }

  /// How big the background dots are (their diameter on screen, in pixels).
  /// Only the dots change; items and text never do. The default is the
  /// original look.
  double dotSize = defaultDotSize;
  static const defaultDotSize = 1.6;
  static const dotSizeMin = 0.8, dotSizeMax = 5.0;

  void setDotSize(double value) {
    final v = value.isFinite
        ? value.clamp(dotSizeMin, dotSizeMax).toDouble()
        : defaultDotSize;
    if (v == dotSize) return;
    dotSize = v;
    notifyListeners();
  }

  /// What the eraser removes: whole strokes it touches, or only the part
  /// of a stroke under it ([EraserMode.partial]).
  EraserMode eraserMode = EraserMode.stroke;

  /// The eraser's diameter on screen (pixels), the same at any zoom.
  double eraserSize = 16;
  static const eraserSizes = (min: 4.0, max: 80.0);

  void setEraser({EraserMode? mode, double? size}) {
    eraserMode = mode ?? eraserMode;
    eraserSize = (size ?? eraserSize).clamp(eraserSizes.min, eraserSizes.max);
    notifyListeners();
  }

  Color highlighterColor = InkColors.electricGold;
  double highlighterWidth = 18.0;

  void setHighlighter({Color? color, double? width}) {
    highlighterColor = color ?? highlighterColor;
    highlighterWidth = width ?? highlighterWidth;
    notifyListeners();
  }

  /// True while the space bar is held: temporarily pan with any tool.
  bool spaceHeld = false;

  // ------------------------------------------------------------ selection --

  Set<String> _selection = const {};
  Set<String> get selection => _selection;

  void select(Iterable<String> ids) {
    cancelPendingLineStraightening();
    _selection = Set.unmodifiable(ids);
    notifyListeners();
  }

  void selectAll() {
    _tool = CanvasTool.select;
    // Reference overlays are never selected (so never deleted by accident).
    select([
      for (final i in _items)
        if (!isReference(i.id)) i.id,
    ]);
  }

  List<CanvasItem> get selectedItems => [
    for (final i in _items)
      if (_selection.contains(i.id)) i,
  ];

  void deleteSelection() {
    if (_selection.isEmpty) return;
    // Locked items stay (unlock them first).
    final doomed = {
      for (final id in _selection)
        if (!isLocked(id)) id,
    };
    if (doomed.isEmpty) return;
    // Connections go with the items they join (one undo step).
    _commit([
      for (final i in _items)
        if (!doomed.contains(i.id) &&
            !(i is ConnectorItem && doomed.any(i.touches)))
          i,
    ]);
    _selection = Set.unmodifiable(_selection.difference(doomed));
    notifyListeners();
  }

  // ------------------------------------------------------ selection units --
  //
  // What the user sees as one object: a group (all items with the same
  // group mark) or one ungrouped item. The selection is drawn as ONE
  // boundary around everything selected, with exactly two dots: top-left
  // (marks the selection) and top-right (drag it to resize / scale).
  // Tags are drawn once per unit, never on every stroke inside it.

  /// The units the selection is made of (connections excluded).
  List<List<CanvasItem>> get selectionUnits => unitsOf(selectedItems);

  /// [items] split into units: each group together, each loose item alone.
  List<List<CanvasItem>> unitsOf(Iterable<CanvasItem> items) {
    final groups = <String, List<CanvasItem>>{};
    final units = <List<CanvasItem>>[];
    for (final i in items) {
      if (i is ConnectorItem) continue;
      final g = groupOf(i.id);
      if (g == null) {
        units.add([i]);
      } else {
        (groups[g] ??= () {
          final list = <CanvasItem>[];
          units.add(list);
          return list;
        }()).add(i);
      }
    }
    return units;
  }

  /// Bounds of [items] (connections excluded), or null when there are none.
  Rect? boundsOf(Iterable<CanvasItem> items) {
    Rect? r;
    for (final i in items) {
      if (i is ConnectorItem) continue;
      final b = itemBounds(i);
      r = r == null ? b : r.expandToInclude(b);
    }
    return r;
  }

  /// The one boundary drawn around the whole selection.
  Rect? get selectionBounds => boundsOf(selectedItems);

  /// Every unit of the canvas that has a tag, with its bounds: one pair of
  /// dots per unit. A group shows its tag when all its members share it.
  List<(Rect, int)> get taggedUnits => [
    for (final unit in unitsOf(_items.where((i) => !isReference(i.id))))
      if (tagOf(unit.first.id) case final tag?
          when unit.every((i) => tagOf(i.id) == tag))
        (boundsOf(unit)!, tag),
  ];

  // ----------------------------------------------------------- item marks --
  //
  // Lock, lasso tag and group are kept with each item as extra fields, the
  // same way fields from a newer version are kept: they are saved and
  // synced with the item, and no item type had to change.

  static const lockedMark = 'locked';
  static const tagMark = 'tag';
  static const groupMark = 'group';

  Object? markOf(String id, String key) => _itemUnknownFields[id]?[key];

  /// Locked items cannot be moved, resized, edited, erased or deleted.
  bool isLocked(String id) => markOf(id, lockedMark) == true;

  /// Index into the lasso/tag colors, or null.
  int? tagOf(String id) {
    final v = markOf(id, tagMark);
    return v is int && v >= 0 && v < CanvasTagColors.selected.length ? v : null;
  }

  /// The user's own tags on an item (ids into the shared registry; see
  /// tag_models.dart). Stored as a mark, so the item, its position and
  /// its geometry never change.
  static const customTagsMark = 'customTags';

  List<String> customTagsOf(String id) => [
    for (final v in markOf(id, customTagsMark) as List? ?? const [])
      if (v is String) v,
  ];

  /// Sets the custom tags of [ids] (empty removes them).
  void setCustomTags(Iterable<String> ids, List<String> tagIds) =>
      setMark(ids, customTagsMark, tagIds.isEmpty ? null : [...tagIds]);

  /// The custom tags shown on [item]: its own (mindmaps) and, for a link
  /// or photo, its Archive resource's.
  List<CustomTag> shownTagsOf(CanvasItem item) {
    final r = resources;
    if (r == null) return const [];
    final ids = <String>{...customTagsOf(item.id)};
    final assetId = switch (item) {
      LinkItem() => item.assetId,
      ImageItem() => item.assetId,
      _ => null,
    };
    if (assetId != null) {
      for (final ref in r.asset(assetId)?.linkTags ?? const <String>[]) {
        if (CustomTag.idOfAssetRef(ref) case final id?) ids.add(id);
      }
    }
    return [for (final id in ids) ?r.tag(id)];
  }

  String? groupOf(String id) {
    final v = markOf(id, groupMark);
    return v is String ? v : null;
  }

  final Set<String> _marksChanged = {};

  /// Sets (or with null removes) a mark on [ids].
  void setMark(Iterable<String> ids, String key, Object? value) {
    var changed = false;
    for (final id in ids) {
      if (itemById(id) == null || markOf(id, key) == value) continue;
      final fields = {...?_itemUnknownFields[id]};
      value == null ? fields.remove(key) : fields[key] = value;
      if (fields.isEmpty) {
        _itemUnknownFields.remove(id);
      } else {
        _itemUnknownFields[id] = fields;
      }
      _marksChanged.add(id);
      changed = true;
    }
    if (!changed) return;
    _markDirty();
    notifyListeners();
  }

  /// The marks of [ids] (to copy them along with the items).
  Map<String, Map<String, dynamic>> marksOf(Iterable<String> ids) => {
    for (final id in ids)
      if (_itemUnknownFields[id] case final m? when m.isNotEmpty) id: {...m},
  };

  /// Adds [items] (one undo step) with their [marks] (by item id), e.g.
  /// copies of tagged or grouped items.
  void addItemsWithMarks(
    List<CanvasItem> items,
    Map<String, Map<String, dynamic>> marks,
  ) {
    for (final e in marks.entries) {
      _itemUnknownFields[e.key] = {...e.value};
      _marksChanged.add(e.key);
    }
    addItems(items);
  }

  /// Applies one side of a cross-canvas move without adding a local undo
  /// entry. The transfer owner records a coordinated inverse so undo affects
  /// both canvases as one logical operation.
  void applyTransferredItems({
    List<CanvasItem> add = const [],
    Set<String> removeIds = const {},
    Map<String, Map<String, dynamic>> marks = const {},
  }) {
    if (add.isEmpty && removeIds.isEmpty) return;
    endEditing();
    for (final e in marks.entries) {
      _itemUnknownFields[e.key] = {...e.value};
      _marksChanged.add(e.key);
    }
    _setItems([
      for (final item in _items)
        if (!removeIds.contains(item.id)) item,
      ...add,
    ]);
    _selection = Set.unmodifiable({
      ..._selection.where((id) => !removeIds.contains(id)),
      ...add.map((item) => item.id),
    });
    _markDirty();
    notifyListeners();
  }

  /// Replaces every item with [items] and their [marks] (restoring a
  /// version snapshot). One undo step, so a restore can be taken back;
  /// every item is saved and synced as a change.
  void replaceAllItems(
    List<CanvasItem> items,
    Map<String, Map<String, dynamic>> marks,
  ) {
    endEditing();
    for (final i in items) {
      final m = marks[i.id];
      if (m == null || m.isEmpty) {
        _itemUnknownFields.remove(i.id);
      } else {
        _itemUnknownFields[i.id] = {...m};
      }
      _marksChanged.add(i.id);
    }
    _commit(items);
    _selection = const {};
    notifyListeners();
  }

  /// Puts [item] in place of the item with the same id (or adds it, if that
  /// item is gone): settling a sync conflict in favour of the other device's
  /// version. One undo step; the item is saved and synced as a new edit, so
  /// it wins over both earlier versions on every device.
  void restoreItem(CanvasItem item, {Map<String, dynamic>? unknownFields}) {
    endEditing();
    if (unknownFields == null || unknownFields.isEmpty) {
      _itemUnknownFields.remove(item.id);
    } else {
      _itemUnknownFields[item.id] = {...unknownFields};
    }
    _marksChanged.add(item.id);
    final index = _items.indexWhere((i) => i.id == item.id);
    _commit(index < 0 ? [..._items, item] : ([..._items]..[index] = item));
    notifyListeners();
  }

  /// Removes the item with [id] (settling a conflict in favour of a deletion).
  /// One undo step.
  void removeItemById(String id) {
    if (!_items.any((i) => i.id == id)) return;
    endEditing();
    _commit([
      for (final i in _items)
        if (i.id != id) i,
    ]);
    _selection = Set.unmodifiable(_selection.where((s) => s != id));
    notifyListeners();
  }

  /// The current version of the item [id] as it syncs (with fields this
  /// version does not know), or null.
  Map<String, dynamic>? itemJson(String id) {
    final i = _items.where((i) => i.id == id).firstOrNull;
    if (i == null) return null;
    final unknown = _itemUnknownFields[id];
    return unknown == null ? i.toJson() : {...i.toJson(), ...unknown};
  }

  /// Locks the selection, or unlocks it if every selected item is locked.
  void toggleLockSelection() {
    final allLocked = _selection.isNotEmpty && _selection.every(isLocked);
    setMark(_selection, lockedMark, allLocked ? null : true);
  }

  /// Gives the selection lasso tag [index] (null removes the tag). Several
  /// loose items tagged together (an area of strokes) become one compound
  /// object first, so the tag shows once, around all of them; existing
  /// groups keep their own boundaries.
  void tagSelection(int? index) {
    if (index != null && selectionUnits.length > 1) {
      final loose = [
        for (final i in selectedItems)
          if (i is! ConnectorItem && groupOf(i.id) == null) i.id,
      ];
      if (loose.length > 1) setMark(loose, groupMark, newId());
    }
    setMark(_selection, tagMark, index);
  }

  /// Joins the selected items into one group (selected and moved together).
  void groupSelection() {
    if (_selection.length < 2) return;
    setMark(_selection, groupMark, newId());
  }

  void ungroupSelection() => setMark(_selection, groupMark, null);

  /// [ids] plus every item grouped with one of them.
  Set<String> withGroups(Iterable<String> ids) {
    final groups = {for (final id in ids) ?groupOf(id)};
    if (groups.isEmpty) return ids.toSet();
    return {
      ...ids,
      for (final i in _items)
        if (groups.contains(groupOf(i.id))) i.id,
    };
  }

  static const referenceMark = 'reference';

  /// A reference overlay: an image or document card drawn faintly behind
  /// everything, never selected, moved or erased by drawing over it.
  bool isReference(String id) => markOf(id, referenceMark) == true;

  bool get hasReferences => _items.any((i) => isReference(i.id));

  /// Makes the selected images and document cards reference overlays.
  void makeSelectionReference() {
    final ids = [
      for (final i in selectedItems)
        if (i is ImageItem || i is LinkItem) i.id,
    ];
    setMark(ids, referenceMark, true);
    select(_selection.difference(ids.toSet()));
  }

  /// Turns every reference overlay back into an ordinary item.
  void releaseReferences() => setMark(
    [
      for (final i in _items)
        if (isReference(i.id)) i.id,
    ],
    referenceMark,
    null,
  );

  /// Rotates the selected ink by [radians] around the selection's centre
  /// (one undo step). Boxes (text, images, cards) are not rotated.
  void rotateSelection(double radians) {
    final strokes = [
      for (final i in selectedItems)
        if (i is StrokeItem && !isLocked(i.id)) i,
    ];
    if (strokes.isEmpty) return;
    var area = strokes.first.bounds;
    for (final s in strokes) {
      area = area.expandToInclude(s.bounds);
    }
    final c = area.center;
    final cos = math.cos(radians), sin = math.sin(radians);
    StrokeItem turn(StrokeItem s) => StrokeItem(
      id: s.id,
      points: [
        for (final p in s.points)
          StrokePoint(
            c.dx + (p.x - c.dx) * cos - (p.y - c.dy) * sin,
            c.dy + (p.x - c.dx) * sin + (p.y - c.dy) * cos,
            p.pressure,
          ),
      ],
      color: s.color,
      strokeWidth: s.strokeWidth,
      pressureWidth: s.pressureWidth,
    );
    final changes = {for (final s in strokes) s.id: turn(s)};
    _commit([for (final i in _items) changes[i.id] ?? i]);
    notifyListeners();
  }

  /// Recolors the selected strokes and texts (one undo step). Locked items
  /// keep their colors.
  void recolorSelection(Color color) {
    final changes = <String, CanvasItem>{
      for (final item in selectedItems)
        if (!isLocked(item.id))
          if (item is StrokeItem)
            item.id: item.recolored(color)
          else if (item is TextItem)
            item.id: item.copyWith(textColor: () => color),
    };
    if (changes.isEmpty) return;
    _commit([for (final i in _items) changes[i.id] ?? i]);
    notifyListeners();
  }

  /// Applies [change] to every selected text note as one undo step.
  void updateSelectedTexts(TextItem Function(TextItem) change) {
    final changes = <String, CanvasItem>{
      for (final item in selectedItems)
        if (item is TextItem && !isLocked(item.id)) item.id: change(item),
    };
    if (changes.isEmpty) return;
    _commit([for (final i in _items) changes[i.id] ?? i]);
    notifyListeners();
  }

  void setFontSize(double size) =>
      updateSelectedTexts((t) => t.copyWith(fontSize: size));

  /// Copies of the selected items, offset slightly, become the selection.
  void duplicateSelection() {
    addItems(_copies(selectedItems, const Offset(24, 24)));
  }

  /// New copies of [items] moved by [delta]. Connections are copied only
  /// when both their ends are copied, and then join the copies.
  static List<CanvasItem> _copies(List<CanvasItem> items, Offset delta) =>
      copyItems(items, delta).$1;

  /// Copies of [items] with new ids, moved by [delta] (connections between
  /// copied items join the copies), and old id → new id.
  static (List<CanvasItem>, Map<String, String>) copyItems(
    List<CanvasItem> items,
    Offset delta,
  ) {
    final newIds = <String, String>{};
    final copies = <CanvasItem>[];
    for (final item in items) {
      if (item is ConnectorItem) continue;
      final id = newId();
      newIds[item.id] = id;
      copies.add(item.withId(id).translated(delta));
    }
    return ([...copies, ..._remapConnectors(items, newIds)], newIds);
  }

  /// Adds [items] as one undo step and selects them.
  void addItems(List<CanvasItem> items) {
    if (items.isEmpty) return;
    endEditing();
    _commit([..._items, ...items]);
    _tool = CanvasTool.select;
    _selection = Set.unmodifiable(items.map((i) => i.id));
    notifyListeners();
  }

  /// Pastes copies of [items] centred on [world].
  void pasteItems(List<CanvasItem> items, Offset world) {
    final placed = items.where((i) => i is! ConnectorItem);
    if (placed.isEmpty) return;
    final bounds = placed
        .map((i) => i.bounds)
        .reduce((a, b) => a.expandToInclude(b));
    addItems(_copies(items, world - bounds.center));
  }

  void bringToFront() {
    final selected = selectedItems;
    if (selected.isEmpty) return;
    _commit([..._items.where((i) => !_selection.contains(i.id)), ...selected]);
    notifyListeners();
  }

  void sendToBack() {
    final selected = selectedItems;
    if (selected.isEmpty) return;
    _commit([...selected, ..._items.where((i) => !_selection.contains(i.id))]);
    notifyListeners();
  }

  /// Places an image (keeping its aspect ratio) centred on [world].
  ImageItem insertImage(Asset asset, Offset world, {double maxSide = 480}) {
    final w = (asset.width ?? 400).toDouble();
    final h = (asset.height ?? 300).toDouble();
    final fit = math.min(1.0, maxSide / math.max(w, h));
    final size = Size(w * fit, h * fit);
    final item = ImageItem(
      id: newId(),
      assetId: asset.id,
      position: world - size.center(Offset.zero),
      width: size.width,
      minHeight: size.height,
    );
    addItems([item]);
    return item;
  }

  LinkItem insertLink(Asset asset, Offset world) {
    final item = LinkItem(
      id: newId(),
      assetId: asset.id,
      position: world - const Offset(LinkItem.defaultWidth / 2, 40),
      width: LinkItem.defaultWidth,
    );
    addItems([item]);
    return item;
  }

  NoteCardItem insertNoteCard(String noteId, Offset world) {
    final item = NoteCardItem(
      id: newId(),
      noteId: noteId,
      position: world - const Offset(150, 60),
      width: 300,
    );
    addItems([item]);
    return item;
  }

  /// A plain note with [text] centred on [world].
  TextItem insertText(String text, Offset world) {
    final width = math.min(
      420.0,
      math.max(TextItem.defaultWidth, text.length * 4.0),
    );
    final item = TextItem(
      id: newId(),
      position: world - Offset(width / 2, 20),
      width: width,
      minHeight: 0,
      text: text,
    );
    addItems([item]);
    return item;
  }

  // -------------------------------------------------------------- editing --

  String? _editingId;
  String? get editingId => _editingId;
  TextItem? get editingItem {
    final item = _editingId == null ? null : itemById(_editingId!);
    return item is TextItem ? item : null;
  }

  void beginEditing(String id) {
    if (_editingId == id || isLocked(id)) return;
    endEditing();
    _beginTransaction();
    _editingId = id;
    _selection = {id};
    notifyListeners();
  }

  /// Live text updates while typing; recorded as one undo step on finish.
  void updateEditingText(String text) {
    final item = editingItem;
    if (item == null || item.text == text) return;
    _replaceItems({item.id: item.copyWith(text: text)});
    notifyListeners();
  }

  void endEditing() {
    final item = editingItem;
    if (item == null) {
      _editingId = null;
      return;
    }
    _editingId = null;
    if (item.text.trim().isEmpty) {
      _setItems([
        for (final i in _items)
          if (i.id != item.id) i,
      ]);
      _selection = const {};
    }
    // Typing is the text tool's own business: it leaves nothing selected
    // (only Select and Lasso hold a selection).
    if (!selectsItems) _selection = const {};
    _endTransaction();
    notifyListeners();
  }

  /// How a new text box starts. The defaults are the Mindmap's and the
  /// notebook's; the Calendar sets smaller ones (a day is a small square)
  /// and has its boxes use the pen colour.
  double newTextWidth = TextItem.defaultWidth;
  double? newTextFontSize;
  bool newTextUsesPenColor = false;

  TextItem createText(Offset world) {
    endEditing();
    final fontSize = newTextFontSize;
    final item = TextItem(
      id: newId(),
      position: world - const Offset(kTextPadding, kTextPadding),
      width: newTextWidth,
      minHeight: 0,
      text: '',
      fontSize: fontSize ?? 16,
      textColor: newTextUsesPenColor ? penColor : null,
    );
    _beginTransaction();
    _setItems([..._items, item]);
    _editingId = item.id;
    _selection = {item.id};
    notifyListeners();
    return item;
  }

  // ---------------------------------------------------------- undo / redo --

  final List<List<CanvasItem>> _undo = [];
  final List<List<CanvasItem>> _redo = [];
  List<CanvasItem>? _txSnapshot;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void _pushUndo(List<CanvasItem> snapshot) {
    _undo.add(snapshot);
    if (_undo.length > historyLimit) _undo.removeAt(0);
    _redo.clear();
  }

  /// Records the current items as one undoable step, then applies [items].
  void _commit(List<CanvasItem> items) {
    cancelPendingLineStraightening();
    _pushUndo(_items);
    _setItems(items);
  }

  /// Multi-frame edits (dragging, drawing, typing) become one undo step.
  void _beginTransaction() => _txSnapshot ??= _items;

  void _endTransaction() {
    final snapshot = _txSnapshot;
    _txSnapshot = null;
    if (snapshot != null && !listEquals(snapshot, _items)) {
      _pushUndo(snapshot);
    }
  }

  void undo() {
    cancelPendingLineStraightening();
    endEditing();
    if (_undo.isEmpty) return;
    _redo.add(_items);
    _setItems(_undo.removeLast());
    _pruneSelection();
    notifyListeners();
  }

  void redo() {
    cancelPendingLineStraightening();
    endEditing();
    if (_redo.isEmpty) return;
    _undo.add(_items);
    _setItems(_redo.removeLast());
    _pruneSelection();
    notifyListeners();
  }

  void _pruneSelection() {
    final ids = _items.map((i) => i.id).toSet();
    _selection = Set.unmodifiable(_selection.where(ids.contains));
  }

  // --------------------------------------------------------------- layout --

  final Map<String, ({TextItem item, TextPainter painter})> _layouts = {};
  final Map<String, ({BoxItem item, CardLayout layout})> _cards = {};

  /// A laid-out painter for [item], cached until the item changes.
  TextPainter textLayout(TextItem item) {
    final cached = _layouts[item.id];
    if (cached != null &&
        cached.item.text == item.text &&
        cached.item.width == item.width &&
        cached.item.fontSize == item.fontSize &&
        cached.item.bold == item.bold &&
        cached.item.italic == item.italic &&
        cached.item.align == item.align &&
        cached.item.textColor == item.textColor) {
      return cached.painter;
    }
    cached?.painter.dispose();
    final painter = layoutText(
      formattedSpan(item.text, styleFor(item)),
      item.width - kTextPadding * 2,
      align: textAlignFor(item.align),
    );
    _layouts[item.id] = (item: item, painter: painter);
    return painter;
  }

  /// Layout for link and note cards, cached until the item or its shared
  /// record changes.
  CardLayout cardLayout(BoxItem item) {
    final cached = _cards[item.id];
    if (cached != null &&
        cached.item.width == item.width &&
        cached.item.minHeight == item.minHeight) {
      return cached.layout;
    }
    cached?.layout.dispose();
    final CardLayout layout;
    switch (item) {
      case LinkItem():
        final asset = resources?.asset(item.assetId);
        layout = layoutLinkCard(
          item,
          asset,
          hasPreview: asset?.previewFile != null,
        );
      case NoteCardItem():
        layout = layoutNoteCard(item, resources?.note(item.noteId));
      case TextItem() || ImageItem():
        layout = CardLayout(height: item.minHeight, lines: const []);
    }
    _cards[item.id] = (item: item, layout: layout);
    return layout;
  }

  void _clearCardLayouts() {
    for (final c in _cards.values) {
      c.layout.dispose();
    }
    _cards.clear();
  }

  /// Real on-canvas bounds: text and cards grow to fit their content.
  Rect itemBounds(CanvasItem item) {
    switch (item) {
      case TextItem():
        final height = textLayout(item).height + kTextPadding * 2;
        return item.position &
            Size(item.width, math.max(item.minHeight, height));
      case final BoxItem box when box is LinkItem || box is NoteCardItem:
        return box.position & Size(box.width, cardLayout(box).height);
      case LinkItem() || NoteCardItem():
        return item.bounds;
      case ImageItem():
        return item.bounds;
      case StrokeItem():
        return item.bounds;
      case ConnectorItem():
        final path = connectorPath(item);
        if (path == null) return Rect.zero;
        var r = Rect.fromPoints(path.first, path.last);
        for (final p in path) {
          r = r.expandToInclude(Rect.fromPoints(p, p));
        }
        return r;
    }
  }

  /// Where [c]'s line starts and ends: on the edges of the two connected
  /// items, along the line between their centres. Null while an end is
  /// missing (deleted, or not synced yet), so the line is not drawn.
  (Offset, Offset)? connectorEnds(ConnectorItem c) {
    final a = itemById(c.fromId), b = itemById(c.toId);
    if (!isConnectable(a) || !isConnectable(b)) return null;
    // A stroke end is a fixed point on its ink; a box end sits on its edge
    // facing the other end.
    final pa = a is StrokeItem ? strokeAnchor(a, c.fromT ?? 0) : null;
    final pb = b is StrokeItem ? strokeAnchor(b, c.toT ?? 1) : null;
    final ra = itemBounds(a!), rb = itemBounds(b!);
    return (
      pa ?? _edgePoint(ra, pb ?? rb.center),
      pb ?? _edgePoint(rb, pa ?? ra.center),
    );
  }

  /// The line of [c] as points: its two ends, with the hand-drawn curve
  /// between them when it has one. Null while an end is missing.
  List<Offset>? connectorPath(ConnectorItem c) {
    final ends = connectorEnds(c);
    if (ends == null) return null;
    return sampleConnector(ends.$1, ends.$2, c.curve);
  }

  /// Objects and drawn lines can be connected (not connections themselves).
  static bool isConnectable(CanvasItem? i) => i is BoxItem || i is StrokeItem;

  /// The point of stroke [s] at share [t] of its points (see
  /// [ConnectorItem.fromT]).
  static Offset strokeAnchor(StrokeItem s, double t) {
    if (s.points.isEmpty) return s.bounds.center;
    final i = (t.clamp(0.0, 1.0) * (s.points.length - 1)).round();
    return s.points[i].offset;
  }

  /// Where on stroke [s] a connection made at [world] attaches: its first
  /// or last point when near one (snapping to the line's ends), else its
  /// nearest point.
  double strokeAnchorAt(StrokeItem s, Offset world) {
    final n = s.points.length;
    if (n < 2) return 0;
    final snap = 14 / _scale;
    if ((s.points.first.offset - world).distance <= snap) return 0;
    if ((s.points.last.offset - world).distance <= snap) return 1;
    var best = 0, bestD = double.infinity;
    for (var i = 0; i < n; i++) {
      final d = (s.points[i].offset - world).distanceSquared;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best / (n - 1);
  }

  /// Where a connection made at [world] onto [target] would attach.
  Offset _attachPoint(CanvasItem target, Offset world, Offset from) =>
      target is StrokeItem
      ? strokeAnchor(target, strokeAnchorAt(target, world))
      : _edgePoint(itemBounds(target), from);

  /// Point where the line from [r]'s centre towards [target] leaves [r].
  static Offset _edgePoint(Rect r, Offset target) {
    final d = target - r.center;
    if (d.dx == 0 && d.dy == 0) return r.center;
    final sx = d.dx == 0 ? double.infinity : (r.width / 2) / d.dx.abs();
    final sy = d.dy == 0 ? double.infinity : (r.height / 2) / d.dy.abs();
    final t = math.min(1.0, math.min(sx, sy));
    return r.center + d * t;
  }

  /// Connections whose ends are both among [ids]' items, given new ids.
  static List<ConnectorItem> _remapConnectors(
    Iterable<CanvasItem> items,
    Map<String, String> newIds,
  ) => [
    for (final c in items.whereType<ConnectorItem>())
      if (newIds.containsKey(c.fromId) && newIds.containsKey(c.toId))
        c.rejoined(newId(), newIds[c.fromId]!, newIds[c.toId]!),
  ];

  // --------------------------------------------------------- hit testing --

  /// Topmost item under [world], or null.
  /// The item under [world] in the order things are drawn: objects and
  /// strokes from the top down, then the connections (which are drawn
  /// underneath them), then nothing (empty canvas). Reference overlays are
  /// never hit.
  CanvasItem? hitTest(Offset world) {
    final tolerance = 6 / _scale;
    for (final item in _items.reversed) {
      if (isReference(item.id)) continue; // behind the ink, not selectable
      switch (item) {
        case BoxItem():
          if (itemBounds(item).contains(world)) return item;
        case StrokeItem():
          if (item.hitTest(world, tolerance)) return item;
        case ConnectorItem():
          break;
      }
    }
    for (final item in _items.reversed.whereType<ConnectorItem>()) {
      final path = connectorPath(item);
      if (path != null && distanceToPolyline(world, path) <= tolerance) {
        return item;
      }
    }
    return null;
  }

  /// Size of the resize handle on screen, in logical pixels.
  static const double handleSize = 10;

  /// Area around the resize handle that grabs it: a finger or pen needs a
  /// bigger target than a mouse (Apple's guideline is 44 points).
  static double handleHitSize(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad
      ? handleSize + 8
      : 44;

  /// How far apart two taps may be and still count as a double tap.
  static double doubleTapSlop(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad
      ? 6
      : 24;

  /// The selection's resize dot (top-right corner of its boundary) when
  /// it is under [screen]: returns the first selected item, else null.
  CanvasItem? resizeHandleAt(
    Offset screen, {
    PointerDeviceKind kind = PointerDeviceKind.mouse,
  }) {
    if (_tool != CanvasTool.select) return null;
    final items = [
      for (final i in selectedItems)
        if (i is! ConnectorItem) i,
    ];
    if (items.isEmpty || items.any((i) => isLocked(i.id))) return null;
    final item = items.first;
    final corner = toScreen(boundsOf(items)!.topRight);
    final size = handleHitSize(kind);
    final hit = Rect.fromCenter(center: corner, width: size, height: size);
    return hit.contains(screen) ? item : null;
  }

  // ---------------------------------------------------------- live state --

  StrokeItem? _liveStroke;

  /// The points have grown since [_liveStroke] was built. Pen movements only
  /// set this (O(1) per event, however many events one frame brings: Apple
  /// Pencil delivers up to 240 a second); the stroke object, with its copy
  /// of the points and its bounds, is rebuilt once per frame when painted.
  bool _liveStale = false;

  StrokeItem? get liveStroke {
    if (_liveStale && _liveStroke != null) _updateLiveStroke();
    return _liveStroke;
  }

  List<StrokePoint> _livePoints = [];

  /// Repaints only the stroke being drawn. Drawing does not notify the
  /// controller's own listeners (which rebuild and repaint the whole
  /// canvas) on every pen movement; that was the main source of lag.
  final ChangeNotifier liveInk = _Ping();

  /// The live stroke's shape, kept between frames (see LiveInkGeometry).
  final LiveInkGeometry liveGeometry = LiveInkGeometry();

  /// The live stroke comes from Apple Pencil: width follows pressure.
  bool _livePressure = false;

  // Short look-ahead of the pen tip (drawn, never stored): velocity of the
  // last movement, in world units per millisecond.
  Duration? _lastMoveTime;
  Offset? _velocity;

  /// How far ahead the live stroke is drawn (0 turns it off).
  static Duration predictionHorizon = const Duration(milliseconds: 12);

  /// Where the pen is expected to be next, or null.
  Offset? get predictedPoint {
    final v = _velocity;
    if (_drag != _Drag.draw || _livePoints.isEmpty) return null;
    if (_hasExternalPrediction) {
      final p = _externalPrediction;
      if (p == null) return null;
      // UIKit predicts about one frame ahead; a wild guess (a fast flick)
      // is shortened so it can never draw a visible spike.
      final last = _livePoints.last.offset;
      final ahead = p - last;
      final maxAhead = 24 / _scale;
      return ahead.distance <= maxAhead
          ? p
          : last + ahead / ahead.distance * maxAhead;
    }
    if (v == null) return null;
    var ahead = v * (predictionHorizon.inMicroseconds / 1000);
    final maxAhead = 12 / _scale; // never more than 12 screen pixels
    if (ahead.distance > maxAhead) ahead = ahead / ahead.distance * maxAhead;
    return _livePoints.last.offset + ahead;
  }

  /// A line-like stroke is straightened after a 1.2-second dwell.
  static Duration holdToStraighten = const Duration(milliseconds: 1200);
  Timer? _holdTimer;
  Offset? _holdAnchor;
  StrokeItem? _pendingStraighten;
  CanvasTool? _pendingStraightenTool;
  List<StrokePoint>? _liveLinePreview;
  StrokeItem? get lineStraightenPreview {
    final live = _liveLinePreview;
    final base = _liveStroke;
    if (live != null && base != null) {
      return StrokeItem(
        id: base.id,
        color: base.color,
        strokeWidth: base.strokeWidth,
        pressureWidth: base.pressureWidth,
        points: live,
      );
    }
    return null;
  }

  /// Cancels delayed straightening when input changes context.
  void cancelPendingLineStraightening() {
    final hadPreview = _liveLinePreview != null;
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdAnchor = null;
    _pendingStraighten = null;
    _pendingStraightenTool = null;
    _liveLinePreview = null;
    if (hadPreview && !_disposed) (liveInk as _Ping).ping();
  }

  void _restartLineHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _liveLinePreview = null;
    // Whether the stroke is line-like is judged when the hold timer fires
    // (below), not at every pen movement: that check walks every point, so
    // doing it per movement made a long stroke slower the longer it got.
    if (_livePoints.length < 2) {
      (liveInk as _Ping).ping();
      return;
    }
    _pendingStraightenTool = _tool;
    _holdTimer = Timer(holdToStraighten, () {
      _holdTimer = null;
      if (_disposed || _tool != _pendingStraightenTool) {
        cancelPendingLineStraightening();
        return;
      }
      if (_drag == _Drag.draw) {
        if (!looksLikeLine(_livePoints, _scale)) return;
        _liveLinePreview = straightened(_livePoints);
        (liveInk as _Ping).ping();
        return;
      }
      final original = _pendingStraighten;
      _pendingStraighten = null;
      _pendingStraightenTool = null;
      if (original == null) return;
      final current = itemById(original.id);
      if (current != original || current is! StrokeItem) return;
      final replacement = StrokeItem(
        id: original.id,
        color: original.color,
        strokeWidth: original.strokeWidth,
        pressureWidth: original.pressureWidth,
        points: straightened(original.points),
      );
      _commit([
        for (final item in _items) item.id == original.id ? replacement : item,
      ]);
      (liveInk as _Ping).ping();
      notifyListeners();
    });
  }

  void _scheduleLineStraightening(StrokeItem stroke) {
    if (!looksLikeLine(stroke.points, _scale)) {
      cancelPendingLineStraightening();
      return;
    }
    _pendingStraighten = stroke;
    _pendingStraightenTool = _tool;
    if (_holdTimer == null && _liveLinePreview == null) {
      _restartLineHold();
    }
    (liveInk as _Ping).ping();
  }

  /// Items drawn faded, e.g. links outside the chosen tag in the Links
  /// library. Display only; nothing is changed or saved.
  bool Function(CanvasItem item)? get dimmed => _dimmed;
  bool Function(CanvasItem item)? _dimmed;
  Color? Function(CanvasItem item)? _highlighted;
  Color? Function(CanvasItem item)? get highlighted => _highlighted;
  set highlighted(Color? Function(CanvasItem item)? value) {
    _highlighted = value;
    notifyListeners();
  }

  set dimmed(bool Function(CanvasItem item)? value) {
    _dimmed = value;
    notifyListeners();
  }

  // Apple Pencil Pro squeeze: eraser while squeezed, then the tool before.
  CanvasTool? _toolBeforeSqueeze;

  /// The eraser is on only because the Pencil is being squeezed.
  bool get squeezeEraser => _toolBeforeSqueeze != null;

  void squeezeBegan() {
    if (_toolBeforeSqueeze != null || _tool == CanvasTool.eraser) return;
    final before = _tool;
    tool = CanvasTool.eraser;
    _toolBeforeSqueeze = before;
    notifyListeners();
  }

  /// Squeeze released or cancelled (also when the view goes away).
  void squeezeEnded() {
    final before = _toolBeforeSqueeze;
    if (before == null) return;
    _toolBeforeSqueeze = null;
    if (_disposed) return;
    tool = before;
    notifyListeners();
  }

  List<Offset> _lassoPoints = [];
  List<Offset> get lassoPoints => _lassoPoints;

  Rect? _marquee;
  Rect? get marquee => _marquee;

  Offset? _hover;
  Offset? get hoverPosition => _hover;

  /// Last pointer position on the canvas (screen space), for pasting.
  Offset? lastPointer;

  // ------------------------------------------------------------- pointers --

  _Drag _drag = _Drag.none;
  Offset _lastScreen = Offset.zero;
  Offset _dragStartWorld = Offset.zero;
  final Set<String> _selectionAtDragStart = const {};

  /// Set by a click on an already selected group: on release without a
  /// drag, only this item stays selected.
  String? _narrowTo;
  CanvasItem? _resizeOriginal;
  List<CanvasItem> _resizeItems = const [];
  Rect? _resizeBounds;
  Duration? _lastDownTime;
  Offset? _lastDownPos;
  PointerDeviceKind _kind = PointerDeviceKind.mouse;

  bool get isPanning => _drag == _Drag.pan;
  bool get isDragging => _drag != _Drag.none;

  /// The order of this drawing's last pointer input among all drawings
  /// (to send an Apple Pencil double-tap to the drawing in use). A counter,
  /// not a time: two inputs can share a clock tick.
  int lastInput = 0;
  static int _inputCount = 0;

  void pointerDown(
    Offset screen, {
    int buttons = kPrimaryButton,
    PointerDeviceKind kind = PointerDeviceKind.mouse,
    double pressure = 0.5,
    bool shift = false,
    bool ctrl = false,
    Duration timeStamp = Duration.zero,
  }) {
    cancelPendingLineStraightening();
    _lastScreen = screen;
    lastInput = ++_inputCount;
    lastPointer = screen;
    _kind = kind;
    final world = toWorld(screen);
    _dragStartWorld = world;

    final isDouble =
        _lastDownTime != null &&
        _lastDownPos != null &&
        timeStamp - _lastDownTime! < doubleClickTime &&
        (screen - _lastDownPos!).distance < doubleTapSlop(kind);
    _lastDownTime = isDouble ? null : timeStamp;
    _lastDownPos = screen;

    // Middle mouse button, space bar or the hand tool always pans.
    if (buttons & kMiddleMouseButton != 0 ||
        spaceHeld ||
        _tool == CanvasTool.pan) {
      _drag = _Drag.pan;
      notifyListeners();
      return;
    }
    if (buttons & kPrimaryButton == 0) return;

    // Inverted stylus tip (e.g. Apple Pencil / digital pen eraser end)
    if (kind == PointerDeviceKind.invertedStylus) {
      endEditing();
      _beginTransaction();
      _drag = _Drag.erase;
      _eraseAt(world, world);
      notifyListeners();
      return;
    }

    switch (_tool) {
      case CanvasTool.pan:
        break;
      case CanvasTool.select:
        _selectDown(
          screen,
          world,
          shift: shift,
          ctrl: ctrl,
          isDouble: isDouble,
          kind: kind,
        );
      case CanvasTool.lasso:
        // Pressing on the lassoed items moves them, as with the select tool.
        final hit = hitTest(world);
        if (hit != null && _selection.contains(hit.id)) {
          _selectDown(
            screen,
            world,
            shift: false,
            ctrl: false,
            isDouble: false,
          );
        } else {
          endEditing();
          _drag = _Drag.lasso;
          _lassoPoints = [world];
        }
      case CanvasTool.text:
        final hit = hitTest(world);
        if (hit is TextItem) {
          beginEditing(hit.id);
        } else {
          createText(world);
        }
      case CanvasTool.pen || CanvasTool.highlighter:
        final wasEditing = _editingId != null;
        endEditing();
        _beginTransaction();
        _drag = _Drag.draw;
        _liveIsStylus = kind == PointerDeviceKind.stylus;
        _firstPressure = pressure;
        // Pressure-shaped ink only once this Pencil has shown it reports
        // pressure (Apple Pencil USB-C and some pens do not): see
        // [_addLiveSample]. Until then the line keeps the chosen width.
        _livePressure = _liveIsStylus && pencilPressureSeen;
        _velocity = null;
        _externalPrediction = null;
        _hasExternalPrediction = false;
        _lastMoveTime = timeStamp;
        _livePoints = [StrokePoint(world.dx, world.dy, pressure)];
        _updateLiveStroke();
        InkMetrics.instance
          ..strokeStarted()
          ..sampleKept();
        // Only the live layer repaints. Notifying everyone here rebuilt the
        // whole page and repainted every stroke of the document in the
        // very frame that should show the first ink (measured: the most
        // expensive frame of a stroke on large documents).
        (liveInk as _Ping).ping();
        if (wasEditing) notifyListeners();
        return;
      case CanvasTool.eraser:
        endEditing();
        _beginTransaction();
        _drag = _Drag.erase;
        _eraseAt(world, world);
      case CanvasTool.connect:
        endEditing();
        if (_pendingFrom != null) {
          // Second tap: the target is chosen when the finger lifts, so a
          // pinch or pan in between (to reach a far item) cancels nothing.
          _drag = _Drag.connectTap;
          _tapAt = world;
          _tapScreen = screen;
          _tapMoved = false;
        } else {
          final hit = hitTest(world);
          if (isConnectable(hit)) _startConnect(hit!, world);
        }
    }
    notifyListeners();
  }

  String? _connectFrom;
  Offset? _connectEnd;

  /// The pencil's path during a connect drag, in world coordinates (the
  /// same pointer tracking as drawing, so zoom and pan do not matter). Only
  /// its refined shape is ever kept (see connector_path.dart).
  final List<Offset> _connectTrail = [];

  void _trackConnect(Offset world) {
    if (_connectTrail.isEmpty ||
        (world - _connectTrail.last).distance * _scale >= 1.5) {
      _connectTrail.add(world);
    } else {
      // Keep the newest position as the last point.
      _connectTrail[_connectTrail.length - 1] = world;
    }
  }

  /// Where on a drawn line the connection starts (see ConnectorItem.fromT).
  double? _fromT;

  /// Source item chosen with a tap (touch): the next tap on another item
  /// connects the two. Tapping it again or empty space cancels.
  String? _pendingFrom;
  Offset? _tapAt;
  Offset? _tapScreen;
  bool _tapMoved = false;

  /// Starts a connection from [hit] (an object or a drawn line) at [world].
  void _startConnect(CanvasItem hit, Offset world) {
    _drag = _Drag.connect;
    _connectFrom = hit.id;
    _connectEnd = world;
    _connectTrail
      ..clear()
      ..add(world);
    _fromT = hit is StrokeItem ? strokeAnchorAt(hit, world) : null;
  }

  /// The item a connection is being made from (highlighted on screen).
  String? get connectSource => _connectFrom ?? _pendingFrom;

  /// The item the live connection would attach to now (highlighted), or
  /// null over empty canvas or the source itself.
  String? get connectTarget {
    final end =
        _connectEnd ??
        (_pendingFrom != null && _hover != null ? toWorld(_hover!) : null);
    if (end == null) return null;
    final hit = hitTest(end);
    return isConnectable(hit) && hit!.id != connectSource ? hit.id : null;
  }

  /// Cancels a connection waiting for its second tap.
  void cancelConnect() {
    if (_pendingFrom == null) return;
    _pendingFrom = null;
    _fromT = null;
    notifyListeners();
  }

  /// Line being drawn with the connect tool (start → pointer). Over a valid
  /// target its end snaps to where it would attach (a stroke's end or
  /// nearest point, or an object's edge).
  (Offset, Offset)? get liveConnection {
    final fromId = _connectFrom ?? _pendingFrom;
    final from = fromId == null ? null : itemById(fromId);
    // While waiting for the second tap, a mouse shows the line to the
    // pointer; on touch there is no hover, so the source is highlighted.
    var end =
        _connectEnd ??
        (_pendingFrom != null && _hover != null ? toWorld(_hover!) : null);
    if (from == null || end == null) return null;
    final start = from is StrokeItem
        ? strokeAnchor(from, _fromT ?? 0)
        : _edgePoint(itemBounds(from), end);
    final targetId = connectTarget;
    final target = targetId == null ? null : itemById(targetId);
    if (target != null) {
      // The ends the finished connection will really have, so nothing
      // moves when the pencil lifts.
      final joined = connectorEnds(_pending(from.id, target, end));
      if (joined != null) return joined;
      end = _attachPoint(target, end, start);
    }
    return (start, end);
  }

  /// The connection that releasing at [at] over [target] would make, as a
  /// straight one (for measuring its ends).
  ConnectorItem _pending(String fromId, CanvasItem target, Offset at) =>
      ConnectorItem(
        id: 'pending',
        fromId: fromId,
        toId: target.id,
        fromT: _fromT,
        toT: target is StrokeItem ? strokeAnchorAt(target, at) : null,
      );

  List<Offset>? _livePathCache;
  int _livePathTrail = -1;
  Offset? _livePathEnd;
  double _livePathScale = 0;

  /// The refined line of the connection being drawn (null: a straight
  /// one). It is the same fit that is stored when the pencil lifts.
  List<Offset>? get livePath {
    final live = liveConnection;
    if (live == null || _connectFrom == null || _connectTrail.length < 3) {
      return null;
    }
    if (_livePathTrail == _connectTrail.length &&
        _livePathEnd == live.$2 &&
        _livePathScale == _scale) {
      return _livePathCache;
    }
    final keys = _fitFor(
      _connectFrom!,
      connectTarget == null ? null : itemById(connectTarget!),
      live.$1,
      live.$2,
    );
    _livePathTrail = _connectTrail.length;
    _livePathEnd = live.$2;
    _livePathScale = _scale;
    return _livePathCache = keys == null
        ? null
        : sampleConnector(live.$1, live.$2, keys);
  }

  /// The curve for the pencil's trail between [a] and [b]: the part of the
  /// trail inside the two boxes is not part of the line.
  List<Offset>? _fitFor(String fromId, CanvasItem? target, Offset a, Offset b) {
    final source = itemById(fromId);
    var trail = List<Offset>.of(_connectTrail);
    bool inside(CanvasItem? item, Offset p) =>
        item is BoxItem && itemBounds(item).contains(p);
    while (trail.length > 3 && inside(source, trail.first)) {
      trail.removeAt(0);
    }
    while (trail.length > 3 && inside(target, trail.last)) {
      trail.removeLast();
    }
    return fitConnector(trail, a, b, tolerance: 3 / _scale);
  }

  /// Finishes a connect drag: joins the two items. Released on the same
  /// item (a tap), it waits for a tap on the target instead.
  void _finishConnect() {
    final fromId = _connectFrom, end = _connectEnd;
    _connectFrom = null;
    _connectEnd = null;
    if (fromId == null || end == null) return;
    final target = hitTest(end);
    if (isConnectable(target) && target!.id == fromId) {
      _pendingFrom = fromId;
      return;
    }
    if (isConnectable(target)) {
      _connect(fromId, target!, end, trail: List.of(_connectTrail));
    }
    _connectTrail.clear();
    _fromT = null;
  }

  /// Second tap of a tap-tap connection.
  void _finishConnectTap() {
    final fromId = _pendingFrom, at = _tapAt;
    _tapAt = _tapScreen = null;
    if (fromId == null || at == null || _tapMoved) return;
    _pendingFrom = null;
    final target = hitTest(at);
    if (isConnectable(target) && target!.id != fromId) {
      _connect(fromId, target, at);
    }
    _fromT = null;
  }

  /// Joins two items unless one is gone or they are already joined at the
  /// same places. A drawn line keeps where on it the connection attaches.
  void _connect(
    String fromId,
    CanvasItem target,
    Offset at, {
    List<Offset>? trail,
  }) {
    if (itemById(fromId) == null || itemById(target.id) == null) return;
    final toT = target is StrokeItem ? strokeAnchorAt(target, at) : null;
    final fromT = _fromT;
    final exists = _items.any(
      (i) =>
          i is ConnectorItem &&
          i.joins(fromId, target.id) &&
          i.fromT == fromT &&
          i.toT == toT,
    );
    if (exists) return;
    var made = ConnectorItem(
      id: newId(),
      fromId: fromId,
      toId: target.id,
      fromT: fromT,
      toT: toT,
    );
    // A hand-drawn gesture becomes a clean curve (or stays straight if it
    // was nearly straight); a tap-tap connection is straight.
    final ends = connectorEnds(made);
    if (trail != null && trail.length >= 3 && ends != null) {
      final saved = List<Offset>.of(_connectTrail);
      _connectTrail
        ..clear()
        ..addAll(trail);
      final keys = _fitFor(fromId, target, ends.$1, ends.$2);
      _connectTrail
        ..clear()
        ..addAll(saved);
      if (keys != null) {
        made = ConnectorItem(
          id: made.id,
          fromId: fromId,
          toId: target.id,
          fromT: fromT,
          toT: toT,
          curve: keys,
        );
      }
    }
    _commit([..._items, made]);
  }

  void _selectDown(
    Offset screen,
    Offset world, {
    required bool shift,
    required bool ctrl,
    required bool isDouble,
    PointerDeviceKind kind = PointerDeviceKind.mouse,
  }) {
    final handle = resizeHandleAt(screen, kind: kind);
    if (handle != null && !isLocked(handle.id)) {
      endEditing();
      _beginTransaction();
      _drag = _Drag.resize;
      _resizeOriginal = handle;
      _resizeItems = [
        for (final i in selectedItems)
          if (i is! ConnectorItem) i,
      ];
      _resizeBounds = boundsOf(_resizeItems);
      return;
    }

    final hit = hitTest(world);
    final opensSomething =
        hit is LinkItem ||
        hit is NoteCardItem ||
        hit is ImageItem ||
        (hit is TextItem && hit.sourceNoteId != null);
    if (opensSomething && (isDouble || ctrl)) {
      // Double-click (or Ctrl+click) opens the link / note.
      onActivate?.call(hit!);
      if (isDouble) return;
    }
    if (isDouble) {
      if (hit is TextItem) {
        beginEditing(hit.id);
      } else if (hit == null) {
        createText(world);
      }
      return;
    }
    if (_editingId != null && hit?.id == _editingId) return;
    endEditing();

    // Tapping selects only photos and links (and keeps what a lasso already
    // selected movable); everything else is selected with the lasso tool.
    final selectable =
        hit != null &&
        (hit is LinkItem || hit is ImageItem || _selection.contains(hit.id));
    if (hit != null && !selectable) {
      if (!shift) _selection = const {};
      return;
    }
    if (hit != null) {
      // A grouped item brings its whole group.
      final picked = withGroups({hit.id});
      if (shift) {
        final next = {..._selection};
        if (next.contains(hit.id)) {
          next.removeAll(picked);
        } else {
          next.addAll(picked);
        }
        _selection = Set.unmodifiable(next);
      } else if (!_selection.contains(hit.id)) {
        _selection = Set.unmodifiable(picked);
      } else if (picked.length > 1 &&
          _selection.length == picked.length &&
          _selection.containsAll(picked)) {
        // A second click on a selected group (without dragging) picks
        // just the item under the pointer.
        _narrowTo = hit.id;
      }
      if (_selection.contains(hit.id)) {
        _beginTransaction();
        _drag = _Drag.move;
      }
    } else {
      // No marquee: only the lasso tool selects areas.
      if (!shift) _selection = const {};
    }
  }

  void pointerMove(
    Offset screen, {
    double pressure = 0.5,
    Duration? timeStamp,
  }) {
    final delta = screen - _lastScreen;
    _lastScreen = screen;
    lastPointer = screen;
    final world = toWorld(screen);
    switch (_drag) {
      case _Drag.none:
        return;
      case _Drag.pan:
        _offset += delta;
        _markDirty();
      case _Drag.move:
        final worldDelta = delta / _scale;
        _replaceItems({
          for (final item in selectedItems)
            if (!isLocked(item.id)) item.id: item.translated(worldDelta),
        });
      case _Drag.resize:
        final original = _resizeOriginal;
        final bounds = _resizeBounds;
        if (_resizeItems.length == 1 && original != null) {
          _replaceItems({original.id: _resized(original, world)});
        } else if (bounds != null && bounds.width > 0) {
          // A group or several objects scale together, keeping their
          // proportions, from the bottom-left corner of their boundary.
          final f = math.max(0.1, (world.dx - bounds.left) / bounds.width);
          _replaceItems({
            for (final i in _resizeItems)
              i.id: scaledItem(i, f, bounds.bottomLeft),
          });
        }
      case _Drag.marquee:
        _marquee = Rect.fromPoints(_dragStartWorld, world);
        _selection = Set.unmodifiable(
          withGroups({
            ..._selectionAtDragStart,
            for (final item in _items)
              if (!isReference(item.id) && _marquee!.overlaps(itemBounds(item)))
                item.id,
          }),
        );
      case _Drag.lasso:
        final last = _lassoPoints.last;
        // Sample points spaced at least 2 pixels apart on screen for efficiency.
        if ((world - last).distance * _scale >= 2.0) {
          _lassoPoints.add(world);
        }
      case _Drag.draw:
        // Only the live stroke repaints (see [liveInk]); no full rebuild.
        _addLiveSample(world, screen, pressure, timeStamp);
        return;
      case _Drag.erase:
        _eraseAt(toWorld(screen - delta), world);
      case _Drag.connect:
        _connectEnd = world;
        _trackConnect(world);
      case _Drag.connectTap:
        // Moving means a drag, not a tap: from an item it is an ordinary
        // connect drag from there (the waiting source is dropped); from
        // empty space it does nothing and the source keeps waiting.
        final start = _tapScreen, at = _tapAt;
        if (start != null && (screen - start).distance > doubleTapSlop(_kind)) {
          final hit = at == null ? null : hitTest(at);
          if (isConnectable(hit)) {
            _pendingFrom = null;
            _tapAt = _tapScreen = null;
            _startConnect(hit!, at!);
            _connectEnd = world;
            _trackConnect(world);
          } else {
            _tapMoved = true;
          }
        }
    }
    notifyListeners();
  }

  /// The pen, finger or mouse lifted. [screen]: where it lifted (the up
  /// event's position). For a stroke it is the stroke's last sample when
  /// the pen moved since the last move event; dropping it cut the last
  /// stretch of every stroke short.
  void pointerUp({Offset? screen, Duration? timeStamp}) {
    StrokeItem? appended;
    final epochBefore = _paintEpoch;
    final itemsBefore = _items;
    final finishStart = InkMetrics.instance.startTimer();
    switch (_drag) {
      case _Drag.draw:
        if (screen != null && _livePoints.isNotEmpty) {
          _addLiveSample(
            toWorld(screen),
            screen,
            _livePoints.last.pressure,
            timeStamp,
            restartHold: false,
          );
        }
        final stroke = liveStroke;
        _liveStroke = null;
        _liveStale = false;
        _velocity = null;
        _externalPrediction = null;
        _hasExternalPrediction = false;
        (liveInk as _Ping).ping();
        if (stroke != null) {
          final displayedPoints = _liveLinePreview;
          _liveLinePreview = null;
          if (displayedPoints != null) (liveInk as _Ping).ping();
          final stored = _cleanShape(
            displayedPoints == null
                ? stroke
                : StrokeItem(
                    id: stroke.id,
                    color: stroke.color,
                    strokeWidth: stroke.strokeWidth,
                    pressureWidth: stroke.pressureWidth,
                    points: displayedPoints,
                  ),
          );
          _setItems([..._items, stored]);
          appended = stored;
          if (displayedPoints != null) {
            _holdTimer?.cancel();
            _holdTimer = null;
            _pendingStraightenTool = null;
          } else {
            _scheduleLineStraightening(stored);
          }
        }
        _endTransaction();
      case _Drag.move || _Drag.resize || _Drag.erase:
        final narrow = _narrowTo;
        if (narrow != null &&
            (_lastScreen - toScreen(_dragStartWorld)).distance < 4) {
          _selection = {narrow};
        }
        _endTransaction();
      case _Drag.marquee:
        _marquee = null;
      case _Drag.lasso:
        if (_lassoPoints.length >= 3) {
          final hits = <String>{};
          for (final item in _items) {
            if (!isReference(item.id) &&
                _lassoContainsOrIntersects(itemBounds(item), _lassoPoints)) {
              hits.add(item.id);
            }
          }
          // A grouped item brings its whole group, as everywhere else.
          select(withGroups(hits));
        }
        _lassoPoints = [];
      case _Drag.connect:
        _finishConnect();
      case _Drag.connectTap:
        _finishConnectTap();
      case _Drag.pan || _Drag.none:
        break;
    }
    final wasDrawing = _drag == _Drag.draw;
    _drag = _Drag.none;
    _narrowTo = null;
    _resizeOriginal = null;
    _resizeItems = const [];
    _resizeBounds = null;
    notifyListeners();
    lastStrokeAppend = appended == null
        ? null
        : StrokeAppend(
            fromEpoch: epochBefore,
            toEpoch: _paintEpoch,
            before: itemsBefore,
            after: _items,
            stroke: appended,
          );
    if (wasDrawing) {
      InkMetrics.instance.strokeFinished(
        InkMetrics.instance.elapsedSince(finishStart),
      );
    }
  }

  /// Adds one pen sample to the stroke being drawn (screen position
  /// [screen], world position [world]).
  void _addLiveSample(
    Offset world,
    Offset screen,
    double pressure,
    Duration? timeStamp, {
    bool restartHold = true,
  }) {
    final metrics = InkMetrics.instance;
    if (_liveIsStylus &&
        !_livePressure &&
        _tool != CanvasTool.highlighter &&
        (pressure - _firstPressure).abs() > 0.02) {
      // This Pencil reports pressure: from now on (this stroke included,
      // within its first few milliseconds) ink follows it.
      pencilPressureSeen = true;
      _livePressure = true;
      _liveStale = true;
    }
    final last = _livePoints.last.offset;
    // Samples closer than half a screen pixel are one position (keeps
    // files small; a still pen reports the same spot many times).
    if ((world - last).distance * _scale < 0.5) {
      metrics.sampleMerged();
      return;
    }
    final before = _lastMoveTime;
    if (timeStamp != null && before != null && timeStamp > before) {
      final ms = (timeStamp - before).inMicroseconds / 1000;
      // Events less than a millisecond apart (coalesced Pencil samples)
      // give a noisy speed on their own: blend them with the last one so
      // the look-ahead tip does not tremble. Slower events replace it.
      final v = (world - last) / ms;
      final old = _velocity;
      _velocity = old == null || ms >= 4 ? v : Offset.lerp(old, v, 0.5);
    }
    _lastMoveTime = timeStamp ?? _lastMoveTime;
    _livePoints.add(StrokePoint(world.dx, world.dy, pressure));
    _liveStale = true;
    metrics.sampleKept();
    // A resting pen still jitters by a pixel or two; only real movement
    // restarts the hold.
    final anchor = _holdAnchor;
    if (restartHold && (anchor == null || (screen - anchor).distance > 4)) {
      _holdAnchor = screen;
      _restartLineHold();
    }
    (liveInk as _Ping).ping();
  }

  /// Where the platform predicts the pen will be next (UIKit's predicted
  /// touches on iPad), in screen units; null when it predicts nothing.
  /// While a stroke receives these, they replace the app's own straight-
  /// line guess. Drawn only, never stored.
  void setPredictedPoint(Offset? screen) {
    if (_drag != _Drag.draw) return;
    _hasExternalPrediction = true;
    _externalPrediction = screen == null ? null : toWorld(screen);
    (liveInk as _Ping).ping();
  }

  /// Set once any Pencil stroke in this session showed varying pressure.
  /// Pens that report none (Apple Pencil USB-C) then draw at exactly the
  /// chosen width instead of a made-up pressure width.
  static bool pencilPressureSeen = false;

  bool _liveIsStylus = false;
  double _firstPressure = 0.5;
  Offset? _externalPrediction;
  bool _hasExternalPrediction = false;

  /// Counts the notifications that can change what [CanvasPainter] draws
  /// (see the painter's raster cache). Hover and save-state changes do not
  /// count.
  int get paintEpoch => _paintEpoch;
  int _paintEpoch = 0;

  /// The last finished stroke, when that was the only change: lets the
  /// painter add one stroke to its cached picture of the document instead
  /// of drawing every stroke again.
  StrokeAppend? lastStrokeAppend;

  @override
  void notifyListeners() {
    _paintEpoch++;
    super.notifyListeners();
  }

  /// Tells listeners about a change that does not alter the drawing.
  void _notifyQuiet() => super.notifyListeners();

  /// [original] resized so its top-right corner follows [corner]; the
  /// bottom-left corner stays where it is.
  CanvasItem _resized(CanvasItem original, Offset corner) {
    final b = itemBounds(original);
    switch (original) {
      case ImageItem():
        // Photos keep their aspect ratio.
        final ratio = original.height / math.max(1, original.width);
        final width = math.max(40.0, corner.dx - b.left);
        final height = width * ratio;
        return original.withBox(
          position: Offset(b.left, b.bottom - height),
          width: width,
          minHeight: height,
        );
      case TextItem():
        final top = math.min(corner.dy, b.bottom - 20);
        return original.withBox(
          position: Offset(b.left, top),
          width: math.max(TextItem.minWidth, corner.dx - b.left),
          minHeight: math.max(0, b.bottom - top),
        );
      case final BoxItem box when box is LinkItem || box is NoteCardItem:
        final top = math.min(corner.dy, b.bottom - 40);
        return box.withBox(
          position: Offset(b.left, top),
          width: math.max(160, corner.dx - b.left),
          minHeight: math.max(0, b.bottom - top),
        );
      case LinkItem() || NoteCardItem() || ConnectorItem():
        return original;
      case StrokeItem():
        final sb = original.bounds;
        final sx = math.max(8, corner.dx - sb.left) / math.max(1, sb.width);
        final sy = math.max(8, sb.bottom - corner.dy) / math.max(1, sb.height);
        return StrokeItem(
          id: original.id,
          color: original.color,
          strokeWidth: original.strokeWidth,
          pressureWidth: original.pressureWidth,
          points: [
            for (final p in original.points)
              StrokePoint(
                sb.left + (p.x - sb.left) * sx,
                sb.bottom - (sb.bottom - p.y) * sy,
                p.pressure,
              ),
          ],
        );
    }
  }

  /// [item] scaled by [f] around [anchor] (a group or several objects
  /// resized together). Text grows with its box; line widths stay.
  CanvasItem scaledItem(CanvasItem item, double f, Offset anchor) {
    Offset at(Offset p) => anchor + (p - anchor) * f;
    switch (item) {
      case StrokeItem():
        return StrokeItem(
          id: item.id,
          color: item.color,
          strokeWidth: item.strokeWidth,
          pressureWidth: item.pressureWidth,
          points: [
            for (final p in item.points)
              () {
                final q = at(Offset(p.x, p.y));
                return StrokePoint(q.dx, q.dy, p.pressure);
              }(),
          ],
        );
      case TextItem():
        return item
            .withBox(
              position: at(item.position),
              width: math.max(TextItem.minWidth, item.width * f),
              minHeight: item.minHeight * f,
            )
            .copyWith(fontSize: (item.fontSize * f).clamp(6.0, 200.0));
      case BoxItem():
        return item.withBox(
          position: at(item.position),
          width: math.max(40, item.width * f),
          minHeight: item.minHeight * f,
        );
      case ConnectorItem():
        return item;
    }
  }

  /// Turns rough shapes into clean ones while [recognizeShapes] is on.
  bool get recognizeShapes => _recognizeShapes;
  bool _recognizeShapes = false;
  set recognizeShapes(bool on) {
    _recognizeShapes = on;
    notifyListeners();
  }

  StrokeItem _cleanShape(StrokeItem stroke) {
    if (!recognizeShapes) return stroke;
    final match = recognizeShape(stroke.points);
    if (match == null) return stroke;
    return StrokeItem(
      id: stroke.id,
      points: match.points,
      color: stroke.color,
      strokeWidth: stroke.strokeWidth,
      pressureWidth: false,
    );
  }

  /// The platform took the pointer away (a system gesture, an alert, the
  /// app leaving the screen, a second finger starting a pinch).
  ///
  /// [keepInk]: the pointer was the Pencil. What it had written is real
  /// handwriting, so it is kept as a finished stroke (never straightened)
  /// instead of vanishing; iPadOS cancels Pencil touches near the screen
  /// edges and when Control Centre or a notification takes over. A finger
  /// stroke cancelled by a pinch is still dropped: that line was the start
  /// of the pinch, not writing.
  void pointerCancel({bool keepInk = false}) {
    cancelPendingLineStraightening();
    if (_drag == _Drag.draw) {
      if (keepInk && _livePoints.isNotEmpty) {
        InkMetrics.instance.cancelledKept++;
        pointerUp();
        cancelPendingLineStraightening();
        return;
      }
      InkMetrics.instance.strokeCancelled(kept: false);
      _liveStroke = null;
      _liveStale = false;
    }
    if (_drag == _Drag.lasso) _lassoPoints = [];
    if (_drag == _Drag.connect) _connectFrom = _connectEnd = null;
    // A pinch started during the second tap: keep waiting for the target.
    if (_drag == _Drag.connectTap) _tapMoved = true;
    pointerUp();
  }

  void pointerHover(Offset? screen) {
    _hover = screen;
    if (screen != null) lastPointer = screen;
    // Hovering changes the drawing only while a tapped connection waits
    // for its target (the line follows the pointer).
    _pendingFrom == null ? _notifyQuiet() : notifyListeners();
  }

  void _updateLiveStroke() {
    _liveStale = false;
    final isHighlighter = _tool == CanvasTool.highlighter;
    _liveStroke = StrokeItem(
      id: _liveStroke?.id ?? newId(),
      points: List.unmodifiable(_livePoints),
      color: isHighlighter
          ? highlighterColor.withValues(alpha: 0.38)
          : penColor,
      strokeWidth: isHighlighter ? highlighterWidth : penWidth,
      pressureWidth: _livePressure && !isHighlighter,
    );
  }

  /// Erases along the segment [from]→[to]: whole strokes it touches, or
  /// (partial mode) only the parts under the eraser.
  void _eraseAt(Offset from, Offset to) {
    final tolerance = eraserSize / 2 / _scale;
    if (eraserMode == EraserMode.partial) {
      _erasePartAt(from, to, tolerance);
      return;
    }
    final steps = math.max(1, ((to - from).distance / tolerance).ceil());
    final samples = [
      for (var i = 0; i <= steps; i++) Offset.lerp(from, to, i / steps)!,
    ];
    final erased = {
      for (final item in _items)
        if (item is StrokeItem &&
            !isLocked(item.id) &&
            samples.any((p) => item.hitTest(p, tolerance)))
          item.id,
    };
    if (erased.isEmpty) return;
    // Connections to an erased line go with it (same undo step), so none
    // is left pointing at nothing.
    _setItems([
      for (final item in _items)
        if (!erased.contains(item.id) &&
            !(item is ConnectorItem && erased.any(item.touches)))
          item,
    ]);
  }

  /// Cuts the parts of strokes within [radius] of [from]→[to] out; what is
  /// left of a stroke stays (the first piece keeps the stroke's id, others
  /// get new ones), with its colour, width and pressure. One undo step per
  /// eraser drag, like the whole-stroke eraser.
  void _erasePartAt(Offset from, Offset to, double radius) {
    final swept = Rect.fromPoints(from, to).inflate(radius);
    final removed = <String>{};
    var changed = false;
    final next = <CanvasItem>[];
    for (final item in _items) {
      if (item is! StrokeItem ||
          isLocked(item.id) ||
          !item.bounds.overlaps(swept)) {
        next.add(item);
        continue;
      }
      // Touching the visible ink erases it: the centre line is cut within
      // the eraser plus half the line's width (more for pressure lines).
      final half = item.strokeWidth * (item.pressureWidth ? 0.8 : 0.5);
      final pieces = erasePolyline(item.points, from, to, radius + half);
      if (pieces == null) {
        next.add(item);
        continue;
      }
      changed = true;
      if (pieces.isEmpty) removed.add(item.id);
      for (var i = 0; i < pieces.length; i++) {
        next.add(
          StrokeItem(
            id: i == 0 ? item.id : newId(),
            points: pieces[i],
            color: item.color,
            strokeWidth: item.strokeWidth,
            pressureWidth: item.pressureWidth,
          ),
        );
      }
    }
    if (!changed) return;
    _setItems([
      for (final item in next)
        if (!(item is ConnectorItem && removed.any(item.touches))) item,
    ]);
  }

  /// Whether [poly] contains or intersects [bounds].
  static bool _lassoContainsOrIntersects(Rect bounds, List<Offset> poly) {
    if (poly.isEmpty) return false;
    var minX = poly.first.dx, maxX = poly.first.dx;
    var minY = poly.first.dy, maxY = poly.first.dy;
    for (final p in poly) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    final polyBounds = Rect.fromLTRB(minX, minY, maxX, maxY);
    if (!polyBounds.overlaps(bounds)) return false;

    // Center or corners inside polygon
    if (_pointInPolygon(bounds.center, poly) ||
        _pointInPolygon(bounds.topLeft, poly) ||
        _pointInPolygon(bounds.topRight, poly) ||
        _pointInPolygon(bounds.bottomLeft, poly) ||
        _pointInPolygon(bounds.bottomRight, poly)) {
      return true;
    }

    // Any polygon vertex inside bounds
    for (final p in poly) {
      if (bounds.contains(p)) return true;
    }
    return false;
  }

  static bool _pointInPolygon(Offset p, List<Offset> poly) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final xi = poly[i].dx, yi = poly[i].dy;
      final xj = poly[j].dx, yj = poly[j].dy;
      final intersect =
          ((yi > p.dy) != (yj > p.dy)) &&
          (p.dx < (xj - xi) * (p.dy - yi) / (yj - yi) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  // ------------------------------------------------------------- autosave --

  Timer? _saveTimer;
  SaveState _saveState;
  SaveState get saveState => _saveState;
  Future<void>? _inFlight;
  bool _disposed = false;

  void _markDirty() {
    _saveState = SaveState.pending;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(flush()));
  }

  // Sync bookkeeping: which item instances were last saved, so each save
  // stamps exactly the items that changed (items are immutable, so a new
  // instance means a change; an undo counts as a new change).
  final Map<String, String> _itemRevs;
  final Map<String, String> _tombstones;
  final List<Map<String, dynamic>> _unknownItems;

  // Fields this version does not know (from a newer version), kept and
  // written back. Entries of deleted items are kept too, so undo restores
  // them; only those of current items are saved.
  final Map<String, Map<String, dynamic>> _itemUnknownFields;
  final Map<String, dynamic> _unknownKeys;
  Map<String, dynamic> _metaUnknownFields;
  String? _metaRev;

  // Notebook fields (a note's handwriting); see [CanvasDocument.kind].
  final String? _docKind;
  List<PageBackground> _pageBackgrounds;
  bool _metaChanged = false;

  bool get isNotebook => isNotebookId(_id, _docKind);
  List<PageBackground> get pageBackgrounds => _pageBackgrounds;

  /// Puts PDF pages under notebook pages (saved and synced with the
  /// document's metadata).
  void setPageBackgrounds(List<PageBackground> backgrounds) {
    cancelPendingLineStraightening();
    _pageBackgrounds = List.unmodifiable(backgrounds);
    _metaChanged = true;
    _markDirty();
    notifyListeners();
  }

  Map<String, CanvasItem> _savedItems;
  String _savedTitle;
  String? _savedFolderId;

  /// Metadata stamp (title, folder, order).
  String? get metaRev => _metaRev;

  /// Applies changes received from the sync hub to this open canvas.
  ///
  /// An item edited here but not yet saved is never overwritten (it counts
  /// as pending, so the local version is pushed and the hub decides).
  /// Undo history is cleared, because undoing past a remote change would
  /// silently revert another device's work. Returns the applied keys.
  Set<String> applyRemote(
    List<SyncChange> changes,
    bool Function(String key, String? localRev) isPending,
  ) {
    final unsaved = {
      for (final i in _items)
        if (!identical(_savedItems[i.id], i)) i.id,
      // Tag, lock, group … changed here and not saved yet.
      ..._marksChanged,
    };
    if (_editingId != null) unsaved.add(_editingId!);
    final metaUnsaved =
        _title != _savedTitle || _folderId != _savedFolderId || _metaChanged;
    final state = CanvasSyncState(
      items: [..._items],
      itemRevs: {..._itemRevs},
      tombstones: {..._tombstones},
      title: _title,
      folderId: _folderId,
      metaRev: _metaRev,
      itemUnknownFields: {..._itemUnknownFields},
      metaUnknownFields: _metaUnknownFields,
      kind: _docKind,
      pageBackgrounds: _pageBackgrounds,
    );
    final applied = applyCanvasChanges(state, _id, changes, (key, rev) {
      final itemId = key.substring(key.lastIndexOf('/') + 1);
      if (key.startsWith('canvases/')) {
        return metaUnsaved || isPending(key, rev);
      }
      return unsaved.contains(itemId) || isPending(key, rev);
    });
    if (applied.isEmpty) return applied;
    for (final c in changes) {
      clock.observe(c.rev);
    }
    final before = {for (final i in _items) i.id: i};
    _items = List.unmodifiable(state.items);
    _itemRevs
      ..clear()
      ..addAll(state.itemRevs);
    _tombstones
      ..clear()
      ..addAll(state.tombstones);
    _title = _savedTitle = state.title;
    _folderId = _savedFolderId = state.folderId;
    _metaRev = state.metaRev;
    _itemUnknownFields
      ..clear()
      ..addAll(state.itemUnknownFields);
    _metaUnknownFields = state.metaUnknownFields;
    _pageBackgrounds = state.pageBackgrounds;
    // Remote versions count as saved, so they are not stamped as local edits.
    _savedItems = {
      for (final i in _items)
        i.id: identical(before[i.id], i) ? _savedItems[i.id] ?? i : i,
    };
    _undo.clear();
    _redo.clear();
    _pruneSelection();
    _markDirty();
    notifyListeners();
    return applied;
  }

  /// Revision stamp of an item (null until it is first saved).
  String? revOf(String itemId) => _itemRevs[itemId];

  /// Deleted item ids and their deletion stamps.
  Map<String, String> get tombstones => Map.unmodifiable(_tombstones);

  /// Updates revision stamps for everything changed since the last save.
  void _stampChanges() {
    final current = {for (final i in _items) i.id: i};
    for (final item in _items) {
      if (!identical(_savedItems[item.id], item) ||
          _marksChanged.contains(item.id) ||
          !_itemRevs.containsKey(item.id)) {
        _itemRevs[item.id] = clock.now();
      }
      _tombstones.remove(item.id);
    }
    for (final id in _savedItems.keys) {
      if (!current.containsKey(id)) {
        _itemRevs.remove(id);
        _layouts.remove(id)?.painter.dispose();
        _cards.remove(id)?.layout.dispose();
        _tombstones[id] = clock.now();
      }
    }
    if (_title != _savedTitle ||
        _folderId != _savedFolderId ||
        _metaChanged ||
        _metaRev == null) {
      _metaRev = clock.now();
    }
    _metaChanged = false;
    _marksChanged.clear();
    _savedItems = current;
    _savedTitle = _title;
    _savedFolderId = _folderId;
  }

  CanvasDocument get document => CanvasDocument(
    id: _id,
    title: _title,
    folderId: _folderId,
    items: liveStroke == null ? _items : [..._items, liveStroke!],
    viewport: CanvasViewport(offset: _offset, scale: _scale),
    updatedAt: DateTime.now(),
    itemRevs: Map.unmodifiable(_itemRevs),
    tombstones: Map.unmodifiable(_tombstones),
    metaRev: _metaRev,
    unknownItems: _unknownItems,
    itemUnknownFields: {
      for (final item in _items) item.id: ?_itemUnknownFields[item.id],
    },
    unknownKeys: _unknownKeys,
    metaUnknownFields: _metaUnknownFields,
    kind: _docKind,
    pageBackgrounds: _pageBackgrounds,
  );

  /// Saves immediately if there are unsaved changes.
  Future<void> flush() async {
    _saveTimer?.cancel();
    await _inFlight;
    if (_saveState != SaveState.pending && _saveState != SaveState.failed) {
      return;
    }
    _setSaveState(SaveState.saving);
    _stampChanges();
    final future = onSave(document);
    _inFlight = future;
    try {
      await future;
      // Changes made while saving leave the state as pending.
      if (_saveState == SaveState.saving) _setSaveState(SaveState.saved);
    } catch (e) {
      AppLog.error('Canvas save failed', e);
      _setSaveState(SaveState.failed);
    } finally {
      _inFlight = null;
    }
  }

  void _setSaveState(SaveState state) {
    _saveState = state;
    if (!_disposed) _notifyQuiet();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    cancelPendingLineStraightening();
    liveInk.dispose();
    resources?.removeListener(_onResourcesChanged);
    for (final layout in _layouts.values) {
      layout.painter.dispose();
    }
    _clearCardLayouts();
    super.dispose();
  }
}

/// One finished stroke added to the drawing by [CanvasController.pointerUp]
/// and nothing else changed: [before] + [stroke] is [after], and the paint
/// epoch went from [fromEpoch] to [toEpoch] for it.
class StrokeAppend {
  const StrokeAppend({
    required this.fromEpoch,
    required this.toEpoch,
    required this.before,
    required this.after,
    required this.stroke,
  });

  final int fromEpoch;
  final int toEpoch;
  final List<CanvasItem> before;
  final List<CanvasItem> after;
  final StrokeItem stroke;
}

/// A ChangeNotifier that can be told to notify from outside.
class _Ping extends ChangeNotifier {
  void ping() => notifyListeners();
}
