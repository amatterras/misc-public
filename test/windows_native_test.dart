// Real-Windows checks for clipboard, image import and link previews.
//
// These touch the system clipboard and the network, so they only run when
// asked for:  set THEAPP_NATIVE_TESTS=1, then `flutter test test/windows_native_test.dart`
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/capture_service.dart';
import 'package:flutter_application_1/features/capture/link_preview.dart';
import 'package:flutter_application_1/platform/windows_native.dart';
import 'package:flutter_test/flutter_test.dart';

final enabled =
    Platform.isWindows && Platform.environment['THEAPP_NATIVE_TESTS'] == '1';

void ps(String script) {
  final r = Process.runSync('powershell', [
    '-NoProfile',
    '-STA',
    '-Command',
    script,
  ]);
  if (r.exitCode != 0) fail('PowerShell failed: ${r.stderr}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_native_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'a copied picture (bitmap) is read and imported as a PNG asset',
    () async {
      // A 3x2 opaque red picture, the way Paint or a screenshot tool copies it.
      ps(r'''
      Add-Type -AssemblyName System.Windows.Forms, System.Drawing
      $b = New-Object System.Drawing.Bitmap 3, 2
      $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::Red)
      [System.Windows.Forms.Clipboard]::SetImage($b)
    ''');
      final clip = readNativeClipboard();
      expect(
        clip.imageBytes,
        isNotNull,
        reason: 'no image found on the clipboard',
      );

      final ws = Workspace(dir);
      await ws.load();
      final asset = await CaptureService(
        ws,
        fetchPreviews: false,
      ).imageFromBytes(clip.imageBytes!, clip.imageExtension);
      expect(asset.width, 3);
      expect(asset.height, 2);
      final file = ws.attachments.fileFor(asset.file!);
      expect(file.path, endsWith('.png'));

      // The stored picture must still be opaque red (not blank/transparent).
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final frame = await codec.getNextFrame();
      final rgba = (await frame.image.toByteData())!;
      expect(
        [
          rgba.getUint8(0),
          rgba.getUint8(1),
          rgba.getUint8(2),
          rgba.getUint8(3),
        ],
        [255, 0, 0, 255],
      );
      ws.dispose();
    },
    skip: !enabled,
  );

  test('files copied in File Explorer are read from the clipboard', () {
    final f = File('${dir.path}${Platform.pathSeparator}photo.png')
      ..writeAsBytesSync([0]);
    ps("Set-Clipboard -Path '${f.path}'");
    final clip = readNativeClipboard();
    expect(clip.files, [f.path]);
    expect(ClipboardContent(files: clip.files).imageFiles, [f.path]);
  }, skip: !enabled);

  test('a real page title is fetched for a pasted link', () async {
    // flutter_test blocks real HTTP by default; allow it for this check.
    HttpOverrides.global = null;
    final preview = await LinkPreviewFetcher().fetch('https://example.com/');
    expect(preview?.title, 'Example Domain');
  }, skip: !enabled);
}
