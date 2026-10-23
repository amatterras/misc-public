// Text from PDF files, in pure Dart, on this device only. Reads the page
// content streams (uncompressed or Flate), the text-showing operators
// (Tj, TJ, ' and ") and the fonts' ToUnicode maps. Scanned PDFs (images
// of text) give no text: that needs OCR, which this app does not have.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Largest PDF read, and most text kept from one.
const maxPdfBytes = 60 * 1024 * 1024;
const maxPdfTextChars = 2000000;

/// The text of the PDF in [bytes] ('' when none can be read).
String pdfText(Uint8List bytes) {
  if (bytes.length > maxPdfBytes || !_startsWith(bytes, 0, '%PDF')) return '';
  final streams = <Uint8List>[];
  var at = 0;
  while (true) {
    final s = _indexOf(bytes, 'stream', at);
    if (s < 0) break;
    // "endstream" also contains "stream".
    if (s >= 3 && _startsWith(bytes, s - 3, 'end')) {
      at = s + 6;
      continue;
    }
    var start = s + 6;
    if (start < bytes.length && bytes[start] == 13) start++;
    if (start < bytes.length && bytes[start] == 10) start++;
    final end = _indexOf(bytes, 'endstream', start);
    if (end < 0) break;
    final dictStart = _lastIndexOf(bytes, '<<', s);
    final dict = dictStart < 0
        ? ''
        : latin1.decode(bytes.sublist(dictStart, s), allowInvalid: true);
    at = end + 9;
    if (dict.contains('/Image') || dict.contains('/FontFile')) continue;
    var data = Uint8List.sublistView(bytes, start, end);
    if (dict.contains('/FlateDecode')) {
      try {
        data = _inflate(data);
      } catch (_) {
        continue; // damaged or another filter: skip it
      }
    } else if (dict.contains('/Filter')) {
      continue; // other filters (DCT, LZW …) are not text
    }
    streams.add(data);
  }
  final cmap = <int, String>{};
  for (final s in streams) {
    final text = latin1.decode(s, allowInvalid: true);
    if (text.contains('begincmap')) _readCMap(text, cmap);
  }
  final out = StringBuffer();
  for (final s in streams) {
    final text = latin1.decode(s, allowInvalid: true);
    if (text.contains('begincmap') || !text.contains('T')) continue;
    _readContent(text, cmap, out);
    if (out.length > maxPdfTextChars) break;
  }
  final result = out
      .toString()
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n+'), '\n')
      .trim();
  return result.length > maxPdfTextChars
      ? result.substring(0, maxPdfTextChars)
      : result;
}

