// The PDF and its notes side by side (a floating window you can move and
// resize; the divider between the two can be dragged). Left: the PDF page
// (drawn here where the device can render PDFs, otherwise a card that opens
// it in the device's viewer at the right page number). Right: the notes
// that point at pages of this PDF; tapping one makes the PDF follow.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/floating_windows.dart';
import '../../app/theme.dart';
import '../../data/models/library_models.dart';
import '../smartlinks/smart_links.dart';
import '../reading/reading_progress.dart' show noteReadPage;
import 'pdf_anchors.dart';

/// Opens the PDF-and-notes window for PDF [assetId].
void openPdfNotes(AppState s, String assetId) {
  final asset = s.workspace.assets[assetId];
  if (asset == null || asset.kind != AssetKind.document) {
    s.showToast('That PDF is not in the Archive.');
    return;
  }
  s.pdfFocus.value ??= (assetId: assetId, page: 1);
  if (s.pdfFocus.value!.assetId != assetId) {
    s.pdfFocus.value = (assetId: assetId, page: 1);
  }
  s.floating.show(
    FloatingWindowSpec(
      id: 'pdf-notes-$assetId',
      title: asset.label,
      liveTitle: () => s.workspace.assets[assetId]?.label ?? 'PDF',
      initialRect: const Rect.fromLTWH(60, 60, 760, 460),
      minSize: const Size(300, 220),
      builder: (_) => PdfNotesSplit(state: s, assetId: assetId),
    ),
  );
}

class PdfNotesSplit extends StatefulWidget {
  const PdfNotesSplit({super.key, required this.state, required this.assetId});

  final AppState state;
  final String assetId;

  @override
  State<PdfNotesSplit> createState() => _PdfNotesSplitState();
}

class _PdfNotesSplitState extends State<PdfNotesSplit> {
  static const _key = 'pdfSplitRatio';
  late double _ratio = _savedRatio;
  int _page = 1;
  final _pageField = TextEditingController(text: '1');

  AppState get s => widget.state;

  double get _savedRatio {
    final v = s.settings.get<num>(_key)?.toDouble() ?? 0.5;
    return v.isFinite ? v.clamp(0.25, 0.75) : 0.5;
  }

  @override
  void initState() {
    super.initState();
    final focus = s.pdfFocus.value;
    if (focus != null && focus.assetId == widget.assetId) _page = focus.page;
    _pageField.text = '$_page';
    s.pdfFocus.addListener(_onFocus);
  }

  @override
  void dispose() {
    s.pdfFocus.removeListener(_onFocus);
    _pageField.dispose();
    super.dispose();
  }

  void _onFocus() {
    final f = s.pdfFocus.value;
    if (f != null && f.assetId == widget.assetId && f.page != _page) {
      setState(() {
        _page = f.page;
        _pageField.text = '$_page';
      });
    }
  }

  void _goTo(int page) {
    final p = page < 1 ? 1 : page;
    setState(() {
      _page = p;
      _pageField.text = '$p';
    });
    s.pdfFocus.value = (assetId: widget.assetId, page: p);
    // The reader's place in an item they are reading follows.
    noteReadPage(s.workspace, widget.assetId, p);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.workspace.changes]),
      builder: (context, _) {
        final asset = s.workspace.assets[widget.assetId];
        if (asset == null) {
          return const Center(child: Text('This PDF was deleted.'));
        }
        return LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < 560;
            final pdf = _pdfPane(asset);
            final notes = _notesPane(asset);
            if (narrow) {
              return Column(
                children: [
                  Expanded(flex: 5, child: pdf),
                  const Divider(height: 1),
                  Expanded(flex: 4, child: notes),
                ],
              );
            }
            final total = box.maxWidth - 8;
            return Row(
              children: [
                SizedBox(width: total * _ratio, child: pdf),
                MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    key: const ValueKey('pdf-split-handle'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) => setState(
                      () => _ratio = (_ratio + d.delta.dx / total).clamp(0.25, 0.75),
                    ),
                    onHorizontalDragEnd: (_) =>
                        unawaited(s.settings.set(_key, _ratio)),
                    child: Container(
                      width: 8,
                      color: AppColors.border.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                Expanded(child: notes),
              ],
            );
          },
        );
      },
    );
  }

  Widget _pdfPane(Asset asset) {
    final ref = WorkspaceRef(RefKind.pdf, asset.id, '$_page');
    final resolved = resolveRef(s, ref);
    final warning = pdfAnchorWarning(s, ref);
    final file = s.workspace.documentFile(asset);
    final ios = s.ios;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('pdf-prev'),
                tooltip: 'Previous page',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_left),
                onPressed: _page > 1 ? () => _goTo(_page - 1) : null,
              ),
              SizedBox(
                width: 54,
                child: TextField(
                  key: const ValueKey('pdf-page-field'),
                  controller: _pageField,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(isDense: true),
                  onSubmitted: (v) => _goTo(int.tryParse(v) ?? _page),
                ),
              ),
              IconButton(
                key: const ValueKey('pdf-next'),
                tooltip: 'Next page',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _goTo(_page + 1),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey('pdf-open'),
                tooltip: 'Open the PDF in the viewer at page $_page',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_new, size: 18),
                onPressed: () => openPdfAnchor(s, ref),
              ),
            ],
          ),
        ),
        if (warning != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              warning,
              key: const ValueKey('pdf-warning'),
              style: TextStyle(fontSize: 12, color: AppColors.warm),
            ),
          ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.canvas,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ios != null && file != null && resolved.opens
                ? FutureBuilder<Uint8List?>(
                    key: ValueKey('pdf-page-$_page'),
                    future: ios.renderPdfPage(file.path, _page - 1, 900),
                    builder: (context, snap) => snap.data == null
                        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                        : Image.memory(snap.data!, fit: BoxFit.contain),
                  )
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.picture_as_pdf_outlined, size: 40),
                          const SizedBox(height: 8),
                          Text(
                            asset.label,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            'Page $_page',
                            key: const ValueKey('pdf-page-label'),
                            style: const TextStyle(fontSize: 22),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            resolved.opens
                                ? 'misc. cannot draw PDF pages on this device yet. Open it in your PDF viewer and go to this page.'
                                : resolved.preview,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _notesPane(Asset asset) {
    final hits = pdfAnchorsOf(s, asset.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'NOTES ON THIS PDF',
                  style: TextStyle(fontSize: 11, letterSpacing: 0.6, color: AppColors.textFaint),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('pdf-new-note'),
                onPressed: () => _newNote(asset),
                icon: const Icon(Icons.note_add_outlined, size: 16),
                label: Text('Note for page $_page'),
              ),
            ],
          ),
        ),
        Expanded(
          child: hits.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No notes point at this PDF yet.',
                      style: TextStyle(color: AppColors.textFaint),
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final h in hits)
                      ListTile(
                        key: ValueKey('pdf-hit-${h.source.id}-${h.page}'),
                        dense: true,
                        selected: h.page == _page,
                        leading: Chip(
                          label: Text('p. ${h.page}'),
                          visualDensity: VisualDensity.compact,
                        ),
                        title: Text(
                          h.sourceTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          h.snippet,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _goTo(h.page),
                        trailing: IconButton(
                          key: ValueKey('pdf-open-note-${h.source.id}-${h.page}'),
                          tooltip: 'Open the note',
                          icon: const Icon(Icons.open_in_new, size: 18),
                          onPressed: () => s.openNote(h.source.id),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  void _newNote(Asset asset) {
    final note = createPdfAnchorNote(s, asset.id, _page);
    s.showToast('Made “${note.displayTitle}”.');
    setState(() {});
  }
}
