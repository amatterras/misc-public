// One search index for the whole workspace: a local, in-memory, rebuildable
// inverted index. It never holds the only copy of anything (it is made from
// the records and can be thrown away at any time), and it does not touch
// disk, so there is nothing to migrate, back up or sync.
//
// A document has a kind, an id, a title and named text fields (title, tags,
// body, url…) with a weight each. Fields may be split in pages (a PDF's
// pages, a notebook's pages) so a hit can say which page matched.
//
// Querying: every word of the query must match (in any field); the last word
// also matches as a prefix (so results appear while typing). Ranking: title
// beats tags beats other fields; an exact phrase in the title and exact
// words rank above prefix matches. Each hit says which fields matched, shows
// a snippet around the match and, for paged fields, the page.
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

/// Lower-case words of [text].
List<String> tokenize(String text) => [
  for (final w in text.toLowerCase().split(_splitter))
    if (w.isNotEmpty) w,
];

class SearchIndex {
  final Map<String, IndexedDoc> _docs = {};
  final Map<String, Map<String, Set<String>>> _fieldTerms =
      {}; // doc → field → terms
  final Map<String, Set<String>> _postings = {}; // term → doc keys
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
    for (final t in all) {
      (_postings[t] ??= {}).add(d.key);
    }
    _sortedTerms = null;
  }

  void remove(String key) {
    final old = _docs.remove(key);
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
      final last = i == words.length - 1;
      final matches = <String, ({double score, Set<String> fields})>{};
      final candidates = <String>{
        if (_postings.containsKey(w)) w,
        if (last) ..._withPrefix(w),
      };
      for (final term in candidates) {
        final exact = term == w;
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
            final s = weight * (exact ? 1.0 : 0.7);
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
      if (matches.isEmpty) return const [];
      perWord.add(matches);
    }
    // Every word must match: intersect.
    var keys = perWord.first.keys.toSet();
    for (final m in perWord.skip(1)) {
      keys = keys.intersection(m.keys.toSet());
    }
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
    bool has(String text) {
      final l = text.toLowerCase();
      return words.every((w) => l.contains(w));
    }

    // Paged text first: the first page where every word occurs, else the
    // first page with any.
    for (final f in doc.fields) {
      final pages = f.pages;
      if (pages == null) continue;
      for (var i = 0; i < pages.length; i++) {
        if (has(pages[i])) return (_around(pages[i], words), i + 1);
      }
      for (var i = 0; i < pages.length; i++) {
        final l = pages[i].toLowerCase();
        if (words.any(l.contains)) return (_around(pages[i], words), i + 1);
      }
    }
    SearchField? best;
    for (final f in doc.fields) {
      final l = f.text.toLowerCase();
      if (!words.any(l.contains)) continue;
      if (best == null || f.weight > best.weight) best = f;
    }
    if (best != null) return (_around(best.text, words), null);
    return (doc.subtitle, null);
  }

  static String _around(String text, List<String> words) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final lower = flat.toLowerCase();
    var at = -1;
    for (final w in words) {
      final i = lower.indexOf(w);
      if (i >= 0 && (at < 0 || i < at)) at = i;
    }
    if (at < 0) return flat.length > 100 ? '${flat.substring(0, 100)}…' : flat;
    final start = max(0, at - 36);
    final end = min(flat.length, at + 80);
    return '${start > 0 ? '…' : ''}${flat.substring(start, end)}'
        '${end < flat.length ? '…' : ''}';
  }
}
