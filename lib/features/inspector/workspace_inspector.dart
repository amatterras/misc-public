// Workspace Health Inspector: finds integrity problems and says where they
// are and what they affect. It never changes anything by itself. Where a
// reliable repair exists, a [RepairPlan] describes exactly what would change
// (before / after); it only runs when the user confirms that preview.
//
// It reuses what the app already has: the read-only [IntegrityChecker], the
// smart-link resolver, the tag registry and the record collections. Nothing
// is sent anywhere.
import '../../app/app_state.dart';
import '../../data/integrity/integrity_check.dart';
import '../../data/models/canvas_models.dart';
import '../../data/models/tag_models.dart';
import '../canvas/canvas_controller.dart' show SaveState;
import '../smartlinks/smart_links.dart';

/// A confirmed problem (data is wrong or missing) or a warning (worth a
/// look, may be intended).
enum FindingLevel { problem, warning }

/// One change the user can approve after seeing it.
class RepairPlan {
  const RepairPlan({
    required this.label,
    required this.before,
    required this.after,
    required this.apply,
    this.note = '',
  });

  final String label;

  /// What is there now / what it would become (short, readable).
  final String before;
  final String after;

  /// Extra sentence about the effect (e.g. what is kept).
  final String note;

  /// Does the change. Returns false if the data changed since the scan and
  /// nothing was done.
  final Future<bool> Function() apply;
}

class InspectorFinding {
  const InspectorFinding({
    required this.code,
    required this.level,
    required this.where,
    required this.impact,
    this.repairs = const [],
  });

  final String code;
  final FindingLevel level;

  /// Where it is, in words (titles are shown on this device only).
  final String where;

  /// What it means for the user.
  final String impact;
  final List<RepairPlan> repairs;
}

class InspectionReport {
  const InspectionReport(this.findings, {required this.checked});
  final List<InspectorFinding> findings;
  final int checked;

  Iterable<InspectorFinding> get problems =>
      findings.where((f) => f.level == FindingLevel.problem);
  Iterable<InspectorFinding> get warnings =>
      findings.where((f) => f.level == FindingLevel.warning);
  bool get clean => findings.isEmpty;
  Iterable<InspectorFinding> ofCode(String code) =>
      findings.where((f) => f.code == code);
}

String _q(String t) => '“${t.trim().isEmpty ? 'untitled' : t.trim()}”';

