import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/library_models.dart';
import '../../data/models/record.dart';
import '../../platform/input_hints.dart';
import '../../widgets/common.dart';
import '../../widgets/page_scaffold.dart';
import '../capture/capture_dialog.dart';
import '../tasks/tasks_page.dart' show TaskRow;
import '../review/review_center.dart';
import 'activity.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    return WorkspaceBuilder(
      state: state,
      builder: (context) {
        final ws = state.workspace;
        final today = dateOnly(DateTime.now());
        final todays =
            ws.tasks.all
                .where(
                  (t) =>
                      !t.done &&
                      t.parentId == null &&
                      t.dueDate != null &&
                      daysBetween(t.dueDate!, today) >= 0,
                )
                .toList()
              ..sort((a, b) => b.priority.compareTo(a.priority));
        final upcoming = <(DateTime, String, Color, VoidCallback)>[];
        for (final t in ws.tasks.all) {
          final due = t.dueDate;
          if (t.done || due == null) continue;
          final diff = daysBetween(today, due);
          if (diff > 0 && diff <= 14) {
            upcoming.add((
              due,
              t.isExam ? 'Exam: ${t.title}' : t.title,
              AppColors.accent,
              () => state.openTask(t.id),
            ));
          }
        }
        for (final e in ws.entries.all) {
          if (e.archived ||
              e.category != CalendarCategory.events ||
              e.startDate == null) {
            continue;
          }
          final diff = daysBetween(today, e.startDate!);
          if (diff >= 0 && diff <= 14) {
            upcoming.add((
              e.startDate!,
              e.name,
              calendarCategoryColor(e.category),
              () => state.openCalendarDay(e.startDate!),
            ));
          }
        }
        upcoming.sort((a, b) => a.$1.compareTo(b.$1));
        final inbox = ws.inbox.all.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final notes = ws.notes.all.toList()
          ..sort((a, b) {
            if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
            return b.updatedAt.compareTo(a.updatedAt);
          });
        final canvases = [...state.canvasList]
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        final activity = activityTimeline(state, limit: 12);

        Widget card(String title, Widget child, {Widget? action}) => SizedBox(
          width: 520,
          child: SectionCard(title: title, action: action, child: child),
        );
        Widget empty(String text) => Text(
          text,
          style: TextStyle(fontSize: 13, color: AppColors.textFaint),
        );
        Widget row(
          IconData icon,
          String title,
          String trailing,
          VoidCallback onTap, {
          Color? color,
        }) => InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color ?? AppColors.textMuted),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                Text(
                  trailing,
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              ],
            ),
          ),
        );

        final sections = <String, Widget>{
          'today': card(
            "Today's Tasks",
            todays.isEmpty
                ? empty('Nothing due today.')
                : Column(
                    children: [
                      for (final t in todays.take(8))
                        TaskRow(
                          state: state,
                          task: t,
                          compact: true,
                          onTap: () => state.openTask(t.id),
                        ),
                    ],
                  ),
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GhostIconButton(
                  key: const ValueKey('home-review'),
                  icon: Icons.fact_check_outlined,
                  tooltip: 'Review today and this week',
                  onTap: () => showReviewCenter(context, state),
                ),
                GhostIconButton(
                  icon: Icons.add,
                  tooltip: 'Open Tasks',
                  onTap: () => state.goTo(AppPage.tasks),
                ),
              ],
            ),
          ),
          'upcoming': card(
            'Upcoming (next 14 days)',
            upcoming.isEmpty
                ? empty('No deadlines or events coming up.')
                : Column(
                    children: [
                      for (final u in upcoming.take(8))
                        row(
                          Icons.circle,
                          u.$2,
                          formatShortDate(u.$1),
                          u.$4,
                          color: u.$3,
                        ),
                    ],
                  ),
          ),
          if (inbox.isNotEmpty)
            'inbox': card(
              'Inbox  ·  ${inbox.length} to file',
              Column(
                children: [
                  for (final item in inbox.take(8))
                    _InboxRow(state: state, item: item),
                ],
              ),
            ),
          'notes': card(
            'Notes',
            notes.isEmpty
                ? empty(
                    'No notes yet. Quick Add or the Notes page creates one.',
                  )
                : Column(
                    children: [
                      for (final n in notes.take(6))
                        row(
                          n.favorite ? Icons.star : Icons.description_outlined,
                          n.displayTitle,
                          _ago(n.updatedAt),
                          () => state.openNote(n.id),
                          color: n.favorite ? AppColors.warm : null,
                        ),
                    ],
                  ),
          ),
          'canvases': card(
            'Recent mindmaps',
            Column(
              children: [
                for (final c in canvases.take(5))
                  row(
                    Icons.grid_view,
                    c.title,
                    _ago(c.updatedAt),
                    () => state.openCanvas(c.id),
                  ),
              ],
            ),
          ),
          'activity': card(
            'Activity',
            activity.isEmpty
                ? empty('Nothing in the last two weeks.')
                : Column(
                    key: const ValueKey('home-activity'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < activity.length; i++) ...[
                        if (i == 0 ||
                            daysBetween(activity[i].at, activity[i - 1].at) !=
                                0)
                          Padding(
                            padding: const EdgeInsets.only(top: 6, bottom: 2),
                            child: Text(
                              activityDayLabel(
                                activity[i].at,
                                DateTime.now(),
                                formatShortDate,
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textFaint,
                              ),
                            ),
                          ),
                        row(
                          activity[i].icon,
                          '${activity[i].verb} ${activity[i].what}: '
                              '${activity[i].title}',
                          '${activity[i].at.hour.toString().padLeft(2, '0')}:'
                              '${activity[i].at.minute.toString().padLeft(2, '0')}',
                          activity[i].open,
                        ),
                      ],
                    ],
                  ),
          ),
        };

        return PageScaffold(
          title: 'Home',
          subtitle: formatLongDate(DateTime.now()),
          trailing: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              GhostIconButton(
                key: const ValueKey('home-customize'),
                icon: Icons.tune,
                tooltip: 'Choose and arrange what this page shows',
                onTap: () => showHomeCustomizer(context, state),
              ),
              const SizedBox(width: Space.sm),
              FilledButton.icon(
                onPressed: () => openQuickAdd(context, state),
                icon: const Icon(Icons.bolt_outlined, size: 16),
                label: Text(withShortcut('Quick Add', 'Ctrl+N')),
              ),
            ],
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: Space.xxl),
            child: Wrap(
              spacing: Space.xl,
              runSpacing: Space.xl,
              children: [
                for (final name in state.homeSections) ?sections[name],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InboxRow extends StatelessWidget {
  const _InboxRow({required this.state, required this.item});

  final AppState state;
  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    final ws = state.workspace;
    final asset = ws.assets[item.assetId];
    final label = asset?.label ?? item.text ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          if (asset != null)
            AssetChip(workspace: ws, asset: asset)
          else
            Icon(Icons.notes, size: 16, color: AppColors.textMuted),
          if (asset == null) ...[
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ] else
            const Spacer(),
          TextButton(
            onPressed: () => showCaptureDialog(context, state, inboxItem: item),
            child: const Text('File…'),
          ),
          GhostIconButton(
            icon: Icons.close,
            tooltip: 'Dismiss',
            size: 14,
            onTap: () async {
              // A typed thought exists only here; links and photos keep
              // their own records, so only thoughts need a confirmation.
              final onlyCopy = asset == null && (item.text ?? '').isNotEmpty;
              if (onlyCopy &&
                  !await confirm(
                    context,
                    title: 'Delete this thought?',
                    message: 'It is only in the Inbox. File it to keep it.',
                  )) {
                return;
              }
              ws.inbox.remove(item.id);
            },
          ),
        ],
      ),
    );
  }
}

