// The New interface's twenty Archive folder colours. Pure data and rules, no
// widgets: folders keep the colour *id* (stable text), so a palette tweak
// never re-colours saved folders and Original (which ignores it) is not
// affected.
import 'package:flutter/material.dart';

class FolderColor {
  const FolderColor(this.id, this.name, this.color);

  /// Stored with the folder. Never renamed once released.
  final String id;
  final String name;
  final Color color;

  /// Readable text/icon colour on top of [color] (full-card treatment).
  Color get onColor => contrastOn(color);
}

abstract final class NewFolderColors {
  static const all = <FolderColor>[
    FolderColor('warm-coral', 'Warm Coral', Color(0xFFCD775C)),
    FolderColor('soft-coral', 'Soft Coral', Color(0xFFE7A396)),
    FolderColor('coral-dust', 'Coral Dust', Color(0xFFD99586)),
    FolderColor('peach-veil', 'Peach Veil', Color(0xFFE4B29F)),
    FolderColor('dusty-rose', 'Dusty Rose', Color(0xFFD7AFBF)),
    FolderColor('rose-taupe', 'Rose Taupe', Color(0xFFC99396)),
    FolderColor('muted-mauve', 'Muted Mauve', Color(0xFFB58BAA)),
    FolderColor('pale-lavender', 'Pale Lavender', Color(0xFFC1BEE5)),
    FolderColor('periwinkle', 'Periwinkle', Color(0xFFABB0EA)),
    FolderColor('lavender-blue', 'Lavender Blue', Color(0xFF9EA4D0)),
    FolderColor('iris', 'Iris', Color(0xFF7D80B8)),
    FolderColor('deep-indigo', 'Deep Indigo', Color(0xFF5B629C)),
    FolderColor('blue-slate', 'Blue Slate', Color(0xFF7589A0)),
    FolderColor('mist-blue', 'Mist Blue', Color(0xFF8FA8C4)),
    FolderColor('muted-denim', 'Muted Denim', Color(0xFF6F87B3)),
    FolderColor('sage', 'Sage', Color(0xFFA8B59F)),
    FolderColor('eucalyptus', 'Eucalyptus', Color(0xFF8EAAA5)),
    FolderColor('sea-glass', 'Sea Glass', Color(0xFF8CB9B7)),
    FolderColor('warm-sand', 'Warm Sand', Color(0xFFD3C0A0)),
    FolderColor('dusty-plum', 'Dusty Plum', Color(0xFF8F718F)),
  ];

  static FolderColor? byId(String? id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The colour for a new folder: the first palette colour (in a fixed,
  /// well-spread order) that is not used by [neighbours] (the folders next to
  /// it: previous, next, same parent). Falls back to the least-used colour,
  /// so a long list still avoids identical neighbours where it can.
  /// [existing] are all folder colour ids already in use.
  static FolderColor assign({
    Iterable<String?> neighbours = const [],
    Iterable<String?> existing = const [],
  }) {
    final near = neighbours.whereType<String>().toSet();
    final use = <String, int>{};
    for (final id in existing.whereType<String>()) {
      use[id] = (use[id] ?? 0) + 1;
    }
    FolderColor? best;
    for (final index in _order) {
      final c = all[index];
      if (near.contains(c.id)) continue;
      if (best == null || (use[c.id] ?? 0) < (use[best.id] ?? 0)) best = c;
      if ((use[c.id] ?? 0) == 0) break;
    }
    return best ?? all.first;
  }

  /// Walks the palette so consecutive picks differ strongly in hue.
  static const _order = [
    0, 8, 17, 15, 11, 4, 13, 6, 1, 16, //
    10, 18, 2, 9, 19, 3, 14, 7, 5, 12,
  ];
}

/// Dark or light foreground, whichever reads better on [background].
Color contrastOn(Color background) {
  const dark = Color(0xFF181C25);
  const light = Color(0xFFFFFBFA);
  double ratio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  return ratio(background, dark) >= ratio(background, light) ? dark : light;
}
