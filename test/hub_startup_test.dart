// Starting the hub at Windows sign-in: registration, upgrade, removal and the
// real command a sign-in would run, all on temporary folders (the user's real
// Startup folder and hub are never touched).
//
// What this cannot prove: that Windows really runs the shortcut at the next
// sign-in. That needs a sign-out/reboot; the shortcut's content is checked
// exactly and the command it contains is run for real instead.
import 'dart:async';
import 'dart:io';

import 'package:flutter_application_1/hub/hub_host.dart';
import 'package:flutter_application_1/hub/hub_startup.dart';
import 'package:flutter_test/flutter_test.dart';

final sep = Platform.pathSeparator;
final onWindows = Platform.isWindows;
const _why = 'Start at sign-in exists only on Windows';

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

Future<bool> until(
  FutureOr<bool> Function() done, {
  Duration limit = const Duration(seconds: 20),
}) async {
  final watch = Stopwatch()..start();
  while (!await done()) {
    if (watch.elapsed > limit) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return true;
}

void main() {
  late Directory root;
  late Directory startup;
  final projectRoot = Directory.current;

  setUp(() {
    root = Directory.systemTemp.createTempSync("theapp_startup_o'brien ");
    startup = Directory('${root.path}${sep}Startup')..createSync();
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A throwaway project folder with the sources the hub is built from.
  Directory fakeProject() {
    final p = Directory('${root.path}${sep}project')..createSync();
    for (final d in ['bin', 'lib${sep}hub', 'lib${sep}sync']) {
      Directory('${p.path}$sep$d').createSync(recursive: true);
    }
    File('${p.path}${sep}bin${sep}thehub.dart')
        .writeAsStringSync('void main(){}');
    return p;
  }

  HubStartup make({
    Directory? project,
    File? exe,
    HubBuilder? build,
    List<String> extra = const [],
  }) => HubStartup(
    startupDir: startup,
    projectRoot: project ?? fakeProject(),
    exe: exe,
    build: build,
    hubDir: Directory('${root.path}${sep}no-hub'),
    extraArguments: extra,
  );

  Future<void> fakeBuild(File source, File output) async {
    output.writeAsBytesSync([77, 90, 1, 2, 3]);
  }

  group('registration', () {
    test('enable builds the program when it is missing, then registers it '
        'exactly', () async {
      var builds = 0;
      final s = make(
        build: (src, out) async {
          builds++;
          await fakeBuild(src, out);
        },
      );
      expect(s.exe.existsSync(), isFalse);
      final r = await s.enable();
      expect(builds, 1);
      expect(r.built, isTrue);
      expect(r.change, StartupChange.created);
      expect(s.exe.existsSync(), isTrue);
      expect(s.exe.parent.existsSync(), isTrue, reason: 'folder was made');
      expect(r.shortcut, s.expected);
      expect(r.shortcut.arguments, contains('serve --background yes'));
      expect(r.shortcut.arguments, contains('--private-host auto'));
      expect(
        startup.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.lnk'),
        ),
        hasLength(1),
      );
    }, skip: onWindows ? false : _why);

    test('enable twice changes nothing: one shortcut, not rewritten, no '
        'rebuild', () async {
      var builds = 0;
      final s = make(
        build: (a, b) async {
          builds++;
          await fakeBuild(a, b);
        },
      );
      await s.enable();
      final stamp = s.shortcutFile.lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final again = await s.enable();
      expect(again.change, StartupChange.unchanged);
      expect(again.built, isFalse);
      expect(builds, 1);
      expect(s.shortcutFile.lastModifiedSync(), stamp);
      expect(
        startup.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.lnk'),
        ),
        hasLength(1),
      );
    }, skip: onWindows ? false : _why);

    test(
      'an upgrade (the program moved) updates the shortcut in place',
      () async {
        final project = fakeProject();
        final first = make(project: project, build: fakeBuild);
        await first.enable();
        final moved = make(
          project: project,
          exe: File('${root.path}${sep}new place${sep}thehub.exe'),
          build: fakeBuild,
        );
        final r = await moved.enable();
        expect(r.change, StartupChange.updated);
        expect(r.shortcut.target, endsWith('new place${sep}thehub.exe'));
        expect(
          startup.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.lnk'),
          ),
          hasLength(1),
          reason: 'never a second registration',
        );
        final st = await moved.status();
        expect(st.registered, isTrue);
        expect(st.targetExists, isTrue);
      },
      skip: onWindows ? false : _why,
    );

    test(
      'sources newer than the program rebuild it (upgrade of the code)',
      () async {
        final project = fakeProject();
        var builds = 0;
        Future<void> counting(File a, File b) async {
          builds++;
          await fakeBuild(a, b);
        }

        final s = make(project: project, build: counting);
        await s.enable();
        expect(builds, 1);
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        File('${project.path}${sep}lib${sep}hub${sep}hub_server.dart')
            .writeAsStringSync('// changed');
        final r = await s.enable();
        expect(builds, 2);
        expect(r.built, isTrue);
        expect(r.change, StartupChange.unchanged, reason: 'same shortcut');
      },
      skip: onWindows ? false : _why,
    );

    test(
      'a failed build registers nothing and keeps the working program',
      () async {
        final project = fakeProject();
        final good = make(project: project, build: fakeBuild);
        await good.enable();
        final before = good.exe.readAsBytesSync();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        File('${project.path}${sep}bin${sep}thehub.dart')
            .writeAsStringSync('//new');
        final broken = make(
          project: project,
          build: (a, b) async =>
              throw const HubStartupException('compile error'),
        );
        await expectLater(broken.enable(), throwsA(isA<HubStartupException>()));
        expect(good.exe.readAsBytesSync(), before);
        expect(File('${good.exe.path}.new').existsSync(), isFalse);

        // And with nothing registered yet, nothing is left behind.
        await good.disable();
        final fresh = make(
          project: project,
          exe: File('${root.path}${sep}other${sep}thehub.exe'),
          build: (a, b) async => throw const HubStartupException('nope'),
        );
        await expectLater(fresh.enable(), throwsA(isA<HubStartupException>()));
        expect(fresh.shortcutFile.existsSync(), isFalse);
      },
      skip: onWindows ? false : _why,
    );

    test(
      'a build that produces nothing is an error, not a registration',
      () async {
        final s = make(build: (a, b) async {});
        await expectLater(s.enable(), throwsA(isA<HubStartupException>()));
        expect(s.shortcutFile.existsSync(), isFalse);
      },
      skip: onWindows ? false : _why,
    );

    test('no project and no program: a clear message', () async {
      final s = HubStartup(
        startupDir: startup,
        projectRoot: Directory('${root.path}${sep}nowhere'),
        build: fakeBuild,
      );
      await expectLater(
        s.enable(),
        throwsA(
          isA<HubStartupException>().having(
            (e) => e.message,
            'message',
            contains('Cannot build'),
          ),
        ),
      );
    }, skip: onWindows ? false : _why);

    test(
      'a missing Startup folder is reported, nothing half-created',
      () async {
        startup.deleteSync();
        final s = make(build: fakeBuild);
        await expectLater(
          s.enable(),
          throwsA(
            isA<HubStartupException>().having(
              (e) => e.message,
              'message',
              contains('Startup folder'),
            ),
          ),
        );
        expect(startup.existsSync(), isFalse);
      },
      skip: onWindows ? false : _why,
    );

    test('a refused shortcut write (permissions) is an error and leaves no '
        'registration', () async {
      final s = HubStartup(
        startupDir: startup,
        projectRoot: fakeProject(),
        build: fakeBuild,
        runPowerShell: (script) async => throw const HubStartupException(
          'Windows refused the shortcut change.',
        ),
      );
      await expectLater(s.enable(), throwsA(isA<HubStartupException>()));
      expect(s.shortcutFile.existsSync(), isFalse);
    }, skip: onWindows ? false : _why);

    test(
      'paths with spaces, apostrophes and a custom data folder survive',
      () async {
        final s = make(
          build: fakeBuild,
          exe: File("${root.path}${sep}it's a path${sep}thehub.exe"),
          extra: ['--data', '${root.path}${sep}my hub data'],
        );
        final r = await s.enable();
        expect(r.shortcut.target, contains("it's a path"));
        expect(
          r.shortcut.arguments,
          contains('"${root.path}${sep}my hub data"'),
        );
        expect(r.shortcut.workingDirectory, contains("it's a path"));
      },
      skip: onWindows ? false : _why,
    );
  });

  group('removal and status', () {
    test('disable removes it and is harmless twice', () async {
      final s = make(build: fakeBuild);
      expect(await s.disable(), isFalse, reason: 'nothing to remove');
      await s.enable();
      expect(await s.disable(), isTrue);
      expect(s.shortcutFile.existsSync(), isFalse);
      expect(await s.disable(), isFalse);
      // It can be registered again afterwards.
      expect((await s.enable()).change, StartupChange.created);
    }, skip: onWindows ? false : _why);

    test(
      'status reports the registration, a broken target, and no hub',
      () async {
        final s = make(build: fakeBuild);
        var st = await s.status();
        expect(st.registered, isFalse);
        expect(st.hubRunning, isFalse);
        await s.enable();
        st = await s.status();
        expect(st.registered, isTrue);
        expect(st.targetExists, isTrue);
        expect(st.broken, isFalse);
        s.exe.deleteSync();
        st = await s.status();
        expect(st.registered, isTrue);
        expect(st.broken, isTrue, reason: 'it would start nothing at sign-in');
      },
      skip: onWindows ? false : _why,
    );

    test(
      'a damaged shortcut file is treated as not registered correctly',
      () async {
        final s = make(build: fakeBuild);
        await s.enable();
        s.shortcutFile.writeAsStringSync('not a shortcut');
        final st = await s.status();
        expect(st.registered, isTrue);
        expect(st.shortcut, isNull);
        expect(st.broken, isTrue, reason: 'it would start nothing at sign-in');
        // Enabling again repairs it.
        final r = await s.enable();
        expect(r.change, isIn([StartupChange.created, StartupChange.updated]));
        expect((await s.status()).targetExists, isTrue);
      },
      skip: onWindows ? false : _why,
    );
  });

  group('the real command a sign-in runs', () {
    late File exe;

    setUpAll(() async {
      if (!onWindows) return;
      // One real build for all of these (about ten seconds).
      final dir = Directory.systemTemp.createTempSync('theapp hub exe ');
      exe = File('${dir.path}${sep}thehub.exe');
      final s = HubStartup(
        startupDir: Directory.systemTemp.createTempSync('theapp_start_'),
        projectRoot: projectRoot,
        exe: exe,
      );
      await s.enable(); // builds for real
    });
    tearDownAll(() {
      if (!onWindows) return;
      try {
        exe.parent.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<ProcessResult> run(List<String> args) =>
        Process.run(exe.path, args, workingDirectory: exe.parent.path);

    test(
      'serve --background starts a hub that keeps running after the '
      'launcher exits, answers, and can be stopped',
      () async {
        final data = Directory('${root.path}${sep}hub data')..createSync();
        final port = await freePort();
        final started = await run([
          'serve',
          '--background',
          'yes',
          '--private-host',
          'auto',
          '--data',
          data.path,
          '--port',
          '$port',
        ]);
        expect(
          started.exitCode,
          0,
          reason: '${started.stdout}${started.stderr}',
        );
        expect(
          await until(() async => await HubStartup.runningHub(data) != null),
          isTrue,
          reason: 'the hub should be answering',
        );
        final info = (await HubStartup.runningHub(data))!;
        expect(info['port'], port);

        // "Is it actually running?": the same answer from the command line.
        final status = await run(['status', '--data', data.path]);
        expect('${status.stdout}', contains('running'));

        // A second launch (a second sign-in, a double click) changes nothing.
        final again = await run([
          'serve',
          '--background',
          'yes',
          '--data',
          data.path,
          '--port',
          '$port',
        ]);
        expect(again.exitCode, isNot(0));
        expect('${again.stderr}${again.stdout}', contains('already running'));
        expect((await HubStartup.runningHub(data))!['pid'], info['pid']);

        // The hub works without THEapp's window: THEapp's own host would use it.
        final host = HubHost(
          dir: data,
          port: port,
          privateAddress: () async => null,
        );
        await host.start();
        expect(host.state, HubHostState.external);
        await host.stop();

        // A log exists and says it started.
        final log = File('${data.path}${sep}logs${sep}hub.log');
        expect(log.existsSync(), isTrue);
        expect(log.readAsStringSync(), contains('Hub listening'));

        final stopped = await run(['stop', '--data', data.path]);
        expect(stopped.exitCode, 0);
        expect(
          await until(() async => await HubStartup.runningHub(data) == null),
          isTrue,
        );
      },
      skip: onWindows ? false : _why,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'after the hub was killed (a crash, a power cut) the next start '
      'works although hub.json is stale',
      () async {
        final data = Directory('${root.path}${sep}hub data 2')..createSync();
        final port = await freePort();
        final args = [
          'serve',
          '--background',
          'yes',
          '--data',
          data.path,
          '--port',
          '$port',
        ];
        expect((await run(args)).exitCode, 0);
        expect(
          await until(() async => await HubStartup.runningHub(data) != null),
          isTrue,
        );
        final pid = (await HubStartup.runningHub(data))!['pid'] as int;
        expect(Process.killPid(pid), isTrue);
        expect(
          await until(() async => await HubStartup.runningHub(data) == null),
          isTrue,
        );
        expect(
          File('${data.path}${sep}hub.json').existsSync(),
          isTrue,
          reason: 'a killed hub leaves its file behind',
        );
        final again = await run(args);
        expect(again.exitCode, 0, reason: '${again.stdout}${again.stderr}');
        expect(
          await until(() async => await HubStartup.runningHub(data) != null),
          isTrue,
        );
        expect((await HubStartup.runningHub(data))!['pid'], isNot(pid));
        await run(['stop', '--data', data.path]);
        await until(() async => await HubStartup.runningHub(data) == null);
      },
      skip: onWindows ? false : _why,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'startup enable/status/disable work from the command line',
      () async {
        // The exe registers itself (no build needed): the shortcut points at it.
        // Uses the real command with the Startup folder redirected.
        final r = await Process.run(
          exe.path,
          ['startup', 'status'],
          environment: {
            'THEAPP_STARTUP_DIR': startup.path,
            'APPDATA': root.path,
          },
        );
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        expect('${r.stdout}', contains('Not registered'));
        final en = await Process.run(
          exe.path,
          ['startup', 'enable'],
          environment: {
            'THEAPP_STARTUP_DIR': startup.path,
            'APPDATA': root.path,
          },
        );
        expect(en.exitCode, 0, reason: '${en.stdout}${en.stderr}');
        expect(startup.listSync().whereType<File>().length, 1);
        final again = await Process.run(
          exe.path,
          ['startup', 'enable'],
          environment: {
            'THEAPP_STARTUP_DIR': startup.path,
            'APPDATA': root.path,
          },
        );
        expect('${again.stdout}', contains('Already'));
        final off = await Process.run(
          exe.path,
          ['startup', 'disable'],
          environment: {
            'THEAPP_STARTUP_DIR': startup.path,
            'APPDATA': root.path,
          },
        );
        expect(off.exitCode, 0);
        expect(startup.listSync().whereType<File>(), isEmpty);
      },
      skip: onWindows ? false : _why,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
