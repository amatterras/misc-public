// Fields this app version does not know, e.g. written by a newer version on
// another device. They are kept next to the record and written back (and
// synced) unchanged, so editing a record in an older version never drops
// what a newer one added. Known fields always win over kept ones.

/// The entries of [raw] whose keys are not in [known].
Map<String, dynamic> unknownFields(
  Map<String, dynamic> raw,
  Iterable<String> known,
) {
  final keys = known.toSet();
  return {
    for (final e in raw.entries)
      if (!keys.contains(e.key)) e.key: e.value,
  };
}

/// [known] with [kept] added back underneath it.
Map<String, dynamic> withUnknownFields(
  Map<String, dynamic> known,
  Map<String, dynamic>? kept,
) => kept == null || kept.isEmpty ? known : {...kept, ...known};
