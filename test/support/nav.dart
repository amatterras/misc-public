// Navigation for tests of the interface: the floating sidebar's items are
// found by key (`new-nav-<page>`), the same way a person uses them. In its
// compact form it shows icons only, so tests must not look for label text.
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// The destination names people (and older tests) use for each page.
const navLabels = {
  'mindmap': AppPage.canvas,
  'canvas': AppPage.canvas,
  'notes': AppPage.notes,
  'archive': AppPage.links,
  'links': AppPage.links,
  'calendar': AppPage.calendar,
  'safari': AppPage.browser,
  'browser': AppPage.browser,
  'ai': AppPage.ai,
};

/// Taps the sidebar item for [label] (a name from [navLabels]), bringing the
/// sidebar back first if it is hidden or tucked away in a narrow window.
Future<void> tapNav(WidgetTester tester, String label) async {
  final page = navLabels[label.toLowerCase()];
  if (page == null) throw ArgumentError('No sidebar item called "$label"');
  final item = find.byKey(ValueKey('new-nav-${page.name}'));
  if (item.evaluate().isEmpty) {
    for (final opener in const ['new-sidebar-show', 'new-sidebar-handle']) {
      final handle = find.byKey(ValueKey(opener));
      if (handle.evaluate().isNotEmpty) {
        await tester.tap(handle);
        await tester.pump(const Duration(milliseconds: 400));
        break;
      }
    }
  }
  expect(item, findsOneWidget, reason: 'the sidebar item for "$label"');
  await tester.tap(item);
}
