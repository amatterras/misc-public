import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/canvas_models.dart' show newId;
import '../../data/models/library_models.dart';
import '../../data/models/record.dart';
import '../../data/workspace.dart';
import '../../widgets/common.dart';

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
        colorIndex: switch (cat) {
          CalendarCategory.reading => 6,
          CalendarCategory.habits => 3,
          CalendarCategory.events => 5,
          CalendarCategory.other => 1,
        },
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
  late final _author = TextEditingController(text: e.author);
  late final _total = TextEditingController(
    text: e.totalPages?.toString() ?? '',
  );
  late final _current = TextEditingController(
    text: e.currentPage == 0 ? '' : '${e.currentPage}',
  );
  late final _highlights = TextEditingController(text: e.highlights);
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
      _author,
      _total,
      _current,
      _highlights,
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
    author: _author.text.trim(),
    totalPages: () => int.tryParse(_total.text.trim()),
    currentPage: int.tryParse(_current.text.trim()) ?? 0,
    highlights: _highlights.text,
    durationMinutes: () => int.tryParse(_duration.text.trim()),
  );

  void _save() {
    final entry = _collect();
    if (entry.name.isEmpty) {
      setState(() => _error = 'Give it a name.');
      return;
    }
    try {
      ws.saveEntry(entry);
      Navigator.pop(context, entry);
    } on CalendarLimitException catch (err) {
      setState(() => _error = err.toString());
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
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
          ),
        ];
      case CalendarCategory.reading:
        final log = e.readingLog.entries.toList()
          ..sort((a, b) => b.key.compareTo(a.key));
        return [
          LabeledField(
            label: 'Author',
            child: TextField(controller: _author),
          ),
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
                  ),
                ),
              ],
            ),
          ),
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
          const SizedBox(height: Space.sm),
          TextField(
            controller: _highlights,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'Highlights and quotes',
            ),
          ),
        ];
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
          ColorDot(index: e.colorIndex, size: 12),
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
              LabeledField(
                label: 'Colour',
                child: ColorPicker(
                  value: e.colorIndex,
                  onChanged: (i) =>
                      setState(() => e = e.copyWith(colorIndex: i)),
                ),
              ),
              ..._categoryFields(),
              const SizedBox(height: Space.md),
              TextField(
                controller: _notes,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(hintText: 'Notes'),
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
                  style: const TextStyle(color: AppColors.danger, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!widget.isNew) ...[
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
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.danger),
            ),
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
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
