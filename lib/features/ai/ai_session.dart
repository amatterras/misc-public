// One AI conversation: the material the user attached, the messages, and
// changes the AI proposed. Proposed changes are only suggestions: nothing
// is created or changed until the user ticks them and presses Apply.
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../data/models/canvas_models.dart';
import '../canvas/canvas_controller.dart';
import '../../data/workspace.dart';
import 'ai_service.dart';

/// Something the user chose to give the AI.
class AiContext {
  const AiContext({
    required this.title,
    required this.source,
    this.text = '',
    this.image,
    this.noteId,
  });

  final String title;
  final AiSource source;
  final String text;

  /// A picture of a mindmap selection (PNG).
  final Uint8List? image;

  /// The note it came from, if any (link suggestions go there).
  final String? noteId;
}

class AiTurn {
  const AiTurn(this.question, this.answer, this.tool, this.sources);
  final String question;
  final String answer;
  final AiTool tool;

  /// Titles of the material the answer was based on, numbered from 1.
  final List<String> sources;
}

/// A change the AI suggested; applied only after approval.
class AiProposal {
  AiProposal(this.label, {this.level = 0, this.selected = true});
  final String label;
  final int level;
  bool selected;
}

class AiSession extends ChangeNotifier {
  AiSession({required this.settings, required this.client});

  final AiSettings settings;

  /// Makes the client when a request is sent (so settings changes apply).
  final Future<AiClient> Function() client;

  final List<AiContext> attached = [];
  final List<AiTurn> turns = [];
  List<AiProposal> proposals = const [];
  AiTool? proposalsFrom;
  String? mindmapCenter;
  bool busy = false;
  String? error;

  void attach(AiContext context) {
    attached.add(context);
    notifyListeners();
  }

  void detach(AiContext context) {
    attached.remove(context);
    notifyListeners();
  }

  void clear() {
    attached.clear();
    turns.clear();
    proposals = const [];
    error = null;
    notifyListeners();
  }

  /// Exactly the text that [send] would send (shown to the user first).
  /// Material is cut to the device's limit; sources not allowed in the
  /// settings are left out.
  String preview(
    AiTool tool,
    String question, {
    List<String> noteTitles = const [],
  }) {
    final budget = settings.maxContextChars;
    final parts = <String>[
      if (tool.instruction.isNotEmpty) tool.instruction,
      if (settings.workingRules.isNotEmpty)
        'User-defined working rules:\n${settings.workingRules}',
      if (question.trim().isNotEmpty) 'Question: ${question.trim()}',
    ];
    var used = 0;
    var n = 0;
    for (final c in allowedContext) {
      n++;
      final room = budget - used;
      if (room <= 0) break;
      final text = c.text.length > room
          ? '${c.text.substring(0, room)}…'
          : c.text;
      used += text.length;
      parts.add(
        '[$n] ${c.title}${c.image != null ? ' (picture attached)' : ''}\n$text',
      );
    }
    if (tool == AiTool.links && noteTitles.isNotEmpty) {
      parts.add('Note titles: ${noteTitles.take(200).join('; ')}');
    }
    return parts.join('\n\n');
  }

  /// Attached material the settings allow.
  List<AiContext> get allowedContext => [
    for (final c in attached)
      if (settings.sources.contains(c.source)) c,
  ];

  static const _baseSystem =
      'You help the user with their own notes and study material. Base '
      'answers on the numbered material given; say so when it does not '
      'cover the question. Refer to material by its number, like [1].';

  String get _system {
    final rules = settings.workingRules;
    return rules.isEmpty
        ? _baseSystem
        : '$_baseSystem\n\nUser-defined working rules (follow when compatible '
              'with safety and the supplied material):\n$rules';
  }

  /// Sends [question] with the attached material. Never called unless the
  /// user pressed Send.
  Future<void> send(
    AiTool tool,
    String question, {
    List<String> noteTitles = const [],
  }) async {
    if (!settings.enabled) {
      error = 'AI is switched off in Settings.';
      notifyListeners();
      return;
    }
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    final images = [
      if (settings.allowImages)
        for (final c in allowedContext)
          if (c.image != null) c.image!,
    ];
    final history = [
      for (final t in turns.reversed.take(3).toList().reversed) ...[
        AiMessage('user', t.question),
        AiMessage('assistant', t.answer),
      ],
    ];
    try {
      final answer = await (await client()).complete([
        AiMessage('system', _system),
        ...history,
        AiMessage(
          'user',
          preview(tool, question, noteTitles: noteTitles),
          images: images,
        ),
      ]);
      turns.add(
        AiTurn(
          question.trim().isEmpty ? tool.label : question.trim(),
          answer,
          tool,
          [for (final c in allowedContext) c.title],
        ),
      );
      if (tool.proposesChanges) {
        proposalsFrom = tool;
        mindmapCenter = tool == AiTool.mindmap ? mindmapRoot(answer) : null;
        proposals = [
          for (final (level, text) in bulletLines(answer))
            if (tool != AiTool.links || noteTitles.contains(text))
              AiProposal(text, level: level),
        ];
      }
    } on AiFailure catch (e) {
      error = e.message;
    } catch (_) {
      error = 'The AI request failed.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  List<AiProposal> get _chosen => [
    for (final p in proposals)
      if (p.selected) p,
  ];

  /// Creates the approved tasks. Returns how many.
  int applyTasks(Workspace ws, {String? projectId, String? noteId}) {
    var n = 0;
    for (final p in _chosen) {
      final t = ws.createTask(p.label, projectId: projectId);
      if (noteId != null) ws.tasks.put(t.copyWith(noteIds: [noteId]));
      n++;
    }
    _done();
    return n;
  }

  /// Adds the approved mindmap (centre plus branches, connected) to [c]
  /// around [at]. Returns how many nodes.
  int applyMindmap(CanvasController c, Offset at) {
    final chosen = _chosen;
    if (chosen.isEmpty) return 0;
    final items = <CanvasItem>[];
    TextItem node(String text, Offset pos, {double size = 16}) => TextItem(
      id: newId(),
      position: pos,
      width: 220,
      minHeight: 0,
      fontSize: size,
      text: text,
    );
    final root = node(mindmapCenter ?? 'Mindmap', at, size: 22);
    items.add(root);
    final parents = <int, TextItem>{-1: root};
    var row = 0;
    for (final p in chosen) {
      final level = p.level.clamp(0, 4);
      final n = node(
        p.label,
        at + Offset(300.0 * (level + 1), 90.0 * row++ - 90),
      );
      items.add(n);
      final parent = parents[level - 1] ?? root;
      items.add(ConnectorItem(id: newId(), fromId: parent.id, toId: n.id));
      parents[level] = n;
      parents.removeWhere((k, _) => k > level);
    }
    c.addItems(items);
    _done();
    return chosen.length;
  }

  /// Adds the approved related notes as [[links]] at the end of note
  /// [noteId]. Returns how many.
  int applyLinks(Workspace ws, String noteId) {
    final note = ws.notes[noteId];
    final chosen = _chosen;
    if (note == null || chosen.isEmpty) return 0;
    ws.notes.put(
      note.copyWith(
        body:
            '${note.body.trimRight()}\n\nRelated: '
            '${chosen.map((p) => '[[${p.label}]]').join(', ')}',
      ),
    );
    _done();
    return chosen.length;
  }

  void discardProposals() => _done();

  void _done() {
    proposals = const [];
    proposalsFrom = null;
    notifyListeners();
  }
}
