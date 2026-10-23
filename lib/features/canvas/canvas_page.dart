import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../platform/input_hints.dart';
import '../../widgets/common.dart';
import 'canvas_controller.dart';
import 'canvas_painter.dart';
import 'canvas_text.dart';
import 'canvas_toolbar.dart';

class CanvasPage extends StatelessWidget {
  const CanvasPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final controller = state.canvas;
    if (controller == null) {
      return const ColoredBox(color: AppColors.canvas);
    }
    return CanvasView(
      key: ValueKey(controller.id),
      controller: controller,
      state: state,
    );
  }
}

/// The interactive canvas surface for one [CanvasController].
class CanvasView extends StatefulWidget {
  const CanvasView({super.key, required this.controller, required this.state});

  final CanvasController controller;
  final AppState state;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView> {
  final _focusNode = FocusNode(debugLabel: 'canvas');
  double _lastPanZoomScale = 1;
  Size _size = Size.zero;
  bool _viewChecked = false;
  bool _showMinimap = true;
  bool _wasVisible = false;

  // Touch and stylus tracking for iPad / iPhone and Apple Pencil
  final Map<int, Offset> _touchPointers = {};
  double? _initialPinchDistance;
  double? _initialPinchScale;
  Offset? _lastPinchFocal;
  int? _activeStylusPointer;

  /// The pointer whose stroke or drag the controller is handling.
  int? _drawingPointer;

  @override
  void initState() {
    super.initState();
    _focusWhenShown();
  }

  @override
  void didUpdateWidget(CanvasView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _focusWhenShown();
  }

  /// The canvas stays alive while other pages are shown, so it must take
  /// keyboard focus each time it becomes visible; otherwise shortcuts
  /// (P, V, Ctrl+V…) only work after clicking it.
  void _focusWhenShown() {
    final visible = s.page == AppPage.canvas;
    if (visible && !_wasVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && s.page == AppPage.canvas && c.editingId == null) {
          _focusNode.requestFocus();
        }
      });
    }
    _wasVisible = visible;
  }

  CanvasController get c => widget.controller;
  AppState get s => widget.state;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Offset get _dropPoint =>
      c.toWorld(c.lastPointer ?? _size.center(Offset.zero));

  Offset get _centerPoint => c.toWorld(_size.center(Offset.zero));

  // ----------------------------------------------------- copy & paste --

  void _copy({bool cut = false}) {
    final items = c.selectedItems;
    if (items.isEmpty) return;
    final text = [
      for (final i in items)
        if (i is TextItem)
          i.text
        else if (i is LinkItem)
          s.workspace.assets[i.assetId]?.url ?? '',
    ].where((t) => t.isNotEmpty).join('\n\n');
    final marker = text.isEmpty ? '[THEapp canvas selection]' : text;
    s.capture
      ..internalItems = items
      ..internalMarker = marker;
    Clipboard.setData(ClipboardData(text: marker));
    if (cut) c.deleteSelection();
  }

  Future<void> _paste() async {
    final at = _dropPoint;
    final content = await s.capture.readClipboard();
    if (!mounted) return;
    final capture = s.capture;
    if (content.text != null &&
        content.text == capture.internalMarker &&
        capture.internalItems.isNotEmpty &&
        content.imageBytes == null) {
      c.pasteItems(capture.internalItems, at);
      return;
    }
    if (content.imageBytes != null) {
      final asset = await capture.imageFromBytes(
        content.imageBytes!,
        content.imageExtension,
      );
      c.insertImage(asset, at);
      return;
    }
    final files = content.imageFiles;
    if (files.isNotEmpty) {
      await _insertImages(await capture.imagesFromFiles(files), at);
      return;
    }
    final url = content.url;
    if (url != null) {
      c.insertLink(capture.link(url), at);
      return;
    }
    final text = content.text?.trim();
    if (text != null && text.isNotEmpty) {
      c.insertText(text, at);
      return;
    }
    s.showToast('Nothing to paste — copy some text, a link or an image first.');
  }

  Future<void> _insertImages(List<Asset> assets, Offset at) async {
    final placed = <CanvasItem>[];
    var x = at.dx - (assets.length - 1) * 180;
    for (final a in assets) {
      placed.add(c.insertImage(a, Offset(x, at.dy), maxSide: 340));
      x += 360;
    }
    c.select(placed.map((i) => i.id));
  }

  Future<void> _addImages() async {
    final assets = await s.capture.pickImages();
    if (!mounted || assets.isEmpty) return;
    await _insertImages(assets, _centerPoint);
  }

  /// PDFs become document cards (the link card) that open in the default
  /// PDF viewer.
  Future<void> _addDocuments() async {
    final assets = await s.capture.pickDocuments();
    if (!mounted || assets.isEmpty) return;
    var at = _centerPoint;
    for (final a in assets) {
      c.insertLink(a, at);
      at += const Offset(32, 32);
    }
  }

  Future<void> _addLink() async {
    final input = await promptText(
      context,
      title: 'Add link',
      hint: 'https://…',
      action: 'Add',
    );
    if (input == null) return;
    final url = extractUrl(input);
    if (url == null) {
      s.showToast('That doesn’t look like a web address.');
      return;
    }
    c.insertLink(s.capture.link(url), _centerPoint);
  }

  // ----------------------------------------------------------- keyboard --

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) c.spaceHeld = true;
      if (event is KeyUpEvent) c.spaceHeld = false;
      setState(() {});
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed || keyboard.isMetaPressed;
    final shift = keyboard.isShiftPressed;

    if (ctrl) {
      if (key == LogicalKeyboardKey.keyZ) {
        shift ? c.redo() : c.undo();
      } else if (key == LogicalKeyboardKey.keyY) {
        c.redo();
      } else if (key == LogicalKeyboardKey.keyA) {
        c.selectAll();
      } else if (key == LogicalKeyboardKey.keyC) {
        _copy();
      } else if (key == LogicalKeyboardKey.keyX) {
        _copy(cut: true);
      } else if (key == LogicalKeyboardKey.keyV) {
        _paste();
      } else if (key == LogicalKeyboardKey.keyD) {
        c.duplicateSelection();
      } else if (key == LogicalKeyboardKey.digit0) {
        c.fitToContent(_size, minScale: CanvasController.minScale);
      } else if (key == LogicalKeyboardKey.digit1) {
        c.zoomAt(_size.center(Offset.zero), 1 / c.scale);
      } else if (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.numpadAdd) {
        c.zoomAt(_size.center(Offset.zero), 1.2);
      } else if (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract) {
        c.zoomAt(_size.center(Offset.zero), 1 / 1.2);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.ignored;

    final tools = {
      LogicalKeyboardKey.keyV: CanvasTool.select,
      LogicalKeyboardKey.keyL: CanvasTool.lasso,
      LogicalKeyboardKey.keyH: CanvasTool.pan,
      LogicalKeyboardKey.keyP: CanvasTool.pen,
      LogicalKeyboardKey.keyI: CanvasTool.highlighter,
      LogicalKeyboardKey.keyE: CanvasTool.eraser,
      LogicalKeyboardKey.keyT: CanvasTool.text,
      LogicalKeyboardKey.keyC: CanvasTool.connect,
    };
    if (tools.containsKey(key)) {
      c.tool = tools[key]!;
    } else if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      c.deleteSelection();
    } else if (key == LogicalKeyboardKey.escape) {
      c.cancelConnect();
      c.select(const []);
    } else if (key == LogicalKeyboardKey.enter && c.selection.length == 1) {
      final item = c.selectedItems.first;
      if (item is TextItem) c.beginEditing(item.id);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------ pointer --

  void _onPointerDown(PointerDownEvent e) {
    _focusNode.requestFocus();
    final isStylus =
        e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus;
    if (isStylus) {
      // The pen wins: keep a finger stroke already drawn, end any pinch, and
      // ignore the fingers (the palm) until the pen lifts.
      if (_drawingPointer != null) c.pointerUp();
      _drawingPointer = null;
      _touchPointers.clear();
      _endPinch();
      _activeStylusPointer = e.pointer;
    } else if (e.kind == PointerDeviceKind.touch) {
      if (_activeStylusPointer != null) {
        // Palm rejection: finger touches are ignored while stylus is in contact.
        return;
      }
      _touchPointers[e.pointer] = e.localPosition;
      if (_touchPointers.length == 2) {
        // Multi-touch gesture started: cancel active single pointer drawing
        if (_drawingPointer != null) c.pointerCancel();
        _drawingPointer = null;
        final points = _touchPointers.values.toList();
        _initialPinchDistance = (points[0] - points[1]).distance;
        _initialPinchScale = c.scale;
        _lastPinchFocal = (points[0] + points[1]) / 2;
        return;
      } else if (_touchPointers.length > 2) {
        return;
      }
    }

    final keyboard = HardwareKeyboard.instance;
    _drawingPointer = e.pointer;
    c.pointerDown(
      e.localPosition,
      buttons: e.buttons,
      kind: e.kind,
      pressure: e.kind == PointerDeviceKind.mouse ? 0.5 : e.pressure,
      shift: keyboard.isShiftPressed,
      ctrl: keyboard.isControlPressed,
      timeStamp: e.timeStamp,
    );
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.touch && _activeStylusPointer != null) {
      return; // Palm rejection
    }
    if (_touchPointers.containsKey(e.pointer)) {
      _touchPointers[e.pointer] = e.localPosition;
      if (_touchPointers.length >= 2) {
        final pts = _touchPointers.values.take(2).toList();
        final focal = (pts[0] + pts[1]) / 2;
        final dist = (pts[0] - pts[1]).distance;
        if (_lastPinchFocal != null) {
          c.panBy(focal - _lastPinchFocal!);
        }
        _lastPinchFocal = focal;
        if (_initialPinchDistance != null &&
            _initialPinchDistance! > 10 &&
            _initialPinchScale != null) {
          final factor =
              (dist / _initialPinchDistance!) * (_initialPinchScale! / c.scale);
          c.zoomAt(focal, factor);
        }
        return;
      }
    }
    if (e.pointer != _drawingPointer) return;
    c.pointerMove(
      e.localPosition,
      pressure: e.kind == PointerDeviceKind.mouse ? 0.5 : e.pressure,
    );
  }

  void _onPointerUp(PointerUpEvent e) {
    _releasePointer(e.pointer);
    // Only the pointer that started the stroke may finish it (a lifted palm
    // must not end the pen stroke).
    if (e.pointer == _drawingPointer) {
      _drawingPointer = null;
      c.pointerUp();
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _releasePointer(e.pointer);
    if (e.pointer == _drawingPointer) {
      _drawingPointer = null;
      c.pointerCancel();
    }
  }

  void _releasePointer(int pointer) {
    if (_activeStylusPointer == pointer) _activeStylusPointer = null;
    _touchPointers.remove(pointer);
    if (_touchPointers.length < 2) _endPinch();
  }

  void _endPinch() {
    _initialPinchDistance = null;
    _initialPinchScale = null;
    _lastPinchFocal = null;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      // Mouse wheel zooms around the cursor.
      final factor = math.exp(-e.scrollDelta.dy / 400);
      c.zoomAt(e.localPosition, factor);
    } else if (e is PointerScaleEvent) {
      c.zoomAt(e.localPosition, e.scale);
    }
  }

  // Precision touchpads: two-finger pan and pinch-zoom.
  void _onPanZoomStart(PointerPanZoomStartEvent e) => _lastPanZoomScale = 1;

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    c.panBy(e.panDelta);
    if (e.scale != _lastPanZoomScale) {
      c.zoomAt(e.localPosition, e.scale / _lastPanZoomScale);
      _lastPanZoomScale = e.scale;
    }
  }

  MouseCursor _cursor() {
    if (c.isPanning) return SystemMouseCursors.grabbing;
    if (c.spaceHeld || c.tool == CanvasTool.pan) {
      return SystemMouseCursors.grab;
    }
    switch (c.tool) {
      case CanvasTool.pen ||
          CanvasTool.highlighter ||
          CanvasTool.eraser ||
          CanvasTool.lasso ||
          CanvasTool.connect:
        return SystemMouseCursors.precise;
      case CanvasTool.text:
        return SystemMouseCursors.text;
      case CanvasTool.select || CanvasTool.pan:
        final hover = c.hoverPosition;
        if (hover == null) return SystemMouseCursors.basic;
        if (c.resizeHandleAt(hover) != null) {
          return SystemMouseCursors.resizeDownRight;
        }
        final hit = c.hitTest(c.toWorld(hover));
        if (hit == null) return SystemMouseCursors.basic;
        return SystemMouseCursors.move;
    }
  }

  // -------------------------------------------------------------- build --

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            _size = constraints.biggest;
            s.canvasViewportSize = _size;
            if (!_viewChecked && !_size.isEmpty) {
              _viewChecked = true;
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => c.ensureSensibleView(_size),
              );
            }
            final editing = c.editingItem;
            return Stack(
              children: [
                Positioned.fill(
                  child: Focus(
                    focusNode: _focusNode,
                    onKeyEvent: _onKey,
                    child: MouseRegion(
                      cursor: _cursor(),
                      onExit: (_) => c.pointerHover(null),
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _onPointerDown,
                        onPointerMove: _onPointerMove,
                        onPointerUp: _onPointerUp,
                        onPointerCancel: _onPointerCancel,
                        onPointerHover: (e) => c.pointerHover(e.localPosition),
                        onPointerSignal: _onPointerSignal,
                        onPointerPanZoomStart: _onPanZoomStart,
                        onPointerPanZoomUpdate: _onPanZoomUpdate,
                        child: CustomPaint(
                          painter: CanvasPainter(c),
                          size: Size.infinite,
                        ),
                      ),
                    ),
                  ),
                ),
                if (editing != null)
                  _TextEditorOverlay(
                    key: ValueKey(editing.id),
                    controller: c,
                    item: editing,
                    onDone: () {
                      c.endEditing();
                      _focusNode.requestFocus();
                    },
                  ),
                Positioned(
                  left: Space.xl,
                  top: Space.xl,
                  child: _TitleChip(state: s, controller: c),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: Space.xl,
                  child: Center(
                    child: CanvasContextBar(
                      controller: c,
                      onActivate: s.activateCanvasItem,
                      onRefreshLink: (l) => s.capture.refreshPreview(l.assetId),
                    ),
                  ),
                ),
                Positioned(
                  right: Space.xl,
                  top: Space.xl + 10,
                  child: _SaveIndicator(state: c.saveState),
                ),
                Positioned(
                  left: Space.xl,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    // Scrolls on short screens (e.g. iPhone landscape).
                    child: SingleChildScrollView(
                      child: CanvasToolbar(
                        controller: c,
                        onAddImage: _addImages,
                        onAddLink: _addLink,
                        onAddDocument: _addDocuments,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: Space.xl,
                  bottom: Space.xl,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (_showMinimap && c.items.isNotEmpty) ...[
                        _Minimap(controller: c, viewport: _size),
                        const SizedBox(height: Space.sm),
                      ],
                      _ZoomControls(
                        controller: c,
                        viewport: _size,
                        minimap: _showMinimap,
                        onToggleMinimap: () =>
                            setState(() => _showMinimap = !_showMinimap),
                      ),
                    ],
                  ),
                ),
                if (c.items.isEmpty) const _EmptyHint(),
                if (c.tool == CanvasTool.connect && c.connectSource != null)
                  const Positioned(
                    top: Space.md,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        key: ValueKey('connect-hint'),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.cardRaised,
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                          ),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: Text(
                              'Now tap the item to connect to '
                              '(tap empty space to cancel)',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Minimap extends StatelessWidget {
  const _Minimap({required this.controller, required this.viewport});

  final CanvasController controller;
  final Size viewport;

  @override
  Widget build(BuildContext context) {
    const size = Size(200, 130);
    final painter = MinimapPainter(controller, viewport);
    void jump(Offset local) =>
        controller.centerOn(painter.toWorld(local, size), viewport);
    return Tooltip(
      message: 'Overview — click or drag to move around',
      waitDuration: const Duration(seconds: 1),
      child: GestureDetector(
        onTapDown: (d) => jump(d.localPosition),
        onPanUpdate: (d) => jump(d.localPosition),
        child: Container(
          width: size.width,
          height: size.height,
          decoration: BoxDecoration(
            color: AppColors.card.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CustomPaint(painter: painter, size: size),
          ),
        ),
      ),
    );
  }
}

/// A real text field placed exactly over the note being edited.
class _TextEditorOverlay extends StatefulWidget {
  const _TextEditorOverlay({
    super.key,
    required this.controller,
    required this.item,
    required this.onDone,
  });

  final CanvasController controller;
  final TextItem item;
  final VoidCallback onDone;

  @override
  State<_TextEditorOverlay> createState() => _TextEditorOverlayState();
}

class _TextEditorOverlayState extends State<_TextEditorOverlay> {
  late final _text = TextEditingController(text: widget.item.text);
  final _focus = FocusNode(debugLabel: 'canvas-text');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final item = widget.item;
    final scale = c.scale;
    final topLeft = c.toScreen(item.position);
    final bounds = c.itemBounds(item);
    final style = styleFor(item, scale: scale);
    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      width: item.width * scale,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: bounds.height * scale),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): widget.onDone,
          },
          child: TextField(
            controller: _text,
            focusNode: _focus,
            maxLines: null,
            onChanged: c.updateEditingText,
            onTapOutside: (_) {},
            style: style,
            textAlign: textAlignFor(item.align),
            cursorWidth: 1.5,
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              hintText: 'Type…  (# heading, - list, **bold**)',
              hintStyle: style.copyWith(color: AppColors.textFaint),
              contentPadding: EdgeInsets.all(kTextPadding * scale),
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleChip extends StatelessWidget {
  const _TitleChip({required this.state, required this.controller});

  final AppState state;
  final CanvasController controller;

  Future<void> _onMenu(BuildContext context, String choice) async {
    if (choice == 'rename') {
      final title = await promptText(
        context,
        title: 'Rename canvas',
        initial: controller.title,
      );
      if (title != null) await state.renameCanvas(controller.id, title);
    } else if (choice == 'folder') {
      String? folderId = controller.folderId;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Move to folder', style: TextStyle(fontSize: 16)),
            content: SizedBox(
              width: 320,
              child: FolderDropdown(
                workspace: state.workspace,
                value: folderId,
                onChanged: (v) => setState(() => folderId = v),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Move'),
              ),
            ],
          ),
        ),
      );
      if (ok == true) await state.moveCanvasToFolder(controller.id, folderId);
    } else if (choice == 'delete') {
      // Also here, not only in the sidebar's right-click menu: on a phone
      // or a touch-only iPad this is the way to remove a canvas.
      final ok = await confirm(
        context,
        title: 'Move “${controller.title}” to trash?',
        message:
            'The file is moved to a trash folder inside your data folder, '
            'not erased.',
        action: 'Move to trash',
      );
      if (ok) await state.deleteCanvas(controller.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final folder = state.workspace.folderPath(controller.folderId);
    return PopupMenuButton<String>(
      tooltip: 'Canvas options',
      position: PopupMenuPosition.under,
      onSelected: (v) => _onMenu(context, v),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'rename', height: 36, child: Text('Rename')),
        PopupMenuItem(
          value: 'folder',
          height: 36,
          child: Text('Move to folder…'),
        ),
        PopupMenuItem(
          value: 'delete',
          height: 36,
          child: Text('Move to trash'),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              folder.isEmpty ? Icons.grid_view : Icons.folder_outlined,
              size: 15,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: Space.sm),
            if (folder.isNotEmpty)
              Text(
                '${folder.map((f) => f.name).join(' / ')} / ',
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textMuted,
                ),
              ),
            Text(
              controller.title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 16, color: AppColors.textFaint),
          ],
        ),
      ),
    );
  }
}

