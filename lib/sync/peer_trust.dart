// How two of your own devices recognise each other without a pairing code.
//
// Every device of a workspace holds the workspace's end-to-end key. A device
// that wants to sync with another one proves it holds that key (an HMAC over
// its id, the time and a random nonce, made with a key derived from the
// workspace key, never the key itself); the other device checks the proof and
// hands out a sync token. So there is nothing to type and nothing to repeat:
// a device that holds the key is trusted, one that does not is refused, and
// a device removed from the workspace (which gets a new key epoch) stops
// being able to prove anything.
//
// * The proof is only good for a few minutes and only once (a captured one
//   cannot be replayed).
// * The "tag" is a short public fingerprint of the key, announced on the
//   network so devices of another workspace are not even tried. It reveals
//   nothing usable: it is a one-way HMAC under the derived key.
// * Nothing here is sent in a form that opens data: records and files stay
//   sealed with the workspace key exactly as on the hub.
//
// Pure Dart (no Flutter).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class PeerTrust {
  PeerTrust(Uint8List workspaceKey, {DateTime Function()? clock})
    : _key = Hmac(
        sha256,
        workspaceKey,
      ).convert(utf8.encode('theapp-peer-auth-v1')).bytes,
      _now = clock ?? DateTime.now;

  final List<int> _key;
  final DateTime Function() _now;

  /// How far a proof's time may be from this device's clock.
  static const maxSkew = Duration(minutes: 5);

  final Map<String, DateTime> _seen = {};

  String _mac(String text) =>
      Hmac(sha256, _key).convert(utf8.encode(text)).toString();

  /// A short public fingerprint of the workspace key (16 hex characters).
  String get tag => _mac('tag').substring(0, 16);

  /// What a device sends to join: its id, name, time, a nonce and the proof.
  Map<String, String> proof(String deviceId, String name, {Random? random}) {
    final rng = random ?? Random.secure();
    final nonce = [
      for (var i = 0; i < 12; i++)
        rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    final ts = '${_now().toUtc().millisecondsSinceEpoch}';
    return {
      'deviceId': deviceId,
      'name': name,
      'ts': ts,
      'nonce': nonce,
      'proof': _mac('join|$deviceId|$ts|$nonce'),
    };
  }

  /// Whether [join] is a fresh, unused proof from a holder of the key.
  bool verify(Map<String, dynamic> join) {
    final id = join['deviceId'], ts = join['ts'], nonce = join['nonce'];
    final proof = join['proof'];
    if (id is! String ||
        ts is! String ||
        nonce is! String ||
        proof is! String) {
      return false;
    }
    final millis = int.tryParse(ts);
    if (millis == null) return false;
    final now = _now().toUtc();
    final at = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    if (now.difference(at).abs() > maxSkew) return false;
    _seen.removeWhere((_, t) => now.difference(t) > maxSkew * 2);
    if (_seen.containsKey(nonce)) return false;
    final expected = _mac('join|$id|$ts|$nonce');
    if (!_same(expected, proof)) return false;
    _seen[nonce] = now;
    return true;
  }

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
