// The recovery code and envelope (sync/recovery_code.dart) and the service
// that creates and uses them (data/storage/recovery_service.dart).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_application_1/data/storage/backup_service.dart';
import 'package:flutter_application_1/data/storage/recovery_service.dart';
import 'package:flutter_application_1/data/storage/storage_encryption.dart';
import 'package:flutter_application_1/sync/recovery_code.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryKeys implements WorkspaceKeyStore {
  Uint8List? key;
  @override
  bool get isSecure => true;
  @override
  Future<Uint8List?> read() async => key;
  @override
  Future<void> write(Uint8List k) async => key = k;
}

void main() {
  const fastN = 1 << 4; // scrypt cost, test-only
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_recovery_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('code', () {
    test('34 characters, groups of four, parses back to the same secret', () {
      final code = RecoveryCode.generate(Random(1));
      expect(code.text.replaceAll('-', '').length, 34);
      expect(code.text.split('-').every((g) => g.length <= 4), isTrue);
      final back = RecoveryCode.parse(code.text)!;
      expect(back.secret, code.secret);
    });

    test('case, spaces and look-alike letters do not matter', () {
      final code = RecoveryCode.generate(Random(2));
      final sloppy = code.text.toLowerCase().replaceAll('-', '  ');
      expect(RecoveryCode.parse(sloppy)!.secret, code.secret);
    });

    test('a typing mistake is caught by the check, not accepted', () {
      final code = RecoveryCode.generate(Random(3));
      final chars = code.text.replaceAll('-', '').split('');
      chars[5] = chars[5] == '7' ? '8' : '7';
      expect(RecoveryCode.parse(chars.join()), isNull);
      expect(RecoveryCode.parse('too short'), isNull);
      expect(RecoveryCode.parse(''), isNull);
    });

    test('two codes differ', () {
      expect(RecoveryCode.generate().text, isNot(RecoveryCode.generate().text));
    });
  });

  group('envelope', () {
    final material = RecoveryMaterial(
      atRestKey: Uint8List.fromList(List.generate(32, (i) => i)),
      syncKeys: {1: Uint8List(32), 2: Uint8List.fromList(List.filled(32, 7))},
      syncCurrent: 2,
    );

    test('opens with its code and returns every key', () {
      final code = RecoveryCode.generate();
      final env = RecoveryEnvelope.seal(material, code, n: fastN);
      final back = RecoveryEnvelope.open(env, code);
      expect(back.atRestKey, material.atRestKey);
      expect(back.syncCurrent, 2);
      expect(back.syncKeys[2], material.syncKeys[2]);
      expect(env['syncEpoch'], 2);
    });

    test('the envelope holds no key or code in the clear', () {
      final code = RecoveryCode.generate();
      final text = jsonEncode(RecoveryEnvelope.seal(material, code, n: fastN));
      expect(text.contains(base64Encode(material.atRestKey)), isFalse);
      expect(text.contains(code.text), isFalse);
      expect(text.contains(code.text.replaceAll('-', '')), isFalse);
    });

    test('a wrong code, damage and a newer format all fail cleanly', () {
      final code = RecoveryCode.generate();
      final env = RecoveryEnvelope.seal(material, code, n: fastN);
      expect(
        () => RecoveryEnvelope.open(env, RecoveryCode.generate()),
        throwsA(isA<RecoveryFailure>()),
      );
      final damaged = {...env, 'ct': base64Encode(List.filled(60, 1))};
      expect(
        () => RecoveryEnvelope.open(damaged, code),
        throwsA(isA<RecoveryFailure>()),
      );
      expect(
        () => RecoveryEnvelope.open({...env, 'v': 99}, code),
        throwsA(isA<RecoveryFailure>()),
      );
      expect(
        () => RecoveryEnvelope.open({'format': 'other'}, code),
        throwsA(isA<RecoveryFailure>()),
      );
    });
  });

  group('service', () {
    Future<(RecoveryService, _MemoryKeys)> workspace([Directory? at]) async {
      final root = at ?? dir;
      final keys = _MemoryKeys()..key = FileCipher.generateKey();
      final enc = await StorageEncryption.open(root, keys: keys);
      expect(enc.status, EncryptionStatus.enabled);
      // Some encrypted data, as the app would have.
      await File('${root.path}${Platform.pathSeparator}data.json')
          .writeAsBytes(enc.cipher!.encryptText('{"hello":"world"}'));
      return (RecoveryService(root, keys: keys), keys);
    }

    test('status: none, then current once a code was made', () async {
      final (service, _) = await workspace();
      expect((await service.status()).state, RecoveryState.none);
      final code = await service.create();
      expect(code.text, isNotEmpty);
      final s = await service.status();
      expect(s.state, RecoveryState.current);
      expect(s.created, isNotNull);
    });

    test('the code is not written anywhere in the workspace', () async {
      final (service, _) = await workspace();
      final code = await service.create();
      final plain = code.text.replaceAll('-', '');
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        expect(
          latin1.decode(f.readAsBytesSync()).contains(plain),
          isFalse,
          reason: f.path,
        );
      }
    });

    test('losing the key, the code gets the data back', () async {
      final (service, keys) = await workspace();
      final code = await service.create();
      keys.key = null; // every trusted device and its keychain are gone
      expect(
        (await StorageEncryption.open(dir, keys: keys)).status,
        EncryptionStatus.keyMissing,
      );
      final result = await service.restore(code.text);
      expect(result.ok, isTrue, reason: result.message);
      expect(
        (await StorageEncryption.open(dir, keys: keys)).status,
        EncryptionStatus.enabled,
      );
    });

    test('a wrong code changes nothing', () async {
      final (service, keys) = await workspace();
      await service.create();
      keys.key = null;
      final result = await service.restore(RecoveryCode.generate().text);
      expect(result.ok, isFalse);
      expect(keys.key, isNull);
    });

    test('a mistyped code is refused before anything is read', () async {
      final (service, keys) = await workspace();
      await service.create();
      keys.key = null;
      final result = await service.restore('1234-5678');
      expect(result.ok, isFalse);
      expect(keys.key, isNull);
    });

    test('keys of another workspace are never installed', () async {
      final (service, keys) = await workspace();
      await service.create();
      final other = Directory.systemTemp.createTempSync('theapp_other_');
      addTearDown(() => other.deleteSync(recursive: true));
      final (otherService, _) = await workspace(other);
      final otherCode = await otherService.create();
      keys.key = null;
      final result = await service.restore(
        otherCode.text,
        envelope: otherService.file,
      );
      expect(result.ok, isFalse);
      expect(keys.key, isNull, reason: 'nothing was installed');
    });

    test('ordinary backups carry the envelope but never the keys', () {
      expect(
        BackupService.isSecret(
          'recovery${Platform.pathSeparator}recovery.json',
        ),
        isFalse,
      );
      expect(BackupService.isSecret('keys/workspace.key'), isTrue);
    });
  });
}
