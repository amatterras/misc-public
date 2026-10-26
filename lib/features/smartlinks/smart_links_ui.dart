// Smart Workspace Links on screen: the "link to…" picker, the panel that
// lists what an item links to and what links to it (with a hover/long-press
// preview), and the Back button that returns from a followed link.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/library_models.dart' show Asset, AssetKind;
import '../../widgets/common.dart' show promptText;
import '../pdfanchors/pdf_anchors.dart';
import 'smart_links.dart';

class _Candidate {
  const _Candidate(this.ref, this.title, this.subtitle, {this.canvas});
  final WorkspaceRef ref;
  final String title;
  final String subtitle;
  final CanvasSummary? canvas;
}

List<_Candidate> _candidates(AppState s, String query, WorkspaceRef? exclude) {
  final q = query.trim().toLowerCase();
  bool has(String t) => q.isEmpty || t.toLowerCase().contains(q);
  final ws = s.workspace;
  final out = <_Candidate>[];
  for (final n in ws.notes.all) {
    final ref = WorkspaceRef(RefKind.note, n.id);
    if (ref != exclude && has(n.displayTitle)) {
      out.add(_Candidate(ref, n.displayTitle, 'Note'));
    }
  }
  for (final c in s.canvasList) {
    if (c.isNotebook || c.isLinksBoard || c.isCalendarInk || c.isComponents) {
      continue;
    }
    final ref = WorkspaceRef(RefKind.canvas, c.id);
    if (ref != exclude && has(c.title)) {
      out.add(_Candidate(ref, c.title, 'Mindmap', canvas: c));
    }
  }
  for (final e in ws.entries.all) {
    final ref = WorkspaceRef(RefKind.entry, e.id);
    if (ref != exclude && has(e.name)) {
      out.add(
        _Candidate(
          ref,
          e.name,
          'Calendar · ${e.category.label}${e.archived ? ' (archived)' : ''}',
        ),
      );
    }
  }
  for (final a in ws.assets.all) {
    final ref = WorkspaceRef(RefKind.asset, a.id);
    if (ref != exclude && has(a.label)) {
      out.add(_Candidate(ref, a.label, 'Archive'));
    }
  }
  out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return out;
}

/// Asks which note, mindmap (or object on one), calendar entry or Archive
/// item to link to; returns the link token to put into the text, or null.
Future<String?> pickWorkspaceLink(
  BuildContext context,
  AppState s, {
  WorkspaceRef? exclude,
}) => showDialog<String>(
  context: context,
  builder: (_) => _LinkPicker(state: s, exclude: exclude),
);

class _LinkPicker extends StatefulWidget {
  const _LinkPicker({required this.state, this.exclude});
  final AppState state;
  final WorkspaceRef? exclude;

  @override
  State<_LinkPicker> createState() => _LinkPickerState();
}

class _LinkPickerState extends State<_LinkPicker> {
  String _query = '';

