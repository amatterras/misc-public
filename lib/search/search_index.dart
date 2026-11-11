// One search index for the whole workspace: a local, in-memory, rebuildable
// inverted index. It never holds the only copy of anything (it is made from
// the records and can be thrown away at any time), and it does not touch
// disk, so there is nothing to migrate, back up or sync.
//
// A document has a kind, an id, a title and named text fields (title, tags,
// body, url…) with a weight each. Fields may be split in pages (a PDF's
// pages, a notebook's pages) so a hit can say which page matched.
//
// Querying: every word of the query must match (in any field). A word
// matches a whole word of the text, the start of one (so results appear
// while typing) or, from three letters on, any part of one ("ount" finds
// "account"). Case, accents and punctuation never matter. When nothing
// matches word by word, the query is also tried with its spaces and
// punctuation removed against the text with theirs removed ("to do" finds
// "to-do" and "todo", "mind map" finds "mindmap"). Ranking: title beats tags
// beats other fields; an exact phrase in the title and exact words rank above
// prefix matches, and those above partial ones. Each hit says which fields
// matched, shows a snippet around the match and, for paged fields, the page.
//
// Pure Dart (no Flutter).
import 'dart:math';

enum DocKind {
  note,
  notebookPage,
  task,
  project,
  entry,
  link,
  document,
  archive,
  folder,
  canvas,
  bookmark,
  aiChat,
  experiment,

  /// Text typed on the Calendar's drawing layer, by day (not the strokes).
  calendarNote,
}

/// One searchable text of a document. [pages] set: the text is split in
/// pages (1-based when reported).
class SearchField {
  const SearchField(this.name, this.text, {this.weight = 2, this.pages});

  final String name;
  final String text;
  final double weight;
  final List<String>? pages;

  SearchField withPages(List<String> p) =>
      SearchField(name, p.join('\n'), weight: weight, pages: p);
}

class IndexedDoc {
  IndexedDoc({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.fields = const [],
    this.version = '',
  });

  final DocKind kind;
  final String id;
  final String title;
  final String subtitle;
  final List<SearchField> fields;

  /// Changes whenever the source record changes (a revision or a hash): the
  /// indexer re-reads only documents whose version differs.
  final String version;

  String get key => '${kind.name}:$id';
}

class SearchHit {
  const SearchHit({
    required this.doc,
    required this.score,
    required this.reasons,
    required this.snippet,
    this.page,
  });

  final IndexedDoc doc;
  final double score;

  /// Names of the fields the query matched in ("title", "tags", "body"…).
  final List<String> reasons;
  final String snippet;

  /// For paged fields: the first page that matched (1-based).
  final int? page;
}

final _splitter = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Accented letters by their plain letter (the first of each group). One
/// character for one character, so a position in the folded text is the
/// same position in the original.
const _accentGroups = [
  'aàáâãäåāăą',
  'cçćĉċč',
  'dďđ',
  'eèéêëēĕėęě',
  'gĝğġģ',
  'hĥħ',
  'iìíîïĩīĭįı',
  'jĵ',
  'kķ',
  'lĺļľŀł',
  'nñńņň',
  'oòóôõöøōŏő',
  'rŕŗř',
  'sśŝşš',
  'tţťŧ',
  'uùúûüũūŭůűų',
  'wŵ',
  'yýÿŷ',
  'zźżž',
];
final Map<int, String> _accentFold = {
  for (final group in _accentGroups)
    for (final r in group.runes.skip(1)) r: String.fromCharCode(group.runes.first),
};

/// [text] in lower case with accents removed: what the index compares.
String foldText(String text) {
  final lower = text.toLowerCase();
  // Plain ASCII (most text) needs no folding.
  var plain = true;
  for (var i = 0; i < lower.length; i++) {
    if (lower.codeUnitAt(i) > 0x7f) {
      plain = false;
      break;
    }
  }
  if (plain) return lower;
  final codes = <int>[];
  for (final r in lower.runes) {
    final plainLetter = _accentFold[r];
    codes.add(plainLetter == null ? r : plainLetter.codeUnitAt(0));
  }
  return String.fromCharCodes(codes);
}

