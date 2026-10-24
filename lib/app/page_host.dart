// The live page for each page instance (see page_windows.dart): the same
// page widgets as the main area, for a particular note, mindmap, Safari
// window or AI conversation, or for a destination moved into a window.
import 'dart:async';

import 'package:flutter/material.dart';

import '../features/ai/ai_chat_page.dart';
import '../features/browser/browser_page.dart';
import '../features/calendar/calendar_page.dart';
import '../features/canvas/canvas_controller.dart';
import '../features/canvas/canvas_page.dart';
import '../features/home/home_page.dart';
import '../features/links/archive_library_page.dart';
import '../features/links/links_page.dart';
import '../features/notes/note_page.dart';
import '../features/notes/notes_page.dart';
import 'app_state.dart';
import 'page_windows.dart';
import 'theme.dart';

Widget buildPageInstance(BuildContext context, AppState s, PageInstance p) =>
    switch (p.kind) {
      AppPage.canvas when p.refId != null => MindmapWindow(
        key: ValueKey('mindmap-${p.refId}'),
        state: s,
        canvasId: p.refId!,
      ),
      AppPage.notes when p.refId != null => NotePage(
        state: s,
        noteId: p.refId!,
      ),
      AppPage.ai => AiChatPage(
        state: s,
        session: s.aiSessionFor(p),
        instanceId: p.id,
      ),
      AppPage.browser => BrowserPage(
        state: s,
        browser: s.browserFor(p),
        instanceId: p.id,
      ),
      AppPage.canvas => MindmapWindow(state: s, canvasId: s.canvas?.id ?? ''),
      AppPage.notes => NotesPage(state: s),
      // Its own view (view, filters, selected day) of the same records.
      AppPage.calendar || AppPage.tasks when p.refId != null => CalendarPage(
        state: s,
        viewKey: 'calendarView.${p.id}',
      ),
      AppPage.calendar || AppPage.tasks => CalendarPage(state: s),
      AppPage.links when p.refId != null => Material(
        color: AppColors.background,
        child: ArchiveLibrary(
          state: s,
          embedded: true,
          initialFolder: p.refId!.startsWith('folder:')
              ? p.refId!.substring(7)
              : null,
          initialSelected: p.refId!.startsWith('res:')
              ? p.refId!.substring(4)
              : null,
        ),
      ),
      AppPage.links => LinksPage(state: s),
      AppPage.home => HomePage(state: s),
    };

/// A mindmap in its own window. Shares the document's controller with any
/// other view of the same mindmap (AppState.acquireCanvas).
class MindmapWindow extends StatefulWidget {
  const MindmapWindow({super.key, required this.state, required this.canvasId});

  final AppState state;
  final String canvasId;

  @override
  State<MindmapWindow> createState() => _MindmapWindowState();
}

class _MindmapWindowState extends State<MindmapWindow> {
  CanvasController? _c;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final c = await widget.state.acquireCanvas(widget.canvasId);
    if (!mounted) {
      if (c != null) unawaited(widget.state.releaseCanvas(widget.canvasId));
      return;
    }
    setState(() {
      _c = c;
      _missing = c == null;
    });
  }

  @override
  void dispose() {
    if (_c != null) unawaited(widget.state.releaseCanvas(widget.canvasId));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_missing) {
      return const Center(
        child: Text(
          'This mindmap no longer exists.',
          style: TextStyle(color: AppColors.textFaint),
        ),
      );
    }
    if (c == null) return const Center(child: CircularProgressIndicator());
    return CanvasView(controller: c, state: widget.state);
  }
}
