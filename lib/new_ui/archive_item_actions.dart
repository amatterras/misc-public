// What tapping an Archive item does, and how its preview is drawn.
//
// - Tap: a link opens its exact saved address; a photo opens in a popup
//   (save, share); a PDF opens in a popup that scrolls through its pages
//   (save, share, make a note, which keeps the Archive item). Anything
//   else opens the item's info dialog.
// - Long press (in the folder view): the info dialog.
// - Previews are "smart cropped": the crop is moved to the busiest part of
//   the picture (edges and colour), not just the centre.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/theme.dart';
import '../data/models/library_models.dart' show Asset, AssetKind;
import '../data/models/object_library_models.dart';
import '../data/storage/attachment_image.dart';
import '../data/storage/attachment_store.dart';
import '../data/workspace.dart';
import '../features/capture/sorting.dart';
import '../platform/pdf_renderer.dart';
import '../platform/platform.dart' as native;

/// The stored file the item is about (its first attachment that exists).
Asset? archiveAssetOf(Workspace ws, LibraryObject o) {
  for (final id in o.attachmentIds) {
    final a = ws.assets[id];
    if (a != null && a.file != null) return a;
  }
  return null;
}

bool _isPdf(Asset a) =>
    a.kind == AssetKind.document &&
    AttachmentStore.extensionOf(a.file ?? '') == 'pdf';

/// What a tap on [o] does. [info] opens the item's info dialog.
enum ArchiveTap { openLink, showImage, showPdf, info }

ArchiveTap archiveTapOf(Workspace ws, LibraryObject o) {
  final asset = archiveAssetOf(ws, o);
  if (asset != null && asset.kind == AssetKind.image) {
    return ArchiveTap.showImage;
  }
  if (asset != null && _isPdf(asset)) return ArchiveTap.showPdf;
  if ((o.sourceUrl ?? '').isNotEmpty) return ArchiveTap.openLink;
  return ArchiveTap.info;
}

/// One tap on an Archive item (see the top of this file).
Future<void> tapArchiveItem(
  BuildContext context,
  AppState s,
  LibraryObject o, {
  required Future<void> Function() info,
}) async {
  final asset = archiveAssetOf(s.workspace, o);
  switch (archiveTapOf(s.workspace, o)) {
    case ArchiveTap.openLink:
      // The saved address exactly as stored: never rebuilt or shortened.
      if (!s.openUrl(o.sourceUrl!)) s.showToast('Could not open the link.');
    case ArchiveTap.showImage:
      await showArchiveImagePopup(context, s, o, asset!);
    case ArchiveTap.showPdf:
      await showArchivePdfPopup(context, s, o, asset!);
    case ArchiveTap.info:
      await info();
  }
}

// ── save / share / note ─────────────────────────────────────────────────

/// The share sheet (iPhone/iPad) for the stored file; from there it can be
/// saved to Photos or Files, AirDropped, mailed.
Future<void> shareArchiveAsset(AppState s, Asset asset) async {
  final name = asset.file;
  final file = name == null ? null : s.workspace.attachments.viewFile(name);
  if (file == null) {
    s.showToast('This file is not on this device yet.');
    return;
  }
  if (s.ios == null) {
    s.showToast('Sharing is not available on this device.');
    return;
  }
  await s.ios!.shareFile(file.path);
}

/// Saves a copy: Windows asks where; iPhone/iPad open the share sheet,
/// which has "Save Image" and "Save to Files".
Future<void> saveArchiveAsset(AppState s, Asset asset) async {
  if (!native.hasSaveDialog) return shareArchiveAsset(s, asset);
  final name = asset.file;
  if (name == null) return;
  final ext = AttachmentStore.extensionOf(name);
  final title = asset.title?.trim() ?? '';
  final path = native.askSavePath(
    suggestedName: title.isNotEmpty ? title : 'archive-item.$ext',
    extension: ext.isEmpty ? 'bin' : ext,
    typeLabel: asset.kind == AssetKind.image ? 'Image' : 'Document',
  );
  if (path == null) return;
  try {
    final bytes = await s.workspace.attachments.readBytes(name);
    await File(path).writeAsBytes(bytes, flush: true);
    s.showToast('Saved.');
  } catch (e) {
    s.showToast('Could not save the file: $e');
  }
}

