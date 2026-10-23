// End-to-end interaction tests: real widgets, simulated mouse and keyboard,
// real files in a temporary data folder, and restarts in between.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/calendar/calendar_page.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_page.dart';
import 'package:flutter_application_1/features/capture/capture_dialog.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/platform/windows_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

/// A real 4x3 PNG, drawn with Flutter (so it decodes everywhere).
Future<Uint8List> makePng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xFFE76F51), BlendMode.src);
  final image = await recorder.endRecording().toImage(4, 3);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

class Harness {
  Harness(this.tester, this.dir);

  final WidgetTester tester;
  final Directory dir;
  late AppState s;
  String? clipboardText;
  final opened = <String>[];
  List<String> picked = const [];

  Future<void> boot() async {
    tester.view.physicalSize = const Size(1700, 1050);
    tester.view.devicePixelRatio = 1;
    final ws = Workspace(dir);
    s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture
      ..fetchPreviews = false
      ..readNativeClipboard = (() => const NativeClipboard())
      ..pickImageFiles = (() => picked);
    s.openUrl = (url) {
      opened.add(url);
      return true;
    };
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return clipboardText == null ? null : {'text': clipboardText};
        }
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await tester.runAsync(s.init);
    await tester.pumpWidget(TheApp(state: s));
    await tester.pump();
  }

  /// Lets real file I/O finish and the UI catch up.
  Future<void> settle({int rounds = 5}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> restart() async {
    // Let every debounced save (started on the fake clock) finish first.
    await settle(rounds: 25);
    await waitForBothClocks(tester, s.flush, what: 'Saving');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    await boot();
  }

  Future<void> shutDown() async {
    await settle(rounds: 25);
    await waitForBothClocks(tester, s.flush, what: 'Saving');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  }

  /// Old page names map to the four destinations; Home is the THEapp
  /// start-page button, Tasks the task column inside calendar.
  Future<void> nav(String label) async {
    if (label == 'Home') {
      await tester.tap(find.byKey(const ValueKey('sidebar-start-page')));
    } else if (label == 'Tasks') {
      await tester.tap(find.text('calendar').last);
      await tester.pump();
      final toggle = find.byKey(const ValueKey('calendar-tasks-toggle'));
      if (find.text('Hide tasks').evaluate().isEmpty) {
        await tester.tap(toggle);
      }
    } else {
      final name =
          const {'Canvas': 'mindmap', 'Links': 'archive'}[label] ??
          label.toLowerCase();
      await tester.tap(find.text(name).last);
    }
    await tester.pump();
    await tester.pump();
  }

  Offset get canvasOrigin => tester.getTopLeft(find.byType(CanvasView));

  /// Screen position of a world point on the open canvas.
  Offset screen(Offset world) => canvasOrigin + s.canvas!.toScreen(world);

  Future<void> click(Offset at) async {
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> drag(Offset from, Offset to) async {
    final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 8)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> key(LogicalKeyboardKey key, {bool ctrl = false}) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_ui_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets(
    'canvas: select, format, duplicate, delete, undo/redo with mouse and keys',
    (tester) async {
      addTearDown(tester.view.reset);
      final h = Harness(tester, dir);
      await h.boot();
      await h.nav('Canvas');
      final c = h.s.canvas!;
      final note = c.items.single as TextItem;

      await h.click(h.screen(c.itemBounds(note).center));
      expect(c.selection, {note.id});

      await tester.tap(find.byTooltip('Bold'));
      await tester.pump();
      expect((c.itemById(note.id) as TextItem).bold, isTrue);
      await tester.tap(find.byTooltip('Text size').at(2)); // L
      await tester.pump();
      expect((c.itemById(note.id) as TextItem).fontSize, 22);

      await h.key(LogicalKeyboardKey.keyD, ctrl: true);
      expect(c.items, hasLength(2));
      await h.key(LogicalKeyboardKey.delete);
      expect(c.items, hasLength(1));
      await h.key(LogicalKeyboardKey.keyZ, ctrl: true);
      expect(c.items, hasLength(2));
      await h.key(LogicalKeyboardKey.keyY, ctrl: true);
      expect(c.items, hasLength(1));

      await h.restart();
      await h.nav('Canvas');
      final saved = h.s.canvas!.items.single as TextItem;
      expect(saved.bold, isTrue);
      expect(saved.fontSize, 22);
      await h.shutDown();
    },
  );

  testWidgets('canvas: drawing, moving and erasing do not interfere', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final h = Harness(tester, dir);
    await h.boot();
    await h.nav('Canvas');
    final c = h.s.canvas!;
    final note = c.items.single as TextItem;
    final start = note.position;
    final empty = c.itemBounds(note).bottomLeft + const Offset(0, 200);

    await h.key(LogicalKeyboardKey.keyP);
    expect(c.tool, CanvasTool.pen);
    // A pen stroke that starts on top of the note must not move it.
    await h.drag(h.screen(c.itemBounds(note).center), h.screen(empty));
    expect(c.items.whereType<StrokeItem>(), hasLength(1));
    expect((c.itemById(note.id) as TextItem).position, start);

    await h.key(LogicalKeyboardKey.keyV);
    final strokesBefore = c.items.whereType<StrokeItem>().length;
    await h.drag(
      h.screen(c.itemBounds(note).topLeft + const Offset(30, 15)),
      h.screen(c.itemBounds(note).topLeft + const Offset(130, 15)),
    );
    expect(
      (c.itemById(note.id) as TextItem).position.dx,
      closeTo(start.dx + 100, 1.5),
    );
    expect(c.items.whereType<StrokeItem>().length, strokesBefore);

    await h.key(LogicalKeyboardKey.keyE);
    final stroke = c.items.whereType<StrokeItem>().single;
    final p = stroke.points[stroke.points.length ~/ 2].offset;
    await h.drag(
      h.screen(p - const Offset(20, 0)),
      h.screen(p + const Offset(20, 0)),
    );
    expect(c.items.whereType<StrokeItem>(), isEmpty);
    expect(
      c.itemById(note.id),
      isNotNull,
      reason: 'the eraser only removes drawings',
    );
    await h.shutDown();
  });

  testWidgets(
    'canvas: Ctrl+V pastes links and text, even after using the sidebar',
    (tester) async {
      addTearDown(tester.view.reset);
      final h = Harness(tester, dir);
      await h.boot();
      await h.nav('Canvas');
      await h.nav('Home');
      await h.nav('Canvas');
      final c = h.s.canvas!;

      h.clipboardText = 'https://example.org/page';
      await h.key(LogicalKeyboardKey.keyV, ctrl: true);
      await h.settle();
      final link = c.items.whereType<LinkItem>().single;
      final asset = h.s.workspace.assets[link.assetId]!;
      expect(asset.url, 'https://example.org/page');

      h.clipboardText = 'A plain idea';
      await h.key(LogicalKeyboardKey.keyV, ctrl: true);
      await h.settle();
      expect(
        c.items.whereType<TextItem>().map((t) => t.text),
        contains('A plain idea'),
      );

      // Pasting the same link again reuses the same asset record.
      h.clipboardText = 'https://example.org/page';
      await h.key(LogicalKeyboardKey.keyV, ctrl: true);
      await h.settle();
      expect(c.items.whereType<LinkItem>(), hasLength(2));
      expect(h.s.workspace.assets.length, 1);

      // Double-clicking a link card opens that exact address.
      final card = c.items.whereType<LinkItem>().first;
      final at = h.screen(c.itemBounds(card).center);
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(h.opened, ['https://example.org/page']);

      // Copy + paste inside the canvas duplicates the card, not the record.
      await h.click(at);
      await h.key(LogicalKeyboardKey.keyC, ctrl: true);
      await h.key(LogicalKeyboardKey.keyV, ctrl: true);
      await h.settle();
      expect(c.items.whereType<LinkItem>(), hasLength(3));
      expect(h.s.workspace.assets.length, 1);

      await h.restart();
      await h.nav('Canvas');
      expect(h.s.canvas!.items.whereType<LinkItem>(), hasLength(3));
      expect(h.s.workspace.assets.all.single.url, 'https://example.org/page');
      await h.shutDown();
    },
  );

  testWidgets(
    'canvas: imported photos are copied, shown, resized and survive restarts',
    (tester) async {
      addTearDown(tester.view.reset);
      final h = Harness(tester, dir);
      final png = (await tester.runAsync(makePng))!;
      final original = File('${dir.path}${Platform.pathSeparator}holiday.png')
        ..writeAsBytesSync(png);
      h.picked = [original.path];
      await h.boot();
      await h.nav('Canvas');
      await tester.tap(find.byTooltip('Add photos from this PC'));
      await h.settle(rounds: 15);
      final c = h.s.canvas!;
      final image = c.items.whereType<ImageItem>().single;
      final asset = h.s.workspace.assets[image.assetId]!;
      expect(asset.kind, AssetKind.image);

      // Resize from the top-right dot: the aspect ratio (4:3) is kept.
      expect(c.selection, {image.id});
      final corner = h.screen(c.itemBounds(image).topRight);
      await h.drag(corner, corner + const Offset(100, -10));
      final resized = c.itemById(image.id) as ImageItem;
      expect(resized.width, closeTo(resized.height * 4 / 3, 0.01));
      expect(resized.width, greaterThan(image.width));

      original.deleteSync(); // the app keeps its own copy
      await h.restart();
      await h.nav('Canvas');
      final again = h.s.canvas!.items.whereType<ImageItem>().single;
      expect(again.width, closeTo(resized.width, 0.01));
      final stored = h.s.workspace.attachments.fileFor(
        h.s.workspace.assets[again.assetId]!.file!,
      );
      expect(stored.existsSync(), isTrue);
      expect(stored.readAsBytesSync(), png);
      await h.shutDown();
    },
  );

  testWidgets(
    'Quick Add creates a task, and its due date shows it on Calendar',
    (tester) async {
      addTearDown(tester.view.reset);
      final h = Harness(tester, dir);
      await h.boot();
      final s = h.s;
      showCaptureDialog(
        tester.element(find.byType(Scaffold).first),
        s,
        destination: CaptureDestination.task,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No date'), findsOneWidget);
      await tester.enterText(
        find
            .descendant(
              of: find.byType(CaptureDialog),
              matching: find.byType(TextField),
            )
            .first,
        'Buy train tickets\nfor the trip on Friday',
      );
      await tester.pump();
      await tester.tap(find.textContaining('Save'));
      await h.settle();
      final task = s.workspace.tasks.all.single;
      expect(task.title, 'Buy train tickets');
      expect(task.notes, 'for the trip on Friday');
      expect(task.dueDate, isNull);

      // Giving it a date (as the Tasks page does) puts the same record on Calendar.
      s.workspace.tasks.put(task.copyWith(dueDate: () => s.calendarStart));
      await h.nav('Calendar');
      expect(find.text('Buy train tickets'), findsOneWidget);
      expect(s.workspace.tasks.length, 1);
      await h.shutDown();
    },
  );

  testWidgets(
    'calendar: habit check-off, archive and restore, day note persistence',
    (tester) async {
      addTearDown(tester.view.reset);
      final h = Harness(tester, dir);
      await h.boot();
      final s = h.s;
      final day = s.calendarStart;
      final habit = CalendarEntry(
        id: newId(),
        category: CalendarCategory.habits,
        name: 'Stretch',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        startDate: day,
      );
      s.workspace.saveEntry(habit);
      await h.nav('Calendar');

      // Tick today's check box on the grid label.
      final firstCell = find.byType(DayCell).first;
      await tester.tap(
        find.descendant(
          of: firstCell,
          matching: find.byIcon(Icons.check_box_outline_blank),
        ),
      );
      await tester.pump();
      expect(s.workspace.entries[habit.id]!.isCheckedOn(day), isTrue);

      // Archive from the Habits view, then restore from the archive.
      await tester.tap(find.text('Habits').first);
      await tester.pump();
      await tester.tap(find.byTooltip('Archive').first);
      await tester.pump();
      expect(s.workspace.entries[habit.id]!.archived, isTrue);
      expect(find.text('0 of 5 active'), findsOneWidget);
      await tester.tap(find.textContaining('Archive  1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Restore'));
      await tester.pump();
      expect(s.workspace.entries[habit.id]!.archived, isFalse);
      await tester.tap(find.text('Close'));
      await tester.pump(const Duration(milliseconds: 300));

      // Open a day and write a note on it.
      await tester.tap(find.textContaining('-Day Grid'));
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(DayCell).at(3),
          matching: find.text('${addDays(day, 3).day}'),
        ),
      );
      await tester.pump();
      expect(find.byType(DayPanel), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(DayPanel),
          matching: find.byType(TextField),
        ),
        'Dentist at 15:00',
      );
      await tester.pump();

      await h.restart();
      expect(s.workspace.entries.length, 1);
      final ws = h.s.workspace;
      expect(ws.dayRecord(addDays(day, 3)).text, 'Dentist at 15:00');
      expect(ws.entries[habit.id]!.isCheckedOn(day), isTrue);
      expect(ws.entries[habit.id]!.archived, isFalse);
      await h.shutDown();
    },
  );

  testWidgets(
    'Ctrl+N and Ctrl+K work from every page; the calendar grid zooms with the wheel',
    (tester) async {
      addTearDown(tester.view.reset);
      final h = Harness(tester, dir);
      await h.boot();
      for (final page in ['Home', 'Canvas', 'Notes', 'Calendar', 'Tasks']) {
        await h.nav(page);
        await h.key(LogicalKeyboardKey.keyN, ctrl: true);
        await h.settle();
        expect(
          find.byType(CaptureDialog),
          findsOneWidget,
          reason: 'Ctrl+N on $page',
        );
        await tester.tap(find.text('Cancel'));
        await tester.pump(const Duration(milliseconds: 400));
        await h.key(LogicalKeyboardKey.keyK, ctrl: true);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.textContaining('Search notes, canvases'),
          findsOneWidget,
          reason: 'Ctrl+K on $page',
        );
        await h.key(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 400));
      }

      await h.nav('Calendar');
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final before = viewer.transformationController!.value.getMaxScaleOnAxis();
      final center = tester.getCenter(find.byType(InteractiveViewer));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -300)));
      await tester.pump();
      final after = viewer.transformationController!.value.getMaxScaleOnAxis();
      expect(after, greaterThan(before));
      await h.shutDown();
    },
  );

  testWidgets('filing an Inbox photo into Notes reuses the same photo record', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final h = Harness(tester, dir);
    await h.boot();
    final ws = h.s.workspace;
    final asset = (await tester.runAsync(
      () async => h.s.capture.imageFromBytes(await makePng(), 'png'),
    ))!;
    ws.inbox.put(
      InboxItem(id: newId(), assetId: asset.id, createdAt: DateTime.now()),
    );
    await tester.pump();
    expect(find.textContaining('Inbox  ·  1 to file'), findsOneWidget);

    await tester.tap(find.text('File…'));
    await h.settle();
    await tester.tap(find.text('Notes').last); // destination segment
    await tester.pump();
    await tester.tap(find.textContaining('Save'));
    await h.settle();

    final note = ws.notes.all.single;
    expect(note.assetIds, [asset.id]);
    expect(ws.assets.length, 1);
    expect(ws.inbox.length, 0);
    expect(ws.attachments.dir.listSync(), hasLength(1));
    await h.shutDown();
  });
}
