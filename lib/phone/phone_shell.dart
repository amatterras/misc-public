// The iPhone interface's frame: five places and one "+", set along the bottom
// as words rather than icons. The places are phone screens (Today, Notes,
// Calendar, Archive) and the existing canvas under a slim bar (Mindmap). Safari
// and AI, and any page instance opened from elsewhere, take the whole screen
// with a Back arrow.
//
// The shell never owns data. It listens to AppState (which place is current,
// something asked to open a note or a task) and shows the matching screen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/page_windows.dart' show PageInstance;
import '../features/ai/ai_chat_page.dart';
import '../features/browser/browser_page.dart';
import '../features/motivation/motivation_service.dart';
import '../features/notes/note_page.dart' show openNotePage;
import '../new_ui/new_components.dart' show BrandPlus;
import '../app/theme.dart';
import 'phone_archive.dart';
import 'phone_calendar.dart';
import 'phone_capture.dart';
import 'phone_map.dart';
import 'phone_more.dart' show PhoneTabKind;
import 'phone_notes.dart';
import 'phone_task.dart';
import 'phone_today.dart';
import 'phone_tokens.dart';
import 'phone_widgets.dart';

class PhoneShell extends StatefulWidget {
  const PhoneShell({super.key, required this.state, required this.motivation});

  final AppState state;
  final MotivationService motivation;

