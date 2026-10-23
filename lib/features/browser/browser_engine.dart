// The browser engine behind a small interface, so the rest of THEapp does
// not depend on the platform:
//   - iPhone/iPad: Apple's WebKit (WKWebView) as a native view, through the
//     "theapp/webview" view type registered in AppDelegate.swift.
//   - Windows: no engine is built in yet (Microsoft WebView2 needs either a
//     Flutter plugin, which needs Windows Developer Mode, or the WebView2
//     SDK). [BrowserEngine.create] returns null there and the page says so.
// The Windows engine is not Safari's engine and is never called that.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What the page in one tab is doing.
class EngineState {
  const EngineState({
    this.url = '',
    this.title = '',
    this.loading = false,
    this.progress = 0,
    this.canGoBack = false,
    this.canGoForward = false,
    this.error,
  });

  final String url;
  final String title;
  final bool loading;
  final double progress;
  final bool canGoBack;
  final bool canGoForward;

  /// A navigation or certificate error to show instead of the page.
  final String? error;

  EngineState copyWith({
    String? url,
    String? title,
    bool? loading,
    double? progress,
    bool? canGoBack,
    bool? canGoForward,
    String? Function()? error,
  }) => EngineState(
    url: url ?? this.url,
    title: title ?? this.title,
    loading: loading ?? this.loading,
    progress: progress ?? this.progress,
    canGoBack: canGoBack ?? this.canGoBack,
    canGoForward: canGoForward ?? this.canGoForward,
    error: error != null ? error() : this.error,
  );
}

/// Things the engine asks the app to decide or record.
sealed class EngineEvent {
  const EngineEvent();
}

/// A page asked for a new window (target=_blank, window.open).
class NewWindowRequested extends EngineEvent {
  const NewWindowRequested(this.url);
  final String url;
}

/// A link with a scheme the browser does not open itself (mailto:, tel:…).
class ExternalLinkRequested extends EngineEvent {
  const ExternalLinkRequested(this.url);
  final String url;
}

/// A download started, progressed, finished or failed.
class DownloadEvent extends EngineEvent {
  const DownloadEvent({
    required this.id,
    required this.url,
    required this.fileName,
    this.progress = 0,
    this.done = false,
    this.path,
    this.error,
  });
  final String id;
  final String url;
  final String fileName;
  final double progress;
  final bool done;
  final String? path;
  final String? error;
}

/// A site asks for camera, microphone or location.
class PermissionRequested extends EngineEvent {
  const PermissionRequested(this.host, this.kind, this.respond);
  final String host;
  final String kind;
  final void Function(bool allow) respond;
}

/// One tab's engine.
abstract class BrowserEngine {
  /// The engine for this platform, or null when none is available here.
  static BrowserEngine? create({required bool private}) {
    if (debugCreate != null) return debugCreate!(private);
    if (Platform.isIOS) return WebKitEngine(private: private);
    return null;
  }

  /// Whether pages can be shown inside THEapp here.
  static bool get available => debugCreate != null || Platform.isIOS;

  /// Replaces [create] in tests.
  @visibleForTesting
  static BrowserEngine? Function(bool private)? debugCreate;

  /// Why no engine runs on this platform (shown on the browser page).
  static String get unavailableReason => Platform.isWindows
      ? 'The Windows browser engine (Microsoft WebView2) is not built into '
            'this version yet. It needs Windows Developer Mode turned on '
            '(Settings → System → For developers) so THEapp can include the '
            'WebView2 component. Bookmarks, history and sending pages to '
            'THEapp work already; pages can be opened in your default browser.'
      : 'No browser engine is available on this platform.';

  final ValueNotifier<EngineState> state = ValueNotifier(const EngineState());
  final StreamController<EngineEvent> _events = StreamController.broadcast();
  Stream<EngineEvent> get events => _events.stream;

  @protected
  void emit(EngineEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  bool get private;

  /// The engine's on-screen view.
  Widget view();

  Future<void> load(String url);
  Future<void> back();
  Future<void> forward();
  Future<void> reload();
  Future<void> stop();

  /// Shows the engine's find-in-page bar (or searches for [text]).
  Future<void> find([String text = '']);
  Future<void> setZoom(double factor);

  /// The text the user selected on the page ('' if none).
  Future<String> selectedText();

  /// The page's visible text (only when the user asks to capture it).
  Future<String> pageText();

  /// Removes cookies, cache and site storage of this engine's data store.
  Future<void> clearData();

  @mustCallSuper
  void dispose() {
    _events.close();
    state.dispose();
  }
}

/// WKWebView through the "theapp/webview" native view (AppDelegate.swift).
class WebKitEngine extends BrowserEngine {
  WebKitEngine({required this.private});

  @override
  final bool private;
  MethodChannel? _channel;
  String? _pendingUrl;

  @override
  Widget view() => UiKitView(
    viewType: 'theapp/webview',
    creationParams: {'private': private},
    creationParamsCodec: const StandardMessageCodec(),
    onPlatformViewCreated: _created,
  );

  void _created(int id) {
    final c = _channel = MethodChannel('theapp/webview/$id');
    c.setMethodCallHandler(_handle);
    final url = _pendingUrl;
    if (url != null) unawaited(c.invokeMethod('load', url));
  }

  Future<Object?> _handle(MethodCall call) async {
    final a = call.arguments;
    switch (call.method) {
      case 'state' when a is Map:
        state.value = EngineState(
          url: a['url'] as String? ?? state.value.url,
          title: a['title'] as String? ?? state.value.title,
          loading: a['loading'] == true,
          progress: (a['progress'] as num?)?.toDouble() ?? 0,
          canGoBack: a['canGoBack'] == true,
          canGoForward: a['canGoForward'] == true,
          error: a['error'] as String?,
        );
      case 'newWindow' when a is String:
        emit(NewWindowRequested(a));
      case 'external' when a is String:
        emit(ExternalLinkRequested(a));
      case 'download' when a is Map:
        emit(
          DownloadEvent(
            id: a['id'] as String? ?? '',
            url: a['url'] as String? ?? '',
            fileName: a['fileName'] as String? ?? 'download',
            progress: (a['progress'] as num?)?.toDouble() ?? 0,
            done: a['done'] == true,
            path: a['path'] as String?,
            error: a['error'] as String?,
          ),
        );
      case 'permission' when a is Map:
        final done = Completer<bool>();
        emit(
          PermissionRequested(
            a['host'] as String? ?? '',
            a['kind'] as String? ?? '',
            done.complete,
          ),
        );
        return done.future;
    }
    return null;
  }

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel?.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> load(String url) async {
    if (_channel == null) {
      _pendingUrl = url;
      state.value = state.value.copyWith(url: url);
      return;
    }
    await _call<void>('load', url);
  }

  @override
  Future<void> back() => _call<void>('back');
  @override
  Future<void> forward() => _call<void>('forward');
  @override
  Future<void> reload() => _call<void>('reload');
  @override
  Future<void> stop() => _call<void>('stop');
  @override
  Future<void> find([String text = '']) => _call<void>('find', text);
  @override
  Future<void> setZoom(double factor) => _call<void>('zoom', factor);
  @override
  Future<String> selectedText() async =>
      await _call<String>('evaluate', 'window.getSelection().toString()') ?? '';
  @override
  Future<String> pageText() async =>
      await _call<String>('evaluate', 'document.body.innerText') ?? '';
  @override
  Future<void> clearData() => _call<void>('clearData');
}
