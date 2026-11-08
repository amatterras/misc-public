// How things connect: notes, mindmaps, tasks, projects, calendar entries
// and Archive resources as dots, with a line for every real link between
// them (note links, attachments, task notes and projects, mindmap cards).
// Read-only: nothing is changed from here. Only linked things are shown.
import '../relations/relations.dart';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/floating_windows.dart';
import '../../app/theme.dart';
import '../../data/repositories/canvas_repository.dart';
import '../../data/workspace.dart';
import '../links/archive_library.dart';

enum GraphKind { note, canvas, task, project, entry, resource }

class GraphNode {
  GraphNode(this.kind, this.id, this.label);
  final GraphKind kind;
  final String id;
  final String label;
  Offset pos = Offset.zero;
  String get key => '${kind.name}:$id';
}

class RelationGraph {
  RelationGraph(this.nodes, this.edges);
  final List<GraphNode> nodes;

  /// Index pairs into [nodes].
  final List<(int, int)> edges;

  static const maxNodes = 400;
}

/// Collects the links (canvases are read from disk).
Future<RelationGraph> buildGraph(
  Workspace ws,
  CanvasRepository canvases,
) async {
  final nodes = <String, GraphNode>{};
  final edges = <(String, String)>{};
  String node(GraphKind k, String id, String label) {
    final n = nodes.putIfAbsent('${k.name}:$id', () => GraphNode(k, id, label));
    return n.key;
  }

  void link(String a, String b) {
    if (a != b) edges.add(a.compareTo(b) < 0 ? (a, b) : (b, a));
  }

  final byTitle = {
    for (final n in ws.notes.all) n.displayTitle.toLowerCase(): n,
  };
  for (final n in ws.notes.all) {
    final me = node(GraphKind.note, n.id, n.displayTitle);
    for (final t in n.linkedTitles) {
      final other = byTitle[t.toLowerCase()];
      if (other != null) {
        link(me, node(GraphKind.note, other.id, other.displayTitle));
      }
    }
  }
  String? resource(String assetId) {
    final a = ws.assets[assetId];
    return a == null ? null : node(GraphKind.resource, a.id, a.label);
  }

  for (final t in ws.tasks.all) {
    final me = node(GraphKind.task, t.id, t.title);
    if (ws.projects[t.projectId] case final p?) {
      link(me, node(GraphKind.project, p.id, p.name));
    }
    for (final id in t.noteIds) {
      if (ws.notes[id] case final n?) {
        link(me, node(GraphKind.note, n.id, n.displayTitle));
      }
    }
  }
  final refs = await referenceMap(ws, canvases);
  for (final MapEntry(key: assetId, value: users) in refs.entries) {
    final r = resource(assetId);
    if (r == null) continue;
    for (final u in users) {
      final kind = switch (u.kind) {
        'note' => GraphKind.note,
        'task' => GraphKind.task,
        'entry' => GraphKind.entry,
        'canvas' => GraphKind.canvas,
        _ => null,
      };
      if (kind != null) link(node(kind, u.id, u.title), r);
    }
  }
  // Explicit relations (by id): note, task, project, entry, file, mindmap.
  GraphNode? refNode(String key) {
    final r = Ref.parse(key);
    if (r == null) return null;
    final service = RelationService(ws);
    if (!service.exists(r)) return null;
    final kind = switch (r.kind) {
      RefKind.note => GraphKind.note,
      RefKind.task => GraphKind.task,
      RefKind.project => GraphKind.project,
      RefKind.entry => GraphKind.entry,
      RefKind.asset => GraphKind.resource,
      RefKind.canvas => GraphKind.canvas,
      RefKind.archive => null,
    };
    if (kind == null) return null;
    final id = node(kind, r.id, service.titleOf(r));
    return nodes[id];
  }

  for (final rel in ws.libraryRelations.all) {
    if (rel.kind != RelationService.kind) continue;
    final a = refNode(rel.objectId), b = refNode(rel.targetId);
    if (a != null && b != null) link(a.key, b.key);
  }
  // Only linked things, the most connected first.
  final degree = <String, int>{};
  for (final (a, b) in edges) {
    degree[a] = (degree[a] ?? 0) + 1;
    degree[b] = (degree[b] ?? 0) + 1;
  }
  final keep = degree.keys.toList()
    ..sort((a, b) => degree[b]!.compareTo(degree[a]!));
  final kept = keep.take(RelationGraph.maxNodes).toList();
  final index = {for (final (i, k) in kept.indexed) k: i};
  final graph = RelationGraph(
    [for (final k in kept) nodes[k]!],
    [
      for (final (a, b) in edges)
        if (index[a] case final i?)
          if (index[b] case final j?) (i, j),
    ],
  );
  // Off the UI thread: hundreds of nodes take a moment.
  final n = graph.nodes.length;
  final links = graph.edges;
  final positions = await compute(_layoutJob, (n, links));
  for (final (i, p) in positions.indexed) {
    graph.nodes[i].pos = p;
  }
  return graph;
}

