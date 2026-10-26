// Workspace Health Inspector: finds missing references, broken and
// outdated links, recoverable links, duplicate tag names and unsaved data;
// changes nothing until a previewed repair is approved; repairs touch only
// what they say.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/tag_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/inspector/inspector_dialog.dart';
import 'package:flutter_application_1/features/inspector/workspace_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState s;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_inspector_');
    final ws = Workspace(Directory('${dir.path}/data'));
    s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await s.init();
  });

  Note note(String title, String body) =>
      s.workspace.createNote(title: title, body: body);

  String snapshot() => [
    for (final n in s.workspace.notes.all) '${n.id}|${n.title}|${n.body}',
    for (final t in s.workspace.customTags.all) '${t.id}|${t.name}',
  ].join(';');

  test('a healthy workspace is clean, and scanning changes nothing', () async {
    final a = note('A', 'plain text');
    final b = note('B', 'links to [[theapp:note/${a.id}|A]]');
    final before = snapshot();
    final r = await inspectWorkspace(s);
    expect(r.findings.where((f) => f.code == 'broken_link'), isEmpty);
    expect(r.findings.where((f) => f.code == 'outdated_link_label'), isEmpty);
    expect(snapshot(), before);
    expect(b.id, isNotEmpty);
  });

  test('a broken link: explained, previewed, repaired alone', () async {
    final n = note('Plan', 'see [[theapp:note/ghost123|Ghost]] and more text');
    final other = note('Other', 'keep [[theapp:note/ghost123|Ghost]] here');
    final r = await inspectWorkspace(s);
    final f = r.findings.firstWhere(
      (f) => f.code == 'broken_link' && f.where.contains('Plan'),
    );
    expect(f.level, FindingLevel.problem);
    expect(f.impact, contains('deleted'));
    final fix = f.repairs.single;
    expect(fix.before, contains('[[theapp:note/ghost123|Ghost]]'));
    expect(fix.after, isNot(contains('[[')));
    // Nothing changed until applied.
    expect(s.workspace.notes[n.id]!.body, contains('[[theapp:'));
    expect(await fix.apply(), isTrue);
    expect(s.workspace.notes[n.id]!.body, 'see Ghost and more text');
    expect(
      s.workspace.notes[other.id]!.body,
      contains('[[theapp:note/ghost123'),
      reason: 'other notes are not touched',
    );
    expect(await fix.apply(), isFalse, reason: 'second run is a no-op');
  });

  test('a recoverable link offers to restore the deleted note', () async {
    final target = note('Target', 'important');
    final src = note('Src', 'see [[theapp:note/${target.id}|Target]]');
    s.workspace.deleteNote(target.id);
    final r = await inspectWorkspace(s);
    final f = r.findings.firstWhere((f) => f.code == 'broken_link');
    final restore = f.repairs.firstWhere((p) => p.label.startsWith('Restore'));
    expect(s.workspace.notes[target.id], isNull);
    expect(await restore.apply(), isTrue);
    expect(s.workspace.notes[target.id]!.body, 'important');
    expect(s.workspace.notes[src.id]!.body, contains(target.id));
    final again = await inspectWorkspace(s);
    expect(again.findings.where((f) => f.code == 'broken_link'), isEmpty);
  });

  test('a renamed target: label update keeps the link target', () async {
    final target = note('Old name', 'x');
    final src = note('Src', 'see [[theapp:note/${target.id}|Old name]] now');
    s.workspace.notes.put(s.workspace.notes[target.id]!.copyWith(title: 'New name'));
    final r = await inspectWorkspace(s);
    final f = r.findings.firstWhere((f) => f.code == 'outdated_link_label');
    expect(f.level, FindingLevel.warning);
    expect(await f.repairs.single.apply(), isTrue);
    expect(
      s.workspace.notes[src.id]!.body,
      'see [[theapp:note/${target.id}|New name]] now',
    );
  });

  test('duplicate tag names: rename, never merge or delete', () async {
    final now = DateTime.now();
    CustomTag tag(String id, String name, DateTime at) =>
        CustomTag(id: id, name: name, color: 0xFF112233, createdAt: at, updatedAt: at);
    s.workspace.customTags.put(tag('t1', 'Exam', now.subtract(const Duration(days: 1))));
    s.workspace.customTags.put(tag('t2', 'exam', now));
    final r = await inspectWorkspace(s);
    final f = r.findings.singleWhere((f) => f.code == 'duplicate_tag_name');
    expect(f.level, FindingLevel.problem);
    expect(f.repairs.single.after, 'exam 2');
    expect(s.workspace.customTags.length, 2);
    expect(await f.repairs.single.apply(), isTrue);
    expect(s.workspace.customTags['t1']!.name, 'Exam');
    expect(s.workspace.customTags['t2']!.name, 'exam 2');
    expect(s.workspace.customTags.length, 2);
    expect((await inspectWorkspace(s)).ofCode('duplicate_tag_name'), isEmpty);
  });

  test('a missing reference is reported with where and impact', () async {
    s.workspace.createTask('Revise');
    final t = s.workspace.tasks.all.first;
    s.workspace.tasks.put(t.copyWith(noteIds: ['no-such-note']));
    final r = await inspectWorkspace(s);
    final f = r.findings.firstWhere((f) => f.code == 'missing_reference');
    expect(f.where, contains('Revise'));
    expect(f.impact, contains('does not exist'));
    expect(f.repairs, isEmpty, reason: 'no reliable automatic repair');
  });

  test('data missing from the saved file is reported as not saved', () async {
    note('Keep me', 'text');
    await s.flush();
    final file = File('${dir.path}/data/data/notes.json');
    expect(file.existsSync(), isTrue);
    file.deleteSync();
    final bak = File('${dir.path}/data/data/notes.json.bak');
    if (bak.existsSync()) bak.deleteSync();
    final r = await inspectWorkspace(s);
    expect(r.ofCode('not_saved'), isNotEmpty);
    expect(r.ofCode('not_saved').first.level, FindingLevel.problem);
  });

  testWidgets('dialog: lists, previews, applies, rescans', (t) async {
    late Note n;
    late InspectionReport first;
    await t.runAsync(() async {
      n = note('Plan', 'see [[theapp:note/ghost123|Ghost]] ok');
      first = await inspectWorkspace(s);
    });
    var scans = 0;
    await t.binding.setSurfaceSize(const Size(1000, 800));
    await t.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showWorkspaceInspector(
              context,
              s,
              scanner: (_) async =>
                  scans++ == 0 ? first : const InspectionReport([], checked: 1),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-inspector')), findsOneWidget);
    expect(find.text('CONFIRMED PROBLEMS'), findsOneWidget);
    await t.tap(find.text('Remove the link, keep the words'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('repair-preview')), findsOneWidget);
    expect(s.workspace.notes[n.id]!.body, contains('[[theapp:'));
    await t.tap(find.byKey(const ValueKey('repair-apply')));
    await t.pumpAndSettle();
    expect(s.workspace.notes[n.id]!.body, 'see Ghost ok');
    expect(find.text('Remove the link, keep the words'), findsNothing);
    expect(find.textContaining('No problems found'), findsOneWidget);
    await t.binding.setSurfaceSize(null);
    await t.pump(const Duration(seconds: 5));
  });
}
