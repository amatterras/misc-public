// Operating-system services used by the pages, picked per platform:
// Windows uses windows_native.dart (dart:ffi), iPhone/iPad the "theapp/ios"
// channel (ios_bridge.dart). Elsewhere they do nothing.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'ios_bridge.dart';
import 'windows_native.dart' as win;

export 'windows_native.dart'
    show
        NativeClipboard,
        flashMainWindow,
        focusMainWindow,
        pickFolder,
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

/// Lets the user choose .ics calendar files (Windows only for now).
List<String> pickCalendarFiles() =>
    Platform.isWindows ? win.pickCalendarFiles() : const <String>[];

/// Opens a stored document in its default app (iOS: Quick Look preview).
bool openDocument(String path) => Platform.isIOS
    ? IosBridge.instance.openDocument(path)
    : Platform.isWindows && win.openFileWithDefaultApp(path);

/// Whether this platform has a folder browser to show the data folder in.
bool get canOpenFolders => Platform.isWindows;

/// Whether THEapp's window can be kept above other windows here (Windows
/// only; iPhone/iPad apps cannot float over other apps).
bool get supportsAlwaysOnTop => Platform.isWindows;

/// Keeps THEapp's window above other windows, or stops; false if this
/// platform cannot or the window was not found.
bool setAlwaysOnTop(bool on) =>
    Platform.isWindows && win.setMainWindowTopmost(on);

/// Full screen without system bars where the OS allows it: Windows hides
/// the window frame; iPhone/iPad hide the status bar (the home indicator
/// stays, as iOS requires). Never touches the window during tests.
bool setImmersive(bool on) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
  if (Platform.isWindows) return win.setMainWindowFullScreen(on);
  if (Platform.isIOS) {
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
    );
    return true;
  }
  return false;
}
