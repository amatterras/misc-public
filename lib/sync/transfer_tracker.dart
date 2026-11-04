// What the attachment transfers are doing, in plain terms, so the app can
// show real progress and never call a file "synced" before it is.
//
// A transfer is "done" only after the hub (upload) or this device (download)
// has the complete file and its SHA-256 matched. Anything else is waiting,
// active, retrying (an interrupted transfer that will continue from where it
// stopped) or failed (with the reason).
import 'package:flutter/foundation.dart';

enum TransferStage { waiting, active, retrying, verifying, done, failed }

class TransferInfo {
  const TransferInfo({
    required this.id,
    required this.upload,
    required this.stage,
    this.bytes = 0,
    this.total = 0,
    this.error,
  });

  /// The attachment's id on the hub (SHA-256 of what is sent).
  final String id;
  final bool upload;
  final TransferStage stage;
  final int bytes;
  final int total;
  final String? error;

  double get fraction => total <= 0 ? 0 : (bytes / total).clamp(0, 1);
  bool get finished =>
      stage == TransferStage.done || stage == TransferStage.failed;
}

class TransferTracker extends ChangeNotifier {
  final Map<String, TransferInfo> _all = {};

  /// Finished entries kept for the list (the newest few).
  static const keepFinished = 20;

  List<TransferInfo> get all => List.unmodifiable(_all.values);
  List<TransferInfo> get unfinished => [
    for (final t in _all.values)
      if (!t.finished) t,
  ];

  TransferInfo? operator [](String id) => _all[id];

  void update(
    String id, {
    required bool upload,
    required TransferStage stage,
    int? bytes,
    int? total,
    String? error,
  }) {
    final old = _all[id];
    _all[id] = TransferInfo(
      id: id,
      upload: upload,
      stage: stage,
      bytes: stage == TransferStage.done
          ? (total ?? old?.total ?? 0)
          : bytes ?? old?.bytes ?? 0,
      total: total ?? old?.total ?? 0,
      error: error,
    );
    final finished = _all.values.where((t) => t.finished).toList();
    if (finished.length > keepFinished) {
      for (final t in finished.take(finished.length - keepFinished)) {
        _all.remove(t.id);
      }
    }
    notifyListeners();
  }
}
