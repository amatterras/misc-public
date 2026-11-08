// A note as a full page: its details (title, text, tags, links, history)
// followed by notebook pages for handwriting, text boxes and PDF pages.
//
// The pages use the same writing engine as Canvas (CanvasController,
// CanvasPainter, LiveInkPainter, stroke_geometry): one stroke model, one
// renderer, one way of saving and syncing. A note's handwriting is a
// canvas document with the fixed id `nb-<noteId>` and kind "notebook".
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/page_windows.dart';
import '../../app/shell.dart' show WorkspaceBuilder;
import '../../app/background_palette.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/paper.dart';
import '../../data/storage/app_log.dart';
import '../../new_ui/new_components.dart' show NewAtmosphere;
import '../../platform/device_idiom.dart';
import '../../platform/input_hints.dart';
import '../../platform/ios_bridge.dart';
import '../../widgets/common.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_painter.dart';
import '../canvas/canvas_toolbar.dart' show EraserPanel;
import '../ink/native_ink.dart';
import '../ink/pen_sizes.dart';
import '../ink/stroke_geometry.dart';
import 'notebook_layout.dart';
import '../export/export_dialog.dart';
import 'paper_dialog.dart';
import 'paper_painter.dart';
import 'notes_page.dart' show NoteEditor;
import '../sharing/share_dialog.dart';
import '../templates/templates.dart';

/// Opens note [noteId] as its own page (with a normal Back button).
Future<void> openNotePage(BuildContext context, AppState state, String id) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        // A pushed route is outside the shell: give it the atmosphere.
        builder: (_) =>
            NewAtmosphere.behind(child: NotePage(state: state, noteId: id)),
      ),
    );

/// Whether a notebook opens with the pen (iPad) or the text tool (Windows,
/// iPhone: tap to type, choose Draw to draw).
bool notebookStartsWithPen(Size screen) =>
    touchFirst && screen.shortestSide >= 600;

/// Pen colours offered on notebook pages (dark ones for PDF pages).
final notebookInk = InkColors.all;

class NotePage extends StatefulWidget {
  const NotePage({super.key, required this.state, required this.noteId});