/// Force layout (Fruchterman–Reingold) of [n] nodes joined by [edges];
/// deterministic for the same data.
List<Offset> forceLayout(
  int n,
  List<(int, int)> edges, {
  int iterations = 200,
}) {
  if (n == 0) return const [];
  final rnd = math.Random(n * 7919 + edges.length);
  final size = 300.0 * math.sqrt(n);
  final pos = [
    for (var i = 0; i < n; i++)
      Offset(rnd.nextDouble() * size, rnd.nextDouble() * size),
  ];
  final k = size / math.sqrt(n);
  var temp = size / 10;
  final disp = List.filled(n, Offset.zero);
  for (var it = 0; it < iterations; it++) {
    for (var i = 0; i < n; i++) {
      disp[i] = Offset.zero;
    }
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        var d = pos[i] - pos[j];
        var dist = d.distance;
        if (dist < 0.01) {
          d = const Offset(0.01, 0);
          dist = 0.01;
        }
        final f = d / dist * (k * k / dist);
        disp[i] += f;
        disp[j] -= f;
      }
    }
    for (final (i, j) in edges) {
      final d = pos[i] - pos[j];
      final dist = math.max(d.distance, 0.01);
      final f = d / dist * (dist * dist / k);
      disp[i] -= f;
      disp[j] += f;
    }
    for (var i = 0; i < n; i++) {
      final d = disp[i];
      final len = d.distance;
      if (len > 0) pos[i] += d / len * math.min(len, temp);
    }
    temp *= 0.97;
  }
  return pos;
}

Color graphColor(GraphKind k) => switch (k) {
  GraphKind.note => const Color(0xFF789BB5),
  GraphKind.canvas => const Color(0xFF8FBFA9),
  // Pale in dark, deepened in light so nodes stay visible on the page.
  GraphKind.task =>
    AppColors.light ? const Color(0xFFA9844C) : const Color(0xFFE5D5B8),
  GraphKind.project =>
    AppColors.light ? const Color(0xFF555B68) : const Color(0xFFEFF0F4),
  GraphKind.entry => CalendarCategoryColors.reminderEvent,
  GraphKind.resource => const Color(0xFFAAAEB6),
};

FloatingWindowSpec graphWindow(AppState s) => FloatingWindowSpec(
  id: 'graph',
  title: 'How things connect',
  initialRect: const Rect.fromLTWH(120, 60, 820, 600),
  minSize: const Size(420, 320),
  builder: (_) => GraphView(state: s),
);

class GraphView extends StatefulWidget {
  const GraphView({super.key, required this.state});
  final AppState state;

  @override
  State<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<GraphView> {
  RelationGraph? _g;
  int? _selected;
  final _hidden = <GraphKind>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final g = await buildGraph(widget.state.workspace, widget.state.canvases);
    if (mounted) setState(() => _g = g);
  }

