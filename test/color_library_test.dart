// The shared color library: the permanent Bright Orange, the curated extra
// accents, distinct swatches, HEX entry, and the same colors everywhere
// (pens, connectors).
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_test/flutter_test.dart';

double distance(Color a, Color b) {
  final dr = (a.r - b.r) * 255, dg = (a.g - b.g) * 255, db = (a.b - b.b) * 255;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

void main() {
  test('Bright Orange #FF6A00 is a permanent, named swatch', () {
    final s = InkColors.byId('bright-orange')!;
    expect(s.name, 'Bright Orange');
    expect(s.color, const Color(0xFFFF6A00));
    expect(InkColors.all, contains(const Color(0xFFFF6A00)));
    expect(hexOf(s.color), '#FF6A00');
  });

  test('new swatches come after the original 19; ids are unique', () {
    expect(InkColors.library, hasLength(24));
    expect(InkColors.library.last.id, 'jet-black');
    expect(InkColors.library[18].id, 'bright-red');
    expect(InkColors.library.map((s) => s.id).toSet(), hasLength(24));
    expect(InkColors.all.toSet(), hasLength(24));
  });

  test('no two swatches are nearly the same on the canvas', () {
    final all = InkColors.library;
    for (var i = 19; i < all.length; i++) {
      for (var j = 0; j < all.length; j++) {
        if (i == j) continue;
        expect(
          distance(all[i].color, all[j].color),
          greaterThan(45),
          reason: '${all[i].name} vs ${all[j].name}',
        );
      }
    }
  });

  test('the palette has warm, cool, neutral and high-contrast choices', () {
    bool has(String id) => InkColors.byId(id) != null;
    expect(has('bright-orange') && has('warm-brown'), isTrue); // warm
    expect(has('sky-blue') && has('electric-azure'), isTrue); // cool
    expect(has('graphite-gray') && has('pearl'), isTrue); // neutral
    expect(has('jet-black') && has('pearl'), isTrue); // contrast
    // Readable on both themes: each is distinguishable from at least one
    // of the two backgrounds by a clear luminance gap.
    for (final s in InkColors.library) {
      final l = s.color.computeLuminance();
      const dark = 0.01, light = 0.95;
      expect(
        math.max((l - dark).abs(), (l - light).abs()),
        greaterThan(0.1),
        reason: s.name,
      );
    }
  });

  test('HEX entry', () {
    expect(parseHexColor('#FF6A00'), const Color(0xFFFF6A00));
    expect(parseHexColor('ff6a00'), const Color(0xFFFF6A00));
    expect(parseHexColor('  #f60 '), const Color(0xFFFF6600));
    expect(parseHexColor('80FF6A00'), const Color(0x80FF6A00));
    for (final bad in ['', '#', '#GG0000', '#12345', 'orange', '#1234567']) {
      expect(parseHexColor(bad), isNull, reason: bad);
    }
    expect(hexOf(const Color(0xFF00BDB1)), '#00BDB1');
  });

  test('new colors work for strokes and connectors and survive save/load', () {
    final orange = InkColors.brightOrange;
    final stroke = StrokeItem(
      id: 's',
      points: const [StrokePoint(0, 0), StrokePoint(5, 5)],
      color: orange,
      strokeWidth: 3,
    );
    final line = ConnectorItem(id: 'k', fromId: 'a', toId: 'b', color: orange);
    final back = [
      for (final i in [stroke, line])
        CanvasItem.fromJson(
          jsonDecode(jsonEncode(i.toJson())) as Map<String, dynamic>,
        ),
    ];
    expect((back[0] as StrokeItem).color, orange);
    expect((back[1] as ConnectorItem).color, orange);
  });
}