const _sectionNames = {
  'today': "Today's tasks",
  'upcoming': 'Upcoming (next 14 days)',
  'inbox': 'Inbox',
  'notes': 'Notes',
  'canvases': 'Recent mindmaps',
  'activity': 'Activity',
};

/// Lets the user choose which sections the start page shows and in what
/// order (drag to rearrange). Saved on this device.
Future<void> showHomeCustomizer(BuildContext context, AppState state) {
  final order = [
    ...state.homeSections,
    for (final s in AppState.allHomeSections)
      if (!state.homeSections.contains(s)) s,
  ];
  final shown = {...state.homeSections};
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Start page', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 360,
          height: 360,
          child: ReorderableListView(
            key: const ValueKey('home-customizer'),
            buildDefaultDragHandles: true,
            onReorderItem: (from, to) =>
                setState(() => order.insert(to, order.removeAt(from))),
            children: [
              for (final name in order)
                CheckboxListTile(
                  key: ValueKey('home-section-$name'),
                  value: shown.contains(name),
                  title: Text(_sectionNames[name] ?? name),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (on) => setState(
                    () => on == true ? shown.add(name) : shown.remove(name),
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
          TextButton(
            key: const ValueKey('home-customizer-save'),
            onPressed: () {
              state.setHomeSections([
                for (final name in order)
                  if (shown.contains(name)) name,
              ]);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
