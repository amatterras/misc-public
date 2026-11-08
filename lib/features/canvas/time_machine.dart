// The Time Machine window for a mindmap: a timeline of its saved versions
// (automatic and named) with what changed, a preview of the one picked,
// and an explicit Restore button. Looking never changes anything; a restore
// first keeps the current state as its own version.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/canvas_ops.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart' show formatShortDate;
import 'canvas_controller.dart';

Future<void> showCanvasVersions(
  BuildContext context,
  AppState s,
  CanvasController c,
) async {
  await c.flush();
  final list = await s.snapshotsOf(c.id);
  if (!context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (_) => _TimeMachine(state: s, canvas: c, versions: list),
  );
}

class _TimeMachine extends StatefulWidget {
  const _TimeMachine({
    required this.state,
    required this.canvas,
    required this.versions,
  });

  final AppState state;
  final CanvasController canvas;
  final List<CanvasSnapshot> versions;

  @override
  State<_TimeMachine> createState() => _TimeMachineState();
}

class _TimeMachineState extends State<_TimeMachine> {
  CanvasSnapshot? _picked;
  Uint8List? _preview;
  String? _restoring; // what restoring would change
  bool _loading = false;
  bool _busy = false;
  String? _message;

  AppState get s => widget.state;

  String _when(DateTime t) =>
      '${formatShortDate(t)} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pick(CanvasSnapshot v) async {
    setState(() {
      _picked = v;
      _preview = null;
      _restoring = null;
      _loading = !v.damaged;
      _message = v.damaged ? 'This version is damaged and cannot be used.' : null;
    });
    if (v.damaged) return;
    final png = await s.snapshotPreview(v.key);
    final summary = await s.restoreSummary(widget.canvas, v.key);
    if (!mounted || _picked?.key != v.key) return;
    setState(() {
      _preview = png;
      _restoring = summary;
      _loading = false;
    });
  }

  Future<void> _restore() async {
    final v = _picked;
    if (v == null || _busy) return;
    setState(() => _busy = true);
    final ok = await s.restoreSnapshot(widget.canvas, v.key);
    if (!mounted) return;
    if (ok) {
      s.showToast(
        'Restored “${v.name}”. Your earlier state is kept as a version, and Undo takes it back.',
      );
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _message =
            'Could not restore. Nothing was changed (the version could not be read, or your current state could not be kept first).';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.versions;
    return AlertDialog(
      key: const ValueKey('time-machine'),
      title: const Text('Time Machine', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 640,
        height: 420,
        child: list.isEmpty
            ? Text(
                'No versions yet. One is made automatically after changes '
                '(at most every 15 minutes), or choose “Save a version…” '
                'on the empty canvas.',
                style: TextStyle(color: AppColors.textFaint),
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 260,
                    child: ListView(
                      children: [
                        for (final v in list)
                          ListTile(
                            key: ValueKey('version-${v.key}'),
                            dense: true,
                            selected: _picked?.key == v.key,
                            leading: Icon(
                              v.damaged
                                  ? Icons.warning_amber
                                  : v.auto
                                  ? Icons.history
                                  : Icons.bookmark_outline,
                              size: 18,
                            ),
                            title: Text(
                              v.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${_when(v.savedAt)}\n'
                              '${v.damaged ? 'Damaged' : v.summary.isEmpty ? '${v.itemCount} items' : v.summary}',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                            isThreeLine: true,
                            onTap: () => _pick(v),
                          ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 24),
                  Expanded(child: _detail()),
                ],
              ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(
            'Kept on this device only. Newest ${TimeMachine.maxAuto} automatic '
            'and ${TimeMachine.maxNamed} named versions.',
            style: TextStyle(fontSize: 11, color: AppColors.textFaint),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton(
          key: const ValueKey('time-machine-restore'),
          onPressed: _picked == null || _picked!.damaged || _busy ? null : _restore,
          child: const Text('Restore this version'),
        ),
      ],
    );
  }

  Widget _detail() {
    final v = _picked;
    if (v == null) {
      return Center(
        child: Text(
          'Pick a version to look at it.\nNothing changes until you restore.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textFaint),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(v.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(
          _when(v.savedAt),
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppColors.canvas,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _preview == null
                ? Center(
                    child: Text(
                      v.damaged ? 'No preview' : 'Empty canvas',
                      style: TextStyle(color: AppColors.textFaint),
                    ),
                  )
                : Image.memory(
                    _preview!,
                    key: const ValueKey('version-preview'),
                    fit: BoxFit.contain,
                  ),
          ),
        ),
        const SizedBox(height: 8),
        if (_restoring != null)
          Text(
            '$_restoring. The current state is kept as “Before restoring…”.',
            key: const ValueKey('version-effect'),
            style: const TextStyle(fontSize: 12),
          ),
        if (_message != null)
          Text(
            _message!,
            key: const ValueKey('version-message'),
            style: TextStyle(fontSize: 12, color: AppColors.warm),
          ),
      ],
    );
  }
}
