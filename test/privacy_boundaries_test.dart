// Privacy boundaries enforced in code: the private vault (slow guessing,
// locking, no leaks), the AI gate, the shared clipboard, what reaches a log,
// and that the privacy summary states only what is true. No network except a
// local hub on 127.0.0.1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/app_log.dart';
import 'package:flutter_application_1/data/storage/log_sanitizer.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/ai/ai_service.dart';
import 'package:flutter_application_1/features/ai/ai_session.dart';
import 'package:flutter_application_1/features/capture/clipboard_guard.dart';
import 'package:flutter_application_1/features/search/search_dialog.dart';
import 'package:flutter_application_1/features/settings/privacy_summary.dart';
import 'package:flutter_application_1/features/sharing/share_dialog.dart';
import 'package:flutter_application_1/features/vault/vault_crypto.dart';
import 'package:flutter_application_1/features/vault/vault_service.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/e2ee.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/storage_modes.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_keys.dart';

final sep = Platform.pathSeparator;

const vaultSecret = 'VAULT-CANARY-TEXT-5b1e private';
const vaultTitle = 'VAULT-CANARY-TITLE-77d0';
const password = 'correct horse battery';

class Recording extends AiClient {
  final requests = <List<AiMessage>>[];
  @override
  Future<String> complete(List<AiMessage> messages) async {
    requests.add(messages);
    return 'ok';
  }

