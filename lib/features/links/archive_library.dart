// Archive organization and link maintenance: the Archive folder tree
// (separate from note folders), where each resource is used (backlinks),
// references to resources that no longer exist, and duplicate resources.
// Every repair is undoable and is preceded by a backup (AppState).
import '../../data/models/calendar_models.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart';
import '../../data/models/task_models.dart';
import '../../data/repositories/canvas_repository.dart';
import '../../data/workspace.dart';

extension ArchiveFolders on Workspace {
  Folder createArchiveFolder(String name, {String? parentId}) {
    final f = Folder(
      id: newId(),
      name: name.trim().isEmpty ? 'Folder' : name.trim(),
      parentId: archiveFolders[parentId]?.id,
      updatedAt: DateTime.now(),
    );
    archiveFolders.put(f);
    return f;
  }

  void renameArchiveFolder(String id, String name) {
    final f = archiveFolders[id];
    if (f == null || name.trim().isEmpty) return;
    archiveFolders.put(f.copyWith(name: name.trim()));
  }

  /// Folder [id] and every folder inside it.
  Set<String> archiveSubtree(String id) {
    final ids = {id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final f in archiveFolders.all) {
        if (f.parentId != null && ids.contains(f.parentId) && ids.add(f.id)) {
          grew = true;
        }
      }
    }
    return ids;
  }

  /// Moves folder [id] into [parentId] (null = top). Refuses to move a
  /// folder into itself or one of its own folders.
  bool moveArchiveFolder(String id, String? parentId) {
    final f = archiveFolders[id];
    if (f == null) return false;
    if (parentId != null &&
        (archiveFolders[parentId] == null ||
            archiveSubtree(id).contains(parentId))) {
      return false;
    }
    if (f.parentId != parentId) {
      archiveFolders.put(f.copyWith(parentId: () => parentId));
    }
    return true;
  }

  /// Removes a folder; what was inside moves up one level.
  void deleteArchiveFolder(String id) {
    final f = archiveFolders[id];
    if (f == null) return;
    for (final c
        in archiveFolders.all.where((c) => c.parentId == id).toList()) {
      archiveFolders.put(c.copyWith(parentId: () => f.parentId));
    }
    for (final a in assets.all.where((a) => a.folderId == id).toList()) {
      assets.put(a.copyWith(folderId: () => f.parentId));
    }
    archiveFolders.remove(id);
  }

  void moveAssetToFolder(String assetId, String? folderId) {
    final a = assets[assetId];
    if (a == null || a.folderId == folderId) return;
    if (folderId != null && archiveFolders[folderId] == null) return;
    assets.put(a.copyWith(folderId: () => folderId));
  }

  /// "Study / Biology" for folder [id] ('' for the top).
  String archiveFolderLabel(String? id) {
    final names = <String>[];
    final seen = <String>{};
    var f = archiveFolders[id];
    while (f != null && seen.add(f.id)) {
      names.insert(0, f.name);
      f = archiveFolders[f.parentId];
    }
    return names.join(' / ');
  }
}

/// Something that refers to a resource.
class ResourceRef {
  const ResourceRef(this.kind, this.id, this.title);

  /// 'note', 'task', 'entry', 'day', 'canvas'.
  final String kind;
  final String id;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is ResourceRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// Every reference to a resource, by resource id (including ids of
/// resources that no longer exist).
Future<Map<String, Set<ResourceRef>>> referenceMap(
  Workspace ws,
  CanvasRepository canvases,
) async {
  final map = <String, Set<ResourceRef>>{};
  void add(String assetId, ResourceRef r) =>
      (map[assetId] ??= <ResourceRef>{}).add(r);
  for (final n in ws.notes.all) {
    for (final id in n.assetIds) {
      add(id, ResourceRef('note', n.id, n.displayTitle));
    }
  }
  for (final t in ws.tasks.all) {
    for (final id in t.assetIds) {
      add(id, ResourceRef('task', t.id, t.title));
    }
  }
  for (final e in ws.entries.all) {
    for (final id in e.assetIds) {
      add(id, ResourceRef('entry', e.id, e.name));
    }
  }
  for (final d in ws.days.all) {
    for (final id in d.assetIds) {
      add(id, ResourceRef('day', d.id, d.id));
    }
  }
  for (final summary in await canvases.listCanvases()) {
    final doc = await canvases.load(summary.id);
    if (doc == null) continue;
    final ref = ResourceRef('canvas', doc.id, doc.title);
    for (final item in doc.items) {
      switch (item) {
        case LinkItem(:final assetId) || ImageItem(:final assetId):
          add(assetId, ref);
        default:
      }
    }
    for (final p in doc.pageBackgrounds) {
      add(p.assetId, ref);
    }
  }
  return map;
}

/// What the link check found.
class LinkReport {
  const LinkReport({required this.broken, required this.duplicates});

  /// Missing resource id → the records still referring to it.
  final Map<String, Set<ResourceRef>> broken;

  /// Groups of resources that are the same link or the same file; the
  /// first of each group is the oldest (the one kept when merging).
  final List<List<Asset>> duplicates;

