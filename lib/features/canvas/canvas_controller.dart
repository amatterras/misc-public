import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../data/sync/sync_clock.dart';
import '../../sync/canvas_merge.dart';
import '../../sync/protocol.dart';
import 'canvas_resources.dart';
import 'canvas_text.dart';

export 'canvas_text.dart' show kTextPadding, canvasTextStyle;

enum CanvasTool { select, pan, pen, eraser, text }

enum SaveState { saved, pending, saving, failed }

/// What the current pointer drag is doing.
enum _Drag { none, pan, move, resize, marquee, draw, erase }

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
  set tool(CanvasTool value) {
    if (value == _tool) return;
    endEditing();
    _tool = value;
    if (value != CanvasTool.select) _selection = const {};
    notifyListeners();
  }

  Color penColor = AppColors.text;
  double penWidth = 2.5;

  void setPen({Color? color, double? width}) {
    penColor = color ?? penColor;
    penWidth = width ?? penWidth;
    notifyListeners();
  }

  /// True while the space bar is held: temporarily pan with any tool.
  bool spaceHeld = false;

  // ------------------------------------------------------------ selection --

  Set<String> _selection = const {};
  Set<String> get selection => _selection;

  void select(Iterable<String> ids) {
    _selection = Set.unmodifiable(ids);
    notifyListeners();
  }

  void selectAll() {
    _tool = CanvasTool.select;
    select(_items.map((i) => i.id));
  }

  List<CanvasItem> get selectedItems => [
    for (final i in _items)
      if (_selection.contains(i.id)) i,
  ];

  void deleteSelection() {
    if (_selection.isEmpty) return;
    _commit([
      for (final i in _items)
        if (!_selection.contains(i.id)) i,
    ]);
    _selection = const {};
    notifyListeners();
  }

  /// Applies [change] to every selected text note as one undo step.
  void updateSelectedTexts(TextItem Function(TextItem) change) {
    final changes = <String, CanvasItem>{
      for (final item in selectedItems)
        if (item is TextItem) item.id: change(item),
    };
    if (changes.isEmpty) return;
    _commit([for (final i in _items) changes[i.id] ?? i]);
    notifyListeners();
  }

  void setFontSize(double size) =>
      updateSelectedTexts((t) => t.copyWith(fontSize: size));

  /// Copies of the selected items, offset slightly, become the selection.
  void duplicateSelection() {
    final copies = [
      for (final item in selectedItems)
        item.withId(newId()).translated(const Offset(24, 24)),
    ];
    if (copies.isEmpty) return;
    addItems(copies);
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
    if (items.isEmpty) return;
    final bounds = items
        .map((i) => i.bounds)
        .reduce((a, b) => a.expandToInclude(b));
    final delta = world - bounds.center;
    addItems([for (final i in items) i.withId(newId()).translated(delta)]);
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
    if (_editingId == id) return;
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
    _endTransaction();
    notifyListeners();
  }

  TextItem createText(Offset world) {
    endEditing();
    final item = TextItem(
      id: newId(),
      position: world - const Offset(kTextPadding, kTextPadding),
      width: TextItem.defaultWidth,
      minHeight: 0,
      text: '',
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
    endEditing();
    if (_undo.isEmpty) return;
    _redo.add(_items);
    _setItems(_undo.removeLast());
    _pruneSelection();
    notifyListeners();
  }

  void redo() {
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
    }
  }

  // --------------------------------------------------------- hit testing --

  /// Topmost item under [world], or null.
  CanvasItem? hitTest(Offset world) {
    final tolerance = 6 / _scale;
    for (final item in _items.reversed) {
      switch (item) {
        case BoxItem():
          if (itemBounds(item).contains(world)) return item;
        case StrokeItem():
          if (item.hitTest(world, tolerance)) return item;
      }
    }
    return null;
  }

  /// Size of the resize handle on screen, in logical pixels.
  static const double handleSize = 10;

  /// The single selected item whose resize handle is under [screen].
  CanvasItem? resizeHandleAt(Offset screen) {
    if (_tool != CanvasTool.select || _selection.length != 1) return null;
    final item = itemById(_selection.first);
    if (item == null) return null;
    final corner = toScreen(itemBounds(item).bottomRight);
    final hit = Rect.fromCenter(
      center: corner,
      width: handleSize + 8,
      height: handleSize + 8,
    );
    return hit.contains(screen) ? item : null;
  }

  // ---------------------------------------------------------- live state --

  StrokeItem? _liveStroke;
  StrokeItem? get liveStroke => _liveStroke;
  List<StrokePoint> _livePoints = [];

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
  Set<String> _selectionAtDragStart = const {};
  CanvasItem? _resizeOriginal;
  Duration? _lastDownTime;
  Offset? _lastDownPos;

  bool get isPanning => _drag == _Drag.pan;
  bool get isDragging => _drag != _Drag.none;

  void pointerDown(
    Offset screen, {
    int buttons = kPrimaryButton,
    PointerDeviceKind kind = PointerDeviceKind.mouse,
    double pressure = 0.5,
    bool shift = false,
    bool ctrl = false,
    Duration timeStamp = Duration.zero,
  }) {
    _lastScreen = screen;
    lastPointer = screen;
    final world = toWorld(screen);
    _dragStartWorld = world;

    final isDouble =
        _lastDownTime != null &&
        _lastDownPos != null &&
        timeStamp - _lastDownTime! < doubleClickTime &&
        (screen - _lastDownPos!).distance < 6;
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
        );
      case CanvasTool.text:
        final hit = hitTest(world);
        if (hit is TextItem) {
          beginEditing(hit.id);
        } else {
          createText(world);
        }
      case CanvasTool.pen:
        endEditing();
        _beginTransaction();
        _drag = _Drag.draw;
        _livePoints = [StrokePoint(world.dx, world.dy, pressure)];
        _updateLiveStroke();
      case CanvasTool.eraser:
        endEditing();
        _beginTransaction();
        _drag = _Drag.erase;
        _eraseAt(world, world);
    }
    notifyListeners();
  }

  void _selectDown(
    Offset screen,
    Offset world, {
    required bool shift,
    required bool ctrl,
    required bool isDouble,
  }) {
    final handle = resizeHandleAt(screen);
    if (handle != null) {
      endEditing();
      _beginTransaction();
      _drag = _Drag.resize;
      _resizeOriginal = handle;
      return;
    }

    final hit = hitTest(world);
    final opensSomething = hit is LinkItem || hit is NoteCardItem;
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

    if (hit != null) {
      if (shift) {
        final next = {..._selection};
        if (!next.remove(hit.id)) next.add(hit.id);
        _selection = Set.unmodifiable(next);
      } else if (!_selection.contains(hit.id)) {
        _selection = {hit.id};
      }
      if (_selection.contains(hit.id)) {
        _beginTransaction();
        _drag = _Drag.move;
      }
    } else {
      _selectionAtDragStart = shift ? _selection : const {};
      _selection = _selectionAtDragStart;
      _drag = _Drag.marquee;
      _marquee = Rect.fromPoints(world, world);
    }
  }

  void pointerMove(Offset screen, {double pressure = 0.5}) {
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
            item.id: item.translated(worldDelta),
        });
      case _Drag.resize:
        final original = _resizeOriginal;
        if (original != null) {
          _replaceItems({original.id: _resized(original, world)});
        }
      case _Drag.marquee:
        _marquee = Rect.fromPoints(_dragStartWorld, world);
        _selection = Set.unmodifiable({
          ..._selectionAtDragStart,
          for (final item in _items)
            if (_marquee!.overlaps(itemBounds(item))) item.id,
        });
      case _Drag.draw:
        final last = _livePoints.last.offset;
        // Skip points closer than half a screen pixel to keep files small.
        if ((world - last).distance * _scale < 0.5) return;
        _livePoints.add(StrokePoint(world.dx, world.dy, pressure));
        _updateLiveStroke();
      case _Drag.erase:
        _eraseAt(toWorld(screen - delta), world);
    }
    notifyListeners();
  }

  void pointerUp() {
    switch (_drag) {
      case _Drag.draw:
        final stroke = _liveStroke;
        _liveStroke = null;
        if (stroke != null) _setItems([..._items, stroke]);
        _endTransaction();
      case _Drag.move || _Drag.resize || _Drag.erase:
        _endTransaction();
      case _Drag.marquee:
        _marquee = null;
      case _Drag.pan || _Drag.none:
        break;
    }
    _drag = _Drag.none;
    _resizeOriginal = null;
    notifyListeners();
  }

  /// [original] resized so its bottom-right corner follows [corner].
  CanvasItem _resized(CanvasItem original, Offset corner) {
    switch (original) {
      case ImageItem():
        // Photos keep their aspect ratio.
        final ratio = original.height / math.max(1, original.width);
        final width = math.max(40.0, corner.dx - original.position.dx);
        return original.withBox(width: width, minHeight: width * ratio);
      case TextItem():
        return original.withBox(
          width: math.max(TextItem.minWidth, corner.dx - original.position.dx),
          minHeight: math.max(0, corner.dy - original.position.dy),
        );
      case final BoxItem box when box is LinkItem || box is NoteCardItem:
        return box.withBox(
          width: math.max(160, corner.dx - box.position.dx),
          minHeight: math.max(0, corner.dy - box.position.dy),
        );
      case LinkItem() || NoteCardItem():
        return original;
      case StrokeItem():
        final b = original.bounds;
        final sx = math.max(8, corner.dx - b.left) / math.max(1, b.width);
        final sy = math.max(8, corner.dy - b.top) / math.max(1, b.height);
        return StrokeItem(
          id: original.id,
          color: original.color,
          strokeWidth: original.strokeWidth,
          points: [
            for (final p in original.points)
              StrokePoint(
                b.left + (p.x - b.left) * sx,
                b.top + (p.y - b.top) * sy,
                p.pressure,
              ),
          ],
        );
    }
  }

  void pointerCancel() {
    if (_drag == _Drag.draw) _liveStroke = null;
    pointerUp();
  }

  void pointerHover(Offset? screen) {
    _hover = screen;
    if (screen != null) lastPointer = screen;
    notifyListeners();
  }

  void _updateLiveStroke() {
    _liveStroke = StrokeItem(
      id: _liveStroke?.id ?? newId(),
      points: List.unmodifiable(_livePoints),
      color: penColor,
      strokeWidth: penWidth,
    );
  }

  /// Removes whole strokes touched along the segment [from]→[to].
  /// (A partial "pixel" eraser can be added later for stylus use.)
  void _eraseAt(Offset from, Offset to) {
    final tolerance = 8 / _scale;
    final steps = math.max(1, ((to - from).distance / tolerance).ceil());
    final samples = [
      for (var i = 0; i <= steps; i++) Offset.lerp(from, to, i / steps)!,
    ];
    final remaining = [
      for (final item in _items)
        if (item is! StrokeItem ||
            !samples.any((p) => item.hitTest(p, tolerance)))
          item,
    ];
    if (remaining.length != _items.length) _setItems(remaining);
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
  String? _metaRev;
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
    };
    if (_editingId != null) unsaved.add(_editingId!);
    final metaUnsaved = _title != _savedTitle || _folderId != _savedFolderId;
    final state = CanvasSyncState(
      items: [..._items],
      itemRevs: {..._itemRevs},
      tombstones: {..._tombstones},
      title: _title,
      folderId: _folderId,
      metaRev: _metaRev,
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
        _metaRev == null) {
      _metaRev = clock.now();
    }
    _savedItems = current;
    _savedTitle = _title;
    _savedFolderId = _folderId;
  }

  CanvasDocument get document => CanvasDocument(
    id: _id,
    title: _title,
    folderId: _folderId,
    items: _liveStroke == null ? _items : [..._items, _liveStroke!],
    viewport: CanvasViewport(offset: _offset, scale: _scale),
    updatedAt: DateTime.now(),
    itemRevs: Map.unmodifiable(_itemRevs),
    tombstones: Map.unmodifiable(_tombstones),
    metaRev: _metaRev,
    unknownItems: _unknownItems,
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
      debugPrint('Canvas save failed: $e');
      _setSaveState(SaveState.failed);
    } finally {
      _inFlight = null;
    }
  }

  void _setSaveState(SaveState state) {
    _saveState = state;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    resources?.removeListener(_onResourcesChanged);
    for (final layout in _layouts.values) {
      layout.painter.dispose();
    }
    _clearCardLayouts();
    super.dispose();
  }
}