  final AppState state;
  final String noteId;

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> {
  CanvasController? _c;
  bool _closed = false;
  double _zoom = 1; // times "fit the page width"

  /// The smallest page zoom (times "fit the page width"). Original: 40 %.
  /// New: the zoom at which the whole page (the tallest one in the note) is
  /// visible with about 2.5 cm of workspace around it, worked out from the
  /// real page size and the room available; never larger than "fit width".
  double _minZoom = originalMinZoom;
  static const originalMinZoom = 0.4;

  /// The zoom actually shown: [_zoom], but never below [_minZoom] (a window
  /// that became small, or a zoom saved before the limit existed).
  double get _z => _zoom < _minZoom ? _minZoom : _zoom;

  /// Logical pixels in one centimetre on this device (Windows 96 dpi, iPad
  /// about 132, iPhone about 160 points per inch).
  double get _pixelsPerCm =>
      touchFirst ? (DeviceIdiom.isPhone ? 62.0 : 52.0) : 37.8;

  double _minZoomFor(BoxConstraints box, NotebookLayout? layout, double fit) {
    var tallest = NotebookLayout.plainHeight;
    if (layout != null) {
      tallest = 0;
      for (var i = 0; i < layout.pageCount; i++) {
        tallest = math.max(tallest, layout.pageHeight(i));
      }
    }
    final shortSide = math.min(box.maxWidth, box.maxHeight);
    // About 2.5 cm each side, but never more than 14 % of the room: on a
    // phone that would leave no space for the page.
    final margin = math.min(2.5 * _pixelsPerCm, shortSide * 0.14);
    final widthScale = (box.maxWidth - 2 * margin) / NotebookLayout.pageWidth;
    final heightScale = (box.maxHeight - 2 * margin) / tallest;
    final wholePage = math.min(widthScale, heightScale);
    if (!wholePage.isFinite || wholePage <= 0 || fit <= 0) {
      return originalMinZoom;
    }
    // Never forces a zoom-in, and never goes below the canvas minimum.
    return (wholePage / fit).clamp(0.2 / fit, 1.0).toDouble();
  }

  bool _fingerDraws = false;
  final _scroll = ScrollController();
  final _horizontalScroll = ScrollController();
  final _gestureSurfaceKey = GlobalKey();
  final Map<int, GlobalKey> _pageKeys = {};
  final Map<int, Offset> _noteTouches = {};
  double? _pinchStartDistance;
  double? _pinchStartZoom;
  Offset? _pinchStartFocal;
  Offset? _pinchDocumentAnchor;
  Offset? _pinchPrefix;
  double _pinchStartScale = 1;
  double _fitScale = 1;
  NotebookLayout? _currentLayout;
  StreamSubscription<String>? _squeeze;
  AppLifecycleListener? _lifecycle;

  // The pointer drawing right now, and whether a Pencil touches (palm
  // rejection: fingers are ignored meanwhile).
  int? _pointer;

  /// Whether a Pencil touches. Only the scroll settings depend on it, so
  /// they listen to it alone: putting the Pencil down must not rebuild the
  /// pages in the very frame that should show the first ink.
  final _stylusDownNow = ValueNotifier<bool>(false);
  bool get _stylusDown => _stylusDownNow.value;
  set _stylusDown(bool value) => _stylusDownNow.value = value;
  bool _pointerIsStylus = false;

  /// Every Apple Pencil sample for the stroke being written (iPad).
  final PencilFeed _pencilFeed = PencilFeed();

  /// Each page's finished ink kept as one image while the pen writes.
  final Map<int, InkRasterCache> _inkRaster = {};

  AppState get s => widget.state;

  String get _zoomSetting => 'notebookZoom.${widget.noteId}';

  @override
  void initState() {
    super.initState();
    s.notebookJump.addListener(_onJump);
    _scroll.addListener(_onNotebookScroll);
    _horizontalScroll.addListener(_onNotebookScroll);
    final savedZoom = s.settings.get<num>(_zoomSetting)?.toDouble();
    _zoom = savedZoom != null && savedZoom.isFinite
        ? NotebookZoom.clampZoom(savedZoom)
        : 1;
    _fingerDraws = s.settings.get<bool>('notebookFingerDraws') ?? false;
    unawaited(_open());
    final ios = s.ios;
    if (ios != null) {
      _squeeze = ios.pencilSqueeze.listen(_onSqueeze);
      unawaited(ios.enablePencilSqueeze());
    }
    _lifecycle = AppLifecycleListener(
      onInactive: () {
        _c?.squeezeEnded();
        _c?.cancelPendingLineStraightening();
        unawaited(_c?.flush());
      },
    );
  }

  void _onNotebookScroll() => _c?.cancelPendingLineStraightening();

  void _setZoom(double value) {
    final zoom = value.clamp(_minZoom, 3.0).toDouble();
    if (_zoom == zoom) return;
    setState(() => _zoom = zoom);
    unawaited(s.settings.set(_zoomSetting, zoom));
  }

  void _notePointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch || _stylusDown) return;
    _c?.cancelPendingLineStraightening();
    _noteTouches[e.pointer] = e.localPosition;
    if (_noteTouches.length == 2) {
      final c = _c;
      if (_pointer != null && !_pointerIsStylus && c != null) {
        _pointer = null;
        c.pointerCancel();
      }
      final points = _noteTouches.values.toList();
      _pinchStartDistance = (points[0] - points[1]).distance;
      _pinchStartZoom = _z;
      _pinchStartFocal = (points[0] + points[1]) / 2;
      _pinchStartScale = _c?.scale ?? _fitScale * _z;
      _capturePinchAnchor(_pinchStartFocal!);
    }
  }

  void _notePointerMove(PointerMoveEvent e) {
    if (!_noteTouches.containsKey(e.pointer)) return;
    _noteTouches[e.pointer] = e.localPosition;
    if (_noteTouches.length < 2 ||
        _pinchStartDistance == null ||
        _pinchStartFocal == null ||
        _pinchStartZoom == null) {
      return;
    }
    final points = _noteTouches.values.take(2).toList();
    final distance = (points[0] - points[1]).distance;
    if (_pinchStartDistance! < 10) return;
    final focal = (points[0] + points[1]) / 2;
    final nextZoom = (_pinchStartZoom! * distance / _pinchStartDistance!).clamp(
      _minZoom,
      3.0,
    );
    if ((_z - nextZoom).abs() < 0.001) return;
    setState(() => _zoom = nextZoom);
    final anchor = _pinchDocumentAnchor;
    final prefix = _pinchPrefix;
    final nextScale = NotebookZoom.clampScale(_fitScale * nextZoom);
    // The note header is fixed size; page coordinates alone scale. Use the
    // measured page origin to compensate both axes around the pinch centroid.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (anchor != null && prefix != null && _scroll.hasClients) {
        final target = prefix.dy + anchor.dy * nextScale - focal.dy;
        _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
      }
      if (anchor != null && prefix != null && _horizontalScroll.hasClients) {
        final target = prefix.dx + anchor.dx * nextScale - focal.dx;
        _horizontalScroll.jumpTo(
          target.clamp(0, _horizontalScroll.position.maxScrollExtent),
        );
      }
    });
  }

  void _capturePinchAnchor(Offset focal) {
    final layout = _currentLayout;
    final bodyObject = _gestureSurfaceKey.currentContext?.findRenderObject();
    if (layout == null || bodyObject is! RenderBox || !bodyObject.hasSize) {
      _pinchDocumentAnchor = null;
      _pinchPrefix = null;
      return;
    }
    final globalFocal = bodyObject.localToGlobal(focal);
    var selectedIndex = 0;
    Rect? selectedGlobal;
    var nearestDistance = double.infinity;
    for (final entry in _pageKeys.entries) {
      final object = entry.value.currentContext?.findRenderObject();
      if (object is! RenderBox || !object.hasSize) continue;
      final rect = object.localToGlobal(Offset.zero) & object.size;
      if (rect.contains(globalFocal)) {
        selectedIndex = entry.key;
        selectedGlobal = rect;
        break;
      }
      final distance = (rect.center - globalFocal).distance;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        selectedIndex = entry.key;
        selectedGlobal = rect;
      }
    }
    if (selectedGlobal == null || _pinchStartScale <= 0) {
      _pinchDocumentAnchor = null;
      _pinchPrefix = null;
      return;
    }
    final page = layout.pageRect(selectedIndex);
    final bodyGlobal = bodyObject.localToGlobal(Offset.zero);
    final pageLocal = selectedGlobal.topLeft - bodyGlobal;
    final pageScrollTop = _scroll.hasClients ? _scroll.offset : 0;
    final pageScrollLeft = _horizontalScroll.hasClients
        ? _horizontalScroll.offset
        : 0;
    _pinchDocumentAnchor =
        page.topLeft +
        Offset(
          (globalFocal.dx - selectedGlobal.left) / _pinchStartScale,
          (globalFocal.dy - selectedGlobal.top) / _pinchStartScale,
        );
    _pinchPrefix = Offset(
      pageScrollLeft + pageLocal.dx - page.left * _pinchStartScale,
      pageScrollTop + pageLocal.dy - page.top * _pinchStartScale,
    );
  }

  void _notePointerEnd(PointerEvent e) {
    _noteTouches.remove(e.pointer);
    if (_noteTouches.length < 2) {
      if (_pinchStartDistance != null) {
        unawaited(s.settings.set(_zoomSetting, _zoom));
      }
      _pinchStartDistance = null;
      _pinchStartZoom = null;
      _pinchStartFocal = null;
      _pinchDocumentAnchor = null;
      _pinchPrefix = null;
    }
  }

  Future<void> _open() async {
    final id = notebookIdFor(widget.noteId);
    final note = s.workspace.notes[widget.noteId];
    CanvasDocument? doc;
    try {
      doc = await s.canvases.load(id);
    } catch (e, st) {
      AppLog.error('Could not open the handwriting of a note', e, st);
    }
    doc ??= CanvasDocument(
      id: id,
      title: note?.displayTitle ?? 'Note',
      items: const [],
      updatedAt: DateTime.now(),
      kind: 'notebook',
    );
    if (!mounted) return;
    final c = CanvasController(
      document: doc,
      onSave: s.saveDocument,
      resources: s.resources,
      clock: s.workspace.clock,
    );
    // Windows and iPhone: clicking or tapping a page types; Draw must be
    // chosen. iPad: Type or Draw is always chosen (Pencil-first).
    c.tool = notebookStartsWithPen(MediaQuery.sizeOf(context))
        ? CanvasTool.pen
        : CanvasTool.text;
    if (doc.pageBackgrounds.isNotEmpty) c.setPen(color: notebookInk[1]);
    // The eraser as last chosen on this device (shared with the Mindmap
    // and the Calendar; changed here through AppState.setEraser).
    c.setEraser(mode: s.eraserMode, size: s.eraserSize);
    s.openNotebooks.add(c); // sync merges remote changes into this document
    // Apple Pencil double-tap: Undo in this handwriting while it is shown.
    _unregisterTap = s.pencilDoubleTap.register(
      c,
      active: () => mounted && (ModalRoute.of(context)?.isCurrent ?? true),
    );
    setState(() => _c = c);
    _onJump(); // a link may have asked for a page of this note
  }

  /// A PDF page link asked to show a page of this note: scroll there. The
  /// text and handwriting are not touched.
  void _onJump() {
    final j = s.notebookJump.value;
    if (j == null || j.noteId != widget.noteId || _c == null) return;
    s.notebookJump.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final layout = _currentLayout;
      if (!mounted || layout == null || !_scroll.hasClients) return;
      final page = j.page.clamp(0, layout.pageCount - 1);
      final top = layout.pageRect(page).top * (_c?.scale ?? 1);
      _scroll.jumpTo(top.clamp(0.0, _scroll.position.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _pageKeys[page]?.currentContext;
        if (mounted && ctx != null) {
          Scrollable.ensureVisible(ctx, duration: Duration.zero);
        }
      });
    });
  }

  void Function()? _unregisterTap;

  void _onSqueeze(String phase) {
    final c = _c;
    if (c == null) return;
    if (phase == 'began') {
      if (ModalRoute.of(context)?.isCurrent ?? false) c.squeezeBegan();
    } else {
      c.squeezeEnded();
    }
  }

  /// Saves and lets go of the document (Back, or the page closing).
  Future<void> _close() async {
    final c = _c;
    if (c == null || _closed) return;
    _closed = true;
    c.squeezeEnded();
    c.cancelPendingLineStraightening();
    c.endEditing();
    try {
      await c.flush();
    } catch (e, st) {
      AppLog.error('Saving a note\'s handwriting failed', e, st);
    }
    s.openNotebooks.remove(c);
  }

  @override
  void dispose() {
    _stylusDownNow.dispose();
    _pencilFeed.end();
    for (final cache in _inkRaster.values) {
      cache.dispose();
    }
    s.notebookJump.removeListener(_onJump);
    _squeeze?.cancel();
    _unregisterTap?.call();
    _lifecycle?.dispose();
    _scroll.removeListener(_onNotebookScroll);
    _horizontalScroll.removeListener(_onNotebookScroll);
    _scroll.dispose();
    _horizontalScroll.dispose();
    final c = _c;
    if (c != null) {
      c.cancelPendingLineStraightening();
      unawaited(_close().whenComplete(c.dispose));
    }
    super.dispose();
  }

  // ---------------------------------------------------------- pointers --

  bool _accepts(PointerEvent e, CanvasController c) => switch (e.kind) {
    PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => true,
    PointerDeviceKind.mouse => e.buttons & kPrimaryButton != 0,
    // iOS reports Pencil through Flutter's stylus kind. Touch never starts
    // ink there, including when the legacy finger-draw preference is on.
    PointerDeviceKind.touch =>
      !touchFirst &&
          !_stylusDown &&
          (_fingerDraws || c.tool == CanvasTool.text),
    _ => false,
  };

  /// The controller works in "screen" units of the page zoom with no
  /// offset: screen = notebook position × zoom.
  Offset _screen(Offset local, Rect page, double scale) =>
      (page.topLeft + local / scale) * scale;

  static double _pressure(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
          e.kind == PointerDeviceKind.invertedStylus
      ? normalizedPressure(e.pressure, e.pressureMax)
      : 0.5;

  void _down(PointerDownEvent e, CanvasController c, Rect page, double sc) {
    final isStylus =
        e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus;
    if ((!isStylus && _pointer != null) || !_accepts(e, c)) return;
    if (isStylus) {
      if (_pointer != null && !_pointerIsStylus) {
        c.pointerCancel();
        _pointer = null;
        _pointerIsStylus = false;
      }
      _noteTouches.clear();
      _pinchStartDistance = null;
      _pinchStartZoom = null;
      _pinchStartFocal = null;
      _pinchDocumentAnchor = null;
      _pinchPrefix = null;
      _stylusDown = true;
    }
    _pointer = e.pointer;
    _pointerIsStylus =
        e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus;
    c.pointerDown(
      _screen(e.localPosition, page, sc),
      kind: e.kind,
      pressure: _pressure(e),
      timeStamp: e.timeStamp,
    );
    final pointer = e.pointer;
    _pencilFeed.begin(
      e,
      move: (local, pressure, timeStamp) {
        if (_pointer != pointer) return;
        c.pointerMove(
          _screen(local, page, sc),
          pressure: pressure,
          timeStamp: timeStamp,
        );
      },
      predict: (local) {
        if (_pointer == pointer) {
          c.setPredictedPoint(local == null ? null : _screen(local, page, sc));
        }
      },
    );
  }

  void _move(PointerMoveEvent e, CanvasController c, Rect page, double sc) {
    if (e.pointer != _pointer) return;
    // Native Pencil samples may already have delivered this moment.
    if (!_pencilFeed.flutterMove(e)) return;
    c.pointerMove(
      _screen(e.localPosition, page, sc),
      pressure: _pressure(e),
      timeStamp: e.timeStamp,
    );
  }

  void _up(
    PointerEvent e,
    CanvasController c,
    Rect page,
    double sc, {
    bool cancel = false,
  }) {
    if (e.pointer != _pointer) return;
    final wasStylus = _pointerIsStylus;
    _pointer = null;
    _pointerIsStylus = false;
    _pencilFeed.end();
    _stylusDown = false;
    if (cancel) {
      // Pencil writing interrupted by the system is kept, not erased.
      c.pointerCancel(keepInk: wasStylus);
    } else {
      c.pointerUp(
        screen: _screen(e.localPosition, page, sc),
        timeStamp: e.timeStamp,
      );
    }
  }

  // ------------------------------------------------------------ PDFs --

  /// Puts the pages of chosen PDFs into this note, after the last page
  /// with content. The PDF is kept unchanged as an attachment.
  Future<void> _addPdf() async {
    final c = _c;
    if (c == null) return;
    final assets = await s.capture.pickDocuments();
    if (assets.isEmpty || !mounted) return;
    final backgrounds = [...c.pageBackgrounds];
    var added = 0;
    for (final asset in assets) {
      s.workspace.attachToNote(widget.noteId, asset.id);
      final file = s.workspace.documentFile(asset);
      final sizes = file == null ? null : await s.ios?.pdfPageSizes(file.path);
      if (sizes == null || sizes.isEmpty) continue;
      final layout = NotebookLayout(
        backgrounds: backgrounds,
        content: NotebookLayout.contentOf(c.items, c.itemBounds),
      );
      // The trailing blank page becomes the first PDF page.
      final start = layout.pageCount - 1;
      for (var k = 0; k < sizes.length; k++) {
        backgrounds.add(
          PageBackground(
            pageIndex: start + k,
            assetId: asset.id,
            pdfPage: k,
            width: sizes[k].width,
            height: sizes[k].height,
          ),
        );
      }
      added += sizes.length;
    }
    if (added > 0) {
      c.setPageBackgrounds(backgrounds);
      c.setPen(color: notebookInk[1]);
      s.showToast('Added $added PDF page(s)');
    } else {
      s.showToast(
        'PDF attached to the note. Its pages can be written on on '
        'iPhone/iPad.',
      );
    }
  }

  /// Writes a copy of each PDF in this note with the ink drawn on it and
  /// shows the share sheet. The original PDFs are not changed.
  Future<void> _exportPdf() async {
    final c = _c;
    final ios = s.ios;
    if (c == null || ios == null) return;
    await c.flush();
    final layout = NotebookLayout(
      backgrounds: c.pageBackgrounds,
      content: NotebookLayout.contentOf(c.items, c.itemBounds),
    );
    final byAsset = <String, List<PageBackground>>{};
    for (final b in c.pageBackgrounds) {
      byAsset.putIfAbsent(b.assetId, () => []).add(b);
    }
    for (final entry in byAsset.entries) {
      final asset = s.workspace.assets[entry.key];
      final file = asset == null ? null : s.workspace.documentFile(asset);
      if (asset == null || file == null) continue;
      final pages = <Map<String, Object>>[
        for (final b in entry.value)
          {
            'page': b.pdfPage,
            'strokes': annotationStrokes(
              c.items.whereType<StrokeItem>(),
              layout.pageRect(b.pageIndex),
              b,
            ),
          },
      ];
      final name = asset.label.replaceAll(RegExp(r'\.pdf$'), '');
      final target =
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          '$name (annotated).pdf';
      if (await ios.exportAnnotatedPdf(file.path, target, pages)) {
        await ios.shareFile(target);
      } else {
        s.showToast('Could not export ${asset.label}');
      }
    }
  }

  // ------------------------------------------------------------- build --

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final note = s.workspace.notes[widget.noteId];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _close();
        if (context.mounted) Navigator.of(context).pop();
      },
      // Transparent: in the shell the app-wide atmosphere shows through;
      // pushed on its own, openNotePage puts one behind it.
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          title: Text(note?.displayTitle ?? 'Note'),
          actions: [
            if (note != null)
              IconButton(
                key: const ValueKey('note-template'),
                tooltip: 'Save as a template',
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                onPressed: () async {
                  final name = await promptText(
                    context,
                    title: 'Template name',
                    initial: note.displayTitle,
                    action: 'Save',
                  );
                  if (name == null || name.trim().isEmpty) return;
                  s.workspace.templates.put(
                    noteTemplate(name.trim(), note.title, note.body),
                  );
                  s.showToast(
                    'Saved. Use it with “New note from a template” (Ctrl+Shift+P).',
                  );
                },
              ),
            if (note != null)
              IconButton(
                key: const ValueKey('note-share'),
                tooltip: 'Share a read-only link',
                icon: const Icon(Icons.ios_share, size: 18),
                onPressed: () => showShareDialog(
                  context,
                  s,
                  kind: 'note',
                  sourceId: note.id,
                  title: note.displayTitle,
                  body: note.body,
                ),
              ),
            // Inside a page window there is no route to leave.
            if (Navigator.of(context).canPop())
              IconButton(
                key: const ValueKey('note-open-window'),
                tooltip: 'Open in a window',
                icon: const Icon(Icons.open_in_new, size: 18),
                onPressed: () async {
                  await _close();
                  s.windows.open(
                    AppPage.notes,
                    refId: widget.noteId,
                    title: note?.displayTitle ?? 'Note',
                    mode: PageMode.floating,
                  );
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
          ],
          bottom: c == null
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(44),
                  child: _toolbar(c),
                ),
        ),
        // The note's details show at once; its pages follow when loaded.
        body: note == null
            ? const SizedBox.shrink()
            : ListenableBuilder(
                listenable: Listenable.merge([?c, s.workspace.changes]),
                builder: (context, _) => _body(c),
              ),
      ),
    );
  }

  Widget _body(CanvasController? c) {
    final layout = c == null
        ? null
        : NotebookLayout(
            backgrounds: c.pageBackgrounds,
            content: NotebookLayout.contentOf(c.items, c.itemBounds),
          );
    return LayoutBuilder(
      builder: (context, box) {
        final fit = (box.maxWidth - 80) / NotebookLayout.pageWidth;
        _minZoom = _minZoomFor(box, layout, fit);
        final scale = (fit * _z).clamp(0.2, 4.0);
        _currentLayout = layout;
        _fitScale = fit;
        c?.setView(Offset.zero, scale);
        final width = NotebookLayout.pageWidth * scale + 80;
        Widget list = Scrollbar(
          controller: _scroll,
          interactive: true,
          child: WorkspaceBuilder(
            state: s,
            builder: (context) => NoteEditor(
              key: ValueKey('note-${widget.noteId}'),
              state: s,
              noteId: widget.noteId,
              scrollController: _scroll,
              onOpenNote: (id) => Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => NotePage(state: s, noteId: id),
                ),
              ),
              onDeleted: () => Navigator.of(context).maybePop(),
              pageCount: layout?.pageCount ?? 0,
              pageBuilder: c == null || layout == null
                  ? null
                  : (context, i) => _page(c, layout, i, scale),
            ),
          ),
        );
        if (width > box.maxWidth) {
          list = SingleChildScrollView(
            controller: _horizontalScroll,
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: width, height: box.maxHeight, child: list),
          );
        }
        final surface = Listener(
          key: _gestureSurfaceKey,
          behavior: HitTestBehavior.translucent,
          onPointerDown: _notePointerDown,
          onPointerMove: _notePointerMove,
          onPointerUp: _notePointerEnd,
          onPointerCancel: _notePointerEnd,
          child: list,
        );
        return ValueListenableBuilder<bool>(
          valueListenable: _stylusDownNow,
          child: surface,
          builder: (context, stylusDown, surface) => ScrollConfiguration(
            // This configuration must wrap both axes; previously the outer
            // horizontal scroll view used Flutter's default, which accepts
            // a Pencil drag and steals writing input.
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: stylusDown || (!touchFirst && _fingerDraws)
                  ? {PointerDeviceKind.trackpad}
                  : {PointerDeviceKind.touch, PointerDeviceKind.trackpad},
            ),
            child: surface!,
          ),
        );
      },
    );
  }

  Widget _page(
    CanvasController c,
    NotebookLayout layout,
    int index,
    double scale,
  ) {
    final rect = layout.pageRect(index);
    final background = layout.background(index);
    final editing = c.editingItem;
    final editingHere =
        editing != null && layout.pageAt(editing.position.dy) == index;
    return KeyedSubtree(
      key: ValueKey('notebook-page-$index'),
      child: Padding(
        padding: EdgeInsets.only(
          top: index == 0 ? AppSpace.xl : 0,
          bottom: NotebookLayout.gap * scale,
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: _pageKeys.putIfAbsent(index, GlobalKey.new),
            width: rect.width * scale,
            height: rect.height * scale,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.xs),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: PaperPainter(
                      s.workspace.notes[widget.noteId]?.paperOrDefault ??
                          const NotePaper(),
                      scale: scale,
                      light: Theme.of(context).brightness == Brightness.light,
                    ),
                  ),
                  if (background != null)
                    PdfPageView(state: s, background: background, scale: scale),
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: CanvasPainter(
                        c,
                        page: rect,
                        pageScale: scale,
                        rasterCache: _inkRaster.putIfAbsent(
                          index,
                          InkRasterCache.new,
                        ),
                        devicePixelRatio: MediaQuery.devicePixelRatioOf(
                          context,
                        ),
                      ),
                    ),
                  ),
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: LiveInkPainter(c, page: rect, pageScale: scale),
                    ),
                  ),
                  Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (e) => _down(e, c, rect, scale),
                    onPointerMove: (e) => _move(e, c, rect, scale),
                    onPointerUp: (e) => _up(e, c, rect, scale),
                    onPointerCancel: (e) =>
                        _up(e, c, rect, scale, cancel: true),
                  ),
                  if (editingHere)
                    Positioned(
                      left: (editing.position.dx - rect.left) * scale,
                      top: (editing.position.dy - rect.top) * scale,
                      width: editing.width * scale,
                      child: _NoteTextField(
                        key: ValueKey(editing.id),
                        controller: c,
                        item: editing,
                        scale: scale,
                      ),
                    ),
                  Positioned(
                    right: 8,
                    bottom: 6,
                    child: IgnorePointer(
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: AppType.sizeMeta,
                          color: AppColors.textFaint,
                        ),
                      ),
                    ),
                  ),
                  if (c.squeezeEraser)
                    Positioned(
                      top: 6,
                      right: 8,
                      child: Icon(
                        Icons.auto_fix_normal,
                        size: 16,
                        color: AppColors.textMuted,
                        semanticLabel: 'Eraser (squeeze)',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The notebook toolbar, one row in three parts:
  ///
  ///  1. the tools (Pen, Highlighter, Eraser, Text, Select);
  ///  2. the options of the chosen tool only (colour, thickness, eraser
  ///     mode, selection actions) — they change with the tool, in place,
  ///     so the row never shows options that do nothing right now;
  ///  3. what is always needed: Undo/Redo, page zoom, paper, export, PDF.
  ///
  /// Wide windows keep part 3 pinned on the right while parts 1–2 scroll;
  /// narrow windows (iPhone, a small floating window) scroll the whole row.
  Widget _toolbar(CanvasController c) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final tools = [
            ..._toolButtons(c),
            const _ToolbarGap(),
            ..._toolOptions(c),
          ];
          final essentials = _essentials(c);
          if (box.maxWidth < 760) {
            return SingleChildScrollView(
              key: const ValueKey('note-toolbar'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
              child: Row(
                children: [...tools, const _ToolbarGap(), ...essentials],
              ),
            );
          }
          return Padding(
            key: const ValueKey('note-toolbar'),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: tools),
                  ),
                ),
                const _ToolbarGap(),
                ...essentials,
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _toolButtons(CanvasController c) {
    Widget tool(CanvasTool t, IconData icon, String tip) => GhostIconButton(
      key: ValueKey('note-tool-${t.name}'),
      icon: icon,
      tooltip: tip,
      active: c.tool == t,
      onTap: () => setState(() => c.tool = t),
    );
    return [
      tool(CanvasTool.pen, Icons.edit_outlined, 'Pen'),
      tool(CanvasTool.highlighter, Icons.border_color_outlined, 'Highlighter'),
      tool(
        CanvasTool.eraser,
        Icons.auto_fix_normal,
        'Eraser (or squeeze Apple Pencil Pro)',
      ),
      tool(CanvasTool.text, Icons.title, 'Text box (headings: #, lists: -)'),
      tool(CanvasTool.select, Icons.near_me_outlined, 'Select and move'),
    ];
  }

  /// Colours picked in this note, newest first (this page only, so no
  /// new setting or global state). Never replaces the full library.
  final List<Color> _recentInk = [];

  void _pickPenColor(CanvasController c, Color color) {
    c.setPen(color: color);
    _recentInk
      ..remove(color)
      ..insert(0, color);
    if (_recentInk.length > 5) _recentInk.removeLast();
  }

  /// The options of the chosen tool (see [_toolbar]).
  List<Widget> _toolOptions(CanvasController c) {
    switch (c.tool) {
      case CanvasTool.pen:
        return [
          InkColorButton(
            key: const ValueKey('note-pen-color'),
            color: c.penColor,
            tooltip: 'Pen colour',
            onSelected: (color) => _pickPenColor(c, color),
          ),
          for (final color in _recentInk.where((r) => r != c.penColor).take(4))
            InkSwatchDot(
              color: color,
              label: 'Recent: ${inkSwatchName(color)}',
              onTap: () => _pickPenColor(c, color),
            ),
          InkWidthButton(
            key: const ValueKey('note-pen-width'),
            tooltip: 'Pen thickness',
            width: c.penWidth,
            widths: penSizes,
            color: c.penColor,
            onSelected: (w) => c.setPen(width: w),
          ),
        ];
      case CanvasTool.highlighter:
        return [
          InkColorButton(
            key: const ValueKey('note-highlighter-color'),
            color: c.highlighterColor,
            tooltip: 'Highlighter colour',
            onSelected: (color) => c.setHighlighter(color: color),
          ),
          InkWidthButton(
            key: const ValueKey('note-highlighter-width'),
            tooltip: 'Highlighter thickness',
            width: c.highlighterWidth,
            widths: highlighterWidths,
            color: c.highlighterColor,
            onSelected: (w) => c.setHighlighter(width: w),
          ),
        ];
      case CanvasTool.eraser:
        return [
          GhostIconButton(
            key: const ValueKey('eraser-mode-stroke'),
            icon: Icons.gesture,
            tooltip: 'Erase whole strokes',
            active: c.eraserMode == EraserMode.stroke,
            onTap: () => s.setEraser(c, mode: EraserMode.stroke),
          ),
          GhostIconButton(
            key: const ValueKey('eraser-mode-partial'),
            icon: Icons.content_cut,
            tooltip: 'Erase only the part under the eraser',
            active: c.eraserMode == EraserMode.partial,
            onTap: () => s.setEraser(c, mode: EraserMode.partial),
          ),
          InkWidthButton(
            key: const ValueKey('note-eraser-size'),
            tooltip: 'Eraser size',
            width: c.eraserSize,
            widths: EraserPanel.sizes,
            ring: true,
            onSelected: (size) => s.setEraser(c, size: size),
          ),
        ];
      case CanvasTool.text:
        return [
          _ToolHint(
            touchFirst
                ? 'Tap a page to type  ·  # heading  ·  - list'
                : 'Click a page to type  ·  # heading  ·  - list',
          ),
        ];
      case CanvasTool.select || CanvasTool.lasso:
        final selected = c.selectedItems;
        if (selected.isEmpty) {
          return [const _ToolHint('Tap ink or text to select it')];
        }
        final texts = selected.whereType<TextItem>().toList();
        return [
          _ToolHint('${selected.length} selected'),
          InkColorButton(
            key: const ValueKey('note-selection-color'),
            color: texts.isEmpty
                ? (selected.whereType<StrokeItem>().firstOrNull?.color ??
                      c.penColor)
                : (texts.first.textColor ?? AppColors.text),
            tooltip: 'Recolour the selection',
            onSelected: c.recolorSelection,
          ),
          if (texts.isNotEmpty) ...[
            GhostIconButton(
              icon: Icons.format_bold,
              tooltip: 'Bold',
              active: texts.first.bold,
              onTap: () => c.updateSelectedTexts(
                (t) => t.copyWith(bold: !texts.first.bold),
              ),
            ),
            GhostIconButton(
              icon: Icons.format_italic,
              tooltip: 'Italic',
              active: texts.first.italic,
              onTap: () => c.updateSelectedTexts(
                (t) => t.copyWith(italic: !texts.first.italic),
              ),
            ),
          ],
          GhostIconButton(
            key: const ValueKey('note-selection-duplicate'),
            icon: Icons.copy_outlined,
            tooltip: 'Duplicate',
            onTap: c.duplicateSelection,
          ),
          GhostIconButton(
            key: const ValueKey('note-selection-delete'),
            icon: Icons.delete_outline,
            tooltip: withShortcut('Delete', 'Del'),
            onTap: c.deleteSelection,
          ),
        ];
      default:
        return const [];
    }
  }

  /// Always visible: history, zoom, paper and export.
  List<Widget> _essentials(CanvasController c) => [
    GhostIconButton(
      icon: Icons.undo,
      tooltip: withShortcut('Undo', 'Ctrl+Z'),
      onTap: c.canUndo ? c.undo : null,
    ),
    GhostIconButton(
      icon: Icons.redo,
      tooltip: withShortcut('Redo', 'Ctrl+Y'),
      onTap: c.canRedo ? c.redo : null,
    ),
    const _ToolbarGap(),
    ZoomStepper(
      key: const ValueKey('note-zoom'),
      label: '${(_z * 100).round()}%',
      valueKey: const ValueKey('note-zoom-value'),
      outTooltip: 'Smaller pages',
      inTooltip: 'Larger pages',
      // The percentage itself resets: one group, no separate fit button.
      resetTooltip: 'Fit page width',
      onOut: _z > _minZoom + 0.0001 ? () => _setZoom(_z / 1.25) : null,
      onIn: _z < 3.0 - 0.0001 ? () => _setZoom(_z * 1.25) : null,
      onReset: () => _setZoom(1),
    ),
    const _ToolbarGap(),
    GhostIconButton(
      key: const ValueKey('note-paper'),
      icon: Icons.grid_4x4,
      tooltip: 'Paper (template, grid, colors)',
      onTap: () => showPaperDialog(context, s, widget.noteId),
    ),
    GhostIconButton(
      icon: Icons.picture_as_pdf_outlined,
      tooltip: 'Add PDF pages to this note',
      onTap: _addPdf,
    ),
    PopupMenuButton<String>(
      key: const ValueKey('note-export'),
      tooltip: 'Export (Markdown, pictures, web page)',
      icon: Icon(Icons.save_alt, size: 18, color: AppColors.textMuted),
      onOpened: c.cancelPendingLineStraightening,
      onSelected: (what) async {
        if (what == 'pdf') {
          await _exportPdf();
          return;
        }
        final note = s.workspace.notes[widget.noteId];
        if (note == null) return;
        await c.flush();
        if (!mounted) return;
        // The Export window: preview, background and size, file name,
        // remembered folder, success / failure with Show / Open.
        await showNoteExportDialog(
          context,
          s,
          note,
          switch (what) {
            'png' => ExportFormat.pages,
            'html' => ExportFormat.web,
            _ => ExportFormat.markdown,
          },
        );
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'md', child: Text('Export text (Markdown)')),
        const PopupMenuItem(
          value: 'png',
          child: Text('Export pages as pictures'),
        ),
        const PopupMenuItem(
          value: 'html',
          child: Text('Export as read-only web page'),
        ),
        // iPhone/iPad: the PDF pages with the ink written on them.
        if (s.ios != null && c.pageBackgrounds.isNotEmpty)
          const PopupMenuItem(
            value: 'pdf',
            child: Text('Export the PDF with your notes'),
          ),
      ],
    ),
  ];
}

