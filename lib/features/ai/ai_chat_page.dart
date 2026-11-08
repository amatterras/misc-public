// The AI destination: saved conversations (new, open, rename, group, pin,
// delete) beside the chat. The same chat panel is used in the floating AI
// window, so a conversation continues wherever it is opened.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/ai_models.dart';
import '../../widgets/common.dart';
import 'ai_session.dart';
import 'ai_window.dart';

class AiChatPage extends StatefulWidget {
  const AiChatPage({
    super.key,
    required this.state,
    this.session,
    this.instanceId,
  });

  final AppState state;

  /// The page instance showing it (to ask before closing with unsent work).
  final String? instanceId;

  /// This window's conversation (default: the main AI session).
  final AiSession? session;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  String _filter = '';

  AppState get s => widget.state;
  AiSession get session => widget.session ?? s.aiSession;

  @override
  void initState() {
    super.initState();
    final id = widget.instanceId;
    if (id != null) s.windows.setCloseGuard(id, _mayClose);
  }

  @override
  void dispose() {
    final id = widget.instanceId;
    if (id != null) s.windows.setCloseGuard(id, null);
    super.dispose();
  }

  /// Closing keeps the conversation; only an unsent question or a reply
  /// still being written would be lost.
  Future<bool> _mayClose() async {
    if (!session.busy && session.draft.trim().isEmpty) return true;
    if (!mounted) return true;
    return confirm(
      context,
      title: 'Close this AI window?',
      message: session.busy
          ? 'A reply is still being written; it stops here.'
          : 'Your unsent question will be lost. The conversation stays.',
      action: 'Close',
    );
  }

  List<AiConversation> get _conversations {
    final q = _filter.trim().toLowerCase();
    return [
      for (final c in s.workspace.aiConversations.all)
        if (q.isEmpty ||
            c.title.toLowerCase().contains(q) ||
            c.group.toLowerCase().contains(q))
          c,
    ]..sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
  }

  Future<void> _menu(AiConversation c, Offset at) async {
    final store = s.workspace.aiConversations;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'group', child: Text('Put in a group…')),
        PopupMenuItem(value: 'pin', child: Text(c.pinned ? 'Unpin' : 'Pin')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'rename':
        final t = await promptText(context, title: 'Rename', initial: c.title);
        if (t != null) store.put(c.copyWith(title: t));
      case 'group':
        final g = await promptText(
          context,
          title: 'Group name (empty: no group)',
          initial: c.group,
        );
        store.put(c.copyWith(group: g ?? ''));
      case 'pin':
        store.put(c.copyWith(pinned: !c.pinned));
      case 'delete':
        final ok = await confirm(
          context,
          title: 'Delete “${c.title}”?',
          message: 'The conversation is removed from this device.',
        );
        if (!ok) return;
        store.remove(c.id);
        if (session.conversationId == c.id) session.newConversation();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([s.workspace.aiConversations, session]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        final list = _list();
        final chat = AiPanel(state: s, session: session);
        if (box.maxWidth < 640) {
          return Column(
            children: [
              SizedBox(height: 150, child: list),
              const Divider(height: 1),
              Expanded(child: chat),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: (box.maxWidth * 0.26).clamp(200, 300), child: list),
            const VerticalDivider(width: 1),
            Expanded(child: chat),
          ],
        );
      },
    ),
  );

  Widget _list() {
    final current = session.conversationId;
    final items = _conversations;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.lg, AppSpace.md, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'AI',
                  style: TextStyle(
                    fontSize: AppType.sizeTitle,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('ai-new-chat'),
                tooltip: 'New conversation',
                icon: const Icon(Icons.add_comment_outlined, size: 18),
                onPressed: session.newConversation,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          child: TextField(
            style: const TextStyle(fontSize: AppType.sizeBodySmall),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, size: 16),
              hintText: 'Find a conversation',
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(AppSpace.lg),
                    child: Text(
                      'No conversations yet.',
                      style: TextStyle(color: AppColors.textFaint),
                    ),
                  ),
                )
              : ListView(
                  key: const ValueKey('ai-conversations'),
                  children: [
                    for (final c in items)
                      GestureDetector(
                        onSecondaryTapUp: (d) => _menu(c, d.globalPosition),
                        onLongPressStart: (d) => _menu(c, d.globalPosition),
                        child: ListTile(
                          key: ValueKey('ai-conversation-${c.id}'),
                          dense: true,
                          selected: c.id == current,
                          selectedTileColor: AppColors.selected,
                          leading: Icon(
                            c.pinned
                                ? Icons.push_pin
                                : Icons.chat_bubble_outline,
                            size: 16,
                          ),
                          title: Text(
                            c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              if (c.group.isNotEmpty) c.group,
                              '${c.messages.length ~/ 2} question(s)',
                            ].join(' · '),
                            style: const TextStyle(fontSize: AppType.sizeMeta),
                          ),
                          onTap: () => session.openConversation(c.id),
                          trailing: IconButton(
                            icon: const Icon(Icons.more_horiz, size: 16),
                            tooltip: 'Rename, group, pin, delete',
                            onPressed: () {
                              final box =
                                  context.findRenderObject() as RenderBox?;
                              _menu(
                                c,
                                box?.localToGlobal(Offset.zero) ?? Offset.zero,
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
