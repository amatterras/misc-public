// Text recognition (OCR) for scanned PDFs, on this device only:
//   - iPhone/iPad: Apple's Vision framework renders and reads each page
//     (IosBridge.ocrPdf).
//   - Windows: the page images inside the PDF (JPEG, or 8-bit gray/RGB
//     Flate images) are read with Windows' built-in OCR engine
//     (Windows.Media.Ocr, Windows 10+, the language packs the user has),
//     driven through Windows PowerShell. Other image encodings (CCITT fax,
//     JBIG2, JPEG 2000) are skipped and reported as not readable.
// Nothing is ever sent to an AI or online OCR service.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../platform/ios_bridge.dart';

/// Bump when recognition changes, so cached results are made again.
const ocrVersion = 1;

/// Limits for one document.
const ocrMaxPages = 60;
const ocrMaxImageSide = 10000; // Windows OCR's own limit
const ocrMaxImageBytes = 40 * 1024 * 1024;
const ocrTimeoutPerPage = Duration(seconds: 40);
const ocrMaxChars = 1000000;

/// One page's picture found in a PDF.
class PdfPageImage {
  const PdfPageImage(this.page, this.extension, this.bytes);

  /// 1-based page number (0 when the page could not be determined).
  final int page;
  final String extension; // 'jpg' or 'bmp'
  final Uint8List bytes;
}

// ------------------------------------------------------------ PDF parsing --

final _objPattern = RegExp(r'(\d+)\s+0\s+obj\b');

/// The PDF's objects by number: (dictionary text, stream start, end).
Map<int, (String, int, int)> _objects(Uint8List b) {
  final text = latin1.decode(b, allowInvalid: true);
  final out = <int, (String, int, int)>{};
  for (final m in _objPattern.allMatches(text)) {
    final n = int.parse(m[1]!);
    final start = m.end;
    final endObj = text.indexOf('endobj', start);
    if (endObj < 0) continue;
    final streamAt = text.indexOf('stream', start);
    if (streamAt >= 0 && streamAt < endObj) {
      var s = streamAt + 6;
      if (s < text.length && text.codeUnitAt(s) == 13) s++;
      if (s < text.length && text.codeUnitAt(s) == 10) s++;
      final e = text.lastIndexOf('endstream', endObj);
      out[n] = (text.substring(start, streamAt), s, e < s ? s : e);
    } else {
      out[n] = (text.substring(start, endObj), -1, -1);
    }
  }
  return out;
}

int? _ref(String dict, String key) {
  final m = RegExp('/$key\\s+(\\d+)\\s+0\\s+R').firstMatch(dict);
  return m == null ? null : int.parse(m[1]!);
}

int? _int(String dict, String key) {
  final m = RegExp('/$key\\s+(\\d+)').firstMatch(dict);
  return m == null ? null : int.parse(m[1]!);
}

/// Page object numbers in reading order (following /Pages /Kids).
List<int> _pages(Map<int, (String, int, int)> objs) {
  int? root;
  for (final value in objs.values) {
    if (RegExp(r'/Type\s*/Catalog').hasMatch(value.$1)) {
      root = _ref(value.$1, 'Pages');
      break;
    }
  }
  final out = <int>[];
  final seen = <int>{};
  void walk(int n) {
    if (!seen.add(n) || out.length > 5000) return;
    final d = objs[n]?.$1;
    if (d == null) return;
    if (RegExp(r'/Type\s*/Page\b(?!s)').hasMatch(d)) {
      out.add(n);
      return;
    }
    final kids = RegExp(r'/Kids\s*\[([^\]]*)\]').firstMatch(d)?[1] ?? '';
    for (final k in RegExp(r'(\d+)\s+0\s+R').allMatches(kids)) {
      walk(int.parse(k[1]!));
    }
  }

  if (root != null) walk(root);
  return out;
}

/// The image XObjects a page uses (directly or through its /Resources).
List<int> _pageImages(Map<int, (String, int, int)> objs, int page) {
  var res = objs[page]!.$1;
  final resRef = _ref(res, 'Resources');
  if (resRef != null) res = objs[resRef]?.$1 ?? res;
  var xobj = RegExp(r'/XObject\s*<<(.*?)>>', dotAll: true).firstMatch(res)?[1];
  final xRef = _ref(res, 'XObject');
  if (xobj == null && xRef != null) xobj = objs[xRef]?.$1;
  if (xobj == null) return const [];
  return [
    for (final m in RegExp(r'/[^\s/]+\s+(\d+)\s+0\s+R').allMatches(xobj))
      if (RegExp(r'/Subtype\s*/Image')
          .hasMatch(objs[int.parse(m[1]!)]?.$1 ?? ''))
        int.parse(m[1]!),
  ];
}

/// A BMP (bottom-up, 24-bit) from 8-bit gray or RGB samples.
Uint8List? _bmp(Uint8List samples, int w, int h, int channels) {
  if (samples.length < w * h * channels) return null;
  final row = ((w * 3 + 3) ~/ 4) * 4;
  final size = 54 + row * h;
  final out = ByteData(size);
  out
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, size, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, w, Endian.little)
    ..setInt32(22, h, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 24, Endian.little)
    ..setUint32(34, row * h, Endian.little);
  final bytes = out.buffer.asUint8List();
  for (var y = 0; y < h; y++) {
    final dst = 54 + (h - 1 - y) * row;
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * channels;
      final r = samples[i];
      final g = channels == 3 ? samples[i + 1] : r;
      final b = channels == 3 ? samples[i + 2] : r;
      bytes[dst + x * 3] = b;
      bytes[dst + x * 3 + 1] = g;
      bytes[dst + x * 3 + 2] = r;
    }
  }
  return bytes;
}

