// Encryption at rest: AES-256-GCM files, key handling, attachments, backups
// and the upgrade of an existing plain-text folder. Everything runs on
// temporary folders with an in-memory key store; never on real data.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_application_1/data/storage/attachment_store.dart';
import 'package:flutter_application_1/data/storage/backup_service.dart';
import 'package:flutter_application_1/data/storage/backup_verifier.dart';
import 'package:flutter_application_1/data/storage/encryption_migration.dart';
import 'package:flutter_application_1/data/storage/json_file_store.dart';
import 'package:flutter_application_1/data/storage/storage_encryption.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/sync/sync_engine.dart'
    show fillAttachmentHashes;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

const canaryTitle = 'CANARY-TITLE-7f3a91';
const canaryBody = 'CANARY-BODY-c20d55 private thoughts';
const canaryAttachment = 'CANARY-ATTACHMENT-91be04';

class MemoryKeyStore implements WorkspaceKeyStore {
  MemoryKeyStore({this.secure = true});
  final bool secure;
  Uint8List? key;
  int writes = 0;

  @override
  bool get isSecure => secure;
  @override
  Future<Uint8List?> read() async => key;
  @override
  Future<void> write(Uint8List value) async {
    writes++;
    key = value;
  }
}

bool hasBytes(List<int> haystack, String needle) {
  final n = utf8.encode(needle);
  outer:
  for (var i = 0; i + n.length <= haystack.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Every file under [dir] that contains [needle] as raw bytes.
Future<List<String>> filesContaining(Directory dir, String needle) async {
  final hits = <String>[];
  await for (final e in dir.list(recursive: true)) {
    if (e is File && hasBytes(await e.readAsBytes(), needle)) {
      hits.add(e.path.substring(dir.path.length + 1));
    }
  }
  return hits;
}

/// Managed files (and backup copies) that are not encrypted.
Future<List<String>> plainFiles(Directory root) async {
  final out = <String>[];
  await for (final f in StorageEncryption.managedFiles(root)) {
    if (!await FileCipher.fileIsEncrypted(f)) {
      out.add(f.path.substring(root.path.length + 1));
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FileCipher cipher;

  setUp(() {
    root = Directory.systemTemp.createTempSync('theapp_enc_');
    cipher = FileCipher(FileCipher.generateKey());
    StorageEncryption.active = null;
  });
  tearDown(() {
    StorageEncryption.active = null;
    AttachmentStore.clearViewCopies();
    root.deleteSync(recursive: true);
  });

  group('FileCipher (AES-256-GCM)', () {
    test('round trip, with the documented header', () {
      final plain = utf8.encode(canaryBody);
      final enc = cipher.encrypt(plain);
      expect(FileCipher.isEncrypted(enc), isTrue);
      expect(enc.sublist(0, 4), utf8.encode('TAEF'));
      expect(enc[4], 1, reason: 'format version');
      expect(enc.length, FileCipher.headerLength + plain.length + 16);
      expect(cipher.decrypt(enc), plain);
      expect(hasBytes(enc, canaryBody), isFalse);
    });

    test('every encryption is different: fresh salt and nonce', () {
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        seen.add(base64Encode(cipher.encrypt(utf8.encode('same'))));
      }
      expect(seen, hasLength(200));
      final headers = {
        for (var i = 0; i < 100; i++)
          base64Encode(cipher.encrypt([1]).sublist(6, FileCipher.headerLength)),
      };
      expect(headers, hasLength(100), reason: 'salt+nonce never repeat');
    });

    test('any changed byte is rejected', () {
      final enc = cipher.encrypt(utf8.encode(canaryBody));
      for (var i = 0; i < enc.length; i++) {
        final bad = Uint8List.fromList(enc)..[i] ^= 0x01;
        expect(
          () => cipher.decrypt(bad),
          throwsA(isA<DecryptionFailure>()),
          reason: 'byte $i',
        );
      }
    });

    test('truncated, extended and foreign data are rejected', () {
      final enc = cipher.encrypt(utf8.encode(canaryBody));
      expect(
        () => cipher.decrypt(enc.sublist(0, enc.length - 1)),
        throwsA(isA<DecryptionFailure>()),
      );
      expect(
        () => cipher.decrypt([...enc, 0]),
        throwsA(isA<DecryptionFailure>()),
      );
      expect(
        () => cipher.decrypt(utf8.encode('{"plain":"json"}')),
        throwsA(isA<DecryptionFailure>()),
      );
    });

    test('a wrong key cannot decrypt', () {
      final enc = cipher.encrypt(utf8.encode(canaryBody));
      final other = FileCipher(FileCipher.generateKey());
      expect(() => other.decrypt(enc), throwsA(isA<DecryptionFailure>()));
    });

    test('a newer format version is refused, not misread', () {
      final enc = Uint8List.fromList(cipher.encrypt([1, 2, 3]))..[4] = 2;
      expect(() => cipher.decrypt(enc), throwsA(isA<DecryptionFailure>()));
    });

    test('keys come from the secure generator and differ', () {
      expect(FileCipher.generateKey(), hasLength(32));
      expect(FileCipher.generateKey(), isNot(equals(FileCipher.generateKey())));
    });
  });

  group('the workspace key', () {
    test('is made once and then reused', () async {
      final keys = MemoryKeyStore();
      final first = await StorageEncryption.open(root, keys: keys);
      expect(first.status, EncryptionStatus.enabled);
      final again = await StorageEncryption.open(root, keys: keys);
      expect(again.status, EncryptionStatus.enabled);
      expect(keys.writes, 1);
      expect(again.cipher!.sameKeyAs(first.cipher!), isTrue);
    });

    test('is never invented while encrypted data exists', () async {
      final keys = MemoryKeyStore();
      final first = await StorageEncryption.open(root, keys: keys);
      final store = JsonFileStore(root, cipher: first.cipher);
      await store.write('data', 'notes', {'t': canaryBody});
      final lost = MemoryKeyStore(); // the key is gone
      final state = await StorageEncryption.open(root, keys: lost);
      expect(state.status, EncryptionStatus.keyMissing);
      expect(state.cipher, isNull);
      expect(lost.writes, 0, reason: 'no replacement key was fabricated');
      expect(state.message, contains('Nothing was changed'));
    });

    test('a different key than the data was made with is refused', () async {
      final keys = MemoryKeyStore();
      final first = await StorageEncryption.open(root, keys: keys);
      await JsonFileStore(
        root,
        cipher: first.cipher,
      ).write('data', 'notes', {'t': 1});
      final wrong = MemoryKeyStore()..key = FileCipher.generateKey();
      final state = await StorageEncryption.open(root, keys: wrong);
      expect(state.status, EncryptionStatus.keyMissing);
      // The data is untouched.
      expect(
        (await JsonFileStore(
          root,
          cipher: first.cipher,
        ).read('data', 'notes'))!['t'],
        1,
      );
    });

    test(
      'a platform without protected storage gets no key and says so',
      () async {
        final keys = MemoryKeyStore(secure: false);
        final state = await StorageEncryption.open(root, keys: keys);
        expect(state.status, EncryptionStatus.unsupportedPlatform);
        expect(state.cipher, isNull);
        expect(keys.writes, 0);
        expect(state.message, contains('NOT encrypted'));
        expect(Directory('${root.path}${sep}keys').existsSync(), isFalse);
      },
    );

    test('the key is not stored beside the data in the clear', () async {
      final keys = MemoryKeyStore();
      final state = await StorageEncryption.open(root, keys: keys);
      final b64 = base64Encode(keys.key!);
      final hex = keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      await JsonFileStore(
        root,
        cipher: state.cipher,
      ).write('data', 'n', {'a': 1});
      expect(await filesContaining(root, b64), isEmpty);
      expect(await filesContaining(root, hex), isEmpty);
    });
  });

  group('JsonFileStore', () {
    test('files, backups and temp files on disk hold no plain text', () async {
      final store = JsonFileStore(root, cipher: cipher);
      await store.write('data', 'notes', {
        'records': [
          {'id': '1', 'title': canaryTitle, 'body': canaryBody},
        ],
      });
      await store.write('data', 'notes', {
        'records': [
          {'id': '1', 'title': canaryTitle, 'body': '$canaryBody v2'},
        ],
      });
      await store.moveToTrash('data', 'notes');
      expect(await filesContaining(root, canaryTitle), isEmpty);
      expect(await filesContaining(root, canaryBody), isEmpty);
      expect(await plainFiles(root), isEmpty);
    });

    test('values read back exactly', () async {
      final store = JsonFileStore(root, cipher: cipher);
      final doc = {
        'records': [
          {
            'id': '1',
            'title': canaryTitle,
            'future': {
              'x': [1, 2],
            },
          },
        ],
        'unknownTop': true,
      };
      await store.write('data', 'notes', doc);
      expect(await store.read('data', 'notes'), doc);
      expect(
        await JsonFileStore(root, cipher: cipher).read('data', 'notes'),
        doc,
      );
    });

    test('a changed ciphertext falls back to the previous version', () async {
      final store = JsonFileStore(root, cipher: cipher);
      await store.write('data', 'notes', {'v': 1});
      await store.write('data', 'notes', {'v': 2});
      final file = File('${root.path}${sep}data${sep}notes.json');
      final bytes = file.readAsBytesSync();
      bytes[bytes.length - 5] ^= 0xFF;
      file.writeAsBytesSync(bytes);
      final fresh = JsonFileStore(root, cipher: cipher);
      expect((await fresh.read('data', 'notes'))!['v'], 1);
      expect(fresh.recoveries, isNotEmpty);
      expect(
        Directory('${root.path}${sep}data')
            .listSync()
            .any((e) => e.path.contains('.corrupt-')),
        isTrue,
        reason: 'the damaged file is kept, not deleted',
      );
    });

    test('with the wrong key nothing is read', () async {
      final store = JsonFileStore(root, cipher: cipher);
      await store.write('data', 'notes', {'v': 1});
      final other = JsonFileStore(
        root,
        cipher: FileCipher(FileCipher.generateKey()),
      );
      expect(await other.read('data', 'notes'), isNull);
    });

    test(
      'encrypted data without any key is a locked store, never "empty"',
      () async {
        await JsonFileStore(
          root,
          cipher: cipher,
        ).write('data', 'notes', {'v': 1});
        final locked = JsonFileStore(root); // no cipher anywhere
        expect(
          () => locked.read('data', 'notes'),
          throwsA(isA<StorageLockedException>()),
        );
      },
    );

    test(
      'older plain files are still read, and encrypted on the next save',
      () async {
        final plain = JsonFileStore(root);
        await plain.write('data', 'notes', {'v': 1, 'canary': canaryBody});
        final store = JsonFileStore(root, cipher: cipher);
        expect((await store.read('data', 'notes'))!['v'], 1);
        await store.write('data', 'notes', {'v': 2, 'canary': canaryBody});
        expect(await filesContaining(root, canaryBody), isEmpty);
      },
    );

    test('without a cipher the behaviour is unchanged (plain JSON)', () async {
      await JsonFileStore(root).write('data', 'notes', {'v': 1});
      expect(
        jsonDecode(
          File('${root.path}${sep}data${sep}notes.json').readAsStringSync(),
        ),
        {'v': 1},
      );
    });
  });

  group('attachments', () {
    test('are stored encrypted and read back', () async {
      final store = AttachmentStore(root, cipher: cipher);
      final bytes = Uint8List.fromList(utf8.encode('$canaryAttachment ' * 50));
      final name = await store.importBytes(bytes, 'png');
      expect(await filesContaining(root, canaryAttachment), isEmpty);
      expect(await store.readBytes(name), bytes);
      final src = File('${root.path}${sep}pic.jpg')..writeAsBytesSync(bytes);
      final name2 = await store.importFile(src);
      expect(await store.readBytes(name2), bytes);
      expect(await filesContaining(store.dir, canaryAttachment), isEmpty);
      expect(
        store.dir.listSync().where((e) => e.path.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('tampered ciphertext is rejected', () async {
      final store = AttachmentStore(root, cipher: cipher);
      final name = await store.importBytes(
        Uint8List.fromList([1, 2, 3, 4]),
        'png',
      );
      final f = store.fileFor(name);
      final bytes = f.readAsBytesSync();
      bytes[bytes.length - 1] ^= 1;
      f.writeAsBytesSync(bytes);
      expect(() => store.readBytes(name), throwsA(isA<DecryptionFailure>()));
    });

    test(
      'content hash and size describe the content, not the ciphertext',
      () async {
        final store = AttachmentStore(root, cipher: cipher);
        final bytes = Uint8List.fromList(utf8.encode('hello'));
        final name = await store.importBytes(bytes, 'txt');
        final (sha, size) = await store.contentInfo(name);
        expect(
          sha,
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        );
        expect(size, 5);
      },
    );

    test(
      'native viewers get a temporary decrypted copy that is removed',
      () async {
        final store = AttachmentStore(root, cipher: cipher);
        final bytes = Uint8List.fromList(utf8.encode('%PDF $canaryAttachment'));
        final name = await store.importBytes(bytes, 'pdf');
        final view = store.viewFile(name)!;
        expect(view.readAsBytesSync(), bytes);
        expect(view.path, isNot(store.fileFor(name).path));
        AttachmentStore.clearViewCopies();
        expect(view.existsSync(), isFalse);
        expect(store.fileFor(name).existsSync(), isTrue);
      },
    );

    test(
      'a download is staged, then stored encrypted and the staging file goes',
      () async {
        final store = AttachmentStore(root, cipher: cipher);
        final staged = store.stagingFile('abc.pdf')
          ..writeAsBytesSync(utf8.encode(canaryAttachment));
        await store.adopt('abc.pdf', staged);
        expect(staged.existsSync(), isFalse);
        expect(await filesContaining(store.dir, canaryAttachment), isEmpty);
        expect(utf8.decode(await store.readBytes('abc.pdf')), canaryAttachment);
      },
    );

    test('sync hashes the content so other devices agree', () async {
      StorageEncryption.active = cipher;
      final ws = Workspace(root);
      await ws.load();
      final pdf = File('${root.path}${sep}doc.pdf')
        ..writeAsBytesSync(utf8.encode('%PDF-1.4 $canaryAttachment'));
      final asset = await ws.documentAssetFromFile(pdf);
      await fillAttachmentHashes(ws);
      final stored = ws.assets[asset.id]!;
      expect(
        stored.fileSha256,
        sha256.convert(pdf.readAsBytesSync()).toString(),
      );
      expect(stored.fileSize, pdf.lengthSync());
      expect(
        await filesContaining(ws.attachments.dir, canaryAttachment),
        isEmpty,
      );
      ws.dispose();
    });

    test('a missing attachment gives no view copy', () {
      expect(
        AttachmentStore(root, cipher: cipher).viewFile('nope.png'),
        isNull,
      );
    });
  });

  group('backups', () {
    Future<(Workspace, String)> workspaceWithData() async {
      StorageEncryption.active = cipher;
      final ws = Workspace(root);
      await ws.load();
      final name = await ws.attachments.importBytes(
        Uint8List.fromList(utf8.encode(canaryAttachment * 3)),
        'png',
      );
      ws.createNote(title: canaryTitle, body: canaryBody);
      await ws.flush();
      return (ws, name);
    }

    test(
      'hold only encrypted data, manifest included, and still verify',
      () async {
        final (ws, _) = await workspaceWithData();
        final backup = await ws.backups.snapshot(
          'manual',
          includeAttachments: true,
        );
        expect(await filesContaining(backup, canaryTitle), isEmpty);
        expect(await filesContaining(backup, canaryBody), isEmpty);
        expect(await filesContaining(backup, canaryAttachment), isEmpty);
        expect(await plainFiles(root), isEmpty);
        expect(await ws.backups.checkManifest(backup), isEmpty);
        expect(await ws.backups.verify(backup), isTrue);
        final check = await verifyRestorable(ws.backups, backup);
        expect(check.problems, isEmpty);
        expect(check.records, greaterThan(0));
        ws.dispose();
      },
    );

    test(
      'the automatic, live and pre-upgrade kinds are encrypted too',
      () async {
        final (ws, _) = await workspaceWithData();
        await ws.backups.automaticBackup();
        await ws.backups.liveSnapshot();
        await ws.backups.snapshot('pre-v9', includeAttachments: true);
        expect((await ws.backups.list()).length, greaterThanOrEqualTo(3));
        expect(
          await filesContaining(ws.backups.backupsDir, canaryTitle),
          isEmpty,
        );
        expect(
          await filesContaining(ws.backups.backupsDir, canaryBody),
          isEmpty,
        );
        for (final b in await ws.backups.list()) {
          expect(await ws.backups.checkManifest(b), isEmpty, reason: b.path);
        }
        ws.dispose();
      },
    );

    test('a changed byte in a backup is detected', () async {
      final (ws, _) = await workspaceWithData();
      final backup = await ws.backups.snapshot('manual');
      final file = backup
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere(
            (f) =>
                f.path.contains('${sep}notes.json') && !f.path.endsWith('.bak'),
          );
      final bytes = file.readAsBytesSync();
      bytes[bytes.length - 3] ^= 0x10;
      file.writeAsBytesSync(bytes);
      expect(await ws.backups.checkManifest(backup), isNotEmpty);
      expect((await verifyRestorable(ws.backups, backup)).ok, isFalse);
      ws.dispose();
    });

    test('a restore brings the data back', () async {
      final (ws, _) = await workspaceWithData();
      final backup = await ws.backups.snapshot(
        'manual',
        includeAttachments: true,
      );
      ws.notes.all.toList().forEach((n) => ws.notes.remove(n.id));
      await ws.flush();
      ws.dispose();
      final w2 = Workspace(root);
      await w2.load();
      expect(w2.notes.all, isEmpty);
      w2.store.readOnly = true; // as the app does while restoring
      w2.store.readOnly = false;
      await w2.backups.restore(backup);
      w2.dispose();
      final w3 = Workspace(root);
      await w3.load();
      expect(w3.notes.all.map((n) => n.title), contains(canaryTitle));
      expect(await plainFiles(root), isEmpty);
      w3.dispose();
    });

    test(
      'a backup made under another key is kept and the live data is untouched',
      () async {
        final (ws, _) = await workspaceWithData();
        final backup = await ws.backups.snapshot(
          'manual',
          includeAttachments: true,
        );
        ws.dispose();
        // The same folder, but this device now has a different key.
        final foreignRoot = Directory.systemTemp.createTempSync(
          'theapp_enc_foreign_',
        );
        addTearDown(() => foreignRoot.deleteSync(recursive: true));
        StorageEncryption.active = FileCipher(FileCipher.generateKey());
        final other = Workspace(foreignRoot);
        await other.load();
        other.createNote(title: 'other device note', body: 'x');
        await other.flush();
        final before = await _snapshot(foreignRoot);
        final backupBefore = await _snapshot(backup);
        await expectLater(
          other.backups.restore(backup),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.message,
              'message',
              contains('key this device does not have'),
            ),
          ),
        );
        expect(
          await _snapshot(backup),
          backupBefore,
          reason: 'backup untouched',
        );
        final after = await _snapshot(foreignRoot);
        expect(
          after.keys.where((k) => !k.startsWith('backups')).toSet(),
          before.keys.where((k) => !k.startsWith('backups')).toSet(),
        );
        for (final k in before.keys.where((k) => !k.startsWith('backups'))) {
          expect(after[k], before[k], reason: 'live file $k unchanged');
        }
        other.dispose();
      },
    );

    test(
      'purging an expired calendar entry still works in encrypted backups',
      () async {
        final (ws, _) = await workspaceWithData();
        final backup = await ws.backups.snapshot('manual');
        expect(await ws.backups.checkManifest(backup), isEmpty);
        await ws.backups.purgeExpiredCalendarEntry(
          id: 'gone',
          tombstoneRev: '1',
        );
        expect(await ws.backups.checkManifest(backup), isEmpty);
        expect(await filesContaining(backup, canaryBody), isEmpty);
        ws.dispose();
      },
    );
  });

  group('upgrading an existing plain-text folder', () {
    /// A folder made by an older version: plain records, an attachment, a
    /// trash file, a damaged-file sidecar and two plain backups (one with a
    /// manifest).
    Future<(BackupService, Directory, Directory)> plainFolder() async {
      final store = JsonFileStore(root);
      await store.write('data', 'notes', {
        'schema': 3,
        'records': [
          {
            'id': 'n1',
            'title': canaryTitle,
            'body': canaryBody,
            'fromTheFuture': {
              'deep': [1, 2, 3],
            },
          },
        ],
        'unknownTop': 'kept',
      });
      await store.write('data', 'tasks_from_the_future', {
        'records': [
          {'id': 't1', 'newField': 'x'},
        ],
      });
      await store.write('data', 'old', {'v': 1});
      await store.moveToTrash('data', 'old');
      File('${root.path}${sep}data${sep}notes.json.corrupt-1')
          .writeAsStringSync(canaryBody);
      final att = AttachmentStore(root);
      await att.importBytes(
        Uint8List.fromList(utf8.encode(canaryAttachment * 4)),
        'png',
      );
      final backups = BackupService(root);
      final withManifest = await backups.snapshot(
        'auto-full',
        includeAttachments: true,
      );
      final legacy = Directory(
        '${root.path}${sep}backups${sep}20240101-000000-auto',
      )..createSync(recursive: true);
      Directory('${legacy.path}${sep}data').createSync();
      File('${legacy.path}${sep}data${sep}notes.json')
          .writeAsStringSync(jsonEncode({'records': [], 'canary': canaryBody}));
      return (backups, withManifest, legacy);
    }

    Future<void> expectAllEncryptedAndReadable(BackupService backups) async {
      expect(await plainFiles(root), isEmpty);
      expect(await filesContaining(root, canaryTitle), isEmpty);
      expect(await filesContaining(root, canaryBody), isEmpty);
      expect(await filesContaining(root, canaryAttachment), isEmpty);
    }

    test(
      'encrypts everything, including old backups, and nothing plain is left',
      () async {
        final (backups, withManifest, _) = await plainFolder();
        expect(await filesContaining(root, canaryBody), isNotEmpty);
        StorageEncryption.active = cipher;
        final result = await migrateToEncrypted(root, cipher, backups: backups);
        expect(result.problems, isEmpty);
        expect(result.complete, isTrue);
        expect(result.encrypted, greaterThan(5));
        await expectAllEncryptedAndReadable(backups);
        expect(
          File('${root.path}${sep}keys$sep$encryptionMarker').existsSync(),
          isTrue,
        );
        // The backup that had a manifest still verifies and restores.
        expect(await backups.checkManifest(withManifest), isEmpty);
        final check = await verifyRestorable(backups, withManifest);
        expect(check.problems, isEmpty);
        // The recovery backup exists, is kept, and verifies.
        expect(result.recoveryBackup, isNotNull);
        expect(result.recoveryBackup!.path, contains('pre-encryption'));
        expect(await backups.checkManifest(result.recoveryBackup!), isEmpty);
      },
    );

    test('keeps unknown and newer records byte for byte in meaning', () async {
      final (backups, _, _) = await plainFolder();
      StorageEncryption.active = cipher;
      await migrateToEncrypted(root, cipher, backups: backups);
      final store = JsonFileStore(root, cipher: cipher);
      final notes = (await store.read('data', 'notes'))!;
      expect(notes['unknownTop'], 'kept');
      expect((notes['records'] as List).first['fromTheFuture'], {
        'deep': [1, 2, 3],
      });
      expect((await store.read('data', 'tasks_from_the_future'))!['records'], [
        {'id': 't1', 'newField': 'x'},
      ]);
      expect((await store.readFromTrash('data', 'old'))!['v'], 1);
      // The damaged-file sidecar is encrypted, not deleted.
      final sidecar = File('${root.path}${sep}data${sep}notes.json.corrupt-1');
      expect(sidecar.existsSync(), isTrue);
      expect(
        utf8.decode(cipher.decrypt(sidecar.readAsBytesSync())),
        canaryBody,
      );
    });

    test('opens as a normal workspace afterwards', () async {
      StorageEncryption.active = null;
      var ws = Workspace(root);
      await ws.load();
      ws.createNote(title: canaryTitle, body: canaryBody);
      await ws.flush();
      ws.dispose();
      StorageEncryption.active = cipher;
      final result = await migrateToEncrypted(
        root,
        cipher,
        backups: BackupService(root),
      );
      expect(result.complete, isTrue);
      ws = Workspace(root);
      await ws.load();
      expect(ws.notes.all.single.title, canaryTitle);
      ws.dispose();
    });

    test('is idempotent', () async {
      final (backups, _, _) = await plainFolder();
      StorageEncryption.active = cipher;
      await migrateToEncrypted(root, cipher, backups: backups);
      final before = await _snapshot(root);
      final again = await migrateToEncrypted(root, cipher, backups: backups);
      expect(again.complete, isTrue);
      expect(again.encrypted, 0);
      expect(again.recoveryBackup, isNull, reason: 'nothing to protect again');
      final after = await _snapshot(root);
      expect(after.keys.toSet().difference(before.keys.toSet()), isEmpty);
      for (final k in before.keys.where((k) => !k.endsWith(encryptionMarker))) {
        expect(after[k], before[k], reason: '$k was rewritten');
      }
    });

    test(
      'an interruption part-way leaves readable data and the next run finishes',
      () async {
        final (backups, withManifest, _) = await plainFolder();
        StorageEncryption.active = cipher;
        var files = 0;
        final first = await migrateToEncrypted(
          root,
          cipher,
          backups: backups,
          hook: (step) {
            if (step.startsWith('file:') && ++files == 2) {
              throw const FileSystemException('power cut');
            }
          },
        );
        expect(first.complete, isFalse);
        expect(first.problems.first, contains('power cut'));
        expect(
          first.recoveryBackup,
          isNotNull,
          reason: 'made before any change',
        );
        // Mixed folder: the store still reads everything.
        final store = JsonFileStore(root, cipher: cipher);
        expect((await store.read('data', 'notes'))!['unknownTop'], 'kept');
        final second = await migrateToEncrypted(root, cipher, backups: backups);
        expect(second.problems, isEmpty);
        await expectAllEncryptedAndReadable(backups);
        expect(await backups.checkManifest(withManifest), isEmpty);
      },
    );

    test(
      'an interruption while encrypting backups is completed later',
      () async {
        final (backups, withManifest, _) = await plainFolder();
        StorageEncryption.active = cipher;
        final first = await migrateToEncrypted(
          root,
          cipher,
          backups: backups,
          hook: (step) {
            if (step.startsWith('backup-files:')) {
              throw const FileSystemException('crash');
            }
          },
        );
        expect(first.complete, isFalse);
        final second = await migrateToEncrypted(root, cipher, backups: backups);
        expect(second.problems, isEmpty);
        await expectAllEncryptedAndReadable(backups);
        for (final b in await backups.list()) {
          final manifest = await backups.readManifest(b);
          if (manifest != null) {
            expect(await backups.checkManifest(b), isEmpty, reason: b.path);
          }
        }
        expect(await backups.checkManifest(withManifest), isEmpty);
      },
    );

    test(
      'a leftover encrypted temp file from a crash is finished or removed',
      () async {
        final (backups, _, _) = await plainFolder();
        StorageEncryption.active = cipher;
        final target = File('${root.path}${sep}data${sep}notes.json');
        final plain = target.readAsBytesSync();
        File('${target.path}.enc-tmp').writeAsBytesSync(cipher.encrypt(plain));
        final result = await migrateToEncrypted(root, cipher, backups: backups);
        expect(result.complete, isTrue);
        expect(File('${target.path}.enc-tmp').existsSync(), isFalse);
        expect(cipher.decrypt(target.readAsBytesSync()), plain);
      },
    );

    test('backup copies outside the data folder are encrypted too', () async {
      final (backups, _, _) = await plainFolder();
      final copies = Directory.systemTemp.createTempSync('theapp_enc_copies_');
      addTearDown(() => copies.deleteSync(recursive: true));
      final copy = Directory('${copies.path}${sep}20240202-000000-manual')
        ..createSync();
      File('${copy.path}${sep}notes.json').writeAsStringSync(canaryBody);
      StorageEncryption.active = cipher;
      final result = await migrateToEncrypted(
        root,
        cipher,
        backups: backups,
        extraBackupRoots: [copies],
      );
      expect(result.complete, isTrue);
      expect(await filesContaining(copies, canaryBody), isEmpty);
    });

    test(
      'an unverifiable recovery backup stops everything before any change',
      () async {
        final (_, _, _) = await plainFolder();
        StorageEncryption.active = cipher;
        final before = await _snapshot(root);
        final failing = _UnverifiableBackups(root);
        final result = await migrateToEncrypted(root, cipher, backups: failing);
        expect(result.complete, isFalse);
        expect(result.problems.first, contains('recovery backup'));
        final after = await _snapshot(root);
        for (final k in before.keys) {
          expect(after[k], before[k], reason: '$k changed');
        }
      },
    );

    test(
      'a folder with nothing to do just records that it is encrypted',
      () async {
        StorageEncryption.active = cipher;
        final result = await migrateToEncrypted(
          root,
          cipher,
          backups: BackupService(root),
        );
        expect(result.complete, isTrue);
        expect(result.encrypted, 0);
      },
    );
  });
}

class _UnverifiableBackups extends BackupService {
  _UnverifiableBackups(super.root);
  @override
  Future<bool> verify(Directory backup) async => false;
}

Future<Map<String, String>> _snapshot(Directory dir) async {
  final out = <String, String>{};
  await for (final e in dir.list(recursive: true)) {
    if (e is File) {
      out[e.path.substring(dir.path.length + 1)] = base64Encode(
        await e.readAsBytes(),
      );
    }
  }
  return out;
}