  @override
  State<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends State<PhoneShell> {
  AppState get s => widget.state;

  /// Places that have been shown once stay alive (their scroll position and
  /// what is typed in them are kept); the others are not built at all.
  final _built = <PhoneTabKind>{PhoneTabKind.today};
  bool _browserBuilt = false;
  bool _aiBuilt = false;
  PhoneTabKind _lastTab = PhoneTabKind.today;

  @override
  void initState() {
    super.initState();
    // The phone opens on Today once per run; later it stays where you are.
    if (!s.homeOpenedOnce) {
      s.homeOpenedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) s.showHome();
      });
    }
    s.addListener(_requests);
    WidgetsBinding.instance.addPostFrameCallback((_) => _requests());
  }

  @override
  void dispose() {
    s.removeListener(_requests);
    super.dispose();
  }

  /// Other parts of the app ask for a note or a task by setting a field on
  /// AppState and moving to its page. The desktop pages read the field; here
  /// the shell opens the matching phone page instead.
  void _requests() {
    final note = s.selectedNoteId;
    final task = s.selectedTaskId;
    if (note == null && task == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final noteNow = s.selectedNoteId;
      final taskNow = s.selectedTaskId;
      if (noteNow != null && s.page == AppPage.notes) {
        s.selectedNoteId = null;
        if (s.workspace.notes[noteNow] != null) {
          openNotePage(context, s, noteNow);
        }
      } else if (taskNow != null) {
        s.selectedTaskId = null;
        openPhoneTask(context, s, taskNow);
      }
    });
  }

  PhoneTabKind? _tabOf() {
    if (s.homeActive) return PhoneTabKind.today;
    return switch (s.page) {
      AppPage.canvas => PhoneTabKind.map,
      AppPage.notes => PhoneTabKind.notes,
      AppPage.links => PhoneTabKind.archive,
      AppPage.calendar || AppPage.tasks => PhoneTabKind.calendar,
      AppPage.browser || AppPage.ai => null,
    };
  }

  void _go(PhoneTabKind tab) {
    switch (tab) {
      case PhoneTabKind.today:
        s.windows.showDestination();
        s.showHome();
      case PhoneTabKind.notes:
        s.goTo(AppPage.notes);
      case PhoneTabKind.calendar:
        s.goTo(AppPage.calendar);
      case PhoneTabKind.archive:
        s.goTo(AppPage.links);
      case PhoneTabKind.map:
        s.goTo(AppPage.canvas);
    }
  }

  void _leaveTool() {
    s.windows.showDestination();
    if (s.page == AppPage.browser || s.page == AppPage.ai) _go(_lastTab);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.windows]),
      builder: (context, _) {
        final active = s.windows.active;
        final tab = _tabOf();
        final toolPage =
            active == null &&
            !s.homeActive &&
            (s.page == AppPage.browser || s.page == AppPage.ai);
        final tool = active != null || toolPage;
        if (!tool && tab != null) {
          _built.add(tab);
          _lastTab = tab;
        }
        if (toolPage && s.page == AppPage.browser) _browserBuilt = true;
        if (toolPage && s.page == AppPage.ai) _aiBuilt = true;

        final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
        final current = tab ?? _lastTab;

        Widget place(PhoneTabKind kind, Widget Function() build) => Offstage(
          offstage: tool || current != kind,
          child: TickerMode(
            enabled: !tool && current == kind,
            child: _built.contains(kind) ? build() : const SizedBox.shrink(),
          ),
        );

        // Transparent: the shell's app-wide atmosphere shows through.
        return ColoredBox(
          color: Colors.transparent,
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        place(
                          PhoneTabKind.today,
                          () => PhoneToday(
                            state: s,
                            motivation: widget.motivation,
                          ),
                        ),
                        place(PhoneTabKind.notes, () => PhoneNotes(state: s)),
                        place(
                          PhoneTabKind.calendar,
                          () => PhoneCalendar(state: s),
                        ),
                        place(
                          PhoneTabKind.archive,
                          () => PhoneArchive(state: s),
                        ),
                        place(PhoneTabKind.map, () => PhoneMap(state: s)),
                      ],
                    ),
                  ),
                  if (!keyboard && !tool)
                    PhoneDock(
                      current: current,
                      onTab: _go,
                      onNew: () => showPhoneNew(context, s, current),
                    ),
                ],
              ),
              if (_browserBuilt || _aiBuilt || active != null)
                _toolLayer(active, toolPage),
            ],
          ),
        );
      },
    );
  }

  /// Safari, AI and page instances: the whole screen, a Back arrow on top.
  Widget _toolLayer(PageInstance? active, bool toolPage) {
    final showing = active != null || toolPage;
    final title = active != null
        ? (active.title.isEmpty ? 'Page' : active.title)
        : s.page == AppPage.ai
        ? 'AI'
        : 'Safari';
    return Positioned.fill(
      child: Offstage(
        offstage: !showing,
        child: TickerMode(
          enabled: showing,
          child: ColoredBox(
            color: AppColors.background,
            child: Column(
              children: [
                Container(
                  padding: EdgeInsets.only(
                    top: MediaQuery.paddingOf(context).top,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: AppColors.border.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  child: SizedBox(
                    height: 52,
                    child: Row(
                      children: [
                        GlyphButton(
                          key: const ValueKey('phone-tool-back'),
                          icon: Icons.arrow_back_ios_new_rounded,
                          label: 'Back',
                          size: 19,
                          color: AppColors.text,
                          onTap: _leaveTool,
                        ),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: PhoneType.row,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_browserBuilt)
                        Offstage(
                          offstage: active != null || s.page != AppPage.browser,
                          child: BrowserPage(state: s),
                        ),
                      if (_aiBuilt)
                        Offstage(
                          offstage: active != null || s.page != AppPage.ai,
                          child: AiChatPage(state: s),
                        ),
                      if (active != null)
                        s.windows.instanceHost(context, active),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The bottom row: five words and a "+". The current place is in full ink with
/// a short rule under it; the others are faint.
class PhoneDock extends StatelessWidget {
  const PhoneDock({
    super.key,
    required this.current,
    required this.onTab,
    required this.onNew,
  });

  final PhoneTabKind current;
  final ValueChanged<PhoneTabKind> onTab;
  final VoidCallback onNew;

  static const _labels = <(PhoneTabKind, String)>[
    (PhoneTabKind.today, 'Today'),
    (PhoneTabKind.notes, 'Notes'),
    (PhoneTabKind.calendar, 'Calendar'),
    (PhoneTabKind.archive, 'Archive'),
    (PhoneTabKind.map, 'Mindmap'),
  ];

  @override
  Widget build(BuildContext context) {
    // Mostly page-coloured so labels stay crisp over scrolling content, but
    // a little of the atmosphere still reads through, so the field is
    // unbroken down to the bottom edge.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.86),
        border: Border(
          top: BorderSide(color: AppColors.border.withValues(alpha: 0.8)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: PhoneSpace.dockHeight,
          child: Row(
            children: [
              const SizedBox(width: 6),
              for (final (tab, label) in _labels)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: tab == current,
                    label: label,
                    child: GestureDetector(
                      key: ValueKey('phone-tab-${tab.name}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (tab != current) HapticFeedback.selectionClick();
                        onTab(tab);
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            style: PhoneType.dock.copyWith(
                              color: tab == current
                                  ? AppColors.text
                                  : AppColors.textFaint,
                            ),
                          ),
                          const SizedBox(height: 6),
                          AnimatedContainer(
                            duration: AppMotion.quick,
                            height: 2,
                            width: tab == current ? 14 : 0,
                            color: AppColors.text,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Semantics(
                button: true,
                label: 'New',
                child: GestureDetector(
                  key: const ValueKey('phone-new'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onNew();
                  },
                  child: SizedBox(
                    width: 62,
                    height: PhoneSpace.dockHeight,
                    child: Center(
                      // The same "+" as Quick Add on iPad and Windows.
                      child: BrandPlus(),
                    ),
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
