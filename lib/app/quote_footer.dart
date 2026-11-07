// The motivational quote: one quiet line in the bottom-right corner of the
// workspace, in both interfaces. It sits in its own slim strip under the page
// (so it never covers a control), ignores touches, and is deliberately
// faint. The text and the quote service are the same as before; only the
// place changed (it used to be in the sidebar / above the phone tabs).
import 'package:flutter/material.dart';

import '../features/motivation/motivation_service.dart';
import 'theme.dart';

class QuoteFooter extends StatelessWidget {
  const QuoteFooter({super.key, required this.service});

  final MotivationService service;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final quote = service.quote;
      if (quote == null) return const SizedBox.shrink();
      final text = quote.attribution.isEmpty
          ? '“${quote.text}”'
          : '“${quote.text}”  ${quote.attribution}';
      return IgnorePointer(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (MediaQuery.sizeOf(context).width * 0.6).clamp(
                  160.0,
                  440.0,
                ),
              ),
              child: Text(
                text,
                key: const ValueKey('motivational-quote'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: AppType.sizeMeta,
                  height: 1.3,
                  fontStyle: FontStyle.italic,
                  color: AppColors.textFaint.withValues(alpha: 0.65),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
