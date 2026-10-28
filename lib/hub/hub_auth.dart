// Device registration and authentication for the hub. Pure Dart.
//
// * A device pairs once with a short one-time code (made on the PC with
//   `thehub pair`), valid for 10 minutes, usable once.
// * It then receives a long random token (256 bits). The hub only stores a
//   SHA-256 hash of each token, so `devices.json` is useless to a thief.
// * The admin token (used by the `thehub` command to stop the service,
//   create pairing codes, etc.) is stored encrypted with Windows DPAPI.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../sync/protocol.dart';
import '../sync/secret_store.dart';

class HubDevice {
  HubDevice({
    required this.id,
    required this.name,
    required this.tokenHash,
    required this.createdAt,
    this.revoked = false,
    this.readOnly = false,
    this.lastSeen,
    this.publicKey,
    this.endorsement,
  });

  final String id;
  final String name;
  final String tokenHash;
  final DateTime createdAt;
  final bool revoked;

  /// The last request this device made (updated at most once a minute).
  DateTime? lastSeen;

  /// The device's public key (base64) and the endorsement that shows a holder
  /// of the workspace key vouches for it (see device_keys.dart). The hub only
  /// stores them; it cannot make a valid endorsement.
  String? publicKey;
  String? endorsement;

  /// May only read (a mirror): pushes and uploads are refused by the hub.
  final bool readOnly;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'tokenHash': tokenHash,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'revoked': revoked,
    if (readOnly) 'readOnly': true,
    if (lastSeen != null) 'lastSeen': lastSeen!.toUtc().toIso8601String(),
    'publicKey': ?publicKey,
    'endorsement': ?endorsement,
  };

  factory HubDevice.fromJson(Map<String, dynamic> j) => HubDevice(
    id: j['id'] as String,
    name: j['name'] as String,
    tokenHash: j['tokenHash'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String),
    revoked: j['revoked'] as bool? ?? false,
    // Mirrors paired before this flag existed have ids starting "mirror".
    readOnly: j['readOnly'] == true || (j['id'] as String).startsWith('mirror'),
    lastSeen: DateTime.tryParse('${j['lastSeen'] ?? ''}'),
    publicKey: j['publicKey'] as String?,
    endorsement: j['endorsement'] as String?,
  );
}

class HubAuth {
  HubAuth._(this.dir);

  static const pairingLifetime = Duration(minutes: 10);

  /// Letters and digits that can't be confused when read aloud or typed.
  static const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  final Directory dir;
  final _random = Random.secure();
  final Map<String, HubDevice> _devices = {};
  final List<Map<String, dynamic>> _pairing = [];
  late String _adminHash;

  String get _sep => Platform.pathSeparator;
  File get _devicesFile => File('${dir.path}${_sep}devices.json');
  static File adminTokenFile(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}admin.token');

  Iterable<HubDevice> get devices => _devices.values;

  static Future<HubAuth> open(Directory dir) async {
    final auth = HubAuth._(dir);
    await auth._load();
    return auth;
  }

  static String hash(String secret) =>
      sha256.convert(utf8.encode(secret)).toString();

  String _token() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _load() async {
    if (await _devicesFile.exists()) {
      final json =
          jsonDecode(await _devicesFile.readAsString()) as Map<String, dynamic>;
      for (final d in json['devices'] as List? ?? const []) {
        final device = HubDevice.fromJson(d as Map<String, dynamic>);
        _devices[device.id] = device;
      }
    }
    // A fresh admin token for every start: whoever can read this user's
    // DPAPI-protected file can control the hub; nobody else can.
    final admin = _token();
    await writeSecret(adminTokenFile(dir), admin);
    _adminHash = hash(admin);
  }

  /// Saves run one at a time (pairings and revocations can arrive together;
  /// two writers on the same temporary file would fail or garble the
  /// registry). Each save writes the registry as it is when it runs.
  Future<void> _saving = Future.value();

  Future<void> _save() {
    final next = _saving.catchError((_) {}).then((_) => _writeDevices());
    _saving = next;
    return next;
  }

