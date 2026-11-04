// The .theappbackup file: everything survives export → import into a fresh
// profile, a damaged or foreign file is refused without adding anything, an
// unsafe path inside a file is refused, and a restore that fails part-way
// leaves the data as it was. Temporary folders only; never real data.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_application_1/data/storage/backup_file.dart';
import 'package:flutter_application_1/data/storage/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _sep = Platform.pathSeparator;

Future<void> _write(Directory root, String rel, List<int> bytes) async {
  final f = File('${root.path}$_sep${rel.replaceAll('/', _sep)}');
  await f.parent.create(recursive: true);
  await f.writeAsBytes(bytes);
}

Future<Directory> _profile(Directory base, String name) async {
  final root = Directory('${base.path}$_sep$name');
  await root.create(recursive: true);
  await _write(
    root,
    'data/notes.json',
    utf8.encode(
      jsonEncode({
        'records': [
          {'id': 'n1', 'title': 'Kept note'},
          {'id': 'n2', 'title': 'Second note'},
        ],
      }),
    ),
  );
  await _write(root, 'settings/app.json', utf8.encode('{"theme":"light"}'));
  await _write(root, 'canvases/c1.json', utf8.encode('{"items":[1,2,3]}'));
  // A photo larger than one read chunk, with non-text bytes.
  await _write(root, 'attachments/photo.png', [
    for (var i = 0; i < 300000; i++) (i * 31 + 7) & 0xFF,
  ]);
  return root;
}

