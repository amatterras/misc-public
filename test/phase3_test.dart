// Phase 3: the Links library (tagged link cards on a board, share-in) and
// the home-screen widget snapshot (today + tomorrow, derived only). The
// Swift widget is checked only for its wiring here; it runs on a device.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_application_1/data/models/tag_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_text.dart';
import 'package:flutter_application_1/features/links/link_tags.dart';
import 'package:flutter_application_1/features/widgets/widget_snapshot.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_p3_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> appState({IosBridge? ios, String name = 'app'}) async {
    final ws = Workspace(Directory('${dir.path}$sep$name'));
    await ws.load();
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
      ios: ios,
    );
    s.capture.fetchPreviews = false; // tests never fetch from the web
    await s.init();
    return s;
  }

  group('link tags', () {
    test('exactly the five tags with their colours', () {
      expect(
        [for (final t in LinkTag.values) (t.label, t.color.toARGB32())],
        [
          ('Resource', 0xFF3060B0),
          ('Projects', 0xFFB03040),
          ('Other', 0xFFF0C060),
          ('Shopping', 0xFF409060),
          ('Second-brain', 0xFFE0A0D0),
        ],
      );
      expect(LinkTag.byId('second-brain'), LinkTag.secondBrain);
      expect(LinkTag.of(['shopping', 'unknown', 'resource']), [
        LinkTag.resource,
        LinkTag.shopping,
      ]);
    });

    test('tags are stored on the link, and old links load unchanged', () {
      final old = {
        'id': 'a',
        'kind': 'link',
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': '2026-01-01T00:00:00Z',
        'url': 'https://example.com',
      };
      final a = Asset.fromJson(old);
      expect(a.linkTags, isEmpty);
      expect(a.toJson().containsKey('linkTags'), isFalse);
      final tagged = a.copyWith(linkTags: ['resource', 'projects']);
      final back = Asset.fromJson(
        jsonDecode(jsonEncode(tagged.toJson())) as Map<String, dynamic>,
      );
      expect(back.linkTags, ['resource', 'projects']);
      // Other changes keep the tags.
      expect(back.copyWith(title: 'x').linkTags, ['resource', 'projects']);
    });

    test('a tagged card shows its tags and grows to fit them', () {
      const item = LinkItem(
        id: 'l',
        position: Offset.zero,
        width: LinkItem.defaultWidth,
        assetId: 'a',
      );
      final plain = Asset(
        id: 'a',
        kind: AssetKind.link,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        url: 'https://example.com',
        title: 'Example',
      );
      final without = layoutLinkCard(item, plain);
      final withTags = layoutLinkCard(
        item,
        plain.copyWith(linkTags: ['resource', 'secondBrain', 'second-brain']),
      );
      expect(without.chips, isEmpty);
      expect(withTags.chips.map((c) => c.$2), [
        LinkTag.resource.color,
        LinkTag.secondBrain.color,
      ]);
      expect(withTags.height, greaterThan(without.height));
      for (final (rect, _, _) in withTags.chips) {
        expect(rect.right, lessThanOrEqualTo(item.width));
      }
      without.dispose();
      withTags.dispose();
    });
  });

  group('links board', () {
    test('links go into free grid places, once each, and stay put', () async {
      final s = await appState();
      final a = s.capture.link('https://a.example');
      final b = s.capture.link('https://b.example');
      final first = await s.addToLinks(a);
      final second = await s.addToLinks(b);
      expect(second.position, isNot(first.position));
      final again = await s.addToLinks(s.capture.link('https://a.example'));
      expect(again.id, first.id, reason: 'same link is not added twice');
      expect(s.linksBoard!.items.whereType<LinkItem>(), hasLength(2));
      // Hidden from the Canvas list, saved as its own document.
      await s.flush();
      expect(s.canvasList.map((c) => c.id), isNot(contains(linksBoardId)));
      final saved = (await s.canvases.load(linksBoardId))!;
      expect(saved.isLinksBoard, isTrue);
      expect(saved.kind, 'links');
      expect(saved.items.whereType<LinkItem>(), hasLength(2));
      s.dispose();

      // Reopened: the same two cards in the same places.
      final again2 = await appState();
      final board = await again2.openLinksBoard();
      expect(board.items.whereType<LinkItem>().map((i) => i.position), [
        first.position,
        second.position,
      ]);
      again2.dispose();
    });

    test('opening an empty library writes nothing', () async {
      final s = await appState();
      await s.openLinksBoard();
      await s.flush();
      expect(await s.canvases.load(linksBoardId), isNull);
      s.dispose();
    });

    test('categories can be added from share-in and changed later', () async {
      final s = await appState();
      final handled = await s.addSharedLinkToLinks(
        Uri.parse(
          'theapp://capture?to=links&tags=Resource,projects'
          '&url=${Uri.encodeComponent('https://docs.example/a?b=1&c=2')}',
        ),
      );
      expect(handled, isTrue);
      final saved = s.library.objects.single;
      expect(saved.sourceUrl, 'https://docs.example/a?b=1&c=2');
      expect(s.library.categoriesOf(saved.id), {'resource', 'projects'});
      await s.library.setCategory(saved.id, 'projects', false);
      await s.library.setCategory(saved.id, 'shopping', true);
      expect(s.library.categoriesOf(saved.id), {'resource', 'shopping'});
      // Not for the Archive shortcut: left to the ordinary share code.
      expect(
        await s.addSharedLinkToLinks(
          Uri.parse('theapp://capture?url=https%3A%2F%2Fx.example'),
        ),
        isFalse,
      );
      expect(
        await s.addSharedLinkToLinks(Uri.parse('theapp://capture?to=links')),
        isFalse,
      );
      s.dispose();
    });

    test('the board and tags reach the other device', () async {
      HttpOverrides.global = null;
      final hub = await HubServer.start(
        dir: Directory('${dir.path}${sep}hub'),
        port: 0,
        dailyBackups: false,
      );
      addTearDown(hub.stop);
      Future<SyncEngine> engineFor(AppState s, String name) async {
        final token = await hub.auth.register(
          hub.auth.createPairingCode(),
          s.workspace.device!.id,
          name,
        );
        return SyncEngine(
          workspace: s.workspace,
          canvases: s.canvases as FileCanvasRepository,
          client: SyncClient(
            Uri.parse('http://127.0.0.1:${hub.port}'),
            token: token,
          ),
        );
      }

      final pc = await appState(name: 'pc');
      final ipad = await appState(name: 'ipad');
      final asset = pc.capture.link('https://shared.example');
      await pc.addToLinks(asset, tags: ['second-brain']);
      await pc.flush();
      await (await engineFor(pc, 'pc')).syncOnce();
      await (await engineFor(ipad, 'ipad')).syncOnce();
      final doc = (await ipad.canvases.load(linksBoardId))!;
      final card = doc.items.whereType<LinkItem>().single;
      expect(ipad.workspace.assets[card.assetId]!.linkTags, ['second-brain']);
      expect(doc.isLinksBoard, isTrue);
      pc.dispose();
      ipad.dispose();
    });

    testWidgets('Archive: filter by category and tag, and label an item', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(appState))!;
      late LibraryObject one, two;
      late CustomTag tag;
      await tester.runAsync(() async {
        one = await s.library.save(
          type: LibraryObjectType.website,
          sourceUrl: 'https://one.example',
          title: 'One',
        );
        two = await s.library.save(
          type: LibraryObjectType.website,
          sourceUrl: 'https://two.example',
          title: 'Two',
        );
        await s.library.setCategory(one.id, 'resource', true);
        tag = s.workspace.createTag('Reading', 0xFF2878F0).tag;
        await s.library.setTags(two.id, {tag.id});
      });
      await tester.pumpWidget(TheApp(state: s));
      s.goTo(AppPage.links);
      await tester.pump();
      await tester.pump();
      expect(find.text('One'), findsOne);
      expect(find.text('Two'), findsOne);

      final resource = find.byKey(const ValueKey('library-filter-resource'));
      expect(resource, findsOne);
      await tester.tap(resource);
      await tester.pump();
      expect(find.text('One'), findsOne);
      expect(find.text('Two'), findsNothing);
      await tester.tap(resource);
      await tester.pump();
      expect(find.text('Two'), findsOne);

      await tester.tap(find.byKey(ValueKey('library-filter-tag-${tag.id}')));
      await tester.pump();
      expect(find.text('One'), findsNothing);
      expect(find.text('Two'), findsOne);
      await tester.tap(find.byKey(const ValueKey('library-filter-clear')));
      await tester.pump();
      expect(find.text('One'), findsOne);
      expect(find.text('Two'), findsOne);

      // Label an item from its dialog.
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-category-shopping')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(s.library.categoriesOf(one.id), {'resource', 'shopping'});

      // Phone width still fits.
      tester.view.physicalSize = const Size(375, 812);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.runAsync(s.flush);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      s.dispose();
    });
  });

  group('widget snapshot', () {
    late Workspace ws;
    final now = DateTime(2026, 10, 23, 8, 15);
    final today = DateTime(2026, 10, 23);
    final tomorrow = DateTime(2026, 10, 24);

    setUp(() async {
      ws = Workspace(dir);
      await ws.load();
    });

    CalendarEntry event(String name, DateTime day, {int? at}) => CalendarEntry(
      id: newId(),
      category: CalendarCategory.events,
      name: name,
      createdAt: now,
      updatedAt: now,
      startDate: day,
      startMinutes: at,
      colorIndex: 2,
    );

    test('today and tomorrow with tasks, events, times and done state', () {
      ws.saveEntry(event('Dentist', today, at: 9 * 60 + 30));
      final t = ws.createTask('Hand in essay', dueDate: today);
      ws.tasks.put(ws.tasks[t.id]!.copyWith(dueMinutes: () => 14 * 60));
      final done = ws.createTask('Buy milk', dueDate: today);
      ws.toggleTask(done.id);
      ws.createTask('Gym', dueDate: tomorrow);
      ws.createTask('Someday'); // no date: not shown
      ws.createTask('Next week', dueDate: DateTime(2026, 10, 30));

      final snap = WidgetSnapshot.build(ws, now);
      final days = (snap['days']! as List).cast<Map<String, Object?>>();
      expect(snap['version'], 1);
      expect(days.map((d) => d['title']), ['Today', 'Tomorrow']);
      expect(days.map((d) => d['date']), ['2026-10-23', '2026-10-24']);
      final items = (days[0]['items']! as List).cast<Map<String, Object?>>();
      expect(items.map((i) => i['title']), [
        'Dentist',
        'Hand in essay',
        'Buy milk',
      ]);
      expect(items[0]['kind'], 'event');
      expect(items[0]['time'], '09:30');
      expect(items[1]['time'], '14:00');
      expect(items[1]['link'], 'theapp://open?task=${t.id}');
      expect(items[0]['link'], 'theapp://open?day=2026-10-23');
      expect(items[2]['done'], isTrue);
      expect(days[1]['total'], 1);
      // Valid JSON for the Swift side.
      expect(() => jsonEncode(snap), returnsNormally);
    });

    test('a busy day keeps 12 items and the full count for "+N more"', () {
      for (var i = 0; i < 20; i++) {
        ws.createTask('Task $i', dueDate: today);
      }
      final day = (WidgetSnapshot.build(ws, now)['days']! as List).first as Map;
      expect(day['total'], 20);
      expect(day['items'] as List, hasLength(WidgetSnapshot.maxItemsPerDay));
    });

    test('building a snapshot changes no records', () async {
      ws.createTask('Read', dueDate: today);
      ws.saveEntry(event('Party', tomorrow));
      await ws.flush();
      String records() => jsonEncode([
        for (final t in ws.tasks.all) ws.tasks.jsonOf(t.id),
        for (final e in ws.entries.all) ws.entries.jsonOf(e.id),
      ]);
      final before = records();
      WidgetSnapshot.build(ws, now);
      expect(records(), before);
      expect(ws.tasks.all, hasLength(1));
      expect(ws.entries.all, hasLength(1));
    });

    test('deep links: task, day, and everything else ignored', () {
      expect(WidgetSnapshot.parseLink(Uri.parse('theapp://open?task=abc')), (
        taskId: 'abc',
        day: null,
      ));
      expect(
        WidgetSnapshot.parseLink(Uri.parse('theapp://open?day=2026-10-24')),
        (taskId: null, day: DateTime(2026, 10, 24)),
      );
      expect(WidgetSnapshot.parseLink(Uri.parse('theapp://open')), isNull);
      expect(
        WidgetSnapshot.parseLink(Uri.parse('theapp://capture?url=x')),
        isNull,
      );
      expect(
        WidgetSnapshot.parseLink(Uri.parse('https://open?task=a')),
        isNull,
      );
    });

    test('a tapped widget opens the task or the calendar day', () async {
      final s = await appState();
      final t = s.workspace.createTask('Essay', dueDate: today);
      expect(s.openWidgetLink(Uri.parse('theapp://open?task=${t.id}')), isTrue);
      expect(s.page, AppPage.calendar); // Tasks live in its task column
      expect(s.calendarTasksOpen, isTrue);
      expect(s.selectedTaskId, t.id);
      expect(
        s.openWidgetLink(Uri.parse('theapp://open?day=2026-10-24')),
        isTrue,
      );
      expect(s.page, AppPage.calendar);
      expect(s.focusDay, tomorrow);
      expect(s.openWidgetLink(Uri.parse('theapp://capture?url=x')), isFalse);
      await s.flush(); // pending page and task-column settings
      s.dispose();
    });
  });

  group('widget updates (simulated iOS channel)', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(IosBridge.channelName);
    late List<String> written;
    late bool groupAvailable;
    setUp(() {
      written = [];
      groupAvailable = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'widgetSnapshot':
            if (!groupAvailable) return false;
            written.add(call.arguments as String);
            return true;
          case 'initialLinks':
            return <Object?>[];
        }
        return null;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('written at start, after changes, and only when changed', () async {
      final s = await appState(ios: IosBridge());
      final at = DateTime(2031, 3, 3, 10); // not today: start-up wrote today
      written.clear();
      expect(await s.updateWidgets(now: at), isTrue);
      expect(await s.updateWidgets(now: at), isFalse, reason: 'no change');
      s.workspace.createTask('New', dueDate: DateTime(2031, 3, 3));
      expect(await s.updateWidgets(now: at), isTrue);
      expect(written, hasLength(2));
      final last = jsonDecode(written.last) as Map<String, dynamic>;
      expect((last['days'] as List).first['total'], 1);
      s.dispose();
    });

    test('no App Group: nothing breaks, the app keeps working', () async {
      groupAvailable = false;
      final s = await appState(ios: IosBridge());
      expect(await s.updateWidgets(), isFalse);
      s.workspace.createTask('Still fine');
      expect(s.workspace.tasks.all, hasLength(1));
      s.dispose();
    });

    test('Windows (no iOS bridge): no snapshot', () async {
      final s = await appState();
      expect(await s.updateWidgets(), isFalse);
      s.dispose();
    });
  });

  group('iOS widget extension wiring', () {
    String read(String path) => File(path).readAsStringSync();

    test('target, plist, entitlements and App Group agree', () {
      final project = read('ios/Runner.xcodeproj/project.pbxproj');
      expect(
        project,
        contains('productType = "com.apple.product-type.app-extension"'),
      );
      expect(project, contains('TheAppWidget.appex in Embed App Extensions'));
      expect(
        project,
        contains(
          'CODE_SIGN_ENTITLEMENTS = TheAppWidget/TheAppWidget.entitlements',
        ),
      );
      expect('{'.allMatches(project).length, '}'.allMatches(project).length);
      expect(
        read('ios/TheAppWidget/Info.plist'),
        contains('com.apple.widgetkit-extension'),
      );
      const group = 'group.com.theapp.shared';
      for (final f in [
        'ios/TheAppWidget/TheAppWidget.entitlements',
        'ios/Runner/Runner.entitlements',
        'ios/ShareExtension/ShareExtension.entitlements',
        // The name lives in one shared file (see AppGroup.swift).
        'ios/Shared/AppGroup.swift',
      ]) {
        expect(read(f), contains(group), reason: f);
      }
      // All three targets use that one resolver (never a hard-coded name),
      // so the app, the extension and the widgets agree on one folder, and
      // all three compile it.
      for (final f in [
        'ios/TheAppWidget/TheAppWidget.swift',
        'ios/Runner/AppDelegate.swift',
        'ios/ShareExtension/ShareViewController.swift',
      ]) {
        final source = read(f);
        expect(source, contains('AppGroup.'), reason: f);
        expect(source, isNot(contains('"$group"')), reason: f);
      }
      expect(
        RegExp('AppGroup.swift in Sources').allMatches(project).length,
        greaterThanOrEqualTo(3),
        reason: 'AppGroup.swift must be in the Runner, widget and share '
            'extension source phases',
      );
      final swift = read('ios/TheAppWidget/TheAppWidget.swift');
      // Reads the same file and fields the Dart side writes.
      expect(swift, contains('widget_snapshot.json'));
      expect(
        read('ios/Runner/AppDelegate.swift'),
        contains('widget_snapshot.json'),
      );
      for (final key in [
        'date',
        'title',
        'link',
        'total',
        'items',
        'kind',
        'time',
        'done',
        'color',
      ]) {
        expect(swift, contains('let $key:'), reason: key);
      }
      expect(swift, contains('+\\(more) more'));
      expect(swift, contains('systemBackground'), reason: 'light and dark');
    });
  });
}
