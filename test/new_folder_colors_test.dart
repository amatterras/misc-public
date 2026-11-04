import 'package:flutter_application_1/new_ui/new_folder_colors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the palette has twenty distinct colours with stable ids', () {
    expect(NewFolderColors.all, hasLength(20));
    expect(NewFolderColors.all.map((c) => c.id).toSet(), hasLength(20));
    expect(
      NewFolderColors.all.map((c) => c.color.toARGB32()).toSet(),
      hasLength(20),
    );
    expect(NewFolderColors.byId('warm-coral')?.name, 'Warm Coral');
    expect(NewFolderColors.byId('nope'), isNull);
  });

  test('text on every colour is readable (WCAG AA for large text, 3:1)', () {
    for (final c in NewFolderColors.all) {
      final a = c.color.computeLuminance();
      final b = c.onColor.computeLuminance();
      final hi = a > b ? a : b;
      final lo = a > b ? b : a;
      expect(
        (hi + 0.05) / (lo + 0.05),
        greaterThanOrEqualTo(3.0),
        reason: c.id,
      );
    }
  });

  test('new folders never repeat a neighbour and spread over the palette', () {
    final used = <String>[];
    String? previous;
    for (var i = 0; i < 40; i++) {
      final c = NewFolderColors.assign(neighbours: [previous], existing: used);
      expect(c.id, isNot(previous));
      used.add(c.id);
      previous = c.id;
    }
    // The first twenty folders use all twenty colours once.
    expect(used.take(20).toSet(), hasLength(20));
  });

  test('a colour next to its neighbours is skipped, even with few options', () {
    final all = NewFolderColors.all.map((c) => c.id).toList();
    final c = NewFolderColors.assign(
      neighbours: all.take(19),
      existing: const [],
    );
    expect(c.id, all.last);
  });
}
