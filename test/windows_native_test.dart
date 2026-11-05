// Real-Windows checks for clipboard, image import and link previews.
//
// They use the REAL system clipboard (that is what is being tested), so each
// test first saves whatever is on it (text, a picture or copied files) and
// puts it back afterwards; the clipboard is briefly replaced while a test
// runs. Link previews are tested against a small local web server, so no
// internet is needed. They run on Windows only: the clipboard code is
// Windows-specific.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/capture_service.dart';
import 'package:flutter_application_1/features/capture/link_preview.dart';
import 'package:flutter_application_1/platform/windows_native.dart';
import 'package:flutter_test/flutter_test.dart';

const _why = 'The clipboard code under test exists only on Windows';
final enabled = Platform.isWindows;

void ps(String script) {
  final r = Process.runSync('powershell', [
    '-NoProfile',
    '-STA',
    '-Command',
    script,
  ]);
  if (r.exitCode != 0) fail('PowerShell failed: ${r.stderr}');
}

/// What was on the clipboard before a test, so it can be put back.
class ClipboardBackup {
  ClipboardBackup._(this.kind, this.file);
  final String kind; // none | text | image | files
  final File? file;

  static ClipboardBackup take(Directory dir) {
    final out = File('${dir.path}${Platform.pathSeparator}clipboard.backup');
    final r = Process.runSync('powershell', [
      '-NoProfile',
      '-STA',
      '-Command',
      '''
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
\$out = '${out.path.replaceAll("'", "''")}'
\$d = [System.Windows.Forms.Clipboard]::GetDataObject()
if (\$d -eq \$null) { 'none'; return }
if (\$d.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
  (\$d.GetData([System.Windows.Forms.DataFormats]::FileDrop) -join "`n") | Set-Content -LiteralPath \$out -Encoding UTF8
  'files'
} elseif (\$d.GetDataPresent([System.Windows.Forms.DataFormats]::Bitmap)) {
  \$img = [System.Windows.Forms.Clipboard]::GetImage()
  \$img.Save(\$out, [System.Drawing.Imaging.ImageFormat]::Png)
  'image'
} elseif (\$d.GetDataPresent([System.Windows.Forms.DataFormats]::UnicodeText)) {
  [System.IO.File]::WriteAllText(\$out, [System.Windows.Forms.Clipboard]::GetText(), [System.Text.Encoding]::UTF8)
  'text'
} else { 'none' }
''',
    ]);
    final kind = '${r.stdout}'.trim().split('\n').last.trim();
    return ClipboardBackup._(
      const {'files', 'image', 'text'}.contains(kind) ? kind : 'none',
      out,
    );
  }

  void restore() {
    final f = file!.path.replaceAll("'", "''");
    final script = switch (kind) {
      'files' =>
        "Set-Clipboard -Path (Get-Content -LiteralPath '$f' -Encoding UTF8)",
      'image' =>
        "Add-Type -AssemblyName System.Windows.Forms, System.Drawing; "
            "[System.Windows.Forms.Clipboard]::SetImage("
            "[System.Drawing.Image]::FromFile('$f'))",
      'text' =>
        "Add-Type -AssemblyName System.Windows.Forms; "
            "[System.Windows.Forms.Clipboard]::SetText("
            "[System.IO.File]::ReadAllText('$f', [System.Text.Encoding]::UTF8))",
      _ =>
        'Add-Type -AssemblyName System.Windows.Forms; '
            '[System.Windows.Forms.Clipboard]::Clear()',
    };
    Process.runSync('powershell', ['-NoProfile', '-STA', '-Command', script]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  ClipboardBackup? backup;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('theapp_native_');
    backup = enabled ? ClipboardBackup.take(dir) : null;
  });
  tearDown(() {
    backup?.restore();
    dir.deleteSync(recursive: true);
  });

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
    skip: enabled ? false : _why,
  );

  test('files copied in File Explorer are read from the clipboard', () {
    final f = File('${dir.path}${Platform.pathSeparator}photo.png')
      ..writeAsBytesSync([0]);
    ps("Set-Clipboard -Path '${f.path}'");
    final clip = readNativeClipboard();
    expect(clip.files, [f.path]);
    expect(ClipboardContent(files: clip.files).imageFiles, [f.path]);
  }, skip: enabled ? false : _why);

  test(
    'a page title is fetched for a pasted link (local web server)',
    () async {
      // flutter_test blocks real HTTP by default; this check talks to a small
      // server on this PC, so it needs no internet.
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        r.response.headers.contentType = ContentType.html;
        r.response.write(
          '<html><head><title>Example Domain</title></head><body>hi</body></html>',
        );
        await r.response.close();
      });
      final preview = await LinkPreviewFetcher(isAllowed: (_) async => true)
          .fetch('http://127.0.0.1:${server.port}/');
      expect(preview?.title, 'Example Domain');
    },
  );
}
