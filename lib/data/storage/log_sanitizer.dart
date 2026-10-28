// What may be written to a log. Logs are plain text files that are not
// encrypted and that people attach to bug reports, so they must never hold
// note text, task content, private links, file contents, AI prompts or
// replies, pairing or recovery codes, authorization headers, tokens, keys or
// vault text. The log call sites already avoid these on purpose; this is the
// safety net at the one place everything passes through (AppLog and the hub's
// log), so a message or exception that carries something by accident is
// cleaned before it is written. Pure Dart (the hub uses it too).
import 'dart:io';

/// [text] with anything that looks like a secret or a private link removed.
String sanitizeLog(String text) {
  var out = text;
  // Headers, bearer tokens, keys.
  out = out.replaceAll(
    RegExp(r'^\s*authorization\s*:.*$', caseSensitive: false, multiLine: true),
    'Authorization: •••',
  );
  out = out.replaceAll(
    RegExp(r'Bearer\s+\S+', caseSensitive: false),
    'Bearer •••',
  );
  out = out.replaceAll(RegExp(r'\bsk-[A-Za-z0-9_\-]{8,}'), 'sk-•••');
  out = out.replaceAll(RegExp(r'\bAIza[0-9A-Za-z_\-]{20,}'), 'AIza•••');
  out = out.replaceAll(RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}'), 'gh•••');
  out = out.replaceAll(RegExp(r'\bxox[abprs]-[A-Za-z0-9-]{10,}'), 'xox•••');
  out = out.replaceAll(RegExp(r'\bAKIA[0-9A-Z]{16}'), 'AKIA•••');
  out = out.replaceAll(
    RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}'),
    'eyJ•••',
  );
  // Private links: only the scheme and host stay.
  out = out.replaceAllMapped(
    RegExp(
      r'''\b(https?)://([^\s/?#'")<>\]]+)[^\s'")<>\]]*''',
      caseSensitive: false,
    ),
    (m) {
      final host = m.group(2)!;
      final at = host.lastIndexOf('@'); // never a user name or password
      return '${m.group(1)}://${at < 0 ? host : host.substring(at + 1)}/…';
    },
  );
  // Fragments that carry keys, and key=value secrets.
  out = out.replaceAll(RegExp(r'#k=[A-Za-z0-9_\-]+'), '#k=•••');
  out = out.replaceAllMapped(
    RegExp(
      r'\b(password|passwd|passphrase|secret|api[_ -]?key|token|pin)\b(\s*[:=]\s*)\S+',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}${m.group(2)}•••',
  );
  // Pairing codes (26 characters, grouped), recovery codes (5×5), 64-digit
  // hex (a one-way pairing value, a hash), and any long token-like word.
  out = out.replaceAll(
    RegExp(r'\b[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){5}-[A-HJ-NP-Z2-9]{2}\b'),
    '••••-pairing',
  );
  out = out.replaceAll(
    RegExp(r'\b[A-Z0-9]{5}(-[A-Z0-9]{5}){4}\b'),
    '•••••-recovery',
  );
  out = out.replaceAll(RegExp(r'\b[0-9a-fA-F]{40,}\b'), '•••hex');
  out = out.replaceAll(RegExp(r'[A-Za-z0-9_\-+/=]{40,}'), '•••token');
  // E-mail addresses.
  out = out.replaceAllMapped(
    RegExp(r'[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})'),
    (m) => '•••@${m.group(1)}',
  );
  return out;
}

/// A safe description of an error for a log: its type, and only details that
/// cannot hold content (an OS error code, a position). The message of most
/// exceptions (a bad JSON file's message quotes the text around the problem)
/// is NOT included.
String describeError(Object? error) {
  if (error == null) return '';
  if (error is FormatException) {
    return 'FormatException${error.offset == null ? '' : ' at offset ${error.offset}'}';
  }
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    return 'FileSystemException${code == null ? '' : ' (os error $code)'}: '
        '${sanitizeLog(error.message)}';
  }
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    return 'SocketException${code == null ? '' : ' (os error $code)'}';
  }
  // Sync and hub failures carry a stable code and a message that is written
  // never to contain user content.
  final type = error.runtimeType.toString();
  if (type == 'SyncFailure' || type == 'ProtocolException') {
    return sanitizeLog(error.toString());
  }
  return type;
}

/// A short, cleaned message for an error that is shown to the user and may
/// be logged: the message of the app's own failures (which are written not to
/// hold content) with secrets and links removed, but never the message of an
/// exception that quotes the text it failed on.
String plainError(Object? error) {
  if (error == null) return '';
  if (error is FormatException || error is SocketException) {
    return describeError(error);
  }
  final text = sanitizeLog('$error');
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

/// "https://host" for a link in a log or message; nothing of the rest.
String hostOnly(String? url) {
  if (url == null) return '(none)';
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return '(link)';
  return '${uri.scheme}://${uri.host}';
}
