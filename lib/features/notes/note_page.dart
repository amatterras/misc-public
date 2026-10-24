// A note as a full page: its details (title, text, tags, links, history)
// followed by notebook pages for handwriting, text boxes and PDF pages.
//
// The pages use the same writing engine as Canvas (CanvasController,
// CanvasPainter, LiveInkPainter, stroke_geometry): one stroke model, one
// renderer, one way of saving and syncing. A note's handwriting is a
// canvas document with the fixed id `nb-<noteId>` and kind "notebook".
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/page_windows.dart';
import '../../app/shell.dart' show WorkspaceBuilder;
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/paper.dart';
import '../../data/storage/app_log.dart';
import '../../platform/input_hints.dart';
import '../../platform/ios_bridge.dart';
import '../../widgets/common.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_painter.dart';
import '../ink/stroke_geometry.dart';
import 'notebook_layout.dart';
import '../export/exports.dart';
import 'paper_dialog.dart';
import 'paper_painter.dart';
import 'notes_page.dart' show NoteEditor;
import '../sharing/share_dialog.dart';
import '../templates/templates.dart';

/// Opens note [noteId] as its own page (with a normal Back button).
Future<void> openNotePage(BuildContext context, AppState state, String id) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NotePage(state: state, noteId: id),
      ),
    );

/// Whether a notebook opens with the pen (iPad) or the text tool (Windows,
/// iPhone: tap to type, choose Draw to draw).
bool notebookStartsWithPen(Size screen) =>
    touchFirst && screen.shortestSide >= 600;