  @override
  Stream<String> stream(List<AiMessage> messages) async* {
    requests.add(messages);
    yield 'ok';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late Workspace ws;
  late AppState app;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_privacy_');
    AppLog.session.clear();
    ws = Workspace(Directory('${root.path}${sep}app'));
    await ws.load();
    app = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await app.settings.load();
  });

  tearDown(() async {
    app.dispose();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('the private vault', () {
    const fast = KdfParams(memoryKiB: 64, iterations: 1);

    VaultService make(
      DateTime Function() now, {
      List<Map<String, dynamic>>? saved,
      Map<String, dynamic>? start,
    }) {
      final limiter = UnlockLimiter(now: now)..load(start);
      return VaultService(
        meta: ws.vaultMeta,
        items: ws.vaultItems,
        kdf: fast,
        limiter: limiter,
        saveAttempts: (s) async => saved?.add(s),
      );
    }

    test('wrong passwords are slowed down more and more, and a right one '
        'starts over', () async {
      var clock = DateTime(2026, 1, 1, 12);
      final saved = <Map<String, dynamic>>[];
      final v = make(() => clock, saved: saved);
      addTearDown(v.dispose);
      await v.create(password);
      v.lock();

      Future<Object?> wrong() => v
          .unlock('definitely wrong!!')
          .then<Object?>((_) => null, onError: (Object e) => e);

      // Three free tries.
      for (var i = 0; i < 3; i++) {
        expect(await wrong(), isA<VaultCryptoException>());
        expect(v.limiter.wait, isNull);
      }
      // The next failures lock for 5 s, 15 s, 30 s, 1 min, 5 min, 15 min.
      final expected = [5, 15, 30, 60, 300, 900, 900];
      for (final seconds in expected) {
        expect(await wrong(), isNot(isA<VaultLockedOut>()));
        expect(v.limiter.wait, Duration(seconds: seconds));
        // While waiting nothing is tried: even the right password is refused,
        // and no key work is done.
        final refused = await v
            .unlock(password)
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect(refused, isA<VaultLockedOut>());
        expect(v.unlocked, isFalse);
        clock = clock.add(Duration(seconds: seconds + 1));
      }
      // A right password works once the wait is over, and starts over.
      await v.unlock(password);
      expect(v.unlocked, isTrue);
      expect(v.limiter.failures, 0);
      expect(v.limiter.wait, isNull);
      expect(saved.last['failures'], 0);
    });

    test('the wait survives closing the app, and the recovery code is slowed '
        'down too', () async {
      var clock = DateTime(2026, 1, 1, 12);
      final saved = <Map<String, dynamic>>[];
      final v = make(() => clock, saved: saved);
      final code = await v.create(password);
      v.lock();
      for (var i = 0; i < 4; i++) {
        await v.unlock('wrong password!!').then((_) {}, onError: (_) {});
      }
      expect(v.limiter.wait, isNotNull);
      v.dispose();

      // "Reopened": a new service reads what was saved.
      final again = make(() => clock, start: saved.last);
      addTearDown(again.dispose);
      expect(again.limiter.wait, isNotNull, reason: 'not reset by a restart');
      await expectLater(
        again.recover(code, 'another good password'),
        throwsA(isA<VaultLockedOut>()),
      );
      for (var i = 0; i < 6; i++) {
        clock = clock.add(const Duration(minutes: 20));
        await again
            .recover('WRONG-WRONG-WRONG-WRONG-WRONG', 'another good password')
            .then((_) {}, onError: (_) {});
      }
      expect(again.limiter.failures, greaterThan(3));
      clock = clock.add(const Duration(hours: 1));
      await again.recover(code, 'another good password');
      expect(again.unlocked, isTrue);
    });

    test('it locks when the app goes to the background and after five '
        'minutes, and the key is wiped', () async {
      final v = VaultService(
        meta: ws.vaultMeta,
        items: ws.vaultItems,
        kdf: fast,
      );
      addTearDown(v.dispose);
      await v.create(password);
      v.save(title: vaultTitle, text: vaultSecret);
      expect(v.unlocked, isTrue);
      // What the main window does when the app is hidden or paused.
      v.lock();
      expect(v.unlocked, isFalse);
      expect(v.entries(), isEmpty);
      expect(
        () => v.save(title: 'x', text: 'y'),
        throwsA(isA<VaultCryptoException>()),
      );
      expect(VaultService.idleLimit, const Duration(minutes: 5));
    });

    testWidgets('it locks by itself after five minutes of no use', (
      tester,
    ) async {
      final v = VaultService(
        meta: ws.vaultMeta,
        items: ws.vaultItems,
        kdf: fast,
      );
      addTearDown(v.dispose);
      await tester.runAsync(() => v.create(password));
      v.save(title: vaultTitle, text: vaultSecret); // use: restarts the timer
      expect(v.unlocked, isTrue);
      await tester.pump(const Duration(minutes: 4, seconds: 59));
      expect(v.unlocked, isTrue);
      v.entries(); // looking at it counts as use
      await tester.pump(const Duration(minutes: 4, seconds: 59));
      expect(v.unlocked, isTrue);
      await tester.pump(const Duration(seconds: 2));
      expect(v.unlocked, isFalse);
      expect(v.entries(), isEmpty);
    });

    test('key bytes are overwritten', () {
      final key = randomBytes(32);
      final copy = List<int>.of(key);
      wipe(key);
      expect(key.every((b) => b == 0), isTrue);
      expect(copy.any((b) => b != 0), isTrue);
    });

    test('vault text is found by nothing but the vault: not search, not '
        'AI, not a share, not the log, not the clipboard, not a backup, '
        'not the hub in clear', () async {
      final v = app.vault;
      await v.create(password);
      v.save(title: vaultTitle, text: vaultSecret);
      expect(v.unlocked, isTrue);

      // Search.
      expect(searchEverything(app, 'VAULT-CANARY'), isEmpty);
      expect(searchEverything(app, vaultSecret), isEmpty);

      // AI: attaching it, or hiding it in a question, never sends it.
      await app.ai.setEnabled(true);
      final fake = Recording();
      final session = AiSession(
        settings: app.ai,
        client: () async => fake,
        vaultCheck: v.containsPlaintext,
      );
      session.attach(
        const AiContext(
          title: 'n',
          source: AiSource.notes,
          text: 'summary with $vaultSecret inside',
        ),
      );
      await session.send(AiTool.ask, 'explain');
      expect(fake.requests, isEmpty, reason: 'nothing was sent');
      expect(session.error, contains('vault'));
      session.clear();
      await session.send(AiTool.ask, 'what is $vaultSecret?');
      expect(fake.requests, isEmpty);
      expect(
        app.sendToAi(
          const AiContext(
            title: 'n',
            source: AiSource.notes,
            text: vaultSecret,
          ),
        ),
        isFalse,
      );

      // Sharing: the vault is not a shareable kind.
      expect(
        () => createShare(
          app,
          kind: 'vault',
          sourceId: 'x',
          title: vaultTitle,
          body: vaultSecret,
        ),
        throwsArgumentError,
      );
      expect(shareableKinds, isNot(contains('vault')));

      // Shared clipboard.
      await app.setShareClipboard(true);
      app.readClipboardText = () async => vaultSecret;
      expect(await app.checkClipboard(), isNull);
      app.readClipboardText = () async => 'a note about $vaultTitle today';
      expect(await app.checkClipboard(), isNull);
      expect(ws.clipboard.all, isEmpty);

      // Logs.
      await v.unlock(password).then((_) {}, onError: (_) {});
      final badLogin = ws;
      expect(badLogin, isNotNull);
      final log = AppLog.session.join('\n');
      expect(log, isNot(contains('VAULT-CANARY')));

      // On disk and in a backup: ciphertext only.
      await ws.flush();
      final backup = await ws.backups.snapshot('manual');
      for (final dir in [ws.root, backup]) {
        await for (final f in dir.list(recursive: true)) {
          if (f is! File) continue;
          final text = latin1.decode(await readSafe(f));
          expect(text, isNot(contains('VAULT-CANARY')), reason: f.path);
        }
      }
      // Synced: the hub gets the vault records sealed on top of their own
      // ciphertext.
      final hub = await HubServer.start(
        dir: Directory('${root.path}${sep}hub'),
        port: 0,
        dailyBackups: false,
      );
      addTearDown(hub.stop);
      final token = await hub.auth.register(
        hub.auth.createPairingCode(),
        ws.device!.id,
        'pc',
      );
      final client = SyncClient(
        Uri.parse('http://127.0.0.1:${hub.port}'),
        token: token,
        crypto: testSyncCrypto,
      );
      addTearDown(client.close);
      expect(ws.vaultItems.all, isNotEmpty);
      final changes = [
        for (final MapEntry(key: name, value: c) in ws.syncCollections.entries)
          if (name == 'vault_items' || name == 'vault_meta')
            for (final ver in c.versions())
              if (!ver.deleted)
                SyncChange(
                  collection: name,
                  id: ver.id,
                  rev: ver.rev,
                  deleted: false,
                  data: c.jsonOf(ver.id),
                ),
      ];
      expect(changes, isNotEmpty);
      await client.push(changes);
      await for (final f in hub.store.dir.list(recursive: true)) {
        if (f is File) {
          expect(
            latin1.decode(await readSafe(f)),
            isNot(contains('VAULT-CANARY')),
          );
        }
      }
    });
  });

  group('the AI gate', () {
    test(
      'nothing is sent when AI is off, whatever built the request',
      () async {
        final fake = Recording();
        final guarded = GuardedAiClient(fake, app.ai);
        await expectLater(
          guarded.complete([const AiMessage('user', 'hello')]),
          throwsA(
            isA<AiFailure>().having(
              (e) => e.kind,
              'kind',
              AiErrorKind.settings,
            ),
          ),
        );
        await expectLater(
          guarded.stream([const AiMessage('user', 'hello')]).toList(),
          throwsA(isA<AiFailure>()),
        );
        expect(fake.requests, isEmpty);
        await app.ai.setEnabled(true);
        expect(
          await guarded.complete([const AiMessage('user', 'hello')]),
          'ok',
        );
        expect(fake.requests, hasLength(1));
      },
    );

    test('pictures and sources follow the settings at the service, not the '
        'screen', () async {
      await app.ai.setEnabled(true);
      await app.ai.setSources({AiSource.notes});
      await app.ai.setAllowImages(false);
      final fake = Recording();
      final session = AiSession(settings: app.ai, client: () async => fake);
      session
        ..attach(
          const AiContext(
            title: 'note',
            source: AiSource.notes,
            text: 'NOTE-TEXT',
          ),
        )
        ..attach(
          const AiContext(
            title: 'task',
            source: AiSource.tasks,
            text: 'TASK-TEXT',
          ),
        )
        ..attach(
          AiContext(
            title: 'pic',
            source: AiSource.notes,
            image: Uint8List.fromList([1, 2, 3]),
          ),
        );
      await session.send(AiTool.ask, 'summarise');
      final sent = fake.requests.single;
      expect(sent.map((m) => m.content).join(), contains('NOTE-TEXT'));
      expect(sent.map((m) => m.content).join(), isNot(contains('TASK-TEXT')));
      expect(sent.every((m) => m.images.isEmpty), isTrue);
      // A client made by something else that tries to send a picture anyway.
      await expectLater(
        GuardedAiClient(fake, app.ai).complete([
          AiMessage(
            'user',
            'x',
            images: [
              Uint8List.fromList([1]),
            ],
          ),
        ]),
        throwsA(isA<AiFailure>()),
      );
    });

    test(
      'switching AI off stops a session even with material attached',
      () async {
        await app.ai.setEnabled(true);
        final fake = Recording();
        final session = AiSession(settings: app.ai, client: () async => fake);
        session.attach(
          const AiContext(title: 'n', source: AiSource.notes, text: 't'),
        );
        await app.ai.setEnabled(false);
        await session.send(AiTool.ask, 'hello');
        expect(fake.requests, isEmpty);
        expect(session.error, contains('off'));
      },
    );

    test('a local model and an internet service are told apart', () async {
      await app.ai.setProvider(AiProvider.ollama);
      expect(app.ai.isLocal, isTrue);
      await app.ai.setProvider(AiProvider.openAiCompatible);
      expect(app.ai.isLocal, isFalse);
      await app.ai.setEndpoint('http://192.168.1.20:11434');
      expect(
        app.ai.isLocal,
        isFalse,
        reason: 'another computer is not "local"',
      );
    });
  });

  group('the shared clipboard', () {
    test('is off by default and syncs nothing until it is turned on', () async {
      expect(app.shareClipboard, isFalse);
      app.readClipboardText = () async => 'hello from another app';
      expect(await app.checkClipboard(), isNull);
      expect(ws.clipboard.all, isEmpty);
      await app.setShareClipboard(true);
      expect((await app.checkClipboard())?.text, 'hello from another app');
    });

    test('secrets, tokens, codes and keys are never synced', () async {
      await app.setShareClipboard(true);
      const secrets = [
        'Bearer abcdefghijklmnop12345',
        'Authorization: Basic dXNlcjpwYXNz',
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r',
        'sk-proj-ABCDEFGHIJKLMNOPQRSTUV',
        'AKIAIOSFODNN7EXAMPLE',
        'password: hunter2hunter2',
        '-----BEGIN RSA PRIVATE KEY-----\nMIIB\n-----END RSA PRIVATE KEY-----',
        'Tr0ub4dor&3xyz!',
        'X7kQ-93mA-Pz21-LwR8-uVn4',
        'ABCDEFGH-JKLM-NPQR-STUV-WXYZ-23',
        '3f786850e387550fdab836ed7e6dc881de23001b',
        'https://example.com/reset?token=abc123def456',
        'https://hub.example/s/AAAA#k=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG',
      ];
      for (final s in secrets) {
        app.readClipboardText = () async => s;
        expect(await app.checkClipboard(), isNull, reason: s);
        expect(clipboardBlockReason(s), isNotNull, reason: s);
      }
      expect(ws.clipboard.all, isEmpty);
      // Ordinary text and links still go.
      for (final ok in [
        'Meeting notes for Tuesday',
        'https://example.com/articles/2026/privacy',
        'Call mum at six',
      ]) {
        expect(clipboardBlockReason(ok), isNull, reason: ok);
      }
    });

    test('a code the app itself copies is never shared', () async {
      await app.setShareClipboard(true);
      app.suppressClipboardShare('purple monkey dishwasher');
      app.readClipboardText = () async => 'purple monkey dishwasher';
      expect(await app.checkClipboard(), isNull);
    });

    test(
      'what another app put on the clipboard is never erased by THEapp',
      () async {
        var system = 'copied in another app: groceries';
        final writes = <String>[];
        app
          ..readClipboardText = (() async => system)
          ..writeClipboardText = (t) async {
            writes.add(t);
            system = t;
          };
        await app.setShareClipboard(true);
        // A secret on the clipboard: not shared, and not cleared or replaced.
        system = 'password: hunter2hunter2';
        expect(await app.checkClipboard(), isNull);
        expect(system, 'password: hunter2hunter2');
        expect(writes, isEmpty);
        // Turning the feature off, or a failed read, changes nothing either.
        await app.setShareClipboard(false);
        expect(await app.checkClipboard(), isNull);
        app.readClipboardText = () async => throw PlatformException(code: 'x');
        await app.setShareClipboard(true);
        expect(await app.checkClipboard(), isNull);
        expect(writes, isEmpty);
        expect(system, 'password: hunter2hunter2');
      },
    );
  });

  group('logs', () {
    test('sanitizeLog removes secrets and private links', () {
      const bearer = 'Bearer abcdefghijklmnopqrstuvwxyz0123456789';
      expect(sanitizeLog('x $bearer y'), isNot(contains('abcdefghijkl')));
      expect(
        sanitizeLog(
          'GET https://private.example/notes/CANARY?token=abc&x=1 failed',
        ),
        'GET https://private.example/… failed',
      );
      expect(
        sanitizeLog('https://user:pw@host.example/a'),
        'https://host.example/…',
      );
      expect(
        sanitizeLog('code ${PairingSecret.generate().display} typed'),
        contains('pairing'),
      );
      expect(sanitizeLog('a' * 50), isNot(contains('a' * 40)));
      expect(sanitizeLog('mail me@example.com'), 'mail •••@example.com');
      expect(sanitizeLog('link #k=abcdefGHIJKL_-12345'), 'link #k=•••');
      expect(sanitizeLog('password = hunter2'), 'password = •••');
      expect(sanitizeLog('Authorization: Basic abc'), 'Authorization: •••');
      expect(sanitizeLog('ordinary line 42'), 'ordinary line 42');
      expect(
        hostOnly('https://a.example/secret/path?q=1'),
        'https://a.example',
      );
      expect(
        describeError(
          const FormatException('TEXT-CANARY inside', 'TEXT-CANARY', 3),
        ),
        'FormatException at offset 3',
      );
    });

    test('a damaged record is logged without its content', () async {
      File('${ws.root.path}${sep}data${sep}notes.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'schema': 3,
            'records': [
              {'id': 12345, 'title': 'CANARY-NOTE-TEXT-aa11'},
            ],
          }),
        );
      AppLog.session.clear();
      await ws.notes.load();
      final log = AppLog.session.join('\n');
      expect(log, contains('unreadable'));
      expect(log, isNot(contains('CANARY')));
    });

    test('errors are logged by type, never with the text that failed', () {
      AppLog.session.clear();
      AppLog.error(
        'Saving failed',
        const FormatException(
          'Unexpected CANARY-JSON-TEXT-ff00',
          'CANARY-JSON-TEXT-ff00',
          5,
        ),
        StackTrace.current,
      );
      AppLog.error(
        'AI request failed',
        'prompt CANARY-PROMPT-1234 key sk-abcdefghijklmnop',
      );
      AppLog.warn('Preview of https://private.example/CANARY-URL-9999 failed');
      final log = AppLog.session.join('\n');
      expect(log, contains('FormatException'));
      for (final c in [
        'CANARY-JSON',
        'CANARY-PROMPT',
        'CANARY-URL',
        'sk-abc',
      ]) {
        expect(log, isNot(contains(c)), reason: c);
      }
    });

    test('hub and app logs hold no pairing code, token or key, on success '
        'or on failure', () async {
      final hubLog = <String>[];
      final hub = await HubServer.start(
        dir: Directory('${root.path}${sep}hub'),
        port: 0,
        dailyBackups: false,
        log: hubLog.add,
      );
      addTearDown(hub.stop);
      final url = Uri.parse('http://127.0.0.1:${hub.port}');
      final good = keyedPairingCode(hub.auth);
      final secret = PairingSecret.parse(good)!;
      // Wrong code, wrong token, then the right code.
      final stranger = SyncClient(url);
      addTearDown(stranger.close);
      const wrongCode = 'CANARY-WRONG-CODE-ABCD1234';
      await stranger
          .register(wrongCode, 'dev1', 'Name')
          .then((_) {}, onError: (_) {});
      final badToken = SyncClient(url, token: 'CANARY-TOKEN-0123456789abcdef');
      addTearDown(badToken.close);
      await badToken.pull(0).then((_) {}, onError: (_) {});
      final r = await app.pairWithHub(url.toString(), good);
      expect(r, isNull);
      await app.syncNow();
      final token = await app.syncKeys.load();
      final text = [...hubLog, ...AppLog.session].join('\n');
      for (final secretText in [
        wrongCode,
        'CANARY-TOKEN',
        good,
        secret.secret,
        secret.registerCode,
        base64Encode(testSyncKey),
      ]) {
        expect(text, isNot(contains(secretText)), reason: secretText);
      }
      expect(token, isNotNull);
      for (final d in hub.auth.devices) {
        expect(text, isNot(contains(d.tokenHash)));
      }
    });
  });

  group('the privacy summary says only what is true', () {
    PrivacyFacts facts({
      bool encrypted = true,
      bool lock = false,
      StorageMode mode = StorageMode.local,
      bool sealed = false,
      int shares = 0,
      bool ai = false,
      bool aiLocal = true,
      bool clipboard = false,
      bool vault = false,
    }) => PrivacyFacts(
      encryptedAtRest: encrypted,
      biometricLock: lock,
      syncMode: mode,
      hubEncryptedOnly: sealed,
      activeShares: shares,
      aiEnabled: ai,
      aiLocal: aiLocal,
      aiSources: const ['Notes'],
      aiHost: aiLocal ? '127.0.0.1' : 'api.example.com',
      clipboardSync: clipboard,
      vaultExists: vault,
    );

    String all(PrivacyFacts f) =>
        privacyLines(f).map((l) => '${l.topic}: ${l.text}').join('\n');
    PrivacyLine line(PrivacyFacts f, String topic) =>
        privacyLines(f).firstWhere((l) => l.topic == topic);

    test('no sync claims nothing leaves; sync is never called end-to-end '
        'before it is confirmed', () {
      expect(line(facts(), 'Sync').text, contains('Nothing is synchronized'));
      for (final mode in [StorageMode.pcHub, StorageMode.hosted]) {
        final pending = line(facts(mode: mode), 'Sync');
        expect(pending.warn, isTrue);
        expect(pending.text, contains('not\n'.trim().isEmpty ? '' : 'not yet'));
        expect(pending.text, isNot(contains('cannot read')));
        final done = line(facts(mode: mode, sealed: true), 'Sync');
        expect(done.warn, isFalse);
        expect(done.text, contains('cannot read'));
        expect(done.text, contains('ciphertext'));
        expect(done.text, contains('deleted'), reason: 'what the hub can see');
      }
    });

    test('encryption at rest, the lock and the vault are only claimed when '
        'present', () {
      expect(line(facts(encrypted: false), 'On this device').warn, isTrue);
      expect(
        line(facts(encrypted: false), 'On this device').text,
        contains('Not encrypted'),
      );
      expect(
        line(facts(), 'On this device').text,
        contains('encrypted on disk'),
      );
      expect(line(facts(), 'Locking').text, contains('No app lock'));
      expect(line(facts(lock: true), 'Locking').text, contains('Face ID'));
      expect(
        privacyLines(facts()).any((l) => l.topic == 'Private vault'),
        isFalse,
      );
      expect(
        line(facts(vault: true), 'Private vault').text,
        contains('never go to search'),
      );
    });

    test('AI: off, on this computer, and on the internet are three different '
        'statements', () {
      expect(line(facts(), 'AI').text, contains('Nothing is sent'));
      final local = line(facts(ai: true), 'AI');
      expect(local.text, contains('on this computer'));
      expect(local.warn, isFalse);
      final cloud = line(facts(ai: true, aiLocal: false), 'AI');
      expect(cloud.warn, isTrue);
      expect(cloud.text, contains('api.example.com'));
      expect(cloud.text, contains('sent to that company'));
      expect(cloud.text, contains('Vault notes are never sent'));
    });

    test('clipboard, shared links and deleting are stated plainly', () {
      expect(line(facts(), 'Clipboard').text, contains('off'));
      final on = line(facts(clipboard: true), 'Clipboard');
      expect(on.warn, isTrue);
      expect(on.text, contains('Passwords'));
      expect(line(facts(shares: 2), 'Shared links').text, contains('2 active'));
      final deleting = line(facts(), 'Deleting').text;
      expect(deleting, contains('does not promise forensic erasure'));
      expect(all(facts()), isNot(contains('guaranteed')));
      expect(all(facts()), isNot(contains('100%')));
    });

    test('built from the real app state', () async {
      final f = PrivacyFacts.of(app);
      expect(f.syncMode, StorageMode.local);
      expect(f.hubEncryptedOnly, isFalse);
      expect(f.aiEnabled, isFalse);
      expect(f.clipboardSync, isFalse);
      await app.ai.setEnabled(true);
      await app.setShareClipboard(true);
      final g = PrivacyFacts.of(app);
      expect(g.aiEnabled, isTrue);
      expect(g.clipboardSync, isTrue);
    });
  });
}
