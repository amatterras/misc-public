// The iPad frame: a slim rail of vertical words down the left edge, and the
// page beside it. The pages are the shared ones (Notes, Calendar, Archive,
// Mindmap, Safari, AI), untouched; the frame and Today are new. Words are
// read bottom to top, so the rail costs 60 pt of width instead of a menu.
//
// Pencil and multitasking: the rail is the only chrome the shell adds, pages
// keep every other pixel, and below 640 pt (Slide Over, a thin Split View)
// AppShell does not use this frame at all but the compact capsule.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../features/motivation/motivation_service.dart';
import '../features/search/search_dialog.dart';
import '../features/settings/settings_dialog.dart';
import '../new_ui/new_tokens.dart';
import '../phone/phone_capture.dart';
import '../phone/phone_more.dart' show PhoneTabKind;
import '../phone/phone_tokens.dart';
import '../phone/phone_widgets.dart';
import 'ipad_today.dart';

class IpadShell extends StatefulWidget {
  const IpadShell({
    super.key,
    required this.state,
    required this.motivation,
    required this.pages,
  });

  final AppState state;
  final MotivationService motivation;

  /// The shared page area built by AppShell (page bar and pages).
  final Widget pages;

  static const railWidth = 60.0;

  @override
  State<IpadShell> createState() => _IpadShellState();
}

class _IpadShellState extends State<IpadShell> {
  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    // Opens on Today once per run, then stays where you are.
    if (!s.homeOpenedOnce) {
      s.homeOpenedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) s.showHome();
      });
    }
  }

  static const _words = <(String, String, AppPage?)>[
    ('today', 'Today', null),
    ('notes', 'Notes', AppPage.notes),
    ('calendar', 'Calendar', AppPage.calendar),
    ('archive', 'Archive', AppPage.links),
    ('canvas', 'Mindmap', AppPage.canvas),
    ('browser', 'Safari', AppPage.browser),
    ('ai', 'AI', AppPage.ai),
  ];

  bool _isCurrent(String id, AppPage? page) {
    if (id == 'today') return s.homeActive;
    if (s.homeActive || s.windows.active != null) return false;
    final current = s.page == AppPage.tasks ? AppPage.calendar : s.page;
    return current == page;
  }

  PhoneTabKind get _kind {
    if (s.homeActive) return PhoneTabKind.today;
    return switch (s.page) {
      AppPage.notes => PhoneTabKind.notes,
      AppPage.links => PhoneTabKind.archive,
      AppPage.calendar || AppPage.tasks => PhoneTabKind.calendar,
      AppPage.canvas => PhoneTabKind.map,
      _ => PhoneTabKind.today,
    };
  }

  void _go(String id, AppPage? page) {
    HapticFeedback.selectionClick();
    if (id == 'today') {
      s.windows.showDestination();
      s.showHome();
    } else {
      s.goTo(page!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.windows]),
      builder: (context, _) {
        final home = s.homeActive;
        return ColoredBox(
          color: NewColors.background,
          child: Row(
            children: [
              _rail(context),
              Expanded(
                child: Stack(
                  children: [
                    Offstage(
                      offstage: home,
                      child: TickerMode(enabled: !home, child: widget.pages),
                    ),
                    if (home)
                      IpadToday(state: s, motivation: widget.motivation),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _rail(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      width: IpadShell.railWidth,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: NewColors.border.withValues(alpha: 0.7)),
        ),
      ),
      child: Column(
        children: [
          SizedBox(height: top + 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final (id, label, page) in _words)
                    _RailWord(
                      key: ValueKey('ipad-rail-$id'),
                      label: label,
                      active: _isCurrent(id, page),
                      onTap: () => _go(id, page),
                    ),
                ],
              ),
            ),
          ),
          GlyphButton(
            key: const ValueKey('ipad-rail-search'),
            icon: Icons.search_rounded,
            label: 'Search',
            onTap: () => showSearchDialog(context, s),
          ),
          GlyphButton(
            key: const ValueKey('ipad-rail-settings'),
            icon: Icons.tune_rounded,
            label: 'Settings',
            onTap: () => showSettingsDialog(context, s),
          ),
          const SizedBox(height: 6),
          Semantics(
            button: true,
            label: 'New',
            child: GestureDetector(
              key: const ValueKey('ipad-rail-new'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.lightImpact();
                showPhoneNew(context, s, _kind);
              },
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: NewColors.text,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.add_rounded,
                  size: 24,
                  color: NewColors.background,
                ),
              ),
            ),
          ),
          SizedBox(height: MediaQuery.paddingOf(context).bottom + 18),
        ],
      ),
    );
  }
}

/// One word on the rail, set sideways. The current one is in full ink with a
/// short rule against the left edge.
class _RailWord extends StatelessWidget {
  const _RailWord({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: active,
    label: label,
    child: Press(
      onTap: onTap,
      child: SizedBox(
        width: IpadShell.railWidth,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: RotatedBox(
                quarterTurns: 3,
                child: Text(
                  label,
                  maxLines: 1,
                  style: PhoneType.row.copyWith(
                    fontSize: 15,
                    letterSpacing: -0.2,
                    color: active ? NewColors.text : NewColors.textFaint,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              child: AnimatedContainer(
                duration: NewMotion.quick,
                width: 2.5,
                height: active ? 18 : 0,
                color: NewColors.text,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
