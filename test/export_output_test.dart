// Exports checked on their actual output: the PNG is decoded and its
// pixels looked at (a photo never shown on screen is in the picture, not a
// placeholder), the size limit holds, files are written completely, the
// Save dialog's cancel saves nothing, and the view-only web page is parsed
// (escaped, no scripts, a security policy, attachments included or named).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/export/exports.dart';
import 'package:flutter_application_1/platform/platform.dart' as native;
import 'package:flutter_test/flutter_test.dart';

/// A solid-colour PNG of [w]×[h].
Future<Uint8List> solidPng(Color color, {int w = 40, int h = 40}) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// The decoded picture: size and the colour at (x, y).
Future<({int width, int height, Color Function(int x, int y) at})> decode(
  Uint8List png,
) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final w = image.width, h = image.height;
  image.dispose();
  codec.dispose();
  return (
    width: w,
    height: h,
    at: (int x, int y) {
      final i = (y * w + x) * 4;
      return Color.fromARGB(
        rgba.getUint8(i + 3),
        rgba.getUint8(i),
        rgba.getUint8(i + 1),
        rgba.getUint8(i + 2),
      );
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState s;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_export_');
    final ws = Workspace(Directory('${dir.path}/data'));
    s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await s.init();
    hasExportDialog = false;
    askExportPath = native.askSavePath;
    replaceExportFile = native.replaceFile;
  });
  tearDown(() async {
    await s.flush();
    s.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    askExportPath = native.askSavePath;
    replaceExportFile = native.replaceFile;
    hasExportDialog = false;
  });

  Directory out() => Directory('${dir.path}/out');

  test('a photo never shown on screen is in the picture', () async {
    final c = s.canvas!;
    c.selectAll();
    c.deleteSelection();
    final red = await s.workspace.imageAssetFromBytes(
      await solidPng(const Color(0xFFFF0000)),
      'png',
    );
    c.insertImage(red, const Offset(0, 0), maxSide: 200);
    final r = (await exportCanvasPicture(s, c, to: out()))!;
    expect(r.missingImages, 0);
    final png = await decode(await r.file.readAsBytes());
    final centre = png.at(png.width ~/ 2, png.height ~/ 2);
    expect(centre, const Color(0xFFFF0000)); // the photo, not a placeholder
    expect(
      Directory(out().path).listSync().where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
  });

  test('a huge mindmap stays within the size limit', () async {
    final c = s.canvas!;
    c.addItems([
      TextItem(
        id: 'a',
        position: Offset.zero,
        width: 200,
        minHeight: 40,
        text: 'A',
      ),
      TextItem(
        id: 'b',
        position: const Offset(200000, 50000),
        width: 200,
        minHeight: 40,
        text: 'B',
      ),
    ]);
    final r = (await exportCanvasPicture(s, c, to: out()))!;
    final png = await decode(await r.file.readAsBytes());
    expect(png.width, lessThanOrEqualTo(2400));
    expect(png.height, greaterThanOrEqualTo(1));
  });

  test(
    'a photo whose file is gone is counted, the export still works',
    () async {
      final c = s.canvas!;
      final photo = await s.workspace.imageAssetFromBytes(
        await solidPng(const Color(0xFF00FF00)),
        'png',
      );
      s.workspace.attachments.fileFor(photo.file!).deleteSync();
      c.insertImage(photo, const Offset(0, 0));
      final r = (await exportCanvasPicture(s, c, to: out()))!;
      expect(r.missingImages, 1);
      await checkPicture(await r.file.readAsBytes());
    },
  );

  test('a picture that would not open is refused before saving', () async {
    await expectLater(
      checkPicture(Uint8List.fromList([1, 2, 3, 4])),
      throwsA(isA<ExportFailure>()),
    );
  });

  test('Save dialog: cancel saves nothing; a chosen path is used', () async {
    final c = s.canvas!;
    c.addItems([
      TextItem(
        id: 't',
        position: Offset.zero,
        width: 200,
        minHeight: 40,
        text: 'Hi',
      ),
    ]);
    hasExportDialog = true;
    String? answer;
    final queue = <String?>[]; // answers consumed first, then [answer]
    var asked = 0;
    askExportPath =
        ({
          required suggestedName,
          required extension,
          required typeLabel,
          initialDir,
        }) {
          expect(suggestedName, endsWith('.$extension'));
          asked++;
          return queue.isNotEmpty ? queue.removeAt(0) : answer;
        };
    await exportCanvasFromMenu(s, c, web: false);
    expect(s.toast.value, 'Export cancelled. Nothing was saved.');
    expect(out().existsSync(), isFalse);

    // An existing file at the chosen path is replaced completely.
    final chosen = File('${dir.path}/chosen/My map.png')
      ..createSync(recursive: true)
      ..writeAsStringSync('old contents that are longer than nothing');
    answer = chosen.path;
    await exportCanvasFromMenu(s, c, web: false);
    expect(s.toast.value, 'Saved ${chosen.path}');
    await checkPicture(await chosen.readAsBytes());

    // A place that cannot be written: a plain message, nothing broken.
    // The dialog opens again so another place can be chosen.
    final other = File('${dir.path}/other/Second try.png');
    queue.addAll(['${chosen.path}/inside-a-file.png', other.path]);
    asked = 0;
    await exportCanvasFromMenu(s, c, web: false);
    expect(asked, 2);
    expect(s.toast.value, 'Saved ${other.path}');
    expect(other.lengthSync(), greaterThan(0));
    await checkPicture(await other.readAsBytes());
    await checkPicture(await chosen.readAsBytes());
    // ... and cancelling after a failure stops without a success message.
    queue.addAll(['${chosen.path}/inside-a-file.png', null]);
    await exportCanvasFromMenu(s, c, web: false);
    expect(s.toast.value, 'Export cancelled. Nothing was saved.');

    final protected = File('${dir.path}/protected.png')
      ..writeAsStringSync('keep this old export');
    final oldBytes = protected.readAsBytesSync();
    answer = protected.path;
    replaceExportFile = (source, destination) async {
      throw FileSystemException(
        'injected replacement failure',
        destination.path,
      );
    };
    queue.addAll([protected.path, null]);
    await exportCanvasFromMenu(s, c, web: false);
    expect(s.toast.value, 'Export cancelled. Nothing was saved.');
    expect(protected.readAsBytesSync(), oldBytes);
    expect(File('${protected.path}.part').existsSync(), isFalse);
  });

  test(
    'view-only web page of a note: escaped, no scripts, attachments in',
    () async {
      final ws = s.workspace;
      final photo = await ws.imageAssetFromBytes(
        await solidPng(const Color(0xFF0000FF)),
        'png',
      );
      final gone = await ws.imageAssetFromBytes(
        await solidPng(const Color(0xFF00FF00)),
        'png',
      );
      ws.attachments.fileFor(gone.file!).deleteSync();
      final good = ws.linkAsset(
        'https://example.com/a?b=1&c=2',
        title: 'Example',
      );
      final bad = ws.linkAsset('javascript:alert(1)', title: 'Trap');
      final note = ws.createNote(
        title: 'Plan <script>alert(1)</script>',
        body: 'Body with <b>tags</b> & "quotes"',
        assetIds: [photo.id, gone.id, good.id, bad.id],
      );
      final r = await exportNoteWebPage(s, note, to: out());
      final html = await r.file.readAsString();
      expect(html, isNot(contains('<script')));
      expect(html, contains('Plan &lt;script&gt;'));
      expect(html, isNot(contains('<b>')));
      expect(
        html,
        contains(
          'Body with &lt;b&gt;tags&lt;&#47;b&gt; &amp; &quot;quotes&quot;',
        ),
      );
      expect(html, contains("Content-Security-Policy"));
      expect(html, contains("default-src 'none'"));
      expect(html, isNot(contains('contenteditable')));
      expect(html, isNot(contains('<form')));
      expect(html, isNot(contains('<input')));
      // The photo is embedded and opens; the missing one is named.
      final m = RegExp(r'data:image/png;base64,([A-Za-z0-9+/=]+)')
          .allMatches(html);
      expect(m, isNotEmpty);
      await checkPicture(base64Decode(m.last.group(1)!));
      expect(html, contains('(photo not available)'));
      expect(r.missingImages, 1);
      // Web links are links; anything else is plain text.
      expect(
        html,
        contains(
          '<a href="https://example.com/a?b=1&amp;c=2" rel="noopener noreferrer nofollow">Example</a>',
        ),
      );
      expect(html, isNot(contains('href="javascript:')));
      expect(html, contains('Trap'));
      expect(ws.notes[note.id]!.body, 'Body with <b>tags</b> & "quotes"');
    },
  );

  test('view-only web page of a mindmap has its picture and policy', () async {
    final c = s.canvas!;
    c.addItems([
      TextItem(
        id: 't',
        position: Offset.zero,
        width: 200,
        minHeight: 40,
        text: '<i>x',
      ),
    ]);
    final r = (await exportCanvasWebPage(s, c, to: out()))!;
    final html = await r.file.readAsString();
    final m = RegExp(r'data:image/png;base64,([A-Za-z0-9+/=]+)')
        .firstMatch(html)!;
    await checkPicture(base64Decode(m.group(1)!));
    expect(html, isNot(contains('<script')));
    expect(html, contains("img-src data:"));
  });
}
