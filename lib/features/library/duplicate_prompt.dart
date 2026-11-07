// The small "Already in Archive" popup shown when a save repeats an item
// that is already saved. Advisory only: the user can open the existing item,
// save another copy anyway, or cancel. Nothing existing is changed.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/library_models.dart' show displayUrl;
import '../../data/models/object_library_models.dart';
import '../../data/repositories/library_repository.dart';
import '../../new_ui/new_archive_page.dart' show openArchiveItem;
import '../links/link_tags.dart';

/// Asks what to do about [dup]. Escape, a tap outside or Cancel: cancel.
Future<DuplicateChoice> showArchiveDuplicatePrompt(
  BuildContext context,
  AppState state,
  ArchiveDuplicate dup,
) async {
  final choice = await showDialog<DuplicateChoice>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.12),
    builder: (context) => ArchiveDuplicateCard(state: state, duplicate: dup),
  );
  return choice ?? DuplicateChoice.cancel;
}

/// Asks about [dup] (nothing to ask when null) and acts on the answer.
/// Returns true when the caller should save a new item ("Save anyway");
/// false when it should save nothing (Cancel, or the existing item was
/// opened). [beforeOpen] runs before the existing item opens (e.g. to close
/// the dialog the save started from).
Future<bool> proceedDespiteArchiveDuplicate(
  BuildContext context,
  AppState state,
  ArchiveDuplicate? dup, {
  VoidCallback? beforeOpen,
}) async {
  if (dup == null) return true;
  final choice = await showArchiveDuplicatePrompt(context, state, dup);
  switch (choice) {
    case DuplicateChoice.saveAnyway:
      return true;
    case DuplicateChoice.cancel:
      return false;
    case DuplicateChoice.openExisting:
      final hostOpen = state.openArchiveObject;
      final canUseContext = context.mounted;
      beforeOpen?.call();
      if (hostOpen != null) {
        hostOpen(dup.existing.id);
      } else if (canUseContext && context.mounted) {
        await openArchiveItem(context, state, dup.existing.id);
      }
      return false;
  }
}

/// The popup's card (public for tests).
class ArchiveDuplicateCard extends StatelessWidget {
  const ArchiveDuplicateCard({
    super.key,
    required this.state,
    required this.duplicate,
  });

  final AppState state;
  final ArchiveDuplicate duplicate;

  static String headline(ArchiveDuplicate d) =>
      d.certain ? 'Already in Archive' : 'Possibly already in Archive';

  static String explanation(ArchiveDuplicate d) => switch (d.reason) {
    DuplicateReason.sameLink => 'This link has been saved before.',
    DuplicateReason.sameFile =>
      'A file with exactly the same content has been saved before.',
    DuplicateReason.sameText => 'The same text has been saved before.',
    DuplicateReason.sameNameAndSize =>
      'A file with the same name and size has been saved before. '
          'It may still be different.',
  };

  static String titleOf(LibraryObject o) {
    if (o.title.trim().isNotEmpty) return o.title.trim();
    final url = o.sourceUrl ?? o.canonicalUrl;
    if (url != null) return displayUrl(url);
    return 'Untitled';
  }

  /// "Resource · Travel · saved 3 Nov 2026": categories, folders, date.
  static String detailsOf(AppState state, LibraryObject o) {
    final ws = state.workspace;
    final categories = LinkTag.of(state.library.categoriesOf(o.id))
        .map((t) => t.label);
    final folders = <String>{
      for (final r in ws.libraryRelations.all)
        if (r.kind == 'space' && r.objectId == o.id)
          if (ws.librarySpaces[r.targetId] case final space?)
            if (space.kind == LibrarySpaceKind.regular &&
                space.name.trim().isNotEmpty)
              space.name.trim(),
    };
    final when = (o.lastSavedAt ?? o.createdAt).toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return [
      ...categories,
      ...folders,
      'saved ${when.day} ${months[when.month - 1]} ${when.year}',
    ].join(' · ');
  }

  static IconData iconOf(LibraryObjectType type) => switch (type) {
    LibraryObjectType.image => Icons.image_outlined,
    LibraryObjectType.article => Icons.article_outlined,
    LibraryObjectType.website => Icons.language,
    LibraryObjectType.document => Icons.picture_as_pdf_outlined,
    LibraryObjectType.note => Icons.notes,
    _ => Icons.inventory_2_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final o = duplicate.existing;
    return Dialog(
      backgroundColor: AppColors.cardRaised,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                headline(duplicate),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                explanation(duplicate),
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              const SizedBox(height: 12),
              Material(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  key: const ValueKey('duplicate-existing'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () =>
                      Navigator.pop(context, DuplicateChoice.openExisting),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          iconOf(o.type),
                          size: 18,
                          color: AppColors.textMuted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                titleOf(o),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.text,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                detailsOf(state, o),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(context, DuplicateChoice.cancel),
                    child: Text(
                      'Cancel',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(context, DuplicateChoice.saveAnyway),
                    child: const Text('Save anyway'),
                  ),
                  FilledButton(
                    autofocus: true,
                    onPressed: () =>
                        Navigator.pop(context, DuplicateChoice.openExisting),
                    child: const Text('Open existing'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
