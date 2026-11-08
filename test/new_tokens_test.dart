import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/new_ui/new_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  tearDown(() {
    AppColors.mode = ThemeMode.dark;
  });

  for (final mode in [ThemeMode.dark, ThemeMode.light]) {
    test('New ${mode.name} theme: text and accent are readable', () {
      AppColors.mode = mode;
      for (final bg in [
        NewColors.background,
        NewColors.surface,
        NewColors.surfaceSecondary,
      ]) {
        expect(_ratio(NewColors.text, bg), greaterThanOrEqualTo(7.0));
        expect(_ratio(NewColors.textMuted, bg), greaterThanOrEqualTo(4.5));
        expect(_ratio(NewColors.textFaint, bg), greaterThanOrEqualTo(4.0));
        expect(_ratio(NewColors.accent, bg), greaterThanOrEqualTo(4.5));
      }
    });
  }

  test('the established dark identity colours are kept', () {
    AppColors.mode = ThemeMode.dark;
    expect(NewColors.background, const Color(0xFF191A1D));
    expect(NewColors.accent, const Color(0xFF789BB5));
  });

  test('AppColors returns the New palette', () {
    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      AppColors.mode = mode;
      expect(AppColors.sidebar, NewColors.surface);
      expect(AppColors.accent, NewColors.accent);
      expect(AppColors.text, NewColors.text);
    }
  });

  test('the semantic category colours are not touched', () {
    expect(CalendarCategoryColors.reading, const Color(0xFF8EA96C));
    expect(CalendarCategoryColors.habits, const Color(0xFF7092D0));
    expect(CalendarCategoryColors.other, const Color(0xFFC491C1));
    expect(CalendarCategoryColors.reminderEvent, const Color(0xFF52B0AB));
    expect(ArchiveCategoryColors.resource, const Color(0xFF5581C1));
    expect(ArchiveCategoryColors.secondBrain, const Color(0xFFD492C1));
  });
}
