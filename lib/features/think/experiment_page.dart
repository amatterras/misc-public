// Thought experiments: a question, the assumptions and verified facts it
// rests on (kept visibly apart), scenarios compared side by side with
// their variables and outcomes, and the open unknowns. Nothing here is
// calculated or filled in by the app; AI suggestions are marked as such.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/floating_windows.dart';
import '../../app/theme.dart';
import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/knowledge_models.dart';
import '../../widgets/common.dart';
import '../ai/ai_service.dart';
import '../ai/ai_session.dart';
import '../sharing/share_dialog.dart';

FloatingWindowSpec experimentWindow(AppState s, String id) =>
    FloatingWindowSpec(
      id: 'experiment-$id',
      title: s.workspace.experiments[id]?.title ?? 'Thought experiment',
      initialRect: const Rect.fromLTWH(140, 60, 760, 560),
      minSize: const Size(420, 320),
      builder: (_) => ExperimentPage(state: s, id: id),
    );

/// Creates a new thought experiment and opens it.
Future<void> newExperiment(BuildContext context, AppState s) async {
  final title = await promptText(
    context,
    title: 'New thought experiment',
    hint: 'What if…',
    action: 'Create',
  );
  if (title == null || title.trim().isEmpty) return;
  final x = ThoughtExperiment(
    id: newId(),
    title: title.trim(),
    updatedAt: DateTime.now(),
  );
  s.workspace.experiments.put(x);
  s.openExperiment(x.id);
}

