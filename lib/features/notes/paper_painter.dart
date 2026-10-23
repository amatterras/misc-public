// Paints a notebook page's paper (one of the three templates). Lines start
// at the page's own corner, so the pattern lines up on every page.
import 'package:flutter/material.dart';

import '../../data/models/paper.dart';

class PaperPainter extends CustomPainter {
  const PaperPainter(this.paper, {this.scale = 1});

  final NotePaper paper;

  /// Screen pixels per page unit.
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Color(paper.background),
    );
    final color = Color(paper.lineColor).withValues(alpha: paper.lineOpacity);
    switch (paper.template) {
      case PaperTemplate.squareGrid || PaperTemplate.largeGrid:
        _grid(canvas, Offset.zero & size, paper.gridSpacing * scale, color);
      case PaperTemplate.splitGridDots:
        final split = size.width * NotePaper.splitGridFraction;
        canvas.drawRect(
          Rect.fromLTWH(split, 0, size.width - split, size.height),
          Paint()..color = Color(paper.dotBackground),
        );
        _grid(
          canvas,
          Rect.fromLTWH(0, 0, split, size.height),
          paper.gridSpacing * scale,
          color,
        );
        _dots(
          canvas,
          Rect.fromLTWH(split, 0, size.width - split, size.height),
          paper.dotSpacing * scale,
          Color(paper.dotColor).withValues(alpha: paper.dotOpacity),
        );
        canvas.drawLine(
          Offset(split, 0),
          Offset(split, size.height),
          Paint()
            ..color = color
            ..strokeWidth = 1.2,
        );
    }
  }

  void _grid(Canvas canvas, Rect area, double step, Color color) {
    if (step < 3) return; // too dense to be useful when zoomed far out
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = area.left + step; x < area.right; x += step) {
      canvas.drawLine(Offset(x, area.top), Offset(x, area.bottom), paint);
    }
    for (var y = area.top + step; y < area.bottom; y += step) {
      canvas.drawLine(Offset(area.left, y), Offset(area.right, y), paint);
    }
  }

  void _dots(Canvas canvas, Rect area, double step, Color color) {
    if (step < 3) return;
    final paint = Paint()..color = color;
    final r = (step / 14).clamp(0.8, 2.2);
    for (var y = area.top + step; y < area.bottom; y += step) {
      for (var x = area.left + step; x < area.right; x += step) {
        canvas.drawCircle(Offset(x, y), r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(PaperPainter old) =>
      old.paper != paper || old.scale != scale;
}
