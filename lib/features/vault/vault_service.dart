// The private vault: notes only readable with the vault password (or the
// recovery code). Threat model and limits are in
// THEAPP_IMPLEMENTATION_HANDOFF.md (5/5). In short: the vault protects
// what is stored on disk, in backups and on the hub; it cannot protect
// against malware on an unlocked device. Vault items never go to search,
// AI, sharing or exports. It locks after [idleLimit] and when the app goes
// to the background.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/vault_models.dart';
import '../../data/repositories/record_collection.dart';
import 'vault_crypto.dart';

/// A decrypted vault item (only in memory while unlocked).
typedef VaultEntry = ({String id, String title, String text, DateTime at});

class VaultService extends ChangeNotifier {
  VaultService({
    required this.meta,
    required this.items,
    this.kdf = const KdfParams(),
  });

  final RecordCollection<VaultMeta> meta;
  final RecordCollection<VaultItem> items;

  /// Settings for new vaults and new passwords (tests use smaller ones).
  final KdfParams kdf;

  static const idleLimit = Duration(minutes: 5);
  static const minPasswordLength = 10;

  Uint8List? _key;
  Timer? _idle;

  bool get exists => meta[VaultMeta.recordId] != null;
  bool get unlocked => _key != null;

  static String _b64(Uint8List b) => base64Encode(b);
  static Uint8List _unb64(String s) => base64Decode(s);

  void _touch() {
    _idle?.cancel();
    _idle = Timer(idleLimit, lock);
  }

  /// Creates the vault; returns the recovery code (shown once).
  Future<String> create(String password) async {
    if (exists) throw const VaultCryptoException('The vault already exists.');
    if (password.length < minPasswordLength) {
      throw const VaultCryptoException(
        'Use at least $minPasswordLength characters.',
      );
    }
    final dataKey = randomBytes(32);
    final recovery = newRecoveryCode();
    final m = await _wrap(dataKey, password, recovery);
    meta.put(m);
    _key = dataKey;
    _touch();
    notifyListeners();
    return recovery;
  }

  Future<VaultMeta> _wrap(
    Uint8List dataKey,
    String password,
    String recovery, {
    VaultMeta? keepRecoveryFrom,
  }) async {
    final salt = randomBytes(16);
    final pk = await deriveKey(password, salt, kdf);
    final w = seal(pk, dataKey, 'vault-key');
    wipe(pk);
    var rSalt = keepRecoveryFrom?.recoverySalt;
    var rNonce = keepRecoveryFrom?.recoveryNonce;
    var rWrapped = keepRecoveryFrom?.recoveryWrapped;
    if (keepRecoveryFrom == null) {
      final s = randomBytes(16);
      final rk = await deriveKey(normalizeRecoveryCode(recovery), s, kdf);
      final r = seal(rk, dataKey, 'vault-recovery');
      wipe(rk);
      rSalt = _b64(s);
      rNonce = _b64(r.nonce);
      rWrapped = _b64(r.data);
    }
    return VaultMeta(
      salt: _b64(salt),
      kdf: kdf.toJson(),
      wrapNonce: _b64(w.nonce),
      wrapped: _b64(w.data),
      recoverySalt: rSalt!,
      recoveryNonce: rNonce!,
      recoveryWrapped: rWrapped!,
      updatedAt: DateTime.now(),
    );
  }

  /// Unlocks with the password; throws [VaultCryptoException] if wrong.
  Future<void> unlock(String password) async {
    final m = meta[VaultMeta.recordId];
    if (m == null) throw const VaultCryptoException('There is no vault.');
    final p = KdfParams.fromJson(m.kdf);
    if (p == null) {
      throw const VaultCryptoException('The vault key record is damaged.');
    }
    final pk = await deriveKey(password, _unb64(m.salt), p);
    try {
      _key = open(pk, _unb64(m.wrapNonce), _unb64(m.wrapped), 'vault-key');
    } finally {
      wipe(pk);
    }
    _touch();
    notifyListeners();
  }

  /// Unlocks with the recovery code and sets a new password.
  Future<void> recover(String code, String newPassword) async {
    final m = meta[VaultMeta.recordId];
    if (m == null) throw const VaultCryptoException('There is no vault.');
    if (newPassword.length < minPasswordLength) {
      throw const VaultCryptoException(
        'Use at least $minPasswordLength characters.',
      );
    }
    final p = KdfParams.fromJson(m.kdf);
    if (p == null) {
      throw const VaultCryptoException('The vault key record is damaged.');
    }
    final rk = await deriveKey(
      normalizeRecoveryCode(code),
      _unb64(m.recoverySalt),
      p,
    );
    final Uint8List dataKey;
    try {
      dataKey = open(
        rk,
        _unb64(m.recoveryNonce),
        _unb64(m.recoveryWrapped),
        'vault-recovery',
      );
    } on VaultCryptoException {
      throw const VaultCryptoException('That recovery code is not right.');
    } finally {
      wipe(rk);
    }
    meta.put(await _wrap(dataKey, newPassword, '', keepRecoveryFrom: m));
    _key = dataKey;
    _touch();
    notifyListeners();
  }

  /// Changes the password (the vault must be unlocked).
  Future<void> changePassword(String newPassword) async {
    final key = _key, m = meta[VaultMeta.recordId];
    if (key == null || m == null) return;
    if (newPassword.length < minPasswordLength) {
      throw const VaultCryptoException(
        'Use at least $minPasswordLength characters.',
      );
    }
    meta.put(await _wrap(key, newPassword, '', keepRecoveryFrom: m));
    _touch();
  }

  void lock() {
    _idle?.cancel();
    _idle = null;
    if (_key == null) return;
    wipe(_key);
    _key = null;
    notifyListeners();
  }

  /// The decrypted items, newest first. Items that cannot be opened (e.g.
  /// damaged) are listed with an explanation instead of being dropped.
  List<VaultEntry> entries() {
    final key = _key;
    if (key == null) return const [];
    _touch();
    final out = <VaultEntry>[];
    for (final i in items.all) {
      try {
        final plain = open(
          key,
          _unb64(i.nonce),
          _unb64(i.data),
          'item:${i.id}',
        );
        final j = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
        out.add((
          id: i.id,
          title: '${j['title'] ?? ''}',
          text: '${j['text'] ?? ''}',
          at: i.updatedAt,
        ));
      } catch (_) {
        out.add((
          id: i.id,
          title: '(cannot be opened)',
          text: 'This item is damaged or was made with another vault key.',
          at: i.updatedAt,
        ));
      }
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  /// Saves an item (new when [id] is null); returns its id.
  String save({String? id, required String title, required String text}) {
    final key = _key;
    if (key == null) throw const VaultCryptoException('The vault is locked.');
    final itemId = id ?? newId();
    final s = seal(
      key,
      Uint8List.fromList(
        utf8.encode(jsonEncode({'title': title, 'text': text})),
      ),
      'item:$itemId',
    );
    items.put(
      VaultItem(
        id: itemId,
        nonce: _b64(s.nonce),
        data: _b64(s.data),
        updatedAt: DateTime.now(),
      ),
    );
    _touch();
    notifyListeners();
    return itemId;
  }

  void delete(String id) {
    if (_key == null) return;
    items.remove(id);
    _touch();
    notifyListeners();
  }

  @override
  void dispose() {
    lock();
    super.dispose();
  }
}
