// Phase 5 audit fixes: crash-safe capture without duplicates, and global
// search over note pages, Archive tags and projects.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/task_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/search/search_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_p5_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> app() async {
    final ws = Workspace(dir);
    await ws.load();
    final s = AppState(
      canvases: FileCanvasRepository(ws.store),
      settings: SettingsRepository(ws.store),
      workspace: ws,
      enableSendTo: false,
    );
    s.capture.fetchPreviews = false;
    await s.init();
    return s;
  }

  test('a capture request processed twice (crash before removal) '
      'gives one Inbox item', () async {
    final s = await app();
    final req = File(
      '${s.sendTo.requestsDir.path}${Platform.pathSeparator}r1.json',
    );
    await req.parent.create(recursive: true);
    final body = jsonEncode({'type': 'text', 'value': 'hello'});
    await req.writeAsString(body);
    await s.sendTo.processRequests(s.capture);
    await req.writeAsString(body); // as if the app crashed before deleting
    await s.sendTo.processRequests(s.capture);
    expect(s.workspace.inbox.all.where((i) => i.text == 'hello'), hasLength(1));
    await s.flush();
    s.dispose();
  });

  test('search finds note-page text, Archive tags and projects, and opens '
      'the original', () async {
    final s = await app();
    final note = s.workspace.createNote(title: 'Biology');
    await s.saveDocument(
      CanvasDocument(
        id: notebookIdFor(note.id),
        title: 'Biology',
        kind: 'notebook',
        items: [
          TextItem(
            id: 't',
            position: Offset.zero,
            width: 200,
            minHeight: 0,
            text: 'mitochondria notes',
          ),
        ],
        updatedAt: DateTime.now(),
      ),
    );
    final link = s.capture.link('https://shop.example');
    await s.addToLinks(link, tags: ['shopping']);
    s.workspace.projects.put(
      Project(
        id: 'p',
        name: 'Thesis',
        kind: ProjectKind.project,
        updatedAt: DateTime(2026),
      ),
    );

    final page = searchEverything(s, 'mitochondria').single;
    expect(page.kind, 'Note page');
    page.open();
    expect(s.page, AppPage.notes);

    final tagged = searchEverything(s, 'shopping');
    expect(tagged.map((r) => r.kind), contains('Link'));
    expect(searchEverything(s, 'thesis').single.kind, 'Project');
    expect(await s.openLinkCard(link.id), isTrue);
    expect(s.page, AppPage.links);
    await s.flush();
    s.dispose();
  });
}