/// Pen colours offered on notebook pages (dark ones for PDF pages).
const notebookInk = InkColors.all;

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
  bool _fingerDraws = false;
  final _scroll = ScrollController();
  StreamSubscription<String>? _squeeze;
  AppLifecycleListener? _lifecycle;

  // The pointer drawing right now, and whether a Pencil touches (palm
  // rejection: fingers are ignored meanwhile).
  int? _pointer;
  bool _stylusDown = false;

  AppState get s => widget.state;

  String get _zoomSetting => 'notebookZoom.${widget.noteId}';

  @override
  void initState() {
    super.initState();
    final savedZoom = s.settings.get<num>(_zoomSetting)?.toDouble();
    _zoom = savedZoom != null && savedZoom.isFinite
        ? savedZoom.clamp(0.4, 3.0)
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
        unawaited(_c?.flush());
      },
    );
  }

  void _setZoom(double value) {
    final zoom = value.clamp(0.4, 3.0);
    if (_zoom == zoom) return;
    setState(() => _zoom = zoom);
    unawaited(s.settings.set(_zoomSetting, zoom));
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
    s.openNotebooks.add(c); // sync merges remote changes into this document
    // Apple Pencil double-tap: Undo in this handwriting while it is shown.
    _unregisterTap = s.pencilDoubleTap.register(
      c,
      active: () => mounted && (ModalRoute.of(context)?.isCurrent ?? true),
    );
    setState(() => _c = c);
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
    _squeeze?.cancel();
    _unregisterTap?.call();
    _lifecycle?.dispose();
    _scroll.dispose();
    final c = _c;
    if (c != null) {
      unawaited(_close().whenComplete(c.dispose));
    }
    super.dispose();
  }

  // ---------------------------------------------------------- pointers --

  bool _accepts(PointerEvent e, CanvasController c) => switch (e.kind) {
    PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => true,
    PointerDeviceKind.mouse => e.buttons & kPrimaryButton != 0,
    PointerDeviceKind.touch =>
      !_stylusDown && (_fingerDraws || c.tool == CanvasTool.text),
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
    if (_pointer != null || !_accepts(e, c)) return;
    if (e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus) {
      _stylusDown = true;
    }
    _pointer = e.pointer;
    c.pointerDown(
      _screen(e.localPosition, page, sc),
      kind: e.kind,
      pressure: _pressure(e),
      timeStamp: e.timeStamp,
    );
  }

  void _move(PointerMoveEvent e, CanvasController c, Rect page, double sc) {
    if (e.pointer != _pointer) return;
    c.pointerMove(
      _screen(e.localPosition, page, sc),
      pressure: _pressure(e),
      timeStamp: e.timeStamp,
    );
  }

  void _up(PointerEvent e, CanvasController c, {bool cancel = false}) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _stylusDown = false;
    cancel ? c.pointerCancel() : c.pointerUp();
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
      child: Scaffold(
        appBar: AppBar(
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
        final scale = (fit * _zoom).clamp(0.2, 4.0);
        c?.setView(Offset.zero, scale);
        final width = NotebookLayout.pageWidth * scale + 80;
        Widget list = ScrollConfiguration(
          // Fingers scroll and the Pencil (or mouse) writes; with "draw
          // with finger" on, only the scrollbar and trackpad scroll.
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: _fingerDraws
                ? {PointerDeviceKind.trackpad}
                : {PointerDeviceKind.touch, PointerDeviceKind.trackpad},
          ),
          child: Scrollbar(
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
          ),
        );
        if (width > box.maxWidth) {
          list = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: width, height: box.maxHeight, child: list),
          );
        }
        return list;
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
    return Padding(
      key: ValueKey('notebook-page-$index'),
      padding: EdgeInsets.only(
        top: index == 0 ? Space.xl : 0,
        bottom: NotebookLayout.gap * scale,
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: rect.width * scale,
          height: rect.height * scale,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: PaperPainter(
                    s.workspace.notes[widget.noteId]?.paperOrDefault ??
                        const NotePaper(),
                    scale: scale,
                  ),
                ),
                if (background != null)
                  PdfPageView(state: s, background: background, scale: scale),
                RepaintBoundary(
                  child: CustomPaint(
                    painter: CanvasPainter(c, page: rect, pageScale: scale),
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
                  onPointerUp: (e) => _up(e, c),
                  onPointerCancel: (e) => _up(e, c, cancel: true),
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
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ),
                ),
                if (c.squeezeEraser)
                  const Positioned(
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
    );
  }

  Widget _toolbar(CanvasController c) {
    Widget tool(CanvasTool t, IconData icon, String tip) => GhostIconButton(
      icon: icon,
      tooltip: tip,
      active: c.tool == t,
      onTap: () => setState(() => c.tool = t),
    );
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Space.md),
        child: Row(
          children: [
            tool(CanvasTool.pen, Icons.edit_outlined, 'Pen'),
            tool(
              CanvasTool.highlighter,
              Icons.border_color_outlined,
              'Highlighter',
            ),
            tool(
              CanvasTool.eraser,
              Icons.auto_fix_normal,
              'Eraser (or squeeze Apple Pencil Pro)',
            ),
            tool(
              CanvasTool.text,
              Icons.title,
              'Text box (headings: #, lists: -)',
            ),
            tool(CanvasTool.select, Icons.near_me_outlined, 'Select and move'),
            const SizedBox(width: Space.sm),
            for (final color in notebookInk)
              GestureDetector(
                onTap: () => setState(() => c.setPen(color: color)),
                child: Container(
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c.penColor == color
                          ? AppColors.accent
                          : AppColors.border,
                      width: c.penColor == color ? 2 : 1,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: Space.sm),
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
            const SizedBox(width: Space.sm),
            GhostIconButton(
              icon: Icons.zoom_out,
              tooltip: 'Smaller pages',
              onTap: () => _setZoom(_zoom / 1.25),
            ),
            GhostIconButton(
              icon: Icons.fit_screen_outlined,
              tooltip: 'Fit page width',
              onTap: () => _setZoom(1),
            ),
            Tooltip(
              message: 'Page zoom ${(_zoom * 100).round()}% relative to fit',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                child: Text(
                  '${(_zoom * 100).round()}%',
                  key: const ValueKey('note-zoom-value'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                    fontFeatures: [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            GhostIconButton(
              icon: Icons.zoom_in,
              tooltip: 'Larger pages',
              onTap: () => _setZoom(_zoom * 1.25),
            ),
            if (touchFirst)
              GhostIconButton(
                icon: Icons.touch_app_outlined,
                tooltip: _fingerDraws
                    ? 'Finger draws (tap to scroll with finger)'
                    : 'Finger scrolls (tap to draw with finger)',
                active: _fingerDraws,
                onTap: () {
                  setState(() => _fingerDraws = !_fingerDraws);
                  unawaited(
                    s.settings.set('notebookFingerDraws', _fingerDraws),
                  );
                },
              ),
            const SizedBox(width: Space.sm),
            PopupMenuButton<String>(
              key: const ValueKey('note-export'),
              tooltip: 'Export (Markdown, pictures, web page)',
              icon: const Icon(Icons.ios_share, size: 18),
              onSelected: (what) async {
                final note = s.workspace.notes[widget.noteId];
                if (note == null) return;
                await c.flush();
                await exportNoteFromMenu(s, note, what);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'md',
                  child: Text('Export text (Markdown)'),
                ),
                PopupMenuItem(
                  value: 'png',
                  child: Text('Export pages as pictures'),
                ),
                PopupMenuItem(
                  value: 'html',
                  child: Text('Export as read-only web page'),
                ),
              ],
            ),
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
            if (s.ios != null && c.pageBackgrounds.isNotEmpty)
              GhostIconButton(
                icon: Icons.ios_share,
                tooltip: 'Export the PDF with your notes',
                onTap: _exportPdf,
              ),
          ],
        ),
      ),
    );
  }
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
    return ColoredBox(
      color: AppColors.text,
      child: Center(
        child: Text(
          widget.state.ios == null
              ? 'PDF page ${widget.background.pdfPage + 1} (shown on '
                    'iPhone/iPad)'
              : '',
          style: const TextStyle(color: Colors.black54, fontSize: 13),
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
