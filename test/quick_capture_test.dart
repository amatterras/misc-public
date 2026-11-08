// Quick Capture: a thought, a task or a link saved from anywhere, safe to
// retry, with optional references to what is open, and without touching the
// page underneath (also a note with unsaved typing).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/capture/quick_capture.dart';
import 'package:flutter_application_1/features/notes/note_page.dart';
import 'package:flutter_application_1/features/smartlinks/smart_links.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('theapp_qcapture_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppState> boot() async {
    final ws = Workspace(dir);
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

  group('saving', () {
    test('a thought: one Inbox item, safe to repeat', () async {
      final s = await boot();
      addTearDown(() async {
        await s.flush();
        s.dispose();
      });
      final before = s.workspace.inbox.length;
      for (var i = 0; i < 3; i++) {
        final r = await saveQuickCapture(
          s,
          id: 'cap1',
          text: '  buy oat milk  ',
          kind: QuickKind.thought,
        );
        expect(r.message, 'Saved to the Inbox');
      }
      expect(s.workspace.inbox.length, before + 1);
      expect(s.workspace.inbox['cap1']!.text, 'buy oat milk');
    });

    test('a task: one Task, notes keep the rest, nothing scheduled', () async {
      final s = await boot();
      addTearDown(() async {
        await s.flush();
        s.dispose();
      });
      for (var i = 0; i < 2; i++) {
        await saveQuickCapture(
          s,
          id: 'task1',
          text: 'Call the dentist\nask about Tuesday',
          kind: QuickKind.task,
        );
      }
      final t = s.workspace.tasks['task1']!;
      expect(s.workspace.tasks.all.where((x) => x.title == 'Call the dentist'), hasLength(1));
      expect(t.notes, 'ask about Tuesday');
      expect(t.dueDate, isNull);
      expect(t.done, isFalse);
    });

    test('a link: the saved reference is reused, one Inbox item', () async {
      final s = await boot();
      addTearDown(() async {
        await s.flush();
        s.dispose();
      });
      await saveQuickCapture(s, id: 'l1', text: 'https://example.com/a', kind: QuickKind.link);
      await saveQuickCapture(s, id: 'l1', text: 'https://example.com/a', kind: QuickKind.link);
      await saveQuickCapture(s, id: 'l2', text: 'https://example.com/a', kind: QuickKind.link);
      final item = s.workspace.inbox['l1']!;
      expect(s.workspace.assets[item.assetId]!.url, 'https://example.com/a');
      expect(
        s.workspace.assets.all.where((a) => a.url == 'https://example.com/a'),
        hasLength(1),
        reason: 'the same address is one saved reference',
      );
    });

    test('empty text and a non-address as a link are refused', () async {
      final s = await boot();
      addTearDown(() async {
        await s.flush();
        s.dispose();
      });
      final before = s.workspace.inbox.length;
      await expectLater(
        saveQuickCapture(s, id: 'x', text: '   ', kind: QuickKind.thought),
        throwsA(isA<QuickCaptureFailure>()),
      );
      await expectLater(
        saveQuickCapture(s, id: 'x', text: 'not an address', kind: QuickKind.link),
        throwsA(isA<QuickCaptureFailure>()),
      );
      expect(s.workspace.inbox.length, before);
    });

    test('a failed save keeps the text; the retry makes no second copy', () async {
      final s = await boot();
      addTearDown(() async {
        await s.flush();
        s.dispose();
      });
      var fail = true;
      Future<void> flaky() async {
        if (fail) throw const FileSystemException('disk is full');
      }

      final before = s.workspace.tasks.all.length;
      await expectLater(
        saveQuickCapture(
          s,
          id: 't9',
          text: 'Pay rent',
          kind: QuickKind.task,
          persist: flaky,
        ),
        throwsA(
          isA<QuickCaptureFailure>().having(
            (e) => e.message,
            'message',
            contains('try again'),
          ),
        ),
      );
      fail = false;
      final r = await saveQuickCapture(
        s,
        id: 't9',
        text: 'Pay rent',
        kind: QuickKind.task,
        persist: flaky,
      );
      expect(r.message, 'Task added');
      expect(s.workspace.tasks.all.length, before + 1);
    });

    test('references to the open note and objects are workspace links', () async {
      final s = await boot();
      addTearDown(() async {
        await s.flush();
        s.dispose();
      });
      final note = s.workspace.createNote(title: 'Thesis');
      s.activeNoteId.value = note.id;
      s.canvas!.addItems([
        TextItem(id: 'o1', position: Offset.zero, width: 200, minHeight: 40, text: 'Big idea'),
      ]);
      s.goTo(AppPage.canvas);
      s.canvas!.select(const ['o1']);
      final options = quickContexts(s);
      expect(options.map((o) => o.label), [
        'Note “Thesis”',
        '1 selected object on “${s.canvas!.title}”',
      ]);
      await saveQuickCapture(
        s,
        id: 'ref1',
        text: 'follow up',
        kind: QuickKind.task,
        contexts: options,
      );
      final task = s.workspace.tasks['ref1']!;
      expect(task.noteIds, [note.id]);
      expect(findLinks(task.notes).map((t) => t.ref), [
        WorkspaceRef(RefKind.note, note.id),
        WorkspaceRef(RefKind.object, s.canvas!.id, 'o1'),
      ]);
      await saveQuickCapture(
        s,
        id: 'ref2',
        text: 'a thought about it',
        kind: QuickKind.thought,
        contexts: options.take(1).toList(),
      );
      expect(s.workspace.inbox['ref2']!.text, contains('[[theapp:note/${note.id}'));
    });
  });

  group('on screen', () {
    Future<AppState> app(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = await tester.runAsync(boot) as AppState;
      await tester.pumpWidget(TheApp(state: s));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      addTearDown(() async {
        await tester.runAsync(s.flush);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 9));
        s.dispose();
      });
      return s;
    }

    /// Real file work finishes between frames; wait until the window closes.
    Future<void> untilClosed(WidgetTester tester) async {
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byKey(const ValueKey('quick-capture')).evaluate().isEmpty) return;
      }
    }

    /// Lets the toast timer run out so no timer is left pending.
    Future<void> finish(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 4));
    }

    Future<void> shortcut(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('from every major section, without leaving it', (tester) async {
      final s = await app(tester, const Size(1300, 900));
      var n = 0;
      // (No Home page: removed 2026-11-03 on ui/new-design.)
      for (final page in [
        AppPage.canvas,
        AppPage.notes,
        AppPage.calendar,
        AppPage.links,
      ]) {
        s.goTo(page);
        await tester.pumpAndSettle();
        await shortcut(tester);
        expect(find.byKey(const ValueKey('quick-capture')), findsOneWidget, reason: '$page');
        await tester.enterText(find.byKey(const ValueKey('quick-capture-text')), 'from $page');
        await tester.tap(find.byKey(const ValueKey('quick-capture-save')));
        await untilClosed(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('quick-capture')), findsNothing, reason: '$page');
        expect(s.page, page, reason: 'still where it was');
        n++;
        expect(
          s.workspace.inbox.all.where((i) => (i.text ?? '').startsWith('from ')).length,
          n,
        );
      }
      await finish(tester);
    });

    testWidgets('the bar button opens it (touch layouts too)', (tester) async {
      await app(tester, const Size(390, 800));
      final button = find.byKey(const ValueKey('quick-capture-button'));
      expect(button, findsOneWidget);
      expect(tester.getSize(button).width, greaterThanOrEqualTo(44));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quick-capture')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quick-capture-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quick-capture')), findsNothing);
      await finish(tester);
    });

    testWidgets('a note with unsaved typing is left exactly as it is', (
      tester,
    ) async {
      final s = await app(tester, const Size(1300, 900));
      final note = s.workspace.createNote(title: 'Draft');
      openNotePage(tester.element(find.byType(Navigator).first), s, note.id);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final body = find.byKey(const ValueKey('note-body'));
      await tester.enterText(body, 'half a sentence that is not');
      await tester.pump();
      final before = tester.widget<TextField>(body).controller!.text;
      await tester.tap(find.byKey(const ValueKey('quick-capture-button')));
      await tester.pumpAndSettle();
      // The open note is offered as something to refer to.
      expect(find.text('Refer to Note “Draft”'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quick-context-0')));
      await tester.enterText(find.byKey(const ValueKey('quick-capture-text')), 'idea for later');
      await tester.tap(find.byKey(const ValueKey('quick-capture-save')));
      await untilClosed(tester);
      await tester.pumpAndSettle();
      expect(find.byType(NotePage), findsOneWidget, reason: 'still on the note');
      expect(tester.widget<TextField>(body).controller!.text, before);
      expect(s.workspace.notes[note.id]!.body, before);
      final captured = s.workspace.inbox.all.firstWhere((i) => i.text == null ? false : i.text!.startsWith('idea for later'));
      expect(captured.text, contains('[[theapp:note/${note.id}|Draft]]'));
      await finish(tester);
    });

    testWidgets('a failing save shows a message and keeps the text', (
      tester,
    ) async {
      final s = await app(tester, const Size(1300, 900));
      await tester.runAsync(() async {});
      var fail = true;
      final navigator = tester.element(find.byType(Navigator).first);
      showQuickCapture(
        navigator,
        s,
        persist: () async {
          if (fail) throw const FileSystemException('read-only');
        },
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('quick-capture-text')), 'keep me');
      final inbox = s.workspace.inbox.length;
      await tester.tap(find.byKey(const ValueKey('quick-capture-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('quick-capture-error')), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('quick-capture-text'))).controller!.text,
        'keep me',
      );
      fail = false;
      await tester.tap(find.byKey(const ValueKey('quick-capture-save')));
      await untilClosed(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('quick-capture')), findsNothing);
      expect(s.workspace.inbox.length, inbox + 1, reason: 'one item, not two');
      await finish(tester);
    });
  });
}
