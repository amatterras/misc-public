import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:async';

import '../data/models/library_models.dart';
import '../data/models/task_models.dart';
import '../features/calendar/calendar_page.dart';
import '../features/canvas/canvas_page.dart';
import '../features/ai/ai_chat_page.dart';
import '../features/browser/browser_page.dart';
import '../features/capture/capture_dialog.dart';
import '../features/capture/capture_service.dart';
import '../features/notes/notes_page.dart';
import '../features/palette/app_switcher.dart';
import '../features/palette/command_palette.dart';
import '../features/library/library_page.dart';
import '../features/motivation/motivation_service.dart';
import '../features/settings/recovery_section.dart' show offerRecoveryCodeOnce;
import '../features/search/search_dialog.dart';
import '../features/settings/settings_dialog.dart';
import '../widgets/common.dart' show GhostIconButton;
import '../widgets/floating_layer.dart';
import '../new_ui/new_archive_page.dart';
import '../phone/phone_profile.dart';
import '../phone/phone_shell.dart';
import '../new_ui/new_sidebar.dart';
import 'interface_version.dart';
import 'page_host.dart';
import 'quote_footer.dart';
import 'page_windows.dart';
import 'app_state.dart';
import 'top_bar.dart';
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
      AppPage.canvas => CaptureDestination.canvas,
      AppPage.links => CaptureDestination.links,
      AppPage.browser || AppPage.ai => CaptureDestination.links,
    },
  );
}

/// Opens the command palette (every command and place, by typing).
Future<void> openCommandPalette(BuildContext context, AppState state) =>
    showCommandPalette(
      context,
      paletteCommands(
        state,
        quickAdd: (c) => openQuickAdd(c, state),
        search: (c) => showSearchDialog(c, state),
        settings: (c) => showSettingsDialog(c, state),
        appSwitcher: (c) => openAppSwitcher(c, state, floating: true),
      ),
    );

List<SwitcherAction> _switcherActions(AppState state) => switcherActions(
  state,
  quickAdd: (c) => openQuickAdd(c, state),
  search: (c) => showSearchDialog(c, state),
  palette: (c) => openCommandPalette(c, state),
);

/// Opens the app switcher as a panel, or straight away as a floating
/// window ([floating]).
Future<void> openAppSwitcher(
  BuildContext context,
  AppState state, {
  bool floating = false,
}) async {
  void float() => state.floating.show(
    appSwitcherWindow(state, () => _switcherActions(state)),
  );
  if (floating) return float();
  await showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      alignment: Alignment.topRight,
      insetPadding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
      child: SizedBox(
        width: 280,
        child: AppSwitcherGrid(
          state: state,
          actions: () => _switcherActions(state),
          closeAfter: true,
          onPopOut: () {
            Navigator.pop(context);
            float();
          },
        ),
      ),
    ),
  );
}

