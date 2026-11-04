// The recovery code: a one-time safety copy of the workspace keys.
//
// misc. keeps its keys in OS-protected storage (Windows DPAPI, the iOS
// Keychain) and moves them between trusted devices by itself. The recovery
// code is for the one case nothing else covers: every trusted device is gone
// (a new PC, a wiped iPhone) and the keys are not there to open the data.
//
// * The code is 168 random bits (a 20-byte secret and a 1-byte check), shown
//   once as 34 letters and digits in groups of four. It is never stored: not
//   in the workspace, not in a backup, not on the sync hub, not in the log.
// * What IS stored (in the workspace's `recovery/` folder, so ordinary
//   backups carry it) is an *envelope*: the keys, sealed with AES-256-GCM
//   under a key made from the code with scrypt. The envelope alone opens
//   nothing; with the code it opens everything.
// * Nobody, including the author of this app, can recover the keys without
//   the code or a trusted device. If every device and the code are lost, the
//   encrypted data cannot be opened. That is the price of end-to-end
//   encryption, and the app says so where the code is shown.
//
// Pure Dart (no Flutter), so it is easy to test.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../data/storage/storage_encryption.dart'
    show DecryptionFailure, FileCipher;

/// Wrong code, damaged envelope, or an envelope from a newer version.
class RecoveryFailure implements Exception {
  const RecoveryFailure(this.message);
  final String message;
  @override
  String toString() => 'RecoveryFailure: $message';
}

class RecoveryCode {
  RecoveryCode._(this._secret);

  static const secretLength = 20;
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford

  final Uint8List _secret;

  /// A new random code.
  factory RecoveryCode.generate([Random? random]) {
    final rng = random ?? Random.secure();
    return RecoveryCode._(
      Uint8List.fromList([
        for (var i = 0; i < secretLength; i++) rng.nextInt(256),
      ]),
    );
  }

  /// The secret the envelope key is made from.
  Uint8List get secret => Uint8List.fromList(_secret);

  static int _check(Uint8List secret) => sha256.convert(secret).bytes.first;

  /// "XXXX-XXXX-…" for people to write down or paste.
  String get text {
    final bytes = Uint8List(secretLength + 1)
      ..setRange(0, secretLength, _secret)
      ..[secretLength] = _check(_secret);
    var bits = 0, acc = 0;
    final out = StringBuffer();
    for (final b in bytes) {
      acc = (acc << 8) | b;
      bits += 8;
      while (bits >= 5) {
        out.write(_alphabet[(acc >> (bits - 5)) & 31]);
        bits -= 5;
      }
      acc &= (1 << bits) - 1;
    }
    if (bits > 0) out.write(_alphabet[(acc << (5 - bits)) & 31]);
    final s = out.toString();
    return [
      for (var i = 0; i < s.length; i += 4)
        s.substring(i, min(i + 4, s.length)),
    ].join('-');
  }

  /// Reads what a person typed or pasted: case, spaces and hyphens do not
  /// matter, and the look-alikes O, I and L are read as 0, 1 and 1. Null if
  /// it is not a valid code (wrong length, a character outside the
  /// alphabet, or the check does not match, i.e. a typing mistake).
  static RecoveryCode? parse(String input) {
    final clean = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-]'), '')
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
    const chars = ((secretLength + 1) * 8 + 4) ~/ 5; // 34
    if (clean.length != chars) return null;
    var bits = 0, acc = 0;
    final bytes = <int>[];
    for (final c in clean.split('')) {
      final v = _alphabet.indexOf(c);
      if (v < 0) return null;
      acc = (acc << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bytes.add((acc >> (bits - 8)) & 255);
        bits -= 8;
        acc &= (1 << bits) - 1;
      }
    }
    if (bytes.length < secretLength + 1) return null;
    final secret = Uint8List.fromList(bytes.sublist(0, secretLength));
    if (bytes[secretLength] != _check(secret)) return null;
    return RecoveryCode._(secret);
  }
}

/// What the envelope protects.
class RecoveryMaterial {
  const RecoveryMaterial({
    required this.atRestKey,
    this.syncKeys = const {},
    this.syncCurrent,
  });

