// Security that asks nothing of the user: link previews never reach private
// networks, imported files must be what they say, the status page never
// shows a false "Protected", notifications are rare, and the app opens with
// no lock or login. Temporary folders and local test servers only.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/attention_gate.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/import_guard.dart';
import 'package:flutter_application_1/data/storage/storage_encryption.dart';
import 'package:flutter_application_1/data/storage/url_guard.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/link_preview.dart';
import 'package:flutter_application_1/features/settings/security_status.dart';
import 'package:flutter_application_1/features/settings/settings_dialog.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/sync/storage_modes.dart';
import 'package:flutter_application_1/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/both_clocks.dart';

InternetAddress _ip(String s) => InternetAddress(s);

SecurityFacts _facts({
  EncryptionStatus encryption = EncryptionStatus.enabled,
  String? dataProblem,
  StorageMode mode = StorageMode.pcHub,
  bool syncEnabled = true,
  bool needsPairing = false,
  SyncConnection connection = SyncConnection.live,
  bool pending = false,
  DateTime? lastSynced,
  bool backupEnabled = true,
  bool backupRunning = false,
  DateTime? lastBackup,
  bool? intact,
  String? failure,
}) => SecurityFacts(
  encryption: encryption,
  dataProblem: dataProblem,
  syncMode: mode,
  syncEnabled: syncEnabled,
  needsPairing: needsPairing,
  connection: connection,
  pendingLocal: pending,
  lastSynced: lastSynced ?? DateTime(2026, 11, 4, 11, 55),
  backupEnabled: backupEnabled,
  backupRunning: backupRunning,
  lastBackup: lastBackup ?? DateTime(2026, 11, 4, 8),
  backupInterval: const Duration(days: 1),
  recoveryPoints: 5,
  backupIntact: intact,
  backupFailure: failure,
  now: DateTime(2026, 11, 4, 12),
);

SecurityArea _area(List<SecurityArea> a, String id) =>
    a.firstWhere((x) => x.id == id);

