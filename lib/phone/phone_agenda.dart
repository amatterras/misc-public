// One day, written as a printed schedule: a column of times on the left, the
// thing in the middle, a tick on the right. Used by Today and by Calendar.
//
// It owns no data and no calendar logic. What a day holds comes from
// HomeAgenda (a sorting of Workspace.itemsOn); ticking, editing, moving and
// deleting call the same functions Calendar and Tasks use.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../data/models/calendar_models.dart';
import '../data/models/canvas_models.dart' show newId;
import '../data/models/record.dart';
import '../data/models/task_models.dart';
import '../data/workspace.dart';
import '../features/calendar/entry_editor.dart';
import '../new_ui/home_agenda.dart';
import '../app/theme.dart';
import '../platform/platform.dart' as native;
import '../widgets/common.dart' show confirm;
import 'phone_task.dart';
import 'phone_tokens.dart';
import 'phone_widgets.dart';

/// What happens when an item is ticked, opened or long-pressed. Shared by
/// every list of items (Today, Calendar's day, the task list).
mixin AgendaActions<T extends StatefulWidget> on State<T> {
  AppState get s;
  Workspace get ws => s.workspace;

  // ── actions (all existing functions) ───────────────────────────────────

  void tick(HomeItem it) {
    HapticFeedback.selectionClick();
    switch (it.item) {
      case TaskOnDay(:final task):
        s.toggleTask(task.id);
      case EntryOnDay(:final entry):
        ws.toggleEntryCompletion(entry.id, it.day);
      case ExternalOnDay():
        break;
    }
  }

  Future<void> open(HomeItem it) async {
    switch (it.item) {
      case EntryOnDay(:final entry):
        await showEntryEditor(context, s, entry: entry);
      case TaskOnDay(:final task):
        await openPhoneTask(context, s, task.id);
      case ExternalOnDay(:final event):
        if (event.link.isNotEmpty) native.openUrl(event.link);
    }
  }

  Future<void> menu(HomeItem it) async {
    final external = it.item is ExternalOnDay;
    final choice = await showPhoneSheet<String>(
      context,
      eyebrow: it.title,
      children: (c) => [
        SheetItem(
          label: external ? 'Open' : 'Edit',
          onTap: () => Navigator.pop(c, 'edit'),
        ),
        if (!external) ...[
          SheetItem(
            label: 'Duplicate',
            onTap: () => Navigator.pop(c, 'duplicate'),
          ),
          SheetItem(label: 'Reschedule', onTap: () => Navigator.pop(c, 'move')),
          SheetItem(
            label: 'Delete',
            color: AppColors.danger,
            onTap: () => Navigator.pop(c, 'delete'),
          ),
        ],
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'edit':
        await open(it);
      case 'duplicate':
        _duplicate(it);
      case 'move':
        final picked = await showDatePicker(
          context: context,
          initialDate: it.day,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) ws.moveDayItem(it.item, it.day, dateOnly(picked));
      case 'delete':
        final ok = await confirm(
          context,
          title: 'Delete “${it.title}”?',
          message: it.item is TaskOnDay
              ? 'Its subtasks are deleted too.'
              : 'This removes it from every view.',
        );
        if (!ok) return;
        switch (it.item) {
          case TaskOnDay(:final task):
            ws.deleteTask(task.id);
          case EntryOnDay(:final entry):
            ws.entries.remove(entry.id);
          case ExternalOnDay():
            break;
        }
        s.showToast('Deleted “${it.title}”.');
    }
  }

  void _duplicate(HomeItem it) {
    switch (it.item) {
      case TaskOnDay(:final task):
        ws.tasks.put(
          Task.fromJson({...task.toJson(), 'id': newId()}).copyWith(
            title: '${task.title} (copy)',
            done: false,
            completedAt: () => null,
          ),
        );
      case EntryOnDay(:final entry):
        try {
          ws.saveEntry(
            CalendarEntry.fromJson({...entry.toJson(), 'id': newId()})
                .copyWith(name: '${entry.name} (copy)', checkoffs: {}),
          );
        } on CalendarLimitException catch (e) {
          s.showToast(e.toString());
        }
      case ExternalOnDay():
        break;
    }
  }
}

class PhoneAgenda extends StatefulWidget {
  const PhoneAgenda({
    super.key,
    required this.state,
    required this.day,
    this.emptyHeadline = 'Nothing planned.',
    this.emptyHint = 'Add something with the + below.',
  });

  final AppState state;
  final DateTime day;
  final String emptyHeadline;
  final String emptyHint;

  @override
  State<PhoneAgenda> createState() => _PhoneAgendaState();
}

class _PhoneAgendaState extends State<PhoneAgenda> with AgendaActions {
  bool _showPast = false;
  bool _showAllUnscheduled = false;

  @override
  AppState get s => widget.state;

  @override
  void didUpdateWidget(PhoneAgenda old) {
    super.didUpdateWidget(old);
    if (dateOnly(old.day) != dateOnly(widget.day)) {
      _showPast = false;
      _showAllUnscheduled = false;
    }
  }

  // ── building ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final day = dateOnly(widget.day);
    final isToday = daysBetween(day, dateOnly(now)) == 0;
    final agenda = HomeAgenda.build(ws, day, now: now);
    final nowMinutes = now.hour * 60 + now.minute;

    if (agenda.total == 0) {
      return EmptyNote(widget.emptyHeadline, hint: widget.emptyHint);
    }

    // Every timed item in order; the ones that are over (and finished or
    // fixed in time) fold behind "Earlier today" on today.
    final timed = [for (final h in agenda.hours) ...agenda.timed[h]!];
    bool isPast(HomeItem i) {
      if (!isToday) return false;
      final end = i.endMinutes ?? i.startMinutes!;
      if (end >= nowMinutes) return false;
      return i.done || !i.completable || i.kind == HomeKind.event;
    }

    final past = [
      for (final i in timed)
        if (isPast(i)) i,
    ];
    final upcoming = [
      for (final i in timed)
        if (!isPast(i)) i,
    ];

    final unscheduled = _showAllUnscheduled || agenda.unscheduled.length <= 6
        ? agenda.unscheduled
        : agenda.unscheduled.take(6).toList();

    final children = <Widget>[];

    if (agenda.overdue.isNotEmpty) {
      children
        ..add(
          _sectionLabel(
            'Overdue',
            color: AppColors.warm,
            trailing: '${agenda.overdue.length}',
          ),
        )
        ..addAll(
          agenda.overdue.map((i) {
            final due = i.item is TaskOnDay
                ? (i.item as TaskOnDay).task.dueDate
                : null;
            return _row(
              i,
              label: due == null
                  ? null
                  : '${due.day} ${monthName(due.month).substring(0, 3)}',
            );
          }),
        );
    }

    if (agenda.allDay.isNotEmpty) {
      children
        ..add(_sectionLabel('All day'))
        ..addAll(agenda.allDay.map(_row));
    }

    if (timed.isNotEmpty) {
      if (agenda.allDay.isNotEmpty || agenda.overdue.isNotEmpty) {
        children.add(_sectionLabel('Schedule'));
      }
      if (past.isNotEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: PhoneSpace.margin),
            child: TextLink(
              _showPast
                  ? 'Hide earlier today'
                  : 'Earlier today · ${past.length}',
              trailing: _showPast
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              onTap: () => setState(() => _showPast = !_showPast),
            ),
          ),
        );
        if (_showPast) children.addAll(past.map(_row));
      }
      var nowPlaced = !isToday || upcoming.isEmpty;
      for (final i in upcoming) {
        if (!nowPlaced && (i.startMinutes ?? 0) >= nowMinutes) {
          children.add(_NowLine(minutes: nowMinutes));
          nowPlaced = true;
        }
        children.add(_row(i));
      }
      if (!nowPlaced) children.add(_NowLine(minutes: nowMinutes));
    }

    if (unscheduled.isNotEmpty) {
      children
        ..add(
          _sectionLabel(
            'Anytime',
            trailing: agenda.unscheduled.length > unscheduled.length
                ? '${unscheduled.length} of ${agenda.unscheduled.length}'
                : null,
          ),
        )
        ..addAll(unscheduled.map(_row));
      if (agenda.unscheduled.length > unscheduled.length) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: PhoneSpace.margin),
            child: TextLink(
              'Show all ${agenda.unscheduled.length}',
              trailing: Icons.keyboard_arrow_down_rounded,
              onTap: () => setState(() => _showAllUnscheduled = true),
            ),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _sectionLabel(String text, {Color? color, String? trailing}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(
          PhoneSpace.margin,
          26,
          PhoneSpace.margin,
          6,
        ),
        child: Eyebrow(text, color: color, trailing: trailing),
      );

  Widget _row(HomeItem it, {String? label}) => AgendaRow(
    leadingLabel: label,
    key: ValueKey('agenda-${it.item.runtimeType}-${it.id}-${it.day}'),
    item: it,
    onTick: () => tick(it),
    onOpen: () => open(it),
    onMenu: () => menu(it),
  );
}

