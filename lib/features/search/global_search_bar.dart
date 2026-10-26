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
import '../smartlinks/smart_links_ui.dart' show LinkBackButton;
import 'search_dialog.dart';

/// Height of the strip on every layout.
const globalSearchBarHeight = 54.0;

/// Wraps the app's navigator ([child]) with the search strip above it.
class GlobalSearchHost extends StatelessWidget {
  const GlobalSearchHost({
    super.key,
    required this.state,
    required this.navigatorKey,
    required this.child,
  });

  final AppState state;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  void _open() {
    final context = navigatorKey.currentContext;
    if (context != null) showSearchDialog(context, state);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _open,
      },
      child: Column(
        children: [
          Material(
            color: AppColors.background,
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
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: child,
            ),
          ),
        ],
      ),
    );
  }
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
                                    key: const ValueKey('global-search-bar-text'),
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
                                  )
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
