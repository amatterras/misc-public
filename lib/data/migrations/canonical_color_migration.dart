import 'dart:ui';

import '../models/calendar_models.dart';
import '../models/canvas_models.dart';

/// Versioned deterministic migration for legacy stored ink and calendar
/// category color indexes. Unknown colors are intentionally preserved.
abstract final class CanonicalColorMigration {
  static const version = 1;

  /// Legacy swatches map in order: Pearl, Steel Blue, Dusty Blue,
  /// Midnight Navy, Petrol, Dusty Mint, Pistachio, Orchid Mist, Soft Amber,
  /// Fuchsia, Antique Gold, Electric Azure, Sapphire, Vivid Turquoise,
  /// Electric Lime, Ultraviolet, Electric Gold, Deep Pine.
  static const Map<int, int> legacyArgbToInkArgb = {
    0xFFEDEDED: 0xFFE3E5E8, // former default text ink -> Pearl
    0xFFE76F51: 0xFFD5A16F, // former coral -> Soft Amber
    0xFFE9A23B: 0xFFD5A16F, // former amber -> Soft Amber
    0xFFE8D45B: 0xFFF2D84A, // former yellow -> Electric Gold
    0xFF79B85A: 0xFFC7D5A0, // former green -> Pistachio
    0xFF35A99A: 0xFF4F9AA6, // former teal -> Petrol
    0xFF4D8FD6: 0xFF789BB5, // former blue -> Steel Blue
    0xFF6965C9: 0xFF793BE8, // former indigo -> Ultraviolet
    0xFFA56BC4: 0xFFC8AED2, // former purple -> Orchid Mist
    0xFFD86D9C: 0xFFE56BDA, // former pink -> Fuchsia
    0xFF9A9A9A: 0xFFE3E5E8, // former grey -> Pearl
    0xFFFFD54F: 0xFFF2D84A, // former highlighter yellow -> Electric Gold
    0xFF81C784: 0xFFC7D5A0, // former highlighter green -> Pistachio
    0xFF64B5F6: 0xFF2878F0, // former highlighter blue -> Electric Azure
    0xFFFF8A65: 0xFFD5A16F, // former highlighter coral -> Soft Amber
    0xFFBA68C8: 0xFFC8AED2, // former highlighter purple -> Orchid Mist
    0xFFF06292: 0xFFE56BDA, // former highlighter pink -> Fuchsia
    0xFF1B2A4A: 0xFF172943, // former notebook navy -> Midnight Navy
    0xFF111111: 0xFF172943, // former notebook black -> Midnight Navy
  };

  /// Preserves the saved alpha channel, which is significant for markers.
  static Color migrateColor(Color color) {
    final oldArgb = color.toARGB32();
    final replacement = legacyArgbToInkArgb[oldArgb & 0x00FFFFFF | 0xFF000000];
    if (replacement == null) return color;
    return Color((oldArgb & 0xFF000000) | (replacement & 0x00FFFFFF));
  }

  static CalendarEntry migrateCalendarEntry(CalendarEntry entry) =>
      entry.colorIndex == entry.category.index
      ? entry
      : entry.copyWith(colorIndex: entry.category.index);

  static CanvasDocument migrateCanvas(CanvasDocument document, String stamp) {
    final replacements = <String, CanvasItem>{};
    for (final item in document.items) {
      switch (item) {
        case StrokeItem():
          final color = migrateColor(item.color);
          if (color != item.color) {
            replacements[item.id] = StrokeItem(
              id: item.id,
              points: item.points,
              color: color,
              strokeWidth: item.strokeWidth,
              pressureWidth: item.pressureWidth,
              penInk: item.penInk,
              tiltWidth: item.tiltWidth,
            );
          }
        case TextItem():
          final textColor = item.textColor == null
              ? null
              : migrateColor(item.textColor!);
          final background = item.background == null
              ? null
              : migrateColor(item.background!);
          if (textColor != item.textColor || background != item.background) {
            replacements[item.id] = item.copyWith(
              textColor: () => textColor,
              background: () => background,
            );
          }
        default:
          break;
      }
    }
    if (replacements.isEmpty) return document;
    return CanvasDocument(
      id: document.id,
      title: document.title,
      items: [for (final item in document.items) replacements[item.id] ?? item],
      updatedAt: document.updatedAt,
      viewport: document.viewport,
      folderId: document.folderId,
      itemRevs: {
        ...document.itemRevs,
        for (final id in replacements.keys) id: stamp,
      },
      tombstones: document.tombstones,
      metaRev: document.metaRev,
      unknownItems: document.unknownItems,
      itemUnknownFields: document.itemUnknownFields,
      unknownKeys: document.unknownKeys,
      metaUnknownFields: document.metaUnknownFields,
      kind: document.kind,
      pageBackgrounds: document.pageBackgrounds,
      layers: document.layers,
    );
  }
}
