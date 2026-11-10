import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/canvas_models.dart';
import '../storage/app_log.dart';
import '../storage/json_file_store.dart';

/// What the UI needs from canvas storage.
///
/// Screens only talk to this interface, so the storage engine (files today,
/// possibly SQLite later) or a sync layer can be swapped in underneath
/// without rewriting the screens.
abstract class CanvasRepository {
  Future<List<CanvasSummary>> listCanvases();
  Future<CanvasDocument?> load(String id);
  Future<void> save(CanvasDocument document);
  Future<void> delete(String id);

  /// Lowest schema version among stored canvases (for migrations).
  Future<int> oldestSchema();

  /// Highest schema version among stored canvases (to detect files written
  /// by a newer app version).
  Future<int> newestSchema();
}

class FileCanvasRepository implements CanvasRepository {
  FileCanvasRepository(this.store);

  static const _collection = 'canvases';

  final JsonFileStore store;

  @override
  Future<List<CanvasSummary>> listCanvases() async {
    final summaries = <CanvasSummary>[];
    for (final id in await store.list(_collection)) {
      final json = await store.read(_collection, id);
      if (json == null) continue;
      try {
        final text = StringBuffer();
        for (final item in json['items'] as List? ?? const []) {
          if (item is Map && item['type'] == 'text') {
            text.writeln(item['text']);
          }
        }
        summaries.add(
          CanvasSummary(
            id: json['id'] as String,
            title: json['title'] as String,
            updatedAt: DateTime.parse(json['updatedAt'] as String).toLocal(),
            folderId: json['folderId'] as String?,
            searchText: text.toString(),
            isNotebook: isNotebookId(id, json['kind'] as String?),
            isLinksBoard: isLinksBoardId(id, json['kind'] as String?),
            isCalendarInk: isCalendarInkId(id, json['kind'] as String?),
            isComponents: isComponentsId(id, json['kind'] as String?),
          ),
        );
      } catch (e) {
        // A canvas file that is readable JSON but not a canvas (a missing or
        // wrongly typed field, for example from a damaged disk) is left out
        // of the list instead of making the whole list, and every sync, fail.
        AppLog.warn('Canvas $id is not a valid canvas and was left out ($e)');
      }
    }
    summaries.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return summaries;
  }

  @override
  Future<int> oldestSchema() async {
    var oldest = CanvasDocument.schemaVersion;
    for (final id in await store.list(_collection)) {
      final json = await store.read(_collection, id);
      final schema = json?['schema'] as int? ?? 1;
      if (schema < oldest) oldest = schema;
    }
    return oldest;
  }

  @override
  Future<int> newestSchema() async {
    var newest = 0;
    for (final id in await store.list(_collection)) {
      final json = await store.read(_collection, id);
      final schema = json?['schema'] as int? ?? 1;
      if (schema > newest) newest = schema;
    }
    return newest;
  }

  @override
  Future<CanvasDocument?> load(String id) async {
    final json = await store.read(_collection, id);
    return json == null ? null : CanvasDocument.fromJson(json);
  }

  /// Drawings with at least this many Pencil samples are encoded on a
  /// background isolate (encoding 80 000 samples took 270–440 ms on the UI
  /// thread, a visible pause right when writing resumes).
  static const bigDrawing = 20000;

  @override
  Future<void> save(CanvasDocument document) {
    // The map is made now, so later edits cannot change this save.
    final json = document.toJson();
    var samples = 0;
    for (final item in document.items) {
      if (item is StrokeItem) samples += item.points.length;
    }
    if (samples < bigDrawing) return store.write(_collection, document.id, json);
    // Same text as store.write makes; its place in the order of saves is
    // taken now, so a later small save can never be overtaken.
    _packPoints(json);
    return store.writeText(
      _collection,
      document.id,
      _encodeOnIsolate(json),
    );
  }

  /// Static, so the isolate is sent only [json] (a closure made inside a
  /// method would also carry the repository and its store).
  static Future<String> _encodeOnIsolate(Map<String, dynamic> json) =>
      Isolate.run(() {
        _unpackPoints(json);
        return const JsonEncoder.withIndent(' ').convert(json);
      });

