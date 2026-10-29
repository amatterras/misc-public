// The Calendar handwriting of one day as a small PNG for the home-screen
// widgets. Display-only and derived, like the rest of the snapshot.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../data/models/canvas_models.dart';
import '../calendar/calendar_ink.dart';
import '../ink/stroke_geometry.dart';

/// Pixels per world unit in the widget image.
const _inkImageScale = 2.0;

/// Base64 PNG of the strokes inside [day]'s ink cell, or null when the day
/// has no handwriting.
Future<String?> renderDayInk(Iterable<CanvasItem> items, DateTime day) async {
  final rect = inkDayRect(day);
  final strokes = [
    for (final i in items)
      if (i is StrokeItem && i.bounds.overlaps(rect)) i,
  ];
  if (strokes.isEmpty) return null;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(_inkImageScale);
  canvas.clipRect(Offset.zero & inkDaySize);
  canvas.translate(-rect.left, -rect.top);
  for (final s in strokes) {
    paintStroke(canvas, s);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (inkDaySize.width * _inkImageScale).round(),
    (inkDaySize.height * _inkImageScale).round(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes == null ? null : base64Encode(bytes.buffer.asUint8List());
}
