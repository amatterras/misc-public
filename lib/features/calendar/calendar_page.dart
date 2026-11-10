import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/shell.dart';
import '../../new_ui/new_components.dart';
import '../../app/theme.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/canvas_models.dart' show StrokeItem, newId;
import '../../data/models/library_models.dart';
import '../../data/models/record.dart';
import '../../data/workspace.dart';
import '../../platform/input_hints.dart';
import '../../platform/platform.dart' as native;
import '../../widgets/common.dart';
import '../tasks/estimate_label.dart';
import '../tasks/tasks_page.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_toolbar.dart' show EraserPanel;
import '../notes/note_page.dart'
    show InkColorButton, InkWidthButton, ZoomStepper;
import '../transfer/transfer.dart';
import 'calendar_ink.dart';
import 'calendar_views.dart';
import 'entry_editor.dart';
import 'reading_goal.dart';
import 'calendar_handwriting.dart';

/// One Calendar page: the custom date grid plus Reading, Habits, Events and
/// Other. Every view reads the same records from [Workspace], so an edit
/// anywhere shows up everywhere.
class CalendarPage extends StatefulWidget {
  const CalendarPage({
    super.key,
    required this.state,
    this.viewKey = 'calendarView',
  });

  final AppState state;

  /// Setting that remembers the chosen view: each Calendar window has its
  /// own, over the same calendar records.
  final String viewKey;

  /// The existing rendered cell baseline was 196×312 logical pixels. Keep
  /// both axes at exactly 2×; InteractiveViewer provides pan/zoom on narrow
  /// Windows, iPad and iPhone viewports instead of shrinking hit targets.
  static const double cellWidth = 392;
  static const double cellHeight = 624;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  /// null = the date grid; otherwise one category's view.
  CalendarCategory? _tab;

  /// What the views show: the one source of truth for category
  /// visibility (the Filter menu). Tasks are their own switch: task cards
  /// on days, not the Tasks panel ([AppState.calendarTasksOpen]).
  final Set<CalendarCategory> _shown = {...CalendarCategory.values};
  bool _showTasks = true;
  DateTime? _selectedDay;
  final _viewer = TransformationController();

  /// Month and week zoom (the range grid has its own, above), and the
  /// size of the area each is shown in (zoom steps centre on it).
  final _monthViewer = TransformationController();
  Size _rangeViewport = Size.zero;
  Size _monthViewport = Size.zero;

  /// Month/week/day/agenda/timeline: the date they show.
  DateTime _anchor = dateOnly(DateTime.now());

  /// Which view (remembered on this device; the 38-day range by default).
  CalendarView get _view =>
      CalendarView.values.asNameMap()[s.settings.get<String>(widget.viewKey)] ??
      CalendarView.range;

  void _setView(CalendarView v) {
    s.settings.set(widget.viewKey, v.name);
    _monthViewer.value = Matrix4.identity();
    _ink?.endEditing();
    setState(() {});
  }

  List<DayItem> _itemsOn(DateTime day) =>
      ws.itemsOn(day, categories: _shown, includeTasks: _showTasks);

  AppState get s => widget.state;
  Workspace get ws => s.workspace;

  /// Draw mode: pointer input on days draws instead of selecting.
  bool _drawing = false;

  /// Ink input on only for a held Pencil squeeze (the eraser): unlike
  /// [_drawing], it changes nothing in the toolbar. Showing the Draw tools
  /// for a squeeze made the toolbar wrap onto a second line, which moved
  /// the whole Calendar down and back up again.
  bool _squeezeInk = false;

  /// Ink input of either kind.
  bool get _inkInput => _drawing || _squeezeInk;

  CanvasController? _ink;

  /// Draw or navigate, per pointer (see CalendarInkArbiter).
  CalendarInkArbiter? _arbiter;
  void Function()? _unregisterTap;

  @override
  void initState() {
    super.initState();
    s.openCalendarInk().then((c) {
      if (!mounted) return;
      // A day is a small square: its text boxes start small and take the
      // pen colour.
      c
        ..newTextWidth = 150
        ..newTextFontSize = 9
        ..newTextUsesPenColor = true;
      setState(() {
        _ink = c;
        _arbiter = CalendarInkArbiter(c)..addListener(_navigationChanged);
      });
      // Apple Pencil double-tap: Undo, as the Undo button, in Draw mode.
      _unregisterTap = s.pencilDoubleTap.register(
        c,
        active: () =>
            mounted && _drawing && _tab == null && s.page == AppPage.calendar,
      );
      _startSqueeze(c);
    });
  }

  // Apple Pencil Pro squeeze: erase while squeezed (iPhone/iPad only).
  CalendarSqueeze? _squeezer;
  StreamSubscription<String>? _squeeze;
  AppLifecycleListener? _lifecycle;

  void _startSqueeze(CanvasController ink) {
    final ios = s.ios;
    if (ios == null) return;
    _squeezer = CalendarSqueeze(
      ink,
      visible: () =>
          mounted &&
          s.page == AppPage.calendar &&
          _tab == null &&
          (ModalRoute.of(context)?.isCurrent ?? true),
      drawing: () => _squeezeInk,
      setDrawing: (on) {
        if (mounted && _squeezeInk != on) setState(() => _squeezeInk = on);
      },
    );
    _squeeze = ios.pencilSqueeze.listen(_squeezer!.phase);
    unawaited(ios.enablePencilSqueeze());
    _lifecycle = AppLifecycleListener(onInactive: () => _squeezer?.end());
    s.addListener(_endSqueezeOffPage);
  }

  /// Two fingers down or up: pinch and pan switch on or off.
  void _navigationChanged() {
    if (mounted) setState(() {});
  }

  void _endSqueezeOffPage() {
    if (s.page != AppPage.calendar) _squeezer?.end();
  }

  Widget _inkOn(DateTime day) {
    final ink = _ink;
    if (ink == null) return const SizedBox.shrink();
    return DayInkLayer(
      key: ValueKey('ink-${dayKey(day)}'),
      controller: ink,
      day: day,
      drawing: _inkInput,
      arbiter: _arbiter,
    );
  }

