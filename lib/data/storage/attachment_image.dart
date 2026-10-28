import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'attachment_store.dart';

/// An image from the attachments, decrypted in memory (no plain file is
/// made). Use instead of `Image.file(store.fileFor(name))`.
@immutable
class AttachmentImageProvider extends ImageProvider<AttachmentImageProvider> {
  const AttachmentImageProvider(this.store, this.name);

  final AttachmentStore store;
  final String name;

  @override
  Future<AttachmentImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    AttachmentImageProvider key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: name,
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await store.readBytes(name);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is AttachmentImageProvider &&
      other.name == name &&
      other.store.dir.path == store.dir.path;

  @override
  int get hashCode => Object.hash(name, store.dir.path);
}
