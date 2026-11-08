// The global search bar that stays: a slim strip above whatever route is
// showing (the shell, an open note, a mindmap window...), so search is
// reachable everywhere and never covers the page below it. It is the front
// of the same search the sidebar and Ctrl+K open (one results list, one
// index): the bar shows the current query, tapping it (or Ctrl+K) opens the
// search with that query still in place, and its clear button is the only
// thing besides the search field itself that forgets the query.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../new_ui/new_components.dart' show AtmosphereFrame, NewAtmosphere;
import '../../phone/phone_profile.dart';
import '../smartlinks/smart_links_ui.dart' show LinkBackButton;
import '../capture/quick_capture.dart';
import '../handoff/handoff_dialog.dart';
import 'search_dialog.dart';

/// Height of the strip on every layout.
const globalSearchBarHeight = 54.0;

/// Counts the full pages on the navigator (the shell, then notes opened as
/// their own page...). On a short screen the strip is only shown above those
/// extra pages, where the sidebar and its search are out of reach.
class SearchRouteObserver extends NavigatorObserver {
  final ValueNotifier<int> depth = ValueNotifier(0);

  void _set(int by) => WidgetsBinding.instance.addPostFrameCallback(
    (_) => depth.value = (depth.value + by).clamp(0, 1000),
  );

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _set(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _set(-1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _set(-1);
  }
}

/// Windows shorter than this (a phone held sideways) keep the strip off the
/// main shell, which has its own search in the sidebar.
const globalSearchShortHeight = 480.0;
final _alwaysDeep = ValueNotifier<int>(2);

/// Wraps the app's navigator ([child]) with the search strip above it.
class GlobalSearchHost extends StatelessWidget {
  const GlobalSearchHost({
    super.key,
    required this.state,
    required this.navigatorKey,
    required this.child,
    this.routes,
  });

  final SearchRouteObserver? routes;

  final AppState state;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  void _open() {
    final context = navigatorKey.currentContext;
    if (context != null) showSearchDialog(context, state);
  }

  void _continue() {
    final context = navigatorKey.currentContext;
    if (context != null) showContinueDialog(context, state);
  }

  void _capture() {
    final context = navigatorKey.currentContext;
    if (context != null) showQuickCapture(context, state);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _open,
        const SingleActivator(
          LogicalKeyboardKey.space,
          control: true,
          shift: true,
        ): _capture,
      },
      child: ValueListenableBuilder<int>(
        valueListenable: routes?.depth ?? _alwaysDeep,
        builder: (context, depth, _) {
          // Short windows and the iPhone layout have their own search on
          // the main shell; there the strip only shows above pages opened
          // over it (a note on its own page), where that search is out of
          // reach.
          final ownSearch =
              media.size.height < globalSearchShortHeight ||
              PhoneProfile.active;
          final show = !(ownSearch && depth <= 1);
          final stripHeight = show
              ? media.padding.top + globalSearchBarHeight
              : 0.0;
          // One window-wide atmosphere: the strip paints its top slice,
          // the pages below paint theirs (see AtmosphereFrame).
          return AtmosphereFrame(
            window: media.size,
            top: stripHeight,
            child: Column(
              children: [
                // The same slot whether shown or not, so showing it never
                // rebuilds the pages below.
                SizedBox(
                  height: stripHeight,
                  child: show
                      ? AtmosphereFrame(
                          window: media.size,
                          top: 0,
                          child: _strip(),
                        )
                      : null,
                ),
                Expanded(
                  child: MediaQuery.removePadding(
                    context: context,
                    // The strip took the status bar / notch; when it is
                    // hidden the page keeps that padding itself.
                    removeTop: show,
                    child: child,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _strip() => NewAtmosphere.behind(
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Material(
        type: MaterialType.transparency,
        // Below the status bar / notch; the page under it then does not
        // add that space a second time.
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: globalSearchBarHeight,
            child: Row(
              children: [
                LinkBackButton(state: state),
                Expanded(
                  child: GlobalSearchBar(state: state, onOpen: _open),
                ),
                // (no tooltip: this strip sits above the app's Overlay)
                Semantics(
                  button: true,
                  label: 'Quick capture (Ctrl+Shift+Space)',
                  child: IconButton(
                    key: const ValueKey('quick-capture-button'),
                    icon: Icon(
                      Icons.bolt,
                      size: 22,
                      color: AppColors.textMuted,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    onPressed: _capture,
                  ),
                ),
                if (state.syncPaired)
                  Semantics(
                    button: true,
                    label: 'Continue on this device',
                    child: IconButton(
                      key: const ValueKey('continue-button'),
                      icon: Icon(
                        Icons.devices_other,
                        size: 22,
                        color: AppColors.textMuted,
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      onPressed: _continue,
                    ),
                  ),
                const SizedBox(width: AppSpace.xs),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The bar itself. Wide windows get a roomy field at the right-hand side;
/// narrow ones (iPhone, a squeezed window) a compact button that shows
/// the query it holds.
class GlobalSearchBar extends StatelessWidget {
  const GlobalSearchBar({super.key, required this.state, required this.onOpen});

  final AppState state;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxWidth < 640;
        final fieldWidth = compact
            ? (box.maxWidth - 24).clamp(44.0, 220.0)
            : (box.maxWidth * 0.36).clamp(380.0, 600.0);
        return Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.only(right: compact ? 8 : 16),
            child: ValueListenableBuilder<String>(
              valueListenable: state.searchQuery,
              builder: (context, query, _) {
                final hasQuery = query.trim().isNotEmpty;
                final iconOnly = compact && !hasQuery;
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: iconOnly ? 48 : fieldWidth,
                    maxWidth: iconOnly ? 48 : fieldWidth,
                    minHeight: 44,
                  ),
                  child: Semantics(
                    button: true,
                    label: hasQuery ? 'Search: $query' : 'Search',
                    hint: 'Search everything (Ctrl+K)',
                    child: ExcludeSemantics(
                      // (no Tooltip: this bar sits above the app's Overlay)
                      child: InkWell(
                        key: const ValueKey('global-search-bar'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: onOpen,
                        child: Container(
                          height: 44,
                          padding: EdgeInsets.symmetric(
                            horizontal: iconOnly ? 0 : 14,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.cardRaised,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Row(
                            mainAxisAlignment: iconOnly
                                ? MainAxisAlignment.center
                                : MainAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.search,
                                size: 22,
                                color: AppColors.textMuted,
                              ),
                              if (!iconOnly) ...[
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    hasQuery ? query : 'Search everything',
                                    key: const ValueKey(
                                      'global-search-bar-text',
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 15.5,
                                      color: hasQuery
                                          ? AppColors.text
                                          : AppColors.textFaint,
                                    ),
                                  ),
                                ),
                                if (hasQuery)
                                  InkResponse(
                                    key: const ValueKey('global-search-clear'),
                                    radius: 20,
                                    onTap: () => state.searchQuery.value = '',
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Icon(
                                        Icons.close,
                                        size: 20,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
