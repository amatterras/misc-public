// The AI chat (in the AI page and the floating AI window): the attached
// material, the conversation (oldest first, formatted, with Copy and
// Regenerate), proposed changes waiting for approval, and the box to ask,
// showing exactly what will be sent and where.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/ai_models.dart';
import 'ai_markdown.dart';
import 'ai_service.dart';
import 'ai_session.dart';
import 'ai_settings_section.dart';

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
  final _scroll = ScrollController();
  AiTool _tool = AiTool.ask;
  int _shownTurns = -1;
  bool _wasBusy = false;

  AppState get s => widget.state;
  AiSession get session => widget.session ?? s.aiSession;

  @override
  void initState() {
    super.initState();
    _question.text = session.draft;
    // The session knows the unsent text, so closing the window can ask.
    _question.addListener(() => session.draft = _question.text);
  }

  @override
  void dispose() {
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<String> get _noteTitles => [
    for (final n in s.workspace.notes.all)
      if (n.title.trim().isNotEmpty) n.displayTitle,
  ];

  /// Sends the question; the box is emptied at once (the question shows in
  /// the conversation, and "Try again" resends it after a failure).
  Future<void> _send() async {
    final question = _question.text;
    _question.clear();
    await session.send(_tool, question, noteTitles: _noteTitles);
  }

  Future<void> _regenerate() => session.regenerate(noteTitles: _noteTitles);

  Future<void> _addPhotos() async {
    if (!s.ai.allows(AiSource.photos)) {
      s.showToast('Photos may not be sent to AI (Settings → AI).');
      return;
    }
    if (!s.ai.allowImages) {
      s.showToast('Pictures are switched off for AI (Settings → AI).');
      return;
    }
    final picked = await s.capture.pickImageBytes();
    for (final p in picked) {
      session.attach(
        AiContext(title: p.name, source: AiSource.photos, image: p.bytes),
      );
    }
  }

  Future<void> _openSettings() => showAppDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text(
        'AI settings',
        style: TextStyle(fontSize: AppType.sizeHeading),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(child: AiSettingsSection(state: s)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  ).then((_) => setState(() {}));

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    s.showToast('Copied.');
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

  /// Keeps the newest message in view: always after a new question or
  /// answer, and while one is written unless the user scrolled up.
  void _follow() {
    final jump =
        session.turns.length != _shownTurns || session.busy != _wasBusy;
    _shownTurns = session.turns.length;
    _wasBusy = session.busy;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final p = _scroll.position;
      if (jump || p.maxScrollExtent - p.pixels < 160) {
        _scroll.jumpTo(p.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      if (!s.ai.enabled) {
        return Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI is off. Nothing is ever sent until you turn it on and '
                'press Send here.',
                style: TextStyle(color: AppColors.textMuted),
              ),
              const SizedBox(height: AppSpace.sm),
              OutlinedButton(
                key: const ValueKey('ai-open-settings'),
                onPressed: _openSettings,
                child: const Text('AI settings'),
              ),
            ],
          ),
        );
      }
      _follow();
      return Column(
        key: const ValueKey('ai-panel'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _attachments(),
          const Divider(height: 1),
          Expanded(child: _messages()),
          const Divider(height: 1),
          _composer(),
        ],
      );
    },
  );

  Widget _attachments() => Padding(
    padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.sm, AppSpace.md, AppSpace.sm),
    child: Wrap(
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
            label: Text(
              '${c.title}${session.allowedContext.contains(c) ? '' : ' (not allowed: not sent)'}',
              style: const TextStyle(fontSize: AppType.sizeLabel),
            ),
            onDeleted: () => session.detach(c),
          ),
        if (session.attached.isEmpty)
          Text(
            'Nothing attached. Select text in a note, a task or items on a '
            'mindmap and choose “Ask AI”, or add a photo.',
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              color: AppColors.textFaint,
            ),
          ),
        IconButton(
          key: const ValueKey('ai-add-photo'),
          tooltip: 'Add a photo (sent only when you press Send)',
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
          onPressed: session.busy ? null : _addPhotos,
        ),
        if (session.attached.isNotEmpty || session.turns.isNotEmpty)
          TextButton(
            onPressed: session.busy ? null : session.clear,
            child: const Text('Clear'),
          ),
        IconButton(
          tooltip: 'AI settings and connection test',
          icon: const Icon(Icons.tune, size: 18),
          onPressed: _openSettings,
        ),
      ],
    ),
  );

  Widget _messages() {
    final turns = session.turns;
    if (turns.isEmpty && !session.busy) {
      return Center(
        key: ValueKey('ai-empty'),
        child: Padding(
          padding: EdgeInsets.all(AppSpace.lg),
          child: Text(
            'Ask a question below. Pick a tool such as Summarize or Quiz me '
            'to work with the attached material.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textFaint),
          ),
        ),
      );
    }
    return ListView(
      key: const ValueKey('ai-messages'),
      controller: _scroll,
      padding: const EdgeInsets.all(AppSpace.md),
      children: [
        for (var i = 0; i < turns.length; i++)
          _turn(turns[i], last: i == turns.length - 1),
        if (session.busy) ...[
          _bubble(session.asking ?? ''),
          Container(
            key: const ValueKey('ai-streaming'),
            child: session.streaming.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(4),
                    child: Text(
                      '…',
                      style: TextStyle(fontSize: AppType.sizeHeading),
                    ),
                  )
                : AiMarkdown(session.streaming),
          ),
        ],
        if (session.proposals.isNotEmpty) _proposals(),
      ],
    );
  }

  Widget _bubble(String text) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      margin: const EdgeInsets.only(top: AppSpace.md, bottom: 6, left: 40),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.selected,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: AppType.sizeBodySmall,
        ),
      ),
    ),
  );

  Widget _turn(AiTurn t, {required bool last}) {
    final faint = TextStyle(
      fontSize: AppType.sizeMeta,
      color: AppColors.textFaint,
    );
    final warn = TextStyle(fontSize: AppType.sizeMeta, color: AppColors.warm);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _bubble(t.question),
        if (t.answer.isNotEmpty) AiMarkdown(t.answer),
        if (t.status != AiMessageStatus.complete)
          Text(switch (t.status) {
            AiMessageStatus.stopped => 'Stopped by you.',
            AiMessageStatus.interrupted =>
              'Interrupted (misc. closed while it was written).',
            AiMessageStatus.failed => t.error ?? 'Failed.',
            _ => '',
          }, style: warn),
        if (t.badCitations.isNotEmpty)
          Text(
            'Note: the answer refers to '
            '${t.badCitations.map((n) => '[$n]').join(', ')}, which is not '
            'part of the material sent.',
            style: warn,
          ),
        if (t.sources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Based on: ${[for (var i = 0; i < t.sources.length; i++) '[${i + 1}] ${t.sources[i]}'].join(', ')}',
              style: faint,
            ),
          ),
        Row(
          children: [
            if (t.answer.isNotEmpty)
              TextButton.icon(
                key: ValueKey('ai-copy-${session.turns.indexOf(t)}'),
                onPressed: () => _copy(t.answer),
                icon: const Icon(Icons.copy, size: 14),
                label: const Text(
                  'Copy',
                  style: TextStyle(fontSize: AppType.sizeLabel),
                ),
              ),
            if (last && session.canRegenerate)
              TextButton.icon(
                key: ValueKey(
                  t.status == AiMessageStatus.complete
                      ? 'ai-regenerate'
                      : 'ai-retry',
                ),
                onPressed: _regenerate,
                icon: const Icon(Icons.refresh, size: 14),
                label: Text(
                  t.status == AiMessageStatus.complete
                      ? 'Regenerate'
                      : 'Try again',
                  style: const TextStyle(fontSize: AppType.sizeLabel),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _proposals() => Container(
    key: const ValueKey('ai-proposals'),
    margin: const EdgeInsets.only(top: AppSpace.md),
    padding: const EdgeInsets.all(AppSpace.sm),
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.accent),
      borderRadius: BorderRadius.circular(AppRadii.sm),
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
            fontSize: AppType.sizeLabel,
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
              style: const TextStyle(fontSize: AppType.sizeBodySmall),
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
  );

  Widget _composer() {
    final preview = session.preview(
      _tool,
      _question.text,
      noteTitles: _tool == AiTool.links ? _noteTitles : const [],
    );
    final pictures = session.allowedImages.length;
    final kind = session.errorKind;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.sm,
        AppSpace.md,
        AppSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (session.error != null)
            Container(
              key: const ValueKey('ai-error'),
              margin: const EdgeInsets.only(bottom: AppSpace.sm),
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.warm),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      session.error!,
                      style: TextStyle(
                        color: AppColors.warm,
                        fontSize: AppType.sizeBodySmall,
                      ),
                    ),
                  ),
                  if (kind == AiErrorKind.settings ||
                      kind == AiErrorKind.auth ||
                      kind == AiErrorKind.notFound ||
                      kind == AiErrorKind.unreachable)
                    TextButton(
                      key: const ValueKey('ai-error-settings'),
                      onPressed: _openSettings,
                      child: const Text('Settings'),
                    ),
                ],
              ),
            ),
          SizedBox(
            height: 30,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final t in AiTool.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      key: ValueKey('ai-tool-${t.name}'),
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        t.label,
                        style: const TextStyle(fontSize: AppType.sizeLabel),
                      ),
                      selected: _tool == t,
                      onSelected: (_) => setState(() => _tool = t),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.enter,
                control: true,
              ): () {
                if (!session.busy) _send();
              },
            },
            child: TextField(
              key: const ValueKey('ai-question'),
              controller: _question,
              minLines: 1,
              maxLines: 5,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Ask… (Ctrl+Enter sends)',
              ),
            ),
          ),
          ExpansionTile(
            key: const ValueKey('ai-what-is-sent'),
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              'What will be sent: ${preview.length} characters'
              '${pictures > 0 ? ' and $pictures picture(s)' : ''}'
              '${session.turns.isEmpty ? '' : ', plus up to 3 earlier questions and answers'}',
              style: TextStyle(
                fontSize: AppType.sizeLabel,
                color: AppColors.textMuted,
              ),
            ),
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: SelectableText(
                    preview,
                    style: TextStyle(
                      fontSize: AppType.sizeMeta,
                      color: AppColors.textFaint,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'To: ${s.ai.isLocal ? 'the local model on this PC' : s.ai.endpoint} (${s.ai.model})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.sizeMeta,
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
        ],
      ),
    );
  }
}
