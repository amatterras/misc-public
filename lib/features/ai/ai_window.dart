// The floating AI window: the attached material, what exactly will be
// sent, the tools, the answers with their sources, and proposed changes
// waiting for approval.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/ai_models.dart';
import 'ai_service.dart';
import 'ai_session.dart';

class AiPanel extends StatefulWidget {
  const AiPanel({super.key, required this.state, this.session});

  final AppState state;

  /// The conversation shown (default: the main AI session).
  final AiSession? session;

  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  final _question = TextEditingController();
  AiTool _tool = AiTool.ask;

  AppState get s => widget.state;
  AiSession get session => widget.session ?? s.aiSession;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  List<String> get _noteTitles => [
    for (final n in s.workspace.notes.all)
      if (n.title.trim().isNotEmpty) n.displayTitle,
  ];

  Future<void> _send() async {
    await session.send(_tool, _question.text, noteTitles: _noteTitles);
    if (session.error == null) _question.clear();
  }

  String? get _sourceNote =>
      session.attached.map((c) => c.noteId).whereType<String>().firstOrNull;

  void _apply() {
    final ws = s.workspace;
    switch (session.proposalsFrom) {
      case AiTool.tasks:
        final n = session.applyTasks(ws, noteId: _sourceNote);
        s.showToast('Created $n task(s).');
      case AiTool.mindmap:
        final c = s.canvas;
        if (c == null) return;
        final n = session.applyMindmap(c, s.canvasDropPoint(c));
        s.goTo(AppPage.canvas);
        s.showToast('Added a mindmap with $n branch(es).');
      case AiTool.links:
        final note = _sourceNote;
        if (note == null) {
          s.showToast('Links can only be added to a note that was attached.');
          return;
        }
        final n = session.applyLinks(ws, note);
        s.showToast('Added $n link(s) to the note.');
      case _:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      if (!s.ai.enabled) {
        return const Padding(
          padding: EdgeInsets.all(Space.lg),
          child: Text(
            'AI is off. Turn it on in Settings → AI. Nothing is ever sent '
            'until you press Send here.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        );
      }
      final preview = session.preview(
        _tool,
        _question.text,
        noteTitles: _tool == AiTool.links ? _noteTitles : const [],
      );
      final pictures = s.ai.allowImages
          ? session.allowedContext.where((c) => c.image != null).length
          : 0;
      return ListView(
        key: const ValueKey('ai-panel'),
        padding: const EdgeInsets.all(Space.md),
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final c in session.attached)
                InputChip(
                  avatar: Icon(
                    c.image != null ? Icons.image_outlined : Icons.notes,
                    size: 14,
                  ),
                  label: Text(c.title, style: const TextStyle(fontSize: 12)),
                  onDeleted: () => session.detach(c),
                ),
              if (session.attached.isEmpty)
                const Text(
                  'Nothing attached. Select text in a note or items on a '
                  'mindmap and choose “Ask AI”.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              if (session.attached.isNotEmpty || session.turns.isNotEmpty)
                TextButton(
                  onPressed: session.clear,
                  child: const Text('Clear'),
                ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final t in AiTool.values)
                ChoiceChip(
                  key: ValueKey('ai-tool-${t.name}'),
                  label: Text(t.label, style: const TextStyle(fontSize: 12)),
                  selected: _tool == t,
                  onSelected: (_) => setState(() => _tool = t),
                ),
            ],
          ),
          const SizedBox(height: Space.sm),
          TextField(
            key: const ValueKey('ai-question'),
            controller: _question,
            minLines: 1,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Ask about the attached material…',
            ),
          ),
          ExpansionTile(
            key: const ValueKey('ai-what-is-sent'),
            tilePadding: EdgeInsets.zero,
            title: Text(
              'What will be sent: ${preview.length} characters'
              '${pictures > 0 ? ' and $pictures picture(s)' : ''}',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            children: [
              SelectableText(
                preview,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textFaint,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'To: ${s.ai.isLocal ? 'the local model on this PC' : s.ai.endpoint}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
              if (session.busy)
                OutlinedButton.icon(
                  key: const ValueKey('ai-stop'),
                  onPressed: session.cancel,
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Stop'),
                )
              else
                FilledButton.icon(
                  key: const ValueKey('ai-send'),
                  onPressed: _send,
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('Send'),
                ),
            ],
          ),
          if (session.error != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(
                session.error!,
                key: const ValueKey('ai-error'),
                style: const TextStyle(color: AppColors.warm, fontSize: 13),
              ),
            ),
          if (session.proposals.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Container(
              key: const ValueKey('ai-proposals'),
              padding: const EdgeInsets.all(Space.sm),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.accent),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    switch (session.proposalsFrom) {
                      AiTool.tasks => 'Proposed tasks: tick the ones to create',
                      AiTool.mindmap =>
                        'Proposed mindmap “${session.mindmapCenter ?? 'Mindmap'}”: '
                            'tick the branches to add',
                      _ => 'Proposed links: tick the ones to add',
                    },
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  for (final p in session.proposals)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.only(left: 16.0 * p.level),
                      value: p.selected,
                      title: Text(
                        p.label,
                        style: const TextStyle(fontSize: 13),
                      ),
                      onChanged: (v) => setState(() => p.selected = v ?? false),
                    ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: session.discardProposals,
                        child: const Text('Discard'),
                      ),
                      const Spacer(),
                      FilledButton(
                        key: const ValueKey('ai-apply'),
                        onPressed: _apply,
                        child: const Text('Apply'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (session.busy) ...[
            const Divider(),
            SelectableText(
              session.streaming.isEmpty ? '…' : session.streaming,
              key: const ValueKey('ai-streaming'),
              style: const TextStyle(fontSize: 13),
            ),
          ],
          for (final t in session.turns.reversed) ...[
            const Divider(),
            Text(
              t.question,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            SelectableText(t.answer, style: const TextStyle(fontSize: 13)),
            if (t.status != AiMessageStatus.complete)
              Text(switch (t.status) {
                AiMessageStatus.stopped => 'Stopped by you.',
                AiMessageStatus.interrupted =>
                  'Interrupted (THEapp closed while it was written).',
                AiMessageStatus.failed => t.error ?? 'Failed.',
                _ => '',
              }, style: const TextStyle(fontSize: 11, color: AppColors.warm)),
            if (t.badCitations.isNotEmpty)
              Text(
                'Note: the answer refers to ${t.badCitations.map((n) => '[$n]').join(', ')}, '
                'which is not part of the material sent.',
                style: const TextStyle(fontSize: 11, color: AppColors.warm),
              ),
            if (t.sources.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Based on: ${[for (var i = 0; i < t.sources.length; i++) '[${i + 1}] ${t.sources[i]}'].join(', ')}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
          ],
        ],
      );
    },
  );
}
