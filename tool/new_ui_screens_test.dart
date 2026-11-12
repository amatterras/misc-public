// ignore_for_file: invalid_use_of_visible_for_testing_member
// NOT part of the regular suite (name starts with "_"; run it by hand).
// 1) Seeds disposable test-data folders with realistic content for
//    real-window screenshots.
// 2) Renders the New/Original interface at iPhone and iPad sizes with the
//    real Windows font into screenshots/new_ui/. These are renders of the
//    app's own widgets in the test harness on Windows, NOT screenshots from
//    an iPhone or iPad.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/platform/device_idiom.dart';
import 'package:flutter_test/flutter_test.dart';

const _out = r'screenshots\new_ui';
final _testEnv = Platform.environment['THEAPP_TESTENV'] ?? 'THEapp-TESTENV';

Future<void> _loadFonts() async {
  ByteData bytes(String p) => ByteData.sublistView(File(p).readAsBytesSync());
  final segoe = FontLoader('Segoe UI')
    ..addFont(Future.value(bytes(r'C:\Windows\Fonts\segoeui.ttf')))
    ..addFont(Future.value(bytes(r'C:\Windows\Fonts\segoeuib.ttf')))
    ..addFont(Future.value(bytes(r'C:\Windows\Fonts\seguisb.ttf')));
  await segoe.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      Future.value(
        bytes(
          r'C:\src\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
        ),
      ),
    );
  await icons.load();
}

Future<void> _png(String path, Color a, Color b) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(
    const Rect.fromLTWH(0, 0, 400, 300),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(400, 300), [
        a,
        b,
      ]),
  );
  c.drawCircle(const Offset(300, 90), 46, Paint()..color = Colors.white54);
  final img = await rec.endRecording().toImage(400, 300);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(data!.buffer.asUint8List());
}

/// Content for Home and the Archive.
Future<void> _seed(AppState s, Directory scratch) async {
  final ws = s.workspace;
  final today = dateOnly(DateTime.now());

  // Calendar / tasks for Home.
  ws.saveEntry(
    CalendarEntry(
      id: newId(),
      category: CalendarCategory.events,
      name: 'Design review',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      startDate: today,
      endDate: today,
      startMinutes: 9 * 60,
      durationMinutes: 60,
      description: 'Walk through the new sidebar',
    ),
  );
  ws.saveEntry(
    CalendarEntry(
      id: newId(),
      category: CalendarCategory.events,
      name: 'Dinner with Ayla',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      startDate: today,
      endDate: today,
      startMinutes: 19 * 60 + 30,
      durationMinutes: 120,
    ),
  );
  ws.saveEntry(
    CalendarEntry(
      id: newId(),
      category: CalendarCategory.habits,
      name: 'Morning stretch',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      startDate: today,
      startMinutes: 7 * 60 + 30,
      durationMinutes: 15,
    ),
  );
  ws.saveEntry(
    CalendarEntry(
      id: newId(),
      category: CalendarCategory.reading,
      name: 'The Overstory',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      startDate: today,
      startMinutes: 21 * 60,
      durationMinutes: 30,
      totalPages: 502,
      currentPage: 211,
      readingLog: {dayKey(today): 20},
    ),
  );
  ws.saveEntry(
    CalendarEntry(
      id: newId(),
      category: CalendarCategory.other,
      name: 'Call the landlord',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      dates: {dayKey(today)},
    ),
  );
  final t1 = ws.createTask('Send the invoice', dueDate: today);
  ws.tasks.put(t1.copyWith(dueMinutes: () => 13 * 60));
  final t2 = ws.createTask('Book train tickets', dueDate: today);
  ws.toggleTask(t2.id);
  ws.createTask('Renew passport', dueDate: addDays(today, -3));
  ws.createTask('Buy a birthday gift', dueDate: today);
  ws.createTask('Tidy the desk');
  for (final d in [1, 2, 4]) {
    ws.createTask('Plan day $d', dueDate: addDays(today, d));
  }

  // Archive.
  await Future(() {});
  final repo = s.library;
  Future<LibrarySpace> folder(String name, {bool pin = false}) async {
    final f = await repo.createSpace(name);
    if (pin) ws.librarySpaces.put(f.copyWith(pinned: true));
    return f;
  }

  Future<void> note(LibrarySpace? f, String title, String body) async {
    await repo.save(
      type: LibraryObjectType.note,
      title: title,
      content: body,
      spaceId: f?.id,
    );
  }

  Future<void> image(LibrarySpace f, String title, Color a, Color b) async {
    final file = File('${scratch.path}\\${title.hashCode}.png');
    await _png(file.path, a, b);
    final assets = await s.capture.imagesFromFiles([file.path]);
    for (final asset in assets) {
      await s.capture.saveAssetToArchive(asset);
      final o = repo.objects.firstWhere(
        (x) => x.attachmentIds.contains(asset.id),
      );
      await repo.update(o.copyWith(title: title));
      await repo.addToRegularSpace(f.id, o.id);
    }
  }

  final travel = await folder('Lisbon trip', pin: true);
  await image(
    travel,
    'Alfama rooftops',
    const Color(0xFFE7A396),
    const Color(0xFF7D80B8),
  );
  await note(
    travel,
    'Three days in Lisbon',
    'Tram 28 early, pastéis in Belém, sunset at Miradouro da Senhora do Monte.',
  );
  await note(
    travel,
    'Harbour hotels',
    'Short list: Memmo Alfama, The Ivens, Santa Clara 1728.',
  );
  await note(
    travel,
    'Packing list',
    'Comfortable shoes, charger, rain jacket, camera.',
  );
  await note(
    travel,
    'Day trip to Sintra',
    'Pena Palace opens at 9:30 — book the morning slot.',
  );
  final recipes = await folder('Recipes');
  await image(
    recipes,
    'Shakshuka',
    const Color(0xFFCD775C),
    const Color(0xFFD9A441),
  );
  await note(
    recipes,
    'Weeknight dal',
    'Red lentils, turmeric, garlic tarka, lemon at the end.',
  );
  await note(
    recipes,
    'Focaccia',
    '78% hydration, overnight in the fridge, flaky salt.',
  );
  final reading = await folder('Reading list');
  await image(
    reading,
    'Book cover scans',
    const Color(0xFF8CB9B7),
    const Color(0xFF5B629C),
  );
  for (final t in [
    'Notes on attention',
    'Why we sleep',
    'The pragmatic programmer',
    'Four thousand weeks',
  ]) {
    await note(reading, t, 'Saved for later: key chapters and quotes from $t.');
  }
  final ideas = await folder('Ideas');
  await note(
    ideas,
    'App for plant care',
    'Reminders based on light and season.',
  );
  await note(null, 'Gift ideas for mum', 'Ceramic set, silk scarf, plant.');
  await note(null, 'Meeting follow-ups', 'Send notes, confirm dates.');
}

