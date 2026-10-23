// Mindmap branch → tasks. A text item and everything below it (following
// connectors from parent to child) becomes a project with one task per
// item, subtasks following the branch; a lone item becomes one task. Each
// item remembers its task (an item mark), so converting again updates the
// same tasks instead of making copies, and the branch shows how much of it
// is done. A branch can also become an indented note draft.
import '../../data/models/canvas_models.dart';
import '../../data/models/task_models.dart';
import '../../data/workspace.dart';
import 'canvas_controller.dart';

const taskMark = 'taskId';
const projectMark = 'projectId';

/// Most items converted at once.
const maxBranchItems = 300;

/// One item of a branch: the item, its depth and its parent item.
typedef BranchNode = ({TextItem item, int depth, String? parent});

String _label(TextItem i) {
  final line = i.text.trim().split('\n').first.trim();
  return line.length > 200 ? line.substring(0, 200) : line;
}

/// The text items of the branch under [rootId], parents before children.
/// Each item appears once even if connectors loop back.
List<BranchNode> branchOf(CanvasController c, String rootId) {
  final root = c.itemById(rootId);
  if (root is! TextItem) return const [];
  final children = <String, List<String>>{};
  for (final i in c.items) {
    if (i is ConnectorItem) (children[i.fromId] ??= []).add(i.toId);
  }
  final out = <BranchNode>[(item: root, depth: 0, parent: null)];
  final seen = {rootId};
  for (var k = 0; k < out.length && out.length < maxBranchItems; k++) {
    final n = out[k];
    for (final id in children[n.item.id] ?? const <String>[]) {
      final child = c.itemById(id);
      if (child is TextItem && _label(child).isNotEmpty && seen.add(id)) {
        out.add((item: child, depth: n.depth + 1, parent: n.item.id));
      }
    }
  }
  return out;
}

/// What a conversion did.
typedef BranchResult = ({int created, int updated, String? projectId});

/// Turns the branch under [rootId] into a project and tasks (or one task).
BranchResult convertBranch(CanvasController c, Workspace ws, String rootId) {
  final nodes = branchOf(c, rootId);
  if (nodes.isEmpty) return (created: 0, updated: 0, projectId: null);
  var created = 0, updated = 0;
  String? projectId;
  if (nodes.length > 1) {
    final root = nodes.first.item;
    final linked = c.markOf(root.id, projectMark);
    final existing = linked is String ? ws.projects[linked] : null;
    if (existing != null) {
      if (existing.name != _label(root)) {
        ws.projects.put(existing.copyWith(name: _label(root)));
        updated++;
      }
      projectId = existing.id;
    } else {
      final p = Project(
        id: newId(),
        name: _label(root),
        kind: ProjectKind.project,
        updatedAt: DateTime.now(),
      );
      ws.projects.put(p);
      c.setMark([root.id], projectMark, p.id);
      projectId = p.id;
      created++;
    }
  }
  // Item id → its task id, filled parents first.
  final taskOf = <String, String>{};
  for (final n in nodes) {
    if (projectId != null && n.depth == 0) continue; // the project itself
    final parentTask = n.parent == null ? null : taskOf[n.parent];
    final linked = c.markOf(n.item.id, taskMark);
    final existing = linked is String ? ws.tasks[linked] : null;
    if (existing != null) {
      if (existing.title != _label(n.item) ||
          existing.projectId != projectId ||
          existing.parentId != parentTask) {
        ws.tasks.put(
          existing.copyWith(
            title: _label(n.item),
            projectId: () => projectId,
            parentId: () => parentTask,
          ),
        );
        updated++;
      }
      taskOf[n.item.id] = existing.id;
    } else {
      final t = ws.createTask(
        _label(n.item),
        projectId: projectId,
        parentId: parentTask,
      );
      c.setMark([n.item.id], taskMark, t.id);
      taskOf[n.item.id] = t.id;
      created++;
    }
  }
  return (created: created, updated: updated, projectId: projectId);
}

/// Done / linked tasks of the branch (derived from the tasks themselves).
(int, int) branchProgress(CanvasController c, Workspace ws, String rootId) {
  var done = 0, total = 0;
  for (final n in branchOf(c, rootId)) {
    final id = c.markOf(n.item.id, taskMark);
    final t = id is String ? ws.tasks[id] : null;
    if (t == null) continue;
    total++;
    if (t.done) done++;
  }
  return (done, total);
}

/// The branch as an indented list, for a note.
String branchAsText(CanvasController c, String rootId) => [
  for (final n in branchOf(c, rootId))
    '${'  ' * n.depth}- ${n.item.text.trim().replaceAll('\n', ' ')}',
].join('\n');
