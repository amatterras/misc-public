import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../data/storage/log_sanitizer.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../data/models/object_library_models.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/storage/app_log.dart';
import '../../data/storage/attachment_store.dart';
import '../../data/storage/import_guard.dart';
import '../../data/workspace.dart';
import '../../platform/platform.dart' as native;
import 'link_preview.dart';

/// What was found on the clipboard, before anything is saved.
class ClipboardContent {
  const ClipboardContent({
    this.text,
    this.imageBytes,
    this.imageExtension = 'png',
    this.files = const [],
  });

  final String? text;
  final Uint8List? imageBytes;
  final String imageExtension;
  final List<String> files;

  String? get url => text == null ? null : extractUrl(text!);
  List<String> get imageFiles => [
    for (final f in files)
      if (AttachmentStore.imageExtensions.contains(
        AttachmentStore.extensionOf(f),
      ))
        f,
  ];
  bool get isEmpty =>
      (text == null || text!.trim().isEmpty) &&
      imageBytes == null &&
      imageFiles.isEmpty;
}

/// Turns clipboard content, picked files and links into shared [Asset]
/// records. Everything stays on this computer; the only network access is
/// fetching a pasted link's public title/preview (which can be turned off).
class CaptureService {
  CaptureService(
    this.workspace, {
    this.fetchPreviews = true,
    LinkPreviewFetcher? fetcher,
  }) : _fetcher = fetcher ?? LinkPreviewFetcher();

  final Workspace workspace;
  LibraryRepository? libraryRepository;
  bool fetchPreviews;
  final LinkPreviewFetcher _fetcher;
  final Set<String> _fetching = {};

  /// Windows clipboard (images, copied files) and photo picker (Windows or
  /// iOS); replaceable in tests so they never touch the real clipboard or
  /// open dialogs.
  native.NativeClipboard Function() readNativeClipboard =
      native.readNativeClipboard;
  FutureOr<List<String>> Function() pickImageFiles = native.pickImageFiles;

  /// Folder where the picker leaves its own copies of the chosen files
  /// (iOS: the app's tmp folder), deleted once they are imported. Null on
  /// Windows, where the picker returns the user's original files.
  Directory? pickerCopies = Platform.isIOS ? Directory.systemTemp : null;

