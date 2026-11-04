// Portable export (portability/workspace_export.dart): complete, checked
// against its manifest, never half-written, and previewable against a
// workspace without changing it.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/portability/workspace_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('theapp_export_'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory sub(String n) =>
      Directory('${root.path}${Platform.pathSeparator}$n');

  Future<Workspace> workspace(String name) async {
    final ws = Workspace(sub(name));
    await ws.load();
    return ws;
  }

  Future<Workspace> seeded() async {
    final ws = await workspace('src');
    ws.createNote(title: 'Plan / draft', body: 'Read chapter 3');
    ws.createNote(title: 'Ideas', body: 'A plant app');
    ws.createTask('Pay rent');
    final photo = await ws.imageAssetFromBytes(
      Uint8List.fromList(List<int>.generate(2000, (i) => i % 251)),
      'png',
    );
    ws.attachToNote(ws.notes.all.first.id, photo.id);
    await ws.flush();
    return ws;
  }

  test(
    'an export holds every record, the notes as Markdown and the files',
    () async {
      final ws = await seeded();
      final out = sub('export');
      final summary = await WorkspaceExport.write(ws, out);
      expect(summary.notes, 2);
      expect(summary.records['notes'], 2);
      expect(summary.records['tasks'], 1);
      expect(summary.attachments, 1);
      expect(summary.missingAttachments, isEmpty);
      expect(await WorkspaceExport.verify(out), isEmpty);

      final notesDir = Directory('${out.path}${Platform.pathSeparator}notes');
      final md = notesDir.listSync().whereType<File>().toList();
      expect(md, hasLength(2));
      expect(
        md.any((f) => f.readAsStringSync().contains('Read chapter 3')),
        isTrue,
      );
      // A title with a slash is a safe file name.
      expect(md.every((f) => !f.uri.pathSegments.last.contains('/')), isTrue);
      final manifest = (await WorkspaceExport.readManifest(out))!;
      expect(manifest['format'], 'misc-export');
      expect(manifest['version'], 1);
      expect((manifest['files'] as List).isNotEmpty, isTrue);
    },
  );

  test('the export holds no keys or tokens', () async {
    final ws = await seeded();
    final out = sub('export');
    await WorkspaceExport.write(ws, out);
    for (final f in out.listSync(recursive: true).whereType<File>()) {
      final name = f.path.toLowerCase();
      expect(name.endsWith('.key') || name.endsWith('.token'), isFalse);
    }
  });

  test('changing, removing or adding to an export is noticed', () async {
    final ws = await seeded();
    final out = sub('export');
    await WorkspaceExport.write(ws, out);
    final sep = Platform.pathSeparator;
    final records = File('${out.path}${sep}records${sep}notes.json');
    final original = records.readAsStringSync();

    records.writeAsStringSync(original.replaceFirst('Ideas', 'Ideaz'));
    expect(
      (await WorkspaceExport.verify(out)).single,
      'Damaged: records/notes.json',
    );
    records.writeAsStringSync(original);
    expect(await WorkspaceExport.verify(out), isEmpty);

    records.deleteSync();
    expect(
      (await WorkspaceExport.verify(out)).single,
      'Missing: records/notes.json',
    );
  });

  test(
    'an unfinished export leaves no half folder and changes nothing',
    () async {
      final ws = await seeded();
      final out = sub('export');
      // An earlier interrupted attempt left a partial folder behind.
      Directory('${out.path}.partial').createSync(recursive: true);
      File('${out.path}.partial${Platform.pathSeparator}junk')
          .writeAsStringSync('x');
      await WorkspaceExport.write(ws, out);
      expect(Directory('${out.path}.partial').existsSync(), isFalse);
      expect(await WorkspaceExport.verify(out), isEmpty);
    },
  );

  test('an existing non-empty folder is never written into', () async {
    final ws = await seeded();
    final out = sub('taken')..createSync(recursive: true);
    File('${out.path}${Platform.pathSeparator}mine.txt')
        .writeAsStringSync('keep');
    await expectLater(
      WorkspaceExport.write(ws, out),
      throwsA(isA<ExportFailure>()),
    );
    expect(
      File('${out.path}${Platform.pathSeparator}mine.txt').readAsStringSync(),
      'keep',
    );
  });

  test('a file that is not here yet is listed, not silently dropped', () async {
    final ws = await seeded();
    final asset = ws.assets.all.first;
    ws.attachments.fileFor(asset.file!).deleteSync();
    final summary = await WorkspaceExport.write(ws, sub('export'));
    expect(summary.missingAttachments, [asset.file]);
    final m = (await WorkspaceExport.readManifest(sub('export')))!;
    expect(m['missingAttachments'], [asset.file]);
  });

  group('preview', () {
    test('into an empty workspace everything is new', () async {
      final ws = await seeded();
      final out = sub('export');
      await WorkspaceExport.write(ws, out);
      final empty = await workspace('dest');
      final p = await ImportPreview.of(out, empty);
      expect(p.sound, isTrue);
      expect(p.collections['notes']!.fresh, 2);
      expect(p.collections['notes']!.same, 0);
      expect(p.collisions, 0);
      expect(empty.notes.length, 0, reason: 'a preview changes nothing');
    });

    test('into the same workspace everything is identical', () async {
      final ws = await seeded();
      final out = sub('export');
      await WorkspaceExport.write(ws, out);
      final p = await ImportPreview.of(out, ws);
      expect(p.collections['notes']!.same, 2);
      expect(p.collections['notes']!.fresh, 0);
      expect(p.collisions, 0);
    });

    test('the same id with other content is reported as a collision', () async {
      final ws = await seeded();
      final out = sub('export');
      await WorkspaceExport.write(ws, out);
      final note = ws.notes.all.first;
      ws.notes.put(note.copyWith(body: 'edited after the export'));
      final p = await ImportPreview.of(out, ws);
      expect(p.collections['notes']!.different, 1);
      expect(p.collections['notes']!.same, 1);
      expect(p.collisions, 1);
    });

    test('a damaged export is not previewed as if it were fine', () async {
      final ws = await seeded();
      final out = sub('export');
      await WorkspaceExport.write(ws, out);
      final sep = Platform.pathSeparator;
      File('${out.path}${sep}records${sep}tasks.json').writeAsStringSync('{}');
      final p = await ImportPreview.of(out, ws);
      expect(p.sound, isFalse);
      expect(p.collections, isEmpty);
    });

    test('an export from a newer version is refused', () async {
      final ws = await seeded();
      final out = sub('export');
      await WorkspaceExport.write(ws, out);
      final f = File('${out.path}${Platform.pathSeparator}manifest.json');
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      f.writeAsStringSync(jsonEncode({...m, 'version': 99}));
      expect(await WorkspaceExport.verify(out), isNotEmpty);
    });
  });
}
