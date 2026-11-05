import 'record.dart';

/// A preserved losing version from a sync conflict (made by the hub when
/// two devices changed the same record). Nothing is lost: the other version
/// is kept here until the user restores or dismisses it.
class SyncConflict implements Record {
  const SyncConflict(this.data);

  final Map<String, dynamic> data;

  // Every getter tolerates a record of an unexpected shape (written by a
  // newer app, damaged, or malformed): the conflict is then still listed and
  // its content kept, never a crash.
  String _str(String key) {
    final v = data[key];
    return v is String ? v : '';
  }

  String? _strOrNull(String key) {
    final v = data[key];
    return v is String ? v : null;
  }

  @override
  String get id => data['id'] as String;

  /// Kind of record, e.g. `notes` or `canvas_items`.
  String get collection => _str('collection');
  String get recordId => _str('recordId');

  /// `concurrent_edit`, `edited_after_delete` or
  /// `deleted_here_edited_elsewhere`.
  String get reason => _str('reason');
  bool get otherDeleted => data['otherDeleted'] == true;
  Map<String, dynamic>? get otherData {
    final v = data['otherData'];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  /// The version the hub kept (the winner) and who made it.
  String? get keptRev => _strOrNull('keptRev');
  String? get keptDevice => _strOrNull('keptDevice');
  bool get keptDeleted => data['keptDeleted'] == true;

  /// The preserved version's revision and device.
  String? get otherRev => _strOrNull('otherRev');
  String? get otherDevice => _strOrNull('otherDevice');

  @override
  DateTime get updatedAt => parseDate(data['at']) ?? DateTime.now();

  /// How the user settled this conflict, or null while it is still open.
  /// Both versions stay inside the record after settling (`otherData`, and
  /// `replaced` when the other version was put in place), so a settling can
  /// be taken back until the record is pruned.
  Map<String, dynamic>? get resolution {
    final v = data['resolved'];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  bool get isResolved => resolution != null;

  /// `kept_current` or `used_other`.
  String? get choice => resolution?['choice'] as String?;
  DateTime? get resolvedAt => parseDate(resolution?['at']);

  /// A settling that was started but not finished (the app was interrupted
  /// between recording the intent and putting the version in place, or
  /// between taking it back and re-opening the conflict).
  bool get isApplying => resolution?['applying'] == true;
  bool get isUndoing => resolution?['undoing'] == true;

  /// The version that was current before `used_other` replaced it.
  Map<String, dynamic>? get replacedData {
    final v = resolution?['replaced'];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  bool get replacedWasDeleted => resolution?['replacedDeleted'] == true;

  /// This conflict, settled. [replaced] is the version that [choice]
  /// `used_other` puts out of place (null if it did not exist). [applying]
  /// marks the intent as recorded but not yet carried out.
  SyncConflict settled(
    String choice, {
    required DateTime at,
    Map<String, dynamic>? replaced,
    bool replacedDeleted = false,
    bool applying = false,
  }) => SyncConflict({
    ...data,
    'resolved': {
      'choice': choice,
      'at': at.toUtc().toIso8601String(),
      'replaced': ?replaced,
      if (replacedDeleted) 'replacedDeleted': true,
      if (applying) 'applying': true,
    },
  });

  /// The same settled conflict with its "in progress" marks changed.
  SyncConflict withProgress({bool applying = false, bool undoing = false}) {
    final r = {...?resolution}
      ..remove('applying')
      ..remove('undoing');
    if (applying) r['applying'] = true;
    if (undoing) r['undoing'] = true;
    return SyncConflict({...data, 'resolved': r});
  }

  /// This conflict, open again (a settling that was taken back).
  SyncConflict reopened() => SyncConflict({...data}..remove('resolved'));

  @override
  Map<String, dynamic> toJson() => data;

  factory SyncConflict.fromJson(Map<String, dynamic> j) {
    if (j['id'] is! String) throw const FormatException('conflict without id');
    return SyncConflict(j);
  }
}

/// "This record was deleted for good." Unlike an ordinary deletion (which can
/// be undone from "recently deleted", and which an old copy can still bring
/// back), a purge is permanent and travels to every device and to the hub: a
/// device or backup that still holds the record cannot restore it. The id is
/// `<collection>.<record id>`, which is all the hub sees of it.
class PurgeMark implements Record {
  const PurgeMark({
    required this.collection,
    required this.recordId,
    required this.at,
    this.blobs = const [],
  });

  final String collection;
  final String recordId;
  final DateTime at;

  /// Ids of the sealed attachment copies on the hub that belonged only to the
  /// purged record (asked to be removed from the hub once).
  final List<String> blobs;

  @override
  String get id => '$collection.$recordId';

  @override
  DateTime get updatedAt => at;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'collection': collection,
    'recordId': recordId,
    'at': at.toUtc().toIso8601String(),
    if (blobs.isNotEmpty) 'blobs': blobs,
  };

  factory PurgeMark.fromJson(Map<String, dynamic> j) {
    final collection = j['collection'], recordId = j['recordId'];
    if (collection is! String || recordId is! String) {
      throw const FormatException('purge mark without a record');
    }
    return PurgeMark(
      collection: collection,
      recordId: recordId,
      at: parseDate(j['at']) ?? DateTime.now(),
      blobs: [
        for (final b in (j['blobs'] as List? ?? const []))
          if (b is String) b,
      ],
    );
  }
}
