import 'record.dart';

/// A preserved losing version from a sync conflict (made by the hub when
/// two devices changed the same record). Nothing is lost: the other version
/// is kept here until the user restores or dismisses it.
class SyncConflict implements Record {
  const SyncConflict(this.data);

  final Map<String, dynamic> data;

  @override
  String get id => data['id'] as String;

  /// Kind of record, e.g. `notes` or `canvas_items`.
  String get collection => data['collection'] as String? ?? '';
  String get recordId => data['recordId'] as String? ?? '';

  /// `concurrent_edit`, `edited_after_delete` or
  /// `deleted_here_edited_elsewhere`.
  String get reason => data['reason'] as String? ?? '';
  bool get otherDeleted => data['otherDeleted'] as bool? ?? false;
  Map<String, dynamic>? get otherData =>
      data['otherData'] as Map<String, dynamic>?;

  /// The version the hub kept (the winner) and who made it.
  String? get keptRev => data['keptRev'] as String?;
  String? get keptDevice => data['keptDevice'] as String?;
  bool get keptDeleted => data['keptDeleted'] as bool? ?? false;

  /// The preserved version's revision and device.
  String? get otherRev => data['otherRev'] as String?;
  String? get otherDevice => data['otherDevice'] as String?;

  @override
  DateTime get updatedAt => parseDate(data['at']) ?? DateTime.now();

  /// How the user settled this conflict, or null while it is still open.
  /// Both versions stay inside the record after settling (`otherData`, and
  /// `replaced` when the other version was put in place), so a settling can
  /// be taken back until the record is pruned.
  Map<String, dynamic>? get resolution =>
      (data['resolved'] as Map?)?.cast<String, dynamic>();
  bool get isResolved => resolution != null;

  /// `kept_current` or `used_other`.
  String? get choice => resolution?['choice'] as String?;
  DateTime? get resolvedAt => parseDate(resolution?['at']);

  /// The version that was current before `used_other` replaced it.
  Map<String, dynamic>? get replacedData =>
      (resolution?['replaced'] as Map?)?.cast<String, dynamic>();
  bool get replacedWasDeleted => resolution?['replacedDeleted'] == true;

  /// This conflict, settled. [replaced] is the version that [choice]
  /// `used_other` put out of place (null if it did not exist).
  SyncConflict settled(
    String choice, {
    required DateTime at,
    Map<String, dynamic>? replaced,
    bool replacedDeleted = false,
  }) => SyncConflict({
    ...data,
    'resolved': {
      'choice': choice,
      'at': at.toUtc().toIso8601String(),
      'replaced': ?replaced,
      if (replacedDeleted) 'replacedDeleted': true,
    },
  });

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