/// Highlighter thicknesses offered in Notes (the same as the Mindmap's).
const highlighterWidths = [12.0, 18.0, 26.0, 36.0];

/// The library name of an ink colour ("Steel Blue"), or "Custom".
String inkSwatchName(Color color) {
  for (final swatch in InkColors.library) {
    if (swatch.color == color) return swatch.name;
  }
  return 'Custom';
}

/// A little space between toolbar groups (instead of dividers).
class _ToolbarGap extends StatelessWidget {
  const _ToolbarGap();

  @override
  Widget build(BuildContext context) => const SizedBox(width: AppSpace.md);
}

/// A quiet line of guidance in the toolbar's options area.
class _ToolHint extends StatelessWidget {
  const _ToolHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
    child: Text(
      text,
      style: TextStyle(fontSize: AppType.sizeLabel, color: AppColors.textFaint),
    ),
  );
}

/// One compact zoom group: − [value] +. Tapping the value resets (fit, or
/// 100 %). Used for the notebook page zoom and the note's text size.
class ZoomStepper extends StatelessWidget {
  const ZoomStepper({
    super.key,
    required this.label,
    required this.outTooltip,
    required this.inTooltip,
    required this.resetTooltip,
    required this.onOut,
    required this.onIn,
    required this.onReset,
    this.valueKey,
    this.outKey,
    this.inKey,
    this.outIcon = Icons.remove,
    this.inIcon = Icons.add,
  });

