// The THEapp sync protocol (version 1), shared by the hub and the clients.
// Pure Dart: no Flutter imports, so the hub can run as a plain Dart program.
// See SYNC_ARCHITECTURE.md for the full description.

/// Bumped whenever the wire format changes incompatibly. Hub and client
/// refuse to talk across different versions.
const syncProtocolVersion = 1;

/// Header every data request must carry.
const protocolHeader = 'x-theapp-protocol';

const maxPushBatch = 200;
const maxPullLimit = 500;
const defaultPullLimit = 200;

/// Largest JSON request body the hub accepts.
const maxJsonBodyBytes = 8 * 1024 * 1024;

/// Largest single record payload.
const maxRecordBytes = 1024 * 1024;

/// Largest attachment file.
const maxAttachmentBytes = 100 * 1024 * 1024;

/// Kinds of records that sync. Anything else is rejected.
const syncedCollections = {
  'assets',
  'notes',
  'folders',
  'inbox',
  'calendar_entries',
  'calendar_entry_expirations',
  'calendar_days',
  'tasks',
  'projects',
  'canvases', // canvas title, folder and item order
  'canvas_items', // id = "<canvasId>/<itemId>"
  'conflicts', // preserved losing versions of concurrent edits
  'clipboard', // shared clipboard text (only while the user turns it on)
  'archive_folders', // Archive folder tree
  'shares', // read-only share links (id = SHA-256 of the token)
  'thought_experiments',
  'vault_meta', // private vault key record (wrapped key only)
  'vault_items', // private vault items (ciphertext only)
  'templates', // the user's own note and project templates
  'external_events', // Google / Outlook events (read-only mirrors)
  'calendar_links', // THEapp entries exported to Google / Outlook
  'custom_tags', // the user's own Archive / Mindmap tags (name, colour)
};

/// Kinds an older hub may not know yet; they are pushed last, on their own.
const newerCollections = {
  'clipboard',
  'archive_folders',
  'shares',
  'thought_experiments',
  'vault_meta',
  'vault_items',
  'templates',
  'external_events',
  'calendar_links',
  'custom_tags',
};

/// `0001792610475963-0000-a1b2c3d4`: see SyncClock.
final revPattern = RegExp(r'^\d{16}-\d{4}-[a-z0-9]{1,32}$');
final idPattern = RegExp(r'^[A-Za-z0-9._-]{1,120}(/[A-Za-z0-9._-]{1,120})?$');
final sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final deviceIdPattern = RegExp(r'^[a-z0-9]{1,32}$');

/// The device part of a revision stamp.
String? deviceOfRev(String rev) {
  final i = rev.indexOf('-', 17);
  return i < 0 ? null : rev.substring(i + 1);
}

class ProtocolException implements Exception {
  const ProtocolException(this.code, this.message, {this.status = 400});

  /// Stable machine-readable code (see SYNC_ARCHITECTURE.md §10).
  final String code;

  /// Human-readable, never contains user content.
  final String message;
  final int status;

  Map<String, dynamic> toJson() => {'error': code, 'message': message};

  @override
  String toString() => '$code: $message';
}

/// One version of one record, as sent over the wire.
class SyncChange {
  const SyncChange({
    required this.collection,
    required this.id,
    required this.rev,
    required this.deleted,
    this.data,
    this.baseRev,
    this.seq,
  });

  final String collection;
  final String id;

  /// Revision stamp of this version (unique; its device part names the
  /// device that made it).
  final String rev;
  final bool deleted;

  /// The record's JSON (null when [deleted]).
  final Map<String, dynamic>? data;

  /// Push only: the hub revision this change was based on (null if the
  /// device never received this record from the hub).
  final String? baseRev;

  /// Pull only: hub sequence number of this version.
  final int? seq;

  String get key => '$collection/$id';

  Map<String, dynamic> toJson() => {
    'collection': collection,
    'id': id,
    'rev': rev,
    'deleted': deleted,
    if (data != null) 'data': data,
    if (baseRev != null) 'baseRev': baseRev,
    if (seq != null) 'seq': seq,
  };

  factory SyncChange.fromJson(Map<String, dynamic> j) {
    final collection = j['collection'];
    final id = j['id'];
    final rev = j['rev'];
    final deleted = j['deleted'];
    final data = j['data'];
    final baseRev = j['baseRev'];
    if (collection is! String || !syncedCollections.contains(collection)) {
      throw const ProtocolException(
        'bad_change',
        'Unknown or missing collection.',
      );
    }
    if (id is! String || !idPattern.hasMatch(id)) {
      throw const ProtocolException('bad_change', 'Invalid record id.');
    }
    if (rev is! String || !revPattern.hasMatch(rev)) {
      throw const ProtocolException('bad_change', 'Invalid revision.');
    }
    if (deleted is! bool) {
      throw const ProtocolException('bad_change', 'Missing deleted flag.');
    }
    if (!deleted && data is! Map<String, dynamic>) {
      throw const ProtocolException('bad_change', 'Missing record data.');
    }
    if (baseRev != null &&
        (baseRev is! String || !revPattern.hasMatch(baseRev))) {
      throw const ProtocolException('bad_change', 'Invalid base revision.');
    }
    return SyncChange(
      collection: collection,
      id: id,
      rev: rev,
      deleted: deleted,
      data: deleted ? null : data as Map<String, dynamic>,
      baseRev: baseRev as String?,
      seq: j['seq'] as int?,
    );
  }
}

/// What the hub did with one pushed change.
enum PushStatus {
  /// Stored as the current version.
  applied,

  /// Already received earlier (a retry); nothing changed.
  duplicate,

  /// The hub kept its own version (e.g. a newer concurrent edit). The
  /// device must adopt [PushResult.current]; its version is preserved as a
  /// conflict record when it was a real edit.
  keptServer,
}

class PushResult {
  const PushResult({
    required this.collection,
    required this.id,
    required this.rev,
    required this.status,
    this.current,
    this.conflictId,
  });

  final String collection;
  final String id;
  final String rev;
  final PushStatus status;

  /// The hub's current version, when the device must adopt it.
  final SyncChange? current;

  /// Id of the conflict record created, if any.
  final String? conflictId;

  Map<String, dynamic> toJson() => {
    'collection': collection,
    'id': id,
    'rev': rev,
    'status': status.name,
    if (current != null) 'current': current!.toJson(),
    if (conflictId != null) 'conflictId': conflictId,
  };

  factory PushResult.fromJson(Map<String, dynamic> j) => PushResult(
    collection: j['collection'] as String,
    id: j['id'] as String,
    rev: j['rev'] as String,
    status: PushStatus.values.byName(j['status'] as String),
    current: j['current'] == null
        ? null
        : SyncChange.fromJson(j['current'] as Map<String, dynamic>),
    conflictId: j['conflictId'] as String?,
  );
}
