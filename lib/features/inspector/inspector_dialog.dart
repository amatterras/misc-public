// Workspace Health Inspector window: scan, list findings (confirmed
// problems apart from warnings), preview and confirm each repair.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import 'workspace_inspector.dart';

Future<void> showWorkspaceInspector(
  BuildContext context,
  AppState state, {
  Future<InspectionReport> Function(AppState)? scanner,
}) => showAppDialog<void>(
  context: context,
  builder: (_) => WorkspaceInspectorDialog(
    state: state,
    scanner: scanner ?? inspectWorkspace,
  ),
);

class WorkspaceInspectorDialog extends StatefulWidget {
  const WorkspaceInspectorDialog({
    super.key,
    required this.state,
    this.scanner = inspectWorkspace,
  });
  final AppState state;

  /// How the workspace is scanned (replaceable in tests).
  final Future<InspectionReport> Function(AppState) scanner;

  @override
  State<WorkspaceInspectorDialog> createState() => _InspectorState();
}

class _InspectorState extends State<WorkspaceInspectorDialog> {
  InspectionReport? _report;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final r = await widget.scanner(widget.state);
    if (mounted) {
      setState(() {
        _report = r;
        _scanning = false;
      });
    }
  }

  /// Shows exactly what would change; runs it only on "Apply".
  Future<void> _preview(RepairPlan plan) async {
    final go = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('repair-preview'),
        title: Text(plan.label, style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _labeled('NOW', plan.before),
              const SizedBox(height: AppSpace.md),
              _labeled('AFTER', plan.after),
              if (plan.note.isNotEmpty) ...[
                const SizedBox(height: AppSpace.md),
                Text(
                  plan.note,
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('repair-apply'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (go != true) return;
    final done = await plan.apply();
    widget.state.showToast(
      done ? 'Done.' : 'Nothing was changed: the data is different now.',
    );
    await _scan();
  }

  Widget _labeled(String label, String text) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 0.5,
          color: AppColors.textFaint,
        ),
      ),
      const SizedBox(height: 2),
      SelectableText(text, style: const TextStyle(fontSize: 13)),
    ],
  );

  Widget _finding(InspectorFinding f) {
    final problem = f.level == FindingLevel.problem;
    final color = problem ? AppColors.danger : AppColors.warm;
    return Padding(
      key: ValueKey('finding-${f.code}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            problem ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.where,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  f.impact,
                  style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
                ),
                if (f.repairs.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final r in f.repairs)
                        TextButton(
                          onPressed: () => _preview(r),
                          child: Text(
                            r.label,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return AlertDialog(
      key: const ValueKey('workspace-inspector'),
      title: const Text('Workspace health', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 600,
        height: 460,
        child: r == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: [
                  Text(
                    r.clean
                        ? 'No problems found (${r.checked} items checked).'
                        : '${r.problems.length} problem(s) and '
                              '${r.warnings.length} warning(s) '
                              '(${r.checked} items checked).',
                    key: const ValueKey('inspector-summary'),
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Checked on this device only. Nothing is changed unless '
                    'you approve a repair after seeing what it does.',
                    style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                  ),
                  if (r.problems.isNotEmpty) ...[
                    const SizedBox(height: AppSpace.md),
                    _heading('CONFIRMED PROBLEMS'),
                    for (final f in r.problems) _finding(f),
                  ],
                  if (r.warnings.isNotEmpty) ...[
                    const SizedBox(height: AppSpace.md),
                    _heading('WARNINGS'),
                    for (final f in r.warnings) _finding(f),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton.icon(
          key: const ValueKey('inspector-rescan'),
          onPressed: _scanning ? null : _scan,
          icon: const Icon(Icons.refresh, size: 16),
          label: Text(_scanning ? 'Scanning…' : 'Scan again'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _heading(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text(
      t,
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 0.5,
        color: AppColors.textFaint,
      ),
    ),
  );
}
