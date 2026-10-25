// AI answers shown with their Markdown formatting: headings, lists,
// quotes, bold, italic, inline code and code blocks (with Copy). Links are
// shown with their address but are not opened from here: the address came
// from the AI, not the user.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdListItem extends MdBlock {
  const MdListItem(this.level, this.marker, this.text);
  final int level;

  /// "•" for bullets, "1." etc. for numbered items.
  final String marker;
  final String text;
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

class MdCode extends MdBlock {
  const MdCode(this.language, this.code);
  final String language;
  final String code;
}

class MdRule extends MdBlock {
  const MdRule();
}

final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*$');
final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
final _item = RegExp(r'^(\s*)([-*+•]|\d{1,3}[.)])\s+(.*)$');
final _quote = RegExp(r'^\s*>\s?(.*)$');

/// The blocks of [source]. A code block left open (an answer still being
/// written) runs to the end.
List<MdBlock> parseMarkdown(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final out = <MdBlock>[];
  final paragraph = <String>[];
  void flush() {
    if (paragraph.isEmpty) return;
    out.add(MdParagraph(paragraph.join('\n')));
    paragraph.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      flush();
      final fence = trimmed.substring(0, 3);
      final language = trimmed.substring(3).trim();
      final code = <String>[];
      for (i++; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith(fence)) break;
        code.add(lines[i]);
      }
      out.add(MdCode(language, code.join('\n')));
      continue;
    }
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    if (_heading.firstMatch(trimmed) case final m?) {
      flush();
      out.add(MdHeading(m.group(1)!.length, m.group(2)!));
    } else if (_rule.hasMatch(line)) {
      flush();
      out.add(const MdRule());
    } else if (_item.firstMatch(line) case final m?) {
      flush();
      final indent = m.group(1)!.replaceAll('\t', '  ').length;
      final marker = m.group(2)!;
      out.add(
        MdListItem(
          (indent ~/ 2).clamp(0, 6),
          RegExp(r'^\d').hasMatch(marker) ? marker : '•',
          m.group(3)!,
        ),
      );
    } else if (_quote.firstMatch(line) case final m?) {
      flush();
      out.add(MdQuote(m.group(1)!));
    } else {
      paragraph.add(line.trim());
    }
  }
  flush();
  return out;
}

enum MdStyle { bold, italic, code, link }

/// [text] cut into runs with their inline styles. A link run's text is its
/// label followed by its address in brackets.
List<(String, Set<MdStyle>)> inlineRuns(String text) {
  final pattern = RegExp(
    r'`([^`]+)`'
    r'|\*\*(.+?)\*\*'
    r'|__(.+?)__'
    r'|\*([^*\s](?:[^*]*[^*\s])?)\*'
    r'|(?<![A-Za-z0-9])_([^_\s](?:[^_]*[^_\s])?)_(?![A-Za-z0-9])'
    r'|\[([^\]]+)\]\(([^)\s]+)\)',
  );
  final out = <(String, Set<MdStyle>)>[];
  var at = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > at) out.add((text.substring(at, m.start), const {}));
    if (m.group(1) != null) {
      out.add((m.group(1)!, const {MdStyle.code}));
    } else if (m.group(2) ?? m.group(3) case final bold?) {
      for (final (t, s) in inlineRuns(bold)) {
        out.add((t, {...s, MdStyle.bold}));
      }
    } else if (m.group(4) ?? m.group(5) case final italic?) {
      for (final (t, s) in inlineRuns(italic)) {
        out.add((t, {...s, MdStyle.italic}));
      }
    } else {
      out.add(('${m.group(6)} (${m.group(7)})', const {MdStyle.link}));
    }
    at = m.end;
  }
  if (at < text.length) out.add((text.substring(at), const {}));
  return out;
}

/// Text that is selectable as a whole and copyable code blocks.
class AiMarkdown extends StatelessWidget {
  const AiMarkdown(this.text, {super.key, this.fontSize = 13});

  final String text;
  final double fontSize;

  static const _mono = 'Consolas';

  TextSpan _inline(String text, TextStyle base) => TextSpan(
    children: [
      for (final (t, styles) in inlineRuns(text))
        TextSpan(
          text: t,
          style: base.copyWith(
            fontWeight: styles.contains(MdStyle.bold) ? FontWeight.w700 : null,
            fontStyle: styles.contains(MdStyle.italic)
                ? FontStyle.italic
                : null,
            fontFamily: styles.contains(MdStyle.code) ? _mono : null,
            fontFamilyFallback: styles.contains(MdStyle.code)
                ? const ['Menlo', 'monospace']
                : null,
            backgroundColor: styles.contains(MdStyle.code)
                ? AppColors.selected
                : null,
            color: styles.contains(MdStyle.link) ? AppColors.accent : null,
            decoration: styles.contains(MdStyle.link)
                ? TextDecoration.underline
                : null,
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style
        .copyWith(fontSize: fontSize, height: 1.4);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final b in parseMarkdown(text))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: switch (b) {
                MdHeading(:final level, :final text) => Text.rich(
                  _inline(
                    text,
                    base.copyWith(
                      fontSize:
                          fontSize +
                          (level <= 1
                              ? 5
                              : level == 2
                              ? 3
                              : 1),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                MdParagraph(:final text) => Text.rich(_inline(text, base)),
                MdListItem(:final level, :final marker, :final text) => Padding(
                  padding: EdgeInsets.only(left: 14.0 * level),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: marker == '•' ? 14 : 24,
                        child: Text(marker, style: base),
                      ),
                      Expanded(child: Text.rich(_inline(text, base))),
                    ],
                  ),
                ),
                MdQuote(:final text) => Container(
                  padding: const EdgeInsets.only(left: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: AppColors.textFaint, width: 3),
                    ),
                  ),
                  child: Text.rich(
                    _inline(text, base.copyWith(color: AppColors.textMuted)),
                  ),
                ),
                MdCode(:final language, :final code) => _CodeBlock(
                  language: language,
                  code: code,
                  fontSize: fontSize - 1,
                ),
                MdRule() => const Divider(),
              },
            ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({
    required this.language,
    required this.code,
    required this.fontSize,
  });

  final String language;
  final String code;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.selected,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                language.isEmpty ? 'Code' : language,
                style: TextStyle(fontSize: 11, color: AppColors.textFaint),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('ai-code-copy'),
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              icon: const Icon(Icons.copy, size: 13),
              label: const Text('Copy', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Text(
            code,
            style: TextStyle(
              fontFamily: AiMarkdown._mono,
              fontFamilyFallback: const ['Menlo', 'monospace'],
              fontSize: fontSize,
              height: 1.35,
            ),
          ),
        ),
      ],
    ),
  );
}
