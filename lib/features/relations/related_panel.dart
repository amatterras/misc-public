// "Related": everything connected to an item, in both directions, with a way
// to add and remove links. Shown in a note's Connections; usable for any
// item that has a [Ref]. Rows open the other item (a PDF row opens at the
// right page where this device can show pages).
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../new_ui/new_archive_page.dart' show openArchiveItem;
import '../../phone/phone_archive.dart' show openPhoneArchiveItem;
import '../../phone/phone_profile.dart';
import '../../search/search_index.dart';
import '../../widgets/common.dart' show promptText;
import 'pdf_page_viewer.dart';
import 'relations.dart';

class RelatedPanel extends StatelessWidget {
  const RelatedPanel({super.key, required this.state, required this.item});

  final AppState state;
  final Ref item;

  RelationService get _service => RelationService(state.workspace);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state.workspace.libraryRelations,
      builder: (context, _) {
        final related = _service.relatedTo(item);
        final out = [
          for (final r in related)
            if (r.outgoing) r,
        ];
        final back = [
          for (final r in related)
            if (!r.outgoing) r,
        ];
        final heading = TextStyle(
          fontSize: 11,
          letterSpacing: 0.6,
          color: AppColors.textFaint,
        );
        Widget group(String title, List<Related> rows) => rows.isEmpty
            ? const SizedBox.shrink()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: Space.sm, bottom: 2),
                    child: Text(title, style: heading),
                  ),
                  for (final r in rows)
                    _RelatedRow(
                      state: state,
                      related: r,
                      onOpen: () =>
                          openRef(context, state, r.other, page: r.page),
                      onUnlink: r.explicit
                          ? () {
                              _service.unlink(r.relationId!);
                              state.showToast('Link removed.');
                            }
                          : null,
                    ),
                ],
              );
        return Column(
          key: const ValueKey('related-panel'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('RELATED', style: heading),
                const Spacer(),
                TextButton.icon(
                  key: const ValueKey('related-add'),
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.add_link, size: 14),
                  label: const Text('Link…', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            if (related.isEmpty)
              Text(
                'Nothing is linked to this yet.',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint),
              ),
            group('LINKS TO', out),
            group('LINKED FROM', back),
          ],
        );
      },
    );
  }

  Future<void> _add(BuildContext context) async {
    final target = await _pickTarget(context, state, exclude: item);
    if (target == null || !context.mounted) return;
    int? page;
    var rel = 'related';
    if (target.kind == RefKind.asset &&
        state.workspace.assets[target.id]?.kind.name == 'document') {
      final text = await promptText(
        context,
        title: 'Which page? (leave empty for the whole PDF)',
        initial: '',
      );
      if (!context.mounted) return;
      page = int.tryParse((text ?? '').trim());
      if (page != null && page > 0) rel = 'cites';
      if (page != null && page <= 0) page = null;
    }
    _service.link(item, target, rel: rel, page: page);
    state.showToast('Linked.');
  }
}

class _RelatedRow extends StatelessWidget {
  const _RelatedRow({
    required this.state,
    required this.related,
    required this.onOpen,
    this.onUnlink,
  });

  final AppState state;
  final Related related;
  final VoidCallback onOpen;
  final VoidCallback? onUnlink;

  static IconData _icon(RefKind k) => switch (k) {
    RefKind.note => Icons.description_outlined,
    RefKind.task => Icons.check_box_outline_blank,
    RefKind.project => Icons.folder_outlined,
    RefKind.entry => Icons.calendar_today_outlined,
    RefKind.asset => Icons.attach_file,
    RefKind.archive => Icons.bookmark_border,
    RefKind.canvas => Icons.hub_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final r = related;
    final faint = AppColors.textFaint;
    return InkWell(
      onTap: r.exists ? onOpen : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(_icon(r.other.kind), size: 16, color: faint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                r.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: r.exists ? AppColors.text : faint,
                  decoration: r.exists ? null : TextDecoration.lineThrough,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              [
                if (r.page != null) 'p. ${r.page}',
                if (r.rel != 'related') r.rel,
              ].join(' · '),
              style: TextStyle(fontSize: 11, color: faint),
            ),
            if (onUnlink != null)
              IconButton(
                tooltip: 'Remove this link',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.link_off, size: 15, color: faint),
                onPressed: onUnlink,
              ),
          ],
        ),
      ),
    );
  }
}

/// Opens the item behind [ref] (a PDF at [page] where pages can be shown).
Future<void> openRef(
  BuildContext context,
  AppState s,
  Ref ref, {
  int? page,
}) async {
  final ws = s.workspace;
  switch (ref.kind) {
    case RefKind.note:
      s.openNote(ref.id);
    case RefKind.task:
      s.openTask(ref.id);
    case RefKind.project:
      s.goTo(AppPage.tasks);
    case RefKind.entry:
      final e = ws.entries[ref.id];
      final day = e?.startDate;
      if (day != null) s.openCalendarDay(day);
    case RefKind.asset:
      final a = ws.assets[ref.id];
      if (a == null) return;
      if (a.kind.name == 'document') {
        await openPdfAtPage(context, s, a, page);
      } else if (!await s.openLinkCard(a.id) && a.url != null) {
        s.openInSafari(a.url!);
      }
    case RefKind.archive:
      if (PhoneProfile.active) {
        await openPhoneArchiveItem(context, s, ref.id);
      } else {
        await openArchiveItem(context, s, ref.id);
      }
    case RefKind.canvas:
      await s.openCanvas(ref.id);
  }
}

/// Lets the person find an item to link to, using the search index.
Future<Ref?> _pickTarget(
  BuildContext context,
  AppState s, {
  required Ref exclude,
}) {
  return showDialog<Ref>(
    context: context,
    builder: (context) => _TargetPicker(state: s, exclude: exclude),
  );
}

class _TargetPicker extends StatefulWidget {
  const _TargetPicker({required this.state, required this.exclude});

  final AppState state;
  final Ref exclude;

  @override
  State<_TargetPicker> createState() => _TargetPickerState();
}

class _TargetPickerState extends State<_TargetPicker> {
  String _q = '';

  static Ref? _refOf(SearchHit h) => switch (h.doc.kind) {
    DocKind.note => Ref(RefKind.note, h.doc.id),
    DocKind.task => Ref(RefKind.task, h.doc.id),
    DocKind.project => Ref(RefKind.project, h.doc.id),
    DocKind.entry => Ref(RefKind.entry, h.doc.id),
    DocKind.link || DocKind.document => Ref(RefKind.asset, h.doc.id),
    DocKind.archive => Ref(RefKind.archive, h.doc.id),
    DocKind.canvas => Ref(RefKind.canvas, h.doc.id),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final hits = _q.trim().isEmpty
        ? const <SearchHit>[]
        : widget.state.search.search(_q, limit: 30);
    final choices = [
      for (final h in hits)
        if (_refOf(h) case final r? when r != widget.exclude) (r, h),
    ];
    return AlertDialog(
      backgroundColor: AppColors.card,
      title: const Text('Link to…', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 420,
        height: 340,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('link-target-search'),
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search a note, task, file, link…',
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final (ref, hit) in choices)
                    ListTile(
                      dense: true,
                      title: Text(hit.doc.title, maxLines: 1),
                      subtitle: Text(
                        hit.doc.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(context, ref),
                    ),
                ],
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
