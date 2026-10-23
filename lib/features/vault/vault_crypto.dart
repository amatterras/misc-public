// The private vault's cryptography, from an established library
// (PointyCastle): Argon2id turns the password into a key, AES-256-GCM
// encrypts. A random data key encrypts the items; it is stored only
// wrapped (encrypted) by the password key and by a one-time recovery
// code. Nothing here is home-made except the record layout.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Argon2id settings (OWASP minimum: 19 MiB, 2 passes, 1 lane).
class KdfParams {
  const KdfParams({
    this.memoryKiB = 19456,
    this.iterations = 2,
    this.lanes = 1,
  });

  final int memoryKiB;
  final int iterations;
  final int lanes;

  Map<String, dynamic> toJson() => {
    'alg': 'argon2id',
    'm': memoryKiB,
    't': iterations,
    'p': lanes,
  };

  /// Null for anything that is not a sane Argon2id setting.
  static KdfParams? fromJson(Object? j) {
    if (j is! Map || j['alg'] != 'argon2id') return null;
    final m = j['m'], t = j['t'], p = j['p'];
    if (m is! int || t is! int || p is! int) return null;
    if (m < 8 || m > 1 << 21 || t < 1 || t > 20 || p < 1 || p > 8) {
      return null;
    }
    return KdfParams(memoryKiB: m, iterations: t, lanes: p);
  }
}

final _random = Random.secure();

Uint8List randomBytes(int n) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) _random.nextInt(256)]);

Uint8List _argon2(String secret, Uint8List salt, KdfParams p) {
  final gen = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        salt,
        desiredKeyLength: 32,
        iterations: p.iterations,
        memory: p.memoryKiB,
        lanes: p.lanes,
      ),
    );
  return gen.process(Uint8List.fromList(utf8.encode(secret)));
}

/// Derives a 256-bit key off the UI thread (takes about a second).
Future<Uint8List> deriveKey(String secret, Uint8List salt, KdfParams p) =>
    Isolate.run(() => _argon2(secret, salt, p));

class VaultCryptoException implements Exception {
  const VaultCryptoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// AES-256-GCM with a fresh 96-bit nonce; [aad] binds the ciphertext to
/// its record (so it cannot be swapped with another one).
({Uint8List nonce, Uint8List data}) seal(
  Uint8List key,
  Uint8List plain,
  String aad,
) {
  final nonce = randomBytes(12);
  final gcm = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(key),
        128,
        nonce,
        Uint8List.fromList(utf8.encode(aad)),
      ),
    );
  return (nonce: nonce, data: gcm.process(plain));
}

/// Opens what [seal] made; throws if the key is wrong or anything changed.
Uint8List open(Uint8List key, Uint8List nonce, Uint8List data, String aad) {
  try {
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          128,
          nonce,
          Uint8List.fromList(utf8.encode(aad)),
        ),
      );
    return gcm.process(data);
  } on InvalidCipherTextException {
    throw const VaultCryptoException('Wrong password, or the data changed.');
  } on ArgumentError {
    throw const VaultCryptoException('The vault data is damaged.');
  }
}

/// A recovery code: 125 random bits as five groups of Crockford base32.
String newRecoveryCode() {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final bytes = randomBytes(25);
  final chars = [for (final b in bytes) alphabet[b & 31]].join();
  return [for (var i = 0; i < 25; i += 5) chars.substring(i, i + 5)].join('-');
}

String normalizeRecoveryCode(String code) =>
    code.toUpperCase().replaceAll(RegExp(r'[^0-9A-Z]'), '');

/// Overwrites key material (best effort: Dart may have copied it).
void wipe(Uint8List? bytes) => bytes?.fillRange(0, bytes.length, 0);