/// Lower-case, accent-free words of [text].
List<String> tokenize(String text) => [
  for (final w in foldText(text).split(_splitter))
    if (w.isNotEmpty) w,
];

/// [text] reduced to its letters and digits, folded: spacing and punctuation
/// removed.
String compactText(String text) => foldText(text).replaceAll(_splitter, '');

/// Shortest word that is also looked for inside other words.
const _infixMinLength = 3;

/// Where [query] matches in [text] (for highlighting): the places where a
/// query word occurs, plus, when no word occurs, the run of text that equals
/// the query once spaces and punctuation are ignored. Sorted, not
/// overlapping.
List<({int start, int end})> matchRanges(String text, String query) {
  final folded = foldText(text);
  final words = tokenize(query);
  if (words.isEmpty) return const [];
  final spans = <({int start, int end})>[];
  for (final w in words.toSet()) {
    var from = 0;
    while (true) {
      final i = folded.indexOf(w, from);
      if (i < 0) break;
      spans.add((start: i, end: i + w.length));
      from = i + w.length;
    }
  }
  if (spans.isEmpty) {
    // Spacing / punctuation variations: the letters in order with anything
    // that is not a letter or digit between them.
    final letters = words.join().split('');
    final pattern = letters.map(RegExp.escape).join(r'[^\p{L}\p{N}]*');
    final m = RegExp(pattern, unicode: true).firstMatch(folded);
    if (m != null) spans.add((start: m.start, end: m.end));
  }
  spans.sort((a, b) => a.start.compareTo(b.start));
  final merged = <({int start, int end})>[];
  for (final s in spans) {
    if (merged.isNotEmpty && s.start <= merged.last.end) {
      final last = merged.removeLast();
      merged.add((start: last.start, end: s.end > last.end ? s.end : last.end));
    } else {
      merged.add(s);
    }
  }
  return merged;
}

class SearchIndex {
  final Map<String, IndexedDoc> _docs = {};
  final Map<String, Map<String, Set<String>>> _fieldTerms =
      {}; // doc → field → terms
  final Map<String, Set<String>> _postings = {}; // term → doc keys
  // doc → field → letters and digits only, for the spacing fallback. Built
  // the first time a query needs it (most never do), then kept current.
  Map<String, Map<String, String>>? _compact;
  List<String>? _sortedTerms;

  int get length => _docs.length;
  IndexedDoc? operator [](String key) => _docs[key];
  Iterable<String> get keys => _docs.keys;

  /// Adds or replaces a document.
  void upsert(IndexedDoc d) {
    remove(d.key);
    _docs[d.key] = d;
    final byField = <String, Set<String>>{};
    final all = <String>{};
    final titleTerms = tokenize(d.title).toSet();
    byField['title'] = titleTerms;
    all.addAll(titleTerms);
    for (final f in d.fields) {
      final terms = tokenize(f.text).toSet();
      (byField[f.name] ??= {}).addAll(terms);
      all.addAll(terms);
    }
    _fieldTerms[d.key] = byField;
    _compact?[d.key] = _compactOf(d);
    for (final t in all) {
      (_postings[t] ??= {}).add(d.key);
    }
    _sortedTerms = null;
  }

  void remove(String key) {
    final old = _docs.remove(key);
    _compact?.remove(key);
    if (old == null) return;
    final byField = _fieldTerms.remove(key) ?? const {};
    final terms = <String>{for (final s in byField.values) ...s};
    for (final t in terms) {
      final p = _postings[t];
      if (p == null) continue;
      p.remove(key);
      if (p.isEmpty) _postings.remove(t);
    }
    _sortedTerms = null;
  }

