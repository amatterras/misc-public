// Asks where the export is, imports it, and shows exactly what was and
// was not imported.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/platform.dart' as native;
import 'note_import.dart';

Future<void> showImportDialog(BuildContext context, AppState s) async {
  var source = ImportSource.obsidian;
  final path = TextEditingController();
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Import notes', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButton<ImportSource>(
                isExpanded: true,
                value: source,
                items: [
                  for (final v in ImportSource.values)
                    DropdownMenuItem(value: v, child: Text(v.label)),
                ],
                onChanged: (v) => setState(() => source = v ?? source),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('import-path'),
                      controller: path,
                      decoration: const InputDecoration(
                        labelText: 'Folder',
                        hintText: r'C:\Users\you\Documents\Vault',
                      ),
                    ),
                  ),
                  if (Platform.isWindows)
                    TextButton(
                      onPressed: () {
                        final picked = native.pickFolder(
                          'Choose the folder to import',
                        );
                        if (picked != null) setState(() => path.text = picked);
                      },
                      child: const Text('Browse…'),
                    ),
                ],
              ),
              const SizedBox(height: Space.sm),
              const Text(
                'Files are only read, never changed. Notion: unzip the '
                'export first. Apple Notes has no export of its own: export '
                'notes as HTML or text files (e.g. with an exporter app), '
                'then import that folder. Importing again skips notes that '
                'are already here.',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('import-go'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Import'),
          ),
        ],
      ),
    ),
  );
  final dir = path.text.trim();
  path.dispose();
  if (go != true || dir.isEmpty || !context.mounted) return;
  final report = await importNotes(s.workspace, Directory(dir), source: source);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Import finished', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 480,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(report.summary, key: const ValueKey('import-summary')),
            if (report.notImported.isNotEmpty) ...[
              const SizedBox(height: Space.md),
              const Text(
                'Not imported:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final line in report.notImported.take(50))
                Text(line, style: const TextStyle(fontSize: 12)),
              if (report.notImported.length > 50)
                Text('… and ${report.notImported.length - 50} more'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
