// Picks a note's paper: one of the three templates (with previews) and its
// spacing, line color/opacity and page color.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/paper.dart';
import 'paper_painter.dart';

Future<void> showPaperDialog(
  BuildContext context,
  AppState state,
  String noteId,
) => showDialog<void>(
  context: context,
  builder: (context) => _PaperDialog(state: state, noteId: noteId),
);

class _PaperDialog extends StatefulWidget {
  const _PaperDialog({required this.state, required this.noteId});

  final AppState state;
  final String noteId;

  @override
  State<_PaperDialog> createState() => _PaperDialogState();
}

class _PaperDialogState extends State<_PaperDialog> {
  late NotePaper _paper =
      widget.state.workspace.notes[widget.noteId]?.paperOrDefault ??
      const NotePaper();

  void _set(NotePaper paper) {
    setState(() => _paper = paper);
    final notes = widget.state.workspace.notes;
    final note = notes[widget.noteId];
    if (note != null && note.paper != paper) {
      notes.put(note.copyWith(paper: paper));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _paper;
    final split = p.template == PaperTemplate.splitGridDots;
    return AlertDialog(
      title: const Text('Paper', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (final t in PaperTemplate.values)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: _TemplateTile(
                          template: t,
                          paper: t == p.template ? p : p.withTemplate(t),
                          selected: t == p.template,
                          onTap: () => _set(p.withTemplate(t)),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Space.md),
              if (split) _heading('Grid (left 2/5)'),
              _slider(
                'Square size',
                p.gridSpacing,
                (v) => _set(p.copyWith(gridSpacing: v)),
                key: const ValueKey('paper-grid-spacing'),
              ),
              _opacitySlider(
                'Line opacity',
                p.lineOpacity,
                (v) => _set(p.copyWith(lineOpacity: v)),
              ),
              _swatches(
                'Line color',
                paperLineColors,
                p.lineColor,
                (c) => _set(p.copyWith(lineColor: c)),
              ),
              const SizedBox(height: Space.sm),
              _swatches(
                'Page color',
                paperBackgroundColors,
                p.background,
                (c) => _set(p.copyWith(background: c)),
              ),
              if (split) ...[
                const SizedBox(height: Space.md),
                _heading('Dots (right 3/5)'),
                _slider(
                  'Dot spacing',
                  p.dotSpacing,
                  (v) => _set(p.copyWith(dotSpacing: v)),
                  key: const ValueKey('paper-dot-spacing'),
                ),
                _opacitySlider(
                  'Dot opacity',
                  p.dotOpacity,
                  (v) => _set(p.copyWith(dotOpacity: v)),
                ),
                _swatches(
                  'Dot color',
                  paperLineColors,
                  p.dotColor,
                  (c) => _set(p.copyWith(dotColor: c)),
                ),
                const SizedBox(height: Space.sm),
                _swatches(
                  'Page color',
                  paperBackgroundColors,
                  p.dotBackground,
                  (c) => _set(p.copyWith(dotBackground: c)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
    ),
  );

  Widget _opacitySlider(
    String label,
    double value,
    ValueChanged<double> onChanged,
  ) => Row(
    children: [
      SizedBox(width: 120, child: Text(label)),
      Expanded(
        child: Slider(
          value: value,
          min: NotePaper.minOpacity,
          max: 1,
          onChanged: onChanged,
        ),
      ),
    ],
  );

  Widget _slider(
    String label,
    double value,
    ValueChanged<double> onChanged, {
    Key? key,
  }) => Row(
    children: [
      SizedBox(width: 120, child: Text(label)),
      Expanded(
        child: Slider(
          key: key,
          value: value,
          min: NotePaper.minSpacing,
          max: NotePaper.maxSpacing,
          divisions: ((NotePaper.maxSpacing - NotePaper.minSpacing) / 4)
              .round(),
          label: value.round().toString(),
          onChanged: onChanged,
        ),
      ),
    ],
  );

  Widget _swatches(
    String label,
    List<int> colors,
    int selected,
    ValueChanged<int> onTap,
  ) => Row(
    children: [
      SizedBox(width: 120, child: Text(label)),
      for (final c in colors)
        GestureDetector(
          onTap: () => onTap(c),
          child: Container(
            width: 24,
            height: 24,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: Color(c),
              shape: BoxShape.circle,
              border: Border.all(
                color: c == selected ? AppColors.accent : AppColors.border,
                width: c == selected ? 2 : 1,
              ),
            ),
          ),
        ),
    ],
  );
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({
    required this.template,
    required this.paper,
    required this.selected,
    required this.onTap,
  });

  final PaperTemplate template;
  final NotePaper paper;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('paper-${template.name}'),
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    child: Column(
      children: [
        Container(
          height: 110,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          // A page is 816 wide; the preview shows it at about 1/6 size.
          child: CustomPaint(
            painter: PaperPainter(paper, scale: 0.17),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          template.label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            color: selected ? AppColors.text : AppColors.textMuted,
          ),
        ),
      ],
    ),
  );
}