  void clear() {
    _compact = null;
    _docs.clear();
    _fieldTerms.clear();
    _postings.clear();
    _sortedTerms = null;
  }

  List<String> get _terms => _sortedTerms ??= _postings.keys.toList()..sort();

  /// Terms starting with [prefix] (up to [limit]).
  Iterable<String> _withPrefix(String prefix, {int limit = 60}) sync* {
    final terms = _terms;
    var lo = 0, hi = terms.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (terms[mid].compareTo(prefix) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var n = 0;
    for (var i = lo; i < terms.length && n < limit; i++, n++) {
      if (!terms[i].startsWith(prefix)) return;
      yield terms[i];
    }
  }

  /// Ranked hits for [query]. [kinds] limits the kinds; [limit] caps the
  /// number of hits.
  List<SearchHit> query(String query, {Set<DocKind>? kinds, int limit = 100}) {
    final words = tokenize(query);
    if (words.isEmpty) return const [];
    // Per word: document key → (best score, matched field names).
    final perWord = <Map<String, ({double score, Set<String> fields})>>[];
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      final matches = <String, ({double score, Set<String> fields})>{};
      // Whole word, start of a word, then (longer words) part of a word.
      final candidates = <String, double>{
        if (_postings.containsKey(w)) w: 1.0,
        for (final t in _withPrefix(w, limit: 200)) t: 0.7,
        if (w.length >= _infixMinLength)
          for (final t in _containing(w, limit: 200)) t: 0.4,
      };
      for (final entry in candidates.entries) {
        final term = entry.key;
        final factor = entry.value;
        for (final key in _postings[term] ?? const <String>{}) {
          final doc = _docs[key]!;
          if (kinds != null && !kinds.contains(doc.kind)) continue;
          final byField = _fieldTerms[key]!;
          var best = 0.0;
          final fields = <String>{};
          byField.forEach((name, terms) {
            if (!terms.contains(term)) return;
            final weight = name == 'title'
                ? 10.0
                : doc.fields
                      .firstWhere(
                        (f) => f.name == name,
                        orElse: () => const SearchField('', ''),
                      )
                      .weight;
            final s = weight * factor;
            fields.add(name);
            if (s > best) best = s;
          });
          final old = matches[key];
          if (old == null || best > old.score) {
            matches[key] = (score: best, fields: {...?old?.fields, ...fields});
          } else {
            old.fields.addAll(fields);
          }
        }
      }
      if (matches.isEmpty) return _spacingFallback(words, kinds, limit);
      perWord.add(matches);
    }
    // Every word must match: intersect.
    var keys = perWord.first.keys.toSet();
    for (final m in perWord.skip(1)) {
      keys = keys.intersection(m.keys.toSet());
    }
    if (keys.isEmpty) return _spacingFallback(words, kinds, limit);
    final phrase = words.join(' ');
    final hits = <SearchHit>[];
    for (final key in keys) {
      final doc = _docs[key]!;
      var score = 0.0;
      final reasons = <String>{};
      for (final m in perWord) {
        score += m[key]!.score;
        reasons.addAll(m[key]!.fields);
      }
      if (words.length > 1 && doc.title.toLowerCase().contains(phrase)) {
        score += 8; // the whole phrase in the title
      }
      if (doc.title.toLowerCase() == phrase) score += 10;
      final (snippet, page) = _snippet(doc, words);
      hits.add(
        SearchHit(
          doc: doc,
          score: score,
          reasons: _orderReasons(reasons),
          snippet: snippet,
          page: page,
        ),
      );
    }
    hits.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.doc.title.compareTo(b.doc.title);
    });
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  /// Terms that contain [part] somewhere inside (not at the start: those
  /// are the prefix matches).
  Iterable<String> _containing(String part, {int limit = 200}) sync* {
    var n = 0;
    for (final t in _terms) {
      if (n >= limit) return;
      if (t.length > part.length && t.contains(part) && !t.startsWith(part)) {
        n++;
        yield t;
      }
    }
  }

  static const _compactMaxLength = 20000;

  /// Letters-and-digits form of the short fields (a long text such as a PDF
  /// is only matched word by word, to keep this small).
  static Map<String, String> _compactOf(IndexedDoc d) {
    final compact = <String, String>{'title': compactText(d.title)};
    for (final f in d.fields) {
      if (f.pages != null || f.text.length > _compactMaxLength) continue;
      compact[f.name] = '${compact[f.name] ?? ''}${compactText(f.text)}';
    }
    return compact;
  }

  /// "to do" / "to-do" / "todo": the query with spaces and punctuation
  /// removed, looked for in the documents' text with theirs removed. Only
  /// used when matching word by word found nothing.
  List<SearchHit> _spacingFallback(
    List<String> words,
    Set<DocKind>? kinds,
    int limit,
  ) {
    final needle = words.join();
    if (needle.length < 2) return const [];
    final hits = <SearchHit>[];
    final all = _compact ??= {
      for (final e in _docs.entries) e.key: _compactOf(e.value),
    };
    for (final entry in all.entries) {
      final doc = _docs[entry.key]!;
      if (kinds != null && !kinds.contains(doc.kind)) continue;
      final reasons = <String>{};
      var score = 0.0;
      entry.value.forEach((field, compact) {
        if (!compact.contains(needle)) return;
        reasons.add(field);
        final weight = field == 'title'
            ? 10.0
            : doc.fields
                  .firstWhere(
                    (f) => f.name == field,
                    orElse: () => const SearchField('', ''),
                  )
                  .weight;
        if (weight * 0.5 > score) score = weight * 0.5;
      });
      if (reasons.isEmpty) continue;
      final (snippet, page) = _snippet(doc, words);
      hits.add(
        SearchHit(
          doc: doc,
          score: score,
          reasons: _orderReasons(reasons),
          snippet: snippet,
          page: page,
        ),
      );
    }
    hits.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.doc.title.compareTo(b.doc.title);
    });
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  static List<String> _orderReasons(Set<String> r) {
    const order = ['title', 'tags', 'project', 'url'];
    final list = r.toList()
      ..sort((a, b) {
        final ia = order.indexOf(a), ib = order.indexOf(b);
        return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
      });
    return list;
  }

  /// A short text around the first match in the best non-title field (and the
  /// page, for paged fields).
  (String, int?) _snippet(IndexedDoc doc, List<String> words) {
    final query = words.join(' ');
    bool has(String text) {
      final l = foldText(text);
      return words.every(l.contains);
    }

    bool any(String text) => matchRanges(text, query).isNotEmpty;

    // Paged text first: the first page where every word occurs, else the
    // first page with any.
    for (final f in doc.fields) {
      final pages = f.pages;
      if (pages == null) continue;
      for (var i = 0; i < pages.length; i++) {
        if (has(pages[i])) return (_around(pages[i], query), i + 1);
      }
      for (var i = 0; i < pages.length; i++) {
        if (any(pages[i])) return (_around(pages[i], query), i + 1);
      }
    }
    SearchField? best;
    for (final f in doc.fields) {
      if (!any(f.text)) continue;
      if (best == null || f.weight > best.weight) best = f;
    }
    if (best != null) return (_around(best.text, query), null);
    return (doc.subtitle, null);
  }

  static String _around(String text, String query) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final spans = matchRanges(flat, query);
    if (spans.isEmpty) {
      return flat.length > 100 ? '${flat.substring(0, 100)}…' : flat;
    }
    final at = spans.first.start;
    final start = max(0, at - 36);
    final end = min(flat.length, at + 80);
    return '${start > 0 ? '…' : ''}${flat.substring(start, end)}'
        '${end < flat.length ? '…' : ''}';
  }
}
