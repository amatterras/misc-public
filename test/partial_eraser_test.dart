// The partial eraser: exact geometry of cutting a stroke with the eraser's
// swept path, and its behaviour on the canvas (split strokes keep their
// look, one undo step, locked strokes untouched, sync revisions, saved
// across a restart), next to the unchanged whole-stroke eraser.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/canvas/canvas_controller.dart';
import 'package:flutter_application_1/features/canvas/canvas_toolbar.dart';
import 'package:flutter_application_1/features/ink/partial_erase.dart';
import 'package:flutter_test/flutter_test.dart';

List<StrokePoint> line(Offset from, Offset to, int n, {double p = 0.5}) => [
  for (var i = 0; i <= n; i++)
    StrokePoint(
      from.dx + (to.dx - from.dx) * i / n,
      from.dy + (to.dy - from.dy) * i / n,
      p,
    ),
];

CanvasController make(List<CanvasItem> items) => CanvasController(
  document: CanvasDocument(
    id: 'c',
    title: 'Ink',
    items: items,
    updatedAt: DateTime(2026),
    viewport: const CanvasViewport(),
    schema: 3,
  ),
  onSave: (_) async {},
);

StrokeItem stroke(String id, List<StrokePoint> points, {double width = 2}) =>
    StrokeItem(
      id: id,
      points: points,
      color: const Color(0xFF3366FF),
      strokeWidth: width,
    );

/// An eraser drag from [from] to [to] (screen == world at scale 1).
void erase(CanvasController c, Offset from, Offset to) {
  c.setView(Offset.zero, 1);
  c.tool = CanvasTool.eraser;
  c.pointerDown(from);
  for (var i = 1; i <= 5; i++) {
    c.pointerMove(Offset.lerp(from, to, i / 5)!);
  }
  c.pointerUp();
}

