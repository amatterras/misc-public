// Operating-system services used by the pages, picked per platform:
// Windows uses windows_native.dart (dart:ffi), iPhone/iPad the "theapp/ios"
// channel (ios_bridge.dart). Elsewhere they do nothing.
import 'dart:async';
import 'dart:io';

import 'ios_bridge.dart';
import 'windows_native.dart' as win;

export 'windows_native.dart'
    show
        NativeClipboard,
        flashMainWindow,
        focusMainWindow,
        openFolder,
        readNativeClipboard;

/// Opens an http(s)/mailto link in the browser or mail app.
bool openUrl(String url) =>
    Platform.isIOS ? IosBridge.instance.openUrl(url) : win.openUrl(url);

/// Lets the user choose photos; returns file paths (empty if cancelled).
FutureOr<List<String>> pickImageFiles() =>
    Platform.isIOS ? IosBridge.instance.pickImageFiles() : win.pickImageFiles();

/// Lets the user choose PDF documents.
FutureOr<List<String>> pickDocumentFiles() => Platform.isIOS
    ? IosBridge.instance.pickDocumentFiles()
    : Platform.isWindows
    ? win.pickDocumentFiles()
    : const <String>[];

/// Opens a stored document in its default app (iOS: Quick Look preview).
bool openDocument(String path) => Platform.isIOS
    ? IosBridge.instance.openDocument(path)
    : Platform.isWindows && win.openFileWithDefaultApp(path);

/// Whether this platform has a folder browser to show the data folder in.
bool get canOpenFolders => Platform.isWindows;
