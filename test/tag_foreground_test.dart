// Text on a tag colour (tags can be any HEX colour): always at least 4.5:1,
// the palette's ink where it is good enough, pure black only where neither
// the ink nor white reaches 4.5:1. Choosing the text colour never changes
// the tag's stored colour.
import 'package:flutter/painting.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/tag_models.dart';
import 'package:flutter_application_1/features/tags/tag_ui.dart';
import 'package:flutter_application_1/new_ui/new_folder_colors.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance() + 0.05, lb = b.computeLuminance() + 0.05;
  return la > lb ? la / lb : lb / la;
}

const ink = Color(0xFF181C25);
const black = Color(0xFF000000);
const white = Color(0xFFFFFFFF);

void main() {
  test('every colour of the RGB space gets readable text', () {
    for (var r = 0; r <= 255; r += 15) {
      for (var g = 0; g <= 255; g += 15) {
        for (var b = 0; b <= 255; b += 15) {
          final c = Color.fromARGB(255, r, g, b);
          final fg = tagForeground(c);
          expect(contrast(fg, c), greaterThanOrEqualTo(4.5), reason: hexOf(c));
        }
      }
    }
  });

  test('the named palettes too: inks, categories, folders, canvas tags', () {
    final colors = [
      for (final s in InkColors.library) s.color,
      for (final f in NewFolderColors.all) f.color,
      ...CanvasTagColors.selected,
      ArchiveCategoryColors.resource,
      ArchiveCategoryColors.projects,
      ArchiveCategoryColors.other,
      ArchiveCategoryColors.shopping,
      ArchiveCategoryColors.secondBrain,
      CalendarCategoryColors.reading,
      CalendarCategoryColors.habits,
      CalendarCategoryColors.other,
      CalendarCategoryColors.reminderEvent,
    ];
    for (final c in colors) {
      expect(
        contrast(tagForeground(c), c),
        greaterThanOrEqualTo(4.5),
        reason: hexOf(c),
      );
    }
  });

  test('the palette ink is used where it reads well; black only as needed', () {
    // Light colours: the ink passes, so it is used (not pure black).
    for (final c in [
      const Color(0xFFFFFFFF),
      const Color(0xFFE9C5DB),
      const Color(0xFFACDCD8),
      const Color(0xFFDEB866),
    ]) {
      expect(tagForeground(c), ink, reason: hexOf(c));
    }
    // Dark colours: white.
    for (final c in [
      const Color(0xFF172943),
      const Color(0xFF2C6149),
      const Color(0xFF111214),
    ]) {
      expect(tagForeground(c), white, reason: hexOf(c));
    }
    // Whenever black is chosen, neither the ink nor white would pass.
    for (var v = 0; v <= 255; v += 5) {
      final c = Color.fromARGB(255, v, (v * 0.8).round(), 255 - v);
      if (tagForeground(c) == black) {
        expect(contrast(ink, c), lessThan(4.5), reason: hexOf(c));
        expect(contrast(white, c), lessThan(4.5), reason: hexOf(c));
      }
    }
  });

  test('choosing the text colour never changes the stored tag colour', () {
    final tag = CustomTag(
      id: 't1',
      name: 'Mid',
      color: 0xFF6B7078,
      createdAt: DateTime(2026, 11, 8),
      updatedAt: DateTime(2026, 11, 8),
    );
    tagForeground(Color(tag.color));
    expect(tag.color, 0xFF6B7078);
  });
}
