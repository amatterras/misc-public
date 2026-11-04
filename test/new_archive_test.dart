// New Archive: layered collection cards over the existing library data,
// the 2/5 preview state, Whole Look (the existing all-items page), colours,
// pinning/ordering, selection and swipe actions.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/interface_version.dart';
import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/features/capture/send_to.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/library/library_page.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/new_ui/archive_model.dart';
import 'package:flutter_application_1/new_ui/new_archive_page.dart';
import 'package:flutter_application_1/new_ui/new_folder_colors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_archive_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> boot(WidgetTester tester, {Size? size}) async {
    tester.view.physicalSize = size ?? const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
    await tester.runAsync(state.init);
    await tester.runAsync(
      () => state.setInterfaceVersion(InterfaceVersion.newDesign),
    );
    return state;
  }

  Future<LibrarySpace> folder(
    WidgetTester tester,
    AppState s,
    String name, {
    int notes = 0,
  }) async {
    late LibrarySpace space;
    await tester.runAsync(() async {
      space = await s.library.createSpace(name);
      for (var i = 0; i < notes; i++) {
        await s.library.save(
          type: LibraryObjectType.note,
          title: '$name note ${i + 1}',
          content: 'Body of $name note ${i + 1}',
          spaceId: space.id,
        );
      }
    });
    return space;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Lets chained file writes (each followed by more work) run to the end.
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.runAsync(state.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  }

  group('ArchiveModel', () {
    testWidgets('counts, colours and ordering come from the library data', (
      tester,
    ) async {
      final s = await boot(tester);
      final ws = s.workspace;
      final a = await folder(tester, s, 'Travel', notes: 5);
      final b = await folder(tester, s, 'Recipes', notes: 1);
      final c = await folder(tester, s, 'Empty');
      await tester.runAsync(
        () => s.library.save(type: LibraryObjectType.note, title: 'Loose'),
      );

      final five = ArchiveModel.collection(s.library, a);
      expect(five.total, 5);
      expect(five.countLabel, '2/5'); // two in front out of five, not a page
      expect(five.hidden, 3);
      expect(ArchiveModel.collection(s.library, b).countLabel, '1/1');
      expect(ArchiveModel.collection(s.library, c).countLabel, '0/0');

      // Items that are in no folder form the virtual "Unfiled" collection.
      final unfiled = ArchiveModel.unfiled(s.library, ws);
      expect(unfiled.items.map((o) => o.title), ['Loose']);

      // Colours: assigned once, saved, never the same as the neighbour.
      expect(ws.librarySpaces.all.every((f) => f.colorId == null), isTrue);
      expect(ArchiveModel.ensureColors(ws), isTrue);
      final colours = [for (final f in ArchiveModel.folders(ws)) f.colorId];
      expect(colours.whereType<String>(), hasLength(3));
      for (var i = 1; i < colours.length; i++) {
        expect(colours[i], isNot(colours[i - 1]));
      }
      final before = [for (final f in ws.librarySpaces.all) f.colorId];
      expect(ArchiveModel.ensureColors(ws), isFalse); // stable
      expect([for (final f in ws.librarySpaces.all) f.colorId], before);

      // Pinned folders first, then manual order.
      ws.librarySpaces.put(c.copyWith(pinned: true));
      expect(ArchiveModel.folders(ws).first.name, 'Empty');
      ArchiveModel.moveBefore(ws, b.id, a.id);
      final names = ArchiveModel.folders(ws).map((f) => f.name).toList();
      expect(names.indexOf('Recipes'), lessThan(names.indexOf('Travel')));
      await close(tester, s);
    });

    testWidgets('folder fields are additive and survive save and load', (
      tester,
    ) async {
      final s = await boot(tester);
      final a = await folder(tester, s, 'Travel');
      final colored = a.copyWith(
        colorId: 'sea-glass',
        pinned: true,
        sortOrder: 30,
        parentId: () => 'p',
      );
      final back = LibrarySpace.fromJson(colored.toJson());
      expect(
        (back.colorId, back.pinned, back.sortOrder, back.parentId),
        ('sea-glass', true, 30, 'p'),
      );
      // A folder saved before these fields existed still loads.
      final old = LibrarySpace.fromJson({
        'id': 'x',
        'name': 'Old',
        'kind': 'regular',
        'query': '',
      });
      expect((old.colorId, old.pinned, old.parentId), (null, false, null));
      await close(tester, s);
    });
  });

  testWidgets('landing shows layered collections with the 2/5 state', (
    tester,
  ) async {
    final s = await boot(tester);
    final a = await folder(tester, s, 'Travel', notes: 5);
    final b = await folder(tester, s, 'Recipes', notes: 1);
    await tester.pumpWidget(TheApp(state: s));
    await settle(tester);
    s.goTo(AppPage.links);
    await settle(tester);

    expect(find.byType(NewArchivePage), findsOneWidget);
    expect(find.byKey(ValueKey('archive-collection-${a.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('archive-collection-${b.id}')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(ValueKey('archive-count-${a.id}'))).data,
      '2/5',
    );
    // Real saved content in front: the two newest notes of the folder.
    final newest = ArchiveModel.collection(s.library, a).items;
    expect(
      find.byKey(ValueKey('archive-preview-${newest[0].id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('archive-preview-${newest[1].id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('archive-preview-${newest[2].id}')),
      findsNothing,
    );

    // Every folder got its own colour, saved.
    expect(
      s.workspace.librarySpaces.all.every((f) => f.colorId != null),
      isTrue,
    );
    await close(tester, s);
  });

  testWidgets('Whole Look is the existing all-items page', (tester) async {
    final s = await boot(tester);
    await folder(tester, s, 'Travel', notes: 2);
    await tester.pumpWidget(TheApp(state: s));
    await settle(tester);
    s.goTo(AppPage.links);
    await settle(tester);

    expect(find.byType(LibraryPage), findsNothing); // not the landing page
    await tester.tap(find.byKey(const ValueKey('archive-whole-look')));
    await settle(tester);
    expect(find.byType(LibraryPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('archive-back')));
    await settle(tester);
    expect(find.byType(LibraryPage), findsNothing);
    await close(tester, s);
  });

  testWidgets('a collection shows everything; swipe, select and colour work', (
    tester,
  ) async {
    final s = await boot(tester);
    final a = await folder(tester, s, 'Travel', notes: 4);
    final other = await folder(tester, s, 'Recipes');
    await tester.pumpWidget(TheApp(state: s));
    await settle(tester);
    s.goTo(AppPage.links);
    await settle(tester);

    await tester.tap(find.byKey(ValueKey('archive-collection-${a.id}')));
    await settle(tester);
    final items = ArchiveModel.collection(s.library, a).items;
    for (final o in items) {
      expect(find.byKey(ValueKey('archive-item-${o.id}')), findsOneWidget);
    }

    // Swipe a row open (past the threshold) and favourite it.
    final target = items.first;
    await tester.drag(
      find.byKey(ValueKey('archive-swipe-${target.id}')),
      const Offset(-300, 0),
    );
    await settle(tester);
    await tester.tap(
      find.byKey(ValueKey('archive-swipe-favorite-${target.id}')),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await settle(tester);
    expect(s.workspace.libraryObjects[target.id]!.metadata['favorite'], isTrue);

    // A brush of a swipe does not open the actions.
    final second = items[1];
    await tester.drag(
      find.byKey(ValueKey('archive-swipe-${second.id}')),
      const Offset(-20, 0),
    );
    await settle(tester);
    expect(
      tester.getTopLeft(find.byKey(ValueKey('archive-item-${second.id}'))).dx,
      greaterThan(0),
    );

    // Selection mode and the bulk move.
    await tester.tap(find.byKey(const ValueKey('archive-select')));
    await settle(tester);
    await tester.tap(find.byKey(ValueKey('archive-item-${items[2].id}')));
    await tester.tap(find.byKey(ValueKey('archive-item-${items[3].id}')));
    await settle(tester);
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('archive-bulk-move')));
    await settle(tester);
    await tester.tap(find.byKey(ValueKey('archive-target-${other.id}')));
    await drain(tester);
    expect(
      ArchiveModel.collection(
        s.library,
        s.workspace.librarySpaces[other.id]!,
      ).total,
      2,
    );
    expect(
      ArchiveModel.collection(
        s.library,
        s.workspace.librarySpaces[a.id]!,
      ).total,
      2,
    );

    // Colour picker: all twenty colours, the choice is saved.
    await tester.tap(find.byKey(const ValueKey('archive-folder-menu')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('archive-menu-color')));
    await settle(tester);
    for (final c in NewFolderColors.all) {
      expect(find.byKey(ValueKey('archive-color-${c.id}')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('archive-color-dusty-plum')));
    await settle(tester);
    expect(s.workspace.librarySpaces[a.id]!.colorId, 'dusty-plum');
    await close(tester, s);
  });

  testWidgets('dedicated Archive search uses the library index', (
    tester,
  ) async {
    final s = await boot(tester);
    await folder(tester, s, 'Travel', notes: 3);
    await tester.pumpWidget(TheApp(state: s));
    await settle(tester);
    s.goTo(AppPage.links);
    await settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('archive-search')),
      'Travel note 2',
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('archive-results')), findsOneWidget);
    expect(find.text('Travel note 2'), findsWidgets);
    await close(tester, s);
  });

  testWidgets('Original keeps the existing Archive page', (tester) async {
    final s = await boot(tester);
    await tester.runAsync(
      () => s.setInterfaceVersion(InterfaceVersion.original),
    );
    await tester.pumpWidget(TheApp(state: s));
    await settle(tester);
    s.goTo(AppPage.links);
    await settle(tester);
    expect(find.byType(NewArchivePage), findsNothing);
    expect(find.byType(LibraryPage), findsOneWidget);
    await close(tester, s);
  });

  shareTests();
}

// Share-to-Archive, the app side: what the iOS Share Extension (and the
// Windows "Send to" menu) leaves as request files becomes Archive objects,
// which the New Archive then shows. The Swift extension itself needs a Mac /
// the cloud build to compile and a device to run: not verified here.
void shareTests() {
  testWidgets('shared text ends up in the New Archive', (tester) async {
    final dir = Directory.systemTemp.createTempSync('theapp_share_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final ws = Workspace(dir);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    )..capture.fetchPreviews = false;
    await tester.runAsync(s.init);
    final bridge = SendToBridge(dir);
    await tester.runAsync(() => bridge.requestsDir.create(recursive: true));
    File('${bridge.requestsDir.path}/a1.json').writeAsStringSync(
      '{"type":"text","value":"Remember to look at the harbour hotels"}',
    );
    File('${bridge.requestsDir.path}/a2.json').writeAsStringSync(
      '{"type":"text","value":"Second shared note about trains"}',
    );
    late int count;
    await tester.runAsync(() async {
      count = await bridge.processRequests(s.capture);
    });
    expect(count, 2);
    final objects = s.library.objects;
    expect(objects.map((o) => o.type).toSet(), {LibraryObjectType.note});
    expect(
      objects.map((o) => o.content),
      containsAll([
        'Remember to look at the harbour hotels',
        'Second shared note about trains',
      ]),
    );
    // Not filed anywhere yet: they show in the Archive's Unfiled collection.
    expect(ArchiveModel.unfiled(s.library, ws).total, 2);
    // Handing in the same request again adds no duplicate.
    File('${bridge.requestsDir.path}/a1.json').writeAsStringSync(
      '{"type":"text","value":"Remember to look at the harbour hotels"}',
    );
    await tester.runAsync(() async {
      await bridge.processRequests(s.capture);
    });
    expect(s.library.objects, hasLength(2));
    await tester.runAsync(s.flush);
    s.dispose();
    await tester.pump(const Duration(seconds: 9));
  });
}
