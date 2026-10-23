import '../models/canvas_models.dart';
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

  @override
  Future<void> save(CanvasDocument document) =>
      store.write(_collection, document.id, document.toJson());

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
