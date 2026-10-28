// End-to-end encryption for sync. The hub (and anyone who runs it) only ever
// holds ciphertext: records and attachments are sealed on the device before
// they are sent, and opened on the device after they are received.
//
// * Cipher: AES-256-GCM with a per-message key (HKDF) and random nonce, the
//   same vetted construction as the files at rest (FileCipher).
// * One random 256-bit workspace key, shared by the user's devices, never
//   sent to the hub in the clear. A new device gets it wrapped under a key
//   made from the pairing code, which the hub never sees (see [PairingSecret]).
// * Each sealed record is bound to its place: collection, id and revision
//   are authenticated, so the hub cannot swap one ciphertext for another.
// * What the hub can still see, because it needs it: the record's
//   collection, its random id, revision stamp (device id and time), the
//   deleted flag, sizes, and for shares the expiry and revoked flags.
//   Titles, text, URLs, file names and every other field are inside.
//
// Pure Dart (no Flutter): the hub uses [isEnvelope] and [envelopeShapeOk].
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../data/storage/storage_encryption.dart'
    show DecryptionFailure, FileCipher;
import 'protocol.dart';

const envelopeVersion = 1;

/// A record from the hub that is not encrypted although this workspace
/// expects it to be (an old hub copy, or a hub that was tampered with).
class PlaintextRecordException implements Exception {
  const PlaintextRecordException(this.key);
  final String key;
  @override
  String toString() => 'PlaintextRecordException: $key';
}

/// Whether [data] is a sealed record.
bool isEnvelope(Map<String, dynamic>? data) =>
    data != null && data['e2ee'] == envelopeVersion && data['c'] is String;

/// What a hub that requires encryption accepts as a record: exactly
/// `{e2ee, c}`, and for shares also `pub` with only the fields the hub
/// needs to serve the page. Nothing else (so no stray plain field).
bool envelopeShapeOk(String collection, Map<String, dynamic> data) {
  if (!isEnvelope(data)) return false;
  final allowed = collection == 'shares' ? {'e2ee', 'c', 'pub'} : {'e2ee', 'c'};
  if (!data.keys.every(allowed.contains)) return false;
  if ((data['c'] as String).length > maxRecordBytes * 2) return false;
  final pub = data['pub'];
  if (pub == null) return true;
  if (collection != 'shares' || pub is! Map<String, dynamic>) return false;
  if (!pub.keys.every({'expiresAt', 'revoked', 'ct'}.contains)) return false;
  if (pub['expiresAt'] != null && pub['expiresAt'] is! String) return false;
  if (pub['revoked'] != null && pub['revoked'] is! bool) return false;
  if (pub['ct'] != null && pub['ct'] is! String) return false;
  return true;
}

class SyncCrypto {
  SyncCrypto(Uint8List workspaceKey)
    : _key = Uint8List.fromList(workspaceKey),
      _cipher = FileCipher(workspaceKey);

  factory SyncCrypto.generate() => SyncCrypto(FileCipher.generateKey());

  final Uint8List _key;
  final FileCipher _cipher;

  /// A copy of the key, only for wrapping it for another device or storing
  /// it in OS-protected storage.
  Uint8List exportKey() => Uint8List.fromList(_key);

  /// Overwrites the key in memory (best effort).
  void dispose() {
    _key.fillRange(0, _key.length, 0);
    _cipher.dispose();
  }

  static List<int> _context(String collection, String id, String rev) =>
      utf8.encode('theapp-sync-v1|$collection|$id|$rev');

  /// The sealed form of a record's JSON.
  Map<String, dynamic> seal(
    String collection,
    String id,
    String rev,
    Map<String, dynamic> data,
  ) {
    final sealed = _cipher.encrypt(
      utf8.encode(jsonEncode(data)),
      context: _context(collection, id, rev),
    );
    return {
      'e2ee': envelopeVersion,
      'c': base64Encode(sealed),
      if (collection == 'shares') 'pub': _sharePublicPart(data),
    };
  }

