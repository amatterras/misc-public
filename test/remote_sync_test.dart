// Remote-sync readiness behaviour that can be proven on one PC: device
// revocation, recovery by pairing again, and the unencrypted-network
// warning. (Real cross-network sync needs Tailscale on two devices.)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/settings/sync_section.dart';
import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the local in-process hub

  late Directory root;
  late HubServer hub;
  late Uri url;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_remote_');
    hub = await HubServer.start(
      dir: Directory('${root.path}${sep}hub'),
      port: 0,
      dailyBackups: false,
    );
    url = Uri.parse('http://127.0.0.1:${hub.port}');
  });
  tearDown(() async {
    await hub.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> app() async {
    final ws = Workspace(Directory('${root.path}${sep}app'));
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await s.init();
    return s;
  }

  test('a revoked token is refused for every kind of request', () async {
    final token = await hub.auth.register(
      hub.auth.createPairingCode(),
      'dev1',
      'Laptop',
    );
    final client = SyncClient(url, token: token);
    await client.pull(0);
    expect(await hub.auth.revoke('dev1'), isTrue);
    Matcher refused() => throwsA(
      isA<SyncFailure>().having((f) => f.code, 'code', 'unauthorized'),
    );
    await expectLater(client.pull(0), refused());
    await expectLater(
      client.push([
        const SyncChange(
          collection: 'notes',
          id: 'n',
          rev: '0001792610475963-0000-dev1',
          deleted: true,
        ),
      ]),
      refused(),
    );
    await expectLater(client.hasAttachment('0' * 64), refused());
    client.close();
  });

  test('a removed device stops retrying, keeps its edits, and sends them '
      'after pairing again', () async {
    final s = await app();
    expect(
      await s.pairWithHub(url.toString(), hub.auth.createPairingCode()),
      isNull,
    );
    await s.syncNow();
    expect(s.syncStatus, startsWith('Synced'));
    expect(s.syncScheduled, isTrue);

    // Removed on the PC with `thehub revoke`.
    expect(await hub.auth.revoke(s.workspace.device!.id), isTrue);
    final note = s.workspace.createNote(title: 'Written after removal');
    await s.syncNow();
    expect(s.syncNeedsPairing, isTrue);
    expect(s.syncScheduled, isFalse, reason: 'no retry every minute');
    expect(s.syncStatus, contains('pair'));
    expect(s.workspace.notes[note.id], isNotNull, reason: 'nothing lost');
    expect(await hub.store.current('notes', note.id), isNull);

    // Pair again: the queued edit goes out.
    await s.disconnectHub();
    expect(
      await s.pairWithHub(url.toString(), hub.auth.createPairingCode()),
      isNull,
    );
    expect(s.syncNeedsPairing, isFalse);
    await s.syncNow();
    expect(s.syncStatus, startsWith('Synced'));
    expect(
      (await hub.store.current('notes', note.id))?.data?['title'],
      'Written after removal',
    );
    await s.flush();
    s.dispose();
  });

  testWidgets('pairing shows a warning for unencrypted home-network '
      'addresses only', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = (await tester.runAsync(app))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncSection(state: s)),
      ),
    );
    final field = find.widgetWithText(TextField, 'Hub address');
    final warning = find.byKey(const ValueKey('unencrypted-warning'));
    for (final (address, warn) in [
      ('http://127.0.0.1:47710', false),
      ('http://100.101.102.103:47710', false),
      ('http://my-pc.tail1234.ts.net:47710', false),
      ('http://192.168.1.20:47710', true),
      ('http://10.0.0.5:47710', true),
    ]) {
      await tester.enterText(field, address);
      await tester.pump();
      expect(warning, warn ? findsOneWidget : findsNothing, reason: address);
    }
    await tester.runAsync(s.flush);
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });
}
