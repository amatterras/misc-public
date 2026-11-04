// Calendar on the phone: the month as a quiet grid of numerals (the chosen day
// is the one inverted figure), the chosen day's schedule below it, and a Tasks
// tab with every open task by when it is due. Same records as the full
// Calendar, which stays one tap away under More.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../data/models/calendar_models.dart' show CalendarCategory;
import '../data/models/record.dart';
import '../data/models/task_models.dart';
import '../data/workspace.dart' show TaskOnDay;
import '../new_ui/home_agenda.dart';
import '../new_ui/new_tokens.dart';
import '../widgets/date_prefs.dart';
import 'phone_agenda.dart';
import 'phone_capture.dart' show PhoneDay;
import 'phone_more.dart';
import 'phone_tokens.dart';
import 'phone_widgets.dart';

class PhoneCalendar extends StatefulWidget {
  const PhoneCalendar({super.key, required this.state});

  final AppState state;

  @override
  State<PhoneCalendar> createState() => _PhoneCalendarState();
}

class _PhoneCalendarState extends State<PhoneCalendar> {
  static const _base = 1200;
  static const _cellHeight = 50.0;

  bool _tasks = false;
  late DateTime _selected = dateOnly(DateTime.now());
  late final DateTime _anchor = DateTime(
    DateTime.now().year,
    DateTime.now().month,
  );
  late final PageController _pages = PageController(initialPage: _base);
  late DateTime _month = _anchor;
  bool _jumping = false;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    s.addListener(_focusCheck);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusCheck());
  }

  @override
  void dispose() {
    s.removeListener(_focusCheck);
    _pages.dispose();
    super.dispose();
  }

  /// Something elsewhere asked Calendar to show a day.
  void _focusCheck() {
    final day = s.focusDay;
    if (day == null || !mounted) return;
    s.focusDay = null;
    setState(() => _tasks = false);
    _select(day);
  }

  DateTime _monthOf(int page) =>
      DateTime(_anchor.year, _anchor.month + (page - _base));

  int _pageOfMonth(DateTime d) =>
      _base + (d.year - _anchor.year) * 12 + d.month - _anchor.month;

  void _select(DateTime day) {
    final d = dateOnly(day);
    PhoneDay.selected = d;
    setState(() {
      _selected = d;
      _month = DateTime(d.year, d.month);
    });
    final page = _pageOfMonth(d);
    if (_pages.hasClients && _pages.page?.round() != page) {
      _jumping = true;
      _pages.jumpToPage(page);
      _jumping = false;
    }
  }

  void _monthSwiped(int page) {
    if (_jumping) return;
    final m = _monthOf(page);
    final now = DateTime.now();
    final d = (m.year == now.year && m.month == now.month)
        ? dateOnly(now)
        : DateTime(m.year, m.month);
    PhoneDay.selected = d;
    setState(() {
      _month = m;
      _selected = d;
    });
  }

  void _step(int by) => _pages.animateToPage(
    (_pages.page ?? _base.toDouble()).round() + by,
    duration: const Duration(milliseconds: 260),
    curve: Curves.easeOutCubic,
  );

  int _rows(DateTime month) {
    final lead =
        (DateTime(month.year, month.month).weekday - DatePrefs.firstWeekday) %
        7;
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    return ((lead + days) / 7).ceil();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.workspace.changes]),
      builder: (context, _) {
        final now = DateTime.now();
        final thisMonth = _month.year == now.year && _month.month == now.month;
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: PhoneHeader(
                eyebrow: '${_month.year}',
                title: monthName(_month.month),
                actions: [
                  PhoneMoreButtons(state: s, tab: PhoneTabKind.calendar),
                ],
              ),
            ),
            SliverToBoxAdapter(child: _modeRow(thisMonth)),
            if (_tasks)
              SliverToBoxAdapter(child: _TaskList(state: s))
            else ...[
              SliverToBoxAdapter(child: _weekdayRow()),
              SliverToBoxAdapter(child: _grid()),
              const SliverToBoxAdapter(child: Hairline()),
              SliverToBoxAdapter(child: _dayHeading()),
              SliverToBoxAdapter(
                child: PhoneAgenda(
                  state: s,
                  day: _selected,
                  emptyHeadline: 'Nothing planned.',
                  emptyHint: 'Add something with the + below.',
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        );
      },
    );
  }

  Widget _modeRow(bool thisMonth) => Padding(
    padding: const EdgeInsets.only(left: PhoneSpace.margin, right: 8),
    child: Row(
      children: [
        _mode('Month', !_tasks, () => setState(() => _tasks = false)),
        const SizedBox(width: 22),
        _mode('Tasks', _tasks, () => setState(() => _tasks = true)),
        const Spacer(),
        if (!_tasks) ...[
          if (!thisMonth)
            TextLink('Today', onTap: () => _select(DateTime.now())),
          GlyphButton(
            icon: Icons.chevron_left_rounded,
            label: 'Previous month',
            size: 26,
            onTap: () => _step(-1),
          ),
          GlyphButton(
            icon: Icons.chevron_right_rounded,
            label: 'Next month',
            size: 26,
            onTap: () => _step(1),
          ),
        ],
      ],
    ),
  );

  Widget _mode(String label, bool on, VoidCallback onTap) => Press(
    onTap: onTap,
    child: SizedBox(
      height: 44,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: on ? NewColors.text : NewColors.textFaint,
            ),
          ),
          const SizedBox(height: 6),
          Container(height: 2, width: on ? 16 : 0, color: NewColors.text),
          const SizedBox(height: 4),
        ],
      ),
    ),
  );

  Widget _weekdayRow() {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PhoneSpace.margin - 6,
        6,
        PhoneSpace.margin - 6,
        4,
      ),
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Center(
                child: Text(
                  letters[(DatePrefs.firstWeekday - 1 + i) % 7],
                  style: PhoneType.eyebrow.copyWith(fontSize: 10.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _grid() => AnimatedContainer(
    duration: const Duration(milliseconds: 200),
    curve: Curves.easeOutCubic,
    height: _rows(_month) * _cellHeight + 6,
    child: PageView.builder(
      key: const ValueKey('phone-month'),
      controller: _pages,
      onPageChanged: _monthSwiped,
      itemBuilder: (context, page) {
        final month = _monthOf(page);
        final lead =
            (DateTime(month.year, month.month).weekday -
                DatePrefs.firstWeekday) %
            7;
        final days = DateUtils.getDaysInMonth(month.year, month.month);
        final rows = _rows(month);
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PhoneSpace.margin - 6,
          ),
          child: Column(
            children: [
              for (var r = 0; r < rows; r++)
                SizedBox(
                  height: _cellHeight,
                  child: Row(
                    children: [
                      for (var c = 0; c < 7; c++)
                        Expanded(
                          child: () {
                            final n = r * 7 + c - lead + 1;
                            if (n < 1 || n > days) return const SizedBox();
                            return _cell(DateTime(month.year, month.month, n));
                          }(),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );

  Widget _cell(DateTime day) {
    final selected = day == _selected;
    final today = daysBetween(dateOnly(DateTime.now()), day) == 0;
    final markers = selected
        ? const <Color>[]
        : HomeAgenda.markers(s.workspace, day, max: 3);
    return Press(
      onTap: () {
        HapticFeedback.selectionClick();
        PhoneDay.selected = day;
        setState(() => _selected = day);
      },
      child: Semantics(
        selected: selected,
        label: '${weekdayName(day.weekday)} ${day.day}',
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? NewColors.text : Colors.transparent,
                ),
                child: Text(
                  '${day.day}',
                  style: PhoneType.numeral.copyWith(
                    fontSize: 16.5,
                    fontWeight: selected || today
                        ? FontWeight.w800
                        : FontWeight.w500,
                    color: selected
                        ? NewColors.background
                        : today
                        ? NewColors.accent
                        : NewColors.text,
                  ),
                ),
              ),
              SizedBox(
                height: 7,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final c in markers)
                      Container(
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.only(
                          top: 3,
                          left: 1.5,
                          right: 1.5,
                        ),
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
      ),
    );
  }

  Widget _dayHeading() {
    final isToday = daysBetween(dateOnly(DateTime.now()), _selected) == 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PhoneSpace.margin,
        20,
        PhoneSpace.margin,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '${weekdayName(_selected.weekday)} ${_selected.day}',
            style: PhoneType.title,
          ),
          if (isToday) ...[
            const SizedBox(width: 10),
            Text(
              'TODAY',
              style: PhoneType.eyebrow.copyWith(color: NewColors.accent),
            ),
          ],
        ],
      ),
    );
  }
}

/// Every open task, by when it is due.
class _TaskList extends StatefulWidget {
  const _TaskList({required this.state});

  final AppState state;

  @override
  State<_TaskList> createState() => _TaskListState();
}

class _TaskListState extends State<_TaskList> with AgendaActions {
  @override
  AppState get s => widget.state;

  @override
  Widget build(BuildContext context) {
    final today = dateOnly(DateTime.now());
    final all = [
      for (final t in ws.tasks.all)
        if (t.parentId == null &&
            (!t.done ||
                (t.completedAt != null &&
                    dateOnly(t.completedAt!.toLocal()) == today)))
          t,
    ];
    int byDue(Task a, Task b) {
      final ad = a.dueDate, bd = b.dueDate;
      if (ad != null && bd != null) {
        final c = ad.compareTo(bd);
        if (c != 0) return c;
        return (a.dueMinutes ?? 0).compareTo(b.dueMinutes ?? 0);
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    }

    final overdue = [
      for (final t in all)
        if (!t.done && t.dueDate != null && t.dueDate!.isBefore(today)) t,
    ]..sort(byDue);
    final dueToday = [
      for (final t in all)
        if (t.dueDate != null && dateOnly(t.dueDate!) == today) t,
    ]..sort(byDue);
    final later = [
      for (final t in all)
        if (!t.done && t.dueDate != null && dateOnly(t.dueDate!).isAfter(today))
          t,
    ]..sort(byDue);
    final undated = [
      for (final t in all)
        if (t.dueDate == null) t,
    ]..sort(byDue);

    if (all.isEmpty) {
      return const EmptyNote(
        'No open tasks.',
        hint: 'Add one with the + below.',
      );
    }

    Widget row(Task t, {String? label}) => AgendaRow(
      key: ValueKey('task-${t.id}'),
      item: HomeItem(
        TaskOnDay(t, CalendarCategory.events.index),
        t.dueDate == null ? today : dateOnly(t.dueDate!),
      ),
      leadingLabel: label,
      onTick: () =>
          tick(HomeItem(TaskOnDay(t, CalendarCategory.events.index), today)),
      onOpen: () =>
          open(HomeItem(TaskOnDay(t, CalendarCategory.events.index), today)),
      onMenu: () =>
          menu(HomeItem(TaskOnDay(t, CalendarCategory.events.index), today)),
    );

    String short(DateTime d) =>
        '${d.day} ${monthName(d.month).substring(0, 3)}';

    Widget label(String text, int n, {Color? color}) => Padding(
      padding: const EdgeInsets.fromLTRB(
        PhoneSpace.margin,
        26,
        PhoneSpace.margin,
        6,
      ),
      child: Eyebrow(text, color: color, trailing: '$n'),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (overdue.isNotEmpty) ...[
          label('Overdue', overdue.length, color: NewColors.warm),
          for (final t in overdue) row(t, label: short(t.dueDate!)),
        ],
        if (dueToday.isNotEmpty) ...[
          label('Today', dueToday.length),
          for (final t in dueToday)
            row(
              t,
              label: t.dueMinutes == null ? null : formatClock(t.dueMinutes!),
            ),
        ],
        if (later.isNotEmpty) ...[
          label('Later', later.length),
          for (final t in later) row(t, label: short(t.dueDate!)),
        ],
        if (undated.isNotEmpty) ...[
          label('No date', undated.length),
          for (final t in undated) row(t),
        ],
      ],
    );
  }
}
