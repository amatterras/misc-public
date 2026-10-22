import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/library_models.dart';
import 'capture_service.dart';

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

  bool _busy = false;

  /// Turns pending request files into Inbox items.
  Future<int> processRequests(CaptureService capture) async {
    if (_busy || !await requestsDir.exists()) return 0;
    _busy = true;
    var count = 0;
    try {
      await for (final entity in requestsDir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final json = jsonDecode(await entity.readAsString()) as Map;
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
          switch (json['type']) {
            case 'file':
              final assets = [
                ...await capture.imagesFromFiles([value]),
                ...await capture.documentsFromFiles([value]),
              ];
              for (final a in assets) {
                ws.inbox.put(
                  InboxItem(id: newId(), assetId: a.id, createdAt: now),
                );
              }
              if (assets.isEmpty) {
                // Not an image: keep the path as text so nothing is lost.
                ws.inbox.put(
                  InboxItem(id: newId(), text: value, createdAt: now),
                );
              }
            case 'url':
              final asset = capture.link(extractUrl(value)!);
              ws.inbox.put(
                InboxItem(id: newId(), assetId: asset.id, createdAt: now),
              );
            default:
              ws.inbox.put(InboxItem(id: newId(), text: value, createdAt: now));
          }
          count++;
          // The request is only removed once its Inbox item is on disk, so a
          // crash in between can at worst import it twice, never lose it.
          await ws.flush();
          await entity.delete();
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
          debugPrint('Bad send-to request ${entity.path}: $e');
          await entity.rename('${entity.path}.failed');
        }
      }
    } finally {
      _busy = false;
    }
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

  static File get shortcutFile => File(
    '${Platform.environment['APPDATA']}\\Microsoft\\Windows\\SendTo\\THEapp.lnk',
  );

  static bool get isInstalled =>
      Platform.isWindows && shortcutFile.existsSync();

  /// Adds "THEapp" to Explorer's right-click "Send to" menu (a normal
  /// shortcut in your SendTo folder; remove it any time).
  static Future<bool> install() async {
    if (!Platform.isWindows) return false;
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");
    final lnk = shortcutFile.path.replaceAll("'", "''");
    final script =
        "\$s = (New-Object -ComObject WScript.Shell).CreateShortcut('$lnk'); "
        "\$s.TargetPath = '$exe'; \$s.Arguments = '--send-to'; "
        "\$s.Description = 'Send to THEapp Inbox'; \$s.Save()";
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
    return result.exitCode == 0 && shortcutFile.existsSync();
  }

  static Future<void> uninstall() async {
    if (shortcutFile.existsSync()) await shortcutFile.delete();
  }

  void dispose() {
    _heartbeat?.cancel();
    _poll?.cancel();
  }
}
