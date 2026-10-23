// Minimal direct bindings to a few Windows functions, via dart:ffi.
//
// We call Windows directly instead of using Flutter plugins because plugins
// require Windows Developer Mode to be enabled on this PC. Every function
// here is a no-op (returns null/empty) on other platforms.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _OpenFileNameW extends Struct {
  @Uint32()
  external int lStructSize;
  @IntPtr()
  external int hwndOwner;
  @IntPtr()
  external int hInstance;
  external Pointer<Utf16> lpstrFilter;
  external Pointer<Utf16> lpstrCustomFilter;
  @Uint32()
  external int nMaxCustFilter;
  @Uint32()
  external int nFilterIndex;
  external Pointer<Utf16> lpstrFile;
  @Uint32()
  external int nMaxFile;
  external Pointer<Utf16> lpstrFileTitle;
  @Uint32()
  external int nMaxFileTitle;
  external Pointer<Utf16> lpstrInitialDir;
  external Pointer<Utf16> lpstrTitle;
  @Uint32()
  external int Flags;
  @Uint16()
  external int nFileOffset;
  @Uint16()
  external int nFileExtension;
  external Pointer<Utf16> lpstrDefExt;
  @IntPtr()
  external int lCustData;
  external Pointer<Void> lpfnHook;
  external Pointer<Utf16> lpTemplateName;
  external Pointer<Void> pvReserved;
  @Uint32()
  external int dwReserved;
  @Uint32()
  external int FlagsEx;
}

class _Win {
  _Win() {
    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final shell32 = DynamicLibrary.open('shell32.dll');
    final comdlg32 = DynamicLibrary.open('comdlg32.dll');
    openClipboard = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'OpenClipboard',
        );
    closeClipboard = user32.lookupFunction<Int32 Function(), int Function()>(
      'CloseClipboard',
    );
    isFormatAvailable = user32
        .lookupFunction<Int32 Function(Uint32), int Function(int)>(
          'IsClipboardFormatAvailable',
        );
    getClipboardData = user32
        .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
          'GetClipboardData',
        );
    registerFormat = user32
        .lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)
        >('RegisterClipboardFormatW');
    showWindow = user32
        .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
          'ShowWindow',
        );
    setForegroundWindow = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'SetForegroundWindow',
        );
    setWindowPos = user32
        .lookupFunction<
          Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int)
        >('SetWindowPos');
    flashWindow = user32
        .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
          'FlashWindow',
        );
    findWindow = user32
        .lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowW');
    globalLock = kernel32
        .lookupFunction<
          Pointer<Uint8> Function(IntPtr),
          Pointer<Uint8> Function(int)
        >('GlobalLock');
    globalUnlock = kernel32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'GlobalUnlock',
        );
    globalSize = kernel32
        .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
          'GlobalSize',
        );
    dragQueryFile = shell32
        .lookupFunction<
          Uint32 Function(IntPtr, Uint32, Pointer<Utf16>, Uint32),
          int Function(int, int, Pointer<Utf16>, int)
        >('DragQueryFileW');
    shellExecute = shell32
        .lookupFunction<
          IntPtr Function(
            IntPtr,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Int32,
          ),
          int Function(
            int,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            Pointer<Utf16>,
            int,
          )
        >('ShellExecuteW');
    getOpenFileName = comdlg32
        .lookupFunction<
          Int32 Function(Pointer<_OpenFileNameW>),
          int Function(Pointer<_OpenFileNameW>)
        >('GetOpenFileNameW');
  }

  late final int Function(int) openClipboard;
  late final int Function() closeClipboard;
  late final int Function(int) isFormatAvailable;
  late final int Function(int) getClipboardData;
  late final int Function(Pointer<Utf16>) registerFormat;
  late final int Function(Pointer<Utf16>, Pointer<Utf16>) findWindow;
  late final int Function(int, int) showWindow;
  late final int Function(int) setForegroundWindow;
  late final int Function(int, int) flashWindow;
  late final int Function(int, int, int, int, int, int, int) setWindowPos;
  late final Pointer<Uint8> Function(int) globalLock;
  late final int Function(int) globalUnlock;
  late final int Function(int) globalSize;
  late final int Function(int, int, Pointer<Utf16>, int) dragQueryFile;
  late final int Function(
    int,
    Pointer<Utf16>,
    Pointer<Utf16>,
    Pointer<Utf16>,
    Pointer<Utf16>,
    int,
  )
  shellExecute;
  late final int Function(Pointer<_OpenFileNameW>) getOpenFileName;
}

_Win? _winInstance;
_Win? get _win {
  if (!Platform.isWindows) return null;
  return _winInstance ??= _Win();
}

const _cfDib = 8;
const _cfHdrop = 15;
const _cfDibV5 = 17;

/// Image and file data found on the Windows clipboard.
class NativeClipboard {
  const NativeClipboard({
    this.imageBytes,
    this.imageExtension = 'png',
    this.files = const [],
  });

  /// Encoded image (PNG, or BMP converted from a bitmap).
  final Uint8List? imageBytes;
  final String imageExtension;

