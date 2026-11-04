// Reading a PDF page by page, with the notes that cite it.
//
// iPhone and iPad: pages are drawn by the system's PDFKit (the bridge call
// that notes already use), one at a time, so memory stays small however long
// the PDF is. Windows has no in-app page renderer (a plugin would be needed),
// so there the PDF opens in the default viewer and misc. says which page to
// go to; the page references themselves (notes citing page N, found from the
// PDF and from the note) work the same everywhere.
//
// This is a reading and referencing aid, not a PDF editor.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/library_models.dart';
import '../../platform/ios_bridge.dart';
import '../../widgets/common.dart' show promptText;
import 'relations.dart';

/// Opens [asset] at [page] (1-based; null: the start).
Future<void> openPdfAtPage(
  BuildContext context,
  AppState s,
  Asset asset,
  int? page,
) async {
  final file = s.workspace.documentFile(asset);
  if (file == null) {
    s.showToast('This PDF is not on this device yet.');
    return;
  }
  if (Platform.isIOS) {
    final sizes = await IosBridge.instance.pdfPageSizes(file.path);
    if (sizes != null && sizes.isNotEmpty && context.mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PdfPageViewer(
            state: s,
            asset: asset,
            path: file.path,
            pages: sizes.length,
            initialPage: (page ?? 1).clamp(1, sizes.length),
          ),
        ),
      );
      return;
    }
  }
  s.openDocument(file.path);
  if (page != null) s.showToast('Opened. Go to page $page.');
}

class PdfPageViewer extends StatefulWidget {
  const PdfPageViewer({
    super.key,
    required this.state,
    required this.asset,
    required this.path,
    required this.pages,
    this.initialPage = 1,
  });

  final AppState state;
  final Asset asset;
  final String path;
  final int pages;
  final int initialPage;

  @override
  State<PdfPageViewer> createState() => _PdfPageViewerState();
}

class _PdfPageViewerState extends State<PdfPageViewer> {
  late int _page = widget.initialPage;
  Uint8List? _image;
  bool _loading = false;

  RelationService get _service => RelationService(widget.state.workspace);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final width =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    final bytes = await IosBridge.instance.renderPdfPage(
      widget.path,
      _page - 1,
      width.clamp(300, 2400),
    );
    if (!mounted) return;
    setState(() {
      _image = bytes;
      _loading = false;
    });
  }

  void _go(int page) {
    if (page < 1 || page > widget.pages || page == _page) return;
    setState(() => _page = page);
    _load();
  }

  Future<void> _jump() async {
    final text = await promptText(
      context,
      title: 'Go to page (1–${widget.pages})',
      initial: '$_page',
    );
    final n = int.tryParse((text ?? '').trim());
    if (n != null) _go(n);
  }

  /// Notes are linked to this page: picks a note (or makes a new one).
  Future<void> _cite() async {
    final s = widget.state;
    final notes = s.workspace.notes.all.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.card,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              key: const ValueKey('cite-new-note'),
              leading: const Icon(Icons.add),
              title: Text('New note about page $_page'),
              onTap: () => Navigator.pop(context, '+new'),
            ),
            for (final n in notes.take(30))
              ListTile(
                title: Text(n.displayTitle, maxLines: 1),
                onTap: () => Navigator.pop(context, n.id),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final noteId = choice == '+new'
        ? s.workspace
              .createNote(title: '${widget.asset.label}, page $_page', body: '')
              .id
        : choice;
    _service.link(
      Ref(RefKind.note, noteId),
      Ref(RefKind.asset, widget.asset.id),
      rel: 'cites',
      page: _page,
    );
    s.showToast('Page $_page is linked to the note.');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final refs = _service
        .pageReferences(widget.asset.id)
        .where((r) => r.page == _page)
        .toList();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: Text(
          widget.asset.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          IconButton(
            key: const ValueKey('pdf-cite'),
            tooltip: 'Link a note to this page',
            icon: const Icon(Icons.add_link),
            onPressed: _cite,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _image == null
                  ? (_loading
                        ? const CircularProgressIndicator()
                        : Text(
                            'This page could not be shown.',
                            style: TextStyle(color: AppColors.textFaint),
                          ))
                  : InteractiveViewer(
                      maxScale: 5,
                      child: Image.memory(_image!, fit: BoxFit.contain),
                    ),
            ),
          ),
          if (refs.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final r in refs)
                    Padding(
                      padding: const EdgeInsets.only(
                        right: 8,
                        top: 6,
                        bottom: 6,
                      ),
                      child: ActionChip(
                        avatar: const Icon(
                          Icons.description_outlined,
                          size: 14,
                        ),
                        label: Text(
                          _service.titleOf(r.from),
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.state.openNote(r.from.id);
                        },
                      ),
                    ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: SizedBox(
              height: 52,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    key: const ValueKey('pdf-prev'),
                    icon: const Icon(Icons.chevron_left),
                    onPressed: _page > 1 ? () => _go(_page - 1) : null,
                  ),
                  TextButton(
                    key: const ValueKey('pdf-page'),
                    onPressed: _jump,
                    child: Text('Page $_page of ${widget.pages}'),
                  ),
                  IconButton(
                    key: const ValueKey('pdf-next'),
                    icon: const Icon(Icons.chevron_right),
                    onPressed: _page < widget.pages
                        ? () => _go(_page + 1)
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
