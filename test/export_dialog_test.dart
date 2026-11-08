// The export window: preview, options, file name, remembered choices, the
// success and failure states, and what ends up in the files.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/export/export_dialog.dart';
import 'package:flutter_application_1/features/export/exports.dart';
import 'package:flutter_application_1/platform/platform.dart' as native;
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> decodeImage(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  final f = await codec.getNextFrame();
  codec.dispose();
  return f.image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState s;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_exportdlg_');
    final ws = Workspace(Directory('${dir.path}/data'));
    s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await s.init();
    s.canvas!.addItems([
      TextItem(
        id: 'a',
        position: Offset.zero,
        width: 200,
        minHeight: 60,
        text: 'Hello',
      ),
      TextItem(
        id: 'b',
        position: const Offset(400, 200),
        width: 200,
        minHeight: 60,
        text: 'World',
      ),
    ]);
    hasExportDialog = false;
    askExportPath = native.askSavePath;
    replaceExportFile = native.replaceFile;
  });
  tearDown(() async {
    hasExportDialog = false;
    askExportPath = native.askSavePath;
    replaceExportFile = native.replaceFile;
    await s.flush();
    s.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Lets real async work (rendering, files) run and the UI catch up, until
  /// the save has ended one way or the other (or a few seconds passed).
  Future<void> work(WidgetTester tester) async {
    for (var i = 0; i < 120; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byKey(const ValueKey('export-success')).evaluate().isNotEmpty ||
          find.byKey(const ValueKey('export-failed')).evaluate().isNotEmpty ||
          (i > 6 && find.byKey(const ValueKey('export-message')).evaluate().isNotEmpty)) {
        return;
      }
    }
  }
  Future<void> open(WidgetTester tester, {bool web = false}) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showExportDialog(context, s, s.canvas!, web: web),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await work(tester);
  }

  testWidgets('the preview shows the picture and the real output size', (
    tester,
  ) async {
    await open(tester);
    expect(find.byKey(const ValueKey('export-preview-image')), findsOneWidget);
    String info() =>
        tester.widget<Text>(find.byKey(const ValueKey('export-info'))).data!;
    expect(info(), contains('PNG'));
    final standard = RegExp(r'(\d+) × (\d+)').firstMatch(info())!;
    // A small mindmap is not blown up past 2x.
    expect(int.parse(standard.group(1)!), lessThanOrEqualTo(2400));
    await tester.tap(find.byKey(const ValueKey('export-opt-Size-Small')));
    await tester.pump();
    await work(tester);
    final small = RegExp(r'(\d+) × (\d+)').firstMatch(info())!;
    expect(
      int.parse(small.group(1)!),
      lessThanOrEqualTo(int.parse(standard.group(1)!)),
    );
    await tester.tap(find.byKey(const ValueKey('export-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('export-dialog')), findsNothing);
    // Nothing was written by looking.
    expect(Directory('${dir.path}/data/exports').existsSync(), isFalse);
  });

  testWidgets('save: a real PNG, success state, choices remembered', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('export-name')), 'My map');
    await tester.tap(find.byKey(const ValueKey('export-opt-Background-Transparent')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('export-opt-Size-Large')));
    await tester.pump();
    await work(tester);
    await tester.tap(find.byKey(const ValueKey('export-save')));
    await work(tester);
    expect(find.byKey(const ValueKey('export-success')), findsOneWidget);
    final path = tester
        .widget<SelectableText>(find.byKey(const ValueKey('export-path')))
        .data!;
    final file = File(path);
    expect(file.path, endsWith('My map.png'));
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(0));
    // A valid PNG, transparent where nothing is drawn.
    final image = await tester.runAsync(() => decodeImage(file.readAsBytesSync()));
    final rgba = (await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    expect(rgba.getUint8(3), 0, reason: 'the corner has no background');
    // Remembered for the next time and in the recent list.
    final prefs = ExportPrefs(s);
    expect(prefs.options.background, ExportBackground.transparent);
    expect(prefs.options.maxSide, 4800);
    expect(prefs.recent.first.format, ExportFormat.png);
    await tester.tap(find.byKey(const ValueKey('export-done')));
    await tester.pumpAndSettle();
  });

  testWidgets('the read-only page: confirmed preview, a view-only file', (
    tester,
  ) async {
    await open(tester, web: true);
    expect(find.text('WHAT THE RECIPIENT SEES'), findsOneWidget);
    expect(find.textContaining('No scripts, no editing'), findsOneWidget);
    expect(find.byKey(const ValueKey('export-opt-Background-Transparent')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('export-save')));
    await work(tester);
    final path = tester
        .widget<SelectableText>(find.byKey(const ValueKey('export-path')))
        .data!;
    final html = File(path).readAsStringSync();
    expect(path, endsWith('.html'));
    expect(html, isNot(contains('<script')));
    expect(html, contains("default-src 'none'"));
    expect(html, contains('data:image/png;base64,'));
    // Nothing of the workspace besides the picture and the title.
    expect(html, isNot(contains('"items"')));
    await tester.tap(find.byKey(const ValueKey('export-done')));
    await tester.pumpAndSettle();
  });

  testWidgets('a cancelled save dialog saves nothing', (tester) async {
    hasExportDialog = true;
    askExportPath = ({
      required suggestedName,
      required extension,
      required typeLabel,
      initialDir,
    }) => null;
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('export-save')));
    await work(tester);
    expect(find.byKey(const ValueKey('export-message')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('export-message'))).data,
      'Cancelled. Nothing was saved.',
    );
    expect(find.byKey(const ValueKey('export-success')), findsNothing);
    expect(find.byKey(const ValueKey('export-save')), findsOneWidget);
  });

  testWidgets('a place that cannot be written: message, retry, no false save', (
    tester,
  ) async {
    hasExportDialog = true;
    final answers = <String>[
      '${dir.path}/blocked/map.png',
      '${dir.path}/ok/map.png',
    ];
    final asked = <String?>[];
    askExportPath = ({
      required suggestedName,
      required extension,
      required typeLabel,
      initialDir,
    }) {
      asked.add(initialDir);
      return answers.removeAt(0);
    };
    replaceExportFile = (source, destination) async {
      if (destination.path.contains('blocked')) {
        throw FileSystemException(
          'denied',
          destination.path,
          const OSError('Access is denied', 5),
        );
      }
      return native.replaceFile(source, destination);
    };
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('export-save')));
    await work(tester);
    expect(find.byKey(const ValueKey('export-failed')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('export-error'))).data,
      allOf(contains('Could not save'), contains('Access is denied')),
    );
    expect(File('${dir.path}/blocked/map.png').existsSync(), isFalse);
    expect(File('${dir.path}/blocked/map.png.part').existsSync(), isFalse);
    // Choose another place.
    await tester.tap(find.byKey(const ValueKey('export-retry')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('export-save')));
    await work(tester);
    expect(find.byKey(const ValueKey('export-success')), findsOneWidget);
    expect(File('${dir.path}/ok/map.png').lengthSync(), greaterThan(0));
    // The next dialog starts in the folder that worked.
    expect(ExportPrefs(s).lastFolder?.path, '${dir.path}/ok');
  });

  testWidgets('repeated exports never overwrite each other', (tester) async {
    await open(tester);
    final paths = <String>[];
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('export-save')));
      await work(tester);
      paths.add(
        tester
            .widget<SelectableText>(find.byKey(const ValueKey('export-path')))
            .data!,
      );
      await tester.tap(find.byKey(const ValueKey('export-done')));
      await tester.pumpAndSettle();
      if (i < 2) {
        await tester.tap(find.text('open'));
        await tester.pump();
        await work(tester);
      }
    }
    expect(paths.toSet(), hasLength(3));
    for (final p in paths) {
      expect(File(p).lengthSync(), greaterThan(0));
    }
  });

  group('logic', () {
    test('options are safe from stored junk', () {
      expect(ExportOptions.fromJson(null), const ExportOptions());
      expect(
        ExportOptions.fromJson({'background': 'sparkle', 'maxSide': 7}),
        const ExportOptions(),
      );
      expect(
        ExportOptions.fromJson({'background': 'transparent', 'maxSide': 1200}),
        const ExportOptions(background: ExportBackground.transparent, maxSide: 1200),
      );
    });

    test('recent choices: newest first, no duplicates, at most five', () async {
      final prefs = ExportPrefs(s);
      for (final side in [1200, 2400, 4800]) {
        await prefs.remember(ExportFormat.png, ExportOptions(maxSide: side));
      }
      await prefs.remember(ExportFormat.web, const ExportOptions());
      await prefs.remember(
        ExportFormat.png,
        const ExportOptions(background: ExportBackground.transparent),
      );
      await prefs.remember(ExportFormat.png, const ExportOptions(maxSide: 1200));
      final recent = prefs.recent;
      expect(recent, hasLength(ExportPrefs.maxRecent));
      expect(recent.first.options.maxSide, 1200);
      expect(
        recent.where((r) => r.format == ExportFormat.png && r.options.maxSide == 1200),
        hasLength(1),
      );
    });

    test('the last folder is only used when it is still writable', () async {
      hasExportDialog = true;
      final ok = Directory('${dir.path}/dest')..createSync();
      final prefs = ExportPrefs(s);
      await prefs.rememberFolder(File('${ok.path}/x.png'));
      expect(prefs.lastFolder?.path, ok.path);
      ok.deleteSync(recursive: true);
      expect(prefs.lastFolder, isNull);
      hasExportDialog = false;
      await s.settings.set('exportLastFolder', ok.path);
      expect(ExportPrefs(s).lastFolder, isNull, reason: 'no dialog here');
    });

    test('a large mindmap stays within the chosen size', () async {
      final c = s.canvas!;
      c.addItems([
        TextItem(
          id: 'far',
          position: const Offset(150000, 90000),
          width: 200,
          minHeight: 60,
          text: 'far',
        ),
      ]);
      for (final (_, side) in exportResolutions) {
        final r = (await exportCanvasPicture(
          s,
          c,
          to: Directory('${dir.path}/big'),
          options: ExportOptions(maxSide: side),
        ))!;
        final image = await decodeImage(r.file.readAsBytesSync());
        expect(image.width, lessThanOrEqualTo(side));
        expect(image.height, lessThanOrEqualTo(side));
        expect([image.width, image.height].reduce((a, b) => a > b ? a : b),
            greaterThan(side - 3));
        image.dispose();
      }
    });
  });
}