  /// Files copied in File Explorer.
  final List<String> files;
}

/// Reads images and copied files from the clipboard (text is read through
/// Flutter's own clipboard API).
NativeClipboard readNativeClipboard() {
  final w = _win;
  if (w == null) return const NativeClipboard();
  var opened = false;
  for (var i = 0; i < 5 && !opened; i++) {
    opened = w.openClipboard(0) != 0;
    if (!opened) sleep(const Duration(milliseconds: 20));
  }
  if (!opened) return const NativeClipboard();
  try {
    final files = <String>[];
    if (w.isFormatAvailable(_cfHdrop) != 0) {
      final drop = w.getClipboardData(_cfHdrop);
      if (drop != 0) {
        final count = w.dragQueryFile(drop, 0xFFFFFFFF, nullptr, 0);
        final buffer = calloc<Uint16>(1024).cast<Utf16>();
        for (var i = 0; i < count; i++) {
          w.dragQueryFile(drop, i, buffer, 1024);
          files.add(buffer.toDartString());
        }
        calloc.free(buffer);
      }
    }
    final pngName = 'PNG'.toNativeUtf16();
    final pngFormat = w.registerFormat(pngName);
    calloc.free(pngName);
    if (pngFormat != 0 && w.isFormatAvailable(pngFormat) != 0) {
      final bytes = _readGlobal(w, pngFormat);
      if (bytes != null) {
        return NativeClipboard(imageBytes: bytes, files: files);
      }
    }
    for (final format in [_cfDibV5, _cfDib]) {
      if (w.isFormatAvailable(format) == 0) continue;
      final dib = _readGlobal(w, format);
      if (dib != null) {
        return NativeClipboard(
          imageBytes: dibToBmp(dib),
          imageExtension: 'bmp',
          files: files,
        );
      }
    }
    return NativeClipboard(files: files);
  } finally {
    w.closeClipboard();
  }
}

Uint8List? _readGlobal(_Win w, int format) {
  final handle = w.getClipboardData(format);
  if (handle == 0) return null;
  final size = w.globalSize(handle);
  final ptr = w.globalLock(handle);
  if (ptr == nullptr || size <= 0) return null;
  try {
    return Uint8List.fromList(ptr.asTypedList(size));
  } finally {
    w.globalUnlock(handle);
  }
}

/// Wraps a clipboard device-independent bitmap in a .bmp file header.
Uint8List dibToBmp(Uint8List dib) {
  final data = ByteData.sublistView(dib);
  final headerSize = data.getUint32(0, Endian.little);
  final bitCount = data.getUint16(14, Endian.little);
  final compression = data.getUint32(16, Endian.little);
  var colors = data.getUint32(32, Endian.little);
  if (colors == 0 && bitCount <= 8) colors = 1 << bitCount;
  var offset = 14 + headerSize + colors * 4;
  if (headerSize == 40 && compression == 3) offset += 12; // BI_BITFIELDS
  final out = BytesBuilder()
    ..add([0x42, 0x4D])
    ..add(_u32(14 + dib.length))
    ..add([0, 0, 0, 0])
    ..add(_u32(offset))
    ..add(dib);
  return out.toBytes();
}

List<int> _u32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

/// Shows the standard Windows "Open" dialog for images. Returns the chosen
/// paths (empty if cancelled).
List<String> pickImageFiles() => _pickFiles(
  'Images\u0000*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp\u0000All files\u0000*.*\u0000\u0000',
  'Add photos to THEapp',
);

/// The same dialog for PDF documents.
List<String> pickDocumentFiles() =>
    _pickFiles('PDF documents\u0000*.pdf\u0000\u0000', 'Add PDFs to THEapp');

List<String> _pickFiles(String filterSpec, String dialogTitle) {
  final w = _win;
  if (w == null) return const [];
  const bufferChars = 32768;
  final ofn = calloc<_OpenFileNameW>();
  final buffer = calloc<Uint16>(bufferChars);
  final filter = filterSpec.toNativeUtf16();
  final title = dialogTitle.toNativeUtf16();
  final windowClass = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  try {
    ofn.ref
      ..lStructSize = sizeOf<_OpenFileNameW>()
      ..hwndOwner = w.findWindow(windowClass, nullptr)
      ..lpstrFilter = filter
      ..lpstrFile = buffer.cast()
      ..nMaxFile = bufferChars
      ..lpstrTitle = title
      // EXPLORER | ALLOWMULTISELECT | FILEMUSTEXIST | PATHMUSTEXIST | NOCHANGEDIR
      ..Flags = 0x80000 | 0x200 | 0x1000 | 0x800 | 0x8;
    if (w.getOpenFileName(ofn) == 0) return const [];
    final parts = <String>[];
    var start = 0;
    final units = buffer.asTypedList(bufferChars);
    for (var i = 0; i < bufferChars; i++) {
      if (units[i] != 0) continue;
      if (i == start) break; // double terminator
      parts.add(String.fromCharCodes(units.sublist(start, i)));
      start = i + 1;
    }
    if (parts.length <= 1) return parts;
    final dir = parts.first;
    return [for (final name in parts.skip(1)) '$dir\\$name'];
  } finally {
    calloc
      ..free(ofn)
      ..free(buffer)
      ..free(filter)
      ..free(title)
      ..free(windowClass);
  }
}

