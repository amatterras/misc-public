import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/library_models.dart';
import '../../data/models/record.dart';
import '../../data/workspace.dart';
import '../../widgets/common.dart';
import 'entry_editor.dart';

/// Payload while dragging a label to another day.
class DayDrag {
  const DayDrag(this.item, this.from);
  final DayItem item;
  final DateTime from;
}

/// One Calendar page: the custom date grid plus Reading, Habits, Events and
/// Other. Every view reads the same records from [Workspace], so an edit
/// anywhere shows up everywhere.
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key, required this.state});

  final AppState state;

  static const double cellWidth = 196;
  static const double cellHeight = 156;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  /// null = the date grid; otherwise one category's view.
  CalendarCategory? _tab;
  final Set<CalendarCategory> _shown = {...CalendarCategory.values};
  bool _showTasks = true;
  Set<int>? _colors;
  DateTime? _selectedDay;
  final _viewer = TransformationController();

  AppState get s => widget.state;
  Workspace get ws => s.workspace;

  @override
  void dispose() {
    _viewer.dispose();
    super.dispose();
  }

  Future<void> _pickRange() async {
    final start = s.calendarStart;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(
        start: start,
        end: addDays(start, s.calendarDays - 1),
      ),
      helpText: 'Choose up to 38 days',
    );
    if (picked == null) return;
    var days = daysBetween(picked.start, picked.end) + 1;
    if (days > AppState.maxCalendarDays) {
      days = AppState.maxCalendarDays;
      s.showToast(
        'Limited to ${AppState.maxCalendarDays} days, starting ${formatShortDate(picked.start)}.',
      );
    }
    await s.setCalendarRange(dateOnly(picked.start), days);
  }

  Future<void> _newEntry([CalendarCategory? category, DateTime? day]) async {
    final cat = category ?? _tab;
    if (cat == null) {
      final chosen = await showMenu<CalendarCategory>(
        context: context,
        position: const RelativeRect.fromLTRB(600, 90, 300, 0),
        items: [
          for (final c in CalendarCategory.values)
            PopupMenuItem(
              value: c,
              enabled: ws.hasRoomIn(c),
              child: Text(
                '${c.label}  (${ws.activeCount(c)}/${CalendarEntry.maxActivePerCategory})',
              ),
            ),
        ],
      );
      if (chosen == null || !mounted) return;
      await showEntryEditor(
        context,
        s,
        category: chosen,
        day: day ?? _selectedDay,
      );
    } else {
      await showEntryEditor(
        context,
        s,
        category: cat,
        day: day ?? _selectedDay,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final focus = s.focusDay;
    if (focus != null) {
      _selectedDay = focus;
      _tab = null;
      s.focusDay = null;
    }
    return WorkspaceBuilder(
      state: s,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.xl, Space.xl, Space.xl, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            ..._overLimitWarning(),
            const SizedBox(height: Space.lg),
            _tabs(),
            const SizedBox(height: Space.md),
            Expanded(
              child: _tab == null
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _grid()),
                        if (_selectedDay != null) ...[
                          const SizedBox(width: Space.md),
                          SizedBox(
                            width: 340,
                            child: DayPanel(
                              key: ValueKey(dayKey(_selectedDay!)),
                              state: s,
                              day: _selectedDay!,
                              onClose: () =>
                                  setState(() => _selectedDay = null),
                              onNewEntry: (c) => _newEntry(c, _selectedDay),
                            ),
                          ),
                        ],
                      ],
                    )
                  : CategoryView(
                      state: s,
                      category: _tab!,
                      onNew: () => _newEntry(_tab),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shown when a sync merged entries from several devices and a category
  /// now has more active entries than allowed. Nothing is archived
  /// automatically: the user decides which ones to archive.
  List<Widget> _overLimitWarning() {
    final over = ws.overLimitCategories;
    if (over.isEmpty) return const [];
    const max = CalendarEntry.maxActivePerCategory;
    final which = [
      for (final c in over) '${c.label} (${ws.activeCount(c)} active)',
    ].join(', ');
    return [
      const SizedBox(height: Space.md),
      Container(
        key: const ValueKey('over-limit-warning'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: OrganizerColors.amber.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: OrganizerColors.amber.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              size: 18,
              color: OrganizerColors.amber,
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                'More than $max active entries in $which after syncing '
                'another device. Nothing was archived; archive entries until '
                'each category has $max again. New entries there are paused '
                'until then.',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _header() {
    final start = s.calendarStart;
    final end = addDays(start, s.calendarDays - 1);
    final archived = ws.entries.all.where((e) => e.archived).length;
    // Wraps onto two lines in narrower windows instead of overflowing.
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: Space.md,
      runSpacing: Space.sm,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(
                Icons.calendar_today_outlined,
                size: 18,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(width: Space.md),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Calendar',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  InkWell(
                    onTap: _pickRange,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '${formatShortDate(start)} – ${formatShortDate(end)} ${end.year}  ·  ${s.calendarDays} days',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.edit_calendar_outlined,
                          size: 14,
                          color: AppColors.textFaint,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _colorFilter(),
            FilledButton.icon(
              onPressed: () => _newEntry(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Quick Add'),
            ),
            OutlinedButton.icon(
              onPressed: () => showArchive(context, s),
              icon: const Icon(Icons.inventory_2_outlined, size: 16),
              label: Text('Archive  $archived'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _colorFilter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'All colours',
            child: InkWell(
              onTap: () => setState(() => _colors = null),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(
                  _colors == null
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ),
          for (var i = 0; i < 10; i++)
            InkWell(
              onTap: () => setState(() {
                final set = {...?_colors};
                if (!set.remove(i)) set.add(i);
                _colors = set.isEmpty ? null : set;
              }),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: organizerColor(i).withValues(
                      alpha: _colors == null || _colors!.contains(i) ? 1 : 0.25,
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _colors?.contains(i) ?? false
                          ? AppColors.text
                          : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tabs() {
    Widget tab(
      String label,
      bool active,
      VoidCallback onTap, {
      IconData? icon,
      String? count,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Material(
          color: active ? AppColors.text : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 15,
                      color: active
                          ? AppColors.background
                          : AppColors.textMuted,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: active
                          ? AppColors.background
                          : AppColors.textMuted,
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.background.withValues(alpha: 0.15)
                            : AppColors.cardRaised,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        count,
                        style: TextStyle(
                          fontSize: 11,
                          color: active
                              ? AppColors.background
                              : AppColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: Space.sm,
      children: [
        // Scrolls sideways when the window is too narrow for all tabs.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                tab(
                  '${s.calendarDays}-Day Grid',
                  _tab == null,
                  () => setState(() => _tab = null),
                  icon: Icons.grid_on,
                ),
                for (final c in CalendarCategory.values)
                  tab(
                    c.label,
                    _tab == c,
                    () => setState(() => _tab = c),
                    count:
                        '${ws.activeCount(c)}/${CalendarEntry.maxActivePerCategory}',
                  ),
              ],
            ),
          ),
        ),
        if (_tab == null)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              const Text(
                'Show',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint),
              ),
              const SizedBox(width: 6),
              for (final c in CalendarCategory.values)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: FilterChip(
                    label: Text(c.label, style: const TextStyle(fontSize: 12)),
                    selected: _shown.contains(c),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (on) =>
                        setState(() => on ? _shown.add(c) : _shown.remove(c)),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: FilterChip(
                  label: const Text('Tasks', style: TextStyle(fontSize: 12)),
                  selected: _showTasks,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: (on) => setState(() => _showTasks = on),
                ),
              ),
              const SizedBox(width: Space.sm),
              GhostIconButton(
                icon: Icons.fit_screen_outlined,
                tooltip: 'Reset zoom',
                onTap: () => _viewer.value = Matrix4.identity(),
              ),
            ],
          ),
      ],
    );
  }

  Widget _grid() {
    final start = s.calendarStart;
    final days = s.calendarDays;
    final rows = (days / 7).ceil();
    const w = CalendarPage.cellWidth, h = CalendarPage.cellHeight;
    final today = dateOnly(DateTime.now());
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: AppColors.canvas,
        child: InteractiveViewer(
          transformationController: _viewer,
          constrained: false,
          minScale: 0.35,
          maxScale: 2.5,
          boundaryMargin: const EdgeInsets.all(600),
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: SizedBox(
              width: w * 7,
              height: h * rows,
              child: Stack(
                children: [
                  for (var i = 0; i < days; i++)
                    Positioned(
                      left: (i % 7) * w,
                      top: (i ~/ 7) * h,
                      width: w,
                      height: h,
                      child: DayCell(
                        state: s,
                        day: addDays(start, i),
                        isToday: daysBetween(today, addDays(start, i)) == 0,
                        selected:
                            _selectedDay != null &&
                            daysBetween(_selectedDay!, addDays(start, i)) == 0,
                        items: ws.itemsOn(
                          addDays(start, i),
                          categories: _shown,
                          colors: _colors,
                          includeTasks: _showTasks,
                        ),
                        onTap: () =>
                            setState(() => _selectedDay = addDays(start, i)),
                        onEditItem: (item) =>
                            _editItem(item, addDays(start, i)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editItem(DayItem item, DateTime day) async {
    switch (item) {
      case EntryOnDay(:final entry):
        await showEntryEditor(context, s, entry: entry);
      case TaskOnDay(:final task):
        s.openTask(task.id);
    }
  }
}

/// One square of the date grid.
class DayCell extends StatelessWidget {
  const DayCell({
    super.key,
    required this.state,
    required this.day,
    required this.isToday,
    required this.selected,
    required this.items,
    required this.onTap,
    required this.onEditItem,
  });

  final AppState state;
  final DateTime day;
  final bool isToday;
  final bool selected;
  final List<DayItem> items;
  final VoidCallback onTap;
  final ValueChanged<DayItem> onEditItem;

  static const maxLabels = 5;

  @override
  Widget build(BuildContext context) {
    final ws = state.workspace;
    final record = ws.days[dayKey(day)];
    return DragTarget<DayDrag>(
      onWillAcceptWithDetails: (d) => daysBetween(d.data.from, day) != 0,
      onAcceptWithDetails: (d) => ws.moveDayItem(d.data.item, d.data.from, day),
      builder: (context, candidates, _) {
        return Material(
          color: candidates.isNotEmpty
              ? const Color(0xFF1F2A36)
              : isToday
              ? const Color(0xFF1C1D26)
              : AppColors.card,
          child: InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: selected ? AppColors.accent : AppColors.background,
                  width: selected ? 1.5 : 1,
                ),
              ),
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${day.day}',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: isToday ? AppColors.accent : AppColors.text,
                        ),
                      ),
                      if (day.day == 1) ...[
                        const SizedBox(width: 4),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            formatShortDate(day).split(' ').first,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (record != null && record.text.trim().isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.only(right: 4, top: 2),
                          child: Icon(
                            Icons.sticky_note_2_outlined,
                            size: 12,
                            color: AppColors.textFaint,
                          ),
                        ),
                      if (record != null && record.assetIds.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.only(right: 4, top: 2),
                          child: Icon(
                            Icons.attach_file,
                            size: 12,
                            color: AppColors.textFaint,
                          ),
                        ),
                      Text(
                        weekdayShort(day).toUpperCase(),
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.textFaint,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  if (record != null && record.text.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        record.text.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  const Spacer(),
                  for (final item in items.take(maxLabels))
                    DayLabel(
                      state: state,
                      item: item,
                      day: day,
                      onTap: () => onEditItem(item),
                    ),
                  if (items.length > maxLabels)
                    Text(
                      '+${items.length - maxLabels} more',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textFaint,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A small coloured label for one entry or task on one day.
class DayLabel extends StatelessWidget {
  const DayLabel({
    super.key,
    required this.state,
    required this.item,
    required this.day,
    required this.onTap,
  });

  final AppState state;
  final DayItem item;
  final DateTime day;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    final color = organizerColor(item.colorIndex);
    final isHabit =
        item is EntryOnDay && item.entry.category == CalendarCategory.habits;
    final checked = isHabit && item.entry.isCheckedOn(day);
    final time = switch (item) {
      EntryOnDay(:final entry) => entry.timeLabel,
      TaskOnDay(:final task) =>
        task.dueMinutes == null
            ? null
            : '${(task.dueMinutes! ~/ 60).toString().padLeft(2, '0')}:${(task.dueMinutes! % 60).toString().padLeft(2, '0')}',
    };
    final label = Container(
      height: 18,
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          if (isHabit)
            InkWell(
              onTap: () => state.workspace.toggleHabit(item.entry.id, day),
              child: Icon(
                checked ? Icons.check_box : Icons.check_box_outline_blank,
                size: 12,
                color: color,
              ),
            )
          else if (item is TaskOnDay)
            InkWell(
              onTap: () => state.workspace.toggleTask(item.task.id),
              child: Icon(
                Icons.check_box_outline_blank,
                size: 12,
                color: color,
              ),
            )
          else
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 4),
          if (time != null) ...[
            Text(
              time,
              style: const TextStyle(fontSize: 9, color: AppColors.textMuted),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                color: checked ? AppColors.textFaint : AppColors.text,
                decoration: checked ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
    final tappable = GestureDetector(
      onTap: onTap,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: label),
    );
    if (isHabit) return tappable; // Recurring: change its schedule instead.
    return Draggable<DayDrag>(
      data: DayDrag(item, day),
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: CalendarPage.cellWidth - 18,
          child: Opacity(opacity: 0.9, child: label),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: label),
      child: tappable,
    );
  }
}

/// Details of one day: its entries and tasks, a note and attachments.
class DayPanel extends StatefulWidget {
  const DayPanel({
    super.key,
    required this.state,
    required this.day,
    required this.onClose,
    required this.onNewEntry,
  });

  final AppState state;
  final DateTime day;
  final VoidCallback onClose;
  final ValueChanged<CalendarCategory> onNewEntry;

  @override
  State<DayPanel> createState() => _DayPanelState();
}

class _DayPanelState extends State<DayPanel> {
  late final _text = TextEditingController(
    text: widget.state.workspace.dayRecord(widget.day).text,
  );

  AppState get s => widget.state;
  Workspace get ws => s.workspace;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _attach(Iterable<Asset> assets) {
    for (final a in assets) {
      ws.attachToDay(widget.day, a.id);
    }
  }

  Future<void> _paste() async {
    final clip = await s.capture.readClipboard();
    if (clip.imageBytes != null) {
      _attach([
        await s.capture.imageFromBytes(clip.imageBytes!, clip.imageExtension),
      ]);
    } else if (clip.imageFiles.isNotEmpty) {
      _attach(await s.capture.imagesFromFiles(clip.imageFiles));
    } else if (clip.url != null) {
      _attach([s.capture.link(clip.url!)]);
    } else {
      s.showToast('No link or image on the clipboard.');
    }
  }

  Future<void> _logReading(CalendarEntry entry) async {
    final input = await promptText(
      context,
      title: 'Pages read on ${formatShortDate(widget.day)}',
      hint: 'e.g. 25',
      action: 'Log',
    );
    final pages = int.tryParse(input ?? '');
    if (pages == null || pages <= 0) return;
    final key = dayKey(widget.day);
    ws.entries.put(
      entry.copyWith(
        readingLog: {
          ...entry.readingLog,
          key: (entry.readingLog[key] ?? 0) + pages,
        },
        currentPage: entry.currentPage + pages,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final day = widget.day;
    final items = ws.itemsOn(day);
    final record = ws.dayRecord(day);
    syncText(this, _text, record.text);
    final reading = ws.entries.all
        .where((e) => e.category == CalendarCategory.reading && !e.archived)
        .toList();
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: ListView(
        padding: const EdgeInsets.all(Space.lg),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  formatLongDate(day),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              GhostIconButton(
                icon: Icons.close,
                tooltip: 'Close',
                onTap: widget.onClose,
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          if (items.isEmpty)
            const Text(
              'Nothing on this day.',
              style: TextStyle(fontSize: 13, color: AppColors.textFaint),
            ),
          for (final item in items) _itemRow(item),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in CalendarCategory.values)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 14),
                  label: Text(c.label, style: const TextStyle(fontSize: 12)),
                  tooltip: ws.hasRoomIn(c)
                      ? 'New ${c.label} entry on this day'
                      : '${c.label} is full (5 active)',
                  onPressed: ws.hasRoomIn(c)
                      ? () => widget.onNewEntry(c)
                      : null,
                ),
            ],
          ),
          if (reading.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in reading)
                  ActionChip(
                    avatar: const Icon(Icons.menu_book_outlined, size: 14),
                    label: Text(
                      'Log pages: ${r.name}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () => _logReading(r),
                  ),
              ],
            ),
          ],
          const SizedBox(height: Space.xl),
          const Text(
            'DAY NOTE',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.6,
              color: AppColors.textFaint,
            ),
          ),
          const SizedBox(height: Space.sm),
          TextField(
            controller: _text,
            minLines: 3,
            maxLines: 10,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'Anything about this day…',
            ),
            onChanged: (v) => ws.saveDay(ws.dayRecord(day).copyWith(text: v)),
          ),
          const SizedBox(height: Space.lg),
          Row(
            children: [
              const Text(
                'ATTACHED',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.6,
                  color: AppColors.textFaint,
                ),
              ),
              const Spacer(),
              GhostIconButton(
                icon: Icons.content_paste,
                tooltip: 'Paste link or image',
                size: 16,
                onTap: _paste,
              ),
              GhostIconButton(
                icon: Icons.add_link,
                tooltip: 'Attach link',
                size: 16,
                onTap: () async {
                  final input = await promptText(
                    context,
                    title: 'Attach link',
                    hint: 'https://…',
                    action: 'Attach',
                  );
                  final url = input == null ? null : extractUrl(input);
                  if (url != null) _attach([s.capture.link(url)]);
                },
              ),
              GhostIconButton(
                icon: Icons.add_photo_alternate_outlined,
                tooltip: 'Attach photos',
                size: 16,
                onTap: () async => _attach(await s.capture.pickImages()),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in assetsFor(s, record.assetIds))
                AssetChip(
                  workspace: ws,
                  asset: a,
                  onRemove: () => ws.saveDay(
                    record.copyWith(
                      assetIds: [...record.assetIds]..remove(a.id),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _itemRow(DayItem item) {
    final color = organizerColor(item.colorIndex);
    final day = widget.day;
    switch (item) {
      case EntryOnDay(:final entry):
        final isHabit = entry.category == CalendarCategory.habits;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: isHabit
              ? Checkbox(
                  value: entry.isCheckedOn(day),
                  activeColor: color,
                  onChanged: (_) => ws.toggleHabit(entry.id, day),
                )
              : Padding(
                  padding: const EdgeInsets.all(8),
                  child: ColorDot(index: entry.colorIndex),
                ),
          title: Text(entry.name),
          subtitle: Text(
            [
              entry.category.label,
              ?entry.timeLabel,
              if (entry.description.isNotEmpty) entry.description,
            ].join(' · '),
            style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
          ),
          trailing: GhostIconButton(
            icon: Icons.edit_outlined,
            tooltip: 'Edit',
            size: 16,
            onTap: () => showEntryEditor(context, s, entry: entry),
          ),
        );
      case TaskOnDay(:final task):
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Checkbox(
            value: task.done,
            activeColor: color,
            onChanged: (_) => ws.toggleTask(task.id),
          ),
          title: Text(item.label),
          subtitle: const Text(
            'Task (from Tasks)',
            style: TextStyle(fontSize: 11, color: AppColors.textFaint),
          ),
          trailing: GhostIconButton(
            icon: Icons.open_in_new,
            tooltip: 'Open in Tasks',
            size: 16,
            onTap: () => s.openTask(task.id),
          ),
        );
    }
  }
}

/// All active entries of one category, with their category-specific details.
class CategoryView extends StatelessWidget {
  const CategoryView({
    super.key,
    required this.state,
    required this.category,
    required this.onNew,
  });

  final AppState state;
  final CalendarCategory category;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final ws = state.workspace;
    final entries =
        ws.entries.all
            .where((e) => e.category == category && !e.archived)
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final full = !ws.hasRoomIn(category);
    return ListView(
      children: [
        Row(
          children: [
            Text(
              '${entries.length} of ${CalendarEntry.maxActivePerCategory} active',
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
            const Spacer(),
            if (full)
              const Padding(
                padding: EdgeInsets.only(right: Space.md),
                child: Text(
                  'Full — archive an entry to add another.',
                  style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              ),
            FilledButton.icon(
              onPressed: full ? null : onNew,
              icon: const Icon(Icons.add, size: 16),
              label: Text('New ${category.label} entry'),
            ),
          ],
        ),
        if (entries.length > CalendarEntry.maxActivePerCategory)
          Container(
            margin: const EdgeInsets.only(top: Space.md),
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(
              color: OrganizerColors.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: OrganizerColors.amber.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              '${category.label} has ${entries.length} active entries (the limit is '
              '${CalendarEntry.maxActivePerCategory}) because changes from several '
              'devices were combined. Nothing was archived automatically — please '
              'archive ${entries.length - CalendarEntry.maxActivePerCategory}.',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        const SizedBox(height: Space.lg),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(Space.xl),
            child: Text(
              'Nothing here yet.',
              style: TextStyle(color: AppColors.textFaint),
            ),
          ),
        Wrap(
          spacing: Space.lg,
          runSpacing: Space.lg,
          children: [
            for (final e in entries)
              SizedBox(
                width: 360,
                child: EntryCard(state: state, entry: e),
              ),
          ],
        ),
      ],
    );
  }
}

class EntryCard extends StatelessWidget {
  const EntryCard({super.key, required this.state, required this.entry});

  final AppState state;
  final CalendarEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final ws = state.workspace;
    final color = organizerColor(e.colorIndex);
    final details = <Widget>[];
    switch (e.category) {
      case CalendarCategory.reading:
        final total = e.totalPages;
        final progress = total == null || total == 0
            ? null
            : (e.currentPage / total).clamp(0.0, 1.0);
        details.addAll([
          if (e.author.isNotEmpty)
            Text(
              e.author,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          const SizedBox(height: 8),
          if (progress != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                color: color,
                backgroundColor: AppColors.cardRaised,
                minHeight: 5,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            total == null
                ? 'Page ${e.currentPage}'
                : 'Page ${e.currentPage} of $total',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          Text(
            '${e.readingLog.length} reading days logged',
            style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
          ),
        ]);
      case CalendarCategory.habits:
        final start = state.calendarStart;
        final rangeDays = [
          for (var i = 0; i < state.calendarDays; i++) addDays(start, i),
        ];
        final scheduled = rangeDays.where(e.occursOn).toList();
        final today = dateOnly(DateTime.now());
        details.addAll([
          Text(
            e.weekdays.isEmpty
                ? 'Every day'
                : [
                    for (var d = 1; d <= 7; d++)
                      if (e.weekdays.contains(d)) weekdayLetters[d - 1],
                  ].join(' '),
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 3,
            runSpacing: 3,
            children: [
              for (final d in scheduled)
                Tooltip(
                  message: formatLongDate(d),
                  child: InkWell(
                    onTap: () => ws.toggleHabit(e.id, d),
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: e.isCheckedOn(d) ? color : AppColors.cardRaised,
                        borderRadius: BorderRadius.circular(3),
                        border: daysBetween(today, d) == 0
                            ? Border.all(color: AppColors.text)
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Click a square to check a day off.',
            style: TextStyle(fontSize: 11, color: AppColors.textFaint),
          ),
        ]);
      case CalendarCategory.events:
        final start = e.startDate, end = e.endDate ?? e.startDate;
        details.add(
          Text(
            start == null
                ? 'No date'
                : [
                    end == null || daysBetween(start, end) == 0
                        ? formatLongDate(start)
                        : '${formatShortDate(start)} – ${formatShortDate(end)} (${daysBetween(start, end) + 1} days)',
                    ?e.timeLabel,
                    if (e.durationMinutes != null) '${e.durationMinutes} min',
                  ].join('  ·  '),
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        );
      case CalendarCategory.other:
        final dates = e.dates.toList()..sort();
        details.add(
          Text(
            dates.isEmpty
                ? 'No dates'
                : dates.map((k) => formatShortDate(parseDayKey(k))).join(', '),
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: _body(context, e, ws, details),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    CalendarEntry e,
    Workspace ws,
    List<Widget> details,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                e.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            GhostIconButton(
              icon: Icons.edit_outlined,
              tooltip: 'Edit',
              size: 16,
              onTap: () => showEntryEditor(context, state, entry: e),
            ),
            GhostIconButton(
              icon: Icons.inventory_2_outlined,
              tooltip: 'Archive',
              size: 16,
              onTap: () => ws.setArchived(e.id, true),
            ),
          ],
        ),
        if (e.description.isNotEmpty)
          Text(
            e.description,
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
        const SizedBox(height: 6),
        ...details,
        if (e.notes.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            e.notes.trim(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
          ),
        ],
        if (e.assetIds.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in assetsFor(state, e.assetIds))
                AssetChip(workspace: ws, asset: a),
            ],
          ),
        ],
      ],
    );
  }
}

Future<void> showArchive(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: state.workspace.entries,
      builder: (context, _) {
        final ws = state.workspace;
        final archived = ws.entries.all.where((e) => e.archived).toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return AlertDialog(
          title: const Text('Archive', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 480,
            height: 380,
            child: archived.isEmpty
                ? const Center(
                    child: Text(
                      'Archived entries appear here.',
                      style: TextStyle(color: AppColors.textFaint),
                    ),
                  )
                : ListView(
                    children: [
                      for (final e in archived)
                        ListTile(
                          leading: ColorDot(index: e.colorIndex),
                          title: Text(e.name),
                          subtitle: Text(
                            e.category.label,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textFaint,
                            ),
                          ),
                          trailing: TextButton(
                            onPressed: ws.hasRoomIn(e.category)
                                ? () => ws.setArchived(e.id, false)
                                : null,
                            child: Text(
                              ws.hasRoomIn(e.category)
                                  ? 'Restore'
                                  : '${e.category.label} full',
                            ),
                          ),
                          onTap: () =>
                              showEntryEditor(context, state, entry: e),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
}
