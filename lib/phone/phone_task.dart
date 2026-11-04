// A task on the phone: the existing task details (title, notes, subtasks,
// due date, labels, repeat, reminder) on a full page with a Back arrow.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../features/tasks/tasks_page.dart' show TaskDetail;
import 'phone_page.dart';

Future<void> openPhoneTask(BuildContext context, AppState state, String id) {
  if (state.workspace.tasks[id] == null) return Future.value();
  return pushPhone<void>(
    context,
    PhonePage(
      eyebrow: 'Task',
      title: state.workspace.tasks[id]!.title,
      child: TaskDetail(
        state: state,
        taskId: id,
        onClose: () => Navigator.of(context).maybePop(),
      ),
    ),
  );
}
