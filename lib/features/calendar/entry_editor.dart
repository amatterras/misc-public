import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../ai/ai_service.dart';
import '../ai/ai_session.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/library_models.dart';
import '../../data/models/record.dart';
import '../../data/workspace.dart';
import '../../widgets/common.dart';
import '../smartlinks/smart_links.dart';
import '../smartlinks/smart_links_ui.dart';
import 'reading_goal.dart';

const weekdayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

/// Creates a new entry (when [entry] is null) or edits an existing one.
/// Returns the saved entry, or null if cancelled.
Future<CalendarEntry?> showEntryEditor(
  BuildContext context,
  AppState state, {
  CalendarEntry? entry,
  CalendarCategory? category,
  DateTime? day,
}) {
  final ws = state.workspace;
  final cat = entry?.category ?? category ?? CalendarCategory.events;
  if (entry == null && !ws.hasRoomIn(cat)) {
    state.showToast(CalendarLimitException(cat).toString());
    return Future.value(null);
  }
  final now = DateTime.now();
  final start = dateOnly(day ?? now);
  final initial =
      entry ??
      CalendarEntry(
        id: newId(),
        category: cat,
        name: '',
        createdAt: now,
        updatedAt: now,
        colorIndex: cat.index,
        startDate:
            cat == CalendarCategory.events || cat == CalendarCategory.habits
            ? start
            : null,
        endDate: cat == CalendarCategory.events ? start : null,
        dates: cat == CalendarCategory.other ? {dayKey(start)} : const {},
      );
  return showDialog<CalendarEntry>(
    context: context,
    builder: (_) => _EntryEditor(
      state: state,
      initial: initial,
      isNew: entry == null,
      day: start,
    ),
  );
}

class _EntryEditor extends StatefulWidget {
  const _EntryEditor({
    required this.state,
    required this.initial,
    required this.isNew,
    required this.day,
  });

  final AppState state;
  final CalendarEntry initial;
  final bool isNew;
  final DateTime day;

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  late CalendarEntry e = widget.initial;
  late final _name = TextEditingController(text: e.name);
  late final _description = TextEditingController(text: e.description);
  late final _notes = TextEditingController(text: e.notes);
  late final _total = TextEditingController(
    text: e.totalPages?.toString() ?? '',
  );
  late final _current = TextEditingController(
    text: e.currentPage == 0 ? '' : '${e.currentPage}',
  );
  late final _pagesPerDay = TextEditingController(
    text: e.targetPagesPerDay?.toString() ?? '',
  );
  late DateTime? _goalStartDate = e.goalStartDate;
  late DateTime? _readingPlanStart = e.readingPlanStartDate;
  late DateTime? _readingPlanEnd = e.readingPlanEndDate;
  late final _duration = TextEditingController(
    text: e.durationMinutes?.toString() ?? '',
  );
  final _logPages = TextEditingController();
  late DateTime _logDay = widget.day;
  String? _error;

  AppState get s => widget.state;
  Workspace get ws => s.workspace;

