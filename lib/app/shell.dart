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
import '../features/settings/settings_dialog.dart';
import '../features/tasks/tasks_page.dart';
import 'app_state.dart';
import 'sidebar.dart';
import 'test_environment.dart';
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
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.state});

  final AppState state;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // Keeps the pages (and what is typed in them) when the window crosses the
  // phone-width threshold and the layout around them changes.
  final _pagesKey = GlobalKey();

  AppState get state => widget.state;

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
            final width = MediaQuery.sizeOf(context).width;
            final isCompact = width < 640;

            final mainContent = ClipRect(
              child: IndexedStack(
                key: _pagesKey,
                index: state.page.index,
                children: [
                  HomePage(state: state),
                  CanvasPage(state: state),
                  NotesPage(state: state),
                  CalendarPage(state: state),
                  TasksPage(state: state),
                ],
              ),
            );

            return Scaffold(
              backgroundColor: AppColors.background,
              body: Stack(
                children: [
                  if (isCompact)
                    SafeArea(
                      bottom: false,
                      child: Column(
                        children: [
                          _CompactTopBar(state: state),
                          Expanded(child: mainContent),
                          ListenableBuilder(
                            // The Inbox badge follows new captures.
                            listenable: state.workspace.changes,
                            builder: (context, _) =>
                                _CompactBottomNav(state: state),
                          ),
                        ],
                      ),
                    )
                  else
                    Row(
                      children: [
                        Expanded(child: mainContent),
                        Sidebar(state: state),
                      ],
                    ),
                  _Toast(state: state, bottomOffset: isCompact ? 72 : 28),
                  if (TestEnvironment.active) const _TestDataBanner(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CompactTopBar extends StatelessWidget {
  const _CompactTopBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final pageTitle = switch (state.page) {
      AppPage.home => 'Home',
      AppPage.canvas => state.canvas?.title ?? 'Canvas',
      AppPage.notes => 'Notes',
      AppPage.calendar => 'Calendar',
      AppPage.tasks => 'Tasks',
    };

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              pageTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.text,
              ),
            ),
          ),
          const SizedBox(width: Space.sm),
          if (state.syncPaired)
            Tooltip(
              message: state.syncStatus,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: state.syncing
                      ? OrganizerColors.blue
                      : OrganizerColors.green,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          const Spacer(),
          IconButton(
            icon: const Icon(
              Icons.search,
              size: 20,
              color: AppColors.textMuted,
            ),
            tooltip: 'Search',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            onPressed: () => showSearchDialog(context, state),
          ),
          IconButton(
            icon: const Icon(
              Icons.add_circle_outline,
              size: 22,
              color: AppColors.accent,
            ),
            tooltip: 'Quick Add',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            onPressed: () => openQuickAdd(context, state),
          ),
          IconButton(
            icon: const Icon(
              Icons.settings_outlined,
              size: 20,
              color: AppColors.textMuted,
            ),
            tooltip: 'Settings',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            onPressed: () => showSettingsDialog(context, state),
          ),
        ],
      ),
    );
  }
}

class _CompactBottomNav extends StatelessWidget {
  const _CompactBottomNav({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    const items = [
      (AppPage.home, Icons.home_outlined, 'Home'),
      (AppPage.canvas, Icons.grid_view, 'Canvas'),
      (AppPage.notes, Icons.description_outlined, 'Notes'),
      (AppPage.calendar, Icons.calendar_today_outlined, 'Calendar'),
      (AppPage.tasks, Icons.check_box_outlined, 'Tasks'),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 54,
          child: Row(
            children: [
              for (final (page, icon, label) in items)
                Expanded(
                  child: InkWell(
                    onTap: () => state.goTo(page),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Icon(
                              icon,
                              size: 22,
                              color: state.page == page
                                  ? AppColors.accent
                                  : AppColors.textMuted,
                            ),
                            if (page == AppPage.home &&
                                state.workspace.inbox.length > 0)
                              Positioned(
                                right: -8,
                                top: -4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: OrganizerColors.blue,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  constraints: const BoxConstraints(
                                    minWidth: 14,
                                  ),
                                  child: Text(
                                    '${state.workspace.inbox.length}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: state.page == page
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: state.page == page
                                ? AppColors.accent
                                : AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown on every page in test data mode, so test and real windows can't be
/// confused.
class _TestDataBanner extends StatelessWidget {
  const _TestDataBanner();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: const BoxDecoration(
              color: AppColors.danger,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(6)),
            ),
            child: Text(
              'TEST DATA — ${TestEnvironment.dataDir?.path ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.state, this.bottomOffset = 28});

  final AppState state;
  final double bottomOffset;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: state.toast,
      builder: (context, message, _) {
        return Positioned(
          left: 0,
          right: 0,
          bottom: bottomOffset,
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
