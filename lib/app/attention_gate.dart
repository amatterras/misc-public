// Keeps notifications rare: something that needs the user's attention is
// announced once, then not again until a cooldown has passed (or the problem
// went away and came back). Retries, reconnects and routine successes never
// pass through here: they only change the status page.
class AttentionGate {
  AttentionGate({this.cooldown = const Duration(hours: 24)});

  final Duration cooldown;
  final Map<String, DateTime> _last = {};

  /// True when [issue] may be announced now. Calling it counts as having
  /// announced it.
  bool allow(String issue, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final before = _last[issue];
    if (before != null && at.difference(before) < cooldown) return false;
    _last[issue] = at;
    return true;
  }

  /// The problem is gone: a later recurrence is announced again.
  void resolved(String issue) => _last.remove(issue);
}
