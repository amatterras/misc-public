// The export window: choose the format, background, size and file name,
// see a small preview made by the same renderer the export itself uses,
// then save. Nothing is written until Save; a cancelled save dialog, a
// place that cannot be written to, or a failed write ends in a plain message
// with "try again" / "choose another place", never a false "saved". After a
// save the window offers to show or open the file.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/library_models.dart';
import '../../data/storage/app_log.dart';
import '../../platform/platform.dart' as native;
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_export.dart';
import 'exports.dart';

enum ExportFormat { png, web, markdown, pages }

extension ExportFormatInfo on ExportFormat {
  String get label => switch (this) {
    ExportFormat.png => 'Picture (PNG)',
    ExportFormat.web => 'Read-only web page',
    ExportFormat.markdown => 'Text (Markdown)',
    ExportFormat.pages => 'Page pictures',
  };

  String get extension => switch (this) {
    ExportFormat.png || ExportFormat.pages => 'png',
    ExportFormat.web => 'html',
    ExportFormat.markdown => 'md',
  };

  String get typeLabel => switch (this) {
    ExportFormat.png || ExportFormat.pages => 'PNG picture',
    ExportFormat.web => 'Web page',
    ExportFormat.markdown => 'Markdown text',
  };
}

// ----------------------------------------------------- remembered choices --

/// Export choices kept on this device (settings, not synced): the last
/// options, a short list of recent choices, and the folder last saved to.
class ExportPrefs {
  ExportPrefs(this.s);
  final AppState s;

  static const maxRecent = 5;

  ExportOptions get options => ExportOptions.fromJson(s.settings.get<Object>('exportOptions'));

  Future<void> saveOptions(ExportOptions o) =>
      s.settings.set('exportOptions', o.toJson());

  /// Recent choices, newest first: a format and its options.
  List<({ExportFormat format, ExportOptions options})> get recent {
    final raw = s.settings.get<List>('exportRecent') ?? const [];
    final out = <({ExportFormat format, ExportOptions options})>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final f = ExportFormat.values.asNameMap()[e['format']];
      if (f == null) continue;
      out.add((format: f, options: ExportOptions.fromJson(e['options'])));
    }
    return out.take(maxRecent).toList();
  }

  Future<void> remember(ExportFormat format, ExportOptions options) {
    final list = [
      (format: format, options: options),
      for (final r in recent)
        if (!(r.format == format && r.options == options)) r,
    ].take(maxRecent);
    return s.settings.set('exportRecent', [
      for (final r in list) {'format': r.format.name, 'options': r.options.toJson()},
    ]);
  }

  /// The folder to open the save dialog in: only where this platform has a
  /// save dialog, and only if it still exists and can be written to.
  Directory? get lastFolder {
    if (!hasExportDialog) return null;
    final path = s.settings.get<String>('exportLastFolder');
    if (path == null || path.isEmpty) return null;
    final dir = Directory(path);
    return isWritableFolder(dir) ? dir : null;
  }

  Future<void> rememberFolder(File saved) {
    if (!hasExportDialog) return Future.value();
    return s.settings.set('exportLastFolder', saved.parent.path);
  }
}

