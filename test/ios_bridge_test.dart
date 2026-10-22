// The iPhone/iPad Dart side, against a SIMULATED native channel. This shows
// the app handles what the Swift code is meant to send; it does not prove the
// Swift code works (that needs a Mac and a device).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/capture_service.dart';
import 'package:flutter_application_1/platform/ios_bridge.dart';
import 'package:flutter_application_1/sync/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

class FakeKeychain implements KeychainBackend {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(IosBridge.channelName);

  late Directory dir;
  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall)> answers;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('theapp_ios_');
    calls = [];
    answers = {};
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answers[call.method]?.call(call);
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    secretKeychain = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Sends a call from the "native side" to Dart, as Swift would.
  Future<void> fromNative(String method, Object? args) async {
    await messenger.handlePlatformMessage(
      IosBridge.channelName,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  Future<AppState> start() async {
    final ws = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
      ios: IosBridge(),
    );
    state.capture.fetchPreviews = false;
    await state.init();
    return state;
  }

  test('tokens go to the Keychain; the file never holds them', () async {
    final keychain = FakeKeychain();
    secretKeychain = keychain;
    final file = File('${dir.path}${sep}sync${sep}hub.token');
    await writeSecret(file, 'secret-token-123');
    expect(file.readAsStringSync(), isNot(contains('secret-token-123')));
    expect(await readSecret(file), 'secret-token-123');
    await deleteSecret(file);
    expect(file.existsSync(), isFalse);
    expect(keychain.values, isEmpty);
  });

  test(
    'a Keychain failure is not hidden by writing the token in plain text',
    () async {
      final file = File('${dir.path}${sep}hub.token');
      await expectLater(
        IosBridge().write('k', 'v'), // native side answers null = failed
        throwsA(isA<PlatformException>()),
      );
      secretKeychain = IosBridge();
      await expectLater(writeSecret(file, 'v'), throwsA(anything));
      expect(file.existsSync(), isFalse);
    },
  );

  test('launch link, later links and shared items reach the Inbox', () async {
    final shared = Directory('${dir.path}${sep}group')..createSync();
    final requests = Directory('${shared.path}${sep}inbox_requests')
      ..createSync();
    // Exactly what ShareViewController.swift writes.
    File('${requests.path}${sep}a.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'type': 'url',
        'value': 'https://example.com/shared',
        'at': '2026-10-22T10:00:00Z',
        'source': 'ios_share_sheet',
      }),
    );
    answers['sharedContainer'] = (_) => shared.path;
    answers['initialLinks'] = (_) => [
      'theapp://capture?text=${Uri.encodeQueryComponent('launch note')}',
      'theapp://capture?text=second',
    ];

    final state = await start();
    final ws = state.workspace;
    expect(
      ws.inbox.all.map((i) => i.text),
      containsAll(['launch note', 'second']),
    );
    expect(
      ws.inbox.all.map((i) => ws.assets[i.assetId]?.url),
      contains('https://example.com/shared'),
    );
    expect(requests.listSync(), isEmpty);

    await fromNative(
      'openedUrl',
      'theapp://capture?url=${Uri.encodeQueryComponent('https://example.com/later')}',
    );
    await state.flush();
    expect(
      ws.inbox.all.map((i) => ws.assets[i.assetId]?.url),
      contains('https://example.com/later'),
    );

    // Something else opened with the theapp:// scheme changes nothing.
    final before = ws.inbox.all.length;
    await fromNative('openedUrl', 'theapp://settings?pair=evil');
    expect(ws.inbox.all.length, before);

    File('${requests.path}${sep}b.json').writeAsStringSync(
      jsonEncode({'type': 'text', 'value': 'while in background'}),
    );
    expect(await state.importSharedItems(), 1);
    expect(ws.inbox.all.map((i) => i.text), contains('while in background'));
    state.dispose();
  });

  test('shared photos are imported; only the shared copy is removed', () async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    final shared = Directory('${dir.path}${sep}group');
    final files = Directory('${shared.path}${sep}inbox_files')
      ..createSync(recursive: true);
    final requests = Directory('${shared.path}${sep}inbox_requests')
      ..createSync();
    final inside = File('${files.path}${sep}a.jpg')..writeAsBytesSync(png);
    final outside = File('${dir.path}${sep}mine.png')
      ..writeAsBytesSync([...png, 1]);
    void request(String name, String path) =>
        File('${requests.path}$sep$name.json').writeAsStringSync(
          jsonEncode({'type': 'file', 'value': path, 'temporary': true}),
        );
    request('a', inside.path);
    request('b', outside.path);
    request('c', '${files.path}$sep..$sep..${sep}mine.png');
    answers['sharedContainer'] = (_) => shared.path;

    final state = await start();
    final ws = state.workspace;
    final images = ws.inbox.all
        .map((i) => ws.assets[i.assetId])
        .where((a) => a?.kind == AssetKind.image);
    expect(images, hasLength(3));
    expect(inside.existsSync(), isFalse, reason: 'shared copy cleaned up');
    expect(outside.existsSync(), isTrue, reason: 'never delete outside files');
    expect(requests.listSync(), isEmpty);
    state.dispose();
  });

  test('without App Groups (free account) nothing breaks', () async {
    answers['sharedContainer'] = (_) => null;
    final state = await start();
    expect(await state.importSharedItems(), 0);
    state.dispose();
  });

  test(
    'photo picker results are imported; only web links are opened',
    () async {
      final photo = File('${dir.path}${sep}picked.jpg')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
          ),
        );
      answers['pickImages'] = (_) => [photo.path];
      final ws = Workspace(dir);
      await ws.load();
      final bridge = IosBridge();
      final capture = CaptureService(ws, fetchPreviews: false)
        ..pickImageFiles = bridge.pickImageFiles;
      final assets = await capture.pickImages();
      expect(assets, hasLength(1));
      expect(assets.single.kind, AssetKind.image);
      expect(ws.assets[assets.single.id], isNotNull);

      expect(bridge.openUrl('https://example.com'), isTrue);
      expect(bridge.openUrl('javascript:alert(1)'), isFalse);
      expect(bridge.openUrl('file:///etc/passwd'), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((c) => c.method == 'openUrl').map((c) => c.arguments),
        ['https://example.com'],
      );
      expect(ws.inbox.all, isEmpty);
      ws.dispose();
    },
  );

  test(
    'PDFs: picker results are imported; only PDFs are passed to preview',
    () async {
      final pdf = File('${dir.path}${sep}Picked.pdf')
        ..writeAsStringSync('%PDF-1.4\n% synthetic\n');
      answers['pickDocuments'] = (_) => [pdf.path];
      final ws = Workspace(dir);
      await ws.load();
      final bridge = IosBridge();
      final capture = CaptureService(ws, fetchPreviews: false)
        ..pickDocumentFiles = bridge.pickDocumentFiles;
      final docs = await capture.pickDocuments();
      expect(docs.single.kind, AssetKind.document);
      expect(docs.single.label, 'Picked.pdf');

      expect(bridge.openDocument('/x/report.exe'), isFalse);
      expect(bridge.openDocument(ws.documentFile(docs.single)!.path), isTrue);
      await Future<void>.delayed(Duration.zero);
      final previews = calls.where((c) => c.method == 'openDocument');
      expect(previews.map((c) => c.arguments), [
        ws.documentFile(docs.single)!.path,
      ]);
      ws.dispose();
    },
  );

  test('no native side (other platforms): calls fail softly', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final bridge = IosBridge();
    expect(await bridge.sharedContainerPath(), isNull);
    expect(await bridge.pickImageFiles(), isEmpty);
    expect(await bridge.pickDocumentFiles(), isEmpty);
    expect(await bridge.read('k'), isNull);
  });

  test('inbox items stay plain records (no iOS-only fields)', () {
    final item = InboxItem(id: 'i', createdAt: DateTime.utc(2026), text: 't');
    expect(item.toJson().keys, containsAll(['id', 'text', 'assetId']));
  });
}