bool _startsWith(Uint8List b, int at, String s) {
  if (at < 0 || at + s.length > b.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[at + i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

int _indexOf(Uint8List b, String s, int from) {
  final first = s.codeUnitAt(0);
  for (var i = from; i <= b.length - s.length; i++) {
    if (b[i] == first && _startsWith(b, i, s)) return i;
  }
  return -1;
}

int _lastIndexOf(Uint8List b, String s, int before) {
  for (var i = before - s.length; i >= 0 && i > before - 4096; i--) {
    if (_startsWith(b, i, s)) return i;
  }
  return -1;
}

String _utf16Hex(String hex) {
  final units = <int>[
    for (var i = 0; i + 4 <= hex.length; i += 4)
      int.parse(hex.substring(i, i + 4), radix: 16),
  ];
  if (units.isEmpty && hex.length == 2) {
    units.add(int.parse(hex, radix: 16));
  }
  return String.fromCharCodes(units);
}

/// bfchar and bfrange entries of a ToUnicode map. All fonts' maps share
/// one table: good enough for search, not for exact layout.
void _readCMap(String text, Map<int, String> cmap) {
  for (final m in RegExp(
    r'beginbfchar(.*?)endbfchar',
    dotAll: true,
  ).allMatches(text)) {
    for (final p in RegExp(
      r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>',
    ).allMatches(m[1]!)) {
      cmap[int.parse(p[1]!, radix: 16)] = _utf16Hex(p[2]!);
    }
  }
  for (final m in RegExp(
    r'beginbfrange(.*?)endbfrange',
    dotAll: true,
  ).allMatches(text)) {
    for (final p in RegExp(
      r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
    ).allMatches(m[1]!)) {
      final lo = int.parse(p[1]!, radix: 16);
      final hi = int.parse(p[2]!, radix: 16);
      final base = int.parse(p[3]!, radix: 16);
      if (hi < lo || hi - lo > 65535) continue;
      for (var c = lo; c <= hi; c++) {
        cmap[c] = String.fromCharCode(base + c - lo);
      }
    }
  }
}

/// Literal string `(…)` starting at [i] (just after the parenthesis).
(String, int) _literal(String s, int i) {
  final b = StringBuffer();
  var depth = 1;
  while (i < s.length) {
    final c = s[i];
    if (c == '\\' && i + 1 < s.length) {
      final n = s[i + 1];
      i += 2;
      switch (n) {
        case 'n':
          b.write('\n');
        case 'r' || 't' || 'b' || 'f':
          b.write(' ');
        case '\n' || '\r':
          break;
        default:
          if (_octal.hasMatch(n)) {
            var oct = n;
            while (oct.length < 3 && i < s.length && _octal.hasMatch(s[i])) {
              oct += s[i++];
            }
            b.writeCharCode(int.parse(oct, radix: 8));
          } else {
            b.write(n);
          }
      }
      continue;
    }
    if (c == '(') depth++;
    if (c == ')' && --depth == 0) return (b.toString(), i + 1);
    b.write(c);
    i++;
  }
  return (b.toString(), i);
}

String _hexText(String hex, Map<int, String> cmap) {
  hex = hex.replaceAll(RegExp(r'\s'), '');
  if (hex.length.isOdd) hex += '0';
  // Two-byte codes when a map knows them, else one byte per character.
  if (cmap.isNotEmpty && hex.length % 4 == 0) {
    final b = StringBuffer();
    var known = 0;
    for (var i = 0; i < hex.length; i += 4) {
      final code = int.parse(hex.substring(i, i + 4), radix: 16);
      final t = cmap[code];
      if (t != null) known++;
      b.write(t ?? '');
    }
    if (known > 0) return b.toString();
  }
  final b = StringBuffer();
  for (var i = 0; i + 2 <= hex.length; i += 2) {
    final code = int.parse(hex.substring(i, i + 2), radix: 16);
    b.write(cmap[code] ?? String.fromCharCode(code));
  }
  return b.toString();
}

String _mapLiteral(String raw, Map<int, String> cmap) {
  if (cmap.isEmpty) return raw;
  final b = StringBuffer();
  for (final c in raw.codeUnits) {
    b.write(cmap[c] ?? String.fromCharCode(c));
  }
  return b.toString();
}

/// Writes the text shown by a content stream.
void _readContent(String s, Map<int, String> cmap, StringBuffer out) {
  final pending = <String>[];
  var i = 0;
  var inText = false;
  while (i < s.length) {
    final c = s[i];
    if (c == '(') {
      final (t, next) = _literal(s, i + 1);
      pending.add(_mapLiteral(t, cmap));
      i = next;
    } else if (c == '<' && i + 1 < s.length && s[i + 1] != '<') {
      final end = s.indexOf('>', i);
      if (end < 0) break;
      pending.add(_hexText(s.substring(i + 1, end), cmap));
      i = end + 1;
    } else if (c == '[') {
      i++;
    } else if (c == ']') {
      // A large negative kerning in TJ is a word gap.
      i++;
    } else if (_opChar.hasMatch(c)) {
      var j = i;
      while (j < s.length && _opChar.hasMatch(s[j])) {
        j++;
      }
      final op = s.substring(i, j);
      switch (op) {
        case 'BT':
          inText = true;
        case 'ET':
          inText = false;
          out.write('\n');
        case 'Tj' || 'TJ':
          if (inText) out.write(pending.join());
          if (op == 'TJ') out.write(' ');
        case "'" || '"':
          out.write('\n${pending.join()}');
        case 'Td' || 'TD' || 'T*' || 'Tm':
          if (inText) out.write(op == 'Tm' ? ' ' : '\n');
      }
      pending.clear();
      i = j;
    } else if (c == '%') {
      final end = s.indexOf('\n', i);
      i = end < 0 ? s.length : end + 1;
    } else {
      // Numbers (TJ spacing) between parts of a word: a big gap is a space.
      if (c == '-' && pending.isNotEmpty) {
        final m = RegExp(r'-(\d{3,})').matchAsPrefix(s, i);
        if (m != null && int.parse(m[1]!) > 180) pending.add(' ');
      }
      i++;
    }
  }
}

final _opChar = RegExp(r'[A-Za-z\x27"*]');
final _octal = RegExp(r'[0-7]');

/// Most bytes one stream may expand to (a tiny stream can unpack to
/// gigabytes in a malicious file).
const maxInflatedBytes = 32 * 1024 * 1024;

Uint8List _inflate(Uint8List data) {
  final out = _CappedSink();
  final sink = ZLibDecoder().startChunkedConversion(out);
  for (var i = 0; i < data.length; i += 64 * 1024) {
    sink.add(
      Uint8List.sublistView(data, i, (i + 64 * 1024).clamp(0, data.length)),
    );
  }
  sink.close();
  return out.bytes.takeBytes();
}

class _CappedSink implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    bytes.add(chunk);
    if (bytes.length > maxInflatedBytes) {
      throw const FormatException('PDF stream too large');
    }
  }

  @override
  void close() {}
}
