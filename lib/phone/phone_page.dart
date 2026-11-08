// A full-screen page pushed over the phone shell (a task, a folder, a full
// desktop page). One slim bar with a Back arrow, nothing else of its own.
import 'package:flutter/material.dart';

import '../new_ui/new_components.dart' show NewAtmosphere;
import '../app/theme.dart';
import 'phone_tokens.dart';
import 'phone_widgets.dart';

class PhonePage extends StatelessWidget {
  const PhonePage({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
    this.eyebrow,
  });

  final String title;
  final String? eyebrow;
  final Widget child;
  final List<Widget> actions;

  @override
  // Transparent: [pushPhone] puts the atmosphere behind every pushed page.
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: Column(
      children: [
        Container(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: AppColors.border.withValues(alpha: 0.7),
              ),
            ),
          ),
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                GlyphButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  label: 'Back',
                  size: 19,
                  color: AppColors.text,
                  onTap: () => Navigator.maybePop(context),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (eyebrow != null)
                        Text(
                          eyebrow!.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: PhoneType.eyebrow.copyWith(
                            fontSize: AppType.sizeMicro,
                          ),
                        ),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PhoneType.row.copyWith(fontSize: 17),
                      ),
                    ],
                  ),
                ),
                ...actions,
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
        Expanded(child: child),
      ],
    ),
  );
}

/// Pushes [page] with the standard iOS slide, on its own copy of the
/// app-wide atmosphere (a pushed route is outside the shell's field).
Future<T?> pushPhone<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(
      MaterialPageRoute<T>(builder: (_) => NewAtmosphere.behind(child: page)),
    );
