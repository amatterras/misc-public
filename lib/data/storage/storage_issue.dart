// What kind of storage problem a failed save is, so the app can say it in
// plain words ("storage is full") instead of a generic error, and so the
// notice can tell the user what to do. Classification only: every kind is
// retried the same way (nothing is ever dropped), and an unknown error is
// treated as temporary.
import 'dart:io';

enum StorageIssue {
  /// The device (or the drive holding the data folder) has no free space.
  full,

  /// The data folder is gone or its drive is not there (for example an
  /// unplugged USB drive or a removed network folder).
  locationLost,

  /// The system refuses writing (read-only, no permission).
  denied,

  /// Anything else (a file locked by another program, a short glitch).
  temporary,
}

/// The kind of problem behind a failed write.
StorageIssue classifyStorageError(Object error) {
  OSError? os;
  var message = '';
  if (error is FileSystemException) {
    os = error.osError;
    message = '${error.message} ${os?.message ?? ''}';
  } else if (error is OSError) {
    os = error;
    message = error.message;
  } else {
    message = '$error';
  }
  final code = os?.errorCode;
  final text = message.toLowerCase();
  if (Platform.isWindows) {
    // ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL.
    if (code == 112 || code == 39) return StorageIssue.full;
    // ERROR_PATH_NOT_FOUND, ERROR_NOT_READY, ERROR_DEV_NOT_EXIST,
    // ERROR_BAD_NETPATH, ERROR_NETNAME_DELETED.
    if (code == 3 || code == 21 || code == 55 || code == 53 || code == 64) {
      return StorageIssue.locationLost;
    }
    // ERROR_ACCESS_DENIED, ERROR_WRITE_PROTECT.
    if (code == 5 || code == 19) return StorageIssue.denied;
  } else {
    // ENOSPC, EDQUOT (Linux 122, Apple 69).
    if (code == 28 || code == 122 || (code == 69 && !Platform.isLinux)) {
      return StorageIssue.full;
    }
    // ENOENT (the folder vanished), ENODEV, ENXIO.
    if (code == 2 || code == 19 || code == 6) return StorageIssue.locationLost;
    // EACCES, EPERM, EROFS.
    if (code == 13 || code == 1 || code == 30) return StorageIssue.denied;
  }
  if (text.contains('no space left') ||
      text.contains('not enough space') ||
      text.contains('disk is full') ||
      text.contains('disk full')) {
    return StorageIssue.full;
  }
  return StorageIssue.temporary;
}

/// The most serious of [issues] (what the notice talks about first).
StorageIssue? worstIssue(Iterable<StorageIssue> issues) {
  StorageIssue? worst;
  for (final i in issues) {
    if (worst == null || _rank(i) > _rank(worst)) worst = i;
  }
  return worst;
}

int _rank(StorageIssue i) => switch (i) {
  StorageIssue.temporary => 0,
  StorageIssue.denied => 1,
  StorageIssue.full => 2,
  StorageIssue.locationLost => 3,
};

/// The notice for unsaved changes, in plain words: what happened, whether
/// the data is safe, and what (if anything) to do. Never claims success.
String unsavedNoticeText(StorageIssue? issue) => switch (issue) {
  StorageIssue.full =>
    'Storage is full, so your latest changes are not saved to disk yet. '
        'Everything saved earlier is safe. Free up some space and keep the '
        'app open — it saves them by itself.',
  StorageIssue.locationLost =>
    'The folder where your data is kept cannot be reached, so your latest '
        'changes are not saved to disk yet. Keep the app open; they are saved '
        'as soon as the folder is back.',
  StorageIssue.denied =>
    'This device does not allow saving right now, so your latest changes '
        'are not saved to disk yet. Everything saved earlier is safe. Keep the '
        'app open; it keeps trying.',
  StorageIssue.temporary || null =>
    'Some changes are not saved yet. misc. keeps retrying — keep the app '
        'open (details in the log).',
};
