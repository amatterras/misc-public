// The iPhone-only Home of the New interface: a compact daily overview built
// from the existing Calendar and Task data (see home_agenda.dart). It owns
// no data and no calendar logic: completion, detail views, creation, move
// and delete all call the same functions Calendar and Tasks use.
//
// Not on Home (by decision): swipe-to-action on cards, drag-to-reschedule.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../data/models/calendar_models.dart';
import '../data/models/canvas_models.dart' show newId;
import '../data/models/record.dart';
import '../data/models/task_models.dart';
import '../data/workspace.dart';
import '../features/calendar/entry_editor.dart';
import '../features/capture/capture_dialog.dart';
import '../features/search/search_dialog.dart';
import '../platform/platform.dart' as native;
import '../widgets/common.dart'
    show confirm, formatMonth, formatShortDate, weekdayShort;
import '../widgets/date_prefs.dart';
import 'home_agenda.dart';
import 'new_components.dart';
import 'new_folder_colors.dart' show contrastOn;
import 'new_tokens.dart';

class NewHome extends StatefulWidget {
  const NewHome({super.key, required this.state});

  final AppState state;

  @override
  State<NewHome> createState() => _NewHomeState();
}

class _NewHomeState extends State<NewHome> {
  static const _basePage = 1000;

  late DateTime _selected = dateOnly(DateTime.now());
  late final DateTime _anchorWeek = DatePrefs.weekStart(DateTime.now());
  late final PageController _pages = PageController(initialPage: _basePage);
  bool _monthOpen = false;
  bool _showPast = false;
  bool _showAllUnscheduled = false;
  bool _jumping = false;

  AppState get s => widget.state;
  Workspace get ws => s.workspace;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  DateTime _weekOf(int page) => addDays(_anchorWeek, (page - _basePage) * 7);

  int _pageOf(DateTime day) =>
      _basePage + daysBetween(_anchorWeek, DatePrefs.weekStart(day)) ~/ 7;

  void _select(DateTime day) {
    final d = dateOnly(day);
    setState(() {
      _selected = d;
      _showPast = false;
      _showAllUnscheduled = false;
    });
    final page = _pageOf(d);
    if (_pages.hasClients && _pages.page?.round() != page) {
      _jumping = true;
      _pages.jumpToPage(page);
      _jumping = false;
    }
  }

  /// Swiping the date strip moves to the same weekday of that week.
  void _weekSwiped(int page) {
    if (_jumping) return;
    final offset = daysBetween(DatePrefs.weekStart(_selected), _selected);
    setState(() {
      _selected = addDays(_weekOf(page), offset);
      _showPast = false;
    });
  }

  // ── actions: all existing ──────────────────────────────────────────────

