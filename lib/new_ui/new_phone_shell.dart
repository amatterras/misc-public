// The New interface on iPhone: a separate mobile layout, not the desktop
// sidebar. Five icon-only destinations at the bottom (Home, Mindmap, Notes,
// Calendar, Archive); Safari and AI stay reachable from the menu in the top
// bar. Home exists only here. The pages themselves are the shared page area
// built by AppShell, kept alive (not rebuilt) while Home is shown.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/shell.dart'
    show openAppSwitcher, openCommandPalette, openQuickAdd;
import '../app/quote_footer.dart';
import '../app/sidebar.dart' show appDestinations;
import '../features/motivation/motivation_service.dart';
import '../app/top_bar.dart' show pageLabel;
import '../features/search/search_dialog.dart';
import '../features/settings/settings_dialog.dart';
import 'new_home.dart';
import 'new_tokens.dart';

/// Bottom navigation order on the phone (after Home).
const phoneDestinations = [
  AppPage.canvas, // Mindmap
  AppPage.notes,
  AppPage.calendar,
  AppPage.links, // Archive
];

class NewPhoneShell extends StatefulWidget {
  const NewPhoneShell({
    super.key,
    required this.state,
    required this.pages,
    required this.motivation,
  });

  final AppState state;

  /// The quote shown quietly in the bottom-right corner.
  final MotivationService motivation;

  /// The shared page area (page bar + the pages) from AppShell.
  final Widget pages;

  @override
  State<NewPhoneShell> createState() => _NewPhoneShellState();
}

class _NewPhoneShellState extends State<NewPhoneShell> {
  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    // The phone opens on Home once per run; later it stays where you are.
    if (!s.homeOpenedOnce) {
      s.homeOpenedOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) s.showHome();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final home = s.homeActive;
    return ColoredBox(
      color: NewColors.background,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Offstage(
                  offstage: home,
                  child: TickerMode(
                    enabled: !home,
                    child: Column(
                      children: [
                        SafeArea(bottom: false, child: _PhoneBar(state: s)),
                        Expanded(child: widget.pages),
                      ],
                    ),
                  ),
                ),
                if (home)
                  SafeArea(
                    bottom: false,
                    child: Column(
                      children: [
                        Expanded(
                          child: NewHome(
                            key: const ValueKey('new-home'),
                            state: s,
                          ),
                        ),
                        QuoteFooter(service: widget.motivation),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          _BottomNav(state: s),
        ],
      ),
    );
  }
}

/// Title and the secondary navigation (Safari, AI, commands, settings).
class _PhoneBar extends StatelessWidget {
  const _PhoneBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final page = state.page == AppPage.tasks ? AppPage.calendar : state.page;
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: NewSpace.lg, right: NewSpace.xs),
      decoration: BoxDecoration(
        color: NewColors.background,
        border: Border(bottom: BorderSide(color: NewColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              pageLabel(page),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NewText.title.copyWith(color: NewColors.text),
            ),
          ),
          IconButton(
            key: const ValueKey('phone-search'),
            tooltip: 'Search',
            icon: Icon(Icons.search, color: NewColors.textMuted),
            onPressed: () => showSearchDialog(context, state),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('phone-more'),
            tooltip: 'More',
            icon: Icon(Icons.more_horiz, color: NewColors.textMuted),
            color: NewColors.surfaceRaised,
            onSelected: (v) {
              switch (v) {
                case 'safari':
                  state.goTo(AppPage.browser);
                case 'ai':
                  state.goTo(AppPage.ai);
                case 'quick':
                  openQuickAdd(context, state);
                case 'commands':
                  openCommandPalette(context, state);
                case 'switcher':
                  openAppSwitcher(context, state);
                case 'settings':
                  showSettingsDialog(context, state);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'safari',
                child: _MenuRow(Icons.explore_outlined, 'Safari'),
              ),
              PopupMenuItem(
                value: 'ai',
                child: _MenuRow(Icons.auto_awesome_outlined, 'AI'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'quick',
                child: _MenuRow(Icons.add_circle_outline, 'Quick Add'),
              ),
              PopupMenuItem(
                value: 'commands',
                child: _MenuRow(Icons.keyboard_command_key, 'Commands'),
              ),
              PopupMenuItem(
                value: 'switcher',
                child: _MenuRow(Icons.apps, 'App switcher'),
              ),
              PopupMenuItem(
                value: 'settings',
                child: _MenuRow(Icons.settings_outlined, 'Settings'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20, color: NewColors.textMuted),
      const SizedBox(width: NewSpace.md),
      Text(label, style: TextStyle(color: NewColors.text)),
    ],
  );
}

/// Icons only; the selected one is tinted with a small marker under it.
class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.state});

  final AppState state;

  Widget _item(
    String key,
    IconData icon,
    String label,
    bool active,
    VoidCallback onTap,
  ) => Expanded(
    child: Semantics(
      button: true,
      selected: active,
      label: label,
      child: InkResponse(
        key: ValueKey(key),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: SizedBox(
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 24,
                color: active ? NewColors.accent : NewColors.textMuted,
              ),
              const SizedBox(height: 4),
              AnimatedContainer(
                duration: NewMotion.quick,
                width: active ? 14 : 0,
                height: 3,
                decoration: BoxDecoration(
                  gradient: NewGradients.brand,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final current = state.page == AppPage.tasks ? AppPage.calendar : state.page;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: NewColors.surface,
        border: Border(top: BorderSide(color: NewColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _item(
              'phone-nav-home',
              state.homeActive ? Icons.home_rounded : Icons.home_outlined,
              'Home',
              state.homeActive,
              state.showHome,
            ),
            for (final page in phoneDestinations)
              _item(
                'phone-nav-${page.name}',
                appDestinations.firstWhere((d) => d.$1 == page).$2,
                appDestinations.firstWhere((d) => d.$1 == page).$3,
                !state.homeActive && current == page,
                () => state.goTo(page),
              ),
          ],
        ),
      ),
    );
  }
}