void main() {
  group('geometry', () {
    test('a dab in the middle cuts exactly at the eraser edge', () {
      final pts = line(Offset.zero, const Offset(100, 0), 10);
      final pieces = erasePolyline(
        pts,
        const Offset(50, 0),
        const Offset(50, 0),
        5,
      )!;
      expect(pieces, hasLength(2));
      expect(pieces[0].first.offset, Offset.zero);
      expect(pieces[0].last.x, closeTo(45, 0.01));
      expect(pieces[1].first.x, closeTo(55, 0.01));
      expect(pieces[1].last.offset, const Offset(100, 0));
      // Points away from the eraser are the original ones, untouched.
      expect(pieces[0].sublist(0, 5), pts.sublist(0, 5));
      expect(pieces[1].sublist(1), pts.sublist(6));
    });

    test('missing the line changes nothing; covering it removes it', () {
      final pts = line(Offset.zero, const Offset(100, 0), 10);
      expect(
        erasePolyline(pts, const Offset(50, 30), const Offset(60, 30), 5),
        isNull,
      );
      expect(
        erasePolyline(pts, const Offset(-10, 0), const Offset(110, 0), 3),
        isEmpty,
      );
    });

    test('a swept path across the line, and a cut at the start', () {
      final pts = line(Offset.zero, const Offset(100, 0), 1); // 2 points
      final across = erasePolyline(
        pts,
        const Offset(30, -20),
        const Offset(30, 20),
        2,
      )!;
      expect(across.map((p) => [p.first.x, p.last.x]), [
        [0, closeTo(28, 0.01)],
        [closeTo(32, 0.01), 100],
      ]);
      final start = erasePolyline(pts, Offset.zero, Offset.zero, 4)!;
      expect(start, hasLength(1));
      expect(start.single.first.x, closeTo(4, 0.01));
    });

    test('pressure is carried to the cut points', () {
      final pts = [
        const StrokePoint(0, 0, 0.2),
        const StrokePoint(100, 0, 1.0),
      ];
      final pieces = erasePolyline(
        pts,
        const Offset(50, 0),
        const Offset(50, 0),
        10,
      )!;
      expect(pieces[0].last.pressure, closeTo(0.2 + 0.8 * 0.4, 0.001));
      expect(pieces[1].first.pressure, closeTo(0.2 + 0.8 * 0.6, 0.001));
    });

    test('random strokes: nothing kept is under the eraser, nothing '
        'outside it is lost', () {
      final rnd = math.Random(7);
      Offset r() => Offset(rnd.nextDouble() * 200, rnd.nextDouble() * 200);
      for (var run = 0; run < 300; run++) {
        final pts = [
          for (var i = 0; i < 2 + rnd.nextInt(30); i++)
            StrokePoint(r().dx, r().dy, rnd.nextDouble()),
        ];
        final a = r(), b = rnd.nextBool() ? r() : a;
        final radius = 2 + rnd.nextDouble() * 20;
        final pieces = erasePolyline(pts, a, b, radius);
        if (pieces == null) {
          // Untouched: no point of the line is within the eraser.
          for (var i = 0; i < pts.length - 1; i++) {
            for (var k = 0; k <= 50; k++) {
              final p = Offset.lerp(pts[i].offset, pts[i + 1].offset, k / 50)!;
              expect(distanceToSegment(p, a, b), greaterThan(radius - 0.5));
            }
          }
          continue;
        }
        for (final piece in pieces) {
          expect(piece.length, greaterThanOrEqualTo(2));
          for (var i = 0; i < piece.length - 1; i++) {
            for (var k = 0; k <= 20; k++) {
              final p = Offset.lerp(
                piece[i].offset,
                piece[i + 1].offset,
                k / 20,
              )!;
              expect(
                distanceToSegment(p, a, b),
                greaterThanOrEqualTo(radius - 0.05),
                reason: 'run $run: kept ink under the eraser',
              );
            }
          }
        }
        final kept = {
          for (final piece in pieces) ...piece.map((p) => p.offset),
        };
        for (final p in pts) {
          if (distanceToSegment(p.offset, a, b) > radius + 0.01) {
            // An outside original point survives, unless it was only part
            // of a tiny leftover sliver (dropped on purpose).
            final inSliver = !kept.contains(p.offset);
            if (inSliver) {
              final nearCut =
                  pieces.isEmpty ||
                  distanceToSegment(p.offset, a, b) < radius + 0.3;
              expect(nearCut, isTrue, reason: 'run $run lost ${p.offset}');
            }
          }
        }
      }
    });
  });

  group('canvas', () {
    test(
      'partial: split pieces keep colour and width; one undo step',
      () async {
        final c = make([
          stroke('s', line(Offset.zero, const Offset(200, 0), 20)),
        ]);
        await c.flush();
        final revBefore = c.revOf('s');
        c.setEraser(mode: EraserMode.partial, size: 10);
        erase(c, const Offset(100, -30), const Offset(100, 30));
        final strokes = c.items.whereType<StrokeItem>().toList();
        expect(strokes, hasLength(2));
        expect(strokes.first.id, 's'); // the first piece is the same stroke
        expect(strokes.last.id, isNot('s'));
        for (final s in strokes) {
          expect(s.color, const Color(0xFF3366FF));
          expect(s.strokeWidth, 2);
        }
        // Gap = eraser (5 each side) + half the line width (1 each side).
        expect(strokes.first.points.last.x, closeTo(94, 0.05));
        expect(strokes.last.points.first.x, closeTo(106, 0.05));
        // Once saved, sync sees an edit of "s" and a new item.
        await c.flush();
        expect(c.revOf('s'), allOf(isNotNull, isNot(revBefore)));
        expect(c.revOf(strokes.last.id), isNotNull);

        c.undo();
        expect(c.items.whereType<StrokeItem>().single.points, hasLength(21));
        c.redo();
        expect(c.items.whereType<StrokeItem>(), hasLength(2));
      },
    );

    test('whole-stroke mode still removes the stroke; size matters', () {
      final c = make([
        stroke('s', line(Offset.zero, const Offset(200, 0), 20)),
      ]);
      c.setEraser(mode: EraserMode.stroke, size: 10);
      erase(c, const Offset(100, 20), const Offset(110, 20));
      expect(c.items, hasLength(1)); // 20 away: out of reach at size 10
      c.setEraser(size: 50);
      erase(c, const Offset(100, 20), const Offset(110, 20));
      expect(c.items, isEmpty);
    });

    test('locked strokes and other items are left alone', () {
      final c = make([
        stroke('locked', line(Offset.zero, const Offset(200, 0), 20)),
        stroke('free', line(const Offset(0, 40), const Offset(200, 40), 20)),
      ]);
      c.select({'locked'});
      c.toggleLockSelection();
      c.select(const {});
      c.setEraser(mode: EraserMode.partial, size: 20);
      erase(c, const Offset(100, -10), const Offset(100, 50));
      final ids = c.items.whereType<StrokeItem>().map((s) => s.id).toList();
      expect(ids.where((i) => i == 'locked'), hasLength(1));
      expect(
        c.items
            .whereType<StrokeItem>()
            .firstWhere((s) => s.id == 'locked')
            .points,
        hasLength(21),
      );
      expect(ids.length, 3); // free was split in two
    });

    test('erasing all of a stroke takes its connections with it', () {
      final c = make([
        stroke('s', line(const Offset(0, 0), const Offset(10, 0), 2)),
        TextItem(
          id: 't',
          position: const Offset(100, 100),
          width: 50,
          minHeight: 20,
          text: 't',
        ),
        ConnectorItem(id: 'k', fromId: 's', toId: 't'),
      ]);
      c.setEraser(mode: EraserMode.partial, size: 40);
      erase(c, const Offset(5, 0), const Offset(6, 0));
      expect(c.items.map((i) => i.id), ['t']);
    });
  });

  group('settings and saving', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('theapp_erase_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<AppState> app() async {
      final ws = Workspace(dir);
      final s = AppState(
        canvases: FileCanvasRepository(ws.store),
        settings: SettingsRepository(ws.store),
        workspace: ws,
        enableSendTo: false,
      );
      s.capture.fetchPreviews = false;
      await s.init();
      return s;
    }

    test('mode and size are remembered; erased pieces are saved', () async {
      var s = await app();
      var ink = await s.openCalendarInk();
      expect(ink.eraserMode, EraserMode.stroke);
      ink.setView(Offset.zero, 1);
      ink.tool = CanvasTool.pen;
      ink.pointerDown(const Offset(10, 50));
      for (var i = 1; i <= 10; i++) {
        ink.pointerMove(Offset(10 + i * 15.0, 50));
      }
      ink.pointerUp();
      await s.setEraser(ink, mode: EraserMode.partial, size: 12);
      erase(ink, const Offset(85, 20), const Offset(85, 80));
      expect(ink.items.whereType<StrokeItem>(), hasLength(2));
      await s.setEraser(ink, size: 500);
      expect(ink.eraserSize, CanvasController.eraserSizes.max);
      await s.flush();
      s.dispose();

      s = await app();
      ink = await s.openCalendarInk();
      expect(ink.eraserMode, EraserMode.partial);
      expect(ink.eraserSize, CanvasController.eraserSizes.max);
      expect(ink.items.whereType<StrokeItem>(), hasLength(2));
      await s.flush();
      s.dispose();
    });

    testWidgets('the eraser panel switches mode and size', (tester) async {
      final c = make(const []);
      c.tool = CanvasTool.eraser;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) => EraserPanel(controller: c),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('eraser-mode-partial')));
      await tester.tap(find.byKey(const ValueKey('eraser-size-32')));
      await tester.pump();
      expect(c.eraserMode, EraserMode.partial);
      expect(c.eraserSize, 32);
    });
  });
}
