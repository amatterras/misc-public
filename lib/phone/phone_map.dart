// Mindmap on the phone: the existing canvas, full width, under one slim bar
// that names the map. Tapping the name opens the list of maps (switch, new,
// rename, trash); the bar replaces the corner picker the desktop canvas has.
import 'package:flutter/material.dart';

import '../app/design_tokens.dart';
import '../app/app_state.dart';
import '../features/canvas/canvas_page.dart' show CanvasPage, runCanvasOption;
import '../new_ui/new_tokens.dart';
import 'phone_more.dart';
import 'phone_tokens.dart';
import 'phone_widgets.dart';

class PhoneMap extends StatelessWidget {
  const PhoneMap({super.key, required this.state});

  final AppState state;

  Future<void> _maps(BuildContext context) async {
    final maps = [
      for (final c in state.canvasList)
        if (!c.isNotebook &&
            !c.isLinksBoard &&
            !c.isCalendarInk &&
            !c.isComponents)
          c,
    ];
    final current = state.canvas;
    final choice = await showPhoneSheet<String>(
      context,
      eyebrow: maps.length == 1 ? '1 mindmap' : '${maps.length} mindmaps',
      children: (c) => [
        for (final m in maps)
          SheetItem(
            label: m.title.isEmpty ? 'Untitled' : m.title,
            hint: m.id == current?.id ? 'Open now' : null,
            onTap: () => Navigator.pop(c, 'open:${m.id}'),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Hairline(
            inset: PhoneSpace.margin,
            endInset: PhoneSpace.margin,
          ),
        ),
        SheetItem(label: 'New mindmap', onTap: () => Navigator.pop(c, 'new')),
        if (current != null) ...[
          SheetItem(label: 'Rename', onTap: () => Navigator.pop(c, 'rename')),
          SheetItem(
            label: 'Move to trash',
            color: NewColors.danger,
            onTap: () => Navigator.pop(c, 'delete'),
          ),
        ],
      ],
    );
    if (!context.mounted || choice == null) return;
    if (choice.startsWith('open:')) {
      await state.openCanvas(choice.substring(5));
    } else if (choice == 'new') {
      await state.createCanvas();
    } else if (current != null) {
      await runCanvasOption(context, state, current, choice);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final title = state.canvas?.title ?? '';
        return Column(
          children: [
            Container(
              padding: EdgeInsets.only(
                top: MediaQuery.paddingOf(context).top,
                left: PhoneSpace.margin,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: NewColors.border.withValues(alpha: 0.7),
                  ),
                ),
              ),
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Expanded(
                      child: Press(
                        onTap: () => _maps(context),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'MINDMAP',
                              style: PhoneType.eyebrow.copyWith(
                                fontSize: AppType.sizeMicro,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    title.isEmpty ? 'Untitled' : title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: PhoneType.title.copyWith(
                                      fontSize: AppType.sizeTitle,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 20,
                                  color: NewColors.textFaint,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    PhoneMoreButtons(state: state, tab: PhoneTabKind.map),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ClipRect(child: CanvasPage(state: state)),
            ),
          ],
        );
      },
    );
  }
}