  /// The 256-bit key that encrypts the data folder.
  final Uint8List atRestKey;

  /// End-to-end sync keys by epoch (empty if sync was never set up) and the
  /// epoch in use.
  final Map<int, Uint8List> syncKeys;
  final int? syncCurrent;
}

abstract final class RecoveryEnvelope {
  static const format = 'misc-recovery';
  static const version = 1;

  /// scrypt cost: 16 MB and about a second on a phone. The code itself is
  /// 160 random bits, so the cost only guards against future weaknesses.
  static const defaultN = 1 << 14;

  static Uint8List _derive(
    RecoveryCode code,
    Uint8List salt, {
    required int n,
    required int r,
    required int p,
  }) {
    final scrypt = Scrypt()..init(ScryptParameters(n, r, p, 32, salt));
    return scrypt.process(code.secret);
  }

  /// Seals [material] under [code].
  static Map<String, dynamic> seal(
    RecoveryMaterial material,
    RecoveryCode code, {
    DateTime? now,
    int n = defaultN,
    Random? random,
  }) {
    final rng = random ?? Random.secure();
    final salt = Uint8List.fromList([
      for (var i = 0; i < 16; i++) rng.nextInt(256),
    ]);
    final key = _derive(code, salt, n: n, r: 8, p: 1);
    final created = (now ?? DateTime.now()).toUtc().toIso8601String();
    final payload = jsonEncode({
      'at': base64Encode(material.atRestKey),
      if (material.syncKeys.isNotEmpty)
        'sync': {
          'current': material.syncCurrent,
          'keys': {
            for (final e in material.syncKeys.entries)
              '${e.key}': base64Encode(e.value),
          },
        },
      'created': created,
    });
    final sealed = FileCipher(key).encryptText(payload);
    return {
      'format': format,
      'v': version,
      'created': created,
      // Not secret: lets the app say when the code no longer covers the
      // newest sync key.
      'syncEpoch': material.syncCurrent,
      'kdf': {
        'alg': 'scrypt',
        'n': n,
        'r': 8,
        'p': 1,
        'salt': base64Encode(salt),
      },
      'ct': base64Encode(sealed),
    };
  }

  /// Opens [envelope] with [code]. Throws [RecoveryFailure] for a wrong code
  /// (the sealed data does not verify) or an unreadable envelope.
  static RecoveryMaterial open(
    Map<String, dynamic> envelope,
    RecoveryCode code,
  ) {
    try {
      if (envelope['format'] != format) {
        throw const RecoveryFailure('This is not a recovery envelope.');
      }
      if ((envelope['v'] as int? ?? 0) > version) {
        throw const RecoveryFailure(
          'This recovery envelope was made by a newer version of misc.',
        );
      }
      final kdf = (envelope['kdf'] as Map).cast<String, dynamic>();
      if (kdf['alg'] != 'scrypt') {
        throw const RecoveryFailure('Unknown recovery format.');
      }
      final key = _derive(
        code,
        base64Decode(kdf['salt'] as String),
        n: kdf['n'] as int,
        r: kdf['r'] as int,
        p: kdf['p'] as int,
      );
      final plain = utf8.decode(
        FileCipher(key).decrypt(base64Decode(envelope['ct'] as String)),
      );
      final json = jsonDecode(plain) as Map<String, dynamic>;
      final at = base64Decode(json['at'] as String);
      if (at.length != FileCipher.keyLength) {
        throw const RecoveryFailure('The recovery envelope is damaged.');
      }
      final sync = json['sync'] as Map<String, dynamic>?;
      return RecoveryMaterial(
        atRestKey: at,
        syncKeys: {
          if (sync != null)
            for (final e in (sync['keys'] as Map).entries)
              int.parse('${e.key}'): base64Decode(e.value as String),
        },
        syncCurrent: sync?['current'] as int?,
      );
    } on DecryptionFailure {
      throw const RecoveryFailure(
        'That recovery code does not open this workspace.',
      );
    } on RecoveryFailure {
      rethrow;
    } on Object {
      throw const RecoveryFailure('The recovery envelope is damaged.');
    }
  }
}
