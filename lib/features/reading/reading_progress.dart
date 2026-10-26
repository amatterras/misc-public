// Reading progress for Archive items: mark a PDF or a saved link as to read,
// reading or finished, keep the last page, jump back in with one click, and
// follow optional weekly goals the reader sets. All of it lives in the
// item's own record (Asset.reading): one reading record per item, no
// copies, saved and synced with the item. Goals are targets to look at;
// nothing here sets a deadline or puts anything on the Calendar.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/library_models.dart';
import '../../data/models/reading_models.dart';
import '../../data/models/record.dart' show dayKey;
import '../../data/workspace.dart';
import '../../widgets/common.dart' show confirm, promptText;
import '../pdfanchors/pdf_anchors.dart';
import '../smartlinks/smart_links.dart';

// ------------------------------------------------------------------ logic --

/// Items the reader keeps track of, newest activity first.
List<Asset> readingItems(Workspace ws) =>
    ws.assets.all.where((a) => a.reading != null).toList()..sort(
      (a, b) => (b.reading!.updatedAt ?? b.updatedAt).compareTo(
        a.reading!.updatedAt ?? a.updatedAt,
      ),
    );

/// Whether [a] can be read and tracked (a PDF or a saved link).
bool canTrackReading(Asset a) =>
    a.kind == AssetKind.document || a.kind == AssetKind.link;

/// Starts keeping track of [assetId]. Asking again changes nothing: there is
/// one reading record per item.
Asset? startReading(Workspace ws, String assetId, {ReadState? state}) {
  final a = ws.assets[assetId];
  if (a == null || !canTrackReading(a)) return null;
  if (a.reading != null) {
    if (state != null && a.reading!.state != state) {
      return setReadState(ws, assetId, state);
    }
    return a;
  }
  ws.assets.put(
    a.copyWith(
      reading: () => ReadingProgress(
        state: state ?? ReadState.reading,
        updatedAt: DateTime.now(),
      ),
    ),
  );
  return ws.assets[assetId];
}

Asset? setReadState(Workspace ws, String assetId, ReadState state) {
  final a = ws.assets[assetId];
  final r = a?.reading;
  if (a == null || r == null || r.state == state) return a;
  ws.assets.put(
    a.copyWith(
      reading: () => r.copyWith(
        state: state,
        // Finished: the last page is the end, when the length is known.
        page: state == ReadState.done && r.totalPages != null
            ? r.totalPages
            : null,
      ),
    ),
  );
  return ws.assets[assetId];
}

/// Sets the page the reader is on (no reading is logged: this is just
/// where they are).
Asset? setReadPage(Workspace ws, String assetId, int page) {
  final a = ws.assets[assetId];
  final r = a?.reading;
  if (a == null || r == null) return a;
  var p = page < 1 ? 1 : page;
  if (r.totalPages != null && p > r.totalPages!) p = r.totalPages!;
  if (p == r.page) return a;
  ws.assets.put(a.copyWith(reading: () => r.copyWith(page: p)));
  return ws.assets[assetId];
}

/// Notes that the reader is now on [page] of PDF [assetId] (when they look at
/// it in the PDF window). Only for items already being read.
void noteReadPage(Workspace ws, String assetId, int page) {
  final r = ws.assets[assetId]?.reading;
  if (r != null && r.state == ReadState.reading) {
    setReadPage(ws, assetId, page);
  }
}

/// Records a reading session of [pages] pages today: the page moves on, the
/// pages and the session are added to today's log.
Asset? logReading(
  Workspace ws,
  String assetId,
  int pages, {
  DateTime? at,
}) {
  final a = ws.assets[assetId];
  final r = a?.reading;
  if (a == null || r == null || pages < 0) return a;
  final day = dayKey(at ?? DateTime.now());
  var page = r.page + pages;
  if (r.totalPages != null && page > r.totalPages!) page = r.totalPages!;
  ws.assets.put(
    a.copyWith(
      reading: () => r.copyWith(
        state: r.state == ReadState.unread ? ReadState.reading : r.state,
        page: page,
        log: pages > 0 ? {...r.log, day: (r.log[day] ?? 0) + pages} : r.log,
        sessions: {...r.sessions, day: (r.sessions[day] ?? 0) + 1},
      ),
    ),
  );
  return ws.assets[assetId];
}

Asset? setReadLength(Workspace ws, String assetId, int? totalPages) {
  final a = ws.assets[assetId];
  final r = a?.reading;
  if (a == null || r == null) return a;
  final total = totalPages != null && totalPages > 0 ? totalPages : null;
  ws.assets.put(
    a.copyWith(
      reading: () => r.copyWith(
        totalPages: () => total,
        page: total != null && r.page > total ? total : null,
      ),
    ),
  );
  return ws.assets[assetId];
}

/// The reader's own weekly targets for an item (null clears one).
Asset? setReadGoals(Workspace ws, String assetId, {int? pages, int? sessions}) {
  final a = ws.assets[assetId];
  final r = a?.reading;
  if (a == null || r == null) return a;
  ws.assets.put(
    a.copyWith(
      reading: () => r.copyWith(
        goalPages: () => pages != null && pages > 0 ? pages : null,
        goalSessions: () => sessions != null && sessions > 0 ? sessions : null,
      ),
    ),
  );
  return ws.assets[assetId];
}

