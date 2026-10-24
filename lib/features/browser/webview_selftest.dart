// A check of the Windows browser engine that can run without anyone at the
// screen: `--data-dir=<test folder> --webview-selftest=local` (test data
// mode only) serves a small page on 127.0.0.1, loads it in a real WebView2
// view, reads its title and text back, writes the result to the log and
// quits (exit code 0 = it worked). `--webview-selftest=<https url>` loads
// that page instead.
import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';

import '../../data/storage/app_log.dart';
import 'browser_engine.dart';

Future<void> runWebViewSelfTest(String target) async {
  HttpServer? server;
  var url = target;
  if (target == 'local') {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      r.response
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><title>THEapp WebView2 check</title>'
          '<p id="t">Hello from the embedded browser.</p>',
        );
      r.response.close();
    });
    url = 'http://127.0.0.1:${server.port}/';
  }
  final engine = WindowsWebViewEngine(private: false);
  final finished = Completer<EngineState>();
  engine.state.addListener(() {
    final s = engine.state.value;
    AppLog.info(
      'WebView check: loading=${s.loading} title="${s.title}" '
      'error=${s.error ?? '-'}',
    );
    if (!finished.isCompleted &&
        ((!s.loading && s.title.isNotEmpty) || s.error != null)) {
      finished.complete(s);
    }
  });
  engine.place(const Rect.fromLTWH(0, 60, 900, 520), 1, visible: true);
  await engine.load(url);
  var ok = false;
  try {
    final s = await finished.future.timeout(const Duration(seconds: 45));
    final text = await engine.pageText();
    ok = s.error == null && s.title.isNotEmpty && text.isNotEmpty;
    AppLog.info(
      'WebView check ${ok ? 'PASSED' : 'FAILED'}: title="${s.title}", '
      'page text ${text.length} chars, back=${s.canGoBack}',
    );
  } on TimeoutException {
    AppLog.info('WebView check FAILED: no answer from WebView2 in 45 s');
  }
  engine.dispose();
  await server?.close(force: true);
  // Let the log reach the disk.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  exit(ok ? 0 : 1);
}