  void _toggle(HomeItem it) {
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

  Future<void> _open(HomeItem it) async {
    switch (it.item) {
      case EntryOnDay(:final entry):
        await showEntryEditor(context, s, entry: entry);
      case TaskOnDay(:final task):
        s.openTask(task.id); // navigating leaves Home
      case ExternalOnDay(:final event):
        if (event.link.isNotEmpty) native.openUrl(event.link);
    }
  }

  Future<void> _menu(HomeItem it) async {
    HapticFeedback.mediumImpact();
    final external = it.item is ExternalOnDay;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: NewColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(NewRadii.lg)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(NewSpace.lg),
              child: Text(
                it.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NewText.title.copyWith(color: NewColors.text),
              ),
            ),
            _sheetRow(Icons.edit_outlined, external ? 'Open' : 'Edit', 'edit'),
            if (!external) ...[
              _sheetRow(Icons.copy_outlined, 'Duplicate', 'duplicate'),
              _sheetRow(Icons.event_repeat_outlined, 'Reschedule', 'move'),
              _sheetRow(
                Icons.delete_outline,
                'Delete',
                'delete',
                color: NewColors.danger,
              ),
            ],
            const SizedBox(height: NewSpace.sm),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'edit':
        await _open(it);
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

  Widget _sheetRow(IconData icon, String label, String value, {Color? color}) =>
      ListTile(
        key: ValueKey('home-menu-$value'),
        leading: Icon(icon, color: color ?? NewColors.textMuted),
        title: Text(label, style: TextStyle(color: color ?? NewColors.text)),
        onTap: () => Navigator.pop(context, value),
      );

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

  Future<void> _quickAdd() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: NewColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(NewRadii.lg)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: NewSpace.sm),
            _sheetRow(Icons.check_circle_outline, 'Task', 'task'),
            _sheetRow(Icons.event_outlined, 'Event', 'event'),
            _sheetRow(Icons.repeat, 'Habit', 'habit'),
            _sheetRow(Icons.notifications_none, 'Reminder', 'reminder'),
            const SizedBox(height: NewSpace.sm),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'task':
        await showCaptureDialog(
          context,
          s,
          destination: CaptureDestination.task,
          day: _selected,
        );
      case 'event':
        await showEntryEditor(
          context,
          s,
          category: CalendarCategory.events,
          day: _selected,
        );
      case 'habit':
        await showEntryEditor(
          context,
          s,
          category: CalendarCategory.habits,
          day: _selected,
        );
      case 'reminder':
        await showEntryEditor(
          context,
          s,
          category: CalendarCategory.other,
          day: _selected,
        );
    }
  }

  // ── building ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: NewColors.background,
      child: ListenableBuilder(
        listenable: Listenable.merge([s, ws.changes]),
        builder: (context, _) {
          final now = DateTime.now();
          final agenda = HomeAgenda.build(ws, _selected, now: now);
          return Stack(
            children: [
              Column(
                children: [
                  _header(),
                  _monthRow(),
                  AnimatedSize(
                    duration: NewMotion.normal,
                    curve: NewMotion.curve,
                    alignment: Alignment.topCenter,
                    child: _monthOpen ? _monthGrid() : _weekStrip(),
                  ),
                  const SizedBox(height: NewSpace.sm),
                  Divider(height: 1, color: NewColors.border),
                  Expanded(child: _agenda(agenda, now)),
                ],
              ),
              Positioned(
                right: NewSpace.lg,
                bottom: NewSpace.lg,
                child: _QuickAddFab(onTap: _quickAdd),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(
      NewSpace.lg,
      NewSpace.md,
      NewSpace.sm,
      NewSpace.xs,
    ),
    child: Row(
      children: [
        Text('Home', style: NewText.heading.copyWith(color: NewColors.text)),
        const Spacer(),
        IconButton(
          key: const ValueKey('home-search'),
          tooltip: 'Search',
          icon: Icon(Icons.search, color: NewColors.textMuted),
          onPressed: () => showSearchDialog(context, s),
        ),
      ],
    ),
  );

  Widget _monthRow() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: NewSpace.lg),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (_monthOpen)
          IconButton(
            key: const ValueKey('home-month-prev'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.chevron_left, color: NewColors.textMuted),
            onPressed: () =>
                _select(DateTime(_selected.year, _selected.month - 1, 1)),
          ),
        InkWell(
          key: const ValueKey('home-month-label'),
          borderRadius: BorderRadius.circular(NewRadii.sm),
          onTap: () => setState(() => _monthOpen = !_monthOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NewSpace.sm,
              vertical: NewSpace.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatMonth(_selected),
                  style: NewText.title.copyWith(color: NewColors.text),
                ),
                const SizedBox(width: NewSpace.xs),
                AnimatedRotation(
                  turns: _monthOpen ? 0.5 : 0,
                  duration: NewMotion.normal,
                  child: Icon(
                    Icons.expand_more,
                    size: 18,
                    color: NewColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_monthOpen)
          IconButton(
            key: const ValueKey('home-month-next'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.chevron_right, color: NewColors.textMuted),
            onPressed: () =>
                _select(DateTime(_selected.year, _selected.month + 1, 1)),
          ),
      ],
    ),
  );

  Widget _weekStrip() => SizedBox(
    key: const ValueKey('home-week-strip'),
    height: 76,
    child: PageView.builder(
      controller: _pages,
      onPageChanged: _weekSwiped,
      itemBuilder: (context, page) {
        final start = _weekOf(page);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: NewSpace.sm),
          child: Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: _dateCell(addDays(start, i), showWeekday: true),
                ),
            ],
          ),
        );
      },
    ),
  );

  Widget _monthGrid() {
    final first = DateTime(_selected.year, _selected.month, 1);
    final gridStart = DatePrefs.weekStart(first);
    final weeks =
        ((daysBetween(gridStart, first) +
                    DateUtils.getDaysInMonth(first.year, first.month)) /
                7)
            .ceil();
    return Padding(
      key: const ValueKey('home-month-grid'),
      padding: const EdgeInsets.symmetric(horizontal: NewSpace.sm),
      child: Column(
        children: [
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Center(
                    child: Text(
                      weekdayShort(addDays(gridStart, i)),
                      style: NewText.meta.copyWith(color: NewColors.textFaint),
                    ),
                  ),
                ),
            ],
          ),
          for (var w = 0; w < weeks; w++)
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: _dateCell(
                      addDays(gridStart, w * 7 + i),
                      showWeekday: false,
                      dim: addDays(gridStart, w * 7 + i).month != first.month,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _dateCell(
    DateTime day, {
    required bool showWeekday,
    bool dim = false,
  }) {
    final selected = daysBetween(day, _selected) == 0;
    final today = daysBetween(day, DateTime.now()) == 0;
    final marks = HomeAgenda.markers(ws, day);
    final onPastel = contrastOn(NewColors.paleLavender);
    return InkWell(
      key: ValueKey('home-date-${dayKey(day)}'),
      borderRadius: BorderRadius.circular(NewRadii.md),
      onTap: () {
        _select(day);
        if (_monthOpen) setState(() => _monthOpen = false);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NewSpace.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showWeekday)
              Text(
                weekdayShort(day),
                style: NewText.meta.copyWith(
                  color: selected ? NewColors.text : NewColors.textFaint,
                ),
              ),
            if (showWeekday) const SizedBox(height: 2),
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: selected
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          NewColors.paleLavender,
                          NewColors.softCoral.withValues(alpha: 0.95),
                        ],
                      )
                    : null,
                border: !selected && today
                    ? Border.all(color: NewColors.accent)
                    : null,
              ),
              child: Text(
                '${day.day}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected || today
                      ? FontWeight.w700
                      : FontWeight.w400,
                  color: selected
                      ? onPastel
                      : dim
                      ? NewColors.textFaint
                      : NewColors.text,
                ),
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              height: 5,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in marks)
                    Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _agenda(HomeAgenda agenda, DateTime now) {
    final today = daysBetween(_selected, now) == 0;
    final nowHour = now.hour;
    final hours = agenda.hours;
    final past = today
        ? [
            for (final h in hours)
              if (h < nowHour) h,
          ]
        : <int>[];
    final shown = [
      for (final h in hours)
        if (!past.contains(h) || _showPast) h,
    ];
    final undated = agenda.unscheduled;
    final unscheduled = _showAllUnscheduled || undated.length <= 6
        ? undated
        : undated.take(6).toList();

    return ListView(
      key: const ValueKey('home-agenda'),
      padding: const EdgeInsets.fromLTRB(
        NewSpace.lg,
        NewSpace.md,
        NewSpace.lg,
        96, // clear of the floating Quick Add
      ),
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                '${weekdayShort(_selected)}, ${formatShortDate(_selected)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NewText.title.copyWith(color: NewColors.text),
              ),
            ),
            const SizedBox(width: NewSpace.sm),
            if (today) const NewPill('Today'),
            const Spacer(),
            Text(
              agenda.total == 0 ? 'Nothing planned' : '${agenda.total} planned',
              key: const ValueKey('home-count'),
              style: NewText.meta.copyWith(color: NewColors.textFaint),
            ),
          ],
        ),
        const SizedBox(height: NewSpace.md),
        if (agenda.overdue.isNotEmpty) ...[
          _section(
            'Overdue',
            color: NewColors.danger,
            count: agenda.overdue.length,
          ),
          for (final it in agenda.overdue) _card(it, overdue: true),
          const SizedBox(height: NewSpace.md),
        ],
        if (agenda.allDay.isNotEmpty) ...[
          _section('All day'),
          for (final it in agenda.allDay) _card(it),
          const SizedBox(height: NewSpace.md),
        ],
        if (past.isNotEmpty && !_showPast)
          Padding(
            padding: const EdgeInsets.only(bottom: NewSpace.sm),
            child: InkWell(
              key: const ValueKey('home-past'),
              borderRadius: BorderRadius.circular(NewRadii.sm),
              onTap: () => setState(() => _showPast = true),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: NewSpace.sm),
                child: Row(
                  children: [
                    Icon(Icons.history, size: 16, color: NewColors.textFaint),
                    const SizedBox(width: NewSpace.sm),
                    Text(
                      'Earlier today · ${past.fold<int>(0, (n, h) => n + agenda.timed[h]!.length)}',
                      style: NewText.meta.copyWith(color: NewColors.textMuted),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.expand_more,
                      size: 18,
                      color: NewColors.textFaint,
                    ),
                  ],
                ),
              ),
            ),
          ),
        for (final h in shown)
          _hourRow(h, agenda.timed[h]!, current: today && h == nowHour),
        if (undated.isNotEmpty) ...[
          const SizedBox(height: NewSpace.md),
          _section('Unscheduled', count: undated.length),
          for (final it in unscheduled) _card(it),
          if (undated.length > unscheduled.length)
            TextButton(
              key: const ValueKey('home-unscheduled-more'),
              onPressed: () => setState(() => _showAllUnscheduled = true),
              child: Text('Show all ${undated.length}'),
            ),
        ],
        const SizedBox(height: NewSpace.lg),
        _summary(agenda),
      ],
    );
  }

  Widget _section(String text, {Color? color, int? count}) => Padding(
    key: ValueKey('home-section-${text.toLowerCase().replaceAll(' ', '-')}'),
    padding: const EdgeInsets.only(bottom: NewSpace.sm),
    child: Row(
      children: [
        Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w600,
            color: color ?? NewColors.textMuted,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: NewSpace.sm),
          Text(
            '$count',
            style: NewText.meta.copyWith(color: color ?? NewColors.textFaint),
          ),
        ],
      ],
    ),
  );

  Widget _hourRow(int hour, List<HomeItem> items, {required bool current}) {
    return Padding(
      key: ValueKey('home-hour-$hour'),
      padding: const EdgeInsets.only(bottom: NewSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                formatClock(hour * 60),
                style: NewText.meta.copyWith(
                  color: current ? NewColors.accent : NewColors.textFaint,
                  fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(children: [for (final it in items) _card(it)]),
          ),
        ],
      ),
    );
  }

  Widget _card(HomeItem it, {bool overdue = false}) => Padding(
    padding: const EdgeInsets.only(bottom: NewSpace.sm),
    child: _HomeCard(
      key: ValueKey('home-card-${it.id}'),
      item: it,
      overdue: overdue,
      onToggle: it.completable ? () => _toggle(it) : null,
      onTap: () => _open(it),
      onLongPress: () => _menu(it),
    ),
  );

  Widget _summary(HomeAgenda a) => NewCard(
    key: const ValueKey('home-summary'),
    color: NewColors.surfaceSecondary,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Daily progress',
              style: NewText.label.copyWith(color: NewColors.textMuted),
            ),
            const Spacer(),
            Text(
              '${(a.progress * 100).round()}%',
              key: const ValueKey('home-progress'),
              style: NewText.label.copyWith(color: NewColors.text),
            ),
          ],
        ),
        const SizedBox(height: NewSpace.sm),
        NewProgressBar(value: a.progress),
        const SizedBox(height: NewSpace.md),
        Row(
          children: [
            _stat('${a.completed}', 'Completed'),
            _stat('${a.remaining}', 'Remaining'),
            _stat('${a.upcomingEvents}', 'Upcoming events'),
          ],
        ),
      ],
    ),
  );

  Widget _stat(String value, String label) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: NewText.title.copyWith(color: NewColors.text)),
        Text(label, style: NewText.meta.copyWith(color: NewColors.textFaint)),
      ],
    ),
  );
}