/// Opens a web link in the default browser. Only http(s) and mailto links
/// are allowed, so a stored "link" can never launch a program.
bool openUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !(uri.isScheme('http') ||
          uri.isScheme('https') ||
          uri.isScheme('mailto'))) {
    return false;
  }
  final w = _win;
  if (w == null) return false;
  final op = 'open'.toNativeUtf16();
  final file = uri.toString().toNativeUtf16();
  try {
    return w.shellExecute(0, op, file, nullptr, nullptr, 1) > 32;
  } finally {
    calloc
      ..free(op)
      ..free(file);
  }
}

/// Opens a stored document (e.g. a PDF) in its default app. Callers pass
/// only files from THEapp's own attachments folder (`Workspace.documentFile`).
bool openFileWithDefaultApp(String path) {
  final w = _win;
  if (w == null || !File(path).existsSync()) return false;
  final op = 'open'.toNativeUtf16();
  final file = path.toNativeUtf16();
  try {
    return w.shellExecute(0, op, file, nullptr, nullptr, 1) > 32;
  } finally {
    calloc
      ..free(op)
      ..free(file);
  }
}

/// Restores THEapp's window and brings it to the front.
void focusMainWindow() {
  final w = _win;
  if (w == null) return;
  final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final title = 'THEapp'.toNativeUtf16();
  try {
    final hwnd = w.findWindow(cls, title);
    if (hwnd == 0) return;
    w.showWindow(hwnd, 9); // SW_RESTORE
    w.setForegroundWindow(hwnd);
  } finally {
    calloc
      ..free(cls)
      ..free(title);
  }
}

/// Flashes THEapp's taskbar button once to draw attention (e.g. a task
/// reminder came due while the window is in the background).
void flashMainWindow() {
  final w = _win;
  if (w == null) return;
  final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final title = 'THEapp'.toNativeUtf16();
  try {
    final hwnd = w.findWindow(cls, title);
    if (hwnd != 0) w.flashWindow(hwnd, 1);
  } finally {
    calloc
      ..free(cls)
      ..free(title);
  }
}

/// Keeps THEapp's window above other windows (or stops doing so).
/// Returns false if the window was not found.
bool setMainWindowTopmost(bool topmost) {
  final w = _win;
  if (w == null) return false;
  final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final title = 'THEapp'.toNativeUtf16();
  try {
    final hwnd = w.findWindow(cls, title);
    if (hwnd == 0) return false;
    // HWND_TOPMOST = -1, HWND_NOTOPMOST = -2;
    // SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE.
    return w.setWindowPos(
          hwnd,
          topmost ? -1 : -2,
          0,
          0,
          0,
          0,
          0x1 | 0x2 | 0x10,
        ) !=
        0;
  } finally {
    calloc
      ..free(cls)
      ..free(title);
  }
}

/// Opens a folder in File Explorer.
void openFolder(String path) {
  if (Platform.isWindows) Process.start('explorer.exe', [path]);
}

final class _BrowseInfoW extends Struct {
  @IntPtr()
  external int hwndOwner;
  external Pointer<Void> pidlRoot;
  external Pointer<Utf16> pszDisplayName;
  external Pointer<Utf16> lpszTitle;
  @Uint32()
  external int ulFlags;
  external Pointer<Void> lpfn;
  @IntPtr()
  external int lParam;
  @Int32()
  external int iImage;
}

/// Lets the user choose a folder (Windows' own folder dialog). Null if
/// cancelled or not on Windows.
String? pickFolder(String title) {
  final w = _win;
  if (w == null) return null;
  final shell32 = DynamicLibrary.open('shell32.dll');
  final ole32 = DynamicLibrary.open('ole32.dll');
  final browse = shell32
      .lookupFunction<
        Pointer<Void> Function(Pointer<_BrowseInfoW>),
        Pointer<Void> Function(Pointer<_BrowseInfoW>)
      >('SHBrowseForFolderW');
  final pathOf = shell32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf16>),
        int Function(Pointer<Void>, Pointer<Utf16>)
      >('SHGetPathFromIDListW');
  final free = ole32
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CoTaskMemFree');
  final info = calloc<_BrowseInfoW>();
  final name = calloc<Uint16>(260).cast<Utf16>();
  final path = calloc<Uint16>(1024).cast<Utf16>();
  final caption = title.toNativeUtf16();
  final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  try {
    info.ref
      ..hwndOwner = w.findWindow(cls, nullptr)
      ..pszDisplayName = name
      ..lpszTitle = caption
      // BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE
      ..ulFlags = 0x1 | 0x40;
    final pidl = browse(info);
    if (pidl == nullptr) return null;
    try {
      return pathOf(pidl, path) != 0 ? path.toDartString() : null;
    } finally {
      free(pidl);
    }
  } finally {
    calloc
      ..free(info)
      ..free(name)
      ..free(path)
      ..free(caption)
      ..free(cls);
  }
}