  final String label;
  final String outTooltip, inTooltip, resetTooltip;
  final VoidCallback? onOut, onIn, onReset;
  final Key? valueKey, outKey, inKey;
  final IconData outIcon, inIcon;

  @override
  Widget build(BuildContext context) {
    Widget step(Key? key, IconData icon, String tip, VoidCallback? onTap) =>
        Tooltip(
          message: tip,
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            onTap: onTap,
            child: SizedBox(
              width: 28,
              height: 28,
              child: Icon(
                icon,
                size: 16,
                color: onTap == null
                    ? AppColors.textFaint
                    : AppColors.textMuted,
              ),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          step(outKey, outIcon, outTooltip, onOut),
          Tooltip(
            message: resetTooltip,
            child: Semantics(
              button: true,
              label: '$label. $resetTooltip',
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadii.xs),
                onTap: onReset,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 44),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.xs,
                      vertical: 6,
                    ),
                    child: Text(
                      label,
                      key: valueKey,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: AppType.sizeLabel,
                        color: AppColors.text,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          step(inKey, inIcon, inTooltip, onIn),
        ],
      ),
    );
  }
}

/// A single swatch (a recent colour, or one cell of the library grid).
class InkSwatchDot extends StatelessWidget {
  const InkSwatchDot({
    super.key,
    required this.color,
    required this.label,
    required this.onTap,
    this.active = false,
    this.size = 18,
  });