/// Stops tracking [assetId]; the item itself is untouched.
void stopReading(Workspace ws, String assetId) {
  final a = ws.assets[assetId];
  if (a?.reading != null) ws.assets.put(a!.copyWith(reading: () => null));
}

/// Continues [assetId] where the reader stopped: a PDF at its last page, a
/// link on its page. False when it could not be opened (the reason is
/// shown).
Future<bool> resumeReading(AppState s, String assetId) async {
  final a = s.workspace.assets[assetId];
  final r = a?.reading;
  if (a == null || r == null) return false;
  final ok = a.kind == AssetKind.document
      ? await openPdfAnchor(s, WorkspaceRef(RefKind.pdf, a.id, '${r.page}'))
      : await _openLink(s, a);
  if (ok && r.state == ReadState.unread) {
    setReadState(s.workspace, a.id, ReadState.reading);
  }
  return ok;
}

Future<bool> _openLink(AppState s, Asset a) async {
  final url = a.url;
  if (url == null) return false;
  if (s.urlOpener != null) {
    s.urlOpener!(url);
    return true;
  }
  if (await s.openLinkCard(a.id)) return true;
  s.openInSafari(url);
  return true;
}

/// The item to resume by default: the one read most recently.
Asset? latestReading(Workspace ws) => readingItems(ws)
    .where((a) => a.reading!.state == ReadState.reading)
    .firstOrNull;

/// What the overview shows.
class ReadingOverviewData {
  const ReadingOverviewData(this.reading, this.toRead, this.done, this.goals);
  final List<Asset> reading;
  final List<Asset> toRead;
  final List<Asset> done;

  /// Items with a goal, with this week's pages and sessions.
  final List<(Asset, ({int pages, int sessions}))> goals;
}

ReadingOverviewData readingOverview(Workspace ws, DateTime now) {
  final items = readingItems(ws);
  List<Asset> of(ReadState s) =>
      [for (final a in items) if (a.reading!.state == s) a];
  return ReadingOverviewData(
    of(ReadState.reading),
    of(ReadState.unread),
    of(ReadState.done),
    [
      for (final a in items)
        if (a.reading!.state != ReadState.done &&
            (a.reading!.goalPages != null || a.reading!.goalSessions != null))
          (a, a.reading!.week(now)),
    ],
  );
}

// --------------------------------------------------------------------- UI --

/// Opens the reading overview.
Future<void> showReadingOverview(BuildContext context, AppState s) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ReadingOverview(state: s),
    );

class _ReadingOverview extends StatelessWidget {
  const _ReadingOverview({required this.state});
  final AppState state;

  Workspace get ws => state.workspace;

  String _ago(DateTime? t) {
    if (t == null) return '';
    final days = DateTime.now().difference(t).inDays;
    return days <= 0 ? 'today' : days == 1 ? 'yesterday' : '$days days ago';
  }

  Future<int?> _askNumber(BuildContext context, String title, {int? initial}) async {
    final text = await promptText(
      context,
      title: title,
      initial: initial?.toString() ?? '',
      hint: 'A whole number (empty to clear)',
      action: 'Save',
    );
    if (text == null) return null;
    final t = text.trim();
    if (t.isEmpty) return 0;
    return int.tryParse(t);
  }

