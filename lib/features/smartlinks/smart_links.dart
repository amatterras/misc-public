// Smart Workspace Links: links between notes, mindmaps (and single mindmap
// objects), calendar entries and Archive items that point at the object
// itself (its stable id), never at a title or a place. Nothing is copied: a
// link is a short token inside text that is saved and synced like any other
// text, so renaming, moving or archiving the target never breaks it, and a
// deleted target shows as deleted instead of turning into something else.
//
//   [[theapp:note/ID|Label]]        a note
//   [[theapp:canvas/ID|Label]]      a mindmap
//   [[theapp:obj/CANVASID#ITEMID|Label]]   one object on a mindmap
//   [[theapp:entry/ID|Label]]       a calendar entry
//   [[theapp:asset/ID|Label]]       an Archive item
//
// "Label" is only what the link looked like when it was made; what is shown
// is the target's current name. Backlinks are found by reading the same
// text the app already searches (no second index to keep in step).
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/models/library_models.dart' show AssetKind;
import '../pdfanchors/pdf_anchors.dart' show openPdfAnchor;
import '../../data/models/canvas_models.dart';
import '../../data/models/calendar_models.dart';
import '../../data/models/record.dart' show parseDayKey;

enum RefKind { note, canvas, object, entry, asset, pdf }

extension RefKindInfo on RefKind {
  String get tag => switch (this) {
    RefKind.note => 'note',
    RefKind.canvas => 'canvas',
    RefKind.object => 'obj',
    RefKind.entry => 'entry',
    RefKind.asset => 'asset',
    RefKind.pdf => 'pdf',
  };

  String get noun => switch (this) {
    RefKind.note => 'Note',
    RefKind.canvas => 'Mindmap',
    RefKind.object => 'Mindmap object',
    RefKind.entry => 'Calendar',
    RefKind.asset => 'Archive',
    RefKind.pdf => 'PDF page',
  };

  /// Whether this kind of link carries a second part after the #.
  bool get hasItem => this == RefKind.object || this == RefKind.pdf;

  IconData get icon => switch (this) {
    RefKind.note => Icons.description_outlined,
    RefKind.canvas => Icons.grid_view,
    RefKind.object => Icons.crop_square,
    RefKind.entry => Icons.calendar_today_outlined,
    RefKind.asset => Icons.bookmarks_outlined,
    RefKind.pdf => Icons.picture_as_pdf_outlined,
  };
}

/// What a link points at: the kind and the stable id (for a mindmap object
/// the mindmap's id and the object's id).
class WorkspaceRef {
  const WorkspaceRef(this.kind, this.id, [this.item]);

  final RefKind kind;
  final String id;

  /// The object's id on mindmap [id] (kind [RefKind.object]) or the page
  /// number, counted from 1 (kind [RefKind.pdf]).
  final String? item;

  /// The page of a PDF link (from 1), or null.
  int? get page => kind == RefKind.pdf ? int.tryParse(item ?? '') : null;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceRef &&
      other.kind == kind &&
      other.id == id &&
      other.item == item;

  @override
  int get hashCode => Object.hash(kind, id, item);

  String get path => '${kind.tag}/$id${item == null ? '' : '#$item'}';