  final Color color;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Semantics(
      button: true,
      selected: active,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? AppColors.text : AppColors.border,
                width: active ? 2 : 1,
                strokeAlign: BorderSide.strokeAlignOutside,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The current ink colour; opens the complete canonical library
/// ([InkColors.library], all 19 colours in their fixed order).
class InkColorButton extends StatelessWidget {
  const InkColorButton({
    super.key,
    required this.color,
    required this.tooltip,
    required this.onSelected,
  });

  final Color color;
  final String tooltip;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<Color>(
    tooltip: '$tooltip: ${inkSwatchName(color)}',
    padding: EdgeInsets.zero,
    position: PopupMenuPosition.under,
    onSelected: onSelected,
    itemBuilder: (_) => [_InkLibraryEntry(current: color)],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.text,
                width: 2,
                strokeAlign: BorderSide.strokeAlignOutside,
              ),
            ),
          ),
          Icon(Icons.expand_more, size: 14, color: AppColors.textFaint),
        ],
      ),
    ),
  );
}

/// The library grid inside [InkColorButton]'s menu.
class _InkLibraryEntry extends PopupMenuEntry<Color> {
  const _InkLibraryEntry({required this.current});

  final Color current;

  @override
  double get height => 160;

  @override
  bool represents(Color? value) => value == current;

