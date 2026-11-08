// Line-by-line comparison of two versions of a note, shown side by side.
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/library_models.dart';
import '../../widgets/common.dart';

enum LineChange { same, removed, added }

/// For each line of [before] and [after]: whether it is unchanged, only in
/// [before] (removed) or only in [after] (added). Longest common
/// subsequence of lines, so moved blocks show as removed + added.
({List<LineChange> before, List<LineChange> after}) diffLines(
  List<String> before,
  List<String> after,
) {
  final n = before.length, m = after.length;
  final lcs = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = before[i] == after[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] > lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final a = List.filled(n, LineChange.removed);
  final b = List.filled(m, LineChange.added);
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (before[i] == after[j]) {
      a[i++] = LineChange.same;
      b[j++] = LineChange.same;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return (before: a, after: b);
}

Future<void> showVersionComparison(
  BuildContext context,
  NoteVersion version,
  Note current,
) {
  final before = [version.title, '', ...version.body.split('\n')];
  final after = [current.title, '', ...current.body.split('\n')];
  final diff = diffLines(before, after);
  Widget column(String heading, List<String> lines, List<LineChange> marks) =>
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              heading,
              style: TextStyle(
                fontSize: AppType.sizeLabel,
                fontWeight: FontWeight.w600,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            for (var i = 0; i < lines.length; i++)
              Container(
                width: double.infinity,
                color: switch (marks[i]) {
                  LineChange.same => null,
                  LineChange.removed => AppColors.warm.withValues(alpha: 0.16),
                  LineChange.added => AppColors.accent.withValues(alpha: 0.18),
                },
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: Text(
                  lines[i].isEmpty ? ' ' : lines[i],
                  style: TextStyle(
                    fontSize: AppType.sizeBodySmall,
                    fontWeight: i == 0 ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
          ],
        ),
      );
  return showAppDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text(
        'Compare versions',
        style: TextStyle(fontSize: AppType.sizeHeading),
      ),
      content: SizedBox(
        width: 820,
        height: 480,
        child: SingleChildScrollView(
          child: Row(
            key: const ValueKey('version-compare'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              column(
                'Version of ${formatShortDate(version.savedAt)}',
                before,
                diff.before,
              ),
              const SizedBox(width: AppSpace.lg),
              column('Now', after, diff.after),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
