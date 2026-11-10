import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/models/canvas_models.dart' show newId;
import '../../data/storage/app_log.dart';
import '../../data/models/library_models.dart';
import '../../data/repositories/archive_duplicates.dart';
import 'capture_service.dart';
import '../links/link_tags.dart';

/// Windows "Send to → THEapp" support.
///
/// Explorer starts the app with the chosen files as arguments. That launch
/// drops a small request file into `<data>\inbox_requests`; if THEapp is
/// already running (it writes a heartbeat file every few seconds) the new
/// launch exits at once and the running app picks the request up. Captured
/// items appear in the Inbox, where you choose where they go.
///
/// This is the Windows equivalent of a share target. iPhone/iPad Share
/// sheet support needs a native iOS Share Extension (built on a Mac) that
/// would write into the same inbox once sync exists.
class SendToBridge {
  SendToBridge(this.root);

  final Directory root;
  Timer? _heartbeat;
  Timer? _poll;

  String get _sep => Platform.pathSeparator;
  Directory get requestsDir => Directory('${root.path}${_sep}inbox_requests');
  File get _heartbeatFile => File('${root.path}${_sep}instance.json');

  static const _fresh = Duration(seconds: 12);

  /// Writes requests for [args]. Returns true if another running instance
  /// will handle them (so this process should exit).
  Future<bool> forward(List<String> args) async {
    final items = [
      for (final a in args)
        if (a.trim().isNotEmpty && !a.startsWith('--')) a,
    ];
    if (items.isEmpty) return false;
    await requestsDir.create(recursive: true);
    for (final item in items) {
      final isFile = await File(item).exists();
      final request = {
        'type': isFile ? 'file' : (extractUrl(item) != null ? 'url' : 'text'),
        'value': item,
        'at': DateTime.now().toIso8601String(),
      };
      final file = File('${requestsDir.path}$_sep${newId()}.json');
      await file.writeAsString(jsonEncode(request), flush: true);
    }
    return isAnotherInstanceRunning();
  }

  Future<bool> isAnotherInstanceRunning() async {
    try {
      if (!await _heartbeatFile.exists()) return false;
      final json = jsonDecode(await _heartbeatFile.readAsString()) as Map;
      if (json['pid'] == pid) return false;
      final at = DateTime.parse(json['at'] as String);
      if (DateTime.now().difference(at) >= _fresh) return false;
      // A recent heartbeat can be left behind by a crash: make sure that
      // process really still exists.
      return processExists(json['pid'] as int);
    } catch (_) {
      return false;
    }
  }

  /// Asks the running window to come to the front (used when THEapp is
  /// started a second time).
  Future<void> requestFocus() async {
    await requestsDir.create(recursive: true);
    final file = File('${requestsDir.path}$_sep${newId()}.json');
    await file.writeAsString(jsonEncode({'type': 'focus'}), flush: true);
  }

  /// Whether a process with [processId] is running (Windows only; elsewhere
  /// assumes yes).
  static bool processExists(int processId) {
    if (!Platform.isWindows) return true;
    try {
      final result = Process.runSync('tasklist', [
        '/FI',
        'PID eq $processId',
        '/NH',
        '/FO',
        'CSV',
      ]);
      return result.stdout.toString().contains('"$processId"');
    } catch (_) {
      return true;
    }
  }

  /// Called when another launch asked this window to come forward.
  VoidCallback? onFocusRequested;

  /// Shared items that were already in the Archive (the existing item was
  /// reused, nothing was saved twice), until taken with [takeReused].
  final _reused = <ArchiveDuplicate>[];

  /// Called after [processRequests] when some shared items were already in
  /// the Archive (the app then asks the user). Without it they wait for
  /// [takeReused].
  void Function(List<ArchiveDuplicate> reused)? onReused;

  /// The items reused since the last call (see [_reused]).
  List<ArchiveDuplicate> takeReused() {
    final out = List<ArchiveDuplicate>.of(_reused);
    _reused.clear();
    return out;
  }

  /// Handles an inbound deep link URL (e.g. theapp://capture?url=... or theapp://share?text=...).
  /// Works across platforms without extra plugins. On iPhone/iPad the links
  /// arrive through `IosBridge.listenForLinks` (not yet run on a device).
  Future<List<InboxItem>> handleUri(Uri uri, CaptureService capture) async {
    if (uri.scheme != 'theapp') return const [];
    final host = uri.host.toLowerCase();
    if (host == 'capture' || host == 'share' || uri.path.contains('capture')) {
      final url = uri.queryParameters['url'];
      final text = uri.queryParameters['text'] ?? uri.queryParameters['body'];
      final title = uri.queryParameters['title'];
      return capture.captureInbound(url: url, text: text, title: title);
    }
    return const [];
  }

  /// Like [handleUri], but saves into the Archive (the object library) when
  /// there is one. Returns how many items were saved.
  Future<int> handleUriToArchive(Uri uri, CaptureService capture) async {
    if (capture.libraryRepository == null) {
      return (await handleUri(uri, capture)).length;
    }
    if (uri.scheme != 'theapp') return 0;
    final host = uri.host.toLowerCase();
    if (host == 'capture' || host == 'share' || uri.path.contains('capture')) {
      return capture.captureToArchive(
        url: uri.queryParameters['url'],
        text: uri.queryParameters['text'] ?? uri.queryParameters['body'],
        title: uri.queryParameters['title'],
        reused: _reused,
      );
    }
    return 0;
  }

