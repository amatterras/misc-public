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

  @override
  DateTime get updatedAt => parseDate(data['at']) ?? DateTime.now();

  @override
  Map<String, dynamic> toJson() => data;

  factory SyncConflict.fromJson(Map<String, dynamic> j) {
    if (j['id'] is! String) throw const FormatException('conflict without id');
    return SyncConflict(j);
  }
}