class _SaveIndicator extends StatelessWidget {
  const _SaveIndicator({required this.state});

  final SaveState state;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (state) {
      SaveState.saved => (
        Icons.cloud_done_outlined,
        'Saved on $thisDevice',
        AppColors.textFaint,
      ),
      SaveState.pending ||
      SaveState.saving => (Icons.sync, 'Saving…', AppColors.textFaint),
      SaveState.failed => (
        Icons.cloud_off_outlined,
        'Save failed — retrying on next change',
        AppColors.danger,
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.controller,
    required this.viewport,
    required this.minimap,
    required this.onToggleMinimap,
  });

  final CanvasController controller;
  final Size viewport;
  final bool minimap;
  final VoidCallback onToggleMinimap;

  @override
  Widget build(BuildContext context) {
    final center = viewport.center(Offset.zero);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GhostIconButton(
            icon: Icons.map_outlined,
            tooltip: minimap ? 'Hide overview' : 'Show overview',
            active: minimap,
            size: 16,
            onTap: onToggleMinimap,
          ),
          GhostIconButton(
            icon: Icons.remove,
            tooltip: 'Zoom out  (Ctrl −)',
            size: 16,
            onTap: () => controller.zoomAt(center, 1 / 1.2),
          ),
          Tooltip(
            message: 'Back to 100 %  (Ctrl 1)',
            child: InkWell(
              onTap: () => controller.zoomAt(center, 1 / controller.scale),
              child: SizedBox(
                width: 48,
                child: Text(
                  '${(controller.scale * 100).round()}%',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ),
          ),
          GhostIconButton(
            icon: Icons.add,
            tooltip: 'Zoom in  (Ctrl +)',
            size: 16,
            onTap: () => controller.zoomAt(center, 1.2),
          ),
          GhostIconButton(
            icon: Icons.fit_screen_outlined,
            tooltip: 'Fit everything on screen  (Ctrl 0)',
            size: 16,
            onTap: () => controller.fitToContent(
              viewport,
              minScale: CanvasController.minScale,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Text(
          touchFirst ? 'Double-tap anywhere to write  ·  pick the pen to draw' : 'Double-click anywhere to write  ·  Ctrl+V to paste text, links or images  ·  P to draw',
          style: const TextStyle(color: AppColors.textFaint, fontSize: 13),
        ),
      ),
    );
  }
}
