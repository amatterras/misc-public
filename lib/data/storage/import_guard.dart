// Checks on files that come from outside before misc. keeps them.
//
// Imported files are untrusted: they arrive from the Share menu, the file
// picker, drag and drop, the clipboard and downloaded previews, and later
// they are opened by system viewers (image decoders, PDFKit, Quick Look).
// A file is only kept when its first bytes really are the kind of file its
// name says, and when it is not absurdly large. Nothing is ever executed, and
// stored files get an app-made name (never the sender's), so a crafted file
// name cannot reach outside the attachments folder.
import 'dart:io';

abstract final class ImportGuard {
  /// Largest picture or document kept. Bigger files are refused, not
  /// truncated.
  static const maxImageBytes = 320 * 1024 * 1024;
  static const maxDocumentBytes = 320 * 1024 * 1024;

  /// Whether [head] (the first bytes of a file, at least 12 and up to 1024)
  /// has the signature of the kind of file [extension] names (pictures: any
  /// picture format) (lower case, no dot).
  /// Kinds that are not checked here (unknown extensions) pass.
  static bool matchesSignature(List<int> head, String extension) {
    bool starts(List<int> sig, [int at = 0]) {
      if (head.length < at + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (head[at + i] != sig[i]) return false;
      }
      return true;
    }

    bool isImage() =>
        starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) || // png
        starts(const [0xFF, 0xD8, 0xFF]) || // jpeg
        starts('GIF87a'.codeUnits) ||
        starts('GIF89a'.codeUnits) ||
        (starts('RIFF'.codeUnits) && starts('WEBP'.codeUnits, 8)) ||
        starts('BM'.codeUnits);

    switch (extension.toLowerCase()) {
      case 'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp':
        // Any real picture format is accepted under any picture name: web
        // images are often a PNG called .jpg and image decoders go by the
        // content. What is refused is a file that is not a picture at all.
        return isImage();
      case 'pdf':
        // The PDF header may follow a few bytes of junk; viewers accept it
        // anywhere in the first 1024 bytes.
        final limit = head.length < 1024 ? head.length : 1024;
        final needle = '%PDF-'.codeUnits;
        for (var i = 0; i + needle.length <= limit; i++) {
          if (starts(needle, i)) return true;
        }
        return false;
      default:
        return true;
    }
  }

  /// Why [file] must not be imported as [extension], or null if it may be.
  /// Reads at most the first kilobyte.
  static Future<String?> problemWith(File file, String extension) async {
    final isImage = const {
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'bmp',
    }.contains(extension.toLowerCase());
    final length = await file.length();
    if (length == 0) return 'The file is empty.';
    if (length > (isImage ? maxImageBytes : maxDocumentBytes)) {
      return 'The file is too large.';
    }
    final head = <int>[];
    await for (final chunk in file.openRead(0, 1024)) {
      head.addAll(chunk);
    }
    if (!matchesSignature(head, extension)) {
      return 'The file is not really a .$extension file.';
    }
    return null;
  }
}