  Future<void> _add(BuildContext context) async {
    final choices = [
      for (final a in ws.assets.all)
        if (canTrackReading(a) && a.reading == null) a,
    ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    final pick = await showDialog<Asset>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add to your reading', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 440,
          height: 340,
          child: choices.isEmpty
              ? const Center(child: Text('Every PDF and saved link is already here.'))
              : ListView(
                  children: [
                    for (final a in choices)
                      ListTile(
                        key: ValueKey('reading-pick-${a.id}'),
                        dense: true,
                        leading: Icon(
                          a.kind == AssetKind.document
                              ? Icons.picture_as_pdf_outlined
                              : Icons.link,
                          size: 18,
                        ),
                        title: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(context, a),
                      ),
                  ],
                ),
        ),
      ),
    );
    if (pick != null) startReading(ws, pick.id);
  }

  Widget _row(BuildContext context, Asset a) {
    final r = a.reading!;
    final frac = r.fraction;
    return Padding(
      key: ValueKey('reading-row-${a.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                a.kind == AssetKind.document ? Icons.picture_as_pdf_outlined : Icons.link,
                size: 16,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              TextButton(
                key: ValueKey('resume-${a.id}'),
                onPressed: () async {
                  final ok = await resumeReading(state, a.id);
                  if (ok && context.mounted) Navigator.pop(context);
                },
                child: const Text('Resume'),
              ),
              PopupMenuButton<String>(
                key: ValueKey('reading-menu-${a.id}'),
                padding: EdgeInsets.zero,
                onSelected: (v) async {
                  switch (v) {
                    case 'read':
                      final n = await _askNumber(context, 'Pages read just now');
                      if (n != null && n > 0) logReading(ws, a.id, n);
                    case 'page':
                      final n = await _askNumber(context, 'Now on page', initial: r.page);
                      if (n != null && n > 0) setReadPage(ws, a.id, n);
                    case 'length':
                      final n = await _askNumber(context, 'How many pages in total?', initial: r.totalPages);
                      if (n != null) setReadLength(ws, a.id, n);
                    case 'goals':
                      final p = await _askNumber(context, 'Pages per week (empty: none)', initial: r.goalPages);
                      if (p == null || !context.mounted) return;
                      final q = await _askNumber(context, 'Sessions per week (empty: none)', initial: r.goalSessions);
                      if (q != null) setReadGoals(ws, a.id, pages: p, sessions: q);
                    case 'done':
                      setReadState(ws, a.id, ReadState.done);
                    case 'unread':
                      setReadState(ws, a.id, ReadState.unread);
                    case 'reading':
                      setReadState(ws, a.id, ReadState.reading);
                    case 'stop':
                      if (await confirm(
                        context,
                        title: 'Stop tracking “${a.label}”?',
                        message: 'Your page and reading log for it are removed. The item itself stays in the Archive.',
                      )) {
                        stopReading(ws, a.id);
                      }
                  }
                },
                itemBuilder: (_) => [
                  if (a.kind == AssetKind.document) ...[
                    const PopupMenuItem(value: 'read', child: Text('I read some pages…')),
                    const PopupMenuItem(value: 'page', child: Text('Set my page…')),
                    const PopupMenuItem(value: 'length', child: Text('Set its length…')),
                  ],
                  const PopupMenuItem(value: 'goals', child: Text('Weekly goals…')),
                  if (r.state != ReadState.reading)
                    const PopupMenuItem(value: 'reading', child: Text('Mark as reading')),
                  if (r.state != ReadState.done)
                    const PopupMenuItem(value: 'done', child: Text('Mark as completed')),
                  if (r.state != ReadState.unread)
                    const PopupMenuItem(value: 'unread', child: Text('Mark as unread')),
                  const PopupMenuItem(value: 'stop', child: Text('Stop tracking…')),
                ],
              ),
            ],
          ),
          if (frac != null)
            Padding(
              padding: const EdgeInsets.only(left: 24, right: 8, top: 2),
              child: LinearProgressIndicator(value: frac, minHeight: 4),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 2),
            child: Text(
              [
                if (a.kind == AssetKind.document)
                  r.totalPages == null
                      ? 'page ${r.page}'
                      : 'page ${r.page} of ${r.totalPages}',
                if (r.updatedAt != null) 'last ${_ago(r.updatedAt)}',
              ].join('  ·  '),
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ws.changes,
      builder: (context, _) {
        final data = readingOverview(ws, DateTime.now());
        final heading = TextStyle(fontSize: 11, letterSpacing: 0.6, color: AppColors.textFaint);
        Widget section(String title, List<Asset> items) => items.isEmpty
            ? const SizedBox.shrink()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Text(title, style: heading),
                  for (final a in items) _row(context, a),
                ],
              );
        final latest = latestReading(ws);
        return AlertDialog(
          key: const ValueKey('reading-overview'),
          title: Row(
            children: [
              const Expanded(
                child: Text('Reading', style: TextStyle(fontSize: 16)),
              ),
              if (latest != null)
                FilledButton.icon(
                  key: const ValueKey('resume-latest'),
                  onPressed: () async {
                    final ok = await resumeReading(state, latest.id);
                    if (ok && context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Resume reading'),
                ),
            ],
          ),
          content: SizedBox(
            width: 520,
            height: 440,
            child: data.reading.isEmpty &&
                    data.toRead.isEmpty &&
                    data.done.isEmpty
                ? Center(
                    child: Text(
                      'Nothing tracked yet. Add a PDF or a saved link to keep your place in it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textFaint),
                    ),
                  )
                : ListView(
                    children: [
                      Text(
                        '${data.reading.length} reading  ·  ${data.toRead.length} to read  ·  ${data.done.length} completed',
                        key: const ValueKey('reading-counts'),
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                      section('READING NOW', data.reading),
                      if (data.goals.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text('YOUR GOALS THIS WEEK', style: heading),
                        for (final (a, w) in data.goals)
                          Padding(
                            key: ValueKey('goal-${a.id}'),
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              '${a.label}:  '
                              '${[
                                if (a.reading!.goalPages != null) '${w.pages} of ${a.reading!.goalPages} pages',
                                if (a.reading!.goalSessions != null) '${w.sessions} of ${a.reading!.goalSessions} sessions',
                              ].join('  ·  ')}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                      ],
                      section('TO READ', data.toRead),
                      section('COMPLETED', data.done),
                    ],
                  ),
          ),
          actions: [
            TextButton.icon(
              key: const ValueKey('reading-add'),
              onPressed: () => _add(context),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add a PDF or link…'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}