  /// Deletes picked copies inside [pickerCopies]; never anything else.
  Future<void> _removePickerCopies(Iterable<String> paths) async {
    final dir = pickerCopies;
    if (dir == null) return;
    String norm(String p) => File(p).absolute.uri.normalizePath().toFilePath();
    var base = norm('${dir.path}${Platform.pathSeparator}');
    if (Platform.isWindows) base = base.toLowerCase();
    for (final path in paths) {
      final full = Platform.isWindows ? norm(path).toLowerCase() : norm(path);
      if (!full.startsWith(base) || full.length <= base.length) continue;
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// Canvas items copied inside the app, plus the text we put on the
  /// system clipboard at the same time (to recognise our own copy).
  List<CanvasItem> internalItems = const [];
  String? internalMarker;

  Future<ClipboardContent> readClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    final nativeData = readNativeClipboard();
    return ClipboardContent(
      text: text,
      imageBytes: nativeData.imageBytes,
      imageExtension: nativeData.imageExtension,
      files: nativeData.files,
    );
  }

  /// Creates (or reuses) the link asset and fetches its preview in the
  /// background.
  Asset link(String url, {String? title}) {
    final asset = workspace.linkAsset(url, title: title);
    if (fetchPreviews && asset.title == null && asset.description == null) {
      unawaited(refreshPreview(asset.id));
    }
    return asset;
  }

  Future<void> refreshPreview(String assetId) async {
    final asset = workspace.assets[assetId];
    if (asset?.url == null || !_fetching.add(assetId)) return;
    try {
      final preview = await _fetcher.fetch(asset!.url!);
      if (preview == null) return;
      String? previewFile;
      int? w, h;
      if (preview.imageUrl != null) {
        final image = await _fetcher.downloadImage(preview.imageUrl!);
        if (image != null) {
          previewFile = await workspace.attachments.importBytes(
            image.$1,
            image.$2,
          );
          final size = await Workspace.imageSizeOfBytes(image.$1);
          w = size?.width.round();
          h = size?.height.round();
          if (size == null) previewFile = null;
        }
      }
      final current = workspace.assets[assetId] ?? asset;
      workspace.assets.put(
        current.copyWith(
          title: (current.title?.isNotEmpty ?? false)
              ? current.title
              : preview.title,
          description: preview.description,
          siteName: preview.siteName,
          previewFile: previewFile,
          width: w,
          height: h,
        ),
      );
    } catch (e) {
      debugPrint(
        'Preview failed for ${hostOnly(asset?.url)}: ${describeError(e)}',
      );
    } finally {
      _fetching.remove(assetId);
    }
  }

  /// Stores clipboard image bytes (bitmaps are converted to PNG).
  Future<Asset> imageFromBytes(Uint8List bytes, String extension) async {
    var data = bytes;
    var ext = extension;
    if (ext == 'bmp') {
      final png = await _toPng(bytes);
      if (png != null) {
        data = png;
        ext = 'png';
      }
    }
    return workspace.imageAssetFromBytes(data, ext);
  }

  Future<List<Asset>> imagesFromFiles(Iterable<String> paths) async {
    final assets = <Asset>[];
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) continue;
      if (!AttachmentStore.imageExtensions.contains(
        AttachmentStore.extensionOf(path),
      )) {
        continue;
      }
      if (!await _acceptable(file)) continue;
      assets.add(await workspace.imageAssetFromFile(file));
    }
    return assets;
  }

  /// Whether [file] really is what its name says and is a sane size (see
  /// [ImportGuard]). A refused file is skipped like any other unsupported
  /// one; the log records only that it happened, never its name or content.
  Future<bool> _acceptable(File file) async {
    final problem = await ImportGuard.problemWith(
      file,
      AttachmentStore.extensionOf(file.path),
    );
    if (problem == null) return true;
    AppLog.warn('An imported file was refused: $problem');
    return false;
  }

  /// Opens the Windows photo picker and imports the chosen files.
  Future<List<Asset>> pickImages() async {
    final paths = await pickImageFiles();
    try {
      return await imagesFromFiles(paths);
    } finally {
      await _removePickerCopies(paths);
    }
  }

  /// Opens the photo picker and returns the chosen pictures' names and bytes
  /// without importing them (e.g. to show the AI). Files that are not
  /// pictures, or larger than [maxBytes], are skipped.
  Future<List<({String name, Uint8List bytes})>> pickImageBytes({
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    final paths = await pickImageFiles();
    try {
      return [
        for (final path in paths)
          if (AttachmentStore.imageExtensions.contains(
                AttachmentStore.extensionOf(path),
              ) &&
              File(path).existsSync() &&
              File(path).lengthSync() <= maxBytes)
            (
              name: path.split(RegExp(r'[\\/]')).last,
              bytes: await File(path).readAsBytes(),
            ),
      ];
    } finally {
      await _removePickerCopies(paths);
    }
  }

  /// PDF picker; replaceable in tests.
  FutureOr<List<String>> Function() pickDocumentFiles =
      native.pickDocumentFiles;

  /// Copies existing PDF files in as document records (others are skipped).
  Future<List<Asset>> documentsFromFiles(Iterable<String> paths) async {
    final assets = <Asset>[];
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) continue;
      if (!Workspace.documentExtensions.contains(
        AttachmentStore.extensionOf(path),
      )) {
        continue;
      }
      if (!await _acceptable(file)) continue;
      assets.add(await workspace.documentAssetFromFile(file));
    }
    return assets;
  }

  Future<List<Asset>> pickDocuments() async {
    final paths = await pickDocumentFiles();
    try {
      return await documentsFromFiles(paths);
    } finally {
      await _removePickerCopies(paths);
    }
  }

  /// Longest text accepted from outside the app (a link can be opened by any
  /// web page, so this is untrusted input).
  static const maxInboundText = 200000;

  /// Puts content shared from outside the app into the Inbox: one item for a
  /// link, one for any text (also when it came with a link), and one per
  /// photo. Links reuse the existing record for the same URL.
  ///
  /// Called for `theapp://` links (iOS Shortcut, via [SendToBridge.handleUri]);
  /// not yet run on a device.
  /// Saves an image or document [asset] as an Archive (library) object.
  /// Returns false when there is no library to save to.
  Future<bool> saveAssetToArchive(
    Asset asset, {
    Set<String> categories = const {},
    Map<String, Object?> metadata = const {},
  }) async {
    final library = libraryRepository;
    if (library == null) return false;
    final info = asset.file == null
        ? null
        : await workspace.attachments.contentInfo(asset.file!);
    final stored = info == null
        ? asset
        : asset.copyWith(fileSha256: info.$1, fileSize: info.$2);
    workspace.assets.put(stored);
    await workspace.assets.flush();
    final object = await library.save(
      type: stored.kind == AssetKind.image
          ? LibraryObjectType.image
          : LibraryObjectType.document,
      title: stored.label,
      attachmentIds: [stored.id],
      thumbnailId: stored.kind == AssetKind.image ? stored.id : null,
      metadata: {'legacyAssetId': stored.id, ...metadata},
    );
    for (final c in categories) {
      await library.setCategory(object.id, c, true);
    }
    return true;
  }

  /// Saves what was shared from outside (a link, text, files) in the
  /// Archive. Returns how many objects were saved (0 without a library).
  Future<int> captureToArchive({
    String? url,
    String? text,
    String? title,
    List<String> files = const [],
    Set<String> categories = const {},
    Map<String, Object?> metadata = const {},
  }) async {
    final library = libraryRepository;
    if (library == null) return 0;
    final cleanUrl = url != null ? extractUrl(url) : null;
    var bodyText = (text ?? '').trim();
    if (bodyText.length > maxInboundText) {
      bodyText = bodyText.substring(0, maxInboundText);
    }
    // Text that only repeats the link adds nothing.
    if (bodyText == cleanUrl || bodyText == url?.trim()) bodyText = '';
    var saved = 0;
    Future<void> label(LibraryObject o) async {
      if (categories.length == 1) {
        for (final existing
            in library.categoriesOf(o.id).difference(categories)) {
          await library.setCategory(o.id, existing, false);
        }
      }
      for (final c in categories) {
        await library.setCategory(o.id, c, true);
      }
      saved++;
    }

    if (cleanUrl != null) {
      await label(
        await library.save(
          type: LibraryObjectType.website,
          sourceUrl: cleanUrl,
          title: title ?? Uri.parse(cleanUrl).host,
          metadata: metadata,
        ),
      );
    }
    if (bodyText.isNotEmpty) {
      await label(
        await library.save(
          type: LibraryObjectType.note,
          title: title ?? 'Shared note',
          content: bodyText,
          metadata: metadata,
        ),
      );
    }
    if (files.isNotEmpty) {
      for (final asset in [
        ...await imagesFromFiles(files),
        ...await documentsFromFiles(files),
      ]) {
        if (await saveAssetToArchive(
          asset,
          categories: categories,
          metadata: metadata,
        )) {
          saved++;
        }
      }
    }
    return saved;
  }

  Future<List<InboxItem>> captureInbound({
    String? url,
    String? text,
    String? title,
    List<String> files = const [],
  }) async {
    final cleanUrl = url != null ? extractUrl(url) : null;
    var bodyText = (text ?? '').trim();
    if (bodyText.length > maxInboundText) {
      bodyText = bodyText.substring(0, maxInboundText);
    }
    // Text that only repeats the link adds nothing.
    if (bodyText == cleanUrl || bodyText == url?.trim()) bodyText = '';
    final created = <InboxItem>[];
    void add({String? text, String? assetId}) {
      final item = InboxItem(
        id: newId(),
        text: text,
        assetId: assetId,
        createdAt: DateTime.now().toUtc(),
      );
      workspace.inbox.put(item);
      created.add(item);
    }

    if (cleanUrl != null) add(assetId: link(cleanUrl, title: title).id);
    if (bodyText.isNotEmpty) add(text: bodyText);
    if (files.isNotEmpty) {
      for (final asset in await imagesFromFiles(files)) {
        add(assetId: asset.id);
      }
    }
    return created;
  }

  static Future<Uint8List?> _toPng(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
