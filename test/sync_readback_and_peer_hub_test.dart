// The two sync fixes of 2026-11-12:
// * the encrypted-only switch-over no longer fails on a canvas's `order`;
// * the direct-sync hub's files are not encrypted at rest (and ones that
//   were are restored).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/data/storage/storage_encryption.dart';
import 'package:flutter_application_1/sync/peer_sync.dart';
import 'package:flutter_application_1/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('read-back comparison', () {
    test('a canvas record ignores only its order', () {
      final here = {
        'title': 'T',
        'folderId': null,
        'order': ['a', 'b'],
      };
      final hub = {
        'title': 'T',
        'folderId': null,
        'order': ['a'],
      };
      expect(
        SyncEngine.comparableForReadBack('canvases', here),
        SyncEngine.comparableForReadBack('canvases', hub),
      );
      // A real difference is still caught.
      expect(
        SyncEngine.comparableForReadBack('canvases', {...here, 'title': 'X'}),
        isNot(SyncEngine.comparableForReadBack('canvases', hub)),
      );
      // The stored record itself is not changed.
      expect(here['order'], ['a', 'b']);
    });

    test('other records keep every field (order included)', () {
      expect(
        SyncEngine.comparableForReadBack('notes', {
          'order': [1],
        }),
        {
          'order': [1],
        },
      );
      expect(
        SyncEngine.comparableForReadBack('assets', {
          'fileBlob': 'x',
          'title': 't',
        }),
        {'title': 't'},
      );
    });
  });

  group('direct-sync hub files', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('directsync_fix_'));
    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    File file(String rel) =>
        File('${root.path}${Platform.pathSeparator}$rel')
          ..parent.createSync(recursive: true);

    test('are not encrypted at rest; other data still is', () async {
      file('peer_hub/hub-id').writeAsStringSync('abc');
      file('peer_hub/journal.jsonl').writeAsStringSync('{}');
      file('data/notes.json').writeAsStringSync('{}');
      final managed = [
        for (final f in await StorageEncryption.managedFiles(root).toList())
          f.path.replaceAll(r'\', '/'),
      ];
      expect(managed.where((p) => p.contains('/peer_hub/')), isEmpty);
      expect(managed.where((p) => p.endsWith('data/notes.json')), hasLength(1));
    });

    test('encrypted by an earlier version are opened again', () async {
      final cipher = FileCipher(FileCipher.generateKey());
      final dir = Directory('${root.path}${Platform.pathSeparator}peer_hub');
      file('peer_hub/hub-id').writeAsBytesSync(
        cipher.encrypt(utf8.encode('hubid123')),
      );
      file('peer_hub/devices.json').writeAsStringSync('{"devices":[]}');
      await restorePlainPeerHub(dir, cipher);
      expect(file('peer_hub/hub-id').readAsStringSync(), 'hubid123');
      expect(file('peer_hub/devices.json').readAsStringSync(), '{"devices":[]}');
      expect(dir.listSync().where((e) => e.path.endsWith('-tmp')), isEmpty);
    });

    test('that cannot be opened are set aside, not deleted', () async {
      final other = FileCipher(FileCipher.generateKey());
      final dir = Directory('${root.path}${Platform.pathSeparator}peer_hub');
      file('peer_hub/hub-id').writeAsBytesSync(
        other.encrypt(utf8.encode('x')),
      );
      await restorePlainPeerHub(dir, null);
      expect(dir.existsSync(), isFalse);
      final aside = root.listSync().where(
        (e) => e.path.contains('peer_hub.unreadable-'),
      );
      expect(aside, hasLength(1));
    });

    test('plain files are left as they are', () async {
      final dir = Directory('${root.path}${Platform.pathSeparator}peer_hub');
      file('peer_hub/hub-id').writeAsStringSync('plain');
      await restorePlainPeerHub(dir, FileCipher(FileCipher.generateKey()));
      expect(file('peer_hub/hub-id').readAsStringSync(), 'plain');
    });
  });
}
