// Where the pages of a note's notebook are, and how many there are.
//
// Pages are stacked vertically in one coordinate space (the notebook's
// "world", like a canvas): page i spans [pageRect(i)], gaps between pages
// belong to no page. Ink and text are stored in these coordinates, so
// their positions never change when pages are added or the zoom changes.
//
// Page rule: there is always exactly one page after the last page that
// has content (a stroke of any size, even a single dot, or a text box).
// PDF pages are pages of their own: writing on the last one adds one blank
// page after it. A new note has one blank page. Nothing is stored for blank pages:
// the count is worked out from the content each time, so scrolling never
// creates pages, and reopening never loses or duplicates one.
import 'dart:math' as math;
import 'dart:ui';

import '../../data/models/canvas_models.dart';

class NotebookLayout {
  NotebookLayout({
    List<PageBackground> backgrounds = const [],
    Iterable<Rect> content = const [],
  }) : _backgrounds = {for (final b in backgrounds) b.pageIndex: b} {
    var last = -1;
    for (final rect in content) {
      last = math.max(last, pageAt(rect.bottom));
    }
    for (final b in backgrounds) {
      last = math.max(last, b.pageIndex - 1); // no blank page after a PDF yet
      _lastBackground = math.max(_lastBackground, b.pageIndex);
    }
    _lastContent = last;
  }

  /// Width of every page (world units; a US Letter page at 96 dpi).
  static const double pageWidth = 816;

  /// Height of a plain page.
  static const double plainHeight = 1056;

  /// Space between pages.
  static const double gap = 32;

  final Map<int, PageBackground> _backgrounds;
  int _lastBackground = -1;
  late final int _lastContent;
  final List<double> _tops = [0];

  PageBackground? background(int index) => _backgrounds[index];

  /// Pages available: every PDF page, plus one blank page after the last
  /// page with ink or text, never fewer than one.
  int get pageCount =>
      math.max(1, math.max(_lastContent + 2, _lastBackground + 1));

  /// Height of page [index] (a PDF page keeps its own shape).
  double pageHeight(int index) {
    final b = _backgrounds[index];
    if (b == null || b.width <= 0) return plainHeight;
    return pageWidth * b.height / b.width;
  }

  double _top(int index) {
    while (_tops.length <= index) {
      final i = _tops.length - 1;
      _tops.add(_tops[i] + pageHeight(i) + gap);
    }
    return _tops[index];
  }

  /// The page's area in notebook coordinates.
  Rect pageRect(int index) =>
      Rect.fromLTWH(0, _top(index), pageWidth, pageHeight(index));

  /// The page a vertical position belongs to; a position in the gap after
  /// a page belongs to that page, anything above the first to page 0.
  int pageAt(double y) {
    if (y <= 0) return 0;
    var i = 0;
    while (_top(i + 1) <= y) {
      i++;
    }
    return i;
  }

  /// Bounds of the items that count as page content (not connections).
  static Iterable<Rect> contentOf(
    Iterable<CanvasItem> items,
    Rect Function(CanvasItem) bounds,
  ) sync* {
    for (final item in items) {
      if (item is ConnectorItem) continue;
      yield bounds(item);
    }
  }
}
