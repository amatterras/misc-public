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

  /// Replaces each stroke's points (`[[x, y, p], ...]`) by one flat
  /// [Float64List]: sending a list of numbers to an isolate is one memory
  /// copy, while thousands of small lists are copied one by one on the UI
  /// thread (measured: most of the cost of starting the background save).
  /// [_unpackPoints] restores the very same values, so the text is the same.
  static void _packPoints(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is! List) return;
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final points = item['points'];
      if (points is! List || points.isEmpty) continue;
      final flat = Float64List(points.length * 3);
      var ok = true;
      for (var i = 0; i < points.length && ok; i++) {
        final p = points[i];
        if (p is List && p.length == 3) {
          for (var k = 0; k < 3; k++) {
            final v = p[k];
            if (v is double) {
              flat[i * 3 + k] = v;
            } else {
              ok = false; // Not plain numbers: sent as it is.
            }
          }
        } else {
          ok = false;
        }
      }
      if (ok) item['points'] = flat;
    }
  }

  static void _unpackPoints(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is! List) return;
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final flat = item['points'];
      if (flat is! Float64List) continue;
      item['points'] = [
        for (var i = 0; i < flat.length; i += 3)
          [flat[i], flat[i + 1], flat[i + 2]],
      ];
    }
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
