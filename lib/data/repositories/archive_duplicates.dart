// Duplicate detection for the Archive (the object library).
//
// Detection is advisory: it only says "this looks like something you already
// saved". It never deletes, merges or overwrites anything; what happens next
// is decided by the caller (normally by asking the user).
//
// What counts as the same item:
// - links: the same normalized address ([ArchiveUrlKey]): http/https, "www.",
//   a trailing slash, the #fragment and tracking parameters (utm_*, fbclid…)
//   are ignored; every other query parameter is kept, so two different pages
//   of one site are never treated as the same;
// - files: the same SHA-256 of the content (any file name);
// - text: the same text, character for character.
// Weaker hint, reported as only "possible": a file with the same name and the
// same size when one of the two has no content hash yet.
// Titles alone never count: two different items can share a name.
import '../models/library_models.dart' show Asset;
import '../models/object_library_models.dart';

/// Why a new item looks like one already in the Archive.
enum DuplicateReason {
  /// The same web address (after normalization).
  sameLink,

  /// A file with exactly the same content.
  sameFile,

  /// Exactly the same text.
  sameText,

  /// Same file name and size, but no content hash to prove it. A hint only.
  sameNameAndSize,
}

/// What the user chose in the "Already in Archive" popup.
enum DuplicateChoice {
  /// Go to the item that is already saved; save nothing.
  openExisting,

  /// Save a separate copy anyway.
  saveAnyway,

  /// Save nothing.
  cancel,
}

/// An existing Archive item that a new save would repeat.
class ArchiveDuplicate {
  const ArchiveDuplicate(this.existing, this.reason, {this.saveCopy});

  final LibraryObject existing;
  final DuplicateReason reason;

  /// For a save that already reused [existing] (share imports): saves the
  /// new item as a separate copy after all ("Save anyway"). Null otherwise.
  final Future<void> Function()? saveCopy;

  /// True when the match is proven (same address, content or text); false
  /// for the name-and-size hint, which must never be acted on automatically.
  bool get certain => reason != DuplicateReason.sameNameAndSize;
}

/// The normalized form of a web address used only to compare addresses.
/// It is never stored and never opened.
class ArchiveUrlKey {
  ArchiveUrlKey._();

  /// Query parameters that only track where a click came from. Removing them
  /// never changes which page is shown.
  static const trackingParameters = {
    'fbclid',
    'gclid',
    'gclsrc',
    'dclid',
    'gbraid',
    'wbraid',
    'msclkid',
    'yclid',
    'twclid',
    'ttclid',
    'li_fat_id',
    'mc_cid',
    'mc_eid',
    'igshid',
    'igsh',
    '_ga',
    '_gl',
    '_hsenc',
    '_hsmi',
    '__hssc',
    '__hstc',
    '__hsfp',
    'hsctatracking',
    'mkt_tok',
    'oly_anon_id',
    'oly_enc_id',
    'vero_id',
    'vero_conv',
    'wickedid',
    'rb_clickid',
    's_cid',
    'ref_src',
    'ref_url',
  };

  /// Share-tracking parameters that are only safe to drop on these sites
  /// (elsewhere the same name can select content).
  static const _siteTracking = {
    'youtube.com': {'si', 'feature', 'pp'},
    'm.youtube.com': {'si', 'feature', 'pp'},
    'music.youtube.com': {'si', 'feature'},
    'youtu.be': {'si', 'feature'},
    'open.spotify.com': {'si', 'context'},
    'instagram.com': {'img_index', 'utm_source'},
    'x.com': {'s', 't'},
    'twitter.com': {'s', 't'},
  };

  static bool _isTracking(String host, String key) {
    final k = key.toLowerCase();
    if (k.startsWith('utm_')) return true;
    if (trackingParameters.contains(k)) return true;
    return _siteTracking[host]?.contains(k) ?? false;
  }

