import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../data/storage/attachment_store.dart';
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
  bool fetchPreviews;
  final LinkPreviewFetcher _fetcher;
  final Set<String> _fetching = {};

  /// Windows clipboard (images, copied files) and photo picker (Windows or
  /// iOS); replaceable in tests so they never touch the real clipboard or
  /// open dialogs.
  native.NativeClipboard Function() readNativeClipboard =
      native.readNativeClipboard;
  FutureOr<List<String>> Function() pickImageFiles = native.pickImageFiles;

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
          final size = await Workspace.imageSize(
            workspace.attachments.fileFor(previewFile),
          );
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
      debugPrint('Preview failed for ${asset?.url}: $e');
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
      assets.add(await workspace.imageAssetFromFile(file));
    }
    return assets;
  }

  /// Opens the Windows photo picker and imports the chosen files.
  Future<List<Asset>> pickImages() async {
    final paths = await pickImageFiles();
    return imagesFromFiles(paths);
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
      assets.add(await workspace.documentAssetFromFile(file));
    }
    return assets;
  }

  Future<List<Asset>> pickDocuments() async =>
      documentsFromFiles(await pickDocumentFiles());

  /// Longest text accepted from outside the app (a link can be opened by any
  /// web page, so this is untrusted input).
  static const maxInboundText = 20000;

  /// Puts content shared from outside the app into the Inbox: one item for a
  /// link, one for any text (also when it came with a link), and one per
  /// photo. Links reuse the existing record for the same URL.
  ///
  /// Not connected yet: nothing calls this outside tests (see
  /// ios/ShareExtension/README.md).
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