  @override
  void dispose() {
    for (final c in [
      _name,
      _description,
      _notes,
      _total,
      _current,
      _pagesPerDay,
      _duration,
      _logPages,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  CalendarEntry _collect() => e.copyWith(
    name: _name.text.trim(),
    description: _description.text.trim(),
    notes: _notes.text,
    totalPages: () => int.tryParse(_total.text.trim()),
    currentPage: int.tryParse(_current.text.trim()) ?? 0,
    targetPagesPerDay: () => int.tryParse(_pagesPerDay.text.trim()),
    goalStartDate: () => _goalStartDate,
    durationMinutes: () => int.tryParse(_duration.text.trim()),
  );

  void _save() {
    final entry = _collect();
    if (entry.name.isEmpty) {
      setState(() => _error = 'Give it a name.');
      return;
    }
    if (widget.isNew &&
        entry.category == CalendarCategory.habits &&
        entry.startMinutes == null) {
      setState(() => _error = 'Choose a time for this habit before saving.');
      return;
    }
    if (entry.category == CalendarCategory.reading) {
      final planStart = _readingPlanStart;
      final planEnd = _readingPlanEnd;
      if ((planStart == null) != (planEnd == null)) {
        setState(() => _error = 'Choose both plan dates, or clear both.');
        return;
      }
      if (planStart != null &&
          planEnd != null &&
          daysBetween(planStart, planEnd) < 0) {
        setState(
          () => _error = 'The end date must be on or after the start date.',
        );
        return;
      }
      final target = entry.targetPagesPerDay;
      if (_pagesPerDay.text.trim().isNotEmpty && target == null) {
        setState(() => _error = 'Enter pages per day as a whole number.');
        return;
      }
      if (target != null && target <= 0) {
        setState(() => _error = 'Pages per day must be greater than zero.');
        return;
      }
      if (target != null && entry.totalPages == null) {
        setState(() => _error = 'Enter the book’s total page count.');
        return;
      }
      if (_total.text.trim().isNotEmpty &&
          int.tryParse(_total.text.trim()) == null) {
        setState(() => _error = 'Total pages must be a whole number.');
        return;
      }
      if (_current.text.trim().isNotEmpty &&
          int.tryParse(_current.text.trim()) == null) {
        setState(() => _error = 'Current page must be a whole number.');
        return;
      }
      if (target != null && entry.goalStartDate == null) {
        setState(() => _error = 'Choose a start date for this reading goal.');
        return;
      }
      if (entry.totalPages != null && entry.totalPages! <= 0) {
        setState(() => _error = 'Total pages must be greater than zero.');
        return;
      }
      if (entry.currentPage < 0 ||
          (entry.totalPages != null && entry.currentPage > entry.totalPages!)) {
        setState(() => _error = 'Current page must be within the book.');
        return;
      }
    }
    try {
      if (entry.category == CalendarCategory.reading &&
          entry.readingPlanId == null) {
        ws.saveReadingPlan(
          entry.copyWith(
            readingPlanStartDate: () => _readingPlanStart,
            readingPlanEndDate: () => _readingPlanEnd,
          ),
        );
      } else {
        ws.saveEntry(entry);
      }
      Navigator.pop(context, entry);
    } on CalendarLimitException catch (err) {
      setState(() => _error = err.toString());
    } on ArgumentError catch (err) {
      setState(() => _error = err.message?.toString() ?? err.toString());
    }
  }

  Future<DateTime?> _pickDate(DateTime? initial) => showDatePicker(
    context: context,
    initialDate: initial ?? widget.day,
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
  );

  Future<int?> _pickTime(int? minutes) async {
    final t = await showTimePicker(
      context: context,
      initialTime: minutes == null
          ? const TimeOfDay(hour: 9, minute: 0)
          : TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
    );
    return t == null ? null : t.hour * 60 + t.minute;
  }

  Widget _dateButton(
    String label,
    DateTime? value,
    ValueChanged<DateTime> onPicked, {
    VoidCallback? onClear,
  }) {
    return LabeledField(
      label: label,
      child: Row(
        children: [
          TextButton.icon(
            icon: const Icon(Icons.event, size: 16),
            label: Text(value == null ? 'Choose…' : formatLongDate(value)),
            onPressed: () async {
              final d = await _pickDate(value);
              if (d != null) onPicked(d);
            },
          ),
          if (value != null && onClear != null)
            GhostIconButton(
              icon: Icons.close,
              tooltip: 'Clear',
              size: 14,
              onTap: onClear,
            ),
        ],
      ),
    );
  }

  Widget _timeFields() {
    return LabeledField(
      label: 'Time',
      child: Row(
        children: [
          TextButton.icon(
            icon: const Icon(Icons.schedule, size: 16),
            label: Text(e.timeLabel ?? 'All day'),
            onPressed: () async {
              final m = await _pickTime(e.startMinutes);
              if (m != null) {
                setState(() => e = e.copyWith(startMinutes: () => m));
              }
            },
          ),
          if (e.startMinutes != null) ...[
            GhostIconButton(
              icon: Icons.close,
              tooltip: 'All day',
              size: 14,
              onTap: () =>
                  setState(() => e = e.copyWith(startMinutes: () => null)),
            ),
            const SizedBox(width: Space.md),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _duration,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  hintText: 'Minutes',
                  suffixText: 'min',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _categoryFields() {
    switch (e.category) {
      case CalendarCategory.events:
        return [
          _dateButton('Starts', e.startDate, (d) {
            setState(() {
              final end = e.endDate;
              e = e.copyWith(
                startDate: () => d,
                endDate: () => end == null || daysBetween(d, end) < 0 ? d : end,
              );
            });
          }),
          _dateButton('Ends', e.endDate, (d) {
            setState(() {
              final start = e.startDate ?? d;
              e = e.copyWith(
                endDate: () => daysBetween(start, d) < 0 ? start : d,
              );
            });
          }),
          _timeFields(),
        ];
      case CalendarCategory.other:
        final dates = e.dates.toList()..sort();
        return [
          LabeledField(
            label: 'Dates',
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final k in dates)
                  InputChip(
                    label: Text(
                      formatShortDate(parseDayKey(k)),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onDeleted: () => setState(
                      () => e = e.copyWith(dates: {...e.dates}..remove(k)),
                    ),
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add date'),
                  onPressed: () async {
                    final d = await _pickDate(null);
                    if (d != null) {
                      setState(
                        () => e = e.copyWith(dates: {...e.dates, dayKey(d)}),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          _timeFields(),
        ];
      case CalendarCategory.habits:
        return [
          _timeFields(),
          if (e.needsTimeConfiguration)
            LabeledField(
              label: 'Needs a time',
              child: Text(
                'Choose a local time for this habit. Existing untimed habits stay unscheduled until you choose one.',
                style: TextStyle(fontSize: 12, color: AppColors.warm),
              ),
            ),
          LabeledField(
            label: 'Repeats',
            child: Wrap(
              spacing: 4,
              children: [
                ChoiceChip(
                  label: const Text('Every day'),
                  selected: e.weekdays.isEmpty,
                  onSelected: (_) =>
                      setState(() => e = e.copyWith(weekdays: const {})),
                ),
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    label: Text(weekdayLetters[d - 1]),
                    selected: e.weekdays.contains(d),
                    showCheckmark: false,
                    onSelected: (on) => setState(() {
                      final set = {...e.weekdays};
                      on ? set.add(d) : set.remove(d);
                      e = e.copyWith(
                        weekdays: set.length == 7 ? const {} : set,
                      );
                    }),
                  ),
              ],
            ),
          ),
          _dateButton(
            'From',
            e.startDate,
            (d) => setState(() => e = e.copyWith(startDate: () => d)),
          ),
          _dateButton(
            'Until',
            e.endDate,
            (d) => setState(() => e = e.copyWith(endDate: () => d)),
            onClear: () => setState(() => e = e.copyWith(endDate: () => null)),
          ),
          LabeledField(
            label: 'Done',
            child: Text(
              '${e.checkoffs.length} check-offs so far',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
          ),
        ];
      case CalendarCategory.reading:
        final plan = e.readingPlanId == null
            ? null
            : ws.entries[e.readingPlanId];
        final log = e.readingLog.entries.toList()
          ..sort((a, b) => b.key.compareTo(a.key));
        return [
          if (e.readingPlanId != null && e.readingPlanDate != null)
            LabeledField(
              label: 'Daily page',
              child: Text(
                'Part of ${plan?.name ?? e.readingPlanId} · ${formatLongDate(e.readingPlanDate!)}',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
          if (e.readingPlanId == null) ...[
            LabeledField(
              label: 'Daily plan',
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _dateButton(
                    'Starts',
                    _readingPlanStart,
                    (d) {
                      setState(() {
                        _readingPlanStart = d;
                        if (_readingPlanEnd != null &&
                            daysBetween(d, _readingPlanEnd!) < 0) {
                          _readingPlanEnd = d;
                        }
                      });
                    },
                    onClear: () => setState(() {
                      _readingPlanStart = null;
                      _readingPlanEnd = null;
                    }),
                  ),
                  _dateButton('Ends (inclusive)', _readingPlanEnd, (d) {
                    setState(() => _readingPlanEnd = d);
                  }, onClear: () => setState(() => _readingPlanEnd = null)),
                ],
              ),
            ),
            if (_readingPlanStart != null && _readingPlanEnd != null)
              LabeledField(
                label: 'Daily pages',
                child: Text(
                  '${daysBetween(_readingPlanStart!, _readingPlanEnd!) + 1} independent pages · end date included',
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ),
          ],
          LabeledField(
            label: 'Progress',
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _current,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: 'Current page'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('of'),
                ),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _total,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: 'Total pages'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
          LabeledField(
            label: 'Goal start',
            child: Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.event, size: 16),
                  label: Text(
                    _goalStartDate == null
                        ? 'Choose start date'
                        : formatLongDate(_goalStartDate!),
                  ),
                  onPressed: () async {
                    final date = await _pickDate(_goalStartDate);
                    if (date != null) {
                      setState(() => _goalStartDate = dateOnly(date));
                    }
                  },
                ),
                if (_goalStartDate != null)
                  GhostIconButton(
                    icon: Icons.close,
                    tooltip: 'Clear goal start date',
                    size: 14,
                    onTap: () => setState(() => _goalStartDate = null),
                  ),
              ],
            ),
          ),
          LabeledField(
            label: 'Target pages per day',
            child: SizedBox(
              width: 150,
              child: TextField(
                controller: _pagesPerDay,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'e.g. 20'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          _goalForecast(),
          LabeledField(
            label: 'Log reading',
            child: Row(
              children: [
                TextButton(
                  onPressed: () async {
                    final d = await _pickDate(_logDay);
                    if (d != null) setState(() => _logDay = d);
                  },
                  child: Text(formatShortDate(_logDay)),
                ),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _logPages,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: 'Pages'),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    final pages = int.tryParse(_logPages.text.trim());
                    if (pages == null || pages <= 0) return;
                    final key = dayKey(_logDay);
                    final current =
                        (int.tryParse(_current.text.trim()) ?? e.currentPage) +
                        pages;
                    setState(() {
                      e = e.copyWith(
                        readingLog: {
                          ...e.readingLog,
                          key: (e.readingLog[key] ?? 0) + pages,
                        },
                      );
                      _current.text = '$current';
                      _logPages.clear();
                    });
                  },
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
          if (log.isNotEmpty)
            LabeledField(
              label: 'Activity',
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final l in log)
                    InputChip(
                      label: Text(
                        '${formatShortDate(parseDayKey(l.key))}: ${l.value} p.',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onDeleted: () => setState(
                        () => e = e.copyWith(
                          readingLog: {...e.readingLog}..remove(l.key),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ];
    }
  }

  Widget _goalForecast() {
    final target = int.tryParse(_pagesPerDay.text.trim());
    final total = int.tryParse(_total.text.trim());
    final current = int.tryParse(_current.text.trim()) ?? 0;
    final start = _goalStartDate;
    if (_pagesPerDay.text.trim().isEmpty && start == null) {
      return const SizedBox.shrink();
    }
    if (target == null || total == null || start == null) {
      return LabeledField(
        label: 'Estimate',
        child: Text(
          'Enter a valid total page count, daily target, and start date.',
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
      );
    }
    try {
      final estimate = estimateReadingGoal(
        totalPages: total,
        currentPage: current,
        pagesPerDay: target,
        startDate: start,
        today: DateTime.now(),
      );
      return LabeledField(
        label: 'Estimate',
        child: Text(
          estimate.isComplete
              ? 'Goal complete.'
              : '${estimate.pagesRemaining} pages left · '
                    '${estimate.daysLabel} · finish '
                    '${formatLongDate(estimate.completionDate!)}\n'
                    'Assumes $target pages every calendar day, starting on '
                    'the later of today and ${formatShortDate(start)}.',
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
      );
    } on ArgumentError {
      return LabeledField(
        label: 'Estimate',
        child: Text(
          'Use positive page counts and keep current progress within the book.',
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
      );
    }
  }

  Future<void> _attach(Future<List<Asset>> Function() source) async {
    final assets = await source();
    setState(() {
      e = e.copyWith(
        assetIds: [
          ...e.assetIds,
          for (final a in assets)
            if (!e.assetIds.contains(a.id)) a.id,
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          ColorDot(color: calendarCategoryColor(e.category), size: 12),
          const SizedBox(width: Space.sm),
          Text(
            widget.isNew
                ? 'New ${e.category.label} entry'
                : 'Edit ${e.category.label} entry',
            style: const TextStyle(fontSize: 16),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                autofocus: widget.isNew,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: switch (e.category) {
                    CalendarCategory.reading => 'Book title',
                    CalendarCategory.habits => 'Habit, e.g. “Morning walk”',
                    CalendarCategory.events => 'Event name',
                    CalendarCategory.other => 'Name',
                  },
                ),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _description,
                decoration: const InputDecoration(
                  hintText: 'Short description (optional)',
                ),
              ),
              const SizedBox(height: Space.md),
              ..._categoryFields(),
              const SizedBox(height: Space.md),
              TextField(
                controller: _notes,
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(
                  hintText: 'Notes',
                  suffixIcon: InsertLinkButton(
                    state: s,
                    controller: _notes,
                    owner: WorkspaceRef(RefKind.entry, e.id),
                  ),
                ),
              ),
              ListenableBuilder(
                listenable: _notes,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: SmartLinksPanel(
                    state: s,
                    owner: WorkspaceRef(RefKind.entry, e.id),
                    text: '${_description.text}\n${_notes.text}',
                    beforeOpen: () async {
                      _save();
                      return _error == null;
                    },
                    onRemoveLink: (t) {
                      _notes.text = removeLinkTo(_notes.text, t);
                      _description.text = removeLinkTo(_description.text, t);
                    },
                  ),
                ),
              ),
              const SizedBox(height: Space.md),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final a in assetsFor(s, e.assetIds))
                    AssetChip(
                      workspace: ws,
                      asset: a,
                      onRemove: () => setState(
                        () => e = e.copyWith(
                          assetIds: [...e.assetIds]..remove(a.id),
                        ),
                      ),
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.add_link, size: 15),
                    label: const Text('Link'),
                    onPressed: () => _attach(() async {
                      final input = await promptText(
                        context,
                        title: 'Attach link',
                        hint: 'https://…',
                        action: 'Attach',
                      );
                      final url = input == null ? null : extractUrl(input);
                      return url == null ? <Asset>[] : [s.capture.link(url)];
                    }),
                  ),
                  TextButton.icon(
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 15,
                    ),
                    label: const Text('Photos'),
                    onPressed: () => _attach(s.capture.pickImages),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: Space.md),
                Text(
                  _error!,
                  style: TextStyle(color: AppColors.danger, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!widget.isNew) ...[
          if (widget.state.ai.enabled)
            TextButton(
              key: const ValueKey('entry-ask-ai'),
              onPressed: () => widget.state.sendToAi(
                AiContext(
                  title: 'Calendar: ${e.name}',
                  source: AiSource.calendar,
                  text: [
                    e.name,
                    e.category.label,
                    if (e.description.isNotEmpty) e.description,
                    if (e.notes.isNotEmpty) e.notes,
                  ].join('\n'),
                ),
              ),
              child: const Text('Ask AI'),
            ),
          TextButton(
            onPressed: () async {
              final ok = await confirm(
                context,
                title: 'Delete “${e.name}”?',
                message: 'This removes it from every view. Archive it instead to keep it.',
              );
              if (ok && context.mounted) {
                ws.entries.remove(e.id);
                Navigator.pop(context);
              }
            },
            child: Text('Delete', style: TextStyle(color: AppColors.danger)),
          ),
          TextButton(
            onPressed: () {
              try {
                ws.saveEntry(_collect().copyWith(archived: !e.archived));
                Navigator.pop(context);
              } on CalendarLimitException catch (err) {
                setState(() => _error = err.toString());
              }
            },
            child: Text(e.archived ? 'Restore' : 'Archive'),
          ),
        ],
        const SizedBox(width: Space.xl),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: AppColors.textMuted)),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