  /// The comparison key of [raw], or null when it is not a web address.
  static String? of(String? raw) {
    if (raw == null) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      return null;
    }
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    // Default ports are the same server; others are kept.
    final port =
        uri.hasPort &&
            !(uri.port == 80 && uri.isScheme('http')) &&
            !(uri.port == 443 && uri.isScheme('https'))
        ? ':${uri.port}'
        : '';
    // Paths are case sensitive on most servers: only the trailing slash goes.
    var path = uri.path;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.isEmpty) path = '/';
    // Kept in the original order of values; parameters sorted by name, so the
    // same parameters written in another order still match.
    final params = <MapEntry<String, String>>[];
    if (uri.hasQuery) {
      for (final part in uri.query.split('&')) {
        if (part.isEmpty) continue;
        final eq = part.indexOf('=');
        final key = _decode(eq < 0 ? part : part.substring(0, eq));
        final value = eq < 0 ? '' : _decode(part.substring(eq + 1));
        if (_isTracking(host, key)) continue;
        params.add(MapEntry(key, value));
      }
    }
    final sorted = [...params]
      ..sort((a, b) {
        final byKey = a.key.compareTo(b.key);
        return byKey != 0 ? byKey : params.indexOf(a) - params.indexOf(b);
      });
    final query = sorted.isEmpty
        ? ''
        : '?${sorted.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
    // A fragment normally only scrolls the same page. Single-page apps use
    // "#/route" or "#!/route" to pick content: those are kept.
    final fragment =
        uri.hasFragment &&
            (uri.fragment.startsWith('/') || uri.fragment.startsWith('!'))
        ? '#${uri.fragment}'
        : '';
    return '$host$port$path$query$fragment';
  }

  static String _decode(String s) {
    try {
      return Uri.decodeQueryComponent(s);
    } catch (_) {
      return s;
    }
  }
}

/// Finds an existing Archive item that a new save would repeat.
///
/// Only local records are used, so it works offline; records synced from
/// other devices are local records too. Address keys are cached per object
/// (invalidated when the object changes), so checking stays fast with
/// thousands of items.
class ArchiveDuplicateFinder {
  final _urlKeys = <String, (DateTime, String?)>{};

  String? _keyOf(LibraryObject o) {
    final cached = _urlKeys[o.id];
    if (cached != null && cached.$1 == o.updatedAt) return cached.$2;
    // The address as saved first (it may keep a #/route the stored canonical
    // form dropped), then the canonical form.
    final key =
        ArchiveUrlKey.of(o.sourceUrl) ?? ArchiveUrlKey.of(o.canonicalUrl);
    _urlKeys[o.id] = (o.updatedAt, key);
    return key;
  }

  /// The best match among [objects] (non-deleted Archive items) for a new
  /// item with [sourceUrl], text [contentHash] and the attachments
  /// [newAssets]; null when nothing matches. Proven matches win over the
  /// name-and-size hint; among equals the most recently saved item wins.
  ArchiveDuplicate? find({
    required Iterable<LibraryObject> objects,
    required Asset? Function(String id) assetOf,
    String? sourceUrl,
    String? contentHash,
    List<Asset> newAssets = const [],
    String? excludeId,
  }) {
    final urlKey = ArchiveUrlKey.of(sourceUrl);
    final hashes = {
      for (final a in newAssets)
        if (a.fileSha256 != null) a.fileSha256!,
    };
    // Name-and-size hints only for files that have no hash.
    final unhashed = [
      for (final a in newAssets)
        if (a.fileSha256 == null && a.fileSize != null && a.fileSize! > 0) a,
    ];
    ArchiveDuplicate? best;
    DateTime when(LibraryObject o) => o.lastSavedAt ?? o.updatedAt;
    void consider(LibraryObject o, DuplicateReason reason) {
      final candidate = ArchiveDuplicate(o, reason);
      final current = best;
      if (current == null ||
          (candidate.certain && !current.certain) ||
          (candidate.certain == current.certain &&
              when(o).isAfter(when(current.existing)))) {
        best = candidate;
      }
    }

    for (final o in objects) {
      if (o.deleted || o.id == excludeId) continue;
      if (urlKey != null && _keyOf(o) == urlKey) {
        consider(o, DuplicateReason.sameLink);
        continue;
      }
      if (contentHash != null && o.contentHash == contentHash) {
        consider(o, DuplicateReason.sameText);
        continue;
      }
      if (newAssets.isEmpty || o.attachmentIds.isEmpty) continue;
      var hinted = false;
      var proven = false;
      for (final id in o.attachmentIds) {
        final old = assetOf(id);
        if (old == null) continue;
        if (old.fileSha256 != null && hashes.contains(old.fileSha256)) {
          proven = true;
          break;
        }
        if (_sameNameAndSize(old, unhashed) ||
            (old.fileSha256 == null &&
                _sameNameAndSize(old, [
                  for (final a in newAssets)
                    if (a.fileSize != null && a.fileSize! > 0) a,
                ]))) {
          hinted = true;
        }
      }
      if (proven) {
        consider(o, DuplicateReason.sameFile);
      } else if (hinted) {
        consider(o, DuplicateReason.sameNameAndSize);
      }
    }
    return best;
  }

  static bool _sameNameAndSize(Asset old, List<Asset> candidates) {
    if (old.fileSize == null || old.fileSize == 0) return false;
    final name = old.label.trim().toLowerCase();
    return candidates.any(
      (a) =>
          a.kind == old.kind &&
          a.fileSize == old.fileSize &&
          a.label.trim().toLowerCase() == name,
    );
  }
}