void main() {
  setUpAll(() => HttpOverrides.global = null); // real HTTP to local servers

  group('URLs that must not be fetched', () {
    test('private, loopback, link-local and Tailscale addresses are non-public', () {
      for (final a in [
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.9',
        '172.31.255.1',
        '192.168.1.1',
        '169.254.169.254', // cloud metadata
        '100.64.0.1',
        '100.100.100.100', // Tailscale
        '0.0.0.0',
        '224.0.0.1',
        '::1',
        'fe80::1',
        'fd7a:115c:a1e0::1', // Tailscale v6
        'fc00::5',
        '::ffff:192.168.0.4', // IPv4-mapped private
        '::',
      ]) {
        expect(isNonPublicAddress(_ip(a)), isTrue, reason: a);
      }
      for (final a in [
        '93.184.216.34',
        '8.8.8.8',
        '172.15.0.1',
        '172.32.0.1',
        '100.63.0.1',
        '100.128.0.1',
        '2606:4700:4700::1111',
        '::ffff:8.8.8.8',
      ]) {
        expect(isNonPublicAddress(_ip(a)), isFalse, reason: a);
      }
    });

    test('only public http(s) hosts without credentials pass', () async {
      Future<List<InternetAddress>> dns(String host) async => switch (host) {
        'public.example' => [_ip('93.184.216.34')],
        'mixed.example' => [_ip('93.184.216.34'), _ip('10.0.0.5')],
        'inside.example' => [_ip('192.168.1.10')],
        _ => throw const SocketException('no such host'),
      };
      Future<bool> ok(String u) => isFetchableUrl(Uri.parse(u), resolve: dns);
      expect(await ok('https://public.example/page'), isTrue);
      expect(await ok('http://public.example/'), isTrue);
      expect(await ok('http://93.184.216.34/'), isTrue);
      expect(await ok('http://127.0.0.1:8080/'), isFalse);
      expect(await ok('http://192.168.1.1/'), isFalse);
      expect(await ok('http://[::1]/'), isFalse);
      expect(await ok('http://inside.example/'), isFalse);
      // One private answer among public ones is enough to refuse.
      expect(await ok('http://mixed.example/'), isFalse);
      expect(await ok('ftp://public.example/'), isFalse);
      expect(await ok('file:///C:/Windows/win.ini'), isFalse);
      expect(await ok('https://user:pw@public.example/'), isFalse);
      expect(await ok('http://unknown.example/'), isFalse);
    });

    test('the preview fetcher never contacts a local server', () async {
      final hits = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) {
        hits.add(r.uri.path);
        r.response
          ..headers.contentType = ContentType.html
          ..write('<title>secret</title>')
          ..close();
      });
      final preview = await LinkPreviewFetcher().fetch(
        'http://127.0.0.1:${server.port}/admin',
      );
      expect(preview, isNull);
      expect(hits, isEmpty, reason: 'no request may reach a private address');
    });

    test('a redirect to a blocked address is not followed', () async {
      final hits = <String>[];
      final inner = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final outer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await inner.close(force: true);
        await outer.close(force: true);
      });
      inner.listen((r) {
        hits.add('inner${r.uri.path}');
        r.response
          ..headers.contentType = ContentType.html
          ..write('<title>inside</title>')
          ..close();
      });
      outer.listen((r) {
        hits.add('outer${r.uri.path}');
        r.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${inner.port}/reboot',
          )
          ..close();
      });
      // The first host is allowed (as if it were public); the target is not.
      final fetcher = LinkPreviewFetcher(
        isAllowed: (uri) async => uri.port == outer.port,
      );
      final preview = await fetcher.fetch(
        'http://127.0.0.1:${outer.port}/start',
      );
      expect(preview, isNull);
      expect(hits, ['outer/start'], reason: 'the redirect target was refused');
    });

    test('an allowed page is read, and a redirect to an allowed page too', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) {
        if (r.uri.path == '/old') {
          r.response
            ..statusCode = HttpStatus.movedPermanently
            ..headers.set(HttpHeaders.locationHeader, '/new')
            ..close();
        } else {
          r.response
            ..headers.contentType = ContentType.html
            ..write('<html><head><title>Hello page</title></head></html>')
            ..close();
        }
      });
      final fetcher = LinkPreviewFetcher(isAllowed: (_) async => true);
      final preview = await fetcher.fetch(
        'http://127.0.0.1:${server.port}/old',
      );
      expect(preview?.title, 'Hello page');
    });

    test('a redirect loop ends instead of running forever', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) {
        r.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/again')
          ..close();
      });
      final fetcher = LinkPreviewFetcher(isAllowed: (_) async => true);
      expect(
        await fetcher.fetch('http://127.0.0.1:${server.port}/'),
        isNull,
      );
    });
  });

  group('imported files must be what they say', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('theapp_import_'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<File> file(String name, List<int> bytes) async =>
        File('${dir.path}${Platform.pathSeparator}$name')
          ..writeAsBytesSync(bytes);

    test('real signatures pass', () async {
      final cases = <String, List<int>>{
        'png': [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0],
        'jpg': [0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0],
        'jpeg': [0xFF, 0xD8, 0xFF, 0xE1, 0, 0, 0, 0, 0, 0, 0, 0],
        'gif': [...'GIF89a'.codeUnits, 0, 0, 0, 0, 0, 0],
        'webp': [...'RIFF'.codeUnits, 1, 0, 0, 0, ...'WEBP'.codeUnits],
        'bmp': [...'BM'.codeUnits, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        'pdf': [...'%PDF-1.7\n'.codeUnits, 0, 0, 0],
      };
      for (final e in cases.entries) {
        final f = await file('ok.${e.key}', e.value);
        expect(await ImportGuard.problemWith(f, e.key), isNull, reason: e.key);
      }
    });

    test('a program renamed to .png or .pdf is refused', () async {
      final exe = [0x4D, 0x5A, 0x90, 0, 3, 0, 0, 0, 4, 0, 0, 0]; // "MZ"
      for (final ext in ['png', 'jpg', 'gif', 'webp', 'bmp', 'pdf']) {
        final f = await file('evil.$ext', exe);
        expect(
          await ImportGuard.problemWith(f, ext),
          isNotNull,
          reason: ext,
        );
      }
      // HTML pretending to be a picture.
      final html = await file('page.png', '<html><script>'.codeUnits);
      expect(await ImportGuard.problemWith(html, 'png'), isNotNull);
    });

    test('a PNG called .jpg is still a picture and is accepted', () async {
      final f = await file('web.jpg', [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, //
      ]);
      expect(await ImportGuard.problemWith(f, 'jpg'), isNull);
    });

    test('empty files are refused', () async {
      final f = await file('empty.png', const []);
      expect(await ImportGuard.problemWith(f, 'png'), 'The file is empty.');
    });

    test('a PDF header after a little junk is accepted (viewers do)', () {
      expect(
        ImportGuard.matchesSignature([
          ...List.filled(200, 0x20),
          ...'%PDF-1.4'.codeUnits,
        ], 'pdf'),
        isTrue,
      );
      expect(
        ImportGuard.matchesSignature([
          ...List.filled(1100, 0x20),
          ...'%PDF-1.4'.codeUnits,
        ], 'pdf'),
        isFalse,
      );
    });
  });

  group('the status page is honest', () {
    test('everything healthy: Protected, with the four areas', () {
      final areas = securityAreas(_facts(intact: true));
      expect(areas.map((a) => a.id), ['local', 'sync', 'backups', 'devices']);
      expect(overallStatus(areas), SecurityStatus.protected);
      expect(SecurityStatus.protected.label, 'Protected');
    });

    test('the exact labels', () {
      expect(SecurityStatus.backingUp.label, 'Backing up');
      expect(SecurityStatus.syncPaused.label, 'Sync paused');
      expect(
        SecurityStatus.backupNeedsAttention.label,
        'Backup needs attention',
      );
      expect(
        SecurityStatus.authorizationExpired.label,
        'Device authorization expired',
      );
    });

    test('hub offline: Sync paused, local changes are safe', () {
      final areas = securityAreas(_facts(connection: SyncConnection.offline));
      final sync = _area(areas, 'sync');
      expect(sync.status, SecurityStatus.syncPaused);
      expect(sync.detail, contains('local changes are safe'));
      expect(sync.detail, contains('automatically'));
      expect(overallStatus(areas), SecurityStatus.syncPaused);
    });

    test('revoked or expired device: Device authorization expired', () {
      final areas = securityAreas(_facts(needsPairing: true));
      expect(_area(areas, 'sync').status, SecurityStatus.authorizationExpired);
      expect(
        _area(areas, 'devices').status,
        SecurityStatus.authorizationExpired,
      );
      expect(overallStatus(areas), SecurityStatus.authorizationExpired);
      expect(
        _area(areas, 'sync').detail,
        contains('needs to be authorized again'),
      );
    });

    test('a damaged or failing backup: Backup needs attention', () {
      expect(
        overallStatus(securityAreas(_facts(intact: false))),
        SecurityStatus.backupNeedsAttention,
      );
      expect(
        overallStatus(securityAreas(_facts(failure: 'disk full'))),
        SecurityStatus.backupNeedsAttention,
      );
      expect(
        overallStatus(securityAreas(_facts(backupEnabled: false))),
        SecurityStatus.backupNeedsAttention,
      );
      expect(
        overallStatus(
          securityAreas(_facts(lastBackup: DateTime(2026, 10, 20))),
        ),
        SecurityStatus.backupNeedsAttention,
      );
    });

    test('a backup in progress: Backing up', () {
      expect(
        overallStatus(securityAreas(_facts(backupRunning: true))),
        SecurityStatus.backingUp,
      );
    });

    test('no hub set up: not a problem, not claimed as protected sync', () {
      final areas = securityAreas(_facts(mode: StorageMode.local));
      expect(_area(areas, 'sync').status, SecurityStatus.notInUse);
      expect(_area(areas, 'devices').status, SecurityStatus.notInUse);
      expect(overallStatus(areas), SecurityStatus.protected);
    });

    test('unencrypted or keyless data is never called Protected', () {
      for (final e in [
        EncryptionStatus.unsupportedPlatform,
        EncryptionStatus.keyMissing,
      ]) {
        final areas = securityAreas(_facts(encryption: e));
        expect(_area(areas, 'local').status, SecurityStatus.needsAttention);
        expect(overallStatus(areas), isNot(SecurityStatus.protected));
      }
      final keyless = securityAreas(
        _facts(encryption: EncryptionStatus.keyMissing),
      );
      expect(_area(keyless, 'local').detail, contains('cannot be recreated'));
    });

    test('a refused or read-only data folder is reported, not hidden', () {
      final areas = securityAreas(
        _facts(dataProblem: 'Your data was saved by a newer build.'),
      );
      expect(_area(areas, 'local').status, SecurityStatus.needsAttention);
      expect(_area(areas, 'local').detail, contains('Nothing was deleted'));
    });

    test('no area shows a key, token, address or score', () {
      final text = [
        for (final facts in [
          _facts(),
          _facts(needsPairing: true),
          _facts(connection: SyncConnection.offline),
          _facts(encryption: EncryptionStatus.keyMissing),
        ])
          for (final a in securityAreas(facts)) '${a.title} ${a.detail}',
      ].join(' ');
      expect(text, isNot(matches(RegExp(r'https?://|\d+\.\d+\.\d+\.\d+'))));
      expect(text.toLowerCase(), isNot(contains('token')));
      expect(text, isNot(contains('%')));
    });
  });

  group('notifications stay rare', () {
    test('one announcement per issue per cooldown, again after it clears', () {
      final gate = AttentionGate(cooldown: const Duration(hours: 24));
      final t = DateTime(2026, 11, 4, 9);
      expect(gate.allow('device-authorization', now: t), isTrue);
      // Every retry for the next day says nothing.
      for (var i = 1; i < 50; i++) {
        expect(
          gate.allow('device-authorization', now: t.add(Duration(minutes: i))),
          isFalse,
        );
      }
      // Another issue is its own.
      expect(gate.allow('backup', now: t), isTrue);
      // After the cooldown, a persisting problem is mentioned once more.
      expect(
        gate.allow('device-authorization', now: t.add(const Duration(hours: 25))),
        isTrue,
      );
      // Fixed and broken again: announced at once.
      gate.resolved('device-authorization');
      expect(
        gate.allow('device-authorization', now: t.add(const Duration(hours: 26))),
        isTrue,
      );
    });
  });

  group('zero friction', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('theapp_zero_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<AppState> boot(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ws = Workspace(dir);
      final state = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      state.capture.fetchPreviews = false;
      await tester.runAsync(state.init);
      await tester.pumpWidget(TheApp(state: state));
      await tester.pump();
      return state;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('the app opens straight to the work: no login, no lock', (
      tester,
    ) async {
      final s = await boot(tester);
      await settle(tester);
      expect(s.appLockActive, isFalse, reason: 'no app lock is ever armed');
      expect(find.byType(TextField), findsNothing, reason: 'no login field');
      expect(find.textContaining('Face ID'), findsNothing);
      expect(find.textContaining('Sign in'), findsNothing);
      expect(find.textContaining('password'), findsNothing);
      expect(s.syncNeedsPairing, isFalse);
      await waitForBothClocks(tester, s.flush, what: 'Saving');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('Security & Privacy page: four areas, no false Protected', (
      tester,
    ) async {
      final s = await boot(tester);
      final context = tester.element(find.byType(Scaffold).first);
      showSettingsDialog(context, s, open: SettingsCategory.privacy);
      await settle(tester);
      expect(find.text('Security & Privacy'), findsWidgets);
      for (final id in ['local', 'sync', 'backups', 'devices']) {
        expect(
          find.byKey(ValueKey('security-area-$id')),
          findsOneWidget,
          reason: id,
        );
      }
      // Test machines have no protected key storage: the page must say so
      // rather than call the data protected.
      expect(StorageEncryption.active, isNull);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('security-status-local'))).data,
        'Needs attention',
      );
      final headline = find.descendant(
        of: find.byKey(const ValueKey('security-overall')),
        matching: find.byType(Text),
      );
      expect(tester.widget<Text>(headline).data, isNot('Protected'));
      // No hub set up: sync and devices are "Not in use", not a problem.
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('security-status-sync'))).data,
        'Not in use',
      );
      await tester.tap(find.byKey(const ValueKey('settings-close')));
      await settle(tester);
      await waitForBothClocks(tester, s.flush, what: 'Saving');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });
  });
}
