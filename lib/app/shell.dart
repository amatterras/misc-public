import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models/library_models.dart';
import '../features/calendar/calendar_page.dart';
import '../features/canvas/canvas_page.dart';
import '../features/capture/capture_dialog.dart';
import '../features/capture/capture_service.dart';
import '../features/home/home_page.dart';
import '../features/notes/notes_page.dart';
import '../features/search/search_dialog.dart';
import '../features/tasks/tasks_page.dart';
import 'app_state.dart';
import 'sidebar.dart';
import 'theme.dart';

/// Opens Quick Add, pre-filled when the clipboard holds a link or image.
Future<void> openQuickAdd(BuildContext context, AppState state) async {
  final clip = await state.capture.readClipboard();
  if (!context.mounted) return;
  final useClipboard =
      clip.url != null || clip.imageBytes != null || clip.imageFiles.isNotEmpty;
  await showCaptureDialog(
    context,
    state,
    initial: useClipboard
        ? ClipboardContent(
            text: clip.url,
            imageBytes: clip.imageBytes,
            imageExtension: clip.imageExtension,
            files: clip.files,
          )
        : null,
    destination: switch (state.page) {
      AppPage.notes => CaptureDestination.notes,
      AppPage.calendar => CaptureDestination.calendar,
      AppPage.tasks => CaptureDestination.task,
      AppPage.home => CaptureDestination.inbox,
      AppPage.canvas => CaptureDestination.canvas,
    },
  );
}

/// Main window layout: workspace on the left, sidebar on the right.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            openQuickAdd(context, state),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showSearchDialog(context, state),
      },
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            return Scaffold(
              backgroundColor: AppColors.background,
              body: Stack(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ClipRect(
                          child: IndexedStack(
                            index: state.page.index,
                            children: [
                              HomePage(state: state),
                              CanvasPage(state: state),
                              NotesPage(state: state),
                              CalendarPage(state: state),
                              TasksPage(state: state),
                            ],
                          ),
                        ),
                      ),
                      Sidebar(state: state),
                    ],
                  ),
                  _Toast(state: state),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: state.toast,
      builder: (context, message, _) {
        return Positioned(
          left: 0,
          right: 0,
          bottom: 28,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: message == null ? 0 : 1,
              duration: const Duration(milliseconds: 160),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.cardRaised,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Text(
                    message ?? '',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Keeps a widget in sync with the shared records.
class WorkspaceBuilder extends StatelessWidget {
  const WorkspaceBuilder({
    super.key,
    required this.state,
    required this.builder,
  });

  final AppState state;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state.workspace.changes,
    builder: (context, _) => builder(context),
  );
}

/// Convenience used by several pages.
List<Asset> assetsFor(AppState state, Iterable<String> ids) => [
  for (final id in ids)
    if (state.workspace.assets[id] != null) state.workspace.assets[id]!,
];