  /// The token to put in text; [label] has the characters that would end
  /// the token removed.
  String token(String label) {
    final clean = label
        .replaceAll(RegExp(r'[\[\]|\r\n]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '[[theapp:$path${clean.isEmpty ? '' : '|$clean'}]]';
  }

  @override
  String toString() => path;
}

/// A link found in text.
class LinkToken {
  const LinkToken(this.ref, this.label, this.start, this.end);
  final WorkspaceRef ref;
  final String label;
  final int start;
  final int end;
}

final _tokenPattern = RegExp(
  r'\[\[theapp:(note|canvas|obj|entry|asset|pdf)/([A-Za-z0-9_-]+)(?:#([A-Za-z0-9_-]+))?(?:\|([^\]\r\n]*))?\]\]',
);

RefKind? _kindOf(String tag) {
  for (final k in RefKind.values) {
    if (k.tag == tag) return k;
  }
  return null;
}

/// Every link in [text], in order.
List<LinkToken> findLinks(String text) {
  if (!text.contains('[[theapp:')) return const [];
  final out = <LinkToken>[];
  for (final m in _tokenPattern.allMatches(text)) {
    final kind = _kindOf(m.group(1)!);
    if (kind == null) continue;
    final item = m.group(3);
    if (kind.hasItem != (item != null)) continue;
    if (kind == RefKind.pdf && (int.tryParse(item!) ?? 0) < 1) continue;
    out.add(
      LinkToken(
        WorkspaceRef(kind, m.group(2)!, item),
        (m.group(4) ?? '').trim(),
        m.start,
        m.end,
      ),
    );
  }
  return out;
}

/// [text] as people read it: every link is replaced by its label (searching
/// and previews never show the ids).
String plainLinkText(String text) {
  if (!text.contains('[[theapp:')) return text;
  return text.replaceAllMapped(_tokenPattern, (m) {
    final label = (m.group(4) ?? '').trim();
    return label.isEmpty ? m.group(1)! : label;
  });
}

/// [text] without the link to [ref] (the other text is untouched; the label
/// stays as plain words).
String removeLinkTo(String text, WorkspaceRef ref) => text.replaceAllMapped(
  _tokenPattern,
  (m) {
    final kind = _kindOf(m.group(1)!);
    final r = kind == null
        ? null
        : WorkspaceRef(kind, m.group(2)!, m.group(3));
    return r == ref ? (m.group(4) ?? '').trim() : m.group(0)!;
  },
);

enum LinkHealth {
  /// The target exists.
  ok,

  /// The target exists but was archived (it still opens).
  archived,

  /// The target is gone (deleted). The link stays, marked, and works again
  /// if the target is restored: its id is never reused for anything else.
  deleted,

  /// The target is there but cannot be opened right now (a PDF whose file
  /// is missing from this device).
  unavailable,
}

/// How a link looks today.
class ResolvedRef {
  const ResolvedRef({
    required this.ref,
    required this.health,
    required this.title,
    required this.preview,
  });

  final WorkspaceRef ref;
  final LinkHealth health;

  /// The target's current name.
  final String title;

  /// A line or two of what the target holds, for a hover or a preview.
  final String preview;

  bool get opens =>
      health != LinkHealth.deleted && health != LinkHealth.unavailable;
}

String _short(String text, [int max = 160]) {
  final t = plainLinkText(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > max ? '${t.substring(0, max)}…' : t;
}

/// Resolves [ref] against the current workspace. [fallbackLabel] (the link's
/// own label) is only used to name a deleted target.
ResolvedRef resolveRef(AppState s, WorkspaceRef ref, {String? fallbackLabel}) {
  final ws = s.workspace;
  ResolvedRef gone([String? title]) => ResolvedRef(
    ref: ref,
    health: LinkHealth.deleted,
    title: (title ?? '').isNotEmpty
        ? title!
        : (fallbackLabel?.isNotEmpty ?? false)
        ? fallbackLabel!
        : 'Missing ${ref.kind.noun.toLowerCase()}',
    preview: 'This ${ref.kind.noun.toLowerCase()} was deleted.',
  );
  switch (ref.kind) {
    case RefKind.note:
      final n = ws.notes[ref.id];
      if (n == null) {
        // A deleted note keeps its last title among its versions.
        final v = ws.deletedNotes().where((d) => d.noteId == ref.id);
        return gone(v.isEmpty ? null : v.first.title);
      }
      return ResolvedRef(
        ref: ref,
        health: LinkHealth.ok,
        title: n.displayTitle,
        preview: _short(n.body),
      );
    case RefKind.canvas || RefKind.object:
      final c = s.canvasList.where((c) => c.id == ref.id).firstOrNull;
      if (c == null) return gone();
      return ResolvedRef(
        ref: ref,
        health: LinkHealth.ok,
        title: ref.kind == RefKind.canvas
            ? c.title
            : '${fallbackLabel ?? 'Object'} · ${c.title}',
        preview: ref.kind == RefKind.canvas
            ? _short(c.searchText)
            : 'On the mindmap “${c.title}”.',
      );
    case RefKind.entry:
      final e = ws.entries[ref.id];
      if (e == null) return gone();
      return ResolvedRef(
        ref: ref,
        health: e.archived ? LinkHealth.archived : LinkHealth.ok,
        title: e.name,
        preview: _short(
          [e.description, e.notes].where((t) => t.isNotEmpty).join(' · '),
        ),
      );
    case RefKind.asset:
      final a = ws.assets[ref.id];
      if (a == null) return gone();
      return ResolvedRef(
        ref: ref,
        health: LinkHealth.ok,
        title: a.label,
        preview: _short(a.description ?? a.url ?? ''),
      );
    case RefKind.pdf:
      final a = ws.assets[ref.id];
      if (a == null || a.kind != AssetKind.document) {
        return gone(fallbackLabel);
      }
      final page = ref.page ?? 1;
      final file = ws.documentFile(a);
      final title = '${a.label} · page $page';
      if (file == null || !file.existsSync()) {
        return ResolvedRef(
          ref: ref,
          health: LinkHealth.unavailable,
          title: title,
          preview:
              'The file of this PDF is not on this device, so the page cannot be opened.',
        );
      }
      // A file whose size is not the one that was imported was changed or
      // replaced outside THEapp; the link is kept but says so.
      final replaced = a.fileSize != null && file.lengthSync() != a.fileSize;
      return ResolvedRef(
        ref: ref,
        health: LinkHealth.ok,
        title: title,
        preview: replaced
            ? 'This PDF file was changed since it was added, so page $page may not be the same page.'
            : 'Page $page of “${a.label}”.',
      );
  }
}

/// A mindmap object's current state, which needs the mindmap's contents.
Future<ResolvedRef> resolveObject(
  AppState s,
  WorkspaceRef ref, {
  String? fallbackLabel,
}) async {
  final base = resolveRef(s, ref, fallbackLabel: fallbackLabel);
  if (ref.kind != RefKind.object || !base.opens) return base;
  final open = s.canvas?.id == ref.id ? s.canvas : null;
  final items =
      open?.items ?? (await s.canvases.load(ref.id))?.items ?? const [];
  final item = items.where((i) => i.id == ref.item).firstOrNull;
  if (item == null) {
    return ResolvedRef(
      ref: ref,
      health: LinkHealth.deleted,
      title: base.title,
      preview: 'This object was deleted from the mindmap.',
    );
  }
  final text = switch (item) {
    TextItem() => item.text,
    LinkItem() => 'Link card',
    ImageItem() => 'Photo',
    _ => ref.kind.noun,
  };
  return ResolvedRef(
    ref: ref,
    health: LinkHealth.ok,
    title: _short(text, 60).isEmpty ? 'Object' : _short(text, 60),
    preview: base.preview,
  );
}

// ------------------------------------------------------------ backlinks --

/// An item whose text links to a target.
class Backlink {
  const Backlink(this.source, this.title, this.snippet);
  final WorkspaceRef source;
  final String title;
  final String snippet;
}

/// Everything that links to [target] (not counting the target itself),
/// read from the notes, calendar entries, Archive items and mindmap text
/// the app already holds. For a mindmap object the mindmap-level links are
/// included too.
List<Backlink> backlinksTo(AppState s, WorkspaceRef target) {
  final ws = s.workspace;
  final out = <Backlink>[];
  void scan(WorkspaceRef source, String title, Iterable<String> texts) {
    if (source == target) return;
    for (final text in texts) {
      for (final t in findLinks(text)) {
        if (t.ref == target) {
          final at = text.substring(0, t.start);
          final from = at.length > 40 ? at.substring(at.length - 40) : at;
          out.add(
            Backlink(
              source,
              title,
              _short('$from${t.label.isEmpty ? '' : t.label}', 90),
            ),
          );
          return;
        }
      }
    }
  }

  for (final n in ws.notes.all) {
    scan(WorkspaceRef(RefKind.note, n.id), n.displayTitle, [n.body]);
  }
  for (final e in ws.entries.all) {
    scan(WorkspaceRef(RefKind.entry, e.id), e.name, [e.description, e.notes]);
  }
  for (final a in ws.assets.all) {
    scan(WorkspaceRef(RefKind.asset, a.id), a.label, [
      a.description ?? '',
      a.title ?? '',
    ]);
  }
  for (final c in s.canvasList) {
    scan(WorkspaceRef(RefKind.canvas, c.id), c.title, [c.searchText]);
  }
  out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return out;
}

/// The links inside [text] with their current state (for the "links in this
/// item" list).
List<ResolvedRef> outgoingLinks(AppState s, String text) => [
  for (final t in findLinks(text))
    resolveRef(s, t.ref, fallbackLabel: t.label),
];

/// A calendar entry's day, for opening it.
DateTime entryDay(CalendarEntry e) =>
    e.startDate ??
    (e.dates.isNotEmpty ? parseDayKey((e.dates.toList()..sort()).first) : null) ??
    DateTime.now();

// ----------------------------------------------------------- navigation --

/// Opens the target of a link and remembers where the user came from, so
/// "Back" returns there. [from] is the item the link was in (for a sensible
/// label and return place). A deleted target is not opened; the user is
/// told instead. Returns whether something was opened.
Future<bool> openWorkspaceRef(
  AppState s,
  WorkspaceRef target, {
  WorkspaceRef? from,
  String? label,
}) async {
  final r = await (target.kind == RefKind.object
      ? resolveObject(s, target, fallbackLabel: label)
      : Future.value(resolveRef(s, target, fallbackLabel: label)));
  if (!r.opens) {
    s.showToast(
      'That ${target.kind.noun.toLowerCase()} was deleted '
      '(“${r.title}”). The link is kept in case it is restored.',
    );
    return false;
  }
  final back = _returnPoint(s, from);
  switch (target.kind) {
    case RefKind.note:
      s.openNote(target.id);
    case RefKind.canvas:
      await s.openCanvas(target.id);
    case RefKind.object:
      await s.openCanvas(target.id);
      s.canvas?.reveal(target.item!);
    case RefKind.entry:
      final e = s.workspace.entries[target.id];
      if (e == null) return false;
      s.openCalendarDay(entryDay(e));
    case RefKind.asset:
      if (!await s.openLinkCard(target.id)) {
        s.showToast('That Archive item is not on the board.');
        return false;
      }
    case RefKind.pdf:
      if (!await openPdfAnchor(s, target)) return false;
  }
  final stack = s.linkReturn.value;
  if (back != null && (stack.isEmpty || stack.last.label != back.label)) {
    s.linkReturn.value = [
      ...stack.length >= 20 ? stack.sublist(1) : stack,
      back,
    ];
  }
  return true;
}

ReturnPoint? _returnPoint(AppState s, WorkspaceRef? from) {
  if (from != null) {
    final r = resolveRef(s, from);
    if (!r.opens) return null;
    return (
      label: r.title,
      restore: () async {
        // Going back never leaves a second return point behind.
        switch (from.kind) {
          case RefKind.note:
            s.openNote(from.id);
          case RefKind.canvas || RefKind.object:
            await s.openCanvas(from.id);
            if (from.item != null) s.canvas?.reveal(from.item!);
          case RefKind.entry:
            final e = s.workspace.entries[from.id];
            if (e != null) s.openCalendarDay(entryDay(e));
          case RefKind.asset:
            await s.openLinkCard(from.id);
          case RefKind.pdf:
            await openPdfAnchor(s, from);
        }
      },
    );
  }
  final page = s.page;
  return (label: 'where you were', restore: () async => s.goTo(page));
}

/// Goes back to where the last followed link was clicked.
Future<void> goBackFromLink(AppState s) async {
  final stack = s.linkReturn.value;
  if (stack.isEmpty) return;
  final point = stack.last;
  s.linkReturn.value = stack.sublist(0, stack.length - 1);
  await point.restore();
}
