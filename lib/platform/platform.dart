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

/// Lets the user choose a `.theappbackup` file to import.
FutureOr<List<String>> pickBackupFile() => Platform.isIOS
    ? IosBridge.instance.pickBackupFiles()
    : Platform.isWindows
    ? win.pickBackupFiles()
    : const <String>[];

/// Asks where to save a file (Windows "Save as"); null if cancelled.
/// Elsewhere there is no such dialog: callers save to the exports folder
/// and offer the share sheet (iPhone/iPad).
String? askSavePath({
  required String suggestedName,
  required String extension,
  required String typeLabel,
  String? initialDir,
}) => Platform.isWindows
    ? win.saveFileDialog(
        suggestedName: suggestedName,
        extension: extension,
        filterSpec: '$typeLabel\u0000*.$extension\u0000\u0000',
        dialogTitle: 'Save $typeLabel',
        initialDir: initialDir,
      )
    : null;

/// Whether [askSavePath] shows a dialog here.
bool get hasSaveDialog => Platform.isWindows;

/// Replaces [destination] with [source] after it has been fully written and
/// checked. Windows uses MoveFileExW with REPLACE_EXISTING; the other
/// dart:io targets use their same-volume rename operation.
Future<File> replaceFile(File source, File destination) async {
  if (Platform.isWindows) {
    win.replaceFileAtomically(source.path, destination.path);
    return destination;
  }
  return source.rename(destination.path);
}

/// Lets the user choose .ics calendar files (Windows only for now).
List<String> pickCalendarFiles() =>
    Platform.isWindows ? win.pickCalendarFiles() : const <String>[];

/// Puts an image on the system clipboard (Windows; iPhone/iPad copy
/// through the share sheet instead). [rgba] is width×height×4 raw pixels;
/// [png] the same image encoded, for apps that paste PNG.
bool copyImageToClipboard({
  required Uint8List rgba,
  required int width,
  required int height,
  Uint8List? png,
}) =>
    Platform.isWindows &&
    win.writeClipboardImage(rgba: rgba, width: width, height: height, png: png);

/// Whether [copyImageToClipboard] works here.
bool get canCopyImages => Platform.isWindows;

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
    // Only the status bar is hidden (through the Flutter view controller's
    // prefersStatusBarHidden); the home indicator and the system edge
    // gestures stay. The OS decides in Split View / Stage Manager.
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: on ? const [SystemUiOverlay.bottom] : SystemUiOverlay.values,
      ),
    );
    return true;
  }
  return false;
}