  bool get isClean => broken.isEmpty && duplicates.isEmpty;
}

/// `https://www.Example.com/a/?utm_source=x#top` → `example.com/a`
String normalizedUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return url.trim().toLowerCase();
  var host = uri.host.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final query = Map.of(uri.queryParameters)
    ..removeWhere((k, _) => k.startsWith('utm_') || k == 'fbclid');
  final q = query.isEmpty
      ? ''
      : '?${(query.keys.toList()..sort()).map((k) => '$k=${query[k]}').join('&')}';
  return '$host$path$q';
}

LinkReport checkLinks(Workspace ws, Map<String, Set<ResourceRef>> refs) {
  final broken = <String, Set<ResourceRef>>{
    for (final MapEntry(:key, :value) in refs.entries)
      if (ws.assets[key] == null) key: value,
  };
  final groups = <String, List<Asset>>{};
  for (final a in ws.assets.all) {
    final key = switch (a) {
      Asset(kind: AssetKind.link, :final url?) => 'u:${normalizedUrl(url)}',
      Asset(:final fileSha256?) => 's:$fileSha256',
      _ => null,
    };
    if (key != null) (groups[key] ??= []).add(a);
  }
  final duplicates = [
    for (final g in groups.values)
      if (g.length > 1) g..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
  ];
  return LinkReport(broken: broken, duplicates: duplicates);
}

/// Records as they were before a repair, to put back on undo.
class ArchiveUndo {
  ArchiveUndo(this.label);
  final String label;
  final List<Asset> assets = [];
  final List<Note> notes = [];
  final List<Task> tasks = [];
  final List<CalendarEntry> entries = [];
  final List<DayRecord> days = [];

  bool get isEmpty =>
      assets.isEmpty &&
      notes.isEmpty &&
      tasks.isEmpty &&
      entries.isEmpty &&
      days.isEmpty;

  void apply(Workspace ws) {
    ws.assets.putAll(assets);
    ws.notes.putAll(notes);
    ws.tasks.putAll(tasks);
    ws.entries.putAll(entries);
    ws.days.putAll(days);
  }
}

/// Replaces resource id [from] with [to] (or removes it when [to] is
/// null) in notes, tasks, calendar entries and days. Canvases are left
/// alone: their cards are changed by opening them.
void _rewrite(Workspace ws, String from, String? to, ArchiveUndo undo) {
  List<String> swap(List<String> ids) => [
    for (final id in ids)
      if (id != from) id else if (to != null && !ids.contains(to)) to,
  ];
  for (final n
      in ws.notes.all.where((n) => n.assetIds.contains(from)).toList()) {
    undo.notes.add(n);
    ws.notes.put(n.copyWith(assetIds: swap(n.assetIds)));
  }
  for (final t
      in ws.tasks.all.where((t) => t.assetIds.contains(from)).toList()) {
    undo.tasks.add(t);
    ws.tasks.put(t.copyWith(assetIds: swap(t.assetIds)));
  }
  for (final e
      in ws.entries.all.where((e) => e.assetIds.contains(from)).toList()) {
    undo.entries.add(e);
    ws.entries.put(e.copyWith(assetIds: swap(e.assetIds)));
  }
  for (final d
      in ws.days.all.where((d) => d.assetIds.contains(from)).toList()) {
    undo.days.add(d);
    ws.days.put(d.copyWith(assetIds: swap(d.assetIds)));
  }
}

/// Removes references to missing resources from notes, tasks and the
/// calendar. Returns what to undo, and how many canvases still show a
/// missing card (to be removed there by hand).
(ArchiveUndo, int) removeBrokenReferences(Workspace ws, LinkReport report) {
  final undo = ArchiveUndo('Remove broken references');
  final canvases = <String>{};
  for (final MapEntry(:key, :value) in report.broken.entries) {
    _rewrite(ws, key, null, undo);
    canvases.addAll([
      for (final r in value)
        if (r.kind == 'canvas') r.id,
    ]);
  }
  return (undo, canvases.length);
}

/// Merges a duplicate group into its first (oldest) resource: tags,
/// projects and missing details are combined, references move to it, and
/// duplicates no mindmap still shows are removed. Returns what to undo and
/// the duplicates kept because a mindmap shows them.
(ArchiveUndo, List<Asset>) mergeDuplicates(
  Workspace ws,
  List<Asset> group,
  Map<String, Set<ResourceRef>> refs,
) {
  final undo = ArchiveUndo('Merge duplicates');
  if (group.length < 2) return (undo, const []);
  var keep = ws.assets[group.first.id] ?? group.first;
  undo.assets.add(keep);
  final kept = <Asset>[];
  for (final dup in group.skip(1)) {
    final d = ws.assets[dup.id];
    if (d == null) continue;
    keep = keep.copyWith(
      title: (keep.title ?? '').trim().isEmpty ? d.title : null,
      description: (keep.description ?? '').trim().isEmpty
          ? d.description
          : null,
      linkTags: {...keep.linkTags, ...d.linkTags}.toList(),
      projectIds: {...keep.projectIds, ...d.projectIds}.toList(),
      folderId: keep.folderId == null ? () => d.folderId : null,
    );
    _rewrite(ws, d.id, keep.id, undo);
    if ((refs[d.id] ?? const {}).any((r) => r.kind == 'canvas')) {
      kept.add(d);
    } else {
      undo.assets.add(d);
      ws.assets.remove(d.id);
    }
  }
  ws.assets.put(keep);
  return (undo, kept);
}
