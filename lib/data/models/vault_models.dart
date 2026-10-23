// Private vault records. Only ciphertext is stored or synced: the title
// and text of an item are inside [VaultItem.data]. See vault_service.dart.
import 'record.dart';

/// The vault's key record (id `key`): the Argon2id salt and settings, and
/// the data key wrapped by the password key and by the recovery key.
class VaultMeta implements Record {
  const VaultMeta({
    required this.salt,
    required this.kdf,
    required this.wrapNonce,
    required this.wrapped,
    required this.recoverySalt,
    required this.recoveryNonce,
    required this.recoveryWrapped,
    required this.updatedAt,
  });

  static const recordId = 'key';

  @override
  String get id => recordId;

  /// Base64 values.
  final String salt, wrapNonce, wrapped;
  final String recoverySalt, recoveryNonce, recoveryWrapped;
  final Map<String, dynamic> kdf;
  @override
  final DateTime updatedAt;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'v': 1,
    'salt': salt,
    'kdf': kdf,
    'wrapNonce': wrapNonce,
    'wrapped': wrapped,
    'recoverySalt': recoverySalt,
    'recoveryNonce': recoveryNonce,
    'recoveryWrapped': recoveryWrapped,
    'updatedAt': utcIso(updatedAt),
  };

  factory VaultMeta.fromJson(Map<String, dynamic> j) => VaultMeta(
    salt: j['salt'] as String? ?? '',
    kdf: (j['kdf'] as Map?)?.cast<String, dynamic>() ?? const {},
    wrapNonce: j['wrapNonce'] as String? ?? '',
    wrapped: j['wrapped'] as String? ?? '',
    recoverySalt: j['recoverySalt'] as String? ?? '',
    recoveryNonce: j['recoveryNonce'] as String? ?? '',
    recoveryWrapped: j['recoveryWrapped'] as String? ?? '',
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}

class VaultItem implements Record {
  const VaultItem({
    required this.id,
    required this.nonce,
    required this.data,
    required this.updatedAt,
  });

  @override
  final String id;

  /// Base64 AES-GCM nonce and ciphertext (with tag) of `{title, text}`.
  final String nonce, data;
  @override
  final DateTime updatedAt;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'nonce': nonce,
    'data': data,
    'updatedAt': utcIso(updatedAt),
  };

  factory VaultItem.fromJson(Map<String, dynamic> j) => VaultItem(
    id: j['id'] as String,
    nonce: j['nonce'] as String? ?? '',
    data: j['data'] as String? ?? '',
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
  );
}