/// Makes a note from the item; the item stays in the Archive.
Future<void> archiveItemToNote(AppState s, LibraryObject o) async {
  final result = await CaptureSorter(
    s.workspace,
    s.library,
  ).convertToNote(o.id);
  if (result == null) return;
  unawaited(
    result.persisted.catchError(
      (Object e) => s.showToast('Could not save that change: $e'),
    ),
  );
  s.showTransferResult((
    message: result.already
        ? 'This item already has that note (in Notes).'
        : '${result.undo.message} Find it in Notes. It is still in the Archive.',
    undo: result.already ? null : result.undo.undo,
  ));
}

Widget _actionBar(List<Widget> buttons) => Padding(
  padding: const EdgeInsets.fromLTRB(
    AppSpace.md,
    AppSpace.sm,
    AppSpace.md,
    AppSpace.md,
  ),
  child: Wrap(
    alignment: WrapAlignment.center,
    spacing: AppSpace.sm,
    runSpacing: AppSpace.sm,
    children: buttons,
  ),
);

Widget _popupHeader(BuildContext context, String title) => Padding(
  padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.sm, 0),
  child: Row(
    children: [
      Expanded(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.body.copyWith(
            fontWeight: FontWeight.w600,
            color: AppColors.text,
          ),
        ),
      ),
      IconButton(
        key: const ValueKey('archive-popup-close'),
        tooltip: 'Close',
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.pop(context),
      ),
    ],
  ),
);

String _titleOf(LibraryObject o) => o.title.isEmpty ? 'Untitled' : o.title;

/// The photo itself in a popup (pinch to zoom), with Save and Share.
Future<void> showArchiveImagePopup(
  BuildContext context,
  AppState s,
  LibraryObject o,
  Asset asset,
) {
  return showAppDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      key: const ValueKey('archive-image-popup'),
      backgroundColor: AppColors.card,
      insetPadding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _popupHeader(ctx, _titleOf(o)),
          Flexible(
            child: InteractiveViewer(
              maxScale: 6,
              child: Image(
                image: AttachmentImageProvider(
                  s.workspace.attachments,
                  asset.file!,
                ),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Padding(
                  padding: const EdgeInsets.all(AppSpace.xl),
                  child: Text(
                    'This image is not on this device yet. It arrives with '
                    'the next sync.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              ),
            ),
          ),
          _actionBar([
            FilledButton.tonalIcon(
              key: const ValueKey('archive-popup-save'),
              onPressed: () => saveArchiveAsset(s, asset),
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('Save'),
            ),
            if (s.ios != null)
              FilledButton.tonalIcon(
                key: const ValueKey('archive-popup-share'),
                onPressed: () => shareArchiveAsset(s, asset),
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('Share'),
              ),
          ]),
        ],
      ),
    ),
  );
}

