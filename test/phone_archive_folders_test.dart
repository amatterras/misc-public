// The phone Archive: every saved item is a folder card (tab with its Archive
// tag, a picture or the item's own text taking 40% of the folder, title and
// source), in a lazily built scrolling list with a light depth effect.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/library/library_page.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/phone/phone_archive.dart';
import 'package:flutter_application_1/phone/phone_folder_card.dart';
import 'package:flutter_application_1/phone/phone_profile.dart';
import 'package:flutter_test/flutter_test.dart';

// A real 1x1 PNG, so a saved picture exists in the attachment store.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_folders_'));
  tearDown(() {
    PhoneProfile.forced = false;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> boot(WidgetTester tester, {Size? size}) async {
    PhoneProfile.forced = true;
    tester.view.physicalSize = size ?? const Size(390, 2400);
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
    return state;
  }

  Future<void> settle(WidgetTester tester, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  Future<void> openArchive(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(TheApp(state: state));
    await settle(tester, 12);
    await tester.tap(find.byKey(const ValueKey('phone-tab-archive')));
    await settle(tester);
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(state.flush);
    await tester.pump(const Duration(seconds: 9));
    state.dispose();
  }

  Future<LibraryObject> save(
    WidgetTester tester,
    AppState s, {
    required String title,
    String? url,
    String? description,
    String? category,
    String? thumbnail,
    String? spaceId,
  }) async {
    late LibraryObject o;
    await tester.runAsync(() async {
      o = await s.library.save(
        type: url == null ? LibraryObjectType.note : LibraryObjectType.website,
        title: title,
        sourceUrl: url,
        description: description,
        content: url == null ? 'Body of $title' : null,
        thumbnailId: thumbnail,
        spaceId: spaceId,
      );
      if (category != null) await s.library.setCategory(o.id, category, true);
    });
    return o;
  }

  Finder card(String id) => find.byKey(ValueKey('archive-item-$id'));

  group('every saved item is a folder', () {
    testWidgets('one card per item, all the same size, tag on the tab', (
      tester,
    ) async {
      final s = await boot(tester);
      final a = await save(
        tester,
        s,
        title: 'Alpha',
        url: 'https://example.com/alpha',
        description: 'About alpha',
        category: 'resource',
      );
      final b = await save(tester, s, title: '', url: 'https://example.org/b');
      final c = await save(tester, s, title: 'Gamma note');
      await openArchive(tester, s);

      expect(find.byType(ArchiveFolderCard), findsNWidgets(3));
      final sizes = {
        for (final o in [a, b, c]) tester.getSize(card(o.id)).height,
      };
      expect(sizes, hasLength(1), reason: 'identical folder height');
      expect(
        tester.getSize(find.byKey(const ValueKey('folder-body')).first).height,
        ArchiveFolderCard.height,
      );
      // tag preserved on its tab; an untagged one shows its source instead
      expect(
        find.descendant(of: card(a.id), matching: find.text('Resource')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card(b.id), matching: find.text('example.org')),
        findsWidgets,
      );
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Untitled'), findsOneWidget);
      await close(tester, s);
    });

    testWidgets('the preview takes two fifths of the folder', (tester) async {
      final s = await boot(tester);
      final a = await save(tester, s, title: 'Alpha', url: 'https://a.test/x');
      await openArchive(tester, s);
      final preview = find.descendant(
        of: card(a.id),
        matching: find.byKey(const ValueKey('folder-preview')),
      );
      final ratio =
          tester.getSize(preview).height /
          tester.getSize(find.byKey(const ValueKey('folder-body'))).height;
      expect(ratio, closeTo(0.4, 0.005));
      await close(tester, s);
    });

    testWidgets('no picture: the item\'s own text; layout unchanged', (
      tester,
    ) async {
      final s = await boot(tester);
      final a = await save(
        tester,
        s,
        title: 'Has text',
        url: 'https://a.test/1',
        description: 'A description saved with the page',
      );
      final b = await save(tester, s, title: 'Bare', url: 'https://a.test/2');
      await openArchive(tester, s);
      expect(
        find.descendant(
          of: card(a.id),
          matching: find.text('A description saved with the page'),
        ),
        findsOneWidget,
      );
      // nothing but its source to show: that, not an invented picture
      expect(
        find.descendant(of: card(b.id), matching: find.byType(Image)),
        findsNothing,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('folder-preview')).first),
        tester.getSize(find.byKey(const ValueKey('folder-preview')).last),
      );
      expect(tester.takeException(), isNull);
      await close(tester, s);
    });

    testWidgets('a saved picture is shown; an unreadable one falls back', (
      tester,
    ) async {
      final s = await boot(tester);
      late String good;
      await tester.runAsync(() async {
        good = await s.workspace.attachments.importBytes(
          Uint8List.fromList(_png),
          'png',
        );
      });
      final withPicture = await save(
        tester,
        s,
        title: 'Pictured',
        url: 'https://a.test/pic',
        thumbnail: good,
      );
      final broken = await save(
        tester,
        s,
        title: 'Broken',
        url: 'https://a.test/broken',
        description: 'still readable text',
        thumbnail: 'missing-file.png',
      );
      await openArchive(tester, s);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await settle(tester);
      expect(
        find.descendant(of: card(withPicture.id), matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: 'no crash on a bad file');
      expect(
        find.descendant(
          of: card(broken.id),
          matching: find.text('still readable text'),
        ),
        findsOneWidget,
      );
      await close(tester, s);
    });
  });

  group('behaviour', () {
    testWidgets('tapping a folder opens that saved item', (tester) async {
      final s = await boot(tester);
      await save(tester, s, title: 'One', url: 'https://a.test/one');
      final two = await save(
        tester,
        s,
        title: 'Two',
        url: 'https://a.test/two',
      );
      await openArchive(tester, s);
      await tester.tap(card(two.id));
      await settle(tester, 12);
      final page = tester.widget<LibraryPage>(
        find.byType(LibraryPage, skipOffstage: false),
      );
      expect(page.initialObjectId, two.id);
      await close(tester, s);
    });

    testWidgets('a folder (collection) opens as folder cards too', (
      tester,
    ) async {
      final s = await boot(tester);
      late LibrarySpace space;
      await tester.runAsync(() async {
        space = await s.library.createSpace('Lisbon trip');
      });
      final inside = await save(
        tester,
        s,
        title: 'Hotel',
        url: 'https://a.test/hotel',
        spaceId: space.id,
      );
      await save(tester, s, title: 'Elsewhere', url: 'https://a.test/else');
      await openArchive(tester, s);
      await tester.tap(find.text('Lisbon trip'));
      await settle(tester, 12);
      expect(find.byType(PhoneFolderPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PhoneFolderPage),
          matching: find.byType(ArchiveFolderCard),
        ),
        findsOneWidget,
      );
      expect(card(inside.id), findsOneWidget);
      await close(tester, s);
    });

    testWidgets('showing the Archive changes no saved data', (tester) async {
      final s = await boot(tester);
      final a = await save(
        tester,
        s,
        title: 'Alpha',
        url: 'https://a.test/alpha',
        category: 'projects',
      );
      await save(tester, s, title: 'Beta', url: 'https://a.test/beta');
      String snapshot() => jsonEncode([
        for (final o in s.library.objects) o.toJson(),
        for (final r in s.workspace.libraryRelations.all) r.toJson(),
      ]);
      final before = snapshot();
      final count = s.library.objects.length;
      await openArchive(tester, s);
      await tester.drag(
        find.byType(CustomScrollView).last,
        const Offset(0, -300),
      );
      await settle(tester);
      expect(snapshot(), before);
      expect(s.library.objects.length, count);
      expect(s.library.categoriesOf(a.id), {'projects'});
      await close(tester, s);
    });
  });

  group('scrolling', () {
    testWidgets('a large collection is built lazily and scrolls to the end', (
      tester,
    ) async {
      final s = await boot(tester, size: const Size(390, 844));
      await tester.runAsync(() async {
        for (var i = 0; i < 300; i++) {
          await s.library.save(
            type: LibraryObjectType.website,
            title: 'Item $i',
            sourceUrl: 'https://site$i.test/page',
          );
        }
      });
      await openArchive(tester, s);
      expect(
        find.byType(ArchiveFolderCard).evaluate().length,
        lessThan(12),
        reason: 'only what is near the screen is built',
      );
      for (var i = 0; i < 30; i++) {
        await tester.fling(
          find.byType(CustomScrollView).last,
          const Offset(0, -2000),
          4000,
        );
        await tester.pump(const Duration(milliseconds: 400));
      }
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(ArchiveFolderCard), findsWidgets);
      expect(find.byType(ArchiveFolderCard).evaluate().length, lessThan(12));
      await close(tester, s);
    });

    test('depth: full size in the middle, smaller toward the edges', () {
      expect(ScrollDepth.scaleFor(0), 1);
      expect(ScrollDepth.scaleFor(1), ScrollDepth.edgeScale);
      expect(ScrollDepth.scaleFor(-1), ScrollDepth.edgeScale);
      expect(ScrollDepth.scaleFor(5), ScrollDepth.edgeScale, reason: 'clamped');
      expect(ScrollDepth.scaleFor(0.5), closeTo(0.97, 1e-9));
      expect(
        ScrollDepth.edgeScale,
        greaterThanOrEqualTo(0.9),
        reason: 'subtle',
      );
    });

    testWidgets('visible folders are scaled by their place, within bounds', (
      tester,
    ) async {
      final s = await boot(tester, size: const Size(390, 844));
      await tester.runAsync(() async {
        for (var i = 0; i < 12; i++) {
          await s.library.save(
            type: LibraryObjectType.website,
            title: 'Item $i',
            sourceUrl: 'https://site$i.test/page',
          );
        }
      });
      await openArchive(tester, s);
      await tester.drag(
        find.byType(CustomScrollView).last,
        const Offset(0, -150),
      );
      await settle(tester);
      final scales = [
        for (final t in tester.widgetList<Transform>(
          find.descendant(
            of: find.byType(ScrollDepth),
            matching: find.byType(Transform),
          ),
        ))
          t.transform.entry(0, 0),
      ];
      expect(scales, isNotEmpty);
      for (final v in scales) {
        expect(v, inInclusiveRange(ScrollDepth.edgeScale - 0.001, 1));
      }
      expect(scales.any((v) => v < 1), isTrue, reason: 'the effect is on');
      await close(tester, s);
    });

    testWidgets('reduced motion: no scaling at all', (tester) async {
      final s = await boot(tester, size: const Size(390, 844));
      await tester.runAsync(() async {
        for (var i = 0; i < 6; i++) {
          await s.library.save(
            type: LibraryObjectType.website,
            title: 'Item $i',
            sourceUrl: 'https://site$i.test/page',
          );
        }
      });
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await openArchive(tester, s);
      await tester.drag(
        find.byType(CustomScrollView).last,
        const Offset(0, -120),
      );
      await settle(tester);
      expect(
        find.descendant(
          of: find.byType(ScrollDepth),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      await close(tester, s);
    });
  });
}
