import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../links/link_tags.dart';
import '../../platform/input_hints.dart';

/// Padding between a text box's edge and its text, in world units.
const double kTextPadding = 10;

TextStyle canvasTextStyle(
  double fontSize, {
  bool bold = false,
  bool italic = false,
  Color? color,
}) => TextStyle(
  color: color ?? AppColors.text,
  fontSize: fontSize,
  height: 1.45,
  fontFamily: 'Segoe UI',
  fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
  fontStyle: italic ? FontStyle.italic : FontStyle.normal,
);

TextStyle styleFor(TextItem item, {double scale = 1}) => canvasTextStyle(
  item.fontSize * scale,
  bold: item.bold,
  italic: item.italic,
  color: item.textColor,
);

TextAlign textAlignFor(TextAlignment a) => switch (a) {
  TextAlignment.left => TextAlign.left,
  TextAlignment.center => TextAlign.center,
  TextAlignment.right => TextAlign.right,
};

final _inline = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|~~(.+?)~~');

/// Renders lightweight Markdown-style formatting typed into a note:
/// `# Heading`, `## Subheading`, `- bullet`, `[ ] todo`, `[x] done`,
/// `**bold**`, `*italic*` and `~~strike~~`.
TextSpan formattedSpan(String text, TextStyle base) {
  final children = <InlineSpan>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var style = base;
    String prefix = '';
    if (line.startsWith('# ')) {
      line = line.substring(2);
      style = base.copyWith(
        fontSize: (base.fontSize ?? 16) * 1.5,
        fontWeight: FontWeight.w700,
        height: 1.3,
      );
    } else if (line.startsWith('## ')) {
      line = line.substring(3);
      style = base.copyWith(
        fontSize: (base.fontSize ?? 16) * 1.2,
        fontWeight: FontWeight.w600,
      );
    } else if (line.startsWith('- ') || line.startsWith('* ')) {
      line = line.substring(2);
      prefix = '•  ';
    } else if (line.startsWith('[ ] ')) {
      line = line.substring(4);
      prefix = '☐  ';
    } else if (line.toLowerCase().startsWith('[x] ')) {
      line = line.substring(4);
      prefix = '☑  ';
      style = style.copyWith(color: AppColors.textMuted);
    }
    if (prefix.isNotEmpty) children.add(TextSpan(text: prefix, style: style));
    var last = 0;
    for (final m in _inline.allMatches(line)) {
      if (m.start > last) {
        children.add(
          TextSpan(text: line.substring(last, m.start), style: style),
        );
      }
      final TextStyle s;
      final String inner;
      if (m.group(1) != null) {
        inner = m.group(1)!;
        s = style.copyWith(fontWeight: FontWeight.w700);
      } else if (m.group(2) != null) {
        inner = m.group(2)!;
        s = style.copyWith(fontStyle: FontStyle.italic);
      } else {
        inner = m.group(3)!;
        s = style.copyWith(decoration: TextDecoration.lineThrough);
      }
      children.add(TextSpan(text: inner, style: s));
      last = m.end;
    }
    if (last < line.length) {
      children.add(TextSpan(text: line.substring(last), style: style));
    }
    if (i < lines.length - 1) children.add(TextSpan(text: '\n', style: style));
  }
  if (children.isEmpty) children.add(TextSpan(text: ' ', style: base));
  return TextSpan(children: children, style: base);
}

TextPainter layoutText(
  InlineSpan span,
  double maxWidth, {
  int? maxLines,
  TextAlign align = TextAlign.left,
}) {
  return TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    textAlign: align,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  )..layout(maxWidth: math.max(1, maxWidth));
}

/// Pre-computed layout for link and note cards.
class CardLayout {
  CardLayout({
    required this.height,
    required this.lines,
    this.previewHeight = 0,
    this.chips = const [],
  });

  final double height;

  /// Text blocks with their offsets relative to the card's top-left.
  final List<(Offset, TextPainter)> lines;

  /// Height of the image strip at the top (0 if none).
  final double previewHeight;

  /// Coloured tag labels (Links library), relative to the card's top-left.
  final List<(Rect, Color, TextPainter)> chips;