PdfPageImage? _image(Uint8List b, (String, int, int) obj, int page) {
  final (dict, start, end) = obj;
  if (start < 0 || end <= start || end - start > ocrMaxImageBytes) return null;
  final w = _int(dict, 'Width') ?? 0, h = _int(dict, 'Height') ?? 0;
  if (w < 32 || h < 32 || w > ocrMaxImageSide || h > ocrMaxImageSide) {
    return null;
  }
  final data = Uint8List.sublistView(b, start, end);
  if (dict.contains('/DCTDecode')) {
    // A JPEG: usable as is (if it is not also Flate-wrapped).
    return dict.contains('/FlateDecode')
        ? null
        : PdfPageImage(page, 'jpg', data);
  }
  if (dict.contains('/FlateDecode') &&
      (_int(dict, 'BitsPerComponent') ?? 8) == 8 &&
      !dict.contains('/DecodeParms')) {
    final channels = dict.contains('/DeviceRGB')
        ? 3
        : dict.contains('/DeviceGray')
        ? 1
        : 0;
    if (channels == 0 || w * h * channels > 120 * 1024 * 1024) return null;
    try {
      final raw = Uint8List.fromList(ZLibDecoder().convert(data));
      final bmp = _bmp(raw, w, h, channels);
      return bmp == null ? null : PdfPageImage(page, 'bmp', bmp);
    } catch (_) {
      return null;
    }
  }
  return null; // CCITT, JBIG2, JPX…: not readable here
}

/// The largest picture of each page (scans have one per page), in page
/// order; pages without a readable picture are left out.
List<PdfPageImage> pdfPageImages(Uint8List bytes) {
  try {
    final objs = _objects(bytes);
    final pages = _pages(objs);
    final out = <PdfPageImage>[];
    if (pages.isNotEmpty) {
      for (final (i, p) in pages.take(ocrMaxPages).indexed) {
        PdfPageImage? best;
        for (final n in _pageImages(objs, p)) {
          final img = _image(bytes, objs[n]!, i + 1);
          if (img != null &&
              (best == null || img.bytes.length > best.bytes.length)) {
            best = img;
          }
        }
        if (best != null) out.add(best);
      }
      return out;
    }
    // No page tree found (e.g. compressed object streams): images in order.
    for (final obj in objs.values) {
      if (out.length >= ocrMaxPages) break;
      if (!RegExp(r'/Subtype\s*/Image').hasMatch(obj.$1)) continue;
      final img = _image(bytes, obj, 0);
      if (img != null) out.add(img);
    }
    return out;
  } catch (_) {
    return const []; // damaged file: nothing to read
  }
}

List<PdfPageImage> _imagesOfFile(String path) {
  final f = File(path);
  if (f.lengthSync() > 120 * 1024 * 1024) return const [];
  return pdfPageImages(f.readAsBytesSync());
}

// --------------------------------------------------------------- engines --

/// Reads text from images on Windows with Windows.Media.Ocr.
class WindowsOcr {
  static const _script = r'''
param([string]$Path)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$type) {
  $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
  $null = $task.Wait(-1)
  $task.Result
}
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) { exit 3 }
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
$stream.Dispose()
foreach ($line in $result.Lines) { $line.Text }
''';

  static bool get available =>
      Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

  static File? _scriptFile;

  /// Text in the image file at [imagePath] ('' when none or on failure).
  static Future<String> recognizeFile(String imagePath) async {
    final script = _scriptFile ??= File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}theapp-ocr-v$ocrVersion.ps1',
    )..writeAsStringSync(_script);
    final proc = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      imagePath,
    ]);
    final out = proc.stdout.transform(utf8.decoder).join();
    unawaited(proc.stderr.drain<void>());
    final code = await proc.exitCode.timeout(
      ocrTimeoutPerPage,
      onTimeout: () {
        proc.kill();
        return -1;
      },
    );
    if (code != 0) return '';
    return (await out).trim();
  }
}

/// The text of each page of the scanned PDF at [path], recognised on this
/// device (null when OCR is not available here). Runs off the UI thread.
Future<List<String>?> ocrPdf(String path, {IosBridge? ios}) async {
  if (ios != null) return ios.ocrPdf(path, maxPages: ocrMaxPages);
  if (!WindowsOcr.available) return null;
  final images = await compute(_imagesOfFile, path);
  if (images.isEmpty) return const [];
  final dir = await Directory.systemTemp.createTemp('theapp-ocr-');
  final pages = <String>[];
  var total = 0;
  try {
    for (final img in images) {
      final f = File(
        '${dir.path}${Platform.pathSeparator}p${img.page}-${pages.length}.${img.extension}',
      );
      await f.writeAsBytes(img.bytes);
      var text = await WindowsOcr.recognizeFile(f.path);
      await f.delete();
      if (total + text.length > ocrMaxChars) {
        text = text.substring(0, (ocrMaxChars - total).clamp(0, text.length));
      }
      total += text.length;
      final page = img.page == 0 ? pages.length + 1 : img.page;
      while (pages.length < page - 1) {
        pages.add(''); // pages without a readable picture
      }
      pages.add(text);
      if (total >= ocrMaxChars) break;
    }
  } finally {
    await dir.delete(recursive: true).catchError((_) => dir);
  }
  return pages;
}
