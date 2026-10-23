// Field-level merges for the two values that two devices are likely to
// change at the same time but that sync otherwise treats as one unit
// (the hub keeps one whole version): a link's tags and a notebook's PDF
// pages. Used when the hub kept its own version over ours, so neither
// device's change is lost.
import '../data/models/canvas_models.dart';

/// Tags after combining our change with the hub's version ([local], as it
/// is here after taking the hub's version).
///
/// With [base] (the tags as last synced) this is a three-way merge: tags
/// we added are added, tags we removed are removed, the other device's
/// changes stay. Without a base, ours are only added (never removes
/// anything the other device has).
List<String> mergeLinkTags({
  required List<String> local,
  required List<String> ours,
  List<String>? base,
}) {
  final before = base ?? local;
  final added = ours.where((t) => !before.contains(t));
  final removed = base == null
      ? const <String>{}
      : base.where((t) => !ours.contains(t)).toSet();
  final result = <String>[];
  for (final t in [...local, ...added]) {
    if (!removed.contains(t) && !result.contains(t)) result.add(t);
  }
  return result;
}

/// The notebook's PDF pages after combining ours with the hub's ([local]).
/// PDF pages are only ever added, so nothing is dropped: a page of ours
/// that the hub's version lacks is added; if its page number is taken by a
/// different PDF page, it goes after the last page. Null if nothing to add.
List<PageBackground>? mergePageBackgrounds(
  List<PageBackground> local,
  List<PageBackground> ours,
) {
  bool same(PageBackground a, PageBackground b) =>
      a.assetId == b.assetId && a.pdfPage == b.pdfPage;
  final missing = [
    for (final b in ours)
      if (!local.any((l) => same(l, b))) b,
  ];
  if (missing.isEmpty) return null;
  final result = [...local];
  var next = [
    for (final b in [...local, ...ours]) b.pageIndex + 1,
  ].fold(0, (a, b) => a > b ? a : b);
  for (final b in missing..sort((a, b) => a.pageIndex.compareTo(b.pageIndex))) {
    final taken = result.any((r) => r.pageIndex == b.pageIndex);
    result.add(
      taken
          ? PageBackground(
              pageIndex: next++,
              assetId: b.assetId,
              pdfPage: b.pdfPage,
              width: b.width,
              height: b.height,
            )
          : b,
    );
  }
  return result..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
}