  Future<void> _writeDevices() async {
    final tmp = File('${_devicesFile.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent(' ').convert({
        'devices': [for (final d in _devices.values) d.toJson()],
      }),
      flush: true,
    );
    await tmp.rename(_devicesFile.path);
  }

  /// Constant-time comparison of two hex hashes.
  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  bool isAdmin(String token) => _same(hash(token), _adminHash);

  /// The device a token belongs to, or null.
  HubDevice? authenticate(String token) {
    final h = hash(token);
    for (final d in _devices.values) {
      if (!d.revoked && _same(d.tokenHash, h)) {
        _seen(d);
        return d;
      }
    }
    return null;
  }

  /// Remembers that [d] was just heard from (and saves, at most a minute
  /// apart, so reading the list never needs a disk write per request).
  void _seen(HubDevice d) {
    final now = DateTime.now();
    final last = d.lastSeen;
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return;
    }
    d.lastSeen = now;
    unawaited(_save().catchError((_) {}));
  }

  /// Stores a device's public key and its endorsement (see device_keys.dart).
  Future<bool> setDeviceKey(
    String deviceId,
    String publicKey,
    String endorsement,
  ) async {
    final d = _devices[deviceId];
    if (d == null || d.revoked) return false;
    d.publicKey = publicKey;
    d.endorsement = endorsement;
    await _save();
    return true;
  }

  /// A new one-time pairing code, shown to the user on the PC.
  String createPairingCode() {
    _pairing.removeWhere(
      (p) => DateTime.now().isAfter(p['expires'] as DateTime),
    );
    final code = List.generate(
      8,
      (_) => _codeAlphabet[_random.nextInt(_codeAlphabet.length)],
    ).join();
    _pairing.add({
      'hash': hash(code),
      'expires': DateTime.now().add(pairingLifetime),
    });
    return code;
  }

  /// When true (the hub requires end-to-end encryption), a device paired
  /// with an ordinary code, which carries no workspace key, can only read:
  /// it could not write valid records anyway. This keeps a Raspberry Pi
  /// mirror read-only and never lets a mirror become writable.
  bool keylessDevicesReadOnly = false;

  /// An end-to-end pairing offer: [registerCode] is a one-way function of
  /// the code the user types, [wrappedKey] the workspace key wrapped under
  /// another one-way function of it (see PairingSecret). The hub learns
  /// neither the code nor the key.
  void createPairingOffer({
    required String registerCode,
    required String wrappedKey,
    bool readOnly = false,
  }) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(registerCode) ||
        wrappedKey.isEmpty ||
        wrappedKey.length > 4096) {
      throw const ProtocolException('bad_request', 'Invalid pairing offer.');
    }
    _pairing.removeWhere(
      (p) => DateTime.now().isAfter(p['expires'] as DateTime),
    );
    _pairing.add({
      'hash': hash(registerCode.toUpperCase()),
      'expires': DateTime.now().add(pairingLifetime),
      'wrappedKey': wrappedKey,
      'readOnly': readOnly,
    });
  }

  /// For a device that is already signed in (a hosted account): the wrapped
  /// key of a pairing offer, once. Null for a wrong or expired code.
  String? redeemPairingOffer(String registerCode) {
    final h = hash(registerCode.trim().toUpperCase());
    final now = DateTime.now();
    final match = _pairing
        .where(
          (p) =>
              p['wrappedKey'] != null &&
              _same(p['hash'] as String, h) &&
              now.isBefore(p['expires'] as DateTime),
        )
        .firstOrNull;
    if (match == null) return null;
    _pairing.remove(match);
    return match['wrappedKey'] as String;
  }

  /// Exchanges a pairing code for a device token (returned once, never
  /// stored). Re-pairing an existing device id replaces its old token.
  Future<String> register(
    String code,
    String deviceId,
    String name, {
    bool readOnly = false,
  }) async =>
      (await registerWithKey(code, deviceId, name, readOnly: readOnly)).token;

  /// [register], also returning the wrapped workspace key of an end-to-end
  /// pairing offer (null for an ordinary code).
  Future<({String token, String? wrappedKey})> registerWithKey(
    String code,
    String deviceId,
    String name, {
    bool readOnly = false,
  }) async {
    if (!deviceIdPattern.hasMatch(deviceId) || deviceId == 'hub') {
      throw const ProtocolException('bad_request', 'Invalid device id.');
    }
    final h = hash(code.trim().toUpperCase());
    final now = DateTime.now();
    final match = _pairing
        .where(
          (p) =>
              _same(p['hash'] as String, h) &&
              now.isBefore(p['expires'] as DateTime),
        )
        .firstOrNull;
    if (match == null) {
      throw const ProtocolException(
        'pairing_failed',
        'The pairing code is wrong or has expired.',
        status: 401,
      );
    }
    _pairing.remove(match); // single use
    final wrappedKey = match['wrappedKey'] as String?;
    final forceReadOnly =
        match['readOnly'] == true ||
        (wrappedKey == null && keylessDevicesReadOnly);
    final token = _token();
    final cleanName = name.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
    _devices[deviceId] = HubDevice(
      id: deviceId,
      name: cleanName.isEmpty
          ? deviceId
          : (cleanName.length > 60 ? cleanName.substring(0, 60) : cleanName),
      tokenHash: hash(token),
      createdAt: DateTime.now(),
      readOnly: readOnly || forceReadOnly || deviceId.startsWith('mirror'),
    );
    await _save();
    return (token: token, wrappedKey: wrappedKey);
  }

  Future<bool> revoke(String deviceId) async {
    final d = _devices[deviceId];
    if (d == null) return false;
    _devices[deviceId] = HubDevice(
      id: d.id,
      name: d.name,
      tokenHash: d.tokenHash,
      createdAt: d.createdAt,
      revoked: true,
      readOnly: d.readOnly,
      lastSeen: d.lastSeen,
    ); // (its public key is dropped: nothing is wrapped for it any more)
    await _save();
    return true;
  }
}
