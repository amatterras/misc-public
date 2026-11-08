// Navigation shared by every surface that moves between the main pages:
// the sidebar capsule, the page bar, the phone tabs and the command palette.
// One list of destinations and one meaning for "drop something on a
// destination", so no surface can drift from the others.
import 'package:flutter/material.dart';

import '../data/models/canvas_models.dart';
import '../data/models/record.dart' show dateOnly;
import '../features/transfer/transfer.dart';
import 'app_state.dart';

/// The six primary destinations, in this order. There is no Home page on
/// Windows/iPad; Tasks live in Calendar.
const appDestinations = [
  (AppPage.canvas, Icons.hub_outlined, 'mindmap'),
  (AppPage.notes, Icons.description_outlined, 'notes'),
  (AppPage.calendar, Icons.calendar_today_outlined, 'calendar'),
  (AppPage.links, Icons.bookmarks_outlined, 'archive'),
  (AppPage.browser, Icons.explore_outlined, 'safari'),
  (AppPage.ai, Icons.auto_awesome_outlined, 'ai'),
];

/// Wraps a navigation entry for [page] so things dropped on it land where
/// that page keeps them: notes → a new note, archive → the Archive board,
/// calendar → today, mindmap → the open mindmap. Other pages take no drops.
Widget navDropTarget(AppState state, AppPage page, Widget child) {
  final open = state.canvas;
  final DropPlace? place = switch (page) {
    AppPage.notes => const NewNotePlace(),
    AppPage.links => const CanvasPlace(linksBoardId),
    AppPage.calendar => DayPlace(dateOnly(DateTime.now())),
    AppPage.canvas when open != null => CanvasPlace(open.id),
    _ => null,
  };
  if (place == null) return child;
  return TransferTarget(
    key: ValueKey('drop-nav-${page.name}'),
    state: state,
    place: place,
    child: child,
  );
}

/// The room the earlier docked sidebar took on the right edge. Floating
/// notices still keep this clear (wide or narrow, following the saved
/// [AppState.sidebarCollapsed] setting), so they never sit under the
/// sidebar capsule.
abstract final class SidebarClearance {
  static const expanded = 272.0;
  static const collapsed = 60.0;
}
