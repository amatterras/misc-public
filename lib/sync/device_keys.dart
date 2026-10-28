// Per-device keys, so the workspace key can be changed when a device is
// removed and the remaining devices receive the new key without anyone
// typing a secret, while the hub (and the removed device) get nothing.
//
// * Each device makes an ECDH P-256 key pair; the private half stays in
//   OS-protected storage (sync_key_store.dart), the public half goes to the
//   hub with an *endorsement*: an HMAC under the first workspace key over
//   the device id and public key. Only a device that holds the workspace key
//   can endorse a key, so the hub cannot slip in a key of its own.
// * Rotation: the device that removes another makes a new workspace key
//   (the next epoch) and wraps it separately for each endorsed device
//   (ECIES: ephemeral ECDH, HKDF, AES-256-GCM). The wrapped key also carries
//   an HMAC under the first workspace key, so a device accepts a new key only
//   from a holder of the old one (never from the hub).
// * A device that was removed no longer reaches the hub, gets no wrapped key,
//   and cannot open anything sealed under the new epoch.
//
// Pure Dart (pointycastle).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../data/storage/storage_encryption.dart'
    show DecryptionFailure, FileCipher;

final _domain = ECDomainParameters('secp256r1');

SecureRandom _random() {
  final r = FortunaRandom();
  final seed = Random.secure();
  r.seed(
    KeyParameter(
      Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256))),
    ),
  );
  return r;
}

Uint8List _bigToBytes(BigInt v, int length) {
  final out = Uint8List(length);
  var x = v;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

BigInt _bytesToBig(List<int> b) {
  var v = BigInt.zero;
  for (final x in b) {
    v = (v << 8) | BigInt.from(x);
  }
  return v;
}

Uint8List _sharedSecret(Uint8List privateBytes, Uint8List publicBytes) {
  final agreement = ECDHBasicAgreement()
    ..init(ECPrivateKey(_bytesToBig(privateBytes), _domain));
  final point = _domain.curve.decodePoint(publicBytes);
  if (point == null) throw const DecryptionFailure('Invalid public key');
  final secret = agreement.calculateAgreement(ECPublicKey(point, _domain));
  // HKDF-SHA256 over the raw shared secret.
  final prk = Hmac(
    sha256,
    utf8.encode('theapp-ecies-v1'),
  ).convert(_bigToBytes(secret, 32)).bytes;
  return Uint8List.fromList(
    Hmac(sha256, prk).convert([...utf8.encode('wrap key'), 1]).bytes,
  );
}

class DeviceKeyPair {
  DeviceKeyPair(this.privateBytes, this.publicBytes);

  /// 32 bytes: keep in OS-protected storage only.
  final Uint8List privateBytes;

  /// 65 bytes (uncompressed point): goes to the hub.
  final Uint8List publicBytes;

  factory DeviceKeyPair.generate() {
    final gen = ECKeyGenerator()
      ..init(
        ParametersWithRandom(ECKeyGeneratorParameters(_domain), _random()),
      );
    final pair = gen.generateKeyPair();
    final priv = pair.privateKey;
    final pub = pair.publicKey;
    return DeviceKeyPair(
      _bigToBytes(priv.d!, 32),
      Uint8List.fromList(pub.Q!.getEncoded(false)),
    );
  }

  String get publicBase64 => base64Encode(publicBytes);
}

/// HMAC under the first workspace key over the device id and public key.
String endorseDeviceKey(
  Uint8List firstWorkspaceKey,
  String deviceId,
  String publicBase64,
) => Hmac(sha256, firstWorkspaceKey)
    .convert(utf8.encode('theapp-device-endorse-v1|$deviceId|$publicBase64'))
    .toString();

bool verifyDeviceKey(
  Uint8List firstWorkspaceKey,
  String deviceId,
  String publicBase64,
  String endorsement,
) {
  final expected = endorseDeviceKey(firstWorkspaceKey, deviceId, publicBase64);
  if (expected.length != endorsement.length) return false;
  var diff = 0;
  for (var i = 0; i < expected.length; i++) {
    diff |= expected.codeUnitAt(i) ^ endorsement.codeUnitAt(i);
  }
  return diff == 0;
}

List<int> _rotationContext(int epoch, String deviceId) =>
    utf8.encode('theapp-rotate-v1|$epoch|$deviceId');

/// [newKey] (the key for [epoch]) wrapped for one device. [firstWorkspaceKey]
/// authenticates it as coming from a holder of the existing key.
String wrapRotatedKey({
  required Uint8List recipientPublic,
  required int epoch,
  required String deviceId,
  required Uint8List newKey,
  required Uint8List firstWorkspaceKey,
}) {
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(_domain), _random()));
  final eph = gen.generateKeyPair();
  final ephPriv = _bigToBytes(eph.privateKey.d!, 32);
  final ephPub = Uint8List.fromList(eph.publicKey.Q!.getEncoded(false));
  final mac = Hmac(
    sha256,
    firstWorkspaceKey,
  ).convert([..._rotationContext(epoch, deviceId), ...newKey]).bytes;
  final wrapKey = _sharedSecret(ephPriv, recipientPublic);
  final sealed = FileCipher(wrapKey)
      .encrypt([...newKey, ...mac], context: _rotationContext(epoch, deviceId));
  return base64Encode([...ephPub, ...sealed]);
}

/// The new key from [wrapped], or null if it is not for this device, was
/// changed, or was not made by a holder of the first workspace key (a hub
/// that wraps a key of its own for the device's public key fails this).
Uint8List? unwrapRotatedKey({
  required DeviceKeyPair device,
  required int epoch,
  required String deviceId,
  required String wrapped,
  required Uint8List firstWorkspaceKey,
}) {
  try {
    final bytes = base64Decode(wrapped);
    if (bytes.length < 65 + 16) return null;
    final wrapKey = _sharedSecret(
      device.privateBytes,
      Uint8List.fromList(bytes.sublist(0, 65)),
    );
    final plain = FileCipher(wrapKey)
        .decrypt(bytes.sublist(65), context: _rotationContext(epoch, deviceId));
    if (plain.length != 64) return null;
    final key = Uint8List.fromList(plain.sublist(0, 32));
    final mac = plain.sublist(32);
    final expected = Hmac(
      sha256,
      firstWorkspaceKey,
    ).convert([..._rotationContext(epoch, deviceId), ...key]).bytes;
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= mac[i] ^ expected[i];
    }
    return diff == 0 ? key : null;
  } on DecryptionFailure {
    return null;
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}