  @override
  void dispose() {
    _squeezer?.end();
    _squeeze?.cancel();
    _arbiter?.removeListener(_navigationChanged);
    _unregisterTap?.call();
    _lifecycle?.dispose();
    s.removeListener(_endSqueezeOffPage);
    _viewer.dispose();
    _monthViewer.dispose();
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

  Future<void> _recognizeHandwriting(DateTime day) async {
    final ink = _ink;
    if (ink == null) return;
    try {
      final recognized = await recognizeCalendarInk(
        controller: ink,
        day: day,
        ios: s.ios,
      );
      if (!mounted) return;
      if (recognized == null) {
        s.showToast(
          'Calendar handwriting OCR is available on Windows and iPad.',
        );
        return;
      }
      if (recognized.trim().isEmpty) {
        s.showToast('No readable handwriting was found on this day.');
        return;
      }

      final suggestion = suggestCalendarEvent(recognized, day);
      final title = TextEditingController(text: suggestion.title);
      final date = TextEditingController(text: dayKey(suggestion.day));
      final time = TextEditingController(
        text: suggestion.startMinutes == null
            ? ''
            : '${(suggestion.startMinutes! ~/ 60).toString().padLeft(2, '0')}:${(suggestion.startMinutes! % 60).toString().padLeft(2, '0')}',
      );
      final duration = TextEditingController(
        text: suggestion.durationMinutes?.toString() ?? '',
      );
      final notes = TextEditingController(text: suggestion.notes);
      try {
        final approved = await showAppDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Review handwriting'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      suggestion.dateWarning ??
                          (suggestion.dateRecognized
                              ? 'Check the detected title, date, and time before creating the event.'
                              : 'No date was confidently detected. The selected calendar day is filled in; change it if needed.'),
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: AppSpace.md),
                    TextField(
                      key: const ValueKey('handwriting-event-title'),
                      controller: title,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Event title',
                      ),
                    ),
                    TextField(
                      key: const ValueKey('handwriting-event-date'),
                      controller: date,
                      decoration: const InputDecoration(
                        labelText: 'Date (YYYY-MM-DD)',
                      ),
                    ),
                    TextField(
                      key: const ValueKey('handwriting-event-time'),
                      controller: time,
                      decoration: const InputDecoration(
                        labelText: 'Start time (HH:MM, optional)',
                      ),
                    ),
                    TextField(
                      key: const ValueKey('handwriting-event-duration'),
                      controller: duration,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Duration in minutes (optional)',
                      ),
                    ),
                    TextField(
                      key: const ValueKey('handwriting-event-notes'),
                      controller: notes,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                    const Text('Recognized handwriting'),
                    const SizedBox(height: AppSpace.xs),
                    SelectableText(
                      recognized.trim(),
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: AppType.sizeLabel,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                key: const ValueKey('confirm-handwriting-event'),
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.event_available, size: 16),
                label: const Text('Create event'),
              ),
            ],
          ),
        );
        if (approved != true || !mounted) return;
        final eventTitle = title.text.trim();
        final dateText = date.text.trim();
        final parsedDay = DateTime.tryParse(dateText);
        final parsedTime = time.text.trim().isEmpty
            ? null
            : parseCalendarHandwritingTime(time.text);
        final durationText = duration.text.trim();
        final parsedDuration = durationText.isEmpty
            ? null
            : int.tryParse(durationText);
        if (eventTitle.isEmpty ||
            parsedDay == null ||
            (time.text.trim().isNotEmpty && parsedTime == null) ||
            (durationText.isNotEmpty &&
                (parsedDuration == null ||
                    parsedDuration < 1 ||
                    parsedDuration > 24 * 60)) ||
            (parsedDuration != null && parsedTime == null)) {
          s.showToast(
            'Enter a title, valid date and time, and a duration from 1 to 1440 minutes.',
          );
          return;
        }
        final localDay = DateTime(
          parsedDay.year,
          parsedDay.month,
          parsedDay.day,
        );
        if (dayKey(localDay) != dateText) {
          s.showToast('Enter the date as YYYY-MM-DD.');
          return;
        }
        final now = DateTime.now();
        final entry = CalendarEntry(
          id: newId(),
          category: CalendarCategory.events,
          name: eventTitle,
          description: notes.text.trim(),
          createdAt: now,
          updatedAt: now,
          startDate: localDay,
          endDate: DateTime(
            localDay.year,
            localDay.month,
            localDay.day + suggestion.endDayOffset,
          ),
          startMinutes: parsedTime,
          durationMinutes: parsedTime == null ? null : parsedDuration,
        );
        try {
          ws.saveEntry(entry);
        } on CalendarLimitException catch (error) {
          s.showToast(error.toString());
          return;
        }
        final google = s.calendarAccounts['google']!;
        if (parsedTime != null && parsedDuration == null) {
          s.showToast(
            'Event saved locally. Add a duration before exporting this timed event to Google Calendar.',
          );
        } else if (google.calendarId != null &&
            google.exportEntries &&
            await google.connected) {
          final status = await google.syncOnce();
          s.showToast('Event saved. Google Calendar: $status');
        } else {
          s.showToast(
            'Event saved locally. Connect Google Calendar and enable event export to send it.',
          );
        }
      } finally {
        title.dispose();
        date.dispose();
        time.dispose();
        duration.dispose();
        notes.dispose();
      }
    } catch (error) {
      if (mounted) s.showToast('Could not read calendar handwriting: $error');
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
      builder: (context) =>
          MediaQuery.sizeOf(context).width < 900 && s.calendarTasksOpen
          // Narrow windows and phones: the task column takes the page.
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('calendar-tasks-toggle'),
                    onPressed: () => s.setCalendarTasksOpen(false),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Close Tasks panel'),
                  ),
                ),
                Expanded(
                  child: TasksPage(
                    key: const ValueKey('calendar-tasks'),
                    state: s,
                  ),
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 2, child: _calendar()),
                // Tasks live here, in a collapsible column about 3/5 wide.
                if (s.calendarTasksOpen) ...[
                  VerticalDivider(width: 1, color: AppColors.border),
                  Expanded(
                    flex: 3,
                    child: TasksPage(
                      key: const ValueKey('calendar-tasks'),
                      state: s,
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _calendar() {
    // Short windows (a phone held sideways) get tighter spacing.
    final short = MediaQuery.sizeOf(context).height < 480;
    final gap = short ? AppSpace.xs : AppSpace.md;
    final rest = <Widget>[
      ..._overLimitWarning(),
      SizedBox(height: gap),
      _viewBar(),
      SizedBox(height: short ? AppSpace.sm : AppSpace.lg),
      _tabs(),
      SizedBox(height: gap),
      Expanded(
        child: _tab == null && _view != CalendarView.range
            ? _otherView()
            : _tab == null
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _grid()),
                  if (_selectedDay != null) ...[
                    const SizedBox(width: AppSpace.md),
                    SizedBox(
                      width: 340,
                      child: DayPanel(
                        key: ValueKey(dayKey(_selectedDay!)),
                        state: s,
                        day: _selectedDay!,
                        onClose: () => setState(() => _selectedDay = null),
                        onNewEntry: (c) => _newEntry(c, _selectedDay),
                        onRecognizeHandwriting: _recognizeHandwriting,
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
    ];
    // The same top section as the Archive (see NewPageHeader), then
    // the very same calendar controls and grid.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _newHeader(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rest,
            ),
          ),
        ),
      ],
    );
  }

  /// The New interface's header: the Archive's top section with the
  /// Calendar's own title line and buttons (the same actions as [_header]).
  Widget _newHeader() {
    final start = s.calendarStart;
    final end = addDays(start, s.calendarDays - 1);
    final archived = ws.entries.all.where((e) => e.archived).length;
    return NewPageHeader(
      title: 'Calendar',
      subtitle: InkWell(
        onTap: _pickRange,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                '${formatShortDate(start)} – ${formatShortDate(end)} ${end.year}  ·  ${s.calendarDays} days',
                overflow: TextOverflow.ellipsis,
                style: AppType.caption.copyWith(color: AppColors.textMuted),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.edit_calendar_outlined,
              size: 14,
              color: AppColors.textFaint,
            ),
          ],
        ),
      ),
      // Quick Add is the one filled (primary) action; the Tasks panel and
      // the Archive stay one click away without competing with it.
      actions: [
        Tooltip(
          message: s.calendarTasksOpen
              ? 'Close the Tasks panel'
              : 'Open the Tasks panel beside the calendar',
          child: NewHeaderButton(
            key: const ValueKey('calendar-tasks-toggle'),
            onPressed: () => s.setCalendarTasksOpen(!s.calendarTasksOpen),
            icon: s.calendarTasksOpen
                ? Icons.keyboard_double_arrow_right
                : Icons.view_sidebar_outlined,
            label: 'Tasks panel',
          ),
        ),
        NewHeaderButton(
          onPressed: () => showArchive(context, s),
          icon: Icons.inventory_2_outlined,
          label: 'Archive  $archived',
        ),
        NewHeaderButton(
          filled: true,
          onPressed: () => _newEntry(),
          icon: Icons.add,
          label: 'Quick Add',
        ),
      ],
    );
  }

  /// View choice, and (outside the range view) back / today / forward.
  Widget _viewBar() {
    final v = _view;
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<CalendarView>(
          key: const ValueKey('calendar-view-switcher'),
          showSelectedIcon: false,
          // Compact with a mouse; full-size touch targets on iPad/iPhone.
          style: touchFirst
              ? null
              : const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [
            for (final c in CalendarView.values)
              ButtonSegment(
                value: c,
                label: Text(
                  c.label,
                  style: const TextStyle(fontSize: AppType.sizeLabel),
                ),
              ),
          ],
          selected: {v},
          onSelectionChanged: (c) => _setView(c.first),
        ),
        if (_inkAvailable(v)) _inkTools(),
        if (v == CalendarView.range ||
            v == CalendarView.month ||
            v == CalendarView.week)
          _zoomControl(v),
        if (v != CalendarView.range) ...[
          GhostIconButton(
            icon: Icons.chevron_left,
            tooltip: 'Earlier',
            onTap: () =>
                setState(() => _anchor = v.step(_anchor, forward: false)),
          ),
          TextButton(
            onPressed: () => setState(() => _anchor = dateOnly(DateTime.now())),
            child: const Text('Today'),
          ),
          GhostIconButton(
            icon: Icons.chevron_right,
            tooltip: 'Later',
            onTap: () =>
                setState(() => _anchor = v.step(_anchor, forward: true)),
          ),
          Text(
            v.title(_anchor),
            key: const ValueKey('calendar-view-title'),
            style: const TextStyle(
              fontSize: AppType.sizeBody,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  void _openDay(DateTime day) {
    _anchor = dateOnly(day);
    _setView(CalendarView.day);
  }

  // ------------------------------------------------------------ drawing --

  bool _inkAvailable(CalendarView v) =>
      _ink != null &&
      _tab == null &&
      (v == CalendarView.range ||
          v == CalendarView.month ||
          v == CalendarView.week);

  /// Picks [tool] and switches Draw mode on (every tool works on the days).
  void _chooseTool(CanvasTool tool) {
    final ink = _ink;
    if (ink == null) return;
    setState(() {
      _drawing = true;
      ink.tool = tool;
    });
  }

  /// The day a new photo goes to: the selected day, else today if it is
  /// shown, else the first day shown.
  DateTime _inkTargetDay() {
    final today = dateOnly(DateTime.now());
    if (_view == CalendarView.range) {
      final selected = _selectedDay;
      if (selected != null) return selected;
      final offset = daysBetween(s.calendarStart, today);
      return offset >= 0 && offset < s.calendarDays ? today : s.calendarStart;
    }
    final shown = _view.daysAround(_anchor);
    return shown.any((d) => daysBetween(d, today) == 0) ? today : _anchor;
  }

  /// Asks for photos and puts them on a day, ready to be moved and resized
  /// with the Select tool.
  Future<void> _addPhoto() async {
    final ink = _ink;
    if (ink == null) return;
    final assets = await s.capture.pickImages();
    if (!mounted || assets.isEmpty) return;
    final day = _inkTargetDay();
    final rect = inkDayRect(day);
    // Near the top of the day: the month's small cells show that part.
    var at = Offset(rect.center.dx, rect.top + 20 + 50);
    setState(() {
      _drawing = true;
      ink.tool = CanvasTool.select;
    });
    final placed = <String>[];
    for (final asset in assets) {
      placed.add(ink.insertImage(asset, at, maxSide: 100).id);
      at += const Offset(10, 10);
    }
    ink.select(placed);
    s.showToast(
      '${assets.length == 1 ? 'Photo' : 'Photos'} added to '
      '${formatShortDate(day)}. Drag to move, the top-right dot resizes.',
    );
  }

  Widget _inkTools() => ListenableBuilder(
    listenable: _ink!,
    builder: (context, _) {
      final ink = _ink!;
      final tool = ink.tool;
      Widget toolButton(CanvasTool t, IconData icon, String tip) =>
          GhostIconButton(
            key: ValueKey('calendar-tool-${t.name}'),
            icon: icon,
            tooltip: tip,
            active: _drawing && tool == t,
            onTap: () => _chooseTool(t),
          );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GhostIconButton(
            key: const ValueKey('calendar-draw'),
            icon: Icons.draw_outlined,
            tooltip: _drawing
                ? 'Stop drawing (dates can be tapped again)'
                : 'Draw on the calendar',
            active: _drawing && tool == CanvasTool.pen,
            onTap: () => setState(() {
              final pen = ink.tool == CanvasTool.pen;
              _drawing = !(_drawing && pen);
              ink.tool = CanvasTool.pen;
            }),
          ),
          if (_drawing) ...[
            toolButton(
              CanvasTool.eraser,
              Icons.auto_fix_normal,
              'Erase drawings',
            ),
            toolButton(CanvasTool.lasso, Icons.gesture, 'Lasso select'),
            toolButton(
              CanvasTool.select,
              Icons.near_me_outlined,
              'Select and move photos',
            ),
            toolButton(CanvasTool.text, Icons.title, 'Write text on a day'),
          ],
          GhostIconButton(
            key: const ValueKey('calendar-add-photo'),
            icon: Icons.add_photo_alternate_outlined,
            tooltip: 'Add a photo to a day',
            onTap: _addPhoto,
          ),
          if (_drawing) ...[..._toolOptions(ink), ..._historyButtons(ink)],
        ],
      );
    },
  );

  List<Widget> _historyButtons(CanvasController ink) => [
    GhostIconButton(
      key: const ValueKey('calendar-undo'),
      icon: Icons.undo,
      tooltip: 'Undo',
      onTap: ink.canUndo ? ink.undo : null,
    ),
    GhostIconButton(
      key: const ValueKey('calendar-redo'),
      icon: Icons.redo,
      tooltip: 'Redo',
      onTap: ink.canRedo ? ink.redo : null,
    ),
  ];

  /// The options of the chosen tool, and only those.
  List<Widget> _toolOptions(CanvasController ink) {
    switch (ink.tool) {
      case CanvasTool.pen:
        return [
          InkColorButton(
            key: const ValueKey('calendar-pen-color'),
            color: ink.penColor,
            tooltip: 'Pen colour',
            onSelected: (c) => setState(() => ink.setPen(color: c)),
          ),
          GhostIconButton(
            key: const ValueKey('calendar-pen-width'),
            icon: Icons.line_weight,
            tooltip: 'Pen thickness (${ink.penWidth.toStringAsFixed(1)})',
            onTap: () => showPenWidthDialog(context, s, ink),
          ),
        ];
      case CanvasTool.eraser:
        return [
          if (!(_squeezer?.active ?? false))
            EraserPanel(controller: ink, onChange: s.setEraser),
          GhostIconButton(
            key: const ValueKey('calendar-eraser-width'),
            icon: Icons.line_weight,
            tooltip: 'Eraser width (${ink.eraserSize.round()})',
            onTap: () => showEraserWidthDialog(context, s, ink),
          ),
        ];
      case CanvasTool.text:
        return [
          InkColorButton(
            key: const ValueKey('calendar-text-color'),
            color: ink.penColor,
            tooltip: 'Text colour',
            onSelected: (c) => setState(() => ink.setPen(color: c)),
          ),
          InkWidthButton(
            key: const ValueKey('calendar-text-size'),
            tooltip: 'Text size',
            width: ink.newTextFontSize ?? 9,
            widths: const [6.0, 9.0, 12.0, 16.0],
            color: ink.penColor,
            onSelected: (w) => setState(() => ink.newTextFontSize = w),
          ),
        ];
      case CanvasTool.select || CanvasTool.lasso:
        final selected = ink.selectedItems;
        if (selected.isEmpty) {
          return [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
              child: Text(
                ink.tool == CanvasTool.lasso
                    ? 'Circle ink, text or photos to select them'
                    : 'Tap a photo to select it',
                style: TextStyle(
                  fontSize: AppType.sizeLabel,
                  color: AppColors.textFaint,
                ),
              ),
            ),
          ];
        }
        return [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
            child: Text(
              '${selected.length} selected',
              style: TextStyle(
                fontSize: AppType.sizeLabel,
                color: AppColors.textMuted,
              ),
            ),
          ),
          InkColorButton(
            key: const ValueKey('calendar-selection-color'),
            color:
                selected.whereType<StrokeItem>().firstOrNull?.color ??
                ink.penColor,
            tooltip: 'Recolour the selection',
            onSelected: ink.recolorSelection,
          ),
          GhostIconButton(
            key: const ValueKey('calendar-selection-duplicate'),
            icon: Icons.copy_outlined,
            tooltip: 'Duplicate',
            onTap: ink.duplicateSelection,
          ),
          GhostIconButton(
            key: const ValueKey('calendar-selection-delete'),
            icon: Icons.delete_outline,
            tooltip: 'Delete the selection',
            onTap: ink.deleteSelection,
          ),
        ];
      default:
        return const [];
    }
  }

  // ---------------------------------------------------------------- zoom --

  static const _rangeZoom = (min: 0.35, max: 2.5);
  static const _monthZoom = (min: 1.0, max: 4.0);

  Widget _zoomControl(CalendarView v) {
    final range = v == CalendarView.range;
    final viewer = range ? _viewer : _monthViewer;
    final limits = range ? _rangeZoom : _monthZoom;
    return ListenableBuilder(
      listenable: viewer,
      builder: (context, _) {
        final z = viewer.value.getMaxScaleOnAxis();
        return ZoomStepper(
          key: const ValueKey('calendar-zoom'),
          valueKey: const ValueKey('calendar-zoom-value'),
          label: '${(z * 100).round()}%',
          outTooltip: 'Zoom out',
          inTooltip: 'Zoom in',
          resetTooltip: 'Back to 100%',
          onOut: z > limits.min + 0.001 ? () => _zoomBy(v, 1 / 1.25) : null,
          onIn: z < limits.max - 0.001 ? () => _zoomBy(v, 1.25) : null,
          onReset: () => viewer.value = Matrix4.identity(),
        );
      },
    );
  }

  /// One zoom step around the middle of the shown area.
  void _zoomBy(CalendarView v, double factor) {
    final range = v == CalendarView.range;
    final viewer = range ? _viewer : _monthViewer;
    final limits = range ? _rangeZoom : _monthZoom;
    final size = range ? _rangeViewport : _monthViewport;
    final current = viewer.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(limits.min, limits.max).toDouble();
    if ((target - current).abs() < 1e-6) return;
    if (!range && target <= 1.0001) {
      viewer.value = Matrix4.identity();
      return;
    }
    final f = target / current;
    final c = size.center(Offset.zero);
    final about = Matrix4.identity()
      ..setEntry(0, 0, f)
      ..setEntry(1, 1, f)
      ..setEntry(0, 3, c.dx * (1 - f))
      ..setEntry(1, 3, c.dy * (1 - f));
    final next = about * viewer.value;
    if (!range) {
      // The month fills the area at 100%: it can only be moved while larger.
      next
        ..setEntry(
          0,
          3,
          next.entry(0, 3).clamp(size.width * (1 - target), 0.0).toDouble(),
        )
        ..setEntry(
          1,
          3,
          next.entry(1, 3).clamp(size.height * (1 - target), 0.0).toDouble(),
        );
    }
    viewer.value = next;
  }

  Widget _otherView() {
    switch (_view) {
      case CalendarView.month || CalendarView.week:
        return LayoutBuilder(
          builder: (context, box) {
            _monthViewport = box.biggest;
            return Listener(
              onPointerDown: (e) {
                if (_inkInput) _arbiter?.down(e);
              },
              onPointerUp: (e) => _arbiter?.release(e.pointer),
              onPointerCancel: (e) => _arbiter?.release(e.pointer),
              child: CalendarGridView(
                view: _view,
                anchor: _anchor,
                itemsOn: _itemsOn,
                onDay: _openDay,
                onItem: _editItem,
                onToggleEntry: (entry, day) =>
                    ws.toggleEntryCompletion(entry.id, day),
                overlay: _inkOn,
                dropOn: (day, cell) =>
                    TransferTarget(state: s, place: DayPlace(day), child: cell),
                zoom: _monthViewer,
                panEnabled: !_inkInput || (_arbiter?.navigating ?? false),
                scaleEnabled: !(_inkInput && (_arbiter?.stylusDown ?? false)),
              ),
            );
          },
        );
      case CalendarView.day:
        return DayPanel(
          key: ValueKey('day-view-${dayKey(_anchor)}'),
          state: s,
          day: _anchor,
          onClose: () => _setView(CalendarView.month),
          onNewEntry: (c) => _newEntry(c, _anchor),
          onRecognizeHandwriting: _recognizeHandwriting,
        );
      case CalendarView.agenda:
        return CalendarAgendaView(
          anchor: _anchor,
          itemsOn: _itemsOn,
          onDay: _openDay,
          onItem: _editItem,
          onToggleEntry: (entry, day) =>
              ws.toggleEntryCompletion(entry.id, day),
        );
      case CalendarView.timeline:
        return CalendarTimelineView(
          anchor: _anchor,
          itemsOn: _itemsOn,
          onItem: _editItem,
          onToggleEntry: (entry, day) =>
              ws.toggleEntryCompletion(entry.id, day),
        );
      case CalendarView.range:
        return _grid();
    }
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
      const SizedBox(height: AppSpace.md),
      Container(
        key: const ValueKey('over-limit-warning'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.warm.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: Border.all(color: AppColors.warm.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warm),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                'More than $max active entries in $which after syncing '
                'another device. Nothing was archived; archive entries until '
                'each category has $max again. New entries there are paused '
                'until then.',
                style: const TextStyle(fontSize: AppType.sizeBodySmall),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// How many of the five switches (four categories + tasks) are off.
  int get _hiddenCount =>
      CalendarCategory.values.where((c) => !_shown.contains(c)).length +
      (_showTasks ? 0 : 1);

  /// The one place to show or hide categories and task cards: a compact
  /// trigger (it says when something is hidden) and a menu of checkboxes
  /// that stays open while several are changed.
  Widget _filterMenu() {
    final hidden = _hiddenCount;
    Widget box(
      String label,
      Color? color,
      bool value,
      VoidCallback toggle, {
      Key? key,
    }) => CheckboxMenuButton(
      key: key,
      value: value,
      closeOnActivate: false,
      onChanged: (_) => setState(toggle),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (color != null)
            ColorDot(color: color, size: 10)
          else
            Icon(Icons.task_alt_outlined, size: 14, color: AppColors.textMuted),
          const SizedBox(width: AppSpace.sm),
          Text(label, style: const TextStyle(fontSize: AppType.sizeBodySmall)),
        ],
      ),
    );
    return MenuAnchor(
      menuChildren: [
        for (final c in CalendarCategory.values)
          box(
            c.label,
            calendarCategoryColor(c),
            _shown.contains(c),
            () => _shown.contains(c) ? _shown.remove(c) : _shown.add(c),
            key: ValueKey('calendar-filter-${c.name}'),
          ),
        const Divider(height: 1),
        box(
          'Show tasks',
          null,
          _showTasks,
          () => _showTasks = !_showTasks,
          key: const ValueKey('calendar-filter-tasks'),
        ),
        if (hidden > 0) ...[
          const Divider(height: 1),
          MenuItemButton(
            key: const ValueKey('calendar-filter-all'),
            closeOnActivate: false,
            onPressed: () => setState(() {
              _shown.addAll(CalendarCategory.values);
              _showTasks = true;
            }),
            child: const Text('Show everything'),
          ),
        ],
      ],
      builder: (context, menu, _) => Tooltip(
        message: 'Show or hide categories and task cards',
        child: TextButton.icon(
          key: const ValueKey('calendar-filter'),
          style: TextButton.styleFrom(
            foregroundColor: hidden > 0
                ? AppColors.accent
                : AppColors.textMuted,
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          icon: const Icon(Icons.filter_list, size: 16),
          label: Text(
            hidden == 0 ? 'Filter' : 'Filter · $hidden hidden',
            style: const TextStyle(fontSize: AppType.sizeLabel),
          ),
        ),
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
          borderRadius: BorderRadius.circular(AppRadii.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.sm),
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
                      fontSize: AppType.sizeBodySmall,
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
                        borderRadius: BorderRadius.circular(AppRadii.xs),
                      ),
                      child: Text(
                        count,
                        style: TextStyle(
                          fontSize: AppType.sizeMeta,
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
      runSpacing: AppSpace.sm,
      children: [
        // Scrolls sideways when the window is too narrow for all tabs.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(AppRadii.md),
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _filterMenu(),
              // Only the 38-day grid pans and zooms.
              if (_view == CalendarView.range)
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
    final today = dateOnly(DateTime.now());
    return LayoutBuilder(
      builder: (context, box) {
        _rangeViewport = box.biggest;
        return _gridBody(start, days, rows, today);
      },
    );
  }

  Widget _gridBody(DateTime start, int days, int rows, DateTime today) {
    const w = CalendarPage.cellWidth, h = CalendarPage.cellHeight;
    // Fingers landing between the day cells count for the arbiter too.
    return Listener(
      onPointerDown: (e) {
        if (_inkInput) _arbiter?.down(e);
      },
      onPointerUp: (e) => _arbiter?.release(e.pointer),
      onPointerCancel: (e) => _arbiter?.release(e.pointer),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.md),
        // Transparent: the grid sits on the app-wide atmosphere.
        child: ColoredBox(
          color: Colors.transparent,
          child: InteractiveViewer(
            transformationController: _viewer,
            // In Draw mode one pointer draws; two fingers pinch and pan (the
            // arbiter decides), and nothing moves while the Pencil is down.
            panEnabled: !_inkInput || (_arbiter?.navigating ?? false),
            scaleEnabled: !(_inkInput && (_arbiter?.stylusDown ?? false)),
            constrained: false,
            minScale: 0.35,
            maxScale: 2.5,
            boundaryMargin: const EdgeInsets.all(600),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: SizedBox(
                width: w * 7,
                height: h * rows,
                child: Stack(
                  children: [
                    for (var i = 0; i < days; i++)
                      Positioned(
                        key: ValueKey(
                          'calendar-cell-${dayKey(addDays(start, i))}',
                        ),
                        left: (i % 7) * w,
                        top: (i ~/ 7) * h,
                        width: w,
                        height: h,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            DayCell(
                              state: s,
                              day: addDays(start, i),
                              isToday:
                                  daysBetween(today, addDays(start, i)) == 0,
                              selected:
                                  _selectedDay != null &&
                                  daysBetween(
                                        _selectedDay!,
                                        addDays(start, i),
                                      ) ==
                                      0,
                              items: _itemsOn(addDays(start, i)),
                              onTap: () => setState(
                                () => _selectedDay = addDays(start, i),
                              ),
                              onEditItem: (item) =>
                                  _editItem(item, addDays(start, i)),
                            ),
                            _inkOn(addDays(start, i)),
                          ],
                        ),
                      ),
                  ],
                ),
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
      case ExternalOnDay(:final event):
        // Changed in Google / Outlook; open it there.
        if (event.link.isNotEmpty) native.openUrl(event.link);
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

  /// Labels that fit in a cell (20 px each) below the date and a note line.
  static const maxLabels = 11;

  @override
  Widget build(BuildContext context) {
    final ws = state.workspace;
    final record = ws.days[dayKey(day)];
    final place = DayPlace(day);
    return DragTarget<Transfer>(
      onWillAcceptWithDetails: (d) =>
          state.transferChoices(d.data, place).isNotEmpty,
      onAcceptWithDetails: (d) =>
          dropTransfer(context, state, d.data, place, d.offset),
      builder: (context, candidates, _) {
        return Material(
          color: candidates.isNotEmpty
              ? AppColors.cardRaised
              : isToday
              ? AppColors.card
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
                            style: TextStyle(
                              fontSize: AppType.sizeMeta,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (record != null && record.text.trim().isNotEmpty)
                        Padding(
                          padding: EdgeInsets.only(right: 4, top: 2),
                          child: Icon(
                            Icons.sticky_note_2_outlined,
                            size: 12,
                            color: AppColors.textFaint,
                          ),
                        ),
                      if (record != null && record.assetIds.isNotEmpty)
                        Padding(
                          padding: EdgeInsets.only(right: 4, top: 2),
                          child: Icon(
                            Icons.attach_file,
                            size: 12,
                            color: AppColors.textFaint,
                          ),
                        ),
                      Text(
                        weekdayShort(day).toUpperCase(),
                        style: TextStyle(
                          fontSize: AppType.sizeMicro,
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
                        style: TextStyle(
                          fontSize: AppType.sizeMeta,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  const Spacer(),
                  Wrap(
                    spacing: 5,
                    runSpacing: 3,
                    children: [
                      for (final item in items.take(maxLabels))
                        DayLabel(
                          state: state,
                          item: item,
                          day: day,
                          onTap: () => onEditItem(item),
                        ),
                    ],
                  ),
                  if (items.length > maxLabels)
                    Text(
                      '+${items.length - maxLabels} more',
                      style: TextStyle(
                        fontSize: AppType.sizeMicro,
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
    final color = item is EntryOnDay
        ? calendarCategoryColor(item.entry.category)
        : AppColors.accent;
    final entry = item is EntryOnDay ? item.entry : null;
    final checked =
        (entry?.isCheckedOn(day) ?? false) ||
        (item is TaskOnDay && item.task.done);
    final time = switch (item) {
      EntryOnDay(:final entry) => entry.timeLabel,
      TaskOnDay(:final task) =>
        task.dueMinutes == null
            ? null
            : '${(task.dueMinutes! ~/ 60).toString().padLeft(2, '0')}:${(task.dueMinutes! % 60).toString().padLeft(2, '0')}',
      ExternalOnDay(:final event) =>
        event.startMinutes == null
            ? null
            : '${(event.startMinutes! ~/ 60).toString().padLeft(2, '0')}:${(event.startMinutes! % 60).toString().padLeft(2, '0')}',
    };
    const labelStyle = TextStyle(
      fontSize: AppType.sizeLabel,
      fontWeight: FontWeight.w500,
    );
    final timeStyle = TextStyle(
      fontSize: AppType.sizeMicro,
      color: AppColors.textMuted,
    );
    final label = LayoutBuilder(
      builder: (context, constraints) {
        final limit = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : CalendarPage.cellWidth - 24;
        final nameStyle = labelStyle.copyWith(
          color: checked ? AppColors.textFaint : AppColors.text,
          decoration: checked ? TextDecoration.lineThrough : null,
        );
        double measure(String text, TextStyle style, double max) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            maxLines: 1,
            ellipsis: '…',
          )..layout(maxWidth: max);
          return painter.width;
        }

        const padding = 10.0;
        final controlWidth = entry != null ? 30.0 : 12.0;
        final timeWidth = time == null ? 0.0 : measure(time, timeStyle, limit);
        final metadataWidth = controlWidth + (time == null ? 0 : timeWidth + 6);
        final textWidth = measure(
          item.label,
          nameStyle,
          (limit - metadataWidth - padding).clamp(24.0, limit).toDouble(),
        );
        final width = (metadataWidth + textWidth + padding)
            .clamp(48.0, limit)
            .toDouble();
        return Container(
          width: width,
          height: 30,
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(AppRadii.xs),
          ),
          child: Row(
            children: [
              if (entry != null)
                Semantics(
                  key: ValueKey('entry-check-${entry.id}-${dayKey(day)}'),
                  label:
                      'Mark ${item.label} complete on ${formatLongDate(day)}',
                  button: true,
                  toggled: checked,
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: InkWell(
                      onTap: () =>
                          state.workspace.toggleEntryCompletion(entry.id, day),
                      child: Icon(
                        checked
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        size: 18,
                        color: color,
                      ),
                    ),
                  ),
                )
              else
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              if (time != null) ...[
                const SizedBox(width: 5),
                Text(time, style: timeStyle, maxLines: 1),
                const SizedBox(width: 5),
              ] else
                const SizedBox(width: 5),
              Flexible(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle,
                ),
              ),
            ],
          ),
        );
      },
    );
    final tappable = GestureDetector(
      onTap: onTap,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: label),
    );
    if (entry?.category == CalendarCategory.habits) return tappable;
    return Draggable<Transfer>(
      data: CalendarItemTransfer(item, day),
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
    required this.onRecognizeHandwriting,
  });

  final AppState state;
  final DateTime day;
  final VoidCallback onClose;
  final ValueChanged<CalendarCategory> onNewEntry;
  final Future<void> Function(DateTime day) onRecognizeHandwriting;

  @override
  State<DayPanel> createState() => _DayPanelState();
}

class _DayPanelState extends State<DayPanel> {
  late final _text = TextEditingController(
    text: widget.state.workspace.dayRecord(widget.day).text,
  );

  AppState get s => widget.state;
  Workspace get ws => s.workspace;
  bool _recognizingHandwriting = false;

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

  /// A task due on this day; with [reminder], it also reminds (at its due
  /// time, or the usual morning time without one) through the existing
  /// task reminders.
  Future<void> _addTask({required bool reminder}) async {
    final title = await promptText(
      context,
      title: reminder ? 'Reminder' : 'New task',
      hint: reminder ? 'What to remind you of' : 'Task',
      action: 'Add',
    );
    if (title == null || title.trim().isEmpty) return;
    final task = ws.createTask(title.trim(), dueDate: widget.day);
    if (reminder) ws.tasks.put(task.copyWith(remindBefore: () => 0));
    s.showToast(
      '${reminder ? 'Reminder' : 'Task'} added for '
      '${formatShortDate(widget.day)}',
    );
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
        .where(
          (e) =>
              e.category == CalendarCategory.reading &&
              e.readingPlanId == null &&
              !e.archived,
        )
        .toList();
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.border),
      ),
      child: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  formatLongDate(day),
                  style: const TextStyle(
                    fontSize: AppType.sizeHeading,
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
          const SizedBox(height: AppSpace.sm),
          OutlinedButton.icon(
            key: const ValueKey('calendar-read-handwriting'),
            onPressed: _recognizingHandwriting
                ? null
                : () async {
                    setState(() => _recognizingHandwriting = true);
                    try {
                      await widget.onRecognizeHandwriting(day);
                    } finally {
                      if (mounted) {
                        setState(() => _recognizingHandwriting = false);
                      }
                    }
                  },
            icon: _recognizingHandwriting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.text_snippet_outlined, size: 16),
            label: Text(
              _recognizingHandwriting
                  ? 'Reading handwriting…'
                  : 'Create event from handwriting',
            ),
          ),
          const SizedBox(height: AppSpace.md),
          if (items.isEmpty)
            Text(
              'Nothing on this day.',
              style: TextStyle(
                fontSize: AppType.sizeBodySmall,
                color: AppColors.textFaint,
              ),
            ),
          for (final item in items) _itemRow(item),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in CalendarCategory.values)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 14),
                  label: Text(
                    c.label,
                    style: const TextStyle(fontSize: AppType.sizeLabel),
                  ),
                  tooltip: ws.hasRoomIn(c)
                      ? 'New ${c.label} entry on this day'
                      : '${c.label} is full (5 active)',
                  onPressed: ws.hasRoomIn(c)
                      ? () => widget.onNewEntry(c)
                      : null,
                ),
              // A task (or a task with a reminder) due this day: the same
              // task records as the Tasks panel, never a calendar copy.
              ActionChip(
                key: const ValueKey('day-add-task'),
                avatar: const Icon(Icons.add_task, size: 14),
                label: const Text(
                  'Task',
                  style: TextStyle(fontSize: AppType.sizeLabel),
                ),
                tooltip: 'New task due on this day',
                onPressed: () => _addTask(reminder: false),
              ),
              ActionChip(
                key: const ValueKey('day-add-reminder'),
                avatar: const Icon(Icons.notifications_none, size: 14),
                label: const Text(
                  'Reminder',
                  style: TextStyle(fontSize: AppType.sizeLabel),
                ),
                tooltip: 'New task due on this day, with a reminder',
                onPressed: () => _addTask(reminder: true),
              ),
            ],
          ),
          if (reading.isNotEmpty) ...[
            const SizedBox(height: AppSpace.md),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in reading)
                  ActionChip(
                    avatar: const Icon(Icons.menu_book_outlined, size: 14),
                    label: Text(
                      'Log pages: ${r.name}',
                      style: const TextStyle(fontSize: AppType.sizeLabel),
                    ),
                    onPressed: () => _logReading(r),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpace.xl),
          Text(
            'DAY NOTE',
            style: TextStyle(
              fontSize: AppType.sizeMeta,
              letterSpacing: 0.6,
              color: AppColors.textFaint,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            controller: _text,
            minLines: 3,
            maxLines: 10,
            style: const TextStyle(fontSize: AppType.sizeBodySmall),
            decoration: const InputDecoration(
              hintText: 'Anything about this day…',
            ),
            onChanged: (v) => ws.saveDay(ws.dayRecord(day).copyWith(text: v)),
          ),
          const SizedBox(height: AppSpace.lg),
          Row(
            children: [
              Text(
                'ATTACHED',
                style: TextStyle(
                  fontSize: AppType.sizeMeta,
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
          const SizedBox(height: AppSpace.sm),
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
    final day = widget.day;
    switch (item) {
      case EntryOnDay(:final entry):
        final color = calendarCategoryColor(entry.category);
        final checked = entry.isCheckedOn(day);
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Checkbox(
            key: ValueKey('entry-check-${entry.id}-${dayKey(day)}'),
            value: checked,
            activeColor: color,
            onChanged: (_) => ws.toggleEntryCompletion(entry.id, day),
          ),
          title: Text(
            entry.name,
            style: checked
                ? TextStyle(
                    decoration: TextDecoration.lineThrough,
                    color: AppColors.textFaint,
                  )
                : null,
          ),
          subtitle: Text(
            [
              entry.category.label,
              ?entry.timeLabel,
              if (entry.description.isNotEmpty) entry.description,
            ].join(' · '),
            style: TextStyle(
              fontSize: AppType.sizeMeta,
              color: AppColors.textFaint,
            ),
          ),
          // Edit is one click; the rarer entry actions share a small menu.
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GhostIconButton(
                icon: Icons.edit_outlined,
                tooltip: 'Edit',
                size: 16,
                onTap: () => showEntryEditor(context, s, entry: entry),
              ),
              PopupMenuButton<String>(
                key: ValueKey('entry-more-${entry.id}'),
                tooltip: 'More for this entry',
                icon: Icon(
                  Icons.more_horiz,
                  size: 16,
                  color: AppColors.textMuted,
                ),
                onSelected: (what) {
                  if (what == 'duplicate') {
                    final copy = ws.duplicateEntry(entry.id);
                    s.showToast(
                      copy == null
                          ? '${entry.category.label} is full '
                                '(${CalendarEntry.maxActivePerCategory} active)'
                          : 'Duplicated “${entry.name}”',
                    );
                  } else if (what == 'archive') {
                    ws.setArchived(entry.id, true);
                    s.showToast(
                      'Archived “${entry.name}”. Restore it from Archive.',
                    );
                  } else if (what.startsWith('move:')) {
                    final to = CalendarCategory.values.byName(
                      what.substring(5),
                    );
                    if (ws.changeEntryCategory(entry.id, to, day)) {
                      s.showToast('Moved “${entry.name}” to ${to.label}');
                    }
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'duplicate',
                    enabled: ws.hasRoomIn(entry.category),
                    child: const Text('Duplicate'),
                  ),
                  // Change category: Reading entries (pages, logs, plans)
                  // stay Reading; full categories are shown but disabled.
                  if (entry.category != CalendarCategory.reading)
                    for (final c in CalendarCategory.values)
                      if (c != entry.category && c != CalendarCategory.reading)
                        PopupMenuItem(
                          key: ValueKey('entry-move-${c.name}'),
                          value: 'move:${c.name}',
                          enabled: ws.canChangeEntryCategory(entry.id, c),
                          child: Row(
                            children: [
                              ColorDot(
                                color: calendarCategoryColor(c),
                                size: 10,
                              ),
                              const SizedBox(width: AppSpace.sm),
                              Text('Move to ${c.label}'),
                            ],
                          ),
                        ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'archive', child: Text('Archive')),
                ],
              ),
            ],
          ),
        );
      case TaskOnDay(:final task):
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.task_alt_outlined, size: 14),
          ),
          title: Text(
            item.label,
            style: task.done
                ? TextStyle(
                    decoration: TextDecoration.lineThrough,
                    color: AppColors.textFaint,
                  )
                : null,
          ),
          subtitle: Row(
            children: [
              Flexible(
                child: Text(
                  'Task (from Tasks)',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.sizeMeta,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
              if (task.estimateMinutes != null) ...[
                const SizedBox(width: 8),
                EstimateLabel(task: task),
              ],
            ],
          ),
          trailing: GhostIconButton(
            icon: Icons.open_in_new,
            tooltip: 'Open in Tasks',
            size: 16,
            onTap: () => s.openTask(task.id),
          ),
        );
      case ExternalOnDay(:final event):
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.cloud_outlined, size: 14),
          ),
          title: Text(item.label),
          subtitle: Text(
            [
              event.provider == 'google' ? 'Google Calendar' : 'Outlook',
              if (event.startMinutes != null)
                '${(event.startMinutes! ~/ 60).toString().padLeft(2, '0')}:'
                    '${(event.startMinutes! % 60).toString().padLeft(2, '0')}',
              if (event.location.isNotEmpty) event.location,
            ].join(' · '),
            style: TextStyle(
              fontSize: AppType.sizeMeta,
              color: AppColors.textFaint,
            ),
          ),
          trailing: event.link.isEmpty
              ? null
              : GhostIconButton(
                  icon: Icons.open_in_new,
                  tooltip: 'Edit it there',
                  size: 16,
                  onTap: () => native.openUrl(event.link),
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
    final countedEntries = ws.activeCount(category);
    final full = !ws.hasRoomIn(category);
    return ListView(
      children: [
        Row(
          children: [
            Text(
              '$countedEntries of ${CalendarEntry.maxActivePerCategory} active',
              style: TextStyle(
                fontSize: AppType.sizeBodySmall,
                color: AppColors.textMuted,
              ),
            ),
            const Spacer(),
            if (full)
              Padding(
                padding: EdgeInsets.only(right: AppSpace.md),
                child: Text(
                  'Full — archive an entry to add another.',
                  style: TextStyle(
                    fontSize: AppType.sizeLabel,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
            FilledButton.icon(
              onPressed: full ? null : onNew,
              icon: const Icon(Icons.add, size: 16),
              label: Text('New ${category.label} entry'),
            ),
          ],
        ),
        if (countedEntries > CalendarEntry.maxActivePerCategory)
          Container(
            margin: const EdgeInsets.only(top: AppSpace.md),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: AppColors.warm.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(color: AppColors.warm.withValues(alpha: 0.5)),
            ),
            child: Text(
              '${category.label} has $countedEntries active entries (the limit is '
              '${CalendarEntry.maxActivePerCategory}) because changes from several '
              'devices were combined. Nothing was archived automatically — please '
              'archive ${countedEntries - CalendarEntry.maxActivePerCategory}.',
              style: const TextStyle(fontSize: AppType.sizeBodySmall),
            ),
          ),
        const SizedBox(height: AppSpace.lg),
        if (entries.isEmpty)
          Padding(
            padding: EdgeInsets.all(AppSpace.xl),
            child: Text(
              'Nothing here yet.',
              style: TextStyle(color: AppColors.textFaint),
            ),
          ),
        Wrap(
          spacing: AppSpace.lg,
          runSpacing: AppSpace.lg,
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
    final color = calendarCategoryColor(e.category);
    final details = <Widget>[];
    switch (e.category) {
      case CalendarCategory.reading:
        final total = e.totalPages;
        final progress = total == null || total == 0
            ? null
            : (e.currentPage / total).clamp(0.0, 1.0);
        details.addAll([
          if (e.readingPlanId != null && e.readingPlanDate != null)
            Text(
              e.readingPlanDetached
                  ? 'Detached daily page · ${formatLongDate(e.readingPlanDate!)}'
                  : 'Daily page · ${formatLongDate(e.readingPlanDate!)}',
              style: TextStyle(
                fontSize: AppType.sizeLabel,
                color: AppColors.textMuted,
              ),
            ),
          if (e.readingPlanId == null &&
              e.readingPlanStartDate != null &&
              e.readingPlanEndDate != null)
            Text(
              'Daily plan · ${formatShortDate(e.readingPlanStartDate!)} – ${formatShortDate(e.readingPlanEndDate!)} (inclusive)',
              style: TextStyle(
                fontSize: AppType.sizeLabel,
                color: AppColors.textMuted,
              ),
            ),
          const SizedBox(height: 8),
          if (progress != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.xs),
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
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              color: AppColors.textMuted,
            ),
          ),
          Text(
            '${e.readingLog.length} reading days logged',
            style: TextStyle(
              fontSize: AppType.sizeMeta,
              color: AppColors.textFaint,
            ),
          ),
        ]);
        final target = e.targetPagesPerDay;
        final goalStart = e.goalStartDate;
        if (target != null && goalStart != null && total != null) {
          try {
            final estimate = estimateReadingGoal(
              totalPages: total,
              currentPage: e.currentPage,
              pagesPerDay: target,
              startDate: goalStart,
              today: DateTime.now(),
            );
            details.add(
              Text(
                estimate.isComplete
                    ? 'Reading goal complete'
                    : 'Goal: ${estimate.daysLabel} · '
                          'finish ${formatShortDate(estimate.completionDate!)}',
                style: TextStyle(
                  fontSize: AppType.sizeMeta,
                  color: AppColors.textFaint,
                ),
              ),
            );
          } on ArgumentError {
            details.add(
              Text(
                'Reading goal needs correction',
                style: TextStyle(
                  fontSize: AppType.sizeMeta,
                  color: AppColors.textFaint,
                ),
              ),
            );
          }
        }
      case CalendarCategory.habits:
        final start = state.calendarStart;
        final rangeDays = [
          for (var i = 0; i < state.calendarDays; i++) addDays(start, i),
        ];
        final scheduled = rangeDays.where(e.occursOn).toList();
        final today = dateOnly(DateTime.now());
        details.addAll([
          Text(
            e.timeLabel == null
                ? 'Choose time to schedule'
                : 'At ${e.timeLabel}',
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              color: e.needsTimeConfiguration
                  ? AppColors.warm
                  : AppColors.textMuted,
            ),
          ),
          Text(
            e.weekdays.isEmpty
                ? 'Every day'
                : [
                    for (var d = 1; d <= 7; d++)
                      if (e.weekdays.contains(d)) weekdayLetters[d - 1],
                  ].join(' '),
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              color: AppColors.textMuted,
            ),
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
                        borderRadius: BorderRadius.circular(AppRadii.xs),
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
          Text(
            'Click a square to check a day off.',
            style: TextStyle(
              fontSize: AppType.sizeMeta,
              color: AppColors.textFaint,
            ),
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
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              color: AppColors.textMuted,
            ),
          ),
        );
      case CalendarCategory.other:
        final dates = e.dates.toList()..sort();
        details.add(
          Text(
            dates.isEmpty
                ? 'No dates'
                : dates.map((k) => formatShortDate(parseDayKey(k))).join(', '),
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              color: AppColors.textMuted,
            ),
          ),
        );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.md),
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
                padding: const EdgeInsets.all(AppSpace.lg),
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
            style: TextStyle(
              fontSize: AppType.sizeBodySmall,
              color: AppColors.textMuted,
            ),
          ),
        const SizedBox(height: 6),
        ...details,
        if (e.notes.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            e.notes.trim(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.sizeLabel,
              color: AppColors.textFaint,
            ),
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
  return showAppDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: state.workspace.entries,
      builder: (context, _) {
        final ws = state.workspace;
        final archived = ws.entries.all.where((e) => e.archived).toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return AlertDialog(
          title: const Text(
            'Archive',
            style: TextStyle(fontSize: AppType.sizeHeading),
          ),
          content: SizedBox(
            width: 480,
            height: 380,
            child: archived.isEmpty
                ? Center(
                    child: Text(
                      'Archived entries appear here.',
                      style: TextStyle(color: AppColors.textFaint),
                    ),
                  )
                : ListView(
                    children: [
                      for (final e in archived)
                        ListTile(
                          leading: ColorDot(
                            color: calendarCategoryColor(e.category),
                          ),
                          title: Text(e.name),
                          subtitle: Text(
                            e.archivedAt == null
                                ? '${e.category.label} · Retention date pending'
                                : '${e.category.label} · Archived '
                                      '${formatLongDate(e.archivedAt!.toLocal())} · '
                                      'permanently deleted '
                                      '${formatLongDate(e.archivedAt!.add(Workspace.archivedEntryRetention).toLocal())}',
                            style: TextStyle(
                              fontSize: AppType.sizeLabel,
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
