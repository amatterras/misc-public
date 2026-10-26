// Custom tags (one registry for the Archive and the Mindmap): create,
// rename, recolor, delete, the 15-tag limit, duplicate names, readable
// text on every colour, and persistence.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/models/tag_models.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/tags/tag_ui.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance() + 0.05, y = b.computeLuminance() + 0.05;
  return x > y ? x / y : y / x;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Workspace ws;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_tags_');
    ws = Workspace(dir);
    await ws.load();
  });
  tearDown(() async {
    ws.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('create, rename, recolor, delete', () {
    final t = ws.createTag('  Ideas   for  later ', 0xFFFF6A00).tag;
    expect(t.name, 'Ideas for later');
    expect(ws.renameTag(t.id, 'Plans'), isNull);
    expect(ws.customTags[t.id]!.name, 'Plans');
    ws.recolorTag(t.id, 0xFF5CC8FF);
    expect(ws.customTags[t.id]!.color, 0xFF5CC8FF);
    ws.deleteTag(t.id);
    expect(ws.customTags[t.id], isNull);
  });

  test('duplicate names are refused after trimming, in any case', () {
    final a = ws.createTag('Work', 0xFF2878F0).tag;
    final b = ws.createTag('Home', 0xFF176B4D).tag;
    final again = ws.createTag('  wORk ', 0xFFFF3B30);
    expect(again.existed, isTrue);
    expect(again.tag.id, a.id);
    expect(ws.renameTag(b.id, ' WORK'), contains('already a tag'));
    expect(ws.renameTag(b.id, 'Home'), isNull, reason: 'its own name');
    expect(ws.renameTag(b.id, '   '), isNotNull);
    // Turkish dotted / dotless i are one letter.
    ws.createTag('Işık', 0xFFB5DC32);
    expect(ws.createTag('IŞIK', 0xFFB5DC32).existed, isTrue);
  });

  test('at most 15 tags; the 16th is refused with a clear message', () {
    for (var i = 0; i < CustomTag.maxTags; i++) {
      ws.createTag('Tag $i', InkColors.all[i].toARGB32());
    }
    expect(ws.customTags.all, hasLength(15));
    expect(ws.tagLimitReached, isTrue);
    expect(
      () => ws.createTag('One too many', 0xFFFF3B30),
      throwsA(
        isA<TagLimitReached>().having(
          (e) => e.message,
          'message',
          contains('15 tags'),
        ),
      ),
    );
    expect(ws.customTags.all, hasLength(15));
    // An existing name is still just reused at the limit.
    expect(ws.createTag('tag 3', 0xFFFF3B30).existed, isTrue);
    // Deleting one makes room again.
    ws.deleteTag(ws.tagNamed('Tag 0')!.id);
    expect(ws.tagLimitReached, isFalse);
    ws.createTag('Fresh', 0xFFFF3B30);
    expect(ws.customTags.all, hasLength(15));
  });

  test('deleting a tag takes it off Archive items but keeps the items', () {
    final keep = ws.createTag('Keep', 0xFF2878F0).tag;
    final gone = ws.createTag('Gone', 0xFFFF3B30).tag;
    final link = ws.linkAsset('https://example.com');
    ws.setAssetTags(link.id, {keep.id, gone.id});
    expect(ws.archiveUsesOfTag(gone.id), 1);
    expect(ws.deleteTag(gone.id), 1);
    final after = ws.assets[link.id]!;
    expect(after.linkTags, contains(CustomTag.assetRef(keep.id)));
    expect(after.linkTags, isNot(contains(CustomTag.assetRef(gone.id))));
    expect(ws.tagsOfAsset(after).map((t) => t.name), ['Keep']);
  });

  test('tags and their assignments survive a restart', () async {
    final t = ws.createTag('Persist', 0xFFFF6A00).tag;
    final link = ws.linkAsset('https://example.org');
    ws.setAssetTags(link.id, {t.id});
    await ws.flush();
    final again = Workspace(dir);
    await again.load();
    addTearDown(again.dispose);
    expect(again.customTags[t.id]!.name, 'Persist');
    expect(again.customTags[t.id]!.color, 0xFFFF6A00);
    expect(again.tagsOfAsset(again.assets[link.id]!).single.id, t.id);
    expect(again.tagLimitReached, isFalse);
  });

  test('tag text is readable on every library colour', () {
    for (final s in InkColors.library) {
      final fg = tagForeground(s.color);
      expect(contrast(fg, s.color), greaterThanOrEqualTo(4.5), reason: s.name);
    }
  });

  testWidgets('picker: HEX makes a tag with that colour; the limit is shown', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final root = Directory.systemTemp.createTempSync('theapp_tagui_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    final wsx = Workspace(root);
    final s = AppState(
      canvases: FileCanvasRepository(wsx.store),
      settings: SettingsRepository(wsx.store),
      workspace: wsx,
      enableSendTo: false,
    );
    addTearDown(s.dispose);
    await tester.runAsync(s.init);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showTagPicker(context, s, selected: {}, what: 'test'),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tag-new-name')), 'Orange');
    await tester.enterText(find.byKey(const ValueKey('tag-hex')), '#FF6A00');
    await tester.tap(find.byKey(const ValueKey('tag-create')));
    await tester.pumpAndSettle();
    expect(s.workspace.tagNamed('Orange')!.color, 0xFFFF6A00);
    // Fill up to the limit: the button is off and the message is there.
    for (var i = 0; i < CustomTag.maxTags - 1; i++) {
      s.workspace.createTag('More $i', 0xFF2878F0);
    }
    await tester.enterText(find.byKey(const ValueKey('tag-new-name')), 'x');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tag-limit')), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('tag-create')),
    );
    expect(button.onPressed, isNull);
    expect(s.workspace.customTags.all, hasLength(15));
  });
}