/// A link label that cannot break the link syntax.
String safeLabel(String title) =>
    title.replaceAll(RegExp(r'[\]\r\n|]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// [text] with every link to [ref] rewritten by [change] (null leaves it).
String _rewriteLinks(
  String text,
  WorkspaceRef ref,
  String Function(LinkToken) change,
) {
  final tokens = findLinks(text).where((t) => t.ref == ref).toList();
  if (tokens.isEmpty) return text;
  var out = text;
  for (final t in tokens.reversed) {
    out = out.replaceRange(t.start, t.end, change(t));
  }
  return out;
}

String _snippet(String text, LinkToken t) {
  final from = (t.start - 30).clamp(0, text.length);
  final to = (t.end + 30).clamp(0, text.length);
  return '${from > 0 ? '…' : ''}${text.substring(from, to).replaceAll('\n', ' ')}${to < text.length ? '…' : ''}';
}

Future<InspectionReport> inspectWorkspace(AppState s) async {
  await s.flush(); // judge what is on disk, not a half-written state
  final ws = s.workspace;
  final findings = <InspectorFinding>[];

  String describe(String where) {
    final parts = where.split('/');
    final id = parts.length > 1 ? parts[1] : '';
    switch (parts.first) {
      case 'notes':
        final n = ws.notes[id];
        return n == null ? 'A note' : 'Note ${_q(n.displayTitle)}';
      case 'calendar_entries':
        final e = ws.entries[id];
        return e == null ? 'A calendar entry' : 'Calendar entry ${_q(e.name)}';
      case 'assets':
        final a = ws.assets[id];
        return a == null ? 'An Archive item' : 'Archive item ${_q(a.label)}';
      case 'tasks':
        final t = ws.tasks[id];
        return t == null ? 'A task' : 'Task ${_q(t.title)}';
      case 'canvas':
        final c = s.canvasList.where((c) => c.id == id).firstOrNull;
        final base = c == null ? 'A mindmap' : 'Mindmap ${_q(c.title)}';
        return parts.length > 2 ? '$base, one object' : base;
      default:
        return where;
    }
  }

  // 1. Everything the read-only data check already knows.
  final base = await s.checkIntegrity();
  for (final i in base.issues) {
    final repairs = <RepairPlan>[];
    if (i.code == 'dangling_connection') {
      final p = i.where.split('/');
      if (p.length == 3) repairs.add(_removeConnector(s, p[1], p[2]));
    }
    findings.add(
      InspectorFinding(
        code: i.code,
        level: i.severity == IntegritySeverity.problem
            ? FindingLevel.problem
            : FindingLevel.warning,
        where: describe(i.where),
        impact: '${i.detail} ${i.recovery}',
        repairs: repairs,
      ),
    );
  }

  // 2. Links between workspace objects.
  Future<void> scan(
    String where,
    Iterable<String> texts,
    Future<bool> Function(String Function(String) f)? edit,
  ) async {
    final seen = <WorkspaceRef>{};
    for (final text in texts) {
      for (final t in findLinks(text)) {
        if (!seen.add(t.ref)) continue;
        final r = t.ref.kind == RefKind.object
            ? await resolveObject(s, t.ref, fallbackLabel: t.label)
            : resolveRef(s, t.ref, fallbackLabel: t.label);
        if (r.health == LinkHealth.deleted) {
          findings.add(
            InspectorFinding(
              code: 'broken_link',
              level: FindingLevel.problem,
              where: describe(where),
              impact:
                  'A link to a ${t.ref.kind.noun.toLowerCase()} '
                  '(${_q(t.label.isEmpty ? r.title : t.label)}) leads nowhere '
                  'because that ${t.ref.kind.noun.toLowerCase()} is deleted. '
                  'Opening it shows a notice; it works again if the target is '
                  'restored.',
              repairs: [
                ?_restoreTarget(s, t.ref, t.label),
                if (edit != null)
                  RepairPlan(
                    label: 'Remove the link, keep the words',
                    before: _snippet(text, t),
                    after: _snippet(
                      text.replaceRange(t.start, t.end, t.label),
                      LinkToken(t.ref, t.label, t.start, t.start + t.label.length),
                    ),
                    note: 'Only this link changes; the rest of the text stays.',
                    apply: () => edit(
                      (cur) => _rewriteLinks(cur, t.ref, (x) => x.label),
                    ),
                  ),
              ],
            ),
          );
        } else if (r.health == LinkHealth.unavailable) {
          findings.add(
            InspectorFinding(
              code: 'inaccessible_document',
              level: FindingLevel.warning,
              where: describe(where),
              impact: r.preview,
            ),
          );
        } else if (r.health == LinkHealth.ok &&
            t.ref.kind != RefKind.pdf &&
            t.ref.kind != RefKind.object &&
            t.label.isNotEmpty &&
            safeLabel(r.title).isNotEmpty &&
            t.label != safeLabel(r.title)) {
          final fresh = safeLabel(r.title);
          findings.add(
            InspectorFinding(
              code: 'outdated_link_label',
              level: FindingLevel.warning,
              where: describe(where),
              impact:
                  'The link still works, but the target was renamed: the text '
                  'shows “${t.label}”, the target is now called “$fresh”.',
              repairs: [
                if (edit != null)
                  RepairPlan(
                    label: 'Show the current name',
                    before: _snippet(text, t),
                    after: _snippet(
                      text.replaceRange(
                        t.start,
                        t.end,
                        '[[theapp:${t.ref.path}|$fresh]]',
                      ),
                      LinkToken(t.ref, fresh, t.start, t.start),
                    ),
                    note: 'Only the label changes; the link target stays.',
                    apply: () => edit(
                      (cur) => _rewriteLinks(
                        cur,
                        t.ref,
                        (x) => '[[theapp:${t.ref.path}|$fresh]]',
                      ),
                    ),
                  ),
              ],
            ),
          );
        }
      }
    }
  }

  for (final n in ws.notes.all.toList()) {
    await scan('notes/${n.id}', [n.body], (f) async {
      final cur = ws.notes[n.id];
      if (cur == null) return false;
      final next = f(cur.body);
      if (next == cur.body) return false;
      ws.notes.put(cur.copyWith(body: next));
      return true;
    });
  }
  for (final e in ws.entries.all.toList()) {
    await scan('calendar_entries/${e.id}', [e.description, e.notes], (f) async {
      final cur = ws.entries[e.id];
      if (cur == null) return false;
      final d = f(cur.description), nn = f(cur.notes);
      if (d == cur.description && nn == cur.notes) return false;
      ws.entries.put(cur.copyWith(description: d, notes: nn));
      return true;
    });
  }
  for (final a in ws.assets.all.toList()) {
    await scan('assets/${a.id}', [a.description ?? '', a.title ?? ''], null);
  }
  for (final c in s.canvasList) {
    if (c.searchText.isEmpty) continue;
    await scan('canvas/${c.id}', [c.searchText], null);
  }

  // 3. Custom tags: the registry forbids two tags with the same name.
  final byName = <String, List<CustomTag>>{};
  for (final t in ws.customTags.all) {
    byName.putIfAbsent(CustomTag.keyOf(t.name), () => []).add(t);
  }
  for (final group in byName.values.where((g) => g.length > 1)) {
    group.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final dup in group.skip(1)) {
      var n = 2;
      String name() => '${dup.name} $n';
      while (ws.tagNamed(name()) != null) {
        n++;
      }
      final newName = name();
      findings.add(
        InspectorFinding(
          code: 'duplicate_tag_name',
          level: FindingLevel.problem,
          where: 'Tag ${_q(dup.name)}',
          impact:
              'Two tags are called “${dup.name}” (this can happen when two '
              'devices made the same tag). They look identical in pickers. '
              'Neither is deleted or merged.',
          repairs: [
            RepairPlan(
              label: 'Rename the newer one',
              before: dup.name,
              after: newName,
              note:
                  'Only the name changes. Everything tagged keeps its tag; '
                  'nothing is merged.',
              apply: () async {
                if (ws.customTags[dup.id] == null) return false;
                return ws.renameTag(dup.id, newName) == null;
              },
            ),
          ],
        ),
      );
    }
  }
  // Items naming a tag that no longer exists (shown nowhere).
  final tagIds = {for (final t in ws.customTags.all) t.id};
  var orphanTagRefs = 0;
  for (final a in ws.assets.all) {
    for (final r in a.linkTags) {
      final id = CustomTag.idOfAssetRef(r);
      if (id != null && !tagIds.contains(id)) orphanTagRefs++;
    }
  }
  if (orphanTagRefs > 0) {
    findings.add(
      InspectorFinding(
        code: 'unknown_tag_reference',
        level: FindingLevel.warning,
        where: 'Archive',
        impact:
            '$orphanTagRefs tag mark(s) on Archive items name a tag that no '
            'longer exists, so they show nothing. They are kept: if the tag '
            'comes back (for example by sync) they show again.',
      ),
    );
  }

  // 4. Saving: only what can be verified. After the flush above, every
  //    record on disk must match what the app holds.
  for (final entry in ws.allCollections.entries) {
    final raw = await ws.store.read('data', entry.key);
    final onDisk = <String>{
      for (final r in (raw?['records'] as List? ?? const []))
        if (r is Map && r['id'] is String) r['id'] as String,
    };
    final inMemory = entry.value.versions().where((v) => !v.deleted).map((v) => v.id).toSet();
    final unsaved = inMemory.difference(onDisk);
    if (unsaved.isNotEmpty) {
      findings.add(
        InspectorFinding(
          code: 'not_saved',
          level: FindingLevel.problem,
          where: 'Stored data: ${entry.key.replaceAll('_', ' ')}',
          impact:
              '${unsaved.length} item(s) are in the app but not in the saved '
              'file, even after saving again. They would be lost if the app '
              'closed now. Free some disk space, then use Back up now to keep '
              'a copy.',
        ),
      );
    }
  }
  final open = s.canvas;
  if (open != null && open.saveState == SaveState.failed) {
    findings.add(
      InspectorFinding(
        code: 'canvas_save_failed',
        level: FindingLevel.problem,
        where: 'Mindmap ${_q(open.title)} (open now)',
        impact:
            'The last save of this mindmap failed. Your changes are still on '
            'screen. Keep it open, free some disk space and make another '
            'change to retry.',
      ),
    );
  }

  findings.sort(
    (a, b) => a.level == b.level ? 0 : (a.level == FindingLevel.problem ? -1 : 1),
  );
  return InspectionReport(findings, checked: base.checked);
}

/// "Restore the deleted target", when the target is a record the app still
/// holds in Recently deleted.
RepairPlan? _restoreTarget(AppState s, WorkspaceRef ref, String label) {
  if (ref.kind == RefKind.note) {
    final v = s.workspace
        .deletedNotes()
        .where((d) => d.noteId == ref.id)
        .firstOrNull;
    if (v == null) return null;
    return RepairPlan(
      label: 'Restore the deleted note',
      before: 'Deleted: ${_q(v.title)}',
      after: 'Back in your notes, with its text, folder and attachments',
      note: 'Only this one note returns; the link works again.',
      apply: () async => await s.restoreDeletedNote(v.id) != null,
    );
  }
  final collection = switch (ref.kind) {
    RefKind.note => 'notes',
    RefKind.entry => 'calendar_entries',
    RefKind.asset || RefKind.pdf => 'assets',
    _ => null,
  };
  if (collection == null) return null;
  final kept = s.workspace.allCollections[collection]?.recentlyDeleted[ref.id];
  if (kept == null) return null;
  final name =
      (kept['title'] ?? kept['name'] ?? kept['body'] ?? label).toString();
  return RepairPlan(
    label: 'Restore the deleted ${ref.kind.noun.toLowerCase()}',
    before: 'Deleted: ${_q(name.split('\n').first)}',
    after: 'Back in your ${collection.replaceAll('_', ' ')}',
    note: 'Only this one item returns; the link works again.',
    apply: () async => s.restoreDeletedRecord(collection, ref.id),
  );
}

RepairPlan _removeConnector(AppState s, String canvasId, String itemId) {
  return RepairPlan(
    label: 'Remove this hidden connection',
    before: 'A connection with a missing end (not visible on the mindmap)',
    after: 'The connection is removed; every other object stays',
    note: 'Removing cannot be undone from here; a backup keeps the old file.',
    apply: () async {
      if (s.canvas?.id == canvasId) return false; // close it first
      final doc = await s.canvases.load(canvasId);
      if (doc == null) return false;
      final ids = {for (final i in doc.items) i.id};
      final victim = doc.items.where((i) => i.id == itemId).firstOrNull;
      if (victim is! ConnectorItem ||
          (ids.contains(victim.fromId) && ids.contains(victim.toId))) {
        return false;
      }
      await s.workspace.backups.snapshot('before-connection-repair');
      await s.canvases.save(
        doc.copyWith(items: [
          for (final i in doc.items)
            if (i.id != itemId) i,
        ]),
      );
      return true;
    },
  );
}
