// What must never go through the shared clipboard. Syncing the clipboard is
// off by default and, when the user turns it on, still never carries what
// looks like a secret: a password, a key, a token, a recovery or pairing
// code, or text from the open private vault. This errs on the side of not
// syncing: a false alarm only means one copied text stays on this device.
import 'dart:math';

/// Why [text] must not be synced, or null when it may be.
String? clipboardBlockReason(
  String text, {
  bool Function(String text)? vaultCheck,
}) {
  final t = text.trim();
  if (t.isEmpty) return null;
  if (vaultCheck != null && vaultCheck(t)) return 'private vault text';

  if (RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----').hasMatch(t)) {
    return 'a private key';
  }
  if (RegExp(
        r'\bBearer\s+[A-Za-z0-9._~+/=-]{8,}',
        caseSensitive: false,
      ).hasMatch(t) ||
      RegExp(
        r'^\s*authorization\s*:',
        caseSensitive: false,
        multiLine: true,
      ).hasMatch(t)) {
    return 'an authorization header';
  }
  if (RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}')
      .hasMatch(t)) {
    return 'a token';
  }
  if (RegExp(
    r'\b(sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|'
    r'xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})',
  ).hasMatch(t)) {
    return 'an API key';
  }
  if (RegExp(
    r'\b(password|passwd|passphrase|secret|api[_ -]?key|token|pin)\b\s*[:=]\s*\S{4,}',
    caseSensitive: false,
  ).hasMatch(t)) {
    return 'a password or key';
  }
  // Share links carry their key after the #; pairing and recovery codes.
  if (RegExp(r'#k=[A-Za-z0-9_-]{20,}').hasMatch(t)) return 'a share key';
  final compact = t.replaceAll(RegExp(r'[\s-]'), '');
  if (RegExp(r'^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$').hasMatch(t)) {
    return 'a recovery code';
  }
  if (RegExp(r'^[A-HJ-NP-Z2-9]{26}(\.[0-9a-f]{16})?$').hasMatch(compact)) {
    return 'a pairing code';
  }
  if (RegExp(r'^[0-9a-fA-F]{32,}$').hasMatch(compact) && !t.contains(' ')) {
    return 'a key';
  }

  // One word with no spaces that looks random: probably a password.
  final isUrl = RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(t);
  if (isUrl) {
    return RegExp(
          r'[?&#](token|key|password|secret|code|sig|signature|auth|session|apikey)=',
          caseSensitive: false,
        ).hasMatch(t)
        ? 'a link with a secret in it'
        : null;
  }
  if (!t.contains(RegExp(r'\s')) && t.length >= 8 && t.length <= 256) {
    final classes = [
      RegExp(r'[a-z]'),
      RegExp(r'[A-Z]'),
      RegExp(r'[0-9]'),
      RegExp(r'[^A-Za-z0-9]'),
    ].where((r) => r.hasMatch(t)).length;
    if (classes >= 3 && _entropyPerChar(t) > 3.0) return 'a password';
    if (t.length >= 32 &&
        RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(t) &&
        _entropyPerChar(t) > 4.0) {
      return 'a key';
    }
  }
  return null;
}

double _entropyPerChar(String s) {
  final counts = <int, int>{};
  for (final c in s.runes) {
    counts[c] = (counts[c] ?? 0) + 1;
  }
  var h = 0.0;
  for (final n in counts.values) {
    final p = n / s.runes.length;
    h -= p * (log(p) / ln2);
  }
  return h;
}
