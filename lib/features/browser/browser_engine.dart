// The browser engine behind a small interface, so the rest of THEapp does
// not depend on the platform:
//   - iPhone/iPad: Apple's WebKit (WKWebView) as a native view, through the
//     "theapp/webview" view type registered in AppDelegate.swift.
//   - Windows: Microsoft Edge WebView2, hosted by the runner itself
//     (windows/runner/webview_host.cpp; no Flutter plugin, so Windows
//     Developer Mode is not needed). It needs the WebView2 Runtime, which
//     Windows 10/11 and Edge install; without it the page shows an error.
// The Windows engine is not Safari's engine and is never called that.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app/floating_windows.dart' show floatingWindowRects;

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
    if (_windowsRunner) return WindowsWebViewEngine(private: private);
    return null;
  }

  /// The Windows app (widget tests also run on Windows, without the native
  /// runner, so they get no engine).
  static bool get _windowsRunner =>
      Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

  /// Whether pages can be shown inside THEapp here.
  static bool get available =>
      debugCreate != null || Platform.isIOS || _windowsRunner;

  /// Replaces [create] in tests.
  @visibleForTesting
  static BrowserEngine? Function(bool private)? debugCreate;

  /// Why no engine runs on this platform (shown on the browser page).
  static String get unavailableReason =>
      'No browser engine is available here. Bookmarks, history and sending '
      'pages to misc. still work; pages can be opened in your default '
      'browser.';

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

/// Microsoft Edge WebView2 views hosted by the Windows runner
/// (windows/runner/webview_host.cpp, channel "theapp/webview_win"). The
/// native view sits over the Flutter page at the place [view] reports; it
/// hides while a menu or dialog is open, while its page is not shown, and
/// while a floating window covers it (native views always draw on top).
class WindowsWebViewEngine extends BrowserEngine {
  WindowsWebViewEngine({required this.private}) : id = _nextId++ {
    _engines[id] = this;
    _ensureHandler();
    unawaited(_call<void>('create', {'private': private}));
  }

  static int _nextId = 1;
  static final Map<int, WindowsWebViewEngine> _engines = {};
  static const _channel = MethodChannel('theapp/webview_win');
  static bool _handlerSet = false;

  final int id;
  @override
  final bool private;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      final a = call.arguments;
      if (a is! Map) return null;
      final e = _engines[a['id']];
      return e?._handle(call.method, a);
    });
  }

  Future<Object?> _handle(String method, Map a) async {
    switch (method) {
      case 'state':
        state.value = EngineState(
          url: a['url'] as String? ?? state.value.url,
          title: a['title'] as String? ?? state.value.title,
          loading: a['loading'] == true,
          progress: (a['progress'] as num?)?.toDouble() ?? 0,
          canGoBack: a['canGoBack'] == true,
          canGoForward: a['canGoForward'] == true,
          error: a['error'] as String?,
        );
      case 'newWindow':
        emit(NewWindowRequested(a['url'] as String? ?? ''));
      case 'external':
        emit(ExternalLinkRequested(a['url'] as String? ?? ''));
      case 'download':
        emit(
          DownloadEvent(
            id: a['downloadId'] as String? ?? '',
            url: a['url'] as String? ?? '',
            fileName: a['fileName'] as String? ?? 'download',
            progress: (a['progress'] as num?)?.toDouble() ?? 0,
            done: a['done'] == true,
            path: a['path'] as String?,
            error: a['error'] as String?,
          ),
        );
      case 'permission':
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

  Future<T?> _call<T>(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, {'id': id, ...args});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Where the native view goes (logical pixels in the window) and whether
  /// it shows.
  void place(Rect rect, double scale, {required bool visible}) => unawaited(
    _call<void>('bounds', {
      'x': rect.left,
      'y': rect.top,
      'w': rect.width,
      'h': rect.height,
      'scale': scale,
      'visible': visible,
    }),
  );

  @override
  Widget view() => _WindowsWebView(engine: this);

  @override
  Future<void> load(String url) async {
    state.value = state.value.copyWith(url: url);
    await _call<void>('load', {'url': url});
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
  Future<void> find([String text = '']) async {
    if (text.isEmpty) return;
    await _evaluate('window.find(${jsonEncode(text)})');
  }

  @override
  Future<void> setZoom(double factor) =>
      _call<void>('zoom', {'factor': factor});

  Future<String> _evaluate(String script) async {
    final json = await _call<String>('evaluate', {'script': script});
    try {
      final v = json == null ? '' : jsonDecode(json);
      return v is String ? v : '';
    } on FormatException {
      return '';
    }
  }

  @override
  Future<String> selectedText() =>
      _evaluate('window.getSelection().toString()');
  @override
  Future<String> pageText() => _evaluate('document.body.innerText');
  @override
  Future<void> clearData() => _call<void>('clearData');

  @override
  void dispose() {
    unawaited(_call<void>('dispose'));
    _engines.remove(id);
    super.dispose();
  }
}

class _WindowsWebView extends StatefulWidget {
  const _WindowsWebView({required this.engine});
  final WindowsWebViewEngine engine;

  @override
  State<_WindowsWebView> createState() => _WindowsWebViewState();
}

class _WindowsWebViewState extends State<_WindowsWebView> {
  Rect? _sent;
  bool? _sentVisible;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    floatingWindowRects.addListener(_schedule);
    _schedule();
  }

  @override
  void dispose() {
    floatingWindowRects.removeListener(_schedule);
    widget.engine.place(Rect.zero, 1, visible: false);
    super.dispose();
  }

  /// Measures after each frame while it is mounted (no frames are forced;
  /// the native side hears only about changes).
  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      _measure();
      _schedule();
    });
  }

  void _measure() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final shown =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        !floatingWindowRects.value.values.any(
          // A window that contains this view is the one it lives in.
          (w) => w.overlaps(rect) && !_contains(w, rect),
        );
    if (rect == _sent && shown == _sentVisible) return;
    _sent = rect;
    _sentVisible = shown;
    widget.engine.place(
      rect,
      MediaQuery.devicePixelRatioOf(context),
      visible: shown && rect.width > 1 && rect.height > 1,
    );
  }

  static bool _contains(Rect outer, Rect inner) =>
      outer.inflate(1).contains(inner.topLeft) &&
      outer.inflate(1).contains(inner.bottomRight);

  // The native view draws here; this only keeps the space.
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
