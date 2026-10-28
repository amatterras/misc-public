// The private vault: notes only readable with the vault password (or the
// recovery code). Threat model and limits are in
// THEAPP_IMPLEMENTATION_HANDOFF.md (5/5). In short: the vault protects
// what is stored on disk, in backups and on the hub; it cannot protect
// against malware on an unlocked device. Vault items never go to search,
// AI, sharing or exports. It locks after [idleLimit] and when the app goes
// to the background. Wrong passwords (and wrong recovery codes) are slowed
// down: after a few tries each failure makes the next wait longer, and the
// wait survives closing the app (see [UnlockLimiter]).
//
// Limits of key hygiene: the vault key and every decrypted byte buffer are
// overwritten as soon as they are not needed (lock, failed or finished
// decryption). Dart strings (the typed password, the text of an open item)
// are immutable and cannot be overwritten; they stay until garbage collection.
// Malware on an unlocked device can read them.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/vault_models.dart';
import '../../data/repositories/record_collection.dart';
import 'vault_crypto.dart';

/// A decrypted vault item (only in memory while unlocked).
typedef VaultEntry = ({String id, String title, String text, DateTime at});

/// Slows down guessing: the first [freeTries] wrong tries cost nothing, then
/// each failure makes the next attempt wait longer (5 s, 15 s, 30 s, 1 min,
/// 5 min, then 15 min), and a right password starts over. The count and the
/// end of the wait are kept (on this device only), so closing and reopening
/// the app does not reset them.
class UnlockLimiter {
  UnlockLimiter({this.freeTries = 3, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final int freeTries;
  final DateTime Function() _now;
  int failures = 0;
  DateTime? lockedUntil;

  static const delays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
  ];

  /// How long to wait before trying again, or null.
  Duration? get wait {
    final until = lockedUntil;
    if (until == null) return null;
    final left = until.difference(_now());
    return left > Duration.zero ? left : null;
  }

  void failed() {
    failures++;
    final over = failures - freeTries;
    if (over > 0) {
      lockedUntil = _now().add(delays[(over - 1).clamp(0, delays.length - 1)]);
    }
  }

  void succeeded() {
    failures = 0;
    lockedUntil = null;
  }

  Map<String, dynamic> toJson() => {
    'failures': failures,
    if (lockedUntil != null)
      'lockedUntil': lockedUntil!.toUtc().toIso8601String(),
  };

  void load(Map<String, dynamic>? json) {
    failures = (json?['failures'] as num?)?.toInt() ?? 0;
    lockedUntil = DateTime.tryParse('${json?['lockedUntil'] ?? ''}');
  }
}

/// Too many wrong tries: nothing was tried (no key work was done).
class VaultLockedOut extends VaultCryptoException {
  VaultLockedOut(this.waitFor)
    : super(
        'Too many wrong tries. Wait ${waitFor.inSeconds < 90 ? '${waitFor.inSeconds} seconds' : '${waitFor.inMinutes} minutes'} '
        'and try again.',
      );

  final Duration waitFor;
}

class VaultService extends ChangeNotifier {
  VaultService({
    required this.meta,
    required this.items,
    this.kdf = const KdfParams(),
    UnlockLimiter? limiter,
    this.saveAttempts,
  }) : limiter = limiter ?? UnlockLimiter();

  /// Slows down wrong passwords (kept on this device only).
  final UnlockLimiter limiter;

  /// Keeps [limiter]'s state (null: only for this run).
  final Future<void> Function(Map<String, dynamic> state)? saveAttempts;

  void _checkAllowed() {
    final wait = limiter.wait;
    if (wait != null) throw VaultLockedOut(wait);
  }

  Future<void> _wrong() async {
    limiter.failed();
    await saveAttempts?.call(limiter.toJson());
  }

  Future<void> _right() async {
    if (limiter.failures == 0 && limiter.lockedUntil == null) return;
    limiter.succeeded();
    await saveAttempts?.call(limiter.toJson());
  }

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
    _checkAllowed();
    final pk = await deriveKey(password, _unb64(m.salt), p);
    try {
      _key = open(pk, _unb64(m.wrapNonce), _unb64(m.wrapped), 'vault-key');
    } on VaultCryptoException {
      await _wrong();
      rethrow;
    } finally {
      wipe(pk);
    }
    await _right();
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
    _checkAllowed();
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
      await _wrong();
      throw const VaultCryptoException('That recovery code is not right.');
    } finally {
      wipe(rk);
    }
    await _right();
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
        final Map<String, dynamic> j;
        try {
          j = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
        } finally {
          wipe(plain); // the decrypted bytes are not kept
        }
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

  /// Whether [text] holds something from an open vault item (a title or
  /// text of at least [minLength] characters). Used to keep vault content out
  /// of AI requests and the shared clipboard even if it was copied.
  bool containsPlaintext(String text, {int minLength = 8}) {
    if (_key == null || text.length < minLength) return false;
    for (final e in entries()) {
      for (final part in [e.title, e.text]) {
        if (part.length >= minLength &&
            (text.contains(part) || part.contains(text))) {
          return true;
        }
      }
    }
    return false;
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