void main() {
  late Directory base;

  setUp(() => base = Directory.systemTemp.createTempSync('theapp_bkfile_'));
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  test('export then import into a fresh profile restores everything', () async {
    final source = await _profile(base, 'source');
    final service = BackupService(source);
    final out = File('${base.path}${_sep}my.$backupFileExtension');
    final file = await service.exportFile(out);
    expect(file.path, out.path);
    expect(await BackupFile.looksLikeBackup(file), isTrue);
    // No half-written file and no leftover temporary backup folder.
    expect(File('${out.path}.partial').existsSync(), isFalse);
    expect(await service.list(), isEmpty);

    // A different installation (nothing in common with the first).
    final fresh = Directory('${base.path}${_sep}fresh')..createSync();
    final other = BackupService(fresh);
    final imported = await other.importFile(file);
    expect(await other.checkManifest(imported), isEmpty);
    expect(await other.list(), hasLength(1));
    expect(imported.path.contains('-imported'), isTrue);

    await other.restore(imported);
    final restoredNotes = File('${fresh.path}${_sep}data${_sep}notes.json');
    expect(
      jsonDecode(await restoredNotes.readAsString())['records'],
      hasLength(2),
    );
    expect(
      await File('${fresh.path}${_sep}attachments${_sep}photo.png').readAsBytes(),
      await File('${source.path}${_sep}attachments${_sep}photo.png').readAsBytes(),
    );
    expect(
      File('${fresh.path}${_sep}settings${_sep}app.json').readAsStringSync(),
      '{"theme":"light"}',
    );
  });

  test('the manifest records which build made the backup', () async {
    final source = await _profile(base, 'source');
    final service = BackupService(source);
    final backup = await service.snapshot('manual');
    final manifest = await service.readManifest(backup);
    expect(manifest?['appBuild'], isA<String>());
  });

  test('a file that is not a backup, or was cut short, adds nothing', () async {
    final fresh = Directory('${base.path}${_sep}fresh')..createSync();
    final service = BackupService(fresh);

    final junk = File('${base.path}${_sep}junk.$backupFileExtension')
      ..writeAsStringSync('hello, I am not a backup');
    await expectLater(
      service.importFile(junk),
      throwsA(isA<BackupFileException>()),
    );

    final source = await _profile(base, 'source');
    final good = await BackupService(
      source,
    ).exportFile(File('${base.path}${_sep}good.$backupFileExtension'));
    final bytes = await good.readAsBytes();
    final cut = File('${base.path}${_sep}cut.$backupFileExtension')
      ..writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
    await expectLater(service.importFile(cut), throwsA(anything));

    expect(await service.list(), isEmpty);
    // No hidden leftovers either.
    final leftovers = Directory(
      '${fresh.path}${_sep}backups',
    ).existsSync()
        ? Directory('${fresh.path}${_sep}backups').listSync()
        : const <FileSystemEntity>[];
    expect(leftovers, isEmpty);
  });

  test('a file with an altered record fails its manifest check', () async {
    final source = await _profile(base, 'source');
    final service = BackupService(source);
    final backup = await service.snapshot('manual', includeAttachments: true);
    // Change one byte of a record after the manifest was written.
    final note = File('${backup.path}${_sep}data${_sep}notes.json');
    final text = await note.readAsString();
    await note.writeAsString(text.replaceFirst('Kept', 'Lost'));
    final packed = await BackupFile.pack(
      backup,
      File('${base.path}${_sep}tampered.$backupFileExtension'),
    );

    final fresh = Directory('${base.path}${_sep}fresh')..createSync();
    final other = BackupService(fresh);
    await expectLater(
      other.importFile(packed),
      throwsA(isA<BackupFileException>()),
    );
    expect(await other.list(), isEmpty);
  });

  test('an unsafe path inside a file is refused', () async {
    // Built by hand: a valid header, then an entry that climbs out.
    Future<File> craft(String path) async {
      final out = File('${base.path}${_sep}evil.$backupFileExtension');
      final raw = BytesBuilder();
      raw.add(utf8.encode('THEAPPBACKUP\n'));
      raw.add((ByteData(4)..setUint32(0, 1)).buffer.asUint8List());
      void entry(String p, List<int> body) {
        final pb = utf8.encode(p);
        raw.add((ByteData(4)..setUint32(0, pb.length)).buffer.asUint8List());
        raw.add(pb);
        raw.add((ByteData(8)..setUint64(0, body.length)).buffer.asUint8List());
        raw.add(body);
      }

      entry('manifest.json', utf8.encode('{}'));
      entry(path, [1, 2, 3]);
      raw.add((ByteData(4)..setUint32(0, 0)).buffer.asUint8List());
      await out.writeAsBytes(gzip.encode(raw.takeBytes()));
      return out;
    }

    final fresh = Directory('${base.path}${_sep}fresh')..createSync();
    final service = BackupService(fresh);
    for (final bad in [
      '../escape.txt',
      'data/../../escape.txt',
      '/etc/passwd',
      'C:/Windows/x.txt',
      'unknown_folder/x.json',
      'data\\..\\x',
    ]) {
      await expectLater(
        service.importFile(await craft(bad)),
        throwsA(isA<BackupFileException>()),
        reason: bad,
      );
    }
    expect(File('${base.path}${_sep}escape.txt').existsSync(), isFalse);
    expect(await service.list(), isEmpty);
  });

  test('a file from a newer format version is refused with a clear message',
      () async {
    final out = File('${base.path}${_sep}future.$backupFileExtension');
    final raw = BytesBuilder()
      ..add(utf8.encode('THEAPPBACKUP\n'))
      ..add((ByteData(4)..setUint32(0, 99)).buffer.asUint8List());
    await out.writeAsBytes(gzip.encode(raw.takeBytes()));
    final fresh = Directory('${base.path}${_sep}fresh')..createSync();
    await expectLater(
      BackupService(fresh).importFile(out),
      throwsA(
        isA<BackupFileException>().having(
          (e) => e.message,
          'message',
          contains('newer THEapp'),
        ),
      ),
    );
  });

  test('automatic backup every week skips days in between', () async {
    final source = await _profile(base, 'source');
    final service = BackupService(source);
    final monday = DateTime(2026, 11, 2, 9);
    await service.automaticBackup(now: monday, every: const Duration(days: 7));
    // The first run makes the weekly full backup.
    expect(await service.list(), hasLength(1));
    await service.automaticBackup(
      now: monday.add(const Duration(days: 2)),
      every: const Duration(days: 7),
    );
    expect(await service.list(), hasLength(1));
    // Daily would have added one for the new day.
    await service.automaticBackup(
      now: monday.add(const Duration(days: 2)),
      every: const Duration(days: 1),
    );
    expect(await service.list(), hasLength(2));
  });

  test('a damaged backup is refused before live data is touched', () async {
    final source = await _profile(base, 'source');
    final service = BackupService(source);
    final backup = await service.snapshot('manual', includeAttachments: true);
    await _write(source, 'data/notes.json', utf8.encode('{"records":[]}'));
    // Damage the backup after its manifest was written.
    final note = File('${backup.path}${_sep}data${_sep}notes.json');
    await note.writeAsString('damaged');
    await expectLater(service.restore(backup), throwsA(anything));
    expect(
      File('${source.path}${_sep}data${_sep}notes.json').readAsStringSync(),
      '{"records":[]}',
    );
    expect(
      File('${source.path}${_sep}settings${_sep}app.json').existsSync(),
      isTrue,
    );
  });
}