  @override
  State<_InkLibraryEntry> createState() => _InkLibraryEntryState();
}

class _InkLibraryEntryState extends State<_InkLibraryEntry> {
  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('ink-library'),
    padding: const EdgeInsets.all(AppSpace.sm),
    child: SizedBox(
      width: 5 * 28.0,
      child: Wrap(
        children: [
          for (final swatch in InkColors.library)
            InkSwatchDot(
              key: ValueKey('ink-swatch-${swatch.id}'),
              color: swatch.color,
              label: swatch.name,
              active: swatch.color == widget.current,
              onTap: () => Navigator.of(context).pop(swatch.color),
            ),
        ],
      ),
    ),
  );
}

/// The current thickness (a dot of that size); opens the list of sizes.
class InkWidthButton extends StatelessWidget {
  const InkWidthButton({
    super.key,
    required this.tooltip,
    required this.width,
    required this.widths,
    required this.onSelected,
    this.color,
    this.ring = false,
  });

  final String tooltip;
  final double width;
  final List<double> widths;
  final ValueChanged<double> onSelected;
  final Color? color;

  /// Draw rings (the eraser's outline) instead of filled dots.
  final bool ring;

  Widget _dot(double w) {
    final d = ring ? (w / 3).clamp(4.0, 18.0) : (w + 2).clamp(3.0, 18.0);
    return SizedBox(
      width: 20,
      height: 20,
      child: Center(
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ring ? null : (color ?? AppColors.text),
            border: ring
                ? Border.all(color: AppColors.text, width: 1.5)
                : Border.all(color: AppColors.border),
          ),
        ),
      ),
    );
  }

  static String _number(double w) =>
      w == w.roundToDouble() ? w.round().toString() : w.toString();

  @override
  Widget build(BuildContext context) => PopupMenuButton<double>(
    tooltip: '$tooltip: ${_number(width)}',
    position: PopupMenuPosition.under,
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final w in widths)
        CheckedPopupMenuItem<double>(
          key: ValueKey('ink-width-$w'),
          value: w,
          checked: w == width,
          height: 36,
          child: Row(
            children: [
              _dot(w),
              const SizedBox(width: AppSpace.sm),
              Text(_number(w)),
            ],
          ),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dot(width),
          Icon(Icons.expand_more, size: 14, color: AppColors.textFaint),
        ],
      ),
    ),
  );
}

