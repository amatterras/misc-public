// Test data mode (--data-dir=) must never resolve to real data.
import 'dart:io';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/test_environment.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;

void main() {
  late Directory root;
  late Directory realApp;
  late Directory realHub;
  late Directory testDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('theapp_testenv_');
    // Stand-ins for %APPDATA%\THEapp and %APPDATA%\THEapp-hub.
    realApp = Directory('${root.path}${sep}THEapp')..createSync();
    realHub = Directory('${root.path}${sep}THEapp-hub')..createSync();
    testDir = Directory('${root.path}${sep}TESTENV${sep}app')
      ..createSync(recursive: true);
    File('${testDir.path}$sep${TestEnvironment.markerFile}').createSync();
  });
  tearDown(() {
    TestEnvironment.dataDir = null;
    root.deleteSync(recursive: true);
  });

  Directory? parse(List<String> args) =>
      TestEnvironment.fromArgs(args, realDirs: [realApp, realHub]);

  Matcher refused(String why) => throwsA(
    isA<TestEnvironmentError>().having(
      (e) => e.message,
      'message',
      contains(why),
    ),
  );

  test('no flag: normal use, nothing changes', () {
    expect(parse(const []), isNull);
    expect(parse(['C:\\some\\photo.png']), isNull); // a Send-to argument
  });

  test('a prepared test folder is accepted', () {
    expect(parse(['--data-dir=${testDir.path}'])!.path, testDir.absolute.path);
  });

  test('real data folders are refused, even with a marker', () {
    for (final real in [realApp, realHub]) {
      File('${real.path}$sep${TestEnvironment.markerFile}').createSync();
      expect(() => parse(['--data-dir=${real.path}']), refused('real'));
      final inner = Directory('${real.path}${sep}x')..createSync();
      File('${inner.path}$sep${TestEnvironment.markerFile}').createSync();
      expect(() => parse(['--data-dir=${inner.path}']), refused('real'));
    }
    // Reaching a real folder through ".." is refused too.
    final sneaky = '${testDir.path}$sep..$sep..${sep}THEapp';
    expect(() => parse(['--data-dir=$sneaky']), refused('real'));
  });

  test('an unprepared folder, typos and ambiguous flags are refused', () {
    final plain = Directory('${root.path}${sep}other')..createSync();
    expect(() => parse(['--data-dir=${plain.path}']), refused('marker'));
    expect(
      () => parse(['--data-dir=${root.path}${sep}missing']),
      refused('marker'),
    );
    expect(() => parse(['--data-dir', testDir.path]), refused('one argument'));
    expect(() => parse(['--data-dir=']), refused('exactly one'));
    expect(
      () => parse(['--data-dir=${testDir.path}', '--data-dir=${testDir.path}']),
      refused('exactly one'),
    );
  });

  test('the test hub is port 47799 on this PC or over Tailscale only', () {
    for (final ok in [
      'http://127.0.0.1:47799',
      'http://localhost:47799',
      'http://100.101.102.103:47799', // the PC's Tailscale address
      'http://pc.tail1234.ts.net:47799',
    ]) {
      expect(TestEnvironment.isTestHub(Uri.parse(ok)), isTrue, reason: ok);
    }
    for (final no in [
      'http://127.0.0.1:47710', // the real hub
      'http://100.101.102.103:47710',
      'http://192.168.1.20:47799', // home network
      'http://8.8.8.8:47799',
    ]) {
      expect(TestEnvironment.isTestHub(Uri.parse(no)), isFalse, reason: no);
    }
  });

  test('in test mode the app will not pair with the real hub port', () async {
    TestEnvironment.dataDir = testDir;
    final ws = Workspace(testDir);
    final state = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await state.init();
    final error = await state.pairWithHub('http://127.0.0.1:47710', 'ABCD1234');
    expect(error, contains('test hub'));
    // Any other port or machine is refused too, not only the real hub's.
    for (final other in [
      'http://127.0.0.1:47800',
      'http://100.64.0.1:47710',
      'http://192.168.1.20:47799',
    ]) {
      expect(
        await state.pairWithHub(other, 'ABCD1234'),
        contains('test hub'),
        reason: other,
      );
    }
    expect(
      File('${testDir.path}${sep}sync${sep}hub.token').existsSync(),
      isFalse,
    );
    state.dispose();
  });
}
