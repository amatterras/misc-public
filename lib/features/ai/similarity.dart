// Finding notes that say the same thing (possible duplicates) and
// searching by meaning. Similar-text detection compares words and works
// offline without AI. Search by meaning uses the local model's embeddings
// (Ollama) and only runs when the user asks for it; it never uses a
// service outside this PC.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../data/models/library_models.dart';

Set<String> _words(String text) => {
  for (final w in text.toLowerCase().split(
    RegExp(r'[^\p{L}\p{N}]+', unicode: true),
  ))
    if (w.length > 2) w,
};

/// How much of their wording two texts share (0..1).
double textSimilarity(String a, String b) {
  final x = _words(a), y = _words(b);
  if (x.isEmpty || y.isEmpty) return 0;
  final common = x.intersection(y).length;
  return common / (x.length + y.length - common);
}

/// Pairs of notes whose text is at least [threshold] similar, most
/// similar first. Notes with very little text are skipped.
List<(Note, Note, double)> similarNotes(
  Iterable<Note> notes, {
  double threshold = 0.6,
}) {
  final list = [
    for (final n in notes)
      if (_words('${n.title} ${n.body}').length >= 4) n,
  ];
  final words = {for (final n in list) n.id: _words('${n.title} ${n.body}')};
  final pairs = <(Note, Note, double)>[];
  for (var i = 0; i < list.length; i++) {
    for (var j = i + 1; j < list.length; j++) {
      final x = words[list[i].id]!, y = words[list[j].id]!;
      final common = x.intersection(y).length;
      final score = common / (x.length + y.length - common);
      if (score >= threshold) pairs.add((list[i], list[j], score));
    }
  }
  return pairs..sort((a, b) => b.$3.compareTo(a.$3));
}

double cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length && i < b.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na == 0 || nb == 0 ? 0 : dot / (math.sqrt(na) * math.sqrt(nb));
}

/// Embeddings from the local model (Ollama /api/embed).
typedef Embedder = Future<List<List<double>>> Function(List<String> texts);

Embedder ollamaEmbedder(Uri endpoint, {String model = 'nomic-embed-text'}) =>
    (texts) async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client.postUrl(endpoint.resolve('/api/embed'));
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode({'model': model, 'input': texts})));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode >= 400) {
          throw HttpException('embed failed (${response.statusCode})');
        }
        final list = (jsonDecode(body) as Map)['embeddings'] as List;
        return [
          for (final e in list)
            [for (final v in e as List) (v as num).toDouble()],
        ];
      } finally {
        client.close(force: true);
      }
    };

/// Notes ranked by meaning for [query]. Embeddings of unchanged notes are
/// kept in memory (this session only), so a repeat search is quick.
class SemanticIndex {
  SemanticIndex(this.embed);
  final Embedder embed;
  final Map<String, (DateTime, List<double>)> _cache = {};

  Future<List<(Note, double)>> search(
    String query,
    Iterable<Note> notes, {
    int limit = 10,
  }) async {
    final todo = [
      for (final n in notes)
        if (_cache[n.id]?.$1 != n.updatedAt) n,
    ];
    for (var i = 0; i < todo.length; i += 32) {
      final batch = todo.skip(i).take(32).toList();
      final vectors = await embed([
        for (final n in batch) '${n.displayTitle}\n${n.body}',
      ]);
      for (var k = 0; k < batch.length && k < vectors.length; k++) {
        _cache[batch[k].id] = (batch[k].updatedAt, vectors[k]);
      }
    }
    final q = (await embed([query])).first;
    final scored = [
      for (final n in notes)
        if (_cache[n.id] case (_, final v)) (n, cosine(q, v)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(limit).toList();
  }
}