  Future<void> _pickObject(_Candidate c) async {
    final doc = await widget.state.canvases.load(c.ref.id);
    if (!mounted) return;
    final texts = [
      for (final i in doc?.items ?? const <CanvasItem>[])
        if (i is TextItem && i.text.trim().isNotEmpty) i,
    ];
    final picked = await showDialog<TextItem>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Objects on “${c.title}”',
          style: const TextStyle(fontSize: 16),
        ),
        content: SizedBox(
          width: 420,
          height: 360,
          child: texts.isEmpty
              ? const Center(child: Text('No text objects on this mindmap.'))
              : ListView(
                  children: [
                    for (final t in texts)
                      ListTile(
                        dense: true,
                        key: ValueKey('object-${t.id}'),
                        title: Text(
                          t.text.trim().split('\n').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, t),
                      ),
                  ],
                ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final label = picked.text.trim().split('\n').first;
    Navigator.pop(
      context,
      WorkspaceRef(RefKind.object, c.ref.id, picked.id).token(label),
    );
  }

  /// Choose a PDF in the Archive and a page: a link to that page.
  Future<void> _pickPdf() async {
    final s = widget.state;
    final docs = s.workspace.assets.all
        .where((a) => a.kind == AssetKind.document)
        .toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    final asset = await showDialog<Asset>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Which PDF?', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 420,
          height: 320,
          child: docs.isEmpty
              ? const Center(child: Text('No PDFs in the Archive yet.'))
              : ListView(
                  children: [
                    for (final a in docs)
                      ListTile(
                        key: ValueKey('pdf-pick-${a.id}'),
                        dense: true,
                        leading: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                        title: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(context, a),
                      ),
                  ],
                ),
        ),
      ),
    );
    if (asset == null || !mounted) return;
    final text = await promptText(
      context,
      title: 'Which page of “${asset.label}”?',
      hint: 'A page number, from 1',
      action: 'Link',
    );
    final page = int.tryParse((text ?? '').trim());
    if (page == null || page < 1 || !mounted) return;
    Navigator.pop(context, pdfAnchorToken(asset, page));
  }

  @override
  Widget build(BuildContext context) {
    final list = _candidates(widget.state, _query, widget.exclude);
    return AlertDialog(
      title: const Text('Link to…', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('link-picker-field'),
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Find a note, mindmap, calendar item or Archive item',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('link-pick-pdf'),
                onPressed: _pickPdf,
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
                label: const Text('A page of a PDF…'),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('Nothing found.'))
                  : ListView.builder(
                      itemCount: list.length > 80 ? 80 : list.length,
                      itemBuilder: (context, i) {
                        final c = list[i];
                        return ListTile(
                          dense: true,
                          key: ValueKey('link-${c.ref.path}'),
                          leading: Icon(c.ref.kind.icon, size: 18),
                          title: Text(
                            c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(c.subtitle),
                          trailing: c.canvas == null
                              ? null
                              : TextButton(
                                  onPressed: () => _pickObject(c),
                                  child: const Text('An object…'),
                                ),
                          onTap: () =>
                              Navigator.pop(context, c.ref.token(c.title)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Lets the user pick a link and puts it into [controller] at the cursor.
Future<void> insertLinkInto(
  BuildContext context,
  AppState s,
  TextEditingController controller, {
  WorkspaceRef? owner,
}) async {
  final token = await pickWorkspaceLink(context, s, exclude: owner);
  if (token == null) return;
  final sel = controller.selection;
  final text = controller.text;
  final at = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
  final end = sel.isValid ? sel.end.clamp(0, text.length) : text.length;
  controller.value = TextEditingValue(
    text: text.replaceRange(at, end, token),
    selection: TextSelection.collapsed(offset: at + token.length),
  );
}

/// A small button that opens the picker for [controller].
class InsertLinkButton extends StatelessWidget {
  const InsertLinkButton({
    super.key,
    required this.state,
    required this.controller,
    this.owner,
  });

  final AppState state;
  final TextEditingController controller;
  final WorkspaceRef? owner;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('insert-workspace-link'),
    tooltip: 'Link to a note, mindmap, calendar item or Archive item',
    icon: const Icon(Icons.add_link, size: 20),
    onPressed: () => insertLinkInto(context, state, controller, owner: owner),
  );
}

/// What [owner] links to (found in [text]) and what links to it.
class SmartLinksPanel extends StatelessWidget {
  const SmartLinksPanel({
    super.key,
    required this.state,
    required this.owner,
    required this.text,
    this.onRemoveLink,
    this.beforeOpen,
  });

  /// Called before a link is followed (e.g. to save and close an open
  /// editor); following goes on only when it returns true.
  final Future<bool> Function()? beforeOpen;

  final AppState state;
  final WorkspaceRef owner;

  /// The text of the owner that may hold links.
  final String text;

  /// Takes a (deleted target's) link out of the owner's text.
  final void Function(WorkspaceRef target)? onRemoveLink;

  @override
  Widget build(BuildContext context) {
    final s = state;
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.workspace.changes]),
      builder: (context, _) {
        final tokens = findLinks(text);
        final seen = <WorkspaceRef>{};
        final links = [
          for (final t in tokens)
            if (seen.add(t.ref)) (t, resolveRef(s, t.ref, fallbackLabel: t.label)),
        ];
        final back = backlinksTo(s, owner);
        if (links.isEmpty && back.isEmpty) return const SizedBox.shrink();
        final heading = TextStyle(
          fontSize: 11,
          letterSpacing: 0.6,
          color: AppColors.textFaint,
        );
        return Column(
          key: const ValueKey('smart-links-panel'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (links.isNotEmpty) ...[
              Text('LINKS IN THIS ITEM', style: heading),
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (t, r) in links)
                    _LinkChip(
                      state: s,
                      resolved: r,
                      owner: owner,
                      beforeOpen: beforeOpen,
                      label: t.label,
                      onRemove: onRemoveLink == null
                          ? null
                          : () => onRemoveLink!(t.ref),
                    ),
                ],
              ),
              const SizedBox(height: Space.lg),
            ],
            if (back.isNotEmpty) ...[
              Text('BACKLINKS', style: heading),
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final b in back)
                    Tooltip(
                      message: '${b.source.kind.noun}: ${b.title}\n${b.snippet}',
                      child: ActionChip(
                        key: ValueKey('backlink-${b.source.path}'),
                        avatar: Icon(b.source.kind.icon, size: 14),
                        label: Text(
                          b.title,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () async {
                          if (beforeOpen != null && !await beforeOpen!()) return;
                          await openWorkspaceRef(
                            s,
                            b.source,
                            from: owner,
                            label: b.title,
                          );
                        },
                      ),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({
    required this.state,
    required this.resolved,
    required this.owner,
    required this.label,
    this.onRemove,
    this.beforeOpen,
  });

  final Future<bool> Function()? beforeOpen;

  final AppState state;
  final ResolvedRef resolved;
  final WorkspaceRef owner;
  final String label;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final r = resolved;
    final deleted =
        r.health == LinkHealth.deleted || r.health == LinkHealth.unavailable;
    final suffix = switch (r.health) {
      LinkHealth.archived => '  (archived)',
      LinkHealth.deleted => '  (deleted)',
      LinkHealth.unavailable => '  (file missing)',
      LinkHealth.ok => '',
    };
    return Tooltip(
      message:
          '${r.ref.kind.noun}: ${r.title}${r.preview.isEmpty ? '' : '\n${r.preview}'}',
      child: InputChip(
        key: ValueKey('link-chip-${r.ref.path}'),
        avatar: Icon(
          deleted ? Icons.link_off : r.ref.kind.icon,
          size: 14,
          color: deleted ? AppColors.warm : null,
        ),
        label: Text(
          '${r.title}$suffix',
          style: TextStyle(
            fontSize: 12,
            decoration: deleted ? TextDecoration.lineThrough : null,
            color: deleted ? AppColors.textFaint : null,
          ),
        ),
        onPressed: () async {
          if (beforeOpen != null && !await beforeOpen!()) return;
          await openWorkspaceRef(state, r.ref, from: owner, label: label);
        },
        onDeleted: deleted && onRemove != null ? onRemove : null,
        deleteButtonTooltipMessage: 'Remove this broken link',
      ),
    );
  }
}

/// "Back to …" after following a link; empty when there is nowhere to go.
class LinkBackButton extends StatelessWidget {
  const LinkBackButton({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<List<ReturnPoint>>(
        valueListenable: state.linkReturn,
        builder: (context, stack, _) {
          if (stack.isEmpty) return const SizedBox.shrink();
          final label = stack.last.label;
          return Padding(
            padding: const EdgeInsets.only(left: 12),
            child: TextButton.icon(
              key: const ValueKey('link-back'),
              onPressed: () => goBackFromLink(state),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  'Back to $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          );
        },
      );
}
