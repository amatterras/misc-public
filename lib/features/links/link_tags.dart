// The fixed tags of the Links library. Stored on a link's Asset by [id]
// (`linkTags` in its JSON), so the names and colours can change without
// touching stored data.
import 'package:flutter/painting.dart';

enum LinkTag {
  resource('resource', 'Resource', Color(0xFF3B82F6)), // blue
  projects('projects', 'Projects', Color(0xFFEF4444)), // red
  other('other', 'Other', Color(0xFFEAB308)), // yellow
  shopping('shopping', 'Shopping', Color(0xFF22C55E)), // green
  secondBrain('second-brain', 'Second-brain', Color(0xFFEC4899)); // pink

  const LinkTag(this.id, this.label, this.color);

  final String id;
  final String label;
  final Color color;

  static LinkTag? byId(String id) {
    for (final t in values) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Known tags among [ids], in the fixed order (unknown ids are skipped
  /// here but kept in the data).
  static List<LinkTag> of(Iterable<String> ids) {
    final set = ids.toSet();
    return [
      for (final t in values)
        if (set.contains(t.id)) t,
    ];
  }
}
