import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../data/models/library_models.dart';
import '../../data/workspace.dart';

/// Gives the canvas access to shared records (link/image assets, notes)
/// and decoded images, and tells it when any of them change.
abstract class CanvasResources implements Listenable {
  Asset? asset(String id);
  Note? note(String id);

  /// The decoded image for an attachment file, or null while it loads.
  ui.Image? image(String fileName);

  /// Completes once each of [fileNames] is decoded or has failed, so a
  /// picture drawn afterwards (an export) has every photo in it.
  Future<void> preload(Iterable<String> fileNames);
}

class WorkspaceCanvasResources extends ChangeNotifier
    implements CanvasResources {
  WorkspaceCanvasResources(this.workspace) {
    workspace.assets.addListener(notifyListeners);
    workspace.notes.addListener(notifyListeners);
  }

  final Workspace workspace;
  final Map<String, ui.Image> _images = {};
  final Map<String, Future<void>> _loading = {};
  final Set<String> _failed = {};
  bool _disposed = false;

  /// Longest side images are decoded at; plenty for on-screen use.
  static const int maxDecodeSize = 2048;

  @override
  Asset? asset(String id) => workspace.assets[id];

  @override
  Note? note(String id) => workspace.notes[id];

  @override
  ui.Image? image(String fileName) {
    final cached = _images[fileName];
    if (cached != null) return cached;
    _start(fileName);
    return null;
  }

  /// Whether [fileName] could not be decoded (an export says so).
  bool failed(String fileName) => _failed.contains(fileName);

  @override
  Future<void> preload(Iterable<String> fileNames) async {
    await Future.wait([for (final name in fileNames) ?_start(name)]);
  }

  Future<void>? _start(String fileName) {
    if (_failed.contains(fileName) || _images.containsKey(fileName)) {
      return null;
    }
    return _loading[fileName] ??= _load(fileName);
  }

  Future<void> _load(String fileName) async {
    try {
      final File file = workspace.attachments.fileFor(fileName);
      final bytes = await file.readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      final scale = (maxDecodeSize / (w > h ? w : h)).clamp(0.0, 1.0);
      final codec = await descriptor.instantiateCodec(
        targetWidth: (w * scale).round(),
        targetHeight: (h * scale).round(),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      if (_disposed) {
        frame.image.dispose();
        return;
      }
      _images[fileName] = frame.image;
    } catch (e) {
      debugPrint('Could not load image $fileName: $e');
      _failed.add(fileName);
    } finally {
      _loading.remove(fileName);
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    workspace.assets.removeListener(notifyListeners);
    workspace.notes.removeListener(notifyListeners);
    for (final img in _images.values) {
      img.dispose();
    }
    super.dispose();
  }
}