/// One line of a schedule. [leadingLabel] replaces the clock time in the left
/// column (a due date in the task list).
class AgendaRow extends StatelessWidget {
  const AgendaRow({
    super.key,
    required this.item,
    required this.onTick,
    required this.onOpen,
    required this.onMenu,
    this.leadingLabel,
  });

  final String? leadingLabel;
  final HomeItem item;
  final VoidCallback onTick;
  final VoidCallback onOpen;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final done = item.done;
    final start = item.startMinutes;
    final end = item.endMinutes;
    final sub = item.subtitle;
    return Press(
      onTap: onOpen,
      onLongPress: onMenu,
      child: Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 62),
            child: Padding(
              padding: const EdgeInsets.only(left: PhoneSpace.margin),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: PhoneSpace.timeColumn,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: leadingLabel != null
                          ? Text(
                              leadingLabel!,
                              style: PhoneType.time.copyWith(
                                color: AppColors.textFaint,
                              ),
                            )
                          : start == null
                          ? null
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  formatClock(start),
                                  style: PhoneType.time.copyWith(
                                    color: done
                                        ? AppColors.textFaint
                                        : AppColors.text,
                                  ),
                                ),
                                if (end != null && end > start)
                                  Text(
                                    formatClock(end % (24 * 60)),
                                    style: PhoneType.time.copyWith(
                                      fontSize: AppType.sizeLabel,
                                      color: AppColors.textFaint,
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: PhoneType.row.copyWith(
                              color: done
                                  ? AppColors.textFaint
                                  : AppColors.text,
                              decoration: done
                                  ? TextDecoration.lineThrough
                                  : null,
                              decorationColor: AppColors.textFaint,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: item.kind.color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  sub.isEmpty
                                      ? item.kind.label
                                      : '${item.kind.label} · $sub',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: PhoneType.meta,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: item.completable
                        ? Align(
                            alignment: Alignment.topCenter,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: TickRing(done: done, onTap: onTick),
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
          const Hairline(inset: PhoneSpace.margin + PhoneSpace.timeColumn),
        ],
      ),
    );
  }
}

/// "Now" in the schedule: the time and a line in the brand gradient.
class _NowLine extends StatelessWidget {
  const _NowLine({required this.minutes});

  final int minutes;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: PhoneSpace.margin, top: 4, bottom: 4),
    child: SizedBox(
      height: 22,
      child: Row(
        children: [
          SizedBox(
            width: PhoneSpace.timeColumn,
            child: Text(
              formatClock(minutes),
              style: PhoneType.time.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.accent,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1.5,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    BrandColors.iris,
                    BrandColors.coral.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