/// The ink of one notebook page as PDF strokes: points in PDF points from
/// the page's top-left, each with its drawn width.
List<Map<String, Object>> annotationStrokes(
  Iterable<StrokeItem> strokes,
  Rect page,
  PageBackground background,
) {
  final k = background.width / page.width;
  return [
    for (final s in strokes)
      if (s.bounds.overlaps(page))
        {
          'color': s.color.toARGB32(),
          'points': [
            for (final p in s.points)
              [
                (p.x - page.left) * k,
                (p.y - page.top) * k,
                s.strokeWidth *
                    k *
                    (s.pressureWidth ? pressureFactor(p.pressure) : 1),
              ],
          ],
        },
  ];
}

/// Creates a note that is a PDF: every page of the PDF becomes a notebook
/// page to write on. Returns the new note's id (null if nothing chosen).
Future<String?> importPdfAsNote(AppState state, {String? folderId}) async {
  final assets = await state.capture.pickDocuments();
  if (assets.isEmpty) return null;
  final asset = assets.first;
  final note = state.workspace.createNote(
    title: asset.label.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), ''),
    folderId: folderId,
  );
  state.workspace.attachToNote(note.id, asset.id);
  final file = state.workspace.documentFile(asset);
  final sizes = file == null ? null : await state.ios?.pdfPageSizes(file.path);
  if (sizes != null && sizes.isNotEmpty) {
    final doc = CanvasDocument(
      id: notebookIdFor(note.id),
      title: note.title,
      items: const [],
      updatedAt: DateTime.now(),
      kind: 'notebook',
      metaRev: state.workspace.clock.now(),
      pageBackgrounds: [
        for (var k = 0; k < sizes.length; k++)
          PageBackground(
            pageIndex: k,
            assetId: asset.id,
            pdfPage: k,
            width: sizes[k].width,
            height: sizes[k].height,
          ),
      ],
    );
    await state.canvases.save(doc);
  } else {
    state.showToast(
      'PDF saved as a note. Its pages can be written on on iPhone/iPad.',
    );
  }
  await state.workspace.flush();
  return note.id;
}