/// The PDF in a popup: every page, scrolled vertically, pinch to zoom; with
/// Save, Share and "Make a note" (the item stays in the Archive).
Future<void> showArchivePdfPopup(
  BuildContext context,
  AppState s,
  LibraryObject o,
  Asset asset,
) async {
  final file = s.workspace.documentFile(asset);
  final renderer = PdfRenderer.instance;
  final sizes = file == null || renderer == null
      ? null
      : await renderer.pageSizes(file.path);
  if (!context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      return Dialog(
        key: const ValueKey('archive-pdf-popup'),
        backgroundColor: AppColors.card,
        insetPadding: const EdgeInsets.all(AppSpace.lg),
        child: SizedBox(
          width: math.min(size.width, 820),
          height: size.height * 0.86,
          child: Column(
            children: [
              _popupHeader(
                ctx,
                sizes == null || sizes.isEmpty
                    ? _titleOf(o)
                    : '${_titleOf(o)} · ${sizes.length} '
                          '${sizes.length == 1 ? 'page' : 'pages'}',
              ),
              Expanded(
                child: file == null
                    ? _pdfProblem(
                        'This PDF is not on this device yet. It arrives with '
                        'the next sync.',
                      )
                    : sizes == null || sizes.isEmpty
                    ? _pdfProblem(
                        'This device cannot show a preview of this PDF. Use '
                        'Share or Save to open it in another app.',
                      )
                    : InteractiveViewer(
                        maxScale: 5,
                        child: ListView.builder(
                          key: const ValueKey('archive-pdf-pages'),
                          padding: const EdgeInsets.all(AppSpace.md),
                          itemCount: sizes.length,
                          itemBuilder: (_, i) => _PdfPage(
                            path: file.path,
                            index: i,
                            size: sizes[i],
                          ),
                        ),
                      ),
              ),
              _actionBar([
                FilledButton.tonalIcon(
                  key: const ValueKey('archive-popup-save'),
                  onPressed: () => saveArchiveAsset(s, asset),
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Save'),
                ),
                if (s.ios != null)
                  FilledButton.tonalIcon(
                    key: const ValueKey('archive-popup-share'),
                    onPressed: () => shareArchiveAsset(s, asset),
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('Share'),
                  ),
                FilledButton.tonalIcon(
                  key: const ValueKey('archive-popup-note'),
                  onPressed: () async {
                    await archiveItemToNote(s, o);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.note_add_outlined, size: 18),
                  label: const Text('Make a note'),
                ),
              ]),
            ],
          ),
        ),
      );
    },
  );
}

Widget _pdfProblem(String text) => Center(
  child: Padding(
    padding: const EdgeInsets.all(AppSpace.xl),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(color: AppColors.textMuted),
    ),
  ),
);

/// One PDF page, rendered when it scrolls into view.
class _PdfPage extends StatefulWidget {
  const _PdfPage({required this.path, required this.index, required this.size});

  final String path;
  final int index;
  final Size size;

  @override
  State<_PdfPage> createState() => _PdfPageState();
}

