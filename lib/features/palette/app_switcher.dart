// The app switcher: a small grid of THEapp's places and quick actions. It
// opens as a panel and can be popped out into a floating window (dragged,
// resized, remembered on this device) that stays open while you work.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/floating_windows.dart';
import '../../app/theme.dart';

class SwitcherAction {
  const SwitcherAction(this.label, this.icon, this.run, {this.active = false});
  final String label;
  final IconData icon;
  final void Function(BuildContext context) run;
  final bool active;
}

List<SwitcherAction> switcherActions(
  AppState s, {
  required void Function(BuildContext) quickAdd,
  required void Function(BuildContext) search,
  required void Function(BuildContext) palette,
}) => [
  SwitcherAction(
    'mindmap',
    Icons.hub_outlined,
    (_) => s.goTo(AppPage.canvas),
    active: s.page == AppPage.canvas,
  ),
  SwitcherAction(
    'notes',
    Icons.description_outlined,
    (_) => s.goTo(AppPage.notes),
    active: s.page == AppPage.notes,
  ),
  SwitcherAction(
    'calendar',
    Icons.calendar_today_outlined,
    (_) => s.goTo(AppPage.calendar),
    active: s.page == AppPage.calendar && !s.calendarTasksOpen,
  ),
  SwitcherAction(
    'tasks',
    Icons.checklist,
    (_) => s.goTo(AppPage.tasks),
    active: s.page == AppPage.calendar && s.calendarTasksOpen,
  ),
  SwitcherAction(
    'archive',
    Icons.bookmarks_outlined,
    (_) => s.goTo(AppPage.links),
    active: s.page == AppPage.links,
  ),
  SwitcherAction('add', Icons.add_circle_outline, quickAdd),
  SwitcherAction('search', Icons.search, search),
  SwitcherAction('commands', Icons.keyboard_command_key, palette),
];

class AppSwitcherGrid extends StatelessWidget {
  const AppSwitcherGrid({
    super.key,
    required this.state,
    required this.actions,
    this.onPopOut,
    this.closeAfter = false,
  });

  final AppState state;
  final List<SwitcherAction> Function() actions;
  final VoidCallback? onPopOut;

  /// Close the surrounding dialog after choosing (not when floating).
  final bool closeAfter;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final list = actions();
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: GridView.count(
              key: const ValueKey('app-switcher-grid'),
              crossAxisCount: 3,
              shrinkWrap: true,
              padding: const EdgeInsets.all(Space.sm),
              children: [
                for (final a in list)
                  InkWell(
                    key: ValueKey('switch-${a.label}'),
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    onTap: () {
                      final nav = Navigator.of(context);
                      if (closeAfter) nav.pop();
                      a.run(closeAfter ? nav.context : context);
                    },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          a.icon,
                          size: 22,
                          color: a.active
                              ? AppColors.accent
                              : AppColors.textMuted,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          a.label,
                          style: TextStyle(
                            fontSize: AppType.sizeMeta,
                            color: a.active
                                ? AppColors.accent
                                : AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (onPopOut != null)
            TextButton.icon(
              key: const ValueKey('app-switcher-pop-out'),
              onPressed: onPopOut,
              icon: const Icon(Icons.open_in_new, size: 15),
              label: const Text('Keep it floating'),
            ),
        ],
      );
    },
  );
}

const appSwitcherWindowId = 'app-switcher';

/// The floating version of the switcher.
FloatingWindowSpec appSwitcherWindow(
  AppState state,
  List<SwitcherAction> Function() actions,
) => FloatingWindowSpec(
  id: appSwitcherWindowId,
  title: 'Switch',
  initialRect: const Rect.fromLTWH(24, 80, 250, 290),
  minSize: const Size(200, 200),
  builder: (_) => AppSwitcherGrid(state: state, actions: actions),
);