  /// Replaces each stroke's points by one flat [Float64List] of the numbers
  /// and a [Uint8List] of how many numbers each point has: sending a list of
  /// numbers to an isolate is one memory copy, while thousands of small
  /// lists are copied one by one on the UI thread (measured: most of the
  /// cost of starting the background save). A point is `[x, y, p]`, or with
  /// Pencil data `[x, y, p, time]` / `[x, y, p, time, altitude, azimuth]`
  /// (see [StrokePoint.toJson]); the time is a whole number, the rest are
  /// doubles. [_unpackPoints] restores the very same values and types, so
  /// the text is the same. Anything else is sent as it is.
  static void _packPoints(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is! List) return;
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final points = item['points'];
      if (points is! List || points.isEmpty) continue;
      var total = 0;
      var ok = true;
      for (final p in points) {
        if (p is! List || (p.length != 3 && p.length != 4 && p.length != 6)) {
          ok = false;
          break;
        }
        total += p.length;
      }
      if (!ok) continue;
      final flat = Float64List(total);
      final lengths = Uint8List(points.length);
      var o = 0;
      for (var i = 0; i < points.length && ok; i++) {
        final p = points[i] as List;
        lengths[i] = p.length;
        for (var k = 0; k < p.length; k++) {
          final v = p[k];
          if (k == 3 ? v is int : v is double) {
            flat[o++] = (v as num).toDouble();
          } else {
            ok = false; // Not the expected numbers: sent as it is.
            break;
          }
        }
      }
      if (ok) item['points'] = (flat, lengths);
    }
  }

  static void _unpackPoints(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is! List) return;
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final packed = item['points'];
      if (packed is! (Float64List, Uint8List)) continue;
      final (flat, lengths) = packed;
      var o = 0;
      item['points'] = [
        for (final n in lengths)
          [for (var k = 0; k < n; k++) k == 3 ? flat[o++].toInt() : flat[o++]],
      ];
    }
  }

  /// Visible for tests: the text a big drawing is saved as (packing, then
  /// unpacking, as the background save does).
  static String encodeLikeBackgroundSave(Map<String, dynamic> json) {
    _packPoints(json);
    _unpackPoints(json);
    return const JsonEncoder.withIndent(' ').convert(json);
  }

  /// Whether [json]'s strokes would all go to the background save as flat
  /// number lists (the fast way). Visible for tests.
  static bool packsCompletely(Map<String, dynamic> json) {
    _packPoints(json);
    final items = json['items'] as List? ?? const [];
    final ok = items.every(
      (i) => i is! Map || i['points'] is! List || (i['points'] as List).isEmpty,
    );
    _unpackPoints(json);
    return ok;
  }

  /// The oldest and newest schema among stored canvases, in one pass over
  /// the files (start-up used to read and decode every drawing twice for
  /// [oldestSchema] and [newestSchema]).
  Future<(int, int)> schemaRange() async {
    var oldest = CanvasDocument.schemaVersion;
    var newest = 0;
    for (final id in await store.list(_collection)) {
      final json = await store.read(_collection, id);
      final schema = json?['schema'] as int? ?? 1;
      if (schema < oldest) oldest = schema;
      if (schema > newest) newest = schema;
    }
    return (oldest, newest);
  }

  @override
  Future<void> delete(String id) => store.moveToTrash(_collection, id);
}

/// Small key/value settings (sidebar state, last opened canvas, ...).
class SettingsRepository {
  SettingsRepository(this.store);

  final JsonFileStore store;
  Map<String, dynamic> _values = {};

  Future<void> load() async {
    _values = await store.read('settings', 'app') ?? {};
  }

  T? get<T>(String key) {
    final value = _values[key];
    return value is T ? value : null;
  }

  Future<void> set(String key, Object? value) {
    _values[key] = value;
    return store.write('settings', 'app', _values);
  }
}