/// One item on Home. Drawing only; every action is passed in.
class _HomeCard extends StatelessWidget {
  const _HomeCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.onLongPress,
    this.onToggle,
    this.overdue = false,
  });

  final HomeItem item;
  final VoidCallback? onToggle;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final kind = item.kind;
    final done = item.done;
    final subtitle = item.subtitle;
    return NewCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      onLongPress: onLongPress,
      borderColor: overdue ? NewColors.danger.withValues(alpha: 0.5) : null,
      child: IntrinsicHeight(
        child: Row(
          children: [
            Container(width: 4, color: kind.color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NewSpace.md,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: done ? NewColors.textFaint : NewColors.text,
                        decoration: done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(kind.icon, size: 13, color: kind.color),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            [
                              kind.label,
                              ?item.timeLabel,
                              if (subtitle.isNotEmpty) subtitle,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NewText.meta.copyWith(
                              color: NewColors.textFaint,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (onToggle != null)
              InkResponse(
                key: ValueKey('home-toggle-${item.id}'),
                onTap: onToggle,
                radius: 24,
                child: SizedBox(
                  width: 48,
                  child: Center(
                    child: AnimatedContainer(
                      duration: NewMotion.quick,
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: done ? kind.color : Colors.transparent,
                        border: Border.all(
                          color: done ? kind.color : NewColors.border,
                          width: 1.5,
                        ),
                      ),
                      child: done
                          ? Icon(
                              Icons.check,
                              size: 16,
                              color: contrastOn(kind.color),
                            )
                          : null,
                    ),
                  ),
                ),
              )
            else
              const SizedBox(width: NewSpace.md),
          ],
        ),
      ),
    );
  }
}

class _QuickAddFab extends StatelessWidget {
  const _QuickAddFab({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Add task, event, habit or reminder',
      child: GestureDetector(
        key: const ValueKey('home-quick-add'),
        onTap: onTap,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            gradient: NewGradients.brand,
            shape: BoxShape.circle,
            boxShadow: [
              ...NewShadows.floating,
              BoxShadow(
                color: NewColors.warmCoral.withValues(alpha: 0.35),
                blurRadius: 16,
              ),
            ],
          ),
          child: const Icon(Icons.add, size: 28, color: Colors.white),
        ),
      ),
    );
  }
}