class _PdfPageState extends State<_PdfPage> {
  Future<Uint8List?>? _bytes;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: LayoutBuilder(
        builder: (context, box) {
          final px = (box.maxWidth * MediaQuery.devicePixelRatioOf(context))
              .round()
              .clamp(300, 2400);
          _bytes ??= PdfRenderer.instance?.renderPage(
            widget.path,
            widget.index,
            px,
          );
          final aspect = widget.size.height <= 0
              ? 1.414
              : widget.size.width / widget.size.height;
          return AspectRatio(
            aspectRatio: aspect,
            child: ColoredBox(
              color: Colors.white,
              child: FutureBuilder<Uint8List?>(
                future: _bytes,
                builder: (_, snap) => snap.data == null
                    ? Center(
                        child: snap.connectionState == ConnectionState.done
                            ? Text('Page ${widget.index + 1}')
                            : const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Image.memory(
                        snap.data!,
                        key: ValueKey('archive-pdf-page-${widget.index}'),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── smart-cropped previews ──────────────────────────────────────────────

/// Where the interesting part of a picture is, as a point from (0,0) top
/// left to (1,1) bottom right. [rgba] is a small decoded copy ([w]×[h]).
///
/// Each pixel's weight is its local contrast (edges, detail) plus its
/// colourfulness; flat sky, walls and paper weigh almost nothing. The
/// result is the weighted centre, pulled slightly to the middle so a lone
/// speck at the border does not decide the crop.
Offset smartFocus(Uint8List rgba, int w, int h) {
  if (w < 3 || h < 3 || rgba.length < w * h * 4) return const Offset(.5, .5);
  double lum(int x, int y) {
    final i = (y * w + x) * 4;
    return 0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2];
  }

  var sum = 0.0, sx = 0.0, sy = 0.0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final gx = lum(x + 1, y) - lum(x - 1, y);
      final gy = lum(x, y + 1) - lum(x, y - 1);
      final i = (y * w + x) * 4;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final sat = (math.max(r, math.max(g, b)) - math.min(r, math.min(g, b)))
          .toDouble();
      final e = math.sqrt(gx * gx + gy * gy) + 0.35 * sat;
      final weight = e * e; // the strongest parts decide
      sum += weight;
      sx += weight * (x + .5);
      sy += weight * (y + .5);
    }
  }
  if (sum <= 0) return const Offset(.5, .5);
  const pull = 0.15; // towards the centre
  final fx = (sx / sum) / w, fy = (sy / sum) / h;
  return Offset(fx + (.5 - fx) * pull, fy + (.5 - fy) * pull);
}

/// The [Alignment] for [BoxFit.cover] that puts [focus] as near the middle
/// of the box as the picture allows. [imageAspect] and [boxAspect] are
/// width / height.
Alignment coverAlignment(Offset focus, double imageAspect, double boxAspect) {
  double axis(double f, double visible) {
    // visible: the share of the picture's length that is shown (0…1].
    if (visible >= 1) return 0;
    final start = (f - visible / 2).clamp(0.0, 1 - visible);
    return start / (1 - visible) * 2 - 1;
  }

  if (imageAspect > boxAspect) {
    return Alignment(axis(focus.dx, boxAspect / imageAspect), 0);
  }
  return Alignment(0, axis(focus.dy, imageAspect / boxAspect));
}

/// Focus and aspect of a stored picture, worked out once per file.
final Map<String, Future<(Offset, double)?>> _focusCache = {};

Future<(Offset, double)?> _focusOf(AttachmentStore store, String name) =>
    _focusCache[name] ??= () async {
      try {
        final bytes = await store.readBytes(name);
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 48);
        final frame = await codec.getNextFrame();
        final img = frame.image;
        final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final result = data == null
            ? null
            : (
                smartFocus(data.buffer.asUint8List(), img.width, img.height),
                img.width / img.height,
              );
        img.dispose();
        codec.dispose();
        return result;
      } catch (_) {
        return null;
      }
    }();

/// A stored picture filling its box, cropped around its busiest part.
class SmartCropImage extends StatelessWidget {
  const SmartCropImage({
    super.key,
    required this.store,
    required this.name,
    this.fallback,
  });

  final AttachmentStore store;
  final String name;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => FutureBuilder<(Offset, double)?>(
        future: _focusOf(store, name),
        builder: (context, snap) {
          final f = snap.data;
          final boxAspect = box.maxHeight > 0 && box.maxHeight.isFinite
              ? box.maxWidth / box.maxHeight
              : 1.0;
          return Image(
            image: AttachmentImageProvider(store, name),
            fit: BoxFit.cover,
            alignment: f == null
                ? Alignment.center
                : coverAlignment(f.$1, f.$2, boxAspect),
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                fallback ?? ColoredBox(color: AppColors.surfaceSecondary),
          );
        },
      ),
    );
  }
}

/// First pages of PDFs, rendered once per file for previews.
final Map<String, Future<Uint8List?>> _pdfThumbCache = {};

/// An item's preview: its picture (smart cropped), the first page of its
/// PDF, or [fallback] when it has neither.
class ArchivePreview extends StatelessWidget {
  const ArchivePreview({
    super.key,
    required this.state,
    required this.object,
    required this.imageFile,
    required this.fallback,
  });

  final AppState state;
  final LibraryObject object;

  /// The stored picture to show (archiveImageFileOf), if any.
  final String? imageFile;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final ws = state.workspace;
    if (imageFile != null) {
      return SmartCropImage(
        store: ws.attachments,
        name: imageFile!,
        fallback: fallback,
      );
    }
    final asset = archiveAssetOf(ws, object);
    final renderer = PdfRenderer.instance;
    if (asset == null || !_isPdf(asset) || renderer == null) return fallback;
    final file = ws.documentFile(asset);
    if (file == null) return fallback;
    final thumb = _pdfThumbCache[asset.file!] ??= renderer
        .renderPage(file.path, 0, 400)
        .catchError((Object _) => null);
    return FutureBuilder<Uint8List?>(
      future: thumb,
      builder: (_, snap) => snap.data == null
          ? fallback
          : ColoredBox(
              color: Colors.white,
              child: Image.memory(
                snap.data!,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter, // the title of a page
                gaplessPlayback: true,
              ),
            ),
    );
  }
}