/// The list of thought experiments (open, new, delete).
Future<void> showExperiments(BuildContext context, AppState s) =>
    showAppDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: s.workspace.experiments,
        builder: (context, _) {
          final list = s.workspace.experiments.all.toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
          return AlertDialog(
            title: const Text(
              'Thought experiments',
              style: TextStyle(fontSize: AppType.sizeHeading),
            ),
            content: SizedBox(
              width: 420,
              height: 360,
              child: list.isEmpty
                  ? Center(
                      child: Text(
                        'None yet.',
                        style: TextStyle(color: AppColors.textFaint),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final x in list)
                          ListTile(
                            dense: true,
                            title: Text(x.title),
                            subtitle: Text(
                              '${x.claims.length} statements · '
                              '${x.scenarios.length} scenarios',
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              s.openExperiment(x.id);
                            },
                            trailing: IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () async {
                                if (await confirm(
                                  context,
                                  title: 'Delete "${x.title}"?',
                                  message: 'This cannot be undone.',
                                )) {
                                  s.workspace.experiments.remove(x.id);
                                }
                              },
                            ),
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                key: const ValueKey('experiment-new'),
                onPressed: () {
                  Navigator.pop(context);
                  newExperiment(context, s);
                },
                child: const Text('New'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );

class ExperimentPage extends StatelessWidget {
  const ExperimentPage({super.key, required this.state, required this.id});

  final AppState state;
  final String id;

  ThoughtExperiment? get x => state.workspace.experiments[id];

  void _put(ThoughtExperiment Function(ThoughtExperiment) change) {
    final cur = x;
    if (cur != null) state.workspace.experiments.put(change(cur));
  }

  Future<Claim?> _editClaim(
    BuildContext context, {
    Claim? claim,
    String title = 'Statement',
  }) async {
    final text = await promptText(
      context,
      title: title,
      initial: claim?.text ?? '',
      action: claim == null ? 'Add' : 'Save',
    );
    if (text == null || text.trim().isEmpty) return null;
    return claim?.copyWith(text: text.trim()) ??
        Claim(id: newId(), text: text.trim());
  }

  Future<void> _linkSource(BuildContext context, Claim c) async {
    final ws = state.workspace;
    final options = [
      for (final n in ws.notes.all) (n.id, 'Note: ${n.displayTitle}'),
      for (final a in ws.assets.all) (a.id, 'Archive: ${a.label}'),
    ];
    final picked = await showAppDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Source for this fact'),
        children: [
          SizedBox(
            width: 420,
            height: 320,
            child: ListView(
              children: [
                for (final (id, label) in options)
                  ListTile(
                    dense: true,
                    title: Text(label, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, id),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    _put(
      (e) => e.copyWith(
        claims: [
          for (final k in e.claims)
            k.id == c.id
                ? k.copyWith(sourceIds: {...k.sourceIds, picked}.toList())
                : k,
        ],
      ),
    );
  }

  String _sourceLabel(String id) {
    final ws = state.workspace;
    return ws.notes[id]?.displayTitle ?? ws.assets[id]?.label ?? '(missing)';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state.workspace.experiments,
    builder: (context, _) {
      final e = x;
      if (e == null) {
        return Center(
          child: Text(
            'This thought experiment was deleted.',
            style: TextStyle(color: AppColors.textFaint),
          ),
        );
      }
      final unsupported = e.unsupportedFacts;
      return Material(
        color: AppColors.background,
        child: ListView(
          padding: const EdgeInsets.all(Space.lg),
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final t = await promptText(
                        context,
                        title: 'Title',
                        initial: e.title,
                      );
                      if (t != null && t.trim().isNotEmpty) {
                        _put((e) => e.copyWith(title: t.trim()));
                      }
                    },
                    child: Text(
                      e.title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Save as a note draft',
                  icon: const Icon(Icons.note_add_outlined, size: 18),
                  onPressed: () {
                    final n = state.workspace.createNote(
                      title: e.title,
                      body: e.toText(),
                    );
                    state.openNote(n.id);
                  },
                ),
                IconButton(
                  tooltip: 'Ask AI about it',
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  onPressed: () => state.sendToAi(
                    AiContext(
                      title: 'Thought experiment: ${e.title}',
                      source: AiSource.notes,
                      text: e.toText(),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Share (read-only link)',
                  icon: const Icon(Icons.ios_share, size: 18),
                  onPressed: () => showShareDialog(
                    context,
                    state,
                    kind: 'experiment',
                    sourceId: e.id,
                    title: e.title,
                    body: e.toText(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            InkWell(
              key: const ValueKey('experiment-question'),
              onTap: () async {
                final q = await promptText(
                  context,
                  title: 'The question',
                  initial: e.question,
                );
                if (q != null) _put((e) => e.copyWith(question: q.trim()));
              },
              child: Text(
                e.question.isEmpty ? 'Add the question…' : e.question,
                style: TextStyle(
                  color: e.question.isEmpty
                      ? AppColors.textFaint
                      : AppColors.text,
                ),
              ),
            ),
            if (unsupported.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(
                  '${unsupported.length} "verified" '
                  '${unsupported.length == 1 ? 'fact has' : 'facts have'} no '
                  'source yet; they are shown as unsupported.',
                  style: TextStyle(
                    fontSize: AppType.sizeLabel,
                    color: AppColors.warm,
                  ),
                ),
              ),
            _section(
              context,
              'Assumptions and facts',
              onAdd: () async {
                final c = await _editClaim(context);
                if (c != null) {
                  _put((e) => e.copyWith(claims: [...e.claims, c]));
                }
              },
            ),
            for (final c in e.claims) _claimRow(context, e, c),
            _section(
              context,
              'Scenarios',
              onAdd: () async {
                final name = await promptText(
                  context,
                  title: 'Scenario name',
                  action: 'Add',
                );
                if (name == null || name.trim().isEmpty) return;
                _put(
                  (e) => e.copyWith(
                    scenarios: [
                      ...e.scenarios,
                      Scenario(id: newId(), name: name.trim()),
                    ],
                  ),
                );
              },
            ),
            if (e.scenarios.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final sc in e.scenarios) _scenario(context, e, sc),
                  ],
                ),
              ),
            _section(
              context,
              'Unknowns',
              onAdd: () async {
                final c = await _editClaim(context, title: 'Open question');
                if (c != null) {
                  _put(
                    (e) => e.copyWith(
                      unknowns: [
                        ...e.unknowns,
                        c.copyWith(origin: ClaimOrigin.unknown),
                      ],
                    ),
                  );
                }
              },
            ),
            for (final u in e.unknowns)
              ListTile(
                dense: true,
                leading: const Icon(Icons.help_outline, size: 16),
                title: Text(u.text),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => _put(
                    (e) => e.copyWith(
                      unknowns: [
                        for (final k in e.unknowns)
                          if (k.id != u.id) k,
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _section(
    BuildContext context,
    String title, {
    required VoidCallback onAdd,
  }) => Padding(
    padding: const EdgeInsets.only(top: Space.lg),
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: AppType.sizeBodySmall,
          ),
        ),
        const Spacer(),
        TextButton.icon(
          key: ValueKey('experiment-add-$title'),
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add'),
        ),
      ],
    ),
  );

  Color _originColor(ClaimOrigin o, bool unsupported) => switch (o) {
    ClaimOrigin.verified when unsupported => AppColors.warm,
    ClaimOrigin.verified => const Color(0xFF81BB8D),
    ClaimOrigin.aiInference => const Color(0xFFA792CE),
    ClaimOrigin.calculation => const Color(0xFF829CB5),
    _ => AppColors.textMuted,
  };

  Widget _claimRow(BuildContext context, ThoughtExperiment e, Claim c) {
    final unsupported = c.origin == ClaimOrigin.verified && c.sourceIds.isEmpty;
    return ListTile(
      dense: true,
      title: Text(c.text),
      subtitle: c.sourceIds.isEmpty
          ? null
          : Text(
              'Sources: ${c.sourceIds.map(_sourceLabel).join(', ')}',
              style: const TextStyle(fontSize: AppType.sizeMeta),
            ),
      leading: PopupMenuButton<ClaimOrigin>(
        tooltip: 'Where it comes from',
        onSelected: (o) => _put(
          (e) => e.copyWith(
            claims: [
              for (final k in e.claims)
                k.id == c.id ? k.copyWith(origin: o) : k,
            ],
          ),
        ),
        itemBuilder: (_) => [
          for (final o in ClaimOrigin.values)
            PopupMenuItem(value: o, child: Text(o.label)),
        ],
        child: Text(
          unsupported ? 'Unsupported fact' : c.origin.label,
          style: TextStyle(
            fontSize: AppType.sizeMeta,
            color: _originColor(c.origin, unsupported),
          ),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Link a source',
            icon: const Icon(Icons.link, size: 16),
            onPressed: () => _linkSource(context, c),
          ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined, size: 16),
            onPressed: () async {
              final edited = await _editClaim(context, claim: c);
              if (edited == null) return;
              _put(
                (e) => e.copyWith(
                  claims: [for (final k in e.claims) k.id == c.id ? edited : k],
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => _put(
              (e) => e.copyWith(
                claims: [
                  for (final k in e.claims)
                    if (k.id != c.id) k,
                ],
                scenarios: [
                  for (final s in e.scenarios)
                    s.copyWith(
                      assumptionIds: [...s.assumptionIds]..remove(c.id),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scenario(BuildContext context, ThoughtExperiment e, Scenario sc) {
    void update(Scenario Function(Scenario) f) => _put(
      (e) => e.copyWith(
        scenarios: [for (final s in e.scenarios) s.id == sc.id ? f(s) : s],
      ),
    );
    Future<void> addTo(bool outcome) async {
      final c = await _editClaim(
        context,
        title: outcome ? 'Expected outcome' : 'Variable (name = value)',
      );
      if (c == null) return;
      update(
        (s) => outcome
            ? s.copyWith(outcomes: [...s.outcomes, c])
            : s.copyWith(variables: [...s.variables, c]),
      );
    }

    return Container(
      key: ValueKey('scenario-${sc.id}'),
      width: 240,
      margin: const EdgeInsets.only(right: Space.sm, top: Space.xs),
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  sc.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Remove scenario',
                icon: const Icon(Icons.close, size: 14),
                onPressed: () => _put(
                  (e) => e.copyWith(
                    scenarios: [
                      for (final s in e.scenarios)
                        if (s.id != sc.id) s,
                    ],
                  ),
                ),
              ),
            ],
          ),
          Text(
            'Relies on',
            style: TextStyle(
              fontSize: AppType.sizeMeta,
              color: AppColors.textFaint,
            ),
          ),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final c in e.claims)
                FilterChip(
                  label: Text(
                    c.text,
                    style: const TextStyle(fontSize: AppType.sizeMeta),
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: sc.assumptionIds.contains(c.id),
                  onSelected: (on) => update(
                    (s) => s.copyWith(
                      assumptionIds: on
                          ? [...s.assumptionIds, c.id]
                          : ([...s.assumptionIds]..remove(c.id)),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Space.xs),
          for (final v in sc.variables)
            Text(
              '• ${v.text}',
              style: const TextStyle(fontSize: AppType.sizeLabel),
            ),
          TextButton(
            onPressed: () => addTo(false),
            child: const Text('+ Variable'),
          ),
          for (final o in sc.outcomes)
            Text(
              '→ ${o.text}  (${o.origin.label})',
              style: const TextStyle(fontSize: AppType.sizeLabel),
            ),
          TextButton(
            onPressed: () => addTo(true),
            child: const Text('+ Outcome'),
          ),
        ],
      ),
    );
  }
}