/// A PDF page under a notebook page, rendered when it scrolls into view.
class PdfPageView extends StatefulWidget {
  const PdfPageView({
    super.key,
    required this.state,
    required this.background,
    required this.scale,
  });

  final AppState state;
  final PageBackground background;
  final double scale;

  @override
  State<PdfPageView> createState() => _PdfPageViewState();
}

class _PdfPageViewState extends State<PdfPageView> {
  ui.Image? _image;
  String? _key;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(PdfPageView old) {
    super.didUpdateWidget(old);
    _load();
  }

  void _load() {
    final ios = widget.state.ios;
    final asset = widget.state.workspace.assets[widget.background.assetId];
    final file = asset == null
        ? null
        : widget.state.workspace.documentFile(asset);
    if (ios == null || file == null) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    // Widths in steps of 256 px, so small zoom changes reuse the image.
    final want = (NotebookLayout.pageWidth * widget.scale * ratio / 256)
        .ceil()
        .clamp(1, 16);
    final key = '${file.path}#${widget.background.pdfPage}@$want';
    if (key == _key) return;
    _key = key;
    unawaited(
      PdfPageCache.instance
          .get(ios, file.path, widget.background.pdfPage, want * 256)
          .then((image) {
            if (mounted && _key == key) setState(() => _image = image);
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image != null) {
      return RawImage(image: image, fit: BoxFit.fill);
    }
    // A PDF page is paper: white with dark text in either theme.
    return ColoredBox(
      color: BackgroundPalette.lightPaper,
      child: Center(
        child: Text(
          widget.state.ios == null
              ? 'PDF page ${widget.background.pdfPage + 1} (shown on '
                    'iPhone/iPad)'
              : '',
          style: const TextStyle(
            color: Colors.black54,
            fontSize: AppType.sizeBodySmall,
          ),
        ),
      ),
    );
  }
}

/// Rendered PDF pages, a few at a time: long PDFs never keep every page in
/// memory (least recently used pages are dropped).
class PdfPageCache {
  PdfPageCache._();
  static final instance = PdfPageCache._();

  static const capacity = 8;
  final _images = <String, Future<ui.Image?>>{};

  Future<ui.Image?> get(IosBridge ios, String path, int page, int width) {
    final key = '$path#$page@$width';
    final cached = _images.remove(key);
    if (cached != null) {
      _images[key] = cached; // most recently used last
      return cached;
    }
    final future = _render(ios, path, page, width);
    _images[key] = future;
    while (_images.length > capacity) {
      unawaited(
        _images.remove(_images.keys.first)!.then((image) => image?.dispose()),
      );
    }
    return future;
  }

  static Future<ui.Image?> _render(
    IosBridge ios,
    String path,
    int page,
    int width,
  ) async {
    try {
      final bytes = await ios.renderPdfPage(path, page, width);
      if (bytes == null) return null;
      final codec = await ui.instantiateImageCodec(bytes);
      return (await codec.getNextFrame()).image;
    } catch (e) {
      AppLog.warn('PDF page could not be shown: $e');
      return null;
    }
  }
}

/// Editing a text box on a notebook page (headings with "#", lists with
/// "-", as on Canvas). Leaving the field ends editing.
class _NoteTextField extends StatefulWidget {
  const _NoteTextField({
    super.key,
    required this.controller,
    required this.item,
    required this.scale,
  });

  final CanvasController controller;
  final TextItem item;
  final double scale;

  @override
  State<_NoteTextField> createState() => _NoteTextFieldState();
}

class _NoteTextFieldState extends State<_NoteTextField> {
  late final _text = TextEditingController(text: widget.item.text);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.controller.endEditing();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(kTextPadding * widget.scale),
    child: TextField(
      controller: _text,
      focusNode: _focus,
      maxLines: null,
      style: canvasTextStyle(
        widget.item.fontSize * widget.scale,
        bold: widget.item.bold,
        italic: widget.item.italic,
        color: widget.item.textColor,
      ),
      decoration: const InputDecoration.collapsed(hintText: 'Type…'),
      onChanged: widget.controller.updateEditingText,
    ),
  );
}