/// Main window layout: workspace on the left, sidebar on the right.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.state, this.motivation});

  final AppState state;
  final MotivationService? motivation;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // Keeps the pages (and what is typed in them) when the window crosses the
  // phone-width threshold and the layout around them changes.
  final _pagesKey = GlobalKey();
  late final MotivationService _motivation;

  // The shell's own focus, so Ctrl+N, Ctrl+K and the other shortcuts keep
  // working after a page that had the keyboard focus goes off screen.
  final _focus = FocusNode(debugLabel: 'shell');
  AppPage? _lastPage;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _motivation =
        widget.motivation ??
        MotivationService(
          greetingDismissed:
              state.settings.get<bool>('welcomeGreetingDismissed') ?? false,
          onGreetingDismissed: () =>
              state.settings.set('welcomeGreetingDismissed', true),
        );
    if (widget.motivation == null) unawaited(_loadMotivation());
    _lastPage = state.page;
    state.addListener(_pageChanged);
    // Once, after start-up: offer a recovery code (never blocks anything).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(seconds: 4));
      if (mounted) unawaited(offerRecoveryCodeOnce(context, state));
    });
  }

  /// A page that held the focus is hidden when another page opens, which
  /// drops the focus out to the route; take it back for the shell.
  void _pageChanged() {
    if (state.page == _lastPage) return;
    _lastPage = state.page;
    // Twice: the hidden page releases its focus during the frame after the
    // page changes.
    void reclaim() {
      if (!mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || primary is FocusScopeNode) _focus.requestFocus();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      reclaim();
      WidgetsBinding.instance.addPostFrameCallback((_) => reclaim());
    });
  }

  Future<void> _loadMotivation() async {
    try {
      await _motivation.load();
    } catch (error, stack) {
      debugPrint('Could not load motivational content: $error\n$stack');
    }
  }

  @override
  void dispose() {
    state.removeListener(_pageChanged);
    _focus.dispose();
    if (widget.motivation == null) _motivation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            openQuickAdd(context, state),
        // Global search stays on the keyboard and in the palette; there is
        // no search bar or button in the top bar or sidebar.
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showSearchDialog(context, state),
        const SingleActivator(
          LogicalKeyboardKey.keyP,
          control: true,
          shift: true,
        ): () =>
            openCommandPalette(context, state),
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
            state.windows.cycle(),
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            state.toggleImmersive(),
        // Page instances (the same actions as the page bar).
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
            state.closeActivePage(),
        const SingleActivator(
          LogicalKeyboardKey.keyN,
          control: true,
          shift: true,
        ): () =>
            state.newPage(AppPage.notes),
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          shift: true,
        ): () {
          final id = state.windows.activeId;
          if (id != null) state.windows.float(id);
        },
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: ListenableBuilder(
          listenable: Listenable.merge([state, state.windows]),
          builder: (context, _) {
            final width = MediaQuery.sizeOf(context).width;
            final isCompact = width < 640;
            // New interface on an iPhone: its own layout with Home.
            // The shell follows the device, the width only adapts it: an
            // iPhone always gets the phone layout (with Home); an iPad never
            // does, however narrow its window is.
            final isNew = state.interfaceVersion == InterfaceVersion.newDesign;
            final phone = PhoneProfile.active;
            final windows = state.windows;
            windows.titleOf ??= (p) => pageTitle(state, p);
            windows.builder ??= (context, p) =>
                buildPageInstance(context, state, p);
            final active = windows.active;
            // A destination moved into its own page window is not built
            // twice.
            Widget page(AppPage kind, Widget Function() build) =>
                windows.find(kind, null) != null
                ? const SizedBox.shrink()
                : build();

            final mainContent = Column(
              children: [
                TopBar(state: state),
                Expanded(
                  child: ClipRect(
                    child: Stack(
                      key: const ValueKey('page-content-viewport'),
                      fit: StackFit.expand,
                      children: [
                        Offstage(
                          offstage: active != null,
                          child: TickerMode(
                            enabled: active == null,
                            child: IndexedStack(
                              key: _pagesKey,
                              index: state.page.index,
                              children: [
                                page(
                                  AppPage.canvas,
                                  () => CanvasPage(state: state),
                                ),
                                page(
                                  AppPage.notes,
                                  () => NotesPage(state: state),
                                ),
                                page(
                                  AppPage.links,
                                  () =>
                                      state.interfaceVersion ==
                                          InterfaceVersion.newDesign
                                      ? NewArchivePage(state: state)
                                      : LibraryPage(state: state),
                                ),
                                page(
                                  AppPage.calendar,
                                  () => CalendarPage(state: state),
                                ),
                                // Tasks are shown inside Calendar (its task column).
                                const SizedBox.shrink(),
                                page(
                                  AppPage.browser,
                                  () => BrowserPage(state: state),
                                ),
                                page(
                                  AppPage.ai,
                                  () => AiChatPage(state: state),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // Pages in the bar that are not floating: the active
                        // one is shown; the others (and minimized ones) stay
                        // alive off screen without painting or animating.
                        for (final p in windows.all)
                          if (p.mode != PageMode.floating)
                            Offstage(
                              key: ValueKey('host-${p.id}'),
                              offstage: p.id != active?.id,
                              child: TickerMode(
                                enabled: p.id == active?.id,
                                child: windows.instanceHost(context, p),
                              ),
                            ),
                        // Floating page windows share this exact content
                        // viewport: below the page bar, above phone tabs,
                        // and to the left of the desktop sidebar.
                        FloatingLayer(windows: state.floating),
                      ],
                    ),
                  ),
                ),
                QuoteFooter(service: _motivation),
              ],
            );

            return Scaffold(
              backgroundColor: AppColors.background,
              body: Stack(
                children: [
                  if (phone)
                    SizedBox.expand(
                      child: PhoneShell(state: state, motivation: _motivation),
                    )
                  else if (isCompact && !isNew)
                    SafeArea(
                      bottom: false,
                      child: Column(
                        children: [
                          ListenableBuilder(
                            listenable: state.workspace.changes,
                            builder: (context, _) =>
                                _CompactTopBar(state: state),
                          ),
                          Expanded(child: mainContent),
                          ListenableBuilder(
                            listenable: state.workspace.changes,
                            builder: (context, _) =>
                                _CompactBottomNav(state: state),
                          ),
                        ],
                      ),
                    )
                  else if (isNew)
                    // New interface (Windows, iPad, any width): same pages,
                    // floating sidebar; narrow windows get its compact form.
                    SizedBox.expand(
                      child: NewSidebarLayout(state: state, child: mainContent),
                    )
                  else
                    Row(
                      children: [
                        Expanded(child: mainContent),
                        Sidebar(state: state),
                      ],
                    ),
                  _Toast(
                    state: state,
                    bottomOffset: (isCompact && !isNew) || phone ? 72 : 28,
                  ),
                  _TransferBar(
                    state: state,
                    bottomOffset: (isCompact && !isNew) || phone ? 120 : 76,
                  ),
                  // The phone shows the greeting itself, as a line on Today.
                  if (!phone)
                    ListenableBuilder(
                      listenable: _motivation,
                      builder: (context, _) => _motivation.greetingVisible
                          ? Positioned(
                              // Below the page bar (and the phone's own
                              // top bar), not on top of it.
                              top:
                                  TopBar.height +
                                  10 +
                                  ((isCompact && !isNew) || phone ? 48 : 0),
                              left: 16,
                              child: _GreetingWindow(service: _motivation),
                            )
                          : const SizedBox.shrink(),
                    ),
                  if (TestEnvironment.active) const _TestDataBanner(),
                  _UnsavedNotice(state: state),
                  _ReminderNotice(state: state),
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
      AppPage.canvas => state.canvas?.title ?? 'mindmap',
      AppPage.notes => 'notes',
      AppPage.links => 'archive',
      AppPage.calendar || AppPage.tasks => 'calendar',
      AppPage.browser => 'safari',
      AppPage.ai => 'ai',
    };

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: BoxDecoration(
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
              style: TextStyle(
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
                  color: state.syncing ? AppColors.accent : AppColors.success,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          const Spacer(),
          IconButton(
            icon: Icon(
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
            icon: Icon(
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
    const items = appDestinations;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.sidebar,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
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
                            Icon(
                              icon,
                              size: 22,
                              color: state.page == page
                                  ? AppColors.accent
                                  : AppColors.textMuted,
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
          ],
        ),
      ),
    );
  }
}

class _GreetingWindow extends StatefulWidget {
  const _GreetingWindow({required this.service});

  final MotivationService service;

  @override
  State<_GreetingWindow> createState() => _GreetingWindowState();
}

class _GreetingWindowState extends State<_GreetingWindow> {
  Offset _drag = Offset.zero;
  Offset _dismissDirection = Offset.zero;
  bool _dragging = false;
  bool _dismissing = false;
  Timer? _dismissTimer;

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  void _dragEnd(DragEndDetails details) {
    final travel = _drag.distance;
    if (travel >= 48) {
      final direction = _drag / travel;
      setState(() {
        _dragging = false;
        _dismissing = true;
        _dismissDirection = direction;
      });
      _dismissTimer = Timer(const Duration(milliseconds: 190), () {
        widget.service.dismissGreeting();
      });
    } else {
      setState(() {
        _dragging = false;
        _drag = Offset.zero;
      });
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: const ValueKey('greeting-window'),
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => setState(() => _dragging = true),
    onPanUpdate: (details) => setState(() => _drag += details.delta),
    onPanEnd: _dragEnd,
    onPanCancel: () => setState(() {
      _dragging = false;
      _drag = Offset.zero;
    }),
    child: AnimatedSlide(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
      offset: _dismissing
          ? _dismissDirection * 2.5
          : Offset(_drag.dx / 340, _drag.dy / 80),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 170),
        opacity: _dismissing ? 0 : (1 - (_drag.distance / 280)).clamp(0.35, 1),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Material(
            elevation: 12,
            color: AppColors.cardRaised,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 340,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                widget.service.greeting ?? '',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
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
            decoration: BoxDecoration(
              color: AppColors.danger,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(6)),
            ),
            child: Text(
              'TEST DATA — ${TestEnvironment.dataDir?.path ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Stays visible while some changes could not be written to disk (the app
/// keeps retrying), so a failing save is never silent.
class _UnsavedNotice extends StatelessWidget {
  const _UnsavedNotice({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: state.workspace.unsaved,
      builder: (context, unsaved, _) {
        if (unsaved.isEmpty) return const SizedBox.shrink();
        return Positioned(
          left: 0,
          right: 0,
          bottom: 72,
          child: Center(
            child: Container(
              key: const ValueKey('unsaved-notice'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.danger,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Some changes are not saved yet. misc. keeps retrying — '
                'keep the app open (details in the log).',
                style: TextStyle(fontSize: 13, color: AppColors.text),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Task reminders that came due (also ones missed while THEapp was closed).
/// They stay until opened or dismissed.
class _ReminderNotice extends StatelessWidget {
  const _ReminderNotice({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Task>>(
      valueListenable: state.dueReminders,
      builder: (context, due, _) {
        if (due.isEmpty) return const SizedBox.shrink();
        // Inside the workspace, never over the sidebar's own controls.
        final compact = MediaQuery.sizeOf(context).width < 640;
        final sidebar = compact
            ? 0.0
            : state.sidebarCollapsed
            ? Sidebar.collapsedWidth
            : Sidebar.expandedWidth;
        return Positioned(
          top: compact ? 56 : 28,
          right: sidebar + 16,
          child: Container(
            key: const ValueKey('reminders'),
            width: 320,
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(
              color: AppColors.cardRaised,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.accent),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  due.length == 1 ? 'Reminder' : '${due.length} reminders',
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
                for (final t in due.take(3))
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          state.dismissReminder(t.id);
                          state.openTask(t.id);
                        },
                        child: const Text('Open'),
                      ),
                      GhostIconButton(
                        icon: Icons.close,
                        tooltip: 'Dismiss reminder',
                        size: 14,
                        onTap: () => state.dismissReminder(t.id),
                      ),
                    ],
                  ),
                if (due.length > 3)
                  Text(
                    '+ ${due.length - 3} more',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
              ],
            ),
          ),
        );
      },
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

/// The result of the last drag-and-drop, with Undo, for a few seconds.
class _TransferBar extends StatelessWidget {
  const _TransferBar({required this.state, required this.bottomOffset});

  final AppState state;
  final double bottomOffset;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: state.lastTransfer,
    builder: (context, result, _) {
      if (result == null) return const SizedBox.shrink();
      return Positioned(
        left: 0,
        right: 0,
        bottom: bottomOffset,
        child: Center(
          // Never wider than the window: a long title shortens, Undo stays.
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width - 32,
            ),
            child: Material(
              key: const ValueKey('transfer-result'),
              color: AppColors.cardRaised,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        result.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (result.undo != null)
                      TextButton(
                        key: const ValueKey('transfer-undo'),
                        onPressed: state.undoLastTransfer,
                        child: const Text('Undo'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
