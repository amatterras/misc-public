import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models/task_estimate.dart';
import '../../data/models/task_models.dart';

/// A task's time estimate as a small clock and "45 min", secondary to its
/// title and deadline. Nothing at all when the task has no estimate.
class EstimateLabel extends StatelessWidget {
  const EstimateLabel({super.key, required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    final minutes = task.estimateMinutes;
    if (minutes == null) return const SizedBox.shrink();
    final color = AppColors.textFaint;
    return Semantics(
      label: 'Estimated ${formatEstimate(minutes)}',
      excludeSemantics: true,
      child: Row(
        key: ValueKey('task-estimate-${task.id}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            formatEstimate(minutes),
            style: TextStyle(fontSize: AppType.sizeMeta, color: color),
          ),
        ],
      ),
    );
  }
}
