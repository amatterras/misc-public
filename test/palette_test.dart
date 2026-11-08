import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/theme.dart';
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
    test('${mode.name} theme: text and accent are readable', () {
      AppColors.mode = mode;
      for (final bg in [
        AppColors.background,
        AppColors.card,
        AppColors.surfaceSecondary,
      ]) {
        expect(_ratio(AppColors.text, bg), greaterThanOrEqualTo(7.0));
        expect(_ratio(AppColors.textMuted, bg), greaterThanOrEqualTo(4.5));
        expect(_ratio(AppColors.textFaint, bg), greaterThanOrEqualTo(4.0));
        expect(_ratio(AppColors.accent, bg), greaterThanOrEqualTo(4.5));
      }
    });
  }

  test('the established dark identity colours are kept', () {
    AppColors.mode = ThemeMode.dark;
    expect(AppColors.background, const Color(0xFF191A1D));
    expect(AppColors.accent, const Color(0xFF789BB5));
  });

  // The palette used to live in two layers (AppColors forwarding to
  // NewColors). They were merged into one; these are the exact values the
  // old layer produced, so the merge provably changed no colour.
  test('every colour role keeps its exact value in both themes', () {
    const expected = {
      ThemeMode.dark: {
        'background': 0xFF191A1D,
        'card': 0xFF1F2126,
        'surfaceSecondary': 0xFF26282F,
        'cardRaised': 0xFF2C2F36,
        'border': 0xFF3A3D45,
        'text': 0xFFEFF0F4,
        'textMuted': 0xFFB7BAC3,
        'textFaint': 0xFF888C96,
        'accent': 0xFF789BB5,
        'onAccent': 0xFF191A1D,
        'accentSecondary': 0xFFABB0EA,
        'selected': 0xFF242D38,
        'hover': 0x14FFFFFF,
        'success': 0xFF8FBF98,
        'warm': 0xFFDFA084,
        'danger': 0xFFE39289,
        'glass': 0x991F2126,
        'glassBorder': 0x26FFFFFF,
        'brand': 0xFF5B629C,
      },
      ThemeMode.light: {
        'background': 0xFFF3F5F9,
        'card': 0xFFFFFFFF,
        'surfaceSecondary': 0xFFECEEF5,
        'cardRaised': 0xFFE5E8F0,
        'border': 0xFFDEE2EA,
        'text': 0xFF181C25,
        'textMuted': 0xFF555B68,
        'textFaint': 0xFF656A78,
        'accent': 0xFF3E6A8C,
        'onAccent': 0xFFFFFFFF,
        'accentSecondary': 0xFF5B629C,
        'selected': 0xFFE0EAF4,
        'hover': 0x0F181C25,
        'success': 0xFF3D784F,
        'warm': 0xFFA45936,
        'danger': 0xFFAF3D36,
        'glass': 0xCCFFFFFF,
        'glassBorder': 0x1A181C25,
        'brand': 0xFF5B629C,
      },
    };
    for (final MapEntry(key: mode, value: roles) in expected.entries) {
      AppColors.mode = mode;
      final actual = {
        'background': AppColors.background,
        'card': AppColors.card,
        'surfaceSecondary': AppColors.surfaceSecondary,
        'cardRaised': AppColors.cardRaised,
        'border': AppColors.border,
        'text': AppColors.text,
        'textMuted': AppColors.textMuted,
        'textFaint': AppColors.textFaint,
        'accent': AppColors.accent,
        'onAccent': AppColors.onAccent,
        'accentSecondary': AppColors.accentSecondary,
        'selected': AppColors.selected,
        'hover': AppColors.hover,
        'success': AppColors.success,
        'warm': AppColors.warm,
        'danger': AppColors.danger,
        'glass': AppColors.glass,
        'glassBorder': AppColors.glassBorder,
        'brand': AppColors.brand,
      };
      for (final MapEntry(key: role, value: argb) in roles.entries) {
        expect(actual[role]!.toARGB32(), argb, reason: '${mode.name} $role');
      }
      // Roles that are defined as another role.
      expect(AppColors.canvas, AppColors.background);
      expect(AppColors.sidebar, AppColors.card);
      expect(AppColors.disabled, AppColors.textFaint);
      expect(AppColors.focus, AppColors.accent);
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