  /// Starts the heartbeat and polls for requests from other launches.
  void start(CaptureService capture) {
    Future<void> beat() async {
      try {
        await _heartbeatFile.writeAsString(
          jsonEncode({'pid': pid, 'at': DateTime.now().toIso8601String()}),
        );
      } catch (_) {}
    }

    unawaited(beat());
    _heartbeat = Timer.periodic(const Duration(seconds: 4), (_) => beat());
    unawaited(processRequests(capture));
    _poll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => processRequests(capture),
    );
  }

  /// Imports of one request started without finishing before it is set
  /// aside (see [processRequests]).
  static const maxAttempts = 2;

  static Future<int> _attemptsSoFar(File attempts) async {
    try {
      if (!await attempts.exists()) return 0;
      // Unreadable counts as used up: it was written by an interrupted try.
      return int.tryParse((await attempts.readAsString()).trim()) ??
          maxAttempts;
    } on FileSystemException {
      return 0;
    }
  }

  /// " (12.3 MB)" for a shared file, so a slow import is explained by the
  /// log. Never the file's name or content.
  static Future<String> _sizeNote(Map json) async {
    if (json['type'] != 'file' || json['value'] is! String) return '';
    try {
      final bytes = await File(json['value'] as String).length();
      return ' (${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB)';
    } on FileSystemException {
      return ' (file missing)';
    }
  }

  bool _busy = false;
  int failedCount = 0;
  String? lastFailure;

  /// Turns pending request files into Archive objects (Inbox items when there
  /// is no library, as in tests).
  Future<int> processRequests(CaptureService capture) async {
    if (_busy || !await requestsDir.exists()) return 0;
    _busy = true;
    failedCount = 0;
    lastFailure = null;
    var count = 0;
    try {
      await for (final entity in requestsDir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        // A request whose import was started [maxAttempts] times without
        // finishing (the app was closed, stopped or ran out of memory
        // during it) is set aside, kept as `.failed` for recovery, instead
        // of being retried at every launch.
        final attempts = File('${entity.path}.attempts');
        final tries = await _attemptsSoFar(attempts);
        if (tries >= maxAttempts) {
          failedCount++;
          lastFailure =
              'A shared item did not finish importing after $tries tries, '
              'so it was set aside (kept, not deleted).';
          AppLog.warn('Share inbox: $lastFailure');
          try {
            await entity.rename('${entity.path}.failed');
            await attempts.delete();
          } on FileSystemException catch (e) {
            AppLog.warn('Share inbox: could not set a request aside: $e');
          }
          continue;
        }
        final watch = Stopwatch()..start();
        var kind = 'unknown';
        try {
          await attempts.writeAsString('${tries + 1}', flush: true);
          final json = jsonDecode(await entity.readAsString()) as Map;
          kind = '${json['type']}';
          AppLog.info(
            'Share inbox: importing a $kind request'
            '${await _sizeNote(json)} (try ${tries + 1})',
          );
          if (json['type'] == 'focus') {
            onFocusRequested?.call();
            await entity.delete();
            continue;
          }
          var value = json['value'] as String;
          // Same limit as links from outside (a shared web page can be huge).
          if (json['type'] != 'file' &&
              value.length > CaptureService.maxInboundText) {
            value = value.substring(0, CaptureService.maxInboundText);
          }
          final ws = capture.workspace;
          final now = DateTime.now();
          // Ids come from the request file, so processing the same request
          // again (after a crash before it was removed) replaces its items
          // instead of adding duplicates.
          final requestId = entity.uri.pathSegments.last.replaceAll(
            RegExp(r'.json$'),
            '',
          );
          var part = 0;
          String itemId() => 'req-$requestId-${part++}';
          if (capture.libraryRepository != null) {
            // The Archive keeps one object per link, file or text (repeats
            // of the same request reuse it), so a retried request adds no
            // duplicate.
            final category = json['tagId'];
            final categories =
                category is String && LinkTag.byId(category) != null
                ? {category}
                : <String>{};
            final title = json['title'] is String
                ? json['title'] as String
                : null;
            final metadata = <String, Object?>{
              if (json['filename'] is String) 'filename': json['filename'],
              if (json['typeIdentifier'] is String)
                'typeIdentifier': json['typeIdentifier'],
              if (json['source'] is String) 'source': json['source'],
              // Lets a retried request (after a crash) be told apart from
              // the user sharing the same thing again.
              'shareRequest': requestId,
            };
            final reused = <ArchiveDuplicate>[];
            final saved = switch (json['type']) {
              'file' => await capture.captureToArchive(
                files: [value],
                categories: categories,
                title: title,
                metadata: metadata,
                reused: reused,
              ),
              'url' => await capture.captureToArchive(
                url: (json['url'] as String?) ?? value,
                categories: categories,
                title: title,
                metadata: metadata,
                reused: reused,
              ),
              _ => await capture.captureToArchive(
                text: value,
                categories: categories,
                title: title,
                metadata: metadata,
                reused: reused,
              ),
            };
            _reused.addAll(
              reused.where(
                (d) => d.existing.metadata['shareRequest'] != requestId,
              ),
            );
            if (saved == 0 && json['type'] == 'file') {
              throw const FormatException(
                'Unsupported or invalid shared file; staged original kept for recovery.',
              );
            }
          } else {
            switch (json['type']) {
              case 'file':
                final assets = [
                  ...await capture.imagesFromFiles([value]),
                  ...await capture.documentsFromFiles([value]),
                ];
                for (final a in assets) {
                  ws.inbox.put(
                    InboxItem(id: itemId(), assetId: a.id, createdAt: now),
                  );
                }
                if (assets.isEmpty) {
                  if (json['temporary'] == true) {
                    throw const FormatException(
                      'Unsupported or invalid shared file; staged original kept for recovery.',
                    );
                  }
                  // Not an image: keep the path as text so nothing is lost.
                  ws.inbox.put(
                    InboxItem(id: itemId(), text: value, createdAt: now),
                  );
                }
              case 'url':
                final asset = capture.link(extractUrl(value)!);
                ws.inbox.put(
                  InboxItem(id: itemId(), assetId: asset.id, createdAt: now),
                );
              default:
                ws.inbox.put(
                  InboxItem(id: itemId(), text: value, createdAt: now),
                );
            }
          }
          count++;
          // The request is only removed once its Inbox item is on disk, so a
          // crash in between never loses it (and, with the ids above, never
          // imports it twice).
          await ws.flush();
          await entity.delete();
          AppLog.info(
            'Share inbox: $kind request imported in '
            '${watch.elapsedMilliseconds} ms',
          );
          // A photo the iOS Share Extension copied into the shared folder
          // has been copied into the app now. Never touches files outside
          // that folder (Windows "Send to" passes the user's own files).
          final copy = File(value);
          if (json['type'] == 'file' &&
              json['temporary'] == true &&
              _isInside(root, copy) &&
              await copy.exists()) {
            await copy.delete();
          }
        } catch (e) {
          failedCount++;
          lastFailure = e is FormatException
              ? e.message
              : 'A shared item could not be read or stored.';
          AppLog.warn(
            'Share inbox: a $kind request failed after '
            '${watch.elapsedMilliseconds} ms: $lastFailure ($e)',
          );
          await entity.rename('${entity.path}.failed');
        } finally {
          try {
            if (await attempts.exists()) await attempts.delete();
          } on FileSystemException {
            // Harmless: at worst counted as one more try next time.
          }
        }
      }
    } finally {
      _busy = false;
    }
    final callback = onReused;
    if (callback != null && _reused.isNotEmpty) callback(takeReused());
    return count;
  }

  /// Whether [file] lies inside [dir] (after resolving `..`).
  static bool _isInside(Directory dir, File file) {
    var base = dir.absolute.uri.normalizePath().toFilePath();
    var target = file.absolute.uri.normalizePath().toFilePath();
    if (Platform.isWindows) {
      base = base.toLowerCase();
      target = target.toLowerCase();
    }
    return target.startsWith(base) && target.length > base.length;
  }

  // ------------------------------------------------- Send To menu entry --

  static String get _sendToFolder =>
      '${Platform.environment['APPDATA']}\\Microsoft\\Windows\\SendTo';

  /// The menu entry's file: its name is what Explorer shows ("misc.").
  static File get shortcutFile => File('$_sendToFolder\\misc..lnk');

  /// The entry made by builds before the rename ("THEapp"): still recognised
  /// and removed, so an existing install is not left with two entries.
  static File get _legacyShortcutFile => File('$_sendToFolder\\THEapp.lnk');

  static bool get isInstalled =>
      Platform.isWindows &&
      (shortcutFile.existsSync() || _legacyShortcutFile.existsSync());

  /// Adds "misc." to Explorer's right-click "Send to" menu (a normal
  /// shortcut in your SendTo folder; remove it any time).
  static Future<bool> install() async {
    if (!Platform.isWindows) return false;
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");
    final lnk = shortcutFile.path.replaceAll("'", "''");
    final script =
        "\$s = (New-Object -ComObject WScript.Shell).CreateShortcut('$lnk'); "
        "\$s.TargetPath = '$exe'; \$s.Arguments = '--send-to'; "
        "\$s.Description = 'Send to misc.'; \$s.Save()";
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
    final ok = result.exitCode == 0 && shortcutFile.existsSync();
    if (ok && _legacyShortcutFile.existsSync()) {
      await _legacyShortcutFile.delete();
    }
    return ok;
  }

  static Future<void> uninstall() async {
    if (shortcutFile.existsSync()) await shortcutFile.delete();
    if (_legacyShortcutFile.existsSync()) await _legacyShortcutFile.delete();
  }

  void dispose() {
    _heartbeat?.cancel();
    _poll?.cancel();
  }
}