Future<AppState> _open(Directory dir) async {
  final ws = Workspace(dir);
  final s = AppState(
    canvases: FileCanvasRepository(ws.store),
    settings: SettingsRepository(ws.store),
    workspace: ws,
    enableSendTo: false,
  )..capture.fetchPreviews = false;
  await s.init();
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── seed folders for the real Windows window ─────────────────────────
  for (final (name, theme, page, _, expanded) in [
    ('app-shot-archive-dark', 'dark', 'links', 'new', false),
    ('app-shot-archive-light', 'light', 'links', 'new', false),
    ('app-shot-r-calendar', 'dark', 'calendar', 'new', false),
    ('app-shot-r-notes', 'dark', 'notes', 'new', true),
    ('app-shot-r-canvas', 'dark', 'canvas', 'new', false),
  ]) {
    test('seed $name', () async {
      final dir = Directory('$_testEnv\\$name');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      await Process.run('cmd', [
        '/c',
        'xcopy',
        '$_testEnv\\app',
        '${dir.path}\\',
        '/E',
        '/I',
        '/Q',
        '/Y',
      ]);
      File('${dir.path}\\instance.json').deleteSync();
      final scratch = Directory.systemTemp.createTempSync('shot_img_');
      final s = await _open(dir);
      await _seed(s, scratch);
      await s.setThemeMode(theme);
      if (expanded) await s.settings.set('newSidebarExpanded', true);
      await s.settings.set('lastPage', page);
      await s.flush();
      s.dispose();
      scratch.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  // ── renders at iPhone / iPad sizes ───────────────────────────────────
  Future<void> render(
    WidgetTester tester, {
    required String file,
    required Size size,
    required bool ios,
    required String theme,
    AppPage page = AppPage.notes,
    bool home = false,
    bool? phone,
  }) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    if (ios) debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    DeviceIdiom.debugIsPhone = phone;
    final dir = Directory.systemTemp.createTempSync('shot_');
    final scratch = Directory.systemTemp.createTempSync('shot_img_');
    final ws = Workspace(dir);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
    await tester.runAsync(() async {
      await s.init();
      await _seed(s, scratch);
      await s.setThemeMode(theme);
      s.goTo(page);
    });
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: TheApp(state: s),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (!home) {
      s.goTo(page);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 1);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      Directory(_out).createSync(recursive: true);
      File('$_out\\$file').writeAsBytesSync(data!.buffer.asUint8List());
    });
    await tester.runAsync(s.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    s.dispose();
    debugDefaultTargetPlatformOverride = null;
    DeviceIdiom.debugIsPhone = null;
    dir.deleteSync(recursive: true);
    scratch.deleteSync(recursive: true);
  }

  const phone = Size(390, 844);
  const ipad = Size(820, 1180);
  final jobs = <(String, Size, bool, String, AppPage, bool, bool?)>[
    (
      '10_new_iphone_home_dark.png',
      phone,
      true,
      'dark',
      AppPage.notes,
      true,
      null,
    ),
    (
      '11_new_iphone_home_light.png',
      phone,
      true,
      'light',
      AppPage.notes,
      true,
      null,
    ),
    (
      '12_new_iphone_archive_dark.png',
      phone,
      true,
      'dark',
      AppPage.links,
      false,
      null,
    ),
    (
      '13_new_iphone_notes_dark.png',
      phone,
      true,
      'dark',
      AppPage.notes,
      false,
      null,
    ),
    (
      '20_new_ipad_archive_dark.png',
      ipad,
      true,
      'dark',
      AppPage.links,
      false,
      null,
    ),
    (
      '21_new_ipad_calendar_dark.png',
      ipad,
      true,
      'dark',
      AppPage.calendar,
      false,
      null,
    ),
    (
      '23_new_ipad_slideover_notes_dark.png',
      Size(320, 900),
      true,
      'dark',
      AppPage.notes,
      false,
      false,
    ),
    (
      '15_new_iphone_landscape_home_dark.png',
      Size(844, 390),
      true,
      'dark',
      AppPage.notes,
      true,
      true,
    ),
  ];
  for (final j in jobs) {
    testWidgets('render ${j.$1}', (tester) async {
      await render(
        tester,
        file: j.$1,
        size: j.$2,
        ios: j.$3,
        theme: j.$4,
        page: j.$5,
        home: j.$6,
        phone: j.$7,
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
