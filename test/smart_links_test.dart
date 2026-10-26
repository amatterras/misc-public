// Smart Workspace Links: stable-id links between notes, mindmaps (and their
// objects), calendar entries and Archive items; rename / move / archive /
// delete / restore / sync of the targets; backlinks; navigation with a way
// back; search; and the panel and picker on screen.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/search/search_dialog.dart';
import 'package:flutter_application_1/features/smartlinks/smart_links.dart';
import 'package:flutter_application_1/features/smartlinks/smart_links_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState s;

  Future<AppState> boot(Directory d) async {
    final ws = Workspace(d);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    state.capture.fetchPreviews = false;
    await state.init();
    return state;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_smartlinks_');
    s = await boot(dir);
  });
  tearDown(() async {
    await s.flush();
    s.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  CalendarEntry entry(String id, String name, {String notes = ''}) {
    final day = DateTime(2026, 10, 26);
    return CalendarEntry(
      id: id,
      category: CalendarCategory.events,
      name: name,
      createdAt: day,
      updatedAt: day,
      startDate: day,
      endDate: day,
      notes: notes,
    );
  }

  group('tokens', () {
    test('make, find, read as text, remove', () {
      const ref = WorkspaceRef(RefKind.note, 'abc123');
      final token = ref.token('Weekly [plan] | goals');
      expect(token, '[[theapp:note/abc123|Weekly plan goals]]');
      final text = 'See $token for more, and '
          '${const WorkspaceRef(RefKind.object, 'c1', 'i9').token('Idea')}.';
      final found = findLinks(text);
      expect(found.map((t) => t.ref), [
        ref,
        const WorkspaceRef(RefKind.object, 'c1', 'i9'),
      ]);
      expect(found.first.label, 'Weekly plan goals');
      expect(text.substring(found.first.start, found.first.end), token);
      expect(plainLinkText(text), 'See Weekly plan goals for more, and Idea.');
      expect(removeLinkTo(text, ref), startsWith('See Weekly plan goals for'));
      expect(findLinks(removeLinkTo(text, ref)), hasLength(1));
    });

    test('damaged or foreign tokens are ignored, plain [[Title]] untouched', () {
      expect(findLinks('[[theapp:nope/x]] [[theapp:note/]] [[Other note]]'), isEmpty);
      expect(findLinks('[[theapp:obj/c1]]'), isEmpty, reason: 'needs an object');
      expect(findLinks('[[theapp:note/a#b]]'), isEmpty, reason: 'no object here');
      final note = Note(
        id: 'n',
        title: 't',
        body: '[[Other note]] [[theapp:note/abc|X]]',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(note.linkedTitles.toList(), ['Other note']);
    });
  });

  group('targets change', () {
    test('rename, move, archive, delete, restore', () {
      final ws = s.workspace;
      final target = ws.createNote(title: 'Original name');
      final ref = WorkspaceRef(RefKind.note, target.id);
      expect(resolveRef(s, ref).title, 'Original name');

      // Renamed: same link, new name.
      ws.notes.put(target.copyWith(title: 'Renamed'));
      expect(resolveRef(s, ref).title, 'Renamed');
      expect(resolveRef(s, ref).health, LinkHealth.ok);

      // Moved to a folder: still found.
      final folder = ws.createFolder('Projects');
      ws.notes.put(ws.notes[target.id]!.copyWith(folderId: () => folder.id));
      expect(resolveRef(s, ref).health, LinkHealth.ok);

      // Deleted: marked deleted with its last name; not opened.
      ws.deleteNote(target.id);
      var r = resolveRef(s, ref, fallbackLabel: 'old label');
      expect(r.health, LinkHealth.deleted);
      expect(r.title, 'Renamed');
      expect(r.opens, isFalse);

      // A new note never takes the old one's place.
      final other = ws.createNote(title: 'Renamed');
      expect(other.id, isNot(target.id));
      expect(resolveRef(s, ref).health, LinkHealth.deleted);
      expect(resolveRef(s, WorkspaceRef(RefKind.note, other.id)).health,
          LinkHealth.ok);

      // Restored: the same link works again.
      ws.restoreNoteVersion(ws.deletedNotes().first.id);
      r = resolveRef(s, ref);
      expect(r.health, LinkHealth.ok);
      expect(r.title, 'Renamed');
    });

    test('archived entry still opens; deleted one is marked', () {
      final ws = s.workspace;
      ws.saveEntry(entry('e1', 'Dentist', notes: 'bring the form'));
      final ref = const WorkspaceRef(RefKind.entry, 'e1');
      expect(resolveRef(s, ref).health, LinkHealth.ok);
      expect(resolveRef(s, ref).preview, contains('bring the form'));
      ws.saveEntry(ws.entries['e1']!.copyWith(archived: true));
      expect(resolveRef(s, ref).health, LinkHealth.archived);
      expect(resolveRef(s, ref).opens, isTrue);
      ws.entries.remove('e1');
      expect(resolveRef(s, ref, fallbackLabel: 'Dentist').health,
          LinkHealth.deleted);
      expect(resolveRef(s, ref, fallbackLabel: 'Dentist').title, 'Dentist');
    });

    test('Archive items and mindmaps', () async {
      final ws = s.workspace;
      final a = ws.linkAsset('https://example.com/a', title: 'Example A');
      final ref = WorkspaceRef(RefKind.asset, a.id);
      expect(resolveRef(s, ref).title, 'Example A');
      ws.assets.put(a.copyWith(title: 'Example B'));
      expect(resolveRef(s, ref).title, 'Example B');
      ws.assets.remove(a.id);
      expect(resolveRef(s, ref).health, LinkHealth.deleted);

      final canvas = WorkspaceRef(RefKind.canvas, s.canvas!.id);
      expect(resolveRef(s, canvas).health, LinkHealth.ok);
      expect(
        resolveRef(s, const WorkspaceRef(RefKind.canvas, 'gone')).health,
        LinkHealth.deleted,
      );
    });

    test('a mindmap object that was deleted is told apart', () async {
      final c = s.canvas!;
      c.addItems([
        TextItem(
          id: 'idea',
          position: Offset.zero,
          width: 200,
          minHeight: 40,
          text: 'Big idea\nmore',
        ),
      ]);
      final ref = WorkspaceRef(RefKind.object, c.id, 'idea');
      var r = await resolveObject(s, ref);
      expect(r.health, LinkHealth.ok);
      expect(r.title, 'Big idea more');
      c.select(const ['idea']);
      c.deleteSelection();
      r = await resolveObject(s, ref);
      expect(r.health, LinkHealth.deleted);
      c.undo();
      r = await resolveObject(s, ref);
      expect(r.health, LinkHealth.ok, reason: 'undo restores it');
    });
  });

  group('backlinks', () {
    test('found in notes, entries, Archive items and mindmaps', () async {
      final ws = s.workspace;
      final target = ws.createNote(title: 'Target');
      final ref = WorkspaceRef(RefKind.note, target.id);
      final token = ref.token('Target');

      final n = ws.createNote(title: 'Source note');
      ws.notes.put(n.copyWith(body: 'intro $token outro'));
      ws.saveEntry(entry('e2', 'Meeting', notes: 'agenda: $token'));
      final a = ws.linkAsset('https://example.com/src', title: 'Source link');
      ws.assets.put(a.copyWith(description: 'see $token'));
      s.canvas!.addItems([
        TextItem(
          id: 't1',
          position: Offset.zero,
          width: 200,
          minHeight: 40,
          text: 'map says $token',
        ),
      ]);
      await s.flush();

      final back = backlinksTo(s, ref);
      expect(
        back.map((b) => b.source.kind).toSet(),
        {RefKind.note, RefKind.entry, RefKind.asset, RefKind.canvas},
      );
      expect(back.firstWhere((b) => b.source.kind == RefKind.note).title,
          'Source note');
      expect(back.firstWhere((b) => b.source.kind == RefKind.note).snippet,
          contains('Target'));
      // A note linking to itself is not its own backlink.
      ws.notes.put(ws.notes[target.id]!.copyWith(body: 'me: $token'));
      expect(backlinksTo(s, ref).any((b) => b.source == ref), isFalse);

      // Renaming the source updates the backlink's title; deleting removes it.
      ws.notes.put(ws.notes[n.id]!.copyWith(title: 'Renamed source'));
      expect(
        backlinksTo(s, ref).map((b) => b.title),
        contains('Renamed source'),
      );
      ws.deleteNote(n.id);
      expect(
        backlinksTo(s, ref).where((b) => b.source.kind == RefKind.note),
        isEmpty,
      );
    });

    test('survive a sync: the records on another device give the same', () async {
      final ws = s.workspace;
      final target = ws.createNote(title: 'Shared');
      final ref = WorkspaceRef(RefKind.note, target.id);
      final src = ws.createNote(title: 'Writer');
      ws.notes.put(src.copyWith(body: 'about ${ref.token('Shared')}'));
      await s.flush();

      // The other device receives the same records (as JSON, like sync).
      final dir2 = Directory.systemTemp.createTempSync('theapp_smartlinks2_');
      addTearDown(() {
        try {
          dir2.deleteSync(recursive: true);
        } catch (_) {}
      });
      final s2 = await boot(dir2);
      addTearDown(() async {
        await s2.flush();
        s2.dispose();
      });
      for (final n in ws.notes.all) {
        s2.workspace.notes.put(
          Note.fromJson(jsonDecode(jsonEncode(n.toJson())) as Map<String, dynamic>),
        );
      }
      expect(resolveRef(s2, ref).title, 'Shared');
      expect(backlinksTo(s2, ref).map((b) => b.title), ['Writer']);
      // Deleting on one device shows as deleted on the other once it syncs.
      s2.workspace.deleteNote(target.id);
      expect(resolveRef(s2, ref).health, LinkHealth.deleted);
      expect(resolveRef(s, ref).health, LinkHealth.ok);
    });
  });

  group('navigation', () {
    test('opens the target, keeps a way back, refuses deleted targets', () async {
      final ws = s.workspace;
      final from = ws.createNote(title: 'From');
      final to = ws.createNote(title: 'To');
      s.openNote(from.id);
      final fromRef = WorkspaceRef(RefKind.note, from.id);

      expect(
        await openWorkspaceRef(
          s,
          WorkspaceRef(RefKind.note, to.id),
          from: fromRef,
        ),
        isTrue,
      );
      expect(s.page, AppPage.notes);
      expect(s.selectedNoteId, to.id);
      expect(s.linkReturn.value.single.label, 'From');

      s.selectedNoteId = null;
      await goBackFromLink(s);
      expect(s.selectedNoteId, from.id);
      expect(s.linkReturn.value, isEmpty, reason: 'going back leaves no trail');

      // A deleted target is not opened and nothing is remembered.
      ws.deleteNote(to.id);
      s.selectedNoteId = null;
      expect(
        await openWorkspaceRef(
          s,
          WorkspaceRef(RefKind.note, to.id),
          from: fromRef,
          label: 'To',
        ),
        isFalse,
      );
      expect(s.selectedNoteId, isNull);
      expect(s.toast.value, contains('was deleted'));
      expect(s.linkReturn.value, isEmpty);
    });

    test('a mindmap object is revealed and selected', () async {
      final c = s.canvas!;
      c.addItems([
        TextItem(
          id: 'far',
          position: const Offset(4000, 3000),
          width: 200,
          minHeight: 40,
          text: 'far away',
        ),
      ]);
      s.goTo(AppPage.home);
      expect(
        await openWorkspaceRef(s, WorkspaceRef(RefKind.object, c.id, 'far')),
        isTrue,
      );
      expect(s.page, AppPage.canvas);
      expect(s.canvas!.selection, {'far'});
      // An object removed meanwhile is refused.
      c.select(const ['far']);
      c.deleteSelection();
      expect(
        await openWorkspaceRef(s, WorkspaceRef(RefKind.object, c.id, 'far')),
        isFalse,
      );
    });

    test('an entry opens on its day', () async {
      s.workspace.saveEntry(entry('e3', 'Trip'));
      expect(
        await openWorkspaceRef(s, const WorkspaceRef(RefKind.entry, 'e3')),
        isTrue,
      );
      expect(s.page, AppPage.calendar);
    });
  });

  test('search reads links as their labels, never their ids', () {
    final ws = s.workspace;
    final t = ws.createNote(title: 'Pelican');
    final n = ws.createNote(title: 'Holder');
    ws.notes.put(
      n.copyWith(body: 'remember ${WorkspaceRef(RefKind.note, t.id).token('Pelican')}'),
    );
    expect(searchEverything(s, 'theapp'), isEmpty);
    expect(searchEverything(s, t.id), isEmpty);
    final hit = searchEverything(s, 'remember pelican');
    expect(hit.map((r) => r.title), contains('Holder'));
    expect(hit.first.subtitle, contains('remember Pelican'));
  });

  group('on screen', () {
    testWidgets('panel: links, hover preview, deleted marking, backlinks', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ws = s.workspace;
      final live = ws.createNote(title: 'Live note');
      ws.notes.put(live.copyWith(body: 'first words of the live note'));
      final gone = ws.createNote(title: 'Gone note');
      final goneRef = WorkspaceRef(RefKind.note, gone.id);
      final owner = ws.createNote(title: 'Owner');
      final writer = ws.createNote(title: 'Writer');
      final ownerRef = WorkspaceRef(RefKind.note, owner.id);
      final text =
          'a ${WorkspaceRef(RefKind.note, live.id).token('Live note')} '
          'b ${goneRef.token('Gone note')}';
      ws.notes.put(owner.copyWith(body: text));
      ws.notes.put(writer.copyWith(body: 'x ${ownerRef.token('Owner')}'));
      ws.deleteNote(gone.id);
      String? removed;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SmartLinksPanel(
                state: s,
                owner: ownerRef,
                text: text,
                onRemoveLink: (t) => removed = t.id,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Live note'), findsOneWidget);
      expect(find.textContaining('Gone note  (deleted)'), findsOneWidget);
      expect(find.text('Writer'), findsOneWidget); // backlink
      // Hover/long-press preview text.
      expect(
        find.byTooltip('Note: Live note\nfirst words of the live note'),
        findsOneWidget,
      );
      // The broken link can be removed; opening it does not navigate.
      await tester.tap(find.byTooltip('Remove this broken link'));
      expect(removed, gone.id);
      s.selectedNoteId = null;
      await tester.tap(find.textContaining('Gone note'));
      await tester.pump();
      expect(s.selectedNoteId, isNull);
      expect(s.toast.value, contains('deleted'));
      // A live link opens and the back trail is kept.
      await tester.tap(find.text('Live note'));
      await tester.pump();
      expect(s.selectedNoteId, live.id);
      expect(s.linkReturn.value.last.label, 'Owner');
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the picker finds things and returns a link token', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ws = s.workspace;
      final n = ws.createNote(title: 'Zebra facts');
      ws.createNote(title: 'Other');
      String? token;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => token = await pickWorkspaceLink(context, s),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('link-picker-field')),
        'zebra',
      );
      await tester.pumpAndSettle();
      expect(find.text('Other'), findsNothing);
      await tester.tap(find.byKey(ValueKey('link-note/${n.id}')));
      await tester.pumpAndSettle();
      expect(token, '[[theapp:note/${n.id}|Zebra facts]]');
    });

    testWidgets('inserting a link puts it at the cursor', (tester) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final n = s.workspace.createNote(title: 'Insert target');
      final controller = TextEditingController(text: 'before after')
        ..selection = const TextSelection.collapsed(offset: 7);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: InsertLinkButton(state: s, controller: controller),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('insert-workspace-link')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('link-note/${n.id}')));
      await tester.pumpAndSettle();
      expect(
        controller.text,
        'before [[theapp:note/${n.id}|Insert target]]after',
      );
    });
  });
}