  /// Only what the hub needs to serve and expire a share link: no title,
  /// no text. [ShareLink.sealed] is encrypted with a key that only the link
  /// holds (see [ShareSeal]).
  static Map<String, dynamic> _sharePublicPart(Map<String, dynamic> data) => {
    'expiresAt': data['expiresAt'],
    'revoked': data['revoked'] == true,
    if (data['revoked'] != true && data['sealed'] is String)
      'ct': data['sealed'],
  };

  /// Opens a sealed record. Throws [DecryptionFailure] if it was changed,
  /// moved to another record or sealed with another key.
  Map<String, dynamic> open(
    String collection,
    String id,
    String rev,
    Map<String, dynamic> envelope,
  ) {
    final bytes = _cipher.decrypt(
      base64Decode(envelope['c'] as String),
      context: _context(collection, id, rev),
    );
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  SyncChange sealChange(SyncChange c) {
    final data = c.data;
    if (data == null) return c;
    return SyncChange(
      collection: c.collection,
      id: c.id,
      rev: c.rev,
      deleted: c.deleted,
      data: seal(c.collection, c.id, c.rev, data),
      baseRev: c.baseRev,
      seq: c.seq,
    );
  }

  /// The plain version of a change from the hub. Hub-made conflict records
  /// (revision device "hub") are not sealed as a whole; the version they
  /// preserve ("otherData") is, and is opened here. Anything else that is not
  /// sealed is refused with [PlaintextRecordException].
  SyncChange openChange(SyncChange c) {
    final data = c.data;
    if (data == null) return c;
    Map<String, dynamic> plain;
    if (isEnvelope(data)) {
      plain = open(c.collection, c.id, c.rev, data);
    } else if (c.collection == 'conflicts' && deviceOfRev(c.rev) == 'hub') {
      plain = Map<String, dynamic>.of(data);
      final other = plain['otherData'];
      if (other is Map<String, dynamic> && isEnvelope(other)) {
        plain['otherData'] = open(
          '${plain['collection']}',
          '${plain['recordId']}',
          '${plain['otherRev']}',
          other,
        );
      }
    } else {
      throw PlaintextRecordException(c.key);
    }
    return SyncChange(
      collection: c.collection,
      id: c.id,
      rev: c.rev,
      deleted: c.deleted,
      data: plain,
      baseRev: c.baseRev,
      seq: c.seq,
    );
  }

  // ---------------------------------------------------------- attachments --

  static final _blobContext = utf8.encode('theapp-blob-v1');

  /// The sealed bytes of an attachment, and the id the hub stores them under
  /// (SHA-256 of the sealed bytes: the hub cannot tell what is inside, and
  /// the same file sealed twice has different ids).
  ({Uint8List bytes, String id}) sealBlob(Uint8List plain) {
    final sealed = _cipher.encrypt(plain, context: _blobContext);
    return (bytes: sealed, id: sha256.convert(sealed).toString());
  }

  Uint8List openBlob(Uint8List sealed) =>
      _cipher.decrypt(sealed, context: _blobContext);
}

// ------------------------------------------------------------------ pairing --

/// The code the user types on a new device. It carries 130 random bits that
/// the hub never sees: the hub only gets [registerCode] (a one-way function
/// of it) and a copy of the workspace key wrapped under [wrapKey] (another
/// one-way function). Without the code the hub cannot open the wrapped key,
/// and a hub that swaps in its own wrapped key fails the GCM check.
///
/// Format: 26 characters from an unambiguous alphabet, in groups of four,
/// optionally followed by `.` and 16 hex digits of the hub's TLS certificate
/// fingerprint (so a hub reached over HTTPS can be pinned without trusting
/// the first connection blindly).
class PairingSecret {
  PairingSecret._(this.secret, this.certPrefix);

  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// 26 characters, no separators.
  final String secret;

  /// First 16 hex digits of the hub certificate's SHA-256, or null.
  final String? certPrefix;

  factory PairingSecret.generate({String? certSha256}) {
    final bytes = FileCipher.randomBytes(26);
    final text = [for (final b in bytes) _alphabet[b % _alphabet.length]]
        .join();
    return PairingSecret._(text, certSha256?.substring(0, 16).toLowerCase());
  }

