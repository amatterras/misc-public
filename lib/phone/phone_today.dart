// Today: the first screen of the iPhone interface. The date is the headline,
// a week of numerals sits under it, and the day follows as a printed
// schedule. Everything shown is the existing Calendar and Tasks data.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/quote_footer.dart';
import '../data/models/record.dart';
import '../features/motivation/motivation_service.dart';
import '../new_ui/home_agenda.dart';
import '../app/theme.dart';
import '../widgets/date_prefs.dart';
import 'phone_agenda.dart';
import 'phone_capture.dart' show PhoneDay;
import 'phone_more.dart';
import 'phone_tokens.dart';
import 'phone_widgets.dart';

class PhoneToday extends StatefulWidget {
  const PhoneToday({super.key, required this.state, required this.motivation});

  final AppState state;
  final MotivationService motivation;

  @override
  State<PhoneToday> createState() => _PhoneTodayState();
}

class _PhoneTodayState extends State<PhoneToday> {
  static const _basePage = 1000;

  late DateTime _selected = dateOnly(DateTime.now());
  late final DateTime _anchorWeek = DatePrefs.weekStart(DateTime.now());
  late final PageController _pages = PageController(initialPage: _basePage);
  bool _jumping = false;

  AppState get s => widget.state;

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
    PhoneDay.selected = d;
    setState(() => _selected = d);
    final page = _pageOf(d);
    if (_pages.hasClients && _pages.page?.round() != page) {
      _jumping = true;
      _pages.jumpToPage(page);
      _jumping = false;
    }
  }

  /// Swiping the strip moves to the same weekday of that week.
  void _weekSwiped(int page) {
    if (_jumping) return;
    final offset = daysBetween(DatePrefs.weekStart(_selected), _selected);
    final d = addDays(_weekOf(page), offset);
    PhoneDay.selected = d;
    setState(() => _selected = d);
  }

  String _relative(DateTime day) {
    final diff = daysBetween(dateOnly(DateTime.now()), day);
    return switch (diff) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      > 1 => 'In $diff days',
      _ => '${-diff} days ago',
    };
  }

  String _headline(DateTime d) => DatePrefs.order == DateOrder.dayMonth
      ? '${d.day} ${monthName(d.month)}'
      : '${monthName(d.month)} ${d.day}';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.workspace.changes, widget.motivation]),
      builder: (context, _) {
        final agenda = HomeAgenda.build(s.workspace, _selected);
        final isToday = daysBetween(dateOnly(DateTime.now()), _selected) == 0;
        return RefreshIndicator(
          color: AppColors.accent,
          backgroundColor: AppColors.card,
          edgeOffset: MediaQuery.paddingOf(context).top,
          onRefresh: () async {
            if (s.syncPaired) await s.syncNow();
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: PhoneHeader(
                  eyebrow:
                      '${weekdayName(_selected.weekday)} · ${_relative(_selected)}',
                  title: _headline(_selected),
                  actions: [
                    PhoneMoreButtons(state: s, tab: PhoneTabKind.today),
                  ],
                ),
              ),
              SliverToBoxAdapter(child: _weekStrip()),
              SliverToBoxAdapter(child: _summary(agenda, isToday)),
              SliverToBoxAdapter(
                child: PhoneAgenda(
                  state: s,
                  day: _selected,
                  emptyHeadline: isToday ? 'A clear day.' : 'Nothing planned.',
                  emptyHint: 'Add something with the + below.',
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 28, bottom: 10),
                  child: QuoteFooter(service: widget.motivation),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _weekStrip() => SizedBox(
    height: 78,
    child: PageView.builder(
      key: const ValueKey('phone-week'),
      controller: _pages,
      onPageChanged: _weekSwiped,
      itemBuilder: (context, page) {
        final start = _weekOf(page);
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PhoneSpace.margin - 6,
          ),
          child: Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(child: _dayCell(addDays(start, i))),
            ],
          ),
        );
      },
    ),
  );

  Widget _dayCell(DateTime day) {
    final selected = day == _selected;
    final today = daysBetween(dateOnly(DateTime.now()), day) == 0;
    final markers = HomeAgenda.markers(s.workspace, day, max: 3);
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return Press(
      onTap: () {
        HapticFeedback.selectionClick();
        _select(day);
      },
      child: Semantics(
        selected: selected,
        label: '${weekdayName(day.weekday)} ${day.day}',
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              letters[day.weekday - 1],
              style: PhoneType.eyebrow.copyWith(
                fontSize: AppType.sizeMeta,
                color: selected ? AppColors.text : AppColors.textFaint,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              '${day.day}',
              style: PhoneType.numeral.copyWith(
                fontSize: 19,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: today
                    ? AppColors.accent
                    : selected
                    ? AppColors.text
                    : AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 7),
            SizedBox(
              height: 4,
              child: selected
                  ? Container(width: 18, height: 2.5, color: AppColors.text)
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final c in markers)
                          Container(
                            width: 4,
                            height: 4,
                            margin: const EdgeInsets.symmetric(horizontal: 1.5),
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

  Widget _summary(HomeAgenda a, bool isToday) {
    final all = a.completed + a.remaining;
    final text = all == 0
        ? null
        : a.remaining == 0
        ? 'All ${a.completed} done'
        : '${a.remaining} to go · ${a.completed} done';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PhoneSpace.margin,
        14,
        PhoneSpace.margin,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  text ?? '',
                  style: PhoneType.time.copyWith(fontSize: AppType.sizeBody),
                ),
              ),
              if (!isToday)
                Press(
                  onTap: () => _select(DateTime.now()),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      'Back to today',
                      style: TextStyle(
                        fontSize: AppType.sizeBody,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (all > 0) ...[
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, c) => Stack(
                children: [
                  Container(height: 2, color: AppColors.border),
                  AnimatedContainer(
                    duration: AppMotion.page,
                    curve: AppMotion.standard,
                    height: 2,
                    width: c.maxWidth * a.progress,
                    decoration: BoxDecoration(gradient: AppGradients.brand),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
