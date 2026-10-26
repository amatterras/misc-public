// Smart Alignment Studio: guides, spacing marks and grid snapping while
// moving (at any zoom), and the explicit align / distribute commands -
// with connectors staying attached and nothing unrelated ever moving.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/alignment.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_test/flutter_test.dart';

TextItem box(String id, Offset at, {double w = 200, double h = 80}) =>
    TextItem(id: id, position: at, width: w, minHeight: h, text: id);

CanvasController make(List<CanvasItem> items) => CanvasController(
  document: CanvasDocument(
    id: 'c',
    title: 'Map',
    items: items,
    updatedAt: DateTime(2026),
    viewport: const CanvasViewport(),
    schema: 3,
  ),
  onSave: (_) async {},
);

Offset posOf(CanvasController c, String id) =>
    (c.itemById(id) as TextItem).position;

/// Drags item [id] by [worldDelta] (screen = world * scale).
void dragBy(CanvasController c, String id, Offset worldDelta) {
  final start = c.toScreen(c.itemBounds(c.itemById(id)!).center);
  final end = start + worldDelta * c.scale;
  c.tool = CanvasTool.select;
  c.select([id]);
  c.pointerDown(start);
  c.pointerMove(Offset.lerp(start, end, 0.3)!);
  c.pointerMove(Offset.lerp(start, end, 0.7)!);
  c.pointerMove(end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('geometry', () {
    const reach = 6.0;
    test('edges and centres stick within reach; farther they do not', () {
      const other = Rect.fromLTWH(0, 0, 200, 100);
      var r = snapMove(
        moving: const Rect.fromLTWH(4, 300, 150, 60),
        others: [other],
        reach: reach,
      );
      expect(r.adjustment, const Offset(-4, 0));
      expect(r.guides.single.vertical, isTrue);
      expect(r.guides.single.at, 0);
      r = snapMove(
        moving: const Rect.fromLTWH(9, 300, 150, 60),
        others: [other],
        reach: reach,
      );
      expect(r.adjustment, Offset.zero);
      expect(r.guides, isEmpty);
      // Centre to centre, horizontally and vertically.
      r = snapMove(
        moving: const Rect.fromLTWH(73, 33, 50, 40),
        others: [other],
        reach: reach,
      );
      expect(r.adjustment.dx, closeTo(2, 1e-9)); // centre 98 -> 100
      expect(r.adjustment.dy, closeTo(-3, 1e-9));
    });

    test('grid snapping fills in where nothing lined up', () {
      final r = snapMove(
        moving: const Rect.fromLTWH(30, 50, 100, 40),
        others: const [],
        reach: reach,
        guides: false,
        grid: 24,
      );
      expect(r.adjustment, const Offset(-6, -2)); // 24, 48
    });

    test('the gaps to the nearest neighbours are measured', () {
      final marks = spacingMarks(
        const Rect.fromLTWH(300, 100, 100, 50),
        const [
          Rect.fromLTWH(0, 100, 200, 50), // left, gap 100
          Rect.fromLTWH(500, 90, 100, 80), // right, gap 100
          Rect.fromLTWH(310, 0, 50, 60), // above, gap 40
        ],
      );
      expect(marks.map((m) => m.distance).toList()..sort(), [40, 100, 100]);
    });

    test('align and distribute', () {
      const a = Rect.fromLTWH(0, 0, 100, 50);
      const b = Rect.fromLTWH(300, 40, 200, 80);
      const c = Rect.fromLTWH(120, 200, 50, 50);
      final rects = [a, b, c];
      Rect moved(AlignAction act, int i) =>
          rects[i].shift(alignDeltas(act, rects)[i]);
      expect(moved(AlignAction.left, 1).left, 0);
      expect(moved(AlignAction.right, 0).right, 500);
      expect(moved(AlignAction.top, 2).top, 0);
      expect(moved(AlignAction.bottom, 0).bottom, 250);
      expect(moved(AlignAction.centerH, 0).center.dx, 250);
      expect(moved(AlignAction.middleV, 1).center.dy, 125);
      // Even spacing across: a stays, b (right-most) stays, c in between.
      final d = alignDeltas(AlignAction.distributeH, rects);
      final after = [for (var i = 0; i < 3; i++) rects[i].shift(d[i])];
      expect(after[0].left, 0);
      expect(after[1].right, 500);
      final gap1 = after[2].left - after[0].right;
      final gap2 = after[1].left - after[2].right;
      expect(gap1, closeTo(gap2, 1e-9));
      // Too few objects: nothing moves.
      expect(
        alignDeltas(AlignAction.distributeV, [a, b]),
        [Offset.zero, Offset.zero],
      );
    });
  });

  group('moving with guides and grid', () {
    for (final zoom in [0.1, 1.0, 8.0]) {
      test('guides stick within 6 screen pixels at zoom $zoom', () async {
        final c = make([
          box('a', Offset.zero),
          box('b', const Offset(500, 300)),
        ]);
        c.setView(Offset.zero, zoom);
        c.setAlignment(guides: true);
        // B's left edge ends 4 screen pixels from A's left edge: sticks.
        dragBy(c, 'b', Offset(-500 + 4 / zoom, 0));
        expect(c.showingAlignOverlay, isTrue);
        expect(c.activeGuides.any((g) => g.vertical && g.at == 0), isTrue);
        c.pointerUp();
        expect(posOf(c, 'b').dx, closeTo(0, 1e-9), reason: 'snapped');
        expect(c.activeGuides, isEmpty, reason: 'overlay gone after the drop');
        // 20 screen pixels away: not snapped, exactly where it was put.
        final c2 = make([
          box('a', Offset.zero),
          box('b', const Offset(500, 300)),
        ]);
        c2.setView(Offset.zero, zoom);
        c2.setAlignment(guides: true);
        dragBy(c2, 'b', Offset(-500 + 20 / zoom, 0));
        c2.pointerUp();
        expect(posOf(c2, 'b').dx, closeTo(20 / zoom, 1e-6));
        expect(c2.activeGuides, isEmpty);
      });
    }

    test('off by default: a move is exactly the drag', () async {
      final c = make([box('a', Offset.zero), box('b', const Offset(500, 300))]);
      c.setView(Offset.zero, 1);
      dragBy(c, 'b', const Offset(-497, 0));
      c.pointerUp();
      expect(posOf(c, 'b'), const Offset(3, 300));
    });

    testWidgets('Alt suspends snapping while held', (tester) async {
      final c = make([box('a', Offset.zero), box('b', const Offset(500, 300))]);
      c.setView(Offset.zero, 1);
      c.setAlignment(guides: true);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      dragBy(c, 'b', const Offset(-497, 0));
      c.pointerUp();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(posOf(c, 'b').dx, 3, reason: 'not pulled to 0');
      c.dispose();
      await tester.pump(const Duration(seconds: 1));
    });

    for (final zoom in [0.25, 1.0, 4.0]) {
      test('grid snapping lands on the grid at zoom $zoom, undo is exact', () async {
        final c = make([
          box('a', const Offset(7, 11)),
          box('far', const Offset(2000, 2000)),
        ]);
        c.setView(Offset.zero, zoom);
        c.setAlignment(grid: true, size: 24);
        final farBefore = c.itemById('far');
        dragBy(c, 'a', const Offset(131, 77));
        expect(c.showingAlignOverlay, isTrue);
        c.pointerUp();
        final p = posOf(c, 'a');
        expect(p.dx % 24, closeTo(0, 1e-9));
        expect(p.dy % 24, closeTo(0, 1e-9));
        expect(c.itemById('far'), same(farBefore), reason: 'others untouched');
        c.undo();
        expect(posOf(c, 'a'), const Offset(7, 11));
      });
    }

    test('connectors stay attached and bent lines keep their shape', () async {
      final c = make([
        box('a', Offset.zero),
        box('b', const Offset(500, 0)),
        box('anchor', const Offset(900, 600)),
        const ConnectorItem(
          id: 'k',
          fromId: 'a',
          toId: 'b',
          bends: [Offset(250, -120)],
        ),
        const ConnectorItem(id: 'k2', fromId: 'b', toId: 'anchor'),
      ]);
      c.setView(Offset.zero, 1);
      c.setAlignment(grid: true, size: 24);
      c.tool = CanvasTool.select;
      c.select(const ['a', 'b']);
      final start = c.toScreen(const Offset(100, 40));
      c.pointerDown(start);
      c.pointerMove(start + const Offset(13, 9));
      c.pointerMove(start + const Offset(53, 29));
      c.pointerUp();
      final k = c.items.whereType<ConnectorItem>().firstWhere((x) => x.id == 'k');
      final moved = posOf(c, 'a') - Offset.zero;
      expect(k.bends.single, const Offset(250, -120) + moved,
          reason: 'both ends moved together');
      for (final conn in c.items.whereType<ConnectorItem>()) {
        final ends = c.connectorEnds(conn)!;
        final a = c.itemBounds(c.itemById(conn.fromId)!).inflate(0.5);
        final b = c.itemBounds(c.itemById(conn.toId)!).inflate(0.5);
        expect(a.contains(ends.$1), isTrue, reason: conn.id);
        expect(b.contains(ends.$2), isTrue, reason: conn.id);
      }
    });
  });

  group('align and distribute commands', () {
    CanvasController scene() => make([
      box('a', const Offset(10, 10), w: 100, h: 50),
      box('b', const Offset(400, 90), w: 200, h: 80),
      box('c', const Offset(150, 300), w: 60, h: 60),
      box('x', const Offset(2000, 2000)),
      const ConnectorItem(id: 'k', fromId: 'a', toId: 'b'),
    ]);

    test('align left moves only the selected, one undo step', () {
      final c = scene();
      final xBefore = c.itemById('x');
      c.select(const ['a', 'b', 'c']);
      expect(c.alignSelection(AlignAction.left), isNull);
      for (final id in ['a', 'b', 'c']) {
        expect(posOf(c, id).dx, 10, reason: id);
      }
      expect(c.itemById('x'), same(xBefore));
      expect(c.items.whereType<ConnectorItem>(), hasLength(1));
      c.undo();
      expect(posOf(c, 'b'), const Offset(400, 90));
      expect(posOf(c, 'c'), const Offset(150, 300));
    });

    test('distribute spaces evenly and keeps the two outer ones', () {
      final c = scene();
      c.select(const ['a', 'b', 'c']);
      c.alignSelection(AlignAction.distributeH);
      final ra = c.itemBounds(c.itemById('a')!);
      final rb = c.itemBounds(c.itemById('b')!);
      final rc = c.itemBounds(c.itemById('c')!);
      expect(ra.left, 10);
      expect(rb.right, 600);
      final ordered = [ra, rc, rb];
      final gap1 = ordered[1].left - ordered[0].right;
      final gap2 = ordered[2].left - ordered[1].right;
      expect(gap1, closeTo(gap2, 1e-9));
    });

    test('too few objects: a plain message, nothing moves', () {
      final c = scene();
      c.select(const ['a', 'b']);
      final before = c.items.map((i) => i.toJson().toString()).toList();
      expect(c.alignSelection(AlignAction.distributeH), contains('at least 3'));
      c.select(const ['a']);
      expect(c.alignSelection(AlignAction.top), contains('at least 2'));
      expect(c.items.map((i) => i.toJson().toString()).toList(), before);
    });

    test('locked objects stay put and are mentioned', () {
      final c = scene();
      c.select(const ['b']);
      c.toggleLockSelection();
      c.select(const ['a', 'b', 'c']);
      final note = c.alignSelection(AlignAction.left);
      expect(note, contains('1 locked object stayed'));
      expect(posOf(c, 'b').dx, 400);
      expect(posOf(c, 'a').dx, posOf(c, 'c').dx);
    });

    test('a group moves as one and a bent line follows when both ends move equally', () {
      final c = make([
        box('a', const Offset(0, 0), w: 100, h: 50),
        box('b', const Offset(300, 0), w: 100, h: 50),
        box('c', const Offset(0, 200), w: 100, h: 50),
        const ConnectorItem(
          id: 'k',
          fromId: 'a',
          toId: 'b',
          bends: [Offset(200, -50)],
        ),
      ]);
      c.select(const ['a', 'b']);
      c.groupSelection(); // a and b are one object now
      c.select(const ['a', 'b', 'c']);
      c.alignSelection(AlignAction.right); // c is to the right edge of the group
      final move = posOf(c, 'a');
      expect(posOf(c, 'b') - posOf(c, 'a'), const Offset(300, 0),
          reason: 'the group kept its shape');
      final k = c.items.whereType<ConnectorItem>().single;
      expect(k.bends.single, const Offset(200, -50) + move);
    });
  });

  group('kept per device', () {
    test('the settings are saved and come back after a restart', () async {
      final dir = Directory.systemTemp.createTempSync('theapp_align_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      Future<AppState> boot() async {
        final ws = Workspace(dir);
        final s = AppState(
          canvases: FileCanvasRepository(ws.store),
          settings: SettingsRepository(ws.store),
          workspace: ws,
          enableSendTo: false,
        );
        await s.init();
        return s;
      }

      var s = await boot();
      expect(s.canvas!.alignGuides, isFalse);
      expect(s.canvas!.gridSnap, isFalse);
      await s.setAlignment(s.canvas!, guides: true, grid: true, size: 32);
      await s.flush();
      s.dispose();
      s = await boot();
      expect(s.canvas!.alignGuides, isTrue);
      expect(s.canvas!.gridSnap, isTrue);
      expect(s.canvas!.gridSize, 32);
      await s.flush();
      s.dispose();
    });
  });
}