  /// Parses what the user typed (case, spaces and dashes do not matter).
  /// Null if it is not a pairing code of this kind.
  static PairingSecret? parse(String input) {
    final parts = input.trim().split('.');
    final text = parts.first.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (text.length != 26 || !text.split('').every(_alphabet.contains)) {
      return null;
    }
    String? prefix;
    if (parts.length == 2) {
      prefix = parts[1].toLowerCase().replaceAll(RegExp(r'[\s-]'), '');
      if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(prefix)) return null;
    } else if (parts.length > 2) {
      return null;
    }
    return PairingSecret._(text, prefix);
  }

  /// The same code with the hub certificate's fingerprint added (so the
  /// device that types it can pin that certificate).
  PairingSecret withCertificate(String certSha256) =>
      PairingSecret._(secret, certSha256.substring(0, 16).toLowerCase());

  /// What is shown to the user.
  String get display {
    final groups = [
      for (var i = 0; i < 26; i += 4)
        secret.substring(i, i + 4 > 26 ? 26 : i + 4),
    ].join('-');
    return certPrefix == null ? groups : '$groups.$certPrefix';
  }

  List<int> _derive(String label) =>
      Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(label)).bytes;

  /// What the hub is given as the one-time pairing code (64 hex digits).
  String get registerCode =>
      _derive('theapp-pairing-register-v1')
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

  FileCipher get _wrapCipher =>
      FileCipher(Uint8List.fromList(_derive('theapp-pairing-wrap-v1')));

  static final _wrapContext = utf8.encode('theapp-pairing-key-v1');

  /// The workspace key, wrapped for the new device.
  String wrap(Uint8List workspaceKey) =>
      base64Encode(_wrapCipher.encrypt(workspaceKey, context: _wrapContext));

  /// The workspace key from [wrapped], or null if the code is not the one it
  /// was wrapped with (or the hub changed it).
  Uint8List? unwrap(String wrapped) {
    try {
      final key = _wrapCipher.decrypt(
        base64Decode(wrapped),
        context: _wrapContext,
      );
      return key.length == FileCipher.keyLength ? key : null;
    } on DecryptionFailure {
      return null;
    } on FormatException {
      return null;
    }
  }
}

// ------------------------------------------------------------------- shares --

/// A share snapshot sealed for a link. The key travels only in the link's
/// `#fragment`, which browsers never send to the server, so the hub stores
/// and serves ciphertext it cannot read. Plain AES-256-GCM (12-byte nonce
/// first, tag last) so the recipient's browser can open it with WebCrypto.
class ShareSeal {
  ShareSeal._(this.key, this.ciphertext);

  /// base64url, no padding: goes in the link after `#k=`.
  final String key;

  /// base64url, no padding: stored with the share on the hub.
  final String ciphertext;

  static final _aad = utf8.encode('theapp-share-v1');

  factory ShareSeal.seal(String title, String body) {
    final key = FileCipher.randomBytes(32);
    final nonce = FileCipher.randomBytes(12);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key), 128, nonce, Uint8List.fromList(_aad)),
      );
    final sealed = gcm.process(
      Uint8List.fromList(utf8.encode(jsonEncode({'t': title, 'b': body}))),
    );
    return ShareSeal._(
      base64Url.encode(key).replaceAll('=', ''),
      base64Url.encode([...nonce, ...sealed]).replaceAll('=', ''),
    );
  }

  /// Opens a share like the recipient's browser does (used by tests and by
  /// the app to preview a link).
  static ({String title, String body})? open(String key, String ciphertext) {
    try {
      final k = base64Url.decode(base64Url.normalize(key));
      final data = base64Url.decode(base64Url.normalize(ciphertext));
      if (k.length != 32 || data.length < 12 + 16) return null;
      final gcm = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(Uint8List.fromList(k)),
            128,
            Uint8List.fromList(data.sublist(0, 12)),
            Uint8List.fromList(_aad),
          ),
        );
      final plain = jsonDecode(
        utf8.decode(gcm.process(Uint8List.fromList(data.sublist(12)))),
      ) as Map<String, dynamic>;
      return (title: '${plain['t']}', body: '${plain['b']}');
    } on InvalidCipherTextException {
      return null;
    } on FormatException {
      return null;
    }
  }
}
