// Renders PDF pages to images, one page at a time, wherever the platform
// can: iPhone/iPad through the existing "theapp/ios" bridge (PDFKit),
// Windows through the "theapp/windows" channel (Windows.Data.Pdf in the
// runner). `PdfRenderer.instance` is null where no renderer exists; callers
// keep their existing fallback (attach only / open in the default viewer).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ios_bridge.dart';

abstract class PdfRenderer {
  /// Page sizes (points, after each page's rotation) of the PDF at [path],
  /// or null if it cannot be read.
  Future<List<Size>?> pageSizes(String path);

  /// PNG of page [page] (0-based) of the PDF at [path], [width] pixels
  /// wide, or null if it cannot be rendered.
  Future<Uint8List?> renderPage(String path, int page, int width);

  static PdfRenderer? _platform;
  static bool _overridden = false;
  static PdfRenderer? _override;

  /// The renderer for this device, or null when pages cannot be rendered
  /// here. During tests there is none unless [setForTests] installed one
  /// (the Windows channel has no handler under `flutter test`, so every
  /// call would come back null anyway).
  static PdfRenderer? get instance {
    if (_overridden) return _override;
    if (Platform.isIOS) return _platform ??= _IosPdfRenderer();
    if (Platform.isWindows) return _platform ??= WindowsPdfRenderer();
    return null;
  }

  /// Replaces [instance] in tests (null = "this device cannot render").
  @visibleForTesting
  static void setForTests(PdfRenderer? renderer) {
    _overridden = true;
    _override = renderer;
  }

  @visibleForTesting
  static void resetForTests() {
    _overridden = false;
    _override = null;
  }
}

class _IosPdfRenderer implements PdfRenderer {
  @override
  Future<List<Size>?> pageSizes(String path) =>
      IosBridge.instance.pdfPageSizes(path);

  @override
  Future<Uint8List?> renderPage(String path, int page, int width) =>
      IosBridge.instance.renderPdfPage(path, page, width);
}

/// Windows: the runner renders with Windows.Data.Pdf (built into Windows,
/// no plugin). Any failure — an unreadable or password-protected PDF, an
/// old runner without the handler — is reported as null, never thrown.
class WindowsPdfRenderer implements PdfRenderer {
  WindowsPdfRenderer({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('theapp/windows');

  final MethodChannel _channel;

  @override
  Future<List<Size>?> pageSizes(String path) async {
    try {
      final result = await _channel.invokeListMethod<Object?>('pdfInfo', path);
      if (result == null) return null;
      final sizes = [
        for (final s in result.whereType<List<Object?>>())
          if (s.length >= 2 && s[0] is num && s[1] is num)
            Size((s[0]! as num).toDouble(), (s[1]! as num).toDouble()),
      ];
      return sizes.isEmpty ? null : sizes;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<Uint8List?> renderPage(String path, int page, int width) async {
    try {
      return await _channel.invokeMethod<Uint8List>('pdfRenderPage', {
        'path': path,
        'page': page,
        'width': width,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
