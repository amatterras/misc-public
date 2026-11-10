import 'dart:io';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_fix3_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('only assets added to the Archive are archive assets', () async {
    final ws = Workspace(dir);
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    await s.init();
    final other = ws.linkAsset('https://other-unit.example.com');
    final added = ws.linkAsset('https://archive.example.com');
    expect(s.archiveAssetIds(), isEmpty);
    await s.addToLinks(added);
    expect(s.archiveAssetIds(), {added.id});
    expect(s.archiveAssetIds(), isNot(contains(other.id)));
  });

  test('the Browser keeps its address bar; no global search bar entry', () {
    // The sidebar capsule and the shared navigation list offer no global
    // search entry.
    for (final path in [
      'lib/new_ui/new_sidebar.dart',
      'lib/app/navigation.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src.contains('showSearchDialog'), isFalse, reason: path);
    }
    final browser = File('lib/features/browser/browser_page.dart')
        .readAsStringSync();
    expect(browser, contains('Search or enter an address'));
  });

  test('straightening waits 0.9 seconds', () {
    expect(
      CanvasController.holdToStraighten,
      const Duration(milliseconds: 900),
    );
  });
}
