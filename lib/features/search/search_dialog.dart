import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/library_models.dart';
import '../../data/models/record.dart';
import '../../platform/platform.dart' as native;
import '../../widgets/common.dart';

class SearchResult {
  const SearchResult({
    required this.icon,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.open,
  });

  final IconData icon;
  final String kind;
  final String title;
  final String subtitle;
  final VoidCallback open;
}

/// Searches every kind of record. Pure function so it can be tested.
List<SearchResult> searchEverything(AppState s, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  bool has(String? text) => text != null && text.toLowerCase().contains(q);
  String snippet(String text) {
    final i = text.toLowerCase().indexOf(q);
    if (i < 0) return text.length > 90 ? '${text.substring(0, 90)}…' : text;
    final start = (i - 30).clamp(0, text.length);
    final end = (i + q.length + 60).clamp(0, text.length);
    return '${start > 0 ? '…' : ''}${text.substring(start, end).replaceAll('\n', ' ')}${end < text.length ? '…' : ''}';
  }

  final ws = s.workspace;
  final results = <SearchResult>[];
  for (final n in ws.notes.all) {
    if (has(n.title) || has(n.body) || n.tags.any(has)) {
      results.add(
        SearchResult(
          icon: Icons.description_outlined,
          kind: 'Note',
          title: n.displayTitle,
          subtitle: has(n.body) ? snippet(n.body) : ws.folderLabel(n.folderId),
          open: () => s.openNote(n.id),
        ),
      );
    }
  }
  for (final c in s.canvasList) {
    if (has(c.title) || has(c.searchText)) {
      results.add(
        SearchResult(
          icon: Icons.grid_view,
          kind: 'Canvas',
          title: c.title,
          subtitle: has(c.searchText) ? snippet(c.searchText) : 'Canvas',
          open: () => s.openCanvas(c.id),
        ),
      );
    }
  }
  for (final a in ws.assets.all) {
    if (a.kind == AssetKind.link &&
        (has(a.title) || has(a.url) || has(a.description))) {
      results.add(
        SearchResult(
          icon: Icons.link,
          kind: 'Link',
          title: a.label,
          subtitle: a.url ?? '',
          open: () => native.openUrl(a.url!),
        ),
      );
    }
  }
  for (final e in ws.entries.all) {
    if (has(e.name) ||
        has(e.description) ||
        has(e.notes) ||
        has(e.author) ||
        has(e.highlights)) {
      final day =
          e.startDate ??
          (e.dates.isNotEmpty
              ? parseDayKey((e.dates.toList()..sort()).first)
              : null) ??
          (e.readingLog.isNotEmpty
              ? parseDayKey((e.readingLog.keys.toList()..sort()).first)
              : null) ??
          DateTime.now();
      results.add(
        SearchResult(
          icon: Icons.calendar_today_outlined,
          kind: e.category.label,
          title: e.name + (e.archived ? '  (archived)' : ''),
          subtitle: e.description.isNotEmpty
              ? snippet(e.description)
              : formatShortDate(day),
          open: () => s.openCalendarDay(day),
        ),
      );
    }
  }
  for (final t in ws.tasks.all) {
    if (has(t.title) || has(t.notes)) {
      results.add(
        SearchResult(
          icon: t.done
              ? Icons.check_box_outlined
              : Icons.check_box_outline_blank,
          kind: t.isExam ? 'Exam' : 'Task',
          title: t.title,
          subtitle: t.dueDate == null
              ? (ws.projects[t.projectId]?.name ?? '')
              : 'Due ${formatShortDate(t.dueDate!)}',
          open: () => s.openTask(t.id),
        ),
      );
    }
  }
  return results;
}

Future<void> showSearchDialog(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SearchDialog(state: state),
  );
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.state});

  final AppState state;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final results = searchEverything(widget.state, _query);
    return Dialog(
      alignment: const Alignment(0, -0.5),
      child: SizedBox(
        width: 620,
        height: 460,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: TextField(
                autofocus: true,
                style: const TextStyle(fontSize: 15),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Search notes, canvases, links, calendar and tasks',
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (results.isNotEmpty) {
                    Navigator.pop(context);
                    results.first.open();
                  }
                },
              ),
            ),
            const Divider(),
            Expanded(
              child: results.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty
                            ? 'Start typing to search everything.'
                            : 'Nothing found.',
                        style: const TextStyle(
                          color: AppColors.textFaint,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, i) {
                        final r = results[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            r.icon,
                            size: 18,
                            color: AppColors.textMuted,
                          ),
                          title: Text(r.title, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            r.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textFaint,
                            ),
                          ),
                          trailing: Text(
                            r.kind,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textFaint,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            r.open();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