/// Whether files can be made in [dir] (it exists, and a probe file works).
bool isWritableFolder(Directory dir) {
  try {
    if (!dir.existsSync()) return false;
    final probe = File(
      '${dir.path}${Platform.pathSeparator}.theapp-write-test-${DateTime.now().microsecondsSinceEpoch}',
    );
    probe.writeAsBytesSync(const [0]);
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

// ------------------------------------------------------------- the window --

/// Exports the mindmap [c] (picture or read-only page).
Future<void> showExportDialog(
  BuildContext context,
  AppState s,
  CanvasController c, {
  bool web = false,
}) {
  if (c.items.isEmpty) {
    s.showToast('This mindmap is empty.');
    return Future.value();
  }
  return showAppDialog<void>(
    context: context,
    builder: (_) => _ExportDialog(
      state: s,
      canvas: c,
      formats: const [ExportFormat.png, ExportFormat.web],
      initial: web ? ExportFormat.web : ExportFormat.png,
    ),
  );
}

/// Exports the note [n] (text, page pictures or read-only page).
Future<void> showNoteExportDialog(
  BuildContext context,
  AppState s,
  Note n,
  ExportFormat initial,
) => showAppDialog<void>(
  context: context,
  builder: (_) => _ExportDialog(
    state: s,
    note: n,
    formats: const [
      ExportFormat.markdown,
      ExportFormat.pages,
      ExportFormat.web,
    ],
    initial: initial,
  ),
);

enum _Phase { edit, saving, done, failed }

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({
    required this.state,
    this.canvas,
    this.note,
    required this.formats,
    required this.initial,
  });

  final AppState state;
  final CanvasController? canvas;
  final Note? note;
  final List<ExportFormat> formats;
  final ExportFormat initial;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late ExportFormat _format = widget.initial;
  late ExportOptions _options = ExportPrefs(widget.state).options;
  late final _name = TextEditingController(text: _defaultName);
  _Phase _phase = _Phase.edit;
  String? _message;
  List<File> _saved = const [];

  Uint8List? _preview;
  ({int w, int h})? _outSize;
  bool _previewing = false;
  int _previewToken = 0;
  Timer? _debounce;

  AppState get s => widget.state;
  CanvasController? get c => widget.canvas;
  Note? get n => widget.note;

  String get _defaultName =>
      safeFileName(c != null ? c!.title : n!.displayTitle);

  bool get _isPicture => c != null && _format == ExportFormat.png;

  @override
  void initState() {
    super.initState();
    _schedulePreview();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    super.dispose();
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _makePreview);
  }

  /// A small picture from the same renderer (never the full-size export),
  /// and the size the real file will have.
  Future<void> _makePreview() async {
    final canvas = c;
    if (canvas == null) return;
    final token = ++_previewToken;
    setState(() => _previewing = true);
    try {
      final r = await renderItemsPicture(
        canvas,
        margin: 24,
        maxSide: 480,
        background: _isPicture ? _options.color : null,
      );
      Rect? area;
      for (final i in canvas.items) {
        final b = canvas.itemBounds(i);
        area = area == null ? b : area.expandToInclude(b);
      }
      if (!mounted || token != _previewToken) return;
      ({int w, int h})? out;
      if (area != null) {
        final rect = area.inflate(48);
        final scale = rect.longestSide <= 0
            ? 1.0
            : (_options.maxSide / rect.longestSide).clamp(0.0, 2.0);
        out = (
          w: (rect.width * scale).ceil().clamp(1, 100000),
          h: (rect.height * scale).ceil().clamp(1, 100000),
        );
      }
      setState(() {
        _preview = r?.png;
        _outSize = out;
        _previewing = false;
      });
    } catch (e, st) {
      AppLog.error('Export preview failed', e, st);
      if (mounted && token == _previewToken) {
        setState(() {
          _preview = null;
          _previewing = false;
        });
      }
    }
  }

  void _set({ExportFormat? format, ExportOptions? options}) {
    setState(() {
      _format = format ?? _format;
      _options = options ?? _options;
    });
    _schedulePreview();
  }

  Future<List<File>> _write(File? target) async {
    final name = safeFileName(_name.text);
    if (c != null) {
      final ExportResult? r = _format == ExportFormat.web
          ? await exportCanvasWebPage(s, c!, file: target, name: name, options: _options)
          : await exportCanvasPicture(s, c!, file: target, name: name, options: _options);
      if (r == null) throw const ExportFailure('This mindmap is empty.');
      return [r.file];
    }
    return switch (_format) {
      ExportFormat.markdown => [await exportNoteMarkdown(s, n!, file: target, name: name)],
      ExportFormat.web => [(await exportNoteWebPage(s, n!, file: target, name: name)).file],
      _ => await exportNotePages(s, n!, name: name),
    };
  }

  Future<void> _save() async {
    final ext = _format.extension;
    final name = safeFileName(_name.text);
    File? target;
    if (hasExportDialog && _format != ExportFormat.pages) {
      final prefs = ExportPrefs(s);
      final dir = prefs.lastFolder ?? exportsFolder(s);
      try {
        await dir.create(recursive: true);
      } on FileSystemException {
        // The save dialog then opens in its own default folder.
      }
      final path = askExportPath(
        suggestedName: '$name.$ext',
        extension: ext,
        typeLabel: _format.typeLabel,
        initialDir: dir.path,
      );
      if (path == null) {
        setState(() {
          _phase = _Phase.edit;
          _message = 'Cancelled. Nothing was saved.';
        });
        return;
      }
      target = File(path);
    }
    setState(() {
      _phase = _Phase.saving;
      _message = null;
    });
    try {
      final files = await _write(target);
      for (final f in files) {
        if (!f.existsSync() || f.lengthSync() == 0) {
          throw const ExportFailure('The file came out empty. Nothing was kept.');
        }
      }
      final prefs = ExportPrefs(s);
      await prefs.saveOptions(_options);
      await prefs.remember(_format, _options);
      if (target != null) await prefs.rememberFolder(files.first);
      if (!mounted) return;
      setState(() {
        _saved = files;
        _phase = _Phase.done;
      });
    } on ExportFailure catch (e) {
      if (mounted) setState(() { _phase = _Phase.failed; _message = e.message; });
    } on FileSystemException catch (e, st) {
      AppLog.error('Export could not be saved', e, st);
      final why = e.osError?.message.trim() ?? '';
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _message =
              'Could not save the export${target == null ? '' : ' to ${target.path}'}'
              '${why.isEmpty ? '' : ': $why'}. Nothing was changed.';
        });
      }
    }
  }

  // ----------------------------------------------------------- the views --

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('export-dialog'),
      title: Text(
        c != null ? 'Export “${c!.title}”' : 'Export “${n!.displayTitle}”',
        style: const TextStyle(fontSize: 16),
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 520,
        child: switch (_phase) {
          _Phase.done => _doneView(),
          _Phase.failed => _failedView(),
          _ => _editView(),
        },
      ),
      actions: switch (_phase) {
        _Phase.done => [
          TextButton(
            key: const ValueKey('export-done'),
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
        _Phase.failed => [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton(
            key: const ValueKey('export-retry'),
            onPressed: () => setState(() => _phase = _Phase.edit),
            child: Text(hasExportDialog ? 'Choose another place' : 'Try again'),
          ),
        ],
        _ => [
          TextButton(
            key: const ValueKey('export-cancel'),
            onPressed: _phase == _Phase.saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('export-save'),
            onPressed: _phase == _Phase.saving ? null : _save,
            child: Text(_phase == _Phase.saving ? 'Saving…' : 'Save…'),
          ),
        ],
      },
    );
  }

  Widget _chips<T>({
    required String label,
    required List<(T, String)> items,
    required T value,
    required ValueChanged<T> onPick,
    String keyPrefix = 'export-opt',
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 92,
          child: Text(label, style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final (v, text) in items)
                ChoiceChip(
                  key: ValueKey('$keyPrefix-$label-$text'),
                  label: Text(text, style: const TextStyle(fontSize: 12)),
                  selected: v == value,
                  onSelected: (_) => onPick(v),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _editView() {
    final prefs = ExportPrefs(s);
    final recent = prefs.recent.where((r) => widget.formats.contains(r.format)).toList();
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (recent.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Recent', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                  for (final r in recent)
                    ActionChip(
                      key: ValueKey('export-recent-${r.format.name}-${r.options.maxSide}-${r.options.background.name}'),
                      avatar: const Icon(Icons.history, size: 14),
                      label: Text(
                        '${r.format.label.split(' (').first}'
                        '${c != null && r.format == ExportFormat.png ? ' · ${_resolutionName(r.options.maxSide)}${r.options.background == ExportBackground.transparent ? ' · transparent' : ''}' : ''}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onPressed: () => _set(format: r.format, options: r.options),
                    ),
                ],
              ),
            ),
          _chips<ExportFormat>(
            label: 'Format',
            items: [for (final f in widget.formats) (f, f.label)],
            value: _format,
            onPick: (f) => _set(format: f),
          ),
          if (_isPicture) ...[
            _chips<ExportBackground>(
              label: 'Background',
              items: const [
                (ExportBackground.canvas, 'As on screen'),
                (ExportBackground.transparent, 'Transparent'),
              ],
              value: _options.background,
              onPick: (b) => _set(options: _options.copyWith(background: b)),
            ),
            _chips<int>(
              label: 'Size',
              items: [for (final (name, side) in exportResolutions) (side, name)],
              value: _options.maxSide,
              onPick: (v) => _set(options: _options.copyWith(maxSide: v)),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              key: const ValueKey('export-name'),
              controller: _name,
              decoration: InputDecoration(
                labelText: 'File name',
                isDense: true,
                suffixText: '.${_format.extension}',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _message!,
                key: const ValueKey('export-message'),
                style: TextStyle(fontSize: 12, color: AppColors.warm),
              ),
            ),
          _previewArea(),
        ],
      ),
    );
  }

  String _resolutionName(int side) =>
      exportResolutions.where((r) => r.$2 == side).firstOrNull?.$1 ?? '$side px';

  Widget _previewArea() {
    final heading = TextStyle(fontSize: 11, letterSpacing: 0.6, color: AppColors.textFaint);
    final web = _format == ExportFormat.web;
    Widget body;
    if (c != null) {
      final picture = _preview == null
          ? Center(
              child: _previewing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('No preview', style: TextStyle(color: AppColors.textFaint)),
            )
          : Image.memory(_preview!, key: const ValueKey('export-preview-image'), fit: BoxFit.contain, gaplessPlayback: true);
      if (web) {
        body = _WebFrame(
          title: c!.title,
          meta: 'Mindmap',
          child: SizedBox(height: 150, child: picture),
        );
      } else {
        body = Container(
          height: 190,
          decoration: BoxDecoration(
            color: AppColors.cardRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: _options.background == ExportBackground.transparent
              ? CustomPaint(painter: _Checkerboard(), child: picture)
              : picture,
        );
      }
    } else {
      final note = n!;
      final text = note.body.trim();
      body = _WebFrame(
        title: note.displayTitle,
        meta: note.tags.map((t) => '#$t').join('  '),
        plain: _format == ExportFormat.markdown,
        child: Text(
          text.isEmpty ? '(no text)' : (text.length > 320 ? '${text.substring(0, 320)}…' : text),
          style: const TextStyle(fontSize: 12, height: 1.5, color: Color(0xFFF5F3EF)),
        ),
      );
    }
    final info = StringBuffer();
    if (_isPicture && _outSize != null) {
      info.write('About ${_outSize!.w} × ${_outSize!.h} px · PNG');
    } else if (web) {
      info.write(
        c != null
            ? 'One page with the picture of the whole mindmap. No scripts, no editing; photos are inside the file.'
            : 'One page with the text, page pictures and photos. No scripts, no editing; attachments listed by name.',
      );
    } else if (_format == ExportFormat.markdown) {
      info.write('Plain text: title, tags and body. Pictures are not included.');
    } else if (_format == ExportFormat.pages) {
      info.write('One PNG per page that has handwriting or text boxes.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(web ? 'WHAT THE RECIPIENT SEES' : 'PREVIEW', style: heading),
        const SizedBox(height: 6),
        body,
        const SizedBox(height: 6),
        Text(info.toString(), key: const ValueKey('export-info'), style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
        Text('Your original is not changed.', style: TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
      ],
    );
  }

  Widget _doneView() {
    final first = _saved.first;
    final bytes = _saved.fold<int>(0, (n, f) => n + f.lengthSync());
    final size = bytes < 1024 * 1024
        ? '${(bytes / 1024).ceil()} KB'
        : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return Column(
      key: const ValueKey('export-success'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, color: AppColors.success),
            const SizedBox(width: 8),
            Text(
              _saved.length == 1 ? 'Saved' : 'Saved ${_saved.length} files',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText(first.path, key: const ValueKey('export-path'), style: const TextStyle(fontSize: 12.5)),
        Text(size, style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            if (native.canOpenFolders)
              OutlinedButton.icon(
                key: const ValueKey('export-reveal'),
                onPressed: () => native.openFolder(first.parent.path),
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Show in folder'),
              ),
            if (Platform.isWindows || Platform.isIOS)
              OutlinedButton.icon(
                key: const ValueKey('export-open'),
                onPressed: () {
                  if (!native.openDocument(first.path)) {
                    s.showToast('Could not open the file here. It is saved at ${first.path}');
                  }
                },
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open'),
              ),
            if (s.ios != null)
              OutlinedButton.icon(
                key: const ValueKey('export-share'),
                onPressed: () => s.ios!.shareFile(first.path),
                icon: const Icon(Icons.ios_share, size: 16),
                label: const Text('Share…'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _failedView() => Column(
    key: const ValueKey('export-failed'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(Icons.error_outline, color: AppColors.warm),
          const SizedBox(width: 8),
          const Text('Not saved', style: TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
      const SizedBox(height: 8),
      Text(_message ?? 'The export could not be saved.', key: const ValueKey('export-error')),
    ],
  );
}

/// The read-only page as the recipient sees it (same colours as the file).
class _WebFrame extends StatelessWidget {
  const _WebFrame({
    required this.title,
    required this.meta,
    required this.child,
    this.plain = false,
  });

  final String title;
  final String meta;
  final Widget child;
  final bool plain;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF191A1D),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFFF5F3EF))),
        if (meta.isNotEmpty)
          Text(meta, style: const TextStyle(fontSize: 11.5, color: Color(0xFFAAAEB6))),
        const SizedBox(height: 8),
        child,
        const SizedBox(height: 8),
        const Text('Shared from misc. · view-only copy',
            style: TextStyle(fontSize: 10.5, color: Color(0xFFAAAEB6))),
      ],
    ),
  );
}

class _Checkerboard extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 10.0;
    final a = Paint()..color = const Color(0xFF4A4C52);
    final b = Paint()..color = const Color(0xFF65686F);
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        final odd = ((x / cell).floor() + (y / cell).floor()).isOdd;
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), odd ? a : b);
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard old) => false;
}

/// Decodes [png] to find its size (for tests and the success view).
Future<ui.Size> pictureSize(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  try {
    final f = await codec.getNextFrame();
    final size = ui.Size(f.image.width.toDouble(), f.image.height.toDouble());
    f.image.dispose();
    return size;
  } finally {
    codec.dispose();
  }
}
