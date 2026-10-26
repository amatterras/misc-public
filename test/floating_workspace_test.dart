// The adaptive floating workspace: windows stay reachable after the area
// shrinks, stick to edges when close, can be restored to a usable
// arrangement, and come back (places, sizes, stacking) after a restart. Each
// device keeps its own layout.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/floating_windows.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/storage/json_file_store.dart';
import 'package:flutter_application_1/widgets/floating_layer.dart';
import 'package:flutter_test/flutter_test.dart';

FloatingWindowSpec spec(String id, {Rect? rect}) => FloatingWindowSpec(
  id: id,
  title: 'Window $id',
  builder: (_) => Container(key: ValueKey('content-$id'), color: Colors.blueGrey),
  initialRect: rect ?? const Rect.fromLTWH(80, 80, 300, 240),
);

/// Settings kept in memory: no files, but a second SettingsRepository on
/// the same store sees what the first one saved (a restart).
class MemoryStore extends JsonFileStore {
  MemoryStore() : super(Directory.systemTemp);
  final data = <String, Map<String, dynamic>>{};

  @override
  Future<void> write(String collection, String id, Map<String, dynamic> json) async {
    data['$collection/$id'] = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>?> read(String collection, String id) async =>
      data['$collection/$id'];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final stores = <String, MemoryStore>{};

  Future<SettingsRepository> settings([String name = 'a']) async {
    final repo = SettingsRepository(stores.putIfAbsent(name, MemoryStore.new));
    await repo.load();
    return repo;
  }

  setUp(stores.clear);

  group('snapping', () {
    const area = Size(800, 600);

    test('edges stick to the area edge and to other windows when close', () {
      // 6 px from the left and 4 px from the top: flush.
      var r = FloatingWindows.snap(
        const Rect.fromLTWH(6, 4, 300, 200),
        area,
        const [],
      );
      expect(r, const Rect.fromLTWH(0, 0, 300, 200));
      // Right edge 5 px short of the area's right edge.
      r = FloatingWindows.snap(
        const Rect.fromLTWH(495, 100, 300, 200),
        area,
        const [],
      );
      expect(r.right, 800);
      expect(r.width, 300);
      // Lines up with another window's right edge (and its top).
      r = FloatingWindows.snap(
        const Rect.fromLTWH(309, 52, 200, 200),
        area,
        const [Rect.fromLTWH(10, 50, 300, 120)],
      );
      expect(r.left, 310);
      expect(r.top, 50);
    });

    test('far from everything nothing moves; sizes never change', () {
      const r = Rect.fromLTWH(200.5, 150.25, 333, 222);
      expect(FloatingWindows.snap(r, area, const [Rect.fromLTWH(600, 400, 50, 50)]), r);
    });
  });

  group('staying reachable', () {
    test('after the area shrinks the window is pulled fully inside', () {
      const saved = Rect.fromLTWH(1500, 900, 600, 400);
      const small = Size(800, 600);
      final fitted = FloatingWindows.fit(saved, small, const Size(220, 140));
      expect(fitted.left, greaterThanOrEqualTo(0));
      expect(fitted.top, greaterThanOrEqualTo(0));
      expect(fitted.right, lessThanOrEqualTo(800));
      expect(fitted.bottom, lessThanOrEqualTo(600));
      // Even a window bigger than the area keeps its title bar on screen.
      final huge = FloatingWindows.fit(
        const Rect.fromLTWH(-300, -50, 2000, 2000),
        small,
        const Size(220, 140),
      );
      expect(huge.topLeft, Offset.zero);
      expect(huge.size, small);
    });

    test('damaged saved places fall back to the default', () async {
      final repo = await settings();
      await repo.set('floatingWindows', {
        'w1': ['x', 1, 2, 3],
        'w2': [1, 2, 3],
        'w3': 'nope',
      });
      final w = FloatingWindows(repo);
      for (final id in ['w1', 'w2', 'w3']) {
        expect(
          w.rectOf(spec(id), viewport: const Size(800, 600)),
          spec(id).initialRect,
          reason: id,
        );
      }
      w.dispose();
    });
  });

  group('restore workspace layout', () {
    test('overlapping, off-screen and corner windows get a usable layout', () async {
      final repo = await settings();
      final w = FloatingWindows(repo);
      const area = Size(900, 600);
      w.area = area;
      for (final id in ['ai', 'note', 'tool']) {
        w.show(spec(id));
      }
      // A mess: off screen, tiny, and in the small corner state.
      w.place('ai', const Rect.fromLTWH(2000, 1500, 50, 50));
      w.place('note', const Rect.fromLTWH(-500, -500, 3000, 3000));
      w.toggleCompact('tool', const Rect.fromLTWH(10, 10, 300, 240), area);
      expect(w.isCompact('tool'), isTrue);

      w.restoreLayout();
      expect(w.open.map((s) => s.id), ['ai', 'note', 'tool'], reason: 'none closed');
      final tops = <double>{};
      for (final s in w.open) {
        final r = FloatingWindows.fit(w.rectOf(s, viewport: area), area, s.minSize);
        expect(r.left, greaterThanOrEqualTo(0), reason: s.id);
        expect(r.top, greaterThanOrEqualTo(0), reason: s.id);
        expect(r.right, lessThanOrEqualTo(area.width), reason: s.id);
        expect(r.bottom, lessThanOrEqualTo(area.height), reason: s.id);
        expect(r.width, greaterThanOrEqualTo(s.minSize.width));
        tops.add(r.top);
        expect(w.isCompact(s.id), isFalse);
      }
      expect(tops, hasLength(3), reason: 'cascaded: every title bar visible');
      // The restored layout is what is remembered.
      final again = FloatingWindows(repo);
      expect(
        again.rectOf(spec('ai'), viewport: area),
        w.rectOf(spec('ai'), viewport: area),
      );
      w.dispose();
      again.dispose();
    });

    test('with no area known it does nothing', () async {
      final w = FloatingWindows(await settings());
      w.show(spec('a'));
      w.place('a', const Rect.fromLTWH(5, 6, 300, 240));
      w.restoreLayout();
      expect(w.rectOf(spec('a')), const Rect.fromLTWH(5, 6, 300, 240));
      w.dispose();
    });
  });

  group('restart recovery and devices', () {
    test('places, sizes and stacking come back after a restart', () async {
      final repo = await settings();
      var w = FloatingWindows(repo);
      for (final id in ['a', 'b', 'c']) {
        w.show(spec(id));
      }
      w.place('a', const Rect.fromLTWH(10, 20, 320, 260));
      w.place('c', const Rect.fromLTWH(400, 300, 350, 250));
      w.toFront('a'); // order now: b, c, a
      w.dispose();

      // A new run reads the same settings from disk.
      final repo2 = await settings();
      w = FloatingWindows(repo2);
      for (final id in ['c', 'a', 'b']) {
        w.show(spec(id)); // reopened in any order
      }
      w.applySavedOrder();
      expect(w.open.map((s) => s.id), ['b', 'c', 'a']);
      expect(w.rectOf(spec('a')), const Rect.fromLTWH(10, 20, 320, 260));
      expect(w.rectOf(spec('c')), const Rect.fromLTWH(400, 300, 350, 250));
      w.dispose();
    });

    test('another device keeps its own layout', () async {
      final windows = FloatingWindows(await settings('windows-pc'));
      final ipad = FloatingWindows(await settings('ipad'));
      windows.place('a', const Rect.fromLTWH(10, 10, 300, 300));
      ipad.place('a', const Rect.fromLTWH(500, 200, 400, 500));
      expect(windows.rectOf(spec('a')).left, 10);
      expect(ipad.rectOf(spec('a')).left, 500);
      windows.dispose();
      ipad.dispose();
    });

    test('snapping can be turned off, per device', () async {
      final w = FloatingWindows(await settings());
      expect(w.snapEnabled, isTrue);
      await w.setSnap(false);
      expect(FloatingWindows(await settings()).snapEnabled, isFalse);
      w.dispose();
    });
  });

  group('on screen', () {
    Future<(FloatingWindows, Finder)> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final w = FloatingWindows(await settings());
      addTearDown(w.dispose);
      w.show(spec('a', rect: const Rect.fromLTWH(100, 100, 300, 240)));
      w.show(spec('b', rect: const Rect.fromLTWH(150, 150, 300, 240)));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: FloatingLayer(windows: w)),
        ),
      );
      return (w, find.byKey(const ValueKey('floating-a-title')));
    }

    testWidgets('dragging near an edge sticks; far away it does not', (
      tester,
    ) async {
      final (w, title) = await pump(tester);
      // Drag window a left so its left edge ends 6 px from the area edge.
      await tester.drag(title, const Offset(-114, 0));
      await tester.pumpAndSettle();
      expect(w.rectOf(spec('a')).left, 0, reason: 'stuck to the edge');
      expect(w.rectOf(spec('a')).width, 300);
      // A drag that ends in the open stays exactly there.
      await tester.drag(title, const Offset(220, 140));
      await tester.pumpAndSettle();
      final r = w.rectOf(spec('a'));
      expect(r.left, inInclusiveRange(150, 230));
      expect(r.top, inInclusiveRange(200, 260));
    });

    testWidgets('turning snapping off leaves the drop where it was let go', (
      tester,
    ) async {
      final (w, title) = await pump(tester);
      await w.setSnap(false);
      await tester.drag(title, const Offset(-114, 0));
      await tester.pumpAndSettle();
      expect(w.rectOf(spec('a')).left, inInclusiveRange(3, 9), reason: 'not stuck');
      expect(w.rectOf(spec('a')).left, isNot(0));
    });

    testWidgets('the title bar menu restores the layout', (tester) async {
      final (w, title) = await pump(tester);
      w.place('a', const Rect.fromLTWH(600, 500, 300, 240));
      await tester.pumpAndSettle();
      final center = tester.getCenter(title);
      final gesture = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Restore workspace layout'), findsOneWidget);
      await tester.tap(find.text('Restore workspace layout'));
      await tester.pumpAndSettle();
      final a = w.rectOf(spec('a'), viewport: const Size(900, 700));
      final b = w.rectOf(spec('b'), viewport: const Size(900, 700));
      expect(a.topLeft, const Offset(128, 128), reason: 'front window, second step');
      expect(b.topLeft, const Offset(150, 150), reason: 'back window, first step');
    });

    testWidgets('a smaller window area pulls windows back inside', (
      tester,
    ) async {
      final (w, _) = await pump(tester);
      w.place('b', const Rect.fromLTWH(560, 420, 320, 260));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(500, 400);
      await tester.pumpAndSettle();
      final box = tester.getRect(find.byKey(const ValueKey('content-b')));
      expect(box.right, lessThanOrEqualTo(500));
      expect(box.bottom, lessThanOrEqualTo(400));
      expect(box.left, greaterThanOrEqualTo(0));
      // Back to a big display: it is where it was.
      tester.view.physicalSize = const Size(900, 700);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const ValueKey('floating-b-title'))).dx, 560);
    });
  });
}
