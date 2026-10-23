// iPhone/iPad services that Flutter has no built-in API for, without
// plugins (which need Windows Developer Mode to build here) and without any
// paid service. The Swift side is in ios/Runner/AppDelegate.swift and
// SceneDelegate.swift, on the method channel "theapp/ios".
//
// STATUS: the Dart side is tested on Windows with a simulated channel. The
// Swift side has NOT been compiled or run (no Mac available). See
// ios/README_IOS.md.
import 'dart:async';

import 'package:flutter/services.dart';

import '../sync/secret_store.dart';

/// A task reminder to show at [at] (local time).
class ScheduledReminder {
  const ScheduledReminder(this.id, this.title, this.at);
  final String id;
  final String title;
  final DateTime at;
}

class IosBridge implements KeychainBackend {
  IosBridge([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'theapp/ios';

  /// The one used by the app on iOS.
  static final IosBridge instance = IosBridge();

  final MethodChannel _channel;

  /// Starts receiving links opened from outside the app, e.g.
  /// `theapp://capture?url=...` from an iOS Shortcut. Also delivers links
  /// that arrived before Flutter was ready (including the launch link); the
  /// native side holds them until this asks for them.
  Future<void> listenForLinks(FutureOr<void> Function(Uri) onLink) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openedUrl' && call.arguments is String) {
        final uri = Uri.tryParse(call.arguments as String);
        if (uri != null) await onLink(uri);
      }
      return null;
    });
    final waiting = await _invoke<List<Object?>>('initialLinks') ?? const [];
    for (final link in waiting.whereType<String>()) {
      final uri = Uri.tryParse(link);
      if (uri != null) await onLink(uri);
    }
  }

  /// Folder the Share Extension writes requests into (the App Group
  /// container), or null when App Groups are not available — they need the
  /// paid Apple Developer Program.
  Future<String?> sharedContainerPath() => _invoke<String>('sharedContainer');

  /// "iPad" or "iPhone" (iOS no longer gives apps the device's own name).
  Future<String?> deviceModel() => _invoke<String>('deviceModel');

  /// Replaces THEapp's pending reminder notifications with [reminders]
  /// (local notifications; no server, no paid account). iOS asks the user
  /// for permission the first time there is something to schedule. Returns
  /// false if notifications are not allowed or not available.
  Future<bool> scheduleReminders(List<ScheduledReminder> reminders) async {
    try {
      return await _invoke<bool>(
            'scheduleReminders',
            [
              for (final r in reminders)
                {
                  'id': r.id,
                  'title': r.title,
                  'at': r.at.millisecondsSinceEpoch,
                },
            ],
            true, // iOS may ask the user for permission first
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Shows the system photo picker; returns copies of the chosen photos as
  /// JPEG files in the app's temporary folder (empty if cancelled).
  Future<List<String>> pickImageFiles() async {
    try {
      return await _channel.invokeListMethod<String>('pickImages') ?? const [];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Shows the system document picker for PDFs; returns copies of the
  /// chosen files in the app's temporary folder (empty if cancelled).
  Future<List<String>> pickDocumentFiles() async {
    try {
      return await _channel.invokeListMethod<String>('pickDocuments') ??
          const [];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Shows a stored PDF with the system previewer (Quick Look). Only paths
  /// ending in `.pdf` are passed on; the caller gives files from THEapp's
  /// attachments folder (`Workspace.documentFile`).
  bool openDocument(String path) {
    if (!path.toLowerCase().endsWith('.pdf')) return false;
    unawaited(_invoke<bool>('openDocument', path, true));
    return true;
  }

  /// Opens an http(s) or mailto link in Safari / Mail. Returns false for any
  /// other kind of link (a stored link can never start something else).
  bool openUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.isScheme('http') ||
            uri.isScheme('https') ||
            uri.isScheme('mailto'))) {
      return false;
    }
    unawaited(_invoke<bool>('openUrl', uri.toString(), true));
    return true;
  }

  @override
  Future<String?> read(String key) => _invoke<String>('keychainRead', key);

  @override
  Future<void> write(String key, String value) async {
    final ok = await _invoke<bool>('keychainWrite', {
      'key': key,
      'value': value,
    });
    if (ok != true) {
      throw PlatformException(
        code: 'keychain',
        message: 'Could not save to the Keychain',
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    await _invoke<bool>('keychainDelete', key);
  }

  /// Longest wait for a native call that should answer at once (Keychain,
  /// links, device model). A call that never answers then fails with a
  /// [TimeoutException] instead of blocking, e.g. app start-up, forever.
  static Duration callTimeout = const Duration(seconds: 5);

  /// [waitsForUser]: the call shows something the user answers (permission
  /// prompt, Safari), so it gets no time limit.
  Future<T?> _invoke<T>(
    String method, [
    Object? arguments,
    bool waitsForUser = false,
  ]) async {
    try {
      final call = _channel.invokeMethod<T>(method, arguments);
      if (waitsForUser) return await call;
      return await call.timeout(
        callTimeout,
        onTimeout: () => throw TimeoutException(
          'No answer from iOS for "$method"',
          callTimeout,
        ),
      );
    } on MissingPluginException {
      return null; // Native side not present (e.g. tests, other platforms).
    }
  }
}