  void dispose() {
    for (final (_, p) in lines) {
      p.dispose();
    }
    for (final (_, _, p) in chips) {
      p.dispose();
    }
  }
}

const double kCardPadding = 12;

CardLayout layoutLinkCard(
  LinkItem item,
  Asset? asset, {
  bool hasPreview = false,
}) {
  final inner = item.width - kCardPadding * 2;
  var y = 0.0;
  var preview = 0.0;
  if (hasPreview && asset?.width != null && asset?.height != null) {
    final ratio = (asset!.height! / asset.width!).clamp(0.3, 0.6);
    preview = item.width * ratio;
    y = preview;
  }
  y += kCardPadding;
  final lines = <(Offset, TextPainter)>[];
  void add(InlineSpan span, int maxLines, {double gap = 2}) {
    final p = layoutText(span, inner - 22, maxLines: maxLines);
    lines.add((Offset(kCardPadding + 22, y), p));
    y += p.height + gap;
  }

  final title = asset?.label ?? 'Link';
  add(
    TextSpan(
      text: title,
      style: canvasTextStyle(14, bold: true).copyWith(height: 1.3),
    ),
    2,
  );
  final chips = <(Rect, Color, TextPainter)>[];
  final tags = LinkTag.of(asset?.linkTags ?? const []);
  if (tags.isNotEmpty) {
    y += 2;
    var x = kCardPadding + 22;
    var rowHeight = 0.0;
    for (final tag in tags) {
      final p = layoutText(
        TextSpan(
          text: tag.label,
          style: canvasTextStyle(11, bold: true, color: tag.color),
        ),
        inner,
        maxLines: 1,
      );
      final size = Size(p.width + 14, p.height + 6);
      if (x + size.width > item.width - kCardPadding && x > kCardPadding + 22) {
        x = kCardPadding + 22;
        y += rowHeight + 4;
      }
      chips.add((Offset(x, y) & size, tag.color, p));
      x += size.width + 6;
      rowHeight = size.height;
    }
    y += rowHeight + 6;
  }
  if (asset?.kind == AssetKind.document) {
    add(
      TextSpan(
        text: 'PDF document · ${doubleClickWord.toLowerCase()} to open',
        style: canvasTextStyle(12, color: AppColors.textMuted),
      ),
      1,
    );
  }
  final url = asset?.url;
  if (url != null && title != displayUrl(url)) {
    add(
      TextSpan(
        text: displayUrl(url),
        style: canvasTextStyle(12, color: AppColors.textMuted),
      ),
      1,
    );
  }
  final description = asset?.description;
  if (description != null && description.trim().isNotEmpty) {
    y += 2;
    add(
      TextSpan(
        text: description.trim(),
        style: canvasTextStyle(
          12,
          color: AppColors.textFaint,
        ).copyWith(height: 1.35),
      ),
      3,
    );
  }
  return CardLayout(
    height: math.max(item.minHeight, y + kCardPadding - 2),
    lines: lines,
    previewHeight: preview,
    chips: chips,
  );
}

CardLayout layoutNoteCard(NoteCardItem item, Note? note) {
  final inner = item.width - kCardPadding * 2;
  var y = kCardPadding + 16;
  final lines = <(Offset, TextPainter)>[];
  final title = layoutText(
    TextSpan(
      text: note?.displayTitle ?? 'Missing note',
      style: canvasTextStyle(15, bold: true).copyWith(height: 1.3),
    ),
    inner,
    maxLines: 2,
  );
  lines.add((Offset(kCardPadding, y), title));
  y += title.height + 6;
  final body = note?.body.trim() ?? 'This note was deleted.';
  if (body.isNotEmpty) {
    final p = layoutText(
      formattedSpan(body, canvasTextStyle(13, color: AppColors.textMuted)),
      inner,
      maxLines: 8,
    );
    lines.add((Offset(kCardPadding, y), p));
    y += p.height;
  }
  return CardLayout(
    height: math.max(item.minHeight, y + kCardPadding),
    lines: lines,
  );
}