  void _open(GraphNode n) {
    final s = widget.state;
    switch (n.kind) {
      case GraphKind.note:
        s.openNote(n.id);
      case GraphKind.task:
        s.openTask(n.id);
      case GraphKind.canvas:
        s.openCanvas(n.id);
      case GraphKind.project:
        s.goTo(AppPage.tasks);
      case GraphKind.entry:
        s.goTo(AppPage.calendar);
      case GraphKind.resource:
        s.openLinkCard(n.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = _g;
    if (g == null) return const Center(child: CircularProgressIndicator());
    if (g.nodes.isEmpty) {
      return Center(
        child: Text(
          'Nothing is linked yet: link notes with [[Title]], attach things '
          'or put cards on a mindmap.',
          style: TextStyle(color: AppColors.textFaint),
        ),
      );
    }
    final bounds = g.nodes
        .map((n) => Rect.fromCircle(center: n.pos, radius: 1))
        .reduce((a, b) => a.expandToInclude(b))
        .inflate(80);
    final sel = _selected == null ? null : g.nodes[_selected!];
    return Material(
      color: AppColors.background,
      child: Column(
        children: [
          Wrap(
            spacing: 4,
            children: [
              for (final k in GraphKind.values)
                FilterChip(
                  label: Text(
                    k.name,
                    style: const TextStyle(fontSize: AppType.sizeMeta),
                  ),
                  avatar: CircleAvatar(
                    backgroundColor: graphColor(k),
                    radius: 5,
                  ),
                  selected: !_hidden.contains(k),
                  onSelected: (on) =>
                      setState(() => on ? _hidden.remove(k) : _hidden.add(k)),
                ),
            ],
          ),
          if (sel != null)
            ListTile(
              dense: true,
              leading: CircleAvatar(
                backgroundColor: graphColor(sel.kind),
                radius: 6,
              ),
              title: Text(sel.label),
              subtitle: Text(
                '${g.edges.where((e) => e.$1 == _selected || e.$2 == _selected).length} links',
              ),
              trailing: TextButton(
                onPressed: () => _open(sel),
                child: const Text('Open'),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => InteractiveViewer(
                constrained: false,
                minScale: 0.05,
                maxScale: 4,
                boundaryMargin: const EdgeInsets.all(400),
                child: GestureDetector(
                  onTapUp: (d) {
                    final p = d.localPosition + bounds.topLeft;
                    int? best;
                    var bestD = 18.0;
                    for (final (i, n) in g.nodes.indexed) {
                      if (_hidden.contains(n.kind)) continue;
                      final dist = (n.pos - p).distance;
                      if (dist < bestD) {
                        bestD = dist;
                        best = i;
                      }
                    }
                    setState(() => _selected = best);
                  },
                  child: CustomPaint(
                    size: bounds.size,
                    painter: _GraphPainter(
                      g,
                      bounds.topLeft,
                      _selected,
                      _hidden,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.g, this.origin, this.selected, this.hidden);
  final RelationGraph g;
  final Offset origin;
  final int? selected;
  final Set<GraphKind> hidden;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(-origin.dx, -origin.dy);
    final line = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    final hot = Paint()
      ..color = AppColors.accent
      ..strokeWidth = 2;
    final near = <int>{?selected};
    for (final (i, j) in g.edges) {
      if (hidden.contains(g.nodes[i].kind) ||
          hidden.contains(g.nodes[j].kind)) {
        continue;
      }
      final on = i == selected || j == selected;
      if (on) near.addAll([i, j]);
      canvas.drawLine(g.nodes[i].pos, g.nodes[j].pos, on ? hot : line);
    }
    for (final (i, n) in g.nodes.indexed) {
      if (hidden.contains(n.kind)) continue;
      canvas.drawCircle(
        n.pos,
        i == selected ? 9 : 6,
        Paint()..color = graphColor(n.kind),
      );
      if (near.contains(i) || g.nodes.length <= 60) {
        final tp = TextPainter(
          text: TextSpan(
            text: n.label.length > 32
                ? '${n.label.substring(0, 32)}…'
                : n.label,
            style: TextStyle(
              fontSize: AppType.sizeMeta,
              color: AppColors.textMuted,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, n.pos + const Offset(9, -7));
      }
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) =>
      old.g != g ||
      old.selected != selected ||
      old.hidden.length != hidden.length;
}

List<Offset> _layoutJob((int, List<(int, int)>) job) =>
    forceLayout(job.$1, job.$2);
